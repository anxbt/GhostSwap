// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";

import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {IPostSettleReveal} from "../src/interface/IPostSettleReveal.sol";

contract PostSettleRevealHookHarness is PostSettleRevealHook {
    
    //Wraps real hook with exposed internals for direct unit testing.

    constructor(IPoolManager manager, uint256 revealDelay, address _owner)
        PostSettleRevealHook(manager, revealDelay, _owner)
    {}

    function exposedBeforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    function exposedAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }
}

contract PostSettleRevealHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant REVEAL_DELAY = 11;

    event IntentCaptured(
        uint256 indexed swapId,
        address indexed trader,
        bytes32 indexed poolId,
        uint256 nonce,
        uint256 createdAtBlock
    );

    event SettlementRecorded(
        uint256 indexed swapId,
        address indexed trader,
        int128 delta0,
        int128 delta1,
        int256 amountSpecified,
        uint256 settledAtBlock
    );

    event RevealReady(uint256 indexed swapId, address indexed trader, uint256 decryptReadyBlock);

    event Revealed(
        uint256 indexed swapId,
        address indexed caller,
        address indexed trader,
        int128 delta0,
        int128 delta1,
        int256 amountSpecified,
        uint256 settledAtBlock
    );

    CoFheTest internal cft;
    PostSettleRevealHookHarness internal hook;

    address internal trader = makeAddr("trader");
    address internal unauthorized = makeAddr("unauthorized");
    address internal compliance = makeAddr("compliance");

    function setUp() public {
        cft = new CoFheTest(false);

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144)
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(address(this)), REVEAL_DELAY, address(this));
        deployCodeTo("PostSettleRevealHook.t.sol:PostSettleRevealHookHarness", constructorArgs, flags);
        hook = PostSettleRevealHookHarness(flags);
    }

    function testWave1HappyPath() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(1e6, 1, trader);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IntentCaptured(1, trader, poolId, 1, block.number);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        (, , , , IPostSettleReveal.SwapState stateAfterBefore) = hook.getSwapIntent(1);
        assertEq(uint256(stateAfterBefore), uint256(IPostSettleReveal.SwapState.IntentCaptured));

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);

        vm.expectEmit(true, true, false, true, address(hook));
        emit SettlementRecorded(1, trader, -1e6, 9e5, -1e6, block.number);

        vm.expectEmit(true, true, false, true, address(hook));
        emit RevealReady(1, trader, block.number + REVEAL_DELAY);

        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));

        (, , , , uint256 settledAtBlock, uint256 readyBlock) = hook.getSettlementRecord(1);
        assertEq(readyBlock, settledAtBlock + REVEAL_DELAY);

        vm.expectRevert(abi.encodeWithSignature("RevealNotReady(uint256,uint256,uint256)", 1, readyBlock, block.number));
        vm.prank(trader);
        hook.revealSwapDetails(1);

        vm.roll(readyBlock);

        vm.expectEmit(true, true, true, true, address(hook));
        emit Revealed(1, trader, trader, -1e6, 9e5, -1e6, settledAtBlock);

        vm.prank(trader);
        hook.revealSwapDetails(1);

        (, , , , IPostSettleReveal.SwapState finalState) = hook.getSwapIntent(1);
        assertEq(uint256(finalState), uint256(IPostSettleReveal.SwapState.RevealedToAuthorized));
    }

    function testNonceReplayRejected() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();

        bytes memory hookData = _buildHookData(1e6, 77, trader);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));

        vm.expectRevert(abi.encodeWithSignature("NonceUsed(address,uint256)", trader, 77));
        hook.exposedBeforeSwap(trader, key, params, hookData);
    }

    function testUnauthorizedRevealRejected() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();

        bytes memory hookData = _buildHookData(1e6, 9, trader);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));

        (, , , , uint256 settledAtBlock, ) = hook.getSettlementRecord(1);
        vm.roll(settledAtBlock + REVEAL_DELAY);

        vm.expectRevert(abi.encodeWithSignature("Unauthorized(address)", unauthorized));
        vm.prank(unauthorized);
        hook.revealSwapDetails(1);
    }

    function testWhitelistedRevealAndDoubleRevealRejected() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();

        bytes memory hookData = _buildHookData(1e6, 14, trader);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));

        hook.setAuthorizedRevealer(compliance, true);

        (, , , , uint256 settledAtBlock, ) = hook.getSettlementRecord(1);
        vm.roll(settledAtBlock + REVEAL_DELAY);

        vm.prank(compliance);
        hook.revealSwapDetails(1);

        vm.expectRevert(abi.encodeWithSignature("AlreadyRevealed(uint256)", 1));
        vm.prank(compliance);
        hook.revealSwapDetails(1);
    }

    function testAfterSwapWithoutIntentFails() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.MissingIntent.selector, trader));
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});
    }

    // Keep this helper in one place so tests and frontend can mirror the exact hookData tuple shape.
    function _buildHookData(uint128 minOutPlaintext, uint256 nonce, address signer) internal returns (bytes memory) {
        InEuint128 memory minOut = cft.createInEuint128(minOutPlaintext, signer);
        return abi.encode(minOut, nonce);
    }
}
