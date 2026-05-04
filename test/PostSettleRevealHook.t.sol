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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";

import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {IPostSettleReveal} from "../src/interface/IPostSettleReveal.sol";
import {GhostVault} from "../src/GhostVault.sol";

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
    uint256 internal constant INTENT_DEADLINE_WINDOW = 30 minutes;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant INTENT_AUTHORIZATION_TYPEHASH = keccak256(
        "IntentAuthorization(address trader,address sender,bytes32 poolId,uint256 nonce,uint256 deadline,uint256 ctHash)"
    );

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

    event SolverBidSubmitted(uint256 indexed swapId, address indexed solver, uint256 indexed bidIndex);
    event SolverAuctionQueued(uint256 indexed swapId, uint256 bidCount);
    event SolverAuctionFinalized(
        uint256 indexed swapId,
        address indexed winner,
        uint128 winningBidAmountOut,
        uint256 bidCount
    );

    CoFheTest internal cft;
    PostSettleRevealHookHarness internal hook;
    MockERC20 internal vaultAsset;
    GhostVault internal vaultTrader;

    uint256 internal traderPk = uint256(keccak256("ghostswap-trader"));
    address internal trader;
    address internal unauthorized = makeAddr("unauthorized");
    address internal compliance = makeAddr("compliance");
    address internal solverA = makeAddr("solverA");
    address internal solverB = makeAddr("solverB");
    address internal solverC = makeAddr("solverC");

    function setUp() public {
        cft = new CoFheTest(false);
        trader = vm.addr(traderPk);

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144)
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(address(this)), REVEAL_DELAY, address(this));
        deployCodeTo("PostSettleRevealHook.t.sol:PostSettleRevealHookHarness", constructorArgs, flags);
        hook = PostSettleRevealHookHarness(flags);

        vaultAsset = new MockERC20("Vault Asset", "VAST", 18);
        vaultTrader = new GhostVault(address(vaultAsset), address(hook));
    }

    function testWave1HappyPath() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(9e5, 1, trader, trader, trader, traderPk, poolId);

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
        vm.warp(block.timestamp + 11);

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
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(9e5, 77, trader, trader, trader, traderPk, poolId);

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
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(9e5, 9, trader, trader, trader, traderPk, poolId);

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
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(9e5, 14, trader, trader, trader, traderPk, poolId);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));

        vm.prank(trader);
        hook.setAuthorizedRevealer(compliance, true);

        (, , , , uint256 settledAtBlock, ) = hook.getSettlementRecord(1);
        vm.roll(settledAtBlock + REVEAL_DELAY);
        vm.warp(block.timestamp + 11);

        vm.prank(compliance);
        hook.revealSwapDetails(1);

        vm.expectRevert(abi.encodeWithSignature("AlreadyRevealed(uint256)", 1));
        vm.prank(compliance);
        hook.revealSwapDetails(1);
    }

    function testAfterSwapRevertsWhenFillBelowEncryptedMinimum() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(1e6, 2, trader, trader, trader, traderPk, poolId);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));

        vm.warp(block.timestamp + 11);

        vm.expectRevert(
            abi.encodeWithSelector(IPostSettleReveal.FillBelowEncryptedMinimum.selector, 1, uint128(9e5), uint128(1e6))
        );
        hook.finalizeSlippageCheck(1);
    }

    function testAfterSwapWithoutIntentFails() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.MissingIntent.selector, trader));
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));
    }

    function testInvalidIntentSignatureRejected() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        uint256 wrongSignerPk = uint256(keccak256("wrong-signer"));
        bytes memory hookData = _buildHookData(9e5, 3, trader, trader, trader, wrongSignerPk, poolId);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.InvalidIntentSignature.selector, vm.addr(wrongSignerPk), trader));
        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);
    }

    function testContractTraderIntentAuthorizedByVaultOperator() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        vaultTrader.setOperator(trader);

        bytes memory hookData = _buildHookData(9e5, 41, trader, trader, address(vaultTrader), traderPk, poolId);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        (address intentTrader, , , , IPostSettleReveal.SwapState stateAfterBefore) = hook.getSwapIntent(1);
        assertEq(intentTrader, address(vaultTrader));
        assertEq(uint256(stateAfterBefore), uint256(IPostSettleReveal.SwapState.IntentCaptured));
    }

    function testContractTraderIntentRejectsUnknownSigner() public {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(9e5, 42, trader, trader, address(vaultTrader), traderPk, poolId);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.InvalidIntentSignature.selector, address(0), address(vaultTrader)));
        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);
    }

    function testWave4SolverAuctionSelectsHighestEncryptedBid() public {
        uint256 swapId = _captureIntent(9e5, 51);

        _submitSolverBid(swapId, solverA, 915_000);

        _submitSolverBid(swapId, solverB, 940_000);

        _submitSolverBid(swapId, solverC, 930_000);

        assertEq(hook.getSolverBidCount(swapId), 3);

        hook.queueSolverAuction(swapId);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.SolverAuctionPending.selector, swapId));
        hook.finalizeSolverAuction(swapId);

        vm.warp(block.timestamp + 11);

        hook.finalizeSolverAuction(swapId);

        IPostSettleReveal.SolverAuction memory auction = hook.getSolverAuction(swapId);
        assertEq(auction.bidCount, 3);
        assertTrue(auction.queued);
        assertTrue(auction.finalized);
        assertEq(auction.winner, solverB);
        assertEq(auction.winningBidAmountOut, 940_000);
    }

    function testWave4SolverAuctionRejectsDuplicateBidder() public {
        uint256 swapId = _captureIntent(9e5, 52);

        _submitSolverBid(swapId, solverA, 910_000);

        vm.startPrank(solverA);
        InEuint128 memory duplicateBid = cft.createInEuint128(920_000, solverA);
        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.DuplicateSolverBid.selector, swapId, solverA));
        hook.submitSolverBid(swapId, duplicateBid);
        vm.stopPrank();
    }

    function testWave4SolverAuctionRejectsQueueWithNoBids() public {
        uint256 swapId = _captureIntent(9e5, 53);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.SolverAuctionNoBids.selector, swapId));
        hook.queueSolverAuction(swapId);
    }

    function testWave4SolverAuctionRejectsSecondQueue() public {
        uint256 swapId = _captureIntent(9e5, 54);

        _submitSolverBid(swapId, solverA, 910_000);
        hook.queueSolverAuction(swapId);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.SolverAuctionAlreadyQueued.selector, swapId));
        hook.queueSolverAuction(swapId);
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

    function _buildHookData(
        uint128 minOutPlaintext,
        uint256 nonce,
        address encryptionSigner,
        address sender,
        address traderAddress,
        uint256 traderPrivateKey,
        bytes32 poolId
    ) internal returns (bytes memory) {
        InEuint128 memory minOut = cft.createInEuint128(minOutPlaintext, encryptionSigner);
        uint256 deadline = block.timestamp + INTENT_DEADLINE_WINDOW;
        bytes32 digest = _intentDigest(traderAddress, sender, poolId, nonce, deadline, minOut.ctHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        return abi.encode(minOut, nonce, traderAddress, deadline, signature);
    }

    function _intentDigest(
        address traderAddress,
        address sender,
        bytes32 poolId,
        uint256 nonce,
        uint256 deadline,
        uint256 ctHash
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(INTENT_AUTHORIZATION_TYPEHASH, traderAddress, sender, poolId, nonce, deadline, ctHash)
        );

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("GhostSwapIntent")),
                keccak256(bytes("1")),
                block.chainid,
                address(hook)
            )
        );
    }

    function _captureIntent(uint128 minOutPlaintext, uint256 nonce) internal returns (uint256 swapId) {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(minOutPlaintext, nonce, trader, trader, trader, traderPk, poolId);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        swapId = hook.nextSwapId() - 1;
    }

    function _submitSolverBid(uint256 swapId, address solver, uint128 bidAmountOut) internal {
        vm.startPrank(solver);
        InEuint128 memory encryptedBid = cft.createInEuint128(bidAmountOut, solver);
        hook.submitSolverBid(swapId, encryptedBid);
        vm.stopPrank();
    }
}
