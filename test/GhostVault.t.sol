// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GhostVault} from "../src/GhostVault.sol";

contract GhostVaultTest is Test {
    MockERC20 internal asset;
    GhostVault internal vault;

    address internal hook = makeAddr("hook");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        asset = new MockERC20("Vault Asset", "VAST", 18);
        vault = new GhostVault(address(asset), hook);

        asset.mint(alice, 1_000e18);
        asset.mint(bob, 1_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    function testDepositWithdrawAndSurplusAttribution() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(100e18, alice);
        assertEq(aliceShares, 100e18);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(100e18, bob);
        assertEq(bobShares, 100e18);

        assertEq(vault.totalShares(), 200e18);
        assertEq(vault.totalAssets(), 200e18);

        // Surplus sits in vault balance after swap settlement; recordSurplus only attributes accounting data.
        asset.mint(address(vault), 20e18);

        vm.prank(hook);
        vault.recordSurplus(1, 20e18, address(vault));

        assertEq(vault.totalSurplusCaptured(), 20e18);
        assertEq(vault.totalManagedAssets(), 200e18);
        assertEq(vault.surplusAttributionOf(alice), 10e18);
        assertEq(vault.surplusAttributionOf(bob), 10e18);
        assertEq(vault.claimableSurplusOf(alice), 10e18);
        assertEq(vault.claimableSurplusOf(bob), 10e18);

        vm.prank(alice);
        uint256 claimed = vault.claimSurplus(alice);

        assertEq(claimed, 10e18);
        assertEq(vault.totalSurplusClaimed(), 10e18);
        assertEq(vault.claimableSurplusOf(alice), 0);

        vm.prank(alice);
        uint256 assetsOut = vault.withdraw(100e18, alice, alice);

        assertEq(assetsOut, 100e18);
        assertEq(vault.totalShares(), 100e18);
        assertEq(asset.balanceOf(alice), 1_010e18);
    }

    function testWithdrawThenClaimDoesNotDoubleCountSurplus() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(bob);
        vault.deposit(100e18, bob);

        asset.mint(address(vault), 20e18);

        vm.prank(hook);
        vault.recordSurplus(1, 20e18, address(vault));

        vm.prank(alice);
        uint256 withdrawn = vault.withdraw(100e18, alice, alice);
        assertEq(withdrawn, 100e18);

        assertEq(vault.claimableSurplusOf(alice), 10e18);

        vm.prank(alice);
        uint256 claimed = vault.claimSurplus(alice);
        assertEq(claimed, 10e18);
        assertEq(asset.balanceOf(alice), 1_010e18);
    }

    function testRecordSurplusOnlyHook() public {
        vm.expectRevert(abi.encodeWithSignature("Unauthorized(address)", alice));
        vm.prank(alice);
        vault.recordSurplus(1, 1e18, address(vault));
    }

    function testRecordSurplusRejectsNonVaultTrader() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidTrader(address)", alice));
        vm.prank(hook);
        vault.recordSurplus(1, 1e18, alice);
    }

    function testRecordSurplusRequiresSharesOutstanding() public {
        asset.mint(address(vault), 1e18);

        vm.expectRevert(abi.encodeWithSignature("NoSharesOutstanding()"));
        vm.prank(hook);
        vault.recordSurplus(1, 1e18, address(vault));
    }
}
