// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AtomaVault is ERC4626Upgradeable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant PERFORMANCE_FEE_BPS = 2000; // 20%
    uint256 public constant WITHDRAWAL_FEE_BPS = 50;  // 0.5%
    uint256 public constant NAV_PRECISION = 1e18;
    uint256 public constant MIN_DEPOSIT = 100e6;       // 100 USDC

    uint64 public constant MIN_EPOCH_DURATION = 1 hours;
    uint64 public constant MAX_EPOCH_DURATION = 30 days;

    uint256 public constant FEE_CRYSTALLIZATION_PERIOD = 7 days;
    uint256 public constant CAPITAL_WHITELIST_DELAY = 24 hours;
    uint256 public constant DEFAULT_MAX_UPDATE_DELTA_BPS = 200;
    uint64 public constant DEFAULT_MIN_UPDATE_INTERVAL = 30 minutes;
    uint64 public constant MAX_MIN_UPDATE_INTERVAL = 1 days;

    uint256 private _totalManagedAssets;
    uint256 public highWaterMark;
    uint256 public genesisTimestamp;
    address public operator;
    uint256 public maxTotalAssets;

    mapping(address => uint256) public depositEpoch;

    struct EpochData {
        uint256 totalSharesRequested;
        uint256 settlementNav;
        bool settled;
    }

    mapping(uint256 => EpochData) private _epochs;
    mapping(uint256 => mapping(address => uint256)) public userEpochShares;

    struct EpochSchedule {
        uint64 startTimestamp;
        uint64 startEpochId;
        uint64 duration;
        uint64 _reserved;
    }

    EpochSchedule[] private _schedules;

    uint256 public maxUpdateDeltaBps;
    uint64 public minUpdateInterval;
    uint64 public lastUpdateAt;
    uint64 public lastCrystallizedAt;
    uint256 public settledUnclaimedAssets;
    mapping(address => uint256) public capitalDestinationActiveAt;

    mapping(address => uint256) public lockedShares;
    uint256 private _shortfallIndexWad;
    mapping(uint256 => uint256) private _epochIndexAtSettle;
    bool private _escrowUnlocked;

    event WithdrawalRequested(address indexed user, uint256 shares, uint256 requestEpoch, uint256 settlementEpoch);
    event EpochSettled(uint256 indexed epochId, uint256 settlementNav, uint256 totalShares);
    event WithdrawalClaimed(address indexed user, uint256 indexed epochId, uint256 shares, uint256 assets, uint256 fee);
    event TotalAssetsUpdated(uint256 newTotal, uint256 navPerShare, uint256 timestamp);
    event PerformanceFeeCharged(uint256 feeShares, uint256 newHwm);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event MaxTotalAssetsUpdated(uint256 newCap);
    event EpochDurationScheduled(uint64 newDuration, uint256 startEpochId, uint256 startTimestamp);
    event UpdateBoundsUpdated(uint256 maxDeltaBps, uint64 minInterval);
    event CapitalDestinationWhitelisted(address indexed destination, uint256 activeAt);
    event CapitalDestinationRevoked(address indexed destination);
    event ClaimsHaircut(uint256 newIndexWad, uint256 remainingLiabilities);

    error NotOperator();
    error DepositLocked();
    error ZeroShares();
    error InsufficientShares();
    error EpochNotEnded();
    error EpochAlreadySettled();
    error EpochNoRequests();
    error EpochNotSettled();
    error NothingToClaim();
    error InsufficientIdle();
    error UseRequestWithdrawal();
    error DepositCapExceeded();
    error BelowMinDeposit();
    error ZeroAddress();
    error TransferDisabled();
    error EpochDurationOutOfBounds();
    error UpdateTooFrequent();
    error UpdateDeltaTooLarge();
    error CrystallizationNotDue();
    error DestinationNotWhitelisted();
    error SchedulesAlreadyInitialized();
    error InvalidBounds();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 asset_, address owner_, address operator_, string memory name_, string memory symbol_) public initializer {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();

        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __Pausable_init();
        __Ownable_init(owner_);

        operator = operator_;
        genesisTimestamp = block.timestamp;
        highWaterMark = NAV_PRECISION / (10 ** _decimalsOffset());

        _schedules.push(EpochSchedule({
            startTimestamp: uint64(block.timestamp),
            startEpochId: 0,
            duration: 1 hours,
            _reserved: 0
        }));

        _seedNavControls();
    }

    function _seedNavControls() internal {
        maxUpdateDeltaBps = DEFAULT_MAX_UPDATE_DELTA_BPS;
        minUpdateInterval = DEFAULT_MIN_UPDATE_INTERVAL;
        lastCrystallizedAt = uint64(block.timestamp);
    }

    function initializeV2() external reinitializer(2) onlyOwner {
        if (_schedules.length != 0) revert SchedulesAlreadyInitialized();
        _schedules.push(EpochSchedule({
            startTimestamp: uint64(genesisTimestamp),
            startEpochId: 0,
            duration: 1 hours,
            _reserved: 0
        }));
    }

    function initializeV3() external reinitializer(3) onlyOwner {
        _seedNavControls();
    }

    // Views
    function _activeSchedule() internal view returns (EpochSchedule memory) {
        for (uint256 i = _schedules.length; i > 0; i--) {
            if (block.timestamp >= _schedules[i - 1].startTimestamp) {
                return _schedules[i - 1];
            }
        }
        revert("No active schedule");
    }

    function _scheduleForEpoch(uint256 epochId) internal view returns (EpochSchedule memory) {
        for (uint256 i = _schedules.length; i > 0; i--) {
            if (epochId >= _schedules[i - 1].startEpochId) {
                return _schedules[i - 1];
            }
        }
        revert("Epoch before any schedule");
    }

    function epochDuration() external view returns (uint64) {
        return _activeSchedule().duration;
    }

    function scheduleCount() external view returns (uint256) {
        return _schedules.length;
    }

    function scheduleAt(uint256 index) external view returns (EpochSchedule memory) {
        return _schedules[index];
    }

    function getCurrentEpoch() public view returns (uint256) {
        EpochSchedule memory s = _activeSchedule();
        return s.startEpochId + (block.timestamp - s.startTimestamp) / s.duration;
    }

    function getEpochEndTime(uint256 epochId) public view returns (uint256) {
        EpochSchedule memory s = _scheduleForEpoch(epochId);
        return s.startTimestamp + (epochId - s.startEpochId + 1) * s.duration;
    }

    function getEpoch(uint256 epochId) external view returns (uint256 totalSharesRequested, uint256 settlementNav, bool settled) {
        EpochData storage e = _epochs[epochId];
        return (e.totalSharesRequested, e.settlementNav, e.settled);
    }

    /// @dev A zero slot means "no shortfall has ever been recorded" — either the vault has always
    ///      been solvent, or V4 storage was never seeded. Both read as a full, unhaircut claim.
    function shortfallIndexWad() public view returns (uint256) {
        uint256 idx = _shortfallIndexWad;
        return idx == 0 ? NAV_PRECISION : idx;
    }

    function epochIndexAtSettle(uint256 epochId) public view returns (uint256) {
        uint256 idx = _epochIndexAtSettle[epochId];
        return idx == 0 ? NAV_PRECISION : idx;
    }

    function totalAssets() public view override returns (uint256) {
        return _totalManagedAssets - settledUnclaimedAssets;
    }

    // ERC-4626 Overrides

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool isMint = from == address(0);
        bool isBurn = to == address(0);
        bool isEscrow = to == address(this) && _escrowUnlocked;
        if (!isMint && !isBurn && !isEscrow) revert TransferDisabled();
        super._update(from, to, value);
    }

    function _applyDepositLock(address receiver, uint256 shares) internal {
        uint256 ep = getCurrentEpoch();
        if (depositEpoch[receiver] != ep) {
            depositEpoch[receiver] = ep;
            lockedShares[receiver] = 0;
        }
        lockedShares[receiver] += shares;
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        if (assets < MIN_DEPOSIT) revert BelowMinDeposit();
        if (maxTotalAssets > 0 && _totalManagedAssets + assets > maxTotalAssets) revert DepositCapExceeded();
        _accrueFee();
        uint256 shares = super.deposit(assets, receiver);
        _totalManagedAssets += assets;
        _applyDepositLock(receiver, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256) {
        _accrueFee();
        uint256 assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert BelowMinDeposit();
        if (maxTotalAssets > 0 && _totalManagedAssets + assets > maxTotalAssets) revert DepositCapExceeded();
        assets = super.mint(shares, receiver);
        _totalManagedAssets += assets;
        _applyDepositLock(receiver, shares);
        return assets;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (maxTotalAssets == 0) return type(uint256).max;
        if (_totalManagedAssets >= maxTotalAssets) return 0;
        return maxTotalAssets - _totalManagedAssets;
    }

    function maxMint(address) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 maxDep = maxDeposit(address(0));
        if (maxDep == type(uint256).max) return type(uint256).max;
        return previewDeposit(maxDep);
    }

    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseRequestWithdrawal();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseRequestWithdrawal();
    }

    // Epoch-Based Withdrawals

    function requestWithdrawal(uint256 shares) external {
        uint256 currentEp = getCurrentEpoch();
        if (shares == 0) revert ZeroShares();
        uint256 balance = balanceOf(msg.sender);
        if (balance < shares) revert InsufficientShares();

        uint256 locked = depositEpoch[msg.sender] >= currentEp ? lockedShares[msg.sender] : 0;
        if (shares > (balance > locked ? balance - locked : 0)) revert DepositLocked();

        _escrowUnlocked = true;
        _transfer(msg.sender, address(this), shares);
        _escrowUnlocked = false;

        uint256 settlementEpoch = currentEp + 1;
        userEpochShares[settlementEpoch][msg.sender] += shares;
        _epochs[settlementEpoch].totalSharesRequested += shares;

        emit WithdrawalRequested(msg.sender, shares, currentEp, settlementEpoch);
    }

    function settleEpoch(uint256 epochId) external onlyOperator {
        EpochData storage e = _epochs[epochId];
        if (getCurrentEpoch() <= epochId) revert EpochNotEnded();
        if (e.settled) revert EpochAlreadySettled();
        uint256 sharesRequested = e.totalSharesRequested;
        if (sharesRequested == 0) revert EpochNoRequests();

        uint256 navGross = totalAssets() * NAV_PRECISION / totalSupply();
        uint256 nav = navGross;

        if (navGross > highWaterMark) {
            uint256 feePerShare = (navGross - highWaterMark) * PERFORMANCE_FEE_BPS / 10000;
            nav = navGross - feePerShare;

            uint256 feeAssets = sharesRequested * feePerShare / NAV_PRECISION;
            if (feeAssets > 0) {
                uint256 feeShares = feeAssets * NAV_PRECISION / navGross;
                _mint(operator, feeShares);
                emit PerformanceFeeCharged(feeShares, highWaterMark);
            }
        }

        e.settlementNav = nav;
        e.settled = true;
        _epochIndexAtSettle[epochId] = shortfallIndexWad();

        _burn(address(this), sharesRequested);
        settledUnclaimedAssets += sharesRequested * nav / NAV_PRECISION;

        emit EpochSettled(epochId, nav, sharesRequested);
    }

    function claimWithdrawal(uint256 epochId) external {
        if (!_epochs[epochId].settled) revert EpochNotSettled();
        uint256 shares = userEpochShares[epochId][msg.sender];
        if (shares == 0) revert NothingToClaim();

        userEpochShares[epochId][msg.sender] = 0;

        uint256 assets = shares * _epochs[epochId].settlementNav / NAV_PRECISION;
        uint256 idxAtSettle = epochIndexAtSettle(epochId);
        uint256 idxNow = shortfallIndexWad();
        if (idxNow < idxAtSettle) assets = assets * idxNow / idxAtSettle;

        uint256 fee = assets * WITHDRAWAL_FEE_BPS / 10000;
        uint256 payout = assets - fee;

        IERC20 token = IERC20(asset());
        if (token.balanceOf(address(this)) < assets) revert InsufficientIdle();

        _totalManagedAssets -= assets;
        settledUnclaimedAssets -= assets;

        token.safeTransfer(msg.sender, payout);
        if (fee > 0) {
            token.safeTransfer(operator, fee);
        }

        emit WithdrawalClaimed(msg.sender, epochId, shares, payout, fee);
    }

    // NAV + Fee Management
    function updateTotalAssets(int256 pnlDelta) external onlyOperator {
        if (block.timestamp < lastUpdateAt + minUpdateInterval) revert UpdateTooFrequent();

        uint256 current = _totalManagedAssets;
        uint256 magnitude = pnlDelta < 0 ? uint256(-pnlDelta) : uint256(pnlDelta);
        if (magnitude > current * maxUpdateDeltaBps / 10000) revert UpdateDeltaTooLarge();

        lastUpdateAt = uint64(block.timestamp);
        _setTotalAssets(pnlDelta < 0 ? current - magnitude : current + magnitude);
    }

    function _setTotalAssets(uint256 newTotal) internal {
        uint256 liabilities = settledUnclaimedAssets;
        if (liabilities > 0 && newTotal < liabilities) {
            uint256 scaled = shortfallIndexWad() * newTotal / liabilities;
            _shortfallIndexWad = scaled == 0 ? 1 : scaled;
            settledUnclaimedAssets = newTotal;
            emit ClaimsHaircut(_shortfallIndexWad, newTotal);
        }
        _totalManagedAssets = newTotal;
        uint256 supply = totalSupply();
        emit TotalAssetsUpdated(newTotal, supply > 0 ? totalAssets() * NAV_PRECISION / supply : 0, block.timestamp);
    }

    function crystallizePerformanceFee() external onlyOperator {
        if (block.timestamp < lastCrystallizedAt + FEE_CRYSTALLIZATION_PERIOD) revert CrystallizationNotDue();
        lastCrystallizedAt = uint64(block.timestamp);
        _accrueFee();
    }

    function _accrueFee() internal {
        uint256 supply = totalSupply();
        if (supply == 0) return;

        uint256 total = totalAssets();
        uint256 nav = total * NAV_PRECISION / supply;
        if (nav <= highWaterMark) return;

        uint256 profit = (nav - highWaterMark) * supply / NAV_PRECISION;
        uint256 feeAssets = profit * PERFORMANCE_FEE_BPS / 10000;
        if (feeAssets == 0) return;

        uint256 feeShares = feeAssets * supply / (total - feeAssets);
        if (feeShares == 0) return;
        _mint(operator, feeShares);

        highWaterMark = totalAssets() * NAV_PRECISION / totalSupply();
        emit PerformanceFeeCharged(feeShares, highWaterMark);
    }

    // Owner only
    function resyncTotalAssets(uint256 newTotal) external onlyOwner whenPaused {
        _setTotalAssets(newTotal);
    }

    function setUpdateBounds(uint256 maxDeltaBps, uint64 minInterval) external onlyOwner {
        if (maxDeltaBps == 0 || maxDeltaBps > 10000 || minInterval > MAX_MIN_UPDATE_INTERVAL) revert InvalidBounds();
        maxUpdateDeltaBps = maxDeltaBps;
        minUpdateInterval = minInterval;
        emit UpdateBoundsUpdated(maxDeltaBps, minInterval);
    }

    function whitelistCapitalDestination(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 activeAt = block.timestamp + CAPITAL_WHITELIST_DELAY;
        capitalDestinationActiveAt[to] = activeAt;
        emit CapitalDestinationWhitelisted(to, activeAt);
    }

    function revokeCapitalDestination(address to) external onlyOwner {
        capitalDestinationActiveAt[to] = 0;
        emit CapitalDestinationRevoked(to);
    }

    /// @notice Moves idle assets out to a whitelisted destination so they can be deployed to the
    ///         off-chain trading venue, which only accepts deposits from the project wallet.
    /// @dev ACCEPTED DESIGN — not a vulnerability. This vault custodies assets off-chain, so the
    ///      owner (Gnosis Safe) MUST be able to withdraw custodied funds; there is no trustless
    ///      variant of this flow. Guards: 24h destination whitelist delay + settled withdrawal
    ///      liabilities reserved below. Do not "fix" by removing owner capital access.
    function capitalWithdraw(address to, uint256 amount) external onlyOwner {
        uint256 activeAt = capitalDestinationActiveAt[to];
        if (activeAt == 0 || block.timestamp < activeAt) revert DestinationNotWhitelisted();
        IERC20 token = IERC20(asset());
        if (token.balanceOf(address(this)) < amount + settledUnclaimedAssets) revert InsufficientIdle();
        token.safeTransfer(to, amount);
    }

    function capitalDeposit(uint256 amount) external onlyOwner {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function setMaxTotalAssets(uint256 cap) external onlyOwner {
        maxTotalAssets = cap;
        emit MaxTotalAssetsUpdated(cap);
    }

    function setEpochDuration(uint64 newDuration) external onlyOwner {
        if (newDuration < MIN_EPOCH_DURATION || newDuration > MAX_EPOCH_DURATION) {
            revert EpochDurationOutOfBounds();
        }

        EpochSchedule memory active = _activeSchedule();
        uint256 currentEp = active.startEpochId + (block.timestamp - active.startTimestamp) / active.duration;
        uint256 nextStart = active.startTimestamp + (currentEp - active.startEpochId + 1) * active.duration;
        uint256 nextEpochId = currentEp + 1;

        EpochSchedule memory newEntry = EpochSchedule({
            startTimestamp: uint64(nextStart),
            startEpochId: uint64(nextEpochId),
            duration: newDuration,
            _reserved: 0
        });

        uint256 len = _schedules.length;
        if (len > 0 && _schedules[len - 1].startTimestamp > block.timestamp) {
            _schedules[len - 1] = newEntry;
        } else {
            _schedules.push(newEntry);
        }

        emit EpochDurationScheduled(newDuration, nextEpochId, nextStart);
    }

    function pause() external onlyOperator {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[35] private __gap;
}
