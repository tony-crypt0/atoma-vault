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

    event WithdrawalRequested(address indexed user, uint256 shares, uint256 requestEpoch, uint256 settlementEpoch);
    event EpochSettled(uint256 indexed epochId, uint256 settlementNav, uint256 totalShares);
    event WithdrawalClaimed(address indexed user, uint256 indexed epochId, uint256 shares, uint256 assets, uint256 fee);
    event TotalAssetsUpdated(uint256 newTotal, uint256 navPerShare, uint256 timestamp);
    event PerformanceFeeCharged(uint256 feeShares, uint256 newHwm);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event MaxTotalAssetsUpdated(uint256 newCap);
    event EpochDurationScheduled(uint64 newDuration, uint256 startEpochId, uint256 startTimestamp);

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

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 asset_, address owner_, address operator_) public initializer {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();

        __ERC4626_init(asset_);
        __ERC20_init("Atoma Vault Share", "AVS");
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
    }

    function initializeV2() external reinitializer(2) onlyOwner {
        _schedules.push(EpochSchedule({
            startTimestamp: uint64(genesisTimestamp),
            startEpochId: 0,
            duration: 1 hours,
            _reserved: 0
        }));
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

    function totalAssets() public view override returns (uint256) {
        return _totalManagedAssets;
    }

    // ERC-4626 Overrides

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _update(address from, address to, uint256 value) internal override {
        bool isMint = from == address(0);
        bool isBurn = to == address(0);
        bool isVaultTransfer = from == address(this) || to == address(this);
        if (!isMint && !isBurn && !isVaultTransfer) revert TransferDisabled();
        super._update(from, to, value);
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        if (assets < MIN_DEPOSIT) revert BelowMinDeposit();
        if (maxTotalAssets > 0 && _totalManagedAssets + assets > maxTotalAssets) revert DepositCapExceeded();
        uint256 shares = super.deposit(assets, receiver);
        _totalManagedAssets += assets;
        depositEpoch[msg.sender] = getCurrentEpoch();
        return shares;
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256) {
        uint256 assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert BelowMinDeposit();
        if (maxTotalAssets > 0 && _totalManagedAssets + assets > maxTotalAssets) revert DepositCapExceeded();
        assets = super.mint(shares, receiver);
        _totalManagedAssets += assets;
        depositEpoch[msg.sender] = getCurrentEpoch();
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

    function requestWithdrawal(uint256 shares) external whenNotPaused {
        uint256 currentEp = getCurrentEpoch();
        if (depositEpoch[msg.sender] >= currentEp) revert DepositLocked();
        if (shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        _transfer(msg.sender, address(this), shares);

        uint256 settlementEpoch = currentEp + 1;
        userEpochShares[settlementEpoch][msg.sender] += shares;
        _epochs[settlementEpoch].totalSharesRequested += shares;

        emit WithdrawalRequested(msg.sender, shares, currentEp, settlementEpoch);
    }

    function settleEpoch(uint256 epochId) external onlyOperator {
        if (getCurrentEpoch() <= epochId) revert EpochNotEnded();
        if (_epochs[epochId].settled) revert EpochAlreadySettled();
        if (_epochs[epochId].totalSharesRequested == 0) revert EpochNoRequests();

        uint256 supply = totalSupply();
        uint256 nav = supply > 0 ? _totalManagedAssets * NAV_PRECISION / supply : NAV_PRECISION;

        _epochs[epochId].settlementNav = nav;
        _epochs[epochId].settled = true;

        emit EpochSettled(epochId, nav, _epochs[epochId].totalSharesRequested);
    }

    function claimWithdrawal(uint256 epochId) external {
        if (!_epochs[epochId].settled) revert EpochNotSettled();
        uint256 shares = userEpochShares[epochId][msg.sender];
        if (shares == 0) revert NothingToClaim();

        userEpochShares[epochId][msg.sender] = 0;

        uint256 assets = shares * _epochs[epochId].settlementNav / NAV_PRECISION;
        uint256 fee = assets * WITHDRAWAL_FEE_BPS / 10000;
        uint256 payout = assets - fee;

        IERC20 token = IERC20(asset());
        if (token.balanceOf(address(this)) < assets) revert InsufficientIdle();

        _burn(address(this), shares);
        _totalManagedAssets -= assets;

        token.safeTransfer(msg.sender, payout);
        if (fee > 0) {
            token.safeTransfer(operator, fee);
        }

        emit WithdrawalClaimed(msg.sender, epochId, shares, payout, fee);
    }

    // NAV + Fee Management
    function updateTotalAssets(uint256 newTotal) external onlyOperator {
        uint256 supply = totalSupply();

        if (supply > 0) {
            uint256 newNav = newTotal * NAV_PRECISION / supply;

            if (newNav > highWaterMark) {
                uint256 profit = (newNav - highWaterMark) * supply / NAV_PRECISION;
                uint256 feeAssets = profit * PERFORMANCE_FEE_BPS / 10000;

                if (feeAssets > 0) {
                    uint256 feeShares = feeAssets * supply / (newTotal - feeAssets);
                    _mint(operator, feeShares);

                    supply = totalSupply();
                    highWaterMark = newTotal * NAV_PRECISION / supply;

                    emit PerformanceFeeCharged(feeShares, highWaterMark);
                }
            }

            emit TotalAssetsUpdated(newTotal, newTotal * NAV_PRECISION / totalSupply(), block.timestamp);
        }

        _totalManagedAssets = newTotal;
    }

    // Owner only
    function capitalWithdraw(address to, uint256 amount) external onlyOwner {
        IERC20(asset()).safeTransfer(to, amount);
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

    uint256[43] private __gap;
}
