// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {IPostSettleReveal} from "../src/interface/IPostSettleReveal.sol";
import {GhostVault} from "../src/GhostVault.sol";

contract PostSettleRevealHookHarness is PostSettleRevealHook {
    constructor(IPoolManager manager, uint256 revealDelay, address _owner, address _cofheVerifier)
        PostSettleRevealHook(manager, revealDelay, _owner, _cofheVerifier)
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

contract EmergencyIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant REVEAL_DELAY = 11;
    uint256 internal constant INTENT_DEADLINE_WINDOW = 30 minutes;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant INTENT_AUTHORIZATION_TYPEHASH = keccak256(
        "IntentAuthorization(address trader,address sender,bytes32 poolId,uint256 nonce,uint256 deadline,uint256 ctHash)"
    );

    event SwapEmergencyResolved(uint256 indexed swapId, address indexed caller, string reason);
    event AuctionCancelled(uint256 indexed swapId, address indexed caller);
    event DecryptResultPublished(bytes32 indexed ctHash, uint128 decryptedValue);

    CoFheTest internal cft;
    PostSettleRevealHookHarness internal hook;
    MockERC20 internal vaultAsset;
    GhostVault internal vaultTrader;

    uint256 internal traderPk = uint256(keccak256("emergency-test-trader"));
    address internal trader;
    address internal unauthorized = makeAddr("unauthorized");
    address internal solverA = makeAddr("solverA");
    uint256 internal cofheVerifierPk = uint256(keccak256("emergency-cofhe-verifier"));
    address internal cofheVerifier;

    function setUp() public {
        cft = new CoFheTest(false);
        trader = vm.addr(traderPk);
        cofheVerifier = vm.addr(cofheVerifierPk);

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144)
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(address(this)), REVEAL_DELAY, address(this), cofheVerifier);
        deployCodeTo("EmergencyIntegration.t.sol:PostSettleRevealHookHarness", constructorArgs, flags);
        hook = PostSettleRevealHookHarness(flags);

        vaultAsset = new MockERC20("Vault Asset", "VAST", 18);
        vaultTrader = new GhostVault(address(vaultAsset), address(hook));
    }

    // ===== Scenario A: Auto-release after 24h =====

    function testAutoRelease_afterFallbackDelay_resolvesSwap() public {
        uint256 swapId = _captureAndSettle(9e5, 1);

        (, , , , uint256 createdAtBlock,) = hook.getSettlementRecord(swapId);
        uint256 fallbackReadyBlock = createdAtBlock + hook.FALLBACK_DELAY_BLOCKS();

        vm.roll(fallbackReadyBlock);

        vm.expectEmit(true, true, false, false, address(hook));
        emit SwapEmergencyResolved(swapId, unauthorized, "auto_release");

        vm.prank(unauthorized);
        hook.autoReleaseStuckSwap(swapId);

        (, , , , IPostSettleReveal.SwapState finalState) = hook.getSwapIntent(swapId);
        assertEq(uint256(finalState), uint256(IPostSettleReveal.SwapState.EmergencyResolved));
    }

    // ===== Scenario B: Cancel stuck auction after timeout =====

    function testCancelAuction_afterTimeout_resolvesSwap() public {
        uint256 swapId = _captureAndSettle(9e5, 10);

        _submitSolverBid(swapId, solverA, 910_000);
        hook.queueSolverAuction(swapId);

        IPostSettleReveal.SolverAuction memory auction = hook.getSolverAuction(swapId);
        uint256 auctionTimeoutBlock = auction.queuedAtBlock + hook.AUCTION_TIMEOUT_BLOCKS();

        vm.roll(auctionTimeoutBlock);

        vm.expectEmit(true, true, false, false, address(hook));
        emit AuctionCancelled(swapId, trader);

        vm.expectEmit(true, true, false, false, address(hook));
        emit SwapEmergencyResolved(swapId, trader, "auction_cancel");

        vm.prank(trader);
        hook.cancelStuckAuction(swapId);

        (, , , , IPostSettleReveal.SwapState finalState) = hook.getSwapIntent(swapId);
        assertEq(uint256(finalState), uint256(IPostSettleReveal.SwapState.EmergencyResolved));

        IPostSettleReveal.SolverAuction memory auctionAfter = hook.getSolverAuction(swapId);
        assertTrue(auctionAfter.cancelled);
    }

    // ===== Scenario C: Cancel stuck swap after 6h =====

    function testCancelStuckSwap_afterCancelDelay_resolvesSwap() public {
        uint256 swapId = _captureAndSettle(9e5, 20);

        (, , , , uint256 createdAtBlock,) = hook.getSettlementRecord(swapId);
        uint256 cancelReadyBlock = createdAtBlock + hook.CANCEL_DELAY_BLOCKS();

        vm.roll(cancelReadyBlock);

        vm.expectEmit(true, true, false, false, address(hook));
        emit SwapEmergencyResolved(swapId, trader, "cancel");

        vm.prank(trader);
        hook.cancelStuckSwap(swapId);

        (, , , , IPostSettleReveal.SwapState finalState) = hook.getSwapIntent(swapId);
        assertEq(uint256(finalState), uint256(IPostSettleReveal.SwapState.EmergencyResolved));
    }

    // ===== publishDecryptResult with valid signature =====

    function testPublishDecryptResult_validSignature_storesResult() public {
        bytes32 ctHash = keccak256("integration-ct-hash");
        uint128 decryptedValue = 950_000;

        bytes32 messageHash = keccak256(abi.encodePacked(ctHash, decryptedValue));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cofheVerifierPk, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectEmit(true, false, false, true, address(hook));
        emit DecryptResultPublished(ctHash, decryptedValue);

        hook.publishDecryptResult(ctHash, decryptedValue, signature);

        (uint128 storedValue, bool ready) = hook.getPublishedDecryptResult(ctHash);
        assertTrue(ready);
        assertEq(storedValue, decryptedValue);
        assertTrue(hook.isDecryptReady(ctHash));
    }

    // ===== Emergency-resolved swap cannot be revealed =====

    function testEmergencyResolved_cannotBeRevealed() public {
        uint256 swapId = _captureAndSettle(9e5, 30);

        (, , , , uint256 createdAtBlock, uint256 decryptReadyBlock) = hook.getSettlementRecord(swapId);

        vm.roll(createdAtBlock + hook.CANCEL_DELAY_BLOCKS());

        vm.prank(trader);
        hook.cancelStuckSwap(swapId);

        vm.roll(decryptReadyBlock);
        vm.warp(block.timestamp + 11);

        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.SwapAlreadyEmergencyResolved.selector, swapId));
        vm.prank(trader);
        hook.revealSwapDetails(swapId);
    }

    // ===== Full lifecycle: submit → settle → cancel → cannot reveal =====

    function testFullLifecycle_cancelAfterDelay() public {
        uint256 swapId = _captureAndSettle(9e5, 40);

        (, , , , uint256 createdAtBlock, uint256 decryptReadyBlock) = hook.getSettlementRecord(swapId);

        // Before cancel delay: cannot cancel
        vm.roll(createdAtBlock + hook.CANCEL_DELAY_BLOCKS() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPostSettleReveal.CancelDelayNotElapsed.selector,
                swapId,
                createdAtBlock + hook.CANCEL_DELAY_BLOCKS(),
                createdAtBlock + hook.CANCEL_DELAY_BLOCKS() - 1
            )
        );
        vm.prank(trader);
        hook.cancelStuckSwap(swapId);

        // After cancel delay: can cancel
        vm.roll(createdAtBlock + hook.CANCEL_DELAY_BLOCKS());
        vm.prank(trader);
        hook.cancelStuckSwap(swapId);

        (, , , , IPostSettleReveal.SwapState finalState) = hook.getSwapIntent(swapId);
        assertEq(uint256(finalState), uint256(IPostSettleReveal.SwapState.EmergencyResolved));

        // Cannot reveal after emergency resolution
        vm.roll(decryptReadyBlock);
        vm.warp(block.timestamp + 11);
        vm.expectRevert(abi.encodeWithSelector(IPostSettleReveal.SwapAlreadyEmergencyResolved.selector, swapId));
        vm.prank(trader);
        hook.revealSwapDetails(swapId);
    }

    // ===== Helper functions =====

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

    function _captureAndSettle(uint128 minOutPlaintext, uint256 nonce) internal returns (uint256 swapId) {
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes32 poolId = PoolId.unwrap(key.toId());

        bytes memory hookData = _buildHookData(minOutPlaintext, nonce, trader, trader, trader, traderPk, poolId);

        vm.prank(trader);
        hook.exposedBeforeSwap(trader, key, params, hookData);

        swapId = hook.nextSwapId() - 1;

        BalanceDelta delta = toBalanceDelta(-1e6, 9e5);
        hook.exposedAfterSwap(trader, key, params, delta, bytes(""));
    }

    function _submitSolverBid(uint256 swapId, address solver, uint128 bidAmountOut) internal {
        vm.startPrank(solver);
        InEuint128 memory encryptedBid = cft.createInEuint128(bidAmountOut, solver);
        hook.submitSolverBid(swapId, encryptedBid);
        vm.stopPrank();
    }
}