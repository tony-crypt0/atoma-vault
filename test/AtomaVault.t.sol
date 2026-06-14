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
            abi.encodeCall(AtomaVault.initialize, (IERC20(address(usdc)), operatorAddr, operatorAddr))
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
        vault.updateTotalAssets(1100 * ONE_USDC);

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

    function test_requestWithdrawal_revertsWhenPaused() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(operatorAddr);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.requestWithdrawal(shares);
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

    function test_claimWithdrawal_burnShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(alice);
        vault.requestWithdrawal(shares);

        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;
        vm.warp(block.timestamp + EPOCH_DURATION * 2);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        uint256 supplyBefore = vault.totalSupply();
        vm.prank(alice);
        vault.claimWithdrawal(settlementEpoch);

        assertEq(vault.totalSupply(), supplyBefore - shares);
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

    function test_updateTotalAssets_noFeeIfBelowHwm() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 opSharesBefore = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(900 * ONE_USDC);

        assertEq(vault.balanceOf(operatorAddr), opSharesBefore);
        assertEq(vault.totalAssets(), 900 * ONE_USDC);
    }

    function test_updateTotalAssets_noFeeIfEqualHwm() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 opSharesBefore = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(1000 * ONE_USDC);

        assertEq(vault.balanceOf(operatorAddr), opSharesBefore);
    }

    function test_updateTotalAssets_mintsFeeSharesAboveHwm() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(11000 * ONE_USDC);

        uint256 opShares = vault.balanceOf(operatorAddr);
        assertGt(opShares, 0);

        uint256 opValue = opShares * vault.totalAssets() / vault.totalSupply();
        uint256 expectedFee = 1000 * ONE_USDC * 2000 / 10000;
        assertApproxEqRel(opValue, expectedFee, 0.01e18);
    }

    function test_updateTotalAssets_updatesHwm() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 hwmBefore = vault.highWaterMark();

        vm.prank(operatorAddr);
        vault.updateTotalAssets(1100 * ONE_USDC);

        assertGt(vault.highWaterMark(), hwmBefore);
    }

    function test_updateTotalAssets_noFeeAfterLoss() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(1100 * ONE_USDC);

        uint256 hwmAfterProfit = vault.highWaterMark();

        vm.prank(operatorAddr);
        vault.updateTotalAssets(1050 * ONE_USDC);

        assertEq(vault.highWaterMark(), hwmAfterProfit);
    }

    function test_updateTotalAssets_revertsIfNotOperator() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(alice);
        vm.expectRevert(AtomaVault.NotOperator.selector);
        vault.updateTotalAssets(1100 * ONE_USDC);
    }

    // ──────────── Capital Management (owner only) ────────────

    function test_capitalWithdraw_doesNotChangeTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(operatorAddr);
        vault.capitalWithdraw(operatorAddr, 500 * ONE_USDC);

        assertEq(vault.totalAssets(), totalBefore);
    }

    function test_capitalDeposit_doesNotChangeTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.capitalWithdraw(operatorAddr, 500 * ONE_USDC);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(operatorAddr);
        vault.capitalDeposit(500 * ONE_USDC);

        assertEq(vault.totalAssets(), totalBefore);
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
        vault.updateTotalAssets(22000 * ONE_USDC);

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

    function test_getCurrentEpoch_afterOneWeek() public {
        vm.warp(block.timestamp + EPOCH_DURATION);
        assertEq(vault.getCurrentEpoch(), 1);
    }

    function test_getEpochEndTime() public view {
        uint256 end0 = vault.getEpochEndTime(0);
        assertEq(end0, vault.genesisTimestamp() + EPOCH_DURATION);
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
        vault.updateTotalAssets(11000 * ONE_USDC);

        assertGt(vault.balanceOf(operatorAddr), opSharesBefore);
    }

    function test_hwm_feeAmountIsCorrect() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(11000 * ONE_USDC);

        uint256 opShares = vault.balanceOf(operatorAddr);
        uint256 opValue = opShares * vault.totalAssets() / vault.totalSupply();
        uint256 expectedFee = 1000 * ONE_USDC * 2000 / 10000;
        assertApproxEqRel(opValue, expectedFee, 0.01e18);
    }

    function test_hwm_noFeeOnLossRecovery() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(11000 * ONE_USDC);

        uint256 hwmAfterProfit = vault.highWaterMark();
        uint256 opSharesAfterProfit = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(10500 * ONE_USDC);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(10800 * ONE_USDC);

        assertEq(vault.highWaterMark(), hwmAfterProfit);
        assertEq(vault.balanceOf(operatorAddr), opSharesAfterProfit);
    }

    function test_hwm_depositDoesNotTriggerFees() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(11000 * ONE_USDC);

        uint256 opSharesAfterFee = vault.balanceOf(operatorAddr);
        uint256 hwmAfterFee = vault.highWaterMark();

        vm.prank(bob);
        vault.deposit(5000 * ONE_USDC, bob);

        assertEq(vault.balanceOf(operatorAddr), opSharesAfterFee);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(16000 * ONE_USDC);

        assertEq(vault.highWaterMark(), hwmAfterFee);
        assertEq(vault.balanceOf(operatorAddr), opSharesAfterFee);
    }

    function test_hwm_feeOnlyOnNewProfit() public {
        vm.prank(alice);
        vault.deposit(10000 * ONE_USDC, alice);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(11000 * ONE_USDC);

        uint256 opSharesFirst = vault.balanceOf(operatorAddr);

        vm.prank(operatorAddr);
        vault.updateTotalAssets(12000 * ONE_USDC);

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

    // ──────────── Deposit Epoch Griefing Protection ────────────

    function test_depositOnBehalf_doesNotLockReceiver() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(bob);
        vault.deposit(MIN_DEPOSIT, alice);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);
    }

    function test_depositOnBehalf_locksSender() public {
        vm.prank(bob);
        vault.deposit(MIN_DEPOSIT, alice);

        vm.prank(bob);
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
}
