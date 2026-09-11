// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AtomaVault.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AtomaVaultTest is Test {
    AtomaVault public vault;
    MockUSDC public usdc;

    address public operatorAddr = makeAddr("operator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant ONE_USDC = 1e6;
    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant MIN_DEPOSIT = 100 * ONE_USDC;

    function setUp() public {
        usdc = new MockUSDC();

        AtomaVault impl = new AtomaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AtomaVault.initialize, (IERC20(address(usdc)), operatorAddr, operatorAddr, "Atoma Vault Share", "AVS"))
        );
        vault = AtomaVault(address(proxy));

        usdc.mint(alice, 1_000_000 * ONE_USDC);
        usdc.mint(bob, 1_000_000 * ONE_USDC);
        usdc.mint(operatorAddr, 1_000_000 * ONE_USDC);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(operatorAddr);
        usdc.approve(address(vault), type(uint256).max);

        vm.startPrank(operatorAddr);
        vault.setUpdateBounds(10000, 0);
        vault.whitelistCapitalDestination(operatorAddr);
        vm.stopPrank();
    }

    function _crystallize() internal {
        vm.warp(block.timestamp + vault.FEE_CRYSTALLIZATION_PERIOD());
        vm.prank(operatorAddr);
        vault.crystallizePerformanceFee();
    }

    // ──────────── Deposit ────────────

    function test_deposit_mintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 1000 * ONE_USDC);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_deposit_setsEpochLock() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        assertEq(vault.depositEpoch(alice), vault.getCurrentEpoch());
    }

    function test_deposit_secondDeposit_sameSharePrice() public {
        vm.prank(alice);
        uint256 shares1 = vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(bob);
        uint256 shares2 = vault.deposit(1000 * ONE_USDC, bob);

        assertEq(shares1, shares2);
    }

    function test_deposit_afterProfit_fewerShares() public {
        vm.prank(alice);
        uint256 shares1 = vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(100 * ONE_USDC));

        vm.prank(bob);
        uint256 shares2 = vault.deposit(1000 * ONE_USDC, bob);

        assertLt(shares2, shares1);
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(operatorAddr);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1000 * ONE_USDC, alice);
    }

    // ──────────── Withdraw/Redeem Disabled ────────────

    function test_withdraw_reverts() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.UseRequestWithdrawal.selector);
        vault.withdraw(1000 * ONE_USDC, alice, alice);
    }

    function test_redeem_reverts() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.UseRequestWithdrawal.selector);
        vault.redeem(shares, alice, alice);
    }

    // ──────────── Request Withdrawal ────────────

    function test_requestWithdrawal_revertsIfSameEpoch() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.DepositLocked.selector);
        vault.requestWithdrawal(shares);
    }

    function test_requestWithdrawal_succeedsNextEpoch() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vault.requestWithdrawal(shares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    function test_requestWithdrawal_queuesForCorrectEpoch() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        uint256 currentEp = vault.getCurrentEpoch();

        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = currentEp + 1;
        assertEq(vault.userEpochShares(settlementEpoch, alice), shares);

        (uint256 totalRequested,,) = vault.getEpoch(settlementEpoch);
        assertEq(totalRequested, shares);
    }

    function test_requestWithdrawal_revertsZeroShares() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.ZeroShares.selector);
        vault.requestWithdrawal(0);
    }

    function test_requestWithdrawal_revertsInsufficientShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.InsufficientShares.selector);
        vault.requestWithdrawal(shares + 1);
    }

    function test_requestWithdrawal_succeedsWhenPaused() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(operatorAddr);
        vault.pause();

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        assertEq(vault.userEpochShares(settlementEpoch, alice), shares);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    function test_deposit_thirdPartyCannotExtendExistingLock() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(bob);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 gifted = vault.balanceOf(alice) - aliceShares;
        assertEq(vault.lockedShares(alice), gifted, "griefing deposit must lock only the gifted shares");

        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);
    }

    // ──────────── Settle Epoch ────────────

    function test_settleEpoch_recordsCorrectNav() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;

        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        (, uint256 nav, bool settled) = vault.getEpoch(settlementEpoch);
        assertTrue(settled);
        assertGt(nav, 0);
    }

    function test_settleEpoch_revertsIfNotEnded() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.EpochNotEnded.selector);
        vault.settleEpoch(settlementEpoch);
    }

    function test_settleEpoch_revertsIfAlreadySettled() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.EpochAlreadySettled.selector);
        vault.settleEpoch(settlementEpoch);
    }

    function test_settleEpoch_revertsIfNoRequests() public {
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.EpochNoRequests.selector);
        vault.settleEpoch(1);
    }

    function test_settleEpoch_revertsIfNotOperator() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.NotOperator.selector);
        vault.settleEpoch(settlementEpoch);
    }

    // ──────────── Claim Withdrawal ────────────

    function test_claimWithdrawal_paysCorrectAmount() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);
        uint256 received = usdc.balanceOf(alice) - balBefore;

        uint256 expectedPayout = 1000 * ONE_USDC * 9950 / 10000;
        assertApproxEqAbs(received, expectedPayout, 1);
    }

    function test_claimWithdrawal_feeGoesToOperator() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        uint256 opBalBefore = usdc.balanceOf(operatorAddr);
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);
        uint256 opReceived = usdc.balanceOf(operatorAddr) - opBalBefore;

        uint256 expectedFee = 1000 * ONE_USDC * 50 / 10000;
        assertApproxEqAbs(opReceived, expectedFee, 1);
    }

    function test_settleEpoch_burnsSharesAndExcludesLiabilities() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(1000 * ONE_USDC, bob);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        assertEq(vault.totalSupply(), bobShares);
        assertApproxEqAbs(vault.totalAssets(), 1000 * ONE_USDC, 2);
        assertApproxEqAbs(vault.settledUnclaimedAssets(), 1000 * ONE_USDC, 2);

        uint256 supplyBefore = vault.totalSupply();
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);

        assertEq(vault.totalSupply(), supplyBefore);
        assertApproxEqAbs(vault.totalAssets(), 1000 * ONE_USDC, 2);
        assertApproxEqAbs(vault.settledUnclaimedAssets(), 0, 2);
    }

    function test_settleEpoch_escrowDoesNotDiluteNav() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(bob);
        vault.deposit(1000 * ONE_USDC, bob);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(100 * ONE_USDC));

        uint256 navPerShare = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertApproxEqRel(navPerShare, 1.1e12, 0.001e18);
    }

    function test_claimWithdrawal_revertsIfNotSettled() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;

        vm.prank(alice);
        vm.expectRevert(AtomaVault.EpochNotSettled.selector);
        vault.claimWithdrawal(settlementEpoch);
    }

    function test_claimWithdrawal_revertsIfNothingToClaim() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        vm.prank(bob);
        vm.expectRevert(AtomaVault.NothingToClaim.selector);
        vault.claimWithdrawal(settlementEpoch);
    }

    function test_claimWithdrawal_revertsIfInsufficientIdle() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + vault.CAPITAL_WHITELIST_DELAY());
        vm.prank(operatorAddr);
        vault.capitalWithdraw(operatorAddr, 1000 * ONE_USDC);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.InsufficientIdle.selector);
        vault.claimWithdrawal(settlementEpoch);
    }

    // ──────────── Update Total Assets + Fees ────────────

    function test_updateTotalAssets_appliesDelta() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(100 * ONE_USDC));

        assertEq(vault.totalAssets(), 900 * ONE_USDC);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(50 * ONE_USDC));

        assertEq(vault.totalAssets(), 950 * ONE_USDC);
    }

    function test_updateTotalAssets_doesNotMintFee() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        uint256 opSharesBefore = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        assertEq(vault.balanceOf(operatorAddr), opSharesBefore);
    }

    function test_updateTotalAssets_revertsDeltaTooLarge() public {
        vm.prank(operatorAddr);
        vault.setUpdateBounds(100, 0);

        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.UpdateDeltaTooLarge.selector);
        vault.updateTotalAssets(int256(11 * ONE_USDC));

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(10 * ONE_USDC));
    }

    function test_updateTotalAssets_revertsTooFrequent() public {
        vm.warp(block.timestamp + 1 days);

        vm.prank(operatorAddr);
        vault.setUpdateBounds(10000, 30 minutes);

        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(10 * ONE_USDC));

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.UpdateTooFrequent.selector);
        vault.updateTotalAssets(int256(10 * ONE_USDC));

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(10 * ONE_USDC));
    }

    function test_updateTotalAssets_revertsIfNotOperator() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.NotOperator.selector);
        vault.updateTotalAssets(int256(100 * ONE_USDC));
    }

    function test_resyncTotalAssets_ownerSetsAbsoluteTotal() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.startPrank(operatorAddr);
        vault.pause();
        vault.resyncTotalAssets(5000 * ONE_USDC);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 5000 * ONE_USDC);
    }

    function test_resyncTotalAssets_revertsIfNotPaused() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vm.expectRevert();
        vault.resyncTotalAssets(5000 * ONE_USDC);
    }

    function test_resyncTotalAssets_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.resyncTotalAssets(5000 * ONE_USDC);
    }

    // ──────────── Fee Crystallization ────────────

    function test_crystallize_noFeeIfBelowHwm() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(100 * ONE_USDC));

        uint256 opSharesBefore = vault.balanceOf(operatorAddr);
        _crystallize();

        assertEq(vault.balanceOf(operatorAddr), opSharesBefore);
    }

    function test_crystallize_noFeeIfEqualHwm() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 opSharesBefore = vault.balanceOf(operatorAddr);
        _crystallize();

        assertEq(vault.balanceOf(operatorAddr), opSharesBefore);
    }

    function test_crystallize_mintsFeeSharesAboveHwm() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        _crystallize();

        uint256 opShares = vault.balanceOf(operatorAddr);
        assertGt(opShares, 0);

        uint256 opValue = opShares * vault.totalAssets() / vault.totalSupply();
        uint256 expectedFee = 1000 * ONE_USDC * 2000 / 10000;
        assertApproxEqRel(opValue, expectedFee, 0.01e18);
    }

    function test_crystallize_updatesHwm() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 hwmBefore = vault.highWaterMark();

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(100 * ONE_USDC));

        _crystallize();

        assertGt(vault.highWaterMark(), hwmBefore);
    }

    function test_crystallize_noFeeAfterLoss() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(100 * ONE_USDC));

        _crystallize();
        uint256 hwmAfterProfit = vault.highWaterMark();
        uint256 opSharesAfterProfit = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(50 * ONE_USDC));

        _crystallize();

        assertEq(vault.highWaterMark(), hwmAfterProfit);
        assertEq(vault.balanceOf(operatorAddr), opSharesAfterProfit);
    }

    function test_deposit_accruesFeeBeforeMint() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        uint256 hwmBefore = vault.highWaterMark();
        vm.prank(bob);
        vault.deposit(10000 * ONE_USDC, bob);

        uint256 opShares = vault.balanceOf(operatorAddr);
        assertGt(opShares, 0);
        assertGt(vault.highWaterMark(), hwmBefore);

        uint256 opValue = opShares * vault.totalAssets() / vault.totalSupply();
        uint256 expectedFee = 1000 * ONE_USDC * 2000 / 10000;
        assertApproxEqRel(opValue, expectedFee, 0.01e18);
    }

    function test_deposit_midPeriodDepositorUnaffectedByCrystallization() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        vm.prank(bob);
        uint256 bobShares = vault.deposit(10000 * ONE_USDC, bob);

        _crystallize();

        uint256 bobValue = bobShares * vault.totalAssets() / vault.totalSupply();
        assertApproxEqRel(bobValue, 10000 * ONE_USDC, 0.0001e18);
    }

    function test_deposit_noAccrualAtOrBelowHwm() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));
        _crystallize();
        uint256 opShares = vault.balanceOf(operatorAddr);
        uint256 hwm = vault.highWaterMark();

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(500 * ONE_USDC));

        vm.prank(bob);
        vault.deposit(10000 * ONE_USDC, bob);

        assertEq(vault.balanceOf(operatorAddr), opShares);
        assertEq(vault.highWaterMark(), hwm);
    }

    function test_crystallize_nothingLeftAfterDepositAccrual() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        vm.prank(bob);
        vault.deposit(10000 * ONE_USDC, bob);
        uint256 opShares = vault.balanceOf(operatorAddr);

        _crystallize();

        assertEq(vault.balanceOf(operatorAddr), opShares);
    }

    function test_crystallize_revertsBeforePeriod() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + vault.FEE_CRYSTALLIZATION_PERIOD() - 1);
        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.CrystallizationNotDue.selector);
        vault.crystallizePerformanceFee();
    }

    function test_settleEpoch_chargesExitFeeAboveHwm() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        uint256 hwmBefore = vault.highWaterMark();
        uint256 crystallizedBefore = vault.lastCrystallizedAt();

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        assertGt(vault.balanceOf(operatorAddr), 0);
        assertEq(vault.highWaterMark(), hwmBefore);
        assertEq(vault.lastCrystallizedAt(), crystallizedBefore);

        (, uint256 nav,) = vault.getEpoch(settlementEpoch);
        assertApproxEqRel(nav, 1.08e12, 0.001e18);
    }

    function test_settleEpoch_exitFeeDoesNotChangeRemainingNav() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(bob);
        vault.deposit(10000 * ONE_USDC, bob);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(2000 * ONE_USDC));

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        uint256 navPerShare = vault.totalAssets() * 1e18 / vault.totalSupply();
        assertApproxEqRel(navPerShare, 1.1e12, 0.001e18);
    }

    function test_updateTotalAssets_haircutsClaimsBelowLiabilities() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000 * ONE_USDC, alice);
        vm.prank(bob);
        vault.deposit(1000 * ONE_USDC, bob);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);
        assertEq(vault.settledUnclaimedAssets(), 1000 * ONE_USDC);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(1200 * ONE_USDC));

        assertEq(vault.settledUnclaimedAssets(), 800 * ONE_USDC);
        assertEq(vault.shortfallIndexWad(), 8e17);
        assertEq(vault.totalAssets(), 0, "equity absorbs the loss before claimants");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);

        assertEq(usdc.balanceOf(alice) - balBefore, 796 * ONE_USDC);
        assertEq(vault.settledUnclaimedAssets(), 0);
    }

    function test_haircut_sparesEpochsSettledAfterwards() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000 * ONE_USDC, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1000 * ONE_USDC, bob);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);
        uint256 aliceEpoch = vault.getCurrentEpoch() + 1;

        vm.warp(block.timestamp + EPOCH_DURATION * 2);
        vm.prank(operatorAddr);
        vault.settleEpoch(aliceEpoch);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(1200 * ONE_USDC));
        assertEq(vault.shortfallIndexWad(), 8e17);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(800 * ONE_USDC));

        vm.prank(bob);
        vault.requestWithdrawal(bobShares);
        uint256 bobEpoch = vault.getCurrentEpoch() + 1;

        vm.warp(block.timestamp + EPOCH_DURATION * 2);
        vm.prank(operatorAddr);
        vault.settleEpoch(bobEpoch);

        assertEq(vault.epochIndexAtSettle(bobEpoch), 8e17, "new cohort snapshots the current index");
        assertEq(vault.epochIndexAtSettle(aliceEpoch), 1e18);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(aliceEpoch);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 796 * ONE_USDC, "alice eats the shortfall");

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.claimWithdrawal(bobEpoch);
        assertEq(usdc.balanceOf(bob) - bobBefore, 796 * ONE_USDC, "bob priced in after the write-down, no second haircut");

        assertEq(vault.settledUnclaimedAssets(), 0);
    }

    // ──────────── Capital Management (owner only) ────────────

    function test_capitalWithdraw_doesNotChangeTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 totalBefore = vault.totalAssets();

        vm.warp(block.timestamp + vault.CAPITAL_WHITELIST_DELAY());
        vm.prank(operatorAddr);
        vault.capitalWithdraw(operatorAddr, 500 * ONE_USDC);

        assertEq(vault.totalAssets(), totalBefore);
    }

    function test_capitalDeposit_doesNotChangeTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + vault.CAPITAL_WHITELIST_DELAY());
        vm.prank(operatorAddr);
        vault.capitalWithdraw(operatorAddr, 500 * ONE_USDC);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(operatorAddr);
        vault.capitalDeposit(500 * ONE_USDC);

        assertEq(vault.totalAssets(), totalBefore);
    }

    function test_capitalWithdraw_revertsIfNotWhitelisted() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.DestinationNotWhitelisted.selector);
        vault.capitalWithdraw(bob, 500 * ONE_USDC);
    }

    function test_capitalWithdraw_revertsBeforeWhitelistDelay() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.whitelistCapitalDestination(bob);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.DestinationNotWhitelisted.selector);
        vault.capitalWithdraw(bob, 500 * ONE_USDC);

        vm.warp(block.timestamp + vault.CAPITAL_WHITELIST_DELAY());
        vm.prank(operatorAddr);
        vault.capitalWithdraw(bob, 500 * ONE_USDC);
    }

    function test_capitalWithdraw_revertsAfterRevoke() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + vault.CAPITAL_WHITELIST_DELAY());
        vm.prank(operatorAddr);
        vault.revokeCapitalDestination(operatorAddr);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.DestinationNotWhitelisted.selector);
        vault.capitalWithdraw(operatorAddr, 500 * ONE_USDC);
    }

    function test_capitalWithdraw_cannotTakeSettledLiabilities() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.InsufficientIdle.selector);
        vault.capitalWithdraw(operatorAddr, 100 * ONE_USDC);
    }

    function test_capitalWithdraw_revertsIfNotOwner() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.capitalWithdraw(alice, 100 * ONE_USDC);
    }

    function test_capitalDeposit_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.capitalDeposit(100 * ONE_USDC);
    }

    // ──────────── Full Flow ────────────

    function test_fullFlow_depositProfitWithdrawClaim() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(10000 * ONE_USDC, bob);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(2000 * ONE_USDC));

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;

        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBefore;

        assertGt(aliceReceived, 10000 * ONE_USDC * 9950 / 10000);

        assertGt(vault.balanceOf(bob), 0);
        assertGt(vault.balanceOf(operatorAddr), 0);
    }

    function test_fullFlow_multipleUsersWithdrawSameEpoch() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(5000 * ONE_USDC, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(5000 * ONE_USDC, bob);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);

        vm.prank(bob);
        vault.requestWithdrawal(bobShares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.claimWithdrawal(settlementEpoch);

        uint256 aliceReceived = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobReceived = usdc.balanceOf(bob) - bobBefore;
        assertEq(aliceReceived, bobReceived);
    }

    // ──────────── Epoch Views ────────────

    function test_getCurrentEpoch_incrementsOverTime() public view {
        assertEq(vault.getCurrentEpoch(), 0);
    }

    function test_getCurrentEpoch_afterOneHour() public {
        vm.warp(block.timestamp + 1 hours);
        assertEq(vault.getCurrentEpoch(), 1);
    }

    function test_getEpochEndTime() public view {
        uint256 end0 = vault.getEpochEndTime(0);
        assertEq(end0, vault.genesisTimestamp() + 1 hours);
    }

    // ──────────── Pause ────────────

    function test_pause_blocksDeposit() public {
        vm.prank(operatorAddr);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1000 * ONE_USDC, alice);
    }

    function test_unpause_allowsDeposit() public {
        vm.prank(operatorAddr);
        vault.pause();

        vm.prank(operatorAddr);
        vault.unpause();

        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);
    }

    function test_unpause_revertsIfNotOwner() public {
        address newOp = makeAddr("newOp");
        vm.prank(operatorAddr);
        vault.setOperator(newOp);

        vm.prank(newOp);
        vault.pause();

        vm.prank(newOp);
        vm.expectRevert();
        vault.unpause();
    }

    // ──────────── Access Control ────────────

    function test_setOperator() public {
        address newOp = makeAddr("newOperator");

        vm.prank(operatorAddr);
        vault.setOperator(newOp);

        assertEq(vault.operator(), newOp);
    }

    function test_setOperator_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setOperator(alice);
    }

    // ──────────── HWM + Fee Correctness ────────────

    function test_hwm_initializedCorrectly() public view {
        uint256 expectedHwm = 1e18 / (10 ** 6);
        assertEq(vault.highWaterMark(), expectedHwm);
    }

    function test_hwm_feesChargedOnFirstProfit() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        uint256 opSharesBefore = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        _crystallize();

        assertGt(vault.balanceOf(operatorAddr), opSharesBefore);
    }

    function test_hwm_noFeeOnLossRecovery() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        _crystallize();

        uint256 hwmAfterProfit = vault.highWaterMark();
        uint256 opSharesAfterProfit = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(-int256(500 * ONE_USDC));

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(300 * ONE_USDC));

        _crystallize();

        assertEq(vault.highWaterMark(), hwmAfterProfit);
        assertEq(vault.balanceOf(operatorAddr), opSharesAfterProfit);
    }

    function test_hwm_depositDoesNotTriggerFees() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        _crystallize();

        uint256 opSharesAfterFee = vault.balanceOf(operatorAddr);
        uint256 hwmAfterFee = vault.highWaterMark();

        vm.prank(bob);
        vault.deposit(5000 * ONE_USDC, bob);

        assertEq(vault.balanceOf(operatorAddr), opSharesAfterFee);

        _crystallize();

        assertEq(vault.highWaterMark(), hwmAfterFee);
        assertEq(vault.balanceOf(operatorAddr), opSharesAfterFee);
    }

    function test_hwm_feeOnlyOnNewProfit() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        _crystallize();

        uint256 opSharesFirst = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(int256(1000 * ONE_USDC));

        _crystallize();

        assertGt(vault.balanceOf(operatorAddr), opSharesFirst);
    }

    // ──────────── Deposit Cap ────────────

    function test_depositCap_noCapByDefault() public {
        assertEq(vault.maxTotalAssets(), 0);

        vm.prank(alice);
        vault.deposit(100000 * ONE_USDC, alice);
    }

    function test_depositCap_setByOwner() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(50000 * ONE_USDC);

        assertEq(vault.maxTotalAssets(), 50000 * ONE_USDC);
    }

    function test_depositCap_revertsOnExceed() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(50000 * ONE_USDC);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.DepositCapExceeded.selector);
        vault.deposit(50001 * ONE_USDC, alice);
    }

    function test_depositCap_allowsExactCap() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(50000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(50000 * ONE_USDC, alice);
    }

    function test_depositCap_multipleDepositsRespectCap() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(50000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(30000 * ONE_USDC, alice);

        vm.prank(bob);
        vm.expectRevert(AtomaVault.DepositCapExceeded.selector);
        vault.deposit(25000 * ONE_USDC, bob);
    }

    function test_depositCap_zeroDisablesCap() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(10000 * ONE_USDC);

        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(0);

        vm.prank(alice);
        vault.deposit(100000 * ONE_USDC, alice);
    }

    function test_depositCap_onlyOwnerCanSet() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMaxTotalAssets(50000 * ONE_USDC);
    }

    // ──────────── Minimum Deposit ────────────

    function test_minDeposit_revertsBelow() public {
        vm.prank(alice);
        vm.expectRevert(AtomaVault.BelowMinDeposit.selector);
        vault.deposit(99 * ONE_USDC, alice);
    }

    function test_minDeposit_allowsExactMinimum() public {
        vm.prank(alice);
        vault.deposit(MIN_DEPOSIT, alice);
    }

    function test_minDeposit_allowsAboveMinimum() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);
    }

    // ──────────── Inflation Attack Protection ────────────

    function test_inflationAttack_mitigatedByDecimalOffset() public {
        vm.prank(alice);
        vault.deposit(MIN_DEPOSIT, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(bob);
        vault.deposit(MIN_DEPOSIT, bob);

        uint256 bobShares = vault.balanceOf(bob);
        assertApproxEqRel(aliceShares, bobShares, 0.001e18);
    }

    function test_firstDepositor_getsCorrectShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        assertGt(shares, 0);

        uint256 valueBack = shares * vault.totalAssets() / vault.totalSupply();
        assertApproxEqAbs(valueBack, 1000 * ONE_USDC, 1);
    }

    // ──────────── Deposit Epoch Lock ────────────

    function test_depositOnBehalf_doesNotRelockExistingReceiver() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(bob);
        vault.deposit(MIN_DEPOSIT, alice);

        uint256 total = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AtomaVault.DepositLocked.selector);
        vault.requestWithdrawal(total);

        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);
    }

    function test_depositOnBehalf_doesNotLockSender() public {
        vm.prank(bob);
        vault.deposit(1000 * ONE_USDC, bob);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(bob);
        vault.deposit(MIN_DEPOSIT, alice);

        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestWithdrawal(bobShares);
    }

    function test_depositLockBypass_viaReceiver_prevented() public {
        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, bob);

        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(AtomaVault.DepositLocked.selector);
        vault.requestWithdrawal(bobShares);
    }

    // ──────────── ERC4626 Max Functions ────────────

    function test_maxDeposit_returnsMaxWhenNoCap() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_maxDeposit_respectsCap() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(50000 * ONE_USDC);

        assertEq(vault.maxDeposit(alice), 50000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(30000 * ONE_USDC, alice);

        assertEq(vault.maxDeposit(bob), 20000 * ONE_USDC);
    }

    function test_maxDeposit_returnsZeroWhenPaused() public {
        vm.prank(operatorAddr);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_returnsZeroWhenFull() public {
        vm.prank(operatorAddr);
        vault.setMaxTotalAssets(1000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        assertEq(vault.maxDeposit(bob), 0);
    }

    function test_maxWithdraw_alwaysZero() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_alwaysZero() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        assertEq(vault.maxRedeem(alice), 0);
    }

    // ──────────── Admin Safety ────────────

    function test_setOperator_revertsOnZeroAddress() public {
        vm.prank(operatorAddr);
        vm.expectRevert(AtomaVault.ZeroAddress.selector);
        vault.setOperator(address(0));
    }

    function test_setMaxTotalAssets_emitsEvent() public {
        vm.prank(operatorAddr);
        vm.expectEmit();
        emit AtomaVault.MaxTotalAssetsUpdated(50000 * ONE_USDC);
        vault.setMaxTotalAssets(50000 * ONE_USDC);
    }

    // ──────────── Transfer Disabled ────────────

    function test_transfer_reverts() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.TransferDisabled.selector);
        vault.transfer(bob, 1);
    }

    function test_transferFrom_reverts() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(AtomaVault.TransferDisabled.selector);
        vault.transferFrom(alice, bob, 1);
    }

    function test_epochLockBypass_prevented() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AtomaVault.TransferDisabled.selector);
        vault.transfer(bob, aliceShares);
    }

    function test_transfer_toVaultReverts() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);
        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.TransferDisabled.selector);
        vault.transfer(address(vault), shares);
    }

    // ──────────── Deposit Lock ────────────

    function test_deposit_topUpDoesNotRelockExistingShares() public {
        vm.prank(alice);
        uint256 oldShares = vault.deposit(50_000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        vault.deposit(100 * ONE_USDC, alice);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.prank(alice);
        vault.requestWithdrawal(oldShares);

        assertEq(vault.userEpochShares(settlementEpoch, alice), oldShares);
    }
}
