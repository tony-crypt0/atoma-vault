// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AtomaVault.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract AtomaVaultUpgradeV2Test is Test {
    AtomaVault public vault;
    MockUSDC2 public usdc;

    address operatorAddr = makeAddr("operator");
    address ownerAddr = makeAddr("owner");
    address alice = makeAddr("alice");

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC2();
        AtomaVault impl = new AtomaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AtomaVault.initialize, (IERC20(address(usdc)), ownerAddr, operatorAddr))
        );
        vault = AtomaVault(address(proxy));

        usdc.mint(alice, 1_000_000 * ONE_USDC);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_initialState_oneHourSchedule() public view {
        assertEq(vault.epochDuration(), 1 hours);
        assertEq(vault.scheduleCount(), 1);
        assertEq(vault.getCurrentEpoch(), 0);
    }

    function test_setEpochDuration_revertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setEpochDuration(7 days);
    }

    function test_setEpochDuration_revertsBelowMin() public {
        vm.prank(ownerAddr);
        vm.expectRevert(AtomaVault.EpochDurationOutOfBounds.selector);
        vault.setEpochDuration(30 minutes);
    }

    function test_setEpochDuration_revertsAboveMax() public {
        vm.prank(ownerAddr);
        vm.expectRevert(AtomaVault.EpochDurationOutOfBounds.selector);
        vault.setEpochDuration(31 days);
    }

    function test_setEpochDuration_takesEffectAtNextBoundary() public {
        vm.warp(block.timestamp + 30 minutes);
        uint256 beforeEpoch = vault.getCurrentEpoch();
        assertEq(beforeEpoch, 0);
        assertEq(vault.epochDuration(), 1 hours);

        vm.prank(ownerAddr);
        vault.setEpochDuration(7 days);

        assertEq(vault.epochDuration(), 1 hours, "duration should not change before boundary");
        assertEq(vault.getCurrentEpoch(), 0, "epoch should not change before boundary");

        vm.warp(block.timestamp + 31 minutes);
        assertEq(vault.epochDuration(), 7 days, "duration should change after boundary");
        assertEq(vault.getCurrentEpoch(), 1, "epoch should be 1 right after boundary");

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.getCurrentEpoch(), 2, "epoch should increment at 7d cadence now");
    }

    function test_setEpochDuration_overwritesPendingIfStillFuture() public {
        vm.prank(ownerAddr);
        vault.setEpochDuration(7 days);
        assertEq(vault.scheduleCount(), 2);

        vm.prank(ownerAddr);
        vault.setEpochDuration(2 days);
        assertEq(vault.scheduleCount(), 2, "second pending should overwrite first, not append");

        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(vault.epochDuration(), 2 days);
    }

    function test_oldEpochStillSettlesAfterDurationChange() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);
        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;

        vm.warp(block.timestamp + 2 hours);
        assertGt(vault.getCurrentEpoch(), settlementEpoch, "epoch ended under old 1h schedule");

        vm.prank(ownerAddr);
        vault.setEpochDuration(7 days);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);

        (, , bool settled) = vault.getEpoch(settlementEpoch);
        assertTrue(settled, "epoch settled under old schedule even after duration change");
    }

    function test_requestStretchedIfBucketsIntoNewSchedule_M2() public {
        vm.prank(alice);
        vault.deposit(1000 * ONE_USDC, alice);

        vm.warp(block.timestamp + 2 hours);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdrawal(aliceShares);
        uint256 settlementEpoch = vault.getCurrentEpoch() + 1;

        vm.prank(ownerAddr);
        vault.setEpochDuration(7 days);

        vm.warp(block.timestamp + 2 hours);
        assertEq(vault.getCurrentEpoch(), settlementEpoch, "request now stretched: still in settlement epoch under new 7d schedule");

        vm.warp(block.timestamp + 7 days);
        assertGt(vault.getCurrentEpoch(), settlementEpoch);

        vm.prank(operatorAddr);
        vault.settleEpoch(settlementEpoch);
        (, , bool settled) = vault.getEpoch(settlementEpoch);
        assertTrue(settled);
    }

    function test_historicalEpochEndTime_preservedAcrossMultipleChanges() public {
        uint256 originalEpoch1End = vault.getEpochEndTime(1);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(ownerAddr);
        vault.setEpochDuration(7 days);

        vm.warp(block.timestamp + 1 days);

        assertEq(
            vault.getEpochEndTime(1),
            originalEpoch1End,
            "first change: epoch under old schedule preserved"
        );

        vm.prank(ownerAddr);
        vault.setEpochDuration(2 days);

        vm.warp(block.timestamp + 14 days);

        assertEq(
            vault.getEpochEndTime(1),
            originalEpoch1End,
            "second change: epoch under original schedule STILL preserved (catches H-1)"
        );
    }
}
