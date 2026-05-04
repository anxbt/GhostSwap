// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GhostVault} from "../src/GhostVault.sol";
import {GhostVaultPeriphery} from "../src/periphery/GhostVaultPeriphery.sol";

contract MockSwapRouter {
    error ForcedRevert();

    uint256 public callCount;
    bytes public lastPayload;
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function swap(bytes calldata payload) external payable returns (bytes32 result) {
        if (shouldRevert) revert ForcedRevert();

        callCount += 1;
        lastPayload = payload;
        result = keccak256(payload);
    }
}

contract GhostVaultPeripheryTest is Test {
    MockERC20 internal asset;
    GhostVault internal vault;
    MockSwapRouter internal router;
    GhostVaultPeriphery internal periphery;

    address internal hook = makeAddr("hook");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal alice = makeAddr("alice");

    function setUp() public {
        asset = new MockERC20("Vault Asset", "VAST", 18);
        vault = new GhostVault(address(asset), hook);
        router = new MockSwapRouter();
        periphery = new GhostVaultPeriphery(address(router), address(vault), address(this));

        vault.setOperator(vaultOperator);
    }

    function testQueueAndExecuteIntentByVaultOperator() public {
        bytes memory routerCallData = abi.encodeWithSelector(MockSwapRouter.swap.selector, bytes("intent-1"));

        vm.prank(vaultOperator);
        uint256 intentId = periphery.queueIntent(routerCallData, block.number + 2, block.timestamp + 1 hours);
        assertEq(intentId, 1);

        vm.expectRevert(
            abi.encodeWithSignature("IntentTooEarly(uint256,uint256,uint256)", intentId, block.number + 2, block.number)
        );
        vm.prank(vaultOperator);
        periphery.executeIntent(intentId);

        vm.roll(block.number + 2);

        vm.prank(vaultOperator);
        bytes memory rawResult = periphery.executeIntent(intentId);

        assertEq(router.callCount(), 1);
        assertEq(keccak256(router.lastPayload()), keccak256(bytes("intent-1")));
        assertEq(abi.decode(rawResult, (bytes32)), keccak256(bytes("intent-1")));

        GhostVaultPeriphery.QueuedIntent memory intent = periphery.getIntent(intentId);
        assertTrue(intent.executed);
        assertFalse(intent.cancelled);
    }

    function testUnauthorizedCannotQueue() public {
        bytes memory routerCallData = abi.encodeWithSelector(MockSwapRouter.swap.selector, bytes("intent-2"));

        vm.expectRevert(abi.encodeWithSignature("Unauthorized(address)", alice));
        vm.prank(alice);
        periphery.queueIntent(routerCallData, block.number, block.timestamp + 1 hours);
    }

    function testCancelIntentPreventsExecution() public {
        bytes memory routerCallData = abi.encodeWithSelector(MockSwapRouter.swap.selector, bytes("intent-3"));

        uint256 intentId = periphery.queueIntent(routerCallData, block.number, block.timestamp + 1 hours);
        periphery.cancelIntent(intentId);

        vm.expectRevert(abi.encodeWithSignature("IntentAlreadyHandled(uint256)", intentId));
        periphery.executeIntent(intentId);
    }

    function testExpiredIntentReverts() public {
        bytes memory routerCallData = abi.encodeWithSelector(MockSwapRouter.swap.selector, bytes("intent-4"));

        vm.prank(vaultOperator);
        uint256 intentId = periphery.queueIntent(routerCallData, block.number, block.timestamp + 5);

        vm.warp(block.timestamp + 6);

        vm.expectRevert(
            abi.encodeWithSignature("IntentExpired(uint256,uint256,uint256)", intentId, block.timestamp - 1, block.timestamp)
        );
        vm.prank(vaultOperator);
        periphery.executeIntent(intentId);
    }

    function testSweepTokenAndNativeByVaultOperator() public {
        asset.mint(address(periphery), 9e18);
        vm.deal(address(periphery), 2 ether);

        vm.prank(vaultOperator);
        periphery.sweepToken(address(asset), alice, 4e18);
        assertEq(asset.balanceOf(alice), 4e18);

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(vaultOperator);
        periphery.sweepNative(payable(alice), 1 ether);

        assertEq(alice.balance, aliceBalanceBefore + 1 ether);
    }

    function testExecuteIntentBubblesRouterRevert() public {
        bytes memory routerCallData = abi.encodeWithSelector(MockSwapRouter.swap.selector, bytes("intent-5"));

        vm.prank(vaultOperator);
        uint256 intentId = periphery.queueIntent(routerCallData, block.number, block.timestamp + 1 hours);

        router.setShouldRevert(true);

        vm.expectRevert(MockSwapRouter.ForcedRevert.selector);
        vm.prank(vaultOperator);
        periphery.executeIntent(intentId);
    }
}
