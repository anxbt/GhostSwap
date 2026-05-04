// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {FHE, ebool, euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {IPostSettleReveal} from "../interface/IPostSettleReveal.sol";
import {IGhostVault} from "../interface/IGhostVault.sol";

contract PostSettleRevealHook is BaseHook, EIP712, IPostSettleReveal {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant INTENT_AUTHORIZATION_TYPEHASH = keccak256(
        "IntentAuthorization(address trader,address sender,bytes32 poolId,uint256 nonce,uint256 deadline,uint256 ctHash)"
    );

    struct HookDataPayload {
        InEuint128 encryptedMinOutInput;
        uint256 nonce;
        address trader;
        uint256 deadline;
        bytes traderSignature;
    }

    struct SolverBid {
        address solver;
        euint128 encryptedAmountOut;
        uint256 submittedAtBlock;
    }

    uint256 public immutable revealDelayBlocks;
    address public immutable owner;

    uint256 public nextSwapId = 1;

    mapping(uint256 => SwapIntent) internal _swapIntents;
    mapping(uint256 => SettlementRecord) internal _settlementRecords;

    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    mapping(address => uint256) public pendingSwapIdByTrader;
    mapping(address => uint256) public pendingSwapIdBySender;
    mapping(address => bool) public authorizedRevealers;
    mapping(address => mapping(address => bool)) public authorizedRevealersByTrader;
    mapping(uint256 => SlippageOutcome) internal _slippageOutcomes;
    mapping(uint256 => ebool) internal _minimumCheckBySwapId;
    mapping(uint256 => SolverBid[]) internal _solverBids;
    mapping(uint256 => SolverAuction) internal _solverAuctions;
    mapping(uint256 => mapping(address => bool)) internal _solverHasBid;
    mapping(uint256 => euint128) internal _winningEncryptedBidBySwapId;
    mapping(uint256 => ebool[]) internal _winningBidMatchesBySwapId;

    address public surplusVault;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    constructor(IPoolManager _poolManager, uint256 _revealDelayBlocks, address _owner)
        BaseHook(_poolManager)
        EIP712("GhostSwapIntent", "1")
    {
        revealDelayBlocks = _revealDelayBlocks;
        owner = _owner;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        // Wave 1 intentionally enables only swap callbacks to keep lifecycle minimal.
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookDataPayload memory payload = _decodeHookData(hookData);

        if (payload.trader == address(0)) {
            revert InvalidHookData();
        }

        if (block.timestamp > payload.deadline) {
            revert ExpiredIntent(payload.deadline, block.timestamp);
        }

        if (pendingSwapIdByTrader[payload.trader] != 0) {
            revert PendingIntentExists(payload.trader, pendingSwapIdByTrader[payload.trader]);
        }

        if (pendingSwapIdBySender[sender] != 0) {
            revert PendingIntentExists(sender, pendingSwapIdBySender[sender]);
        }

        bytes32 poolId = PoolId.unwrap(key.toId());
        _verifyIntentSignature(payload, sender, poolId);

        if (nonceUsed[payload.trader][payload.nonce]) revert NonceUsed(payload.trader, payload.nonce);

        nonceUsed[payload.trader][payload.nonce] = true;

        euint128 encryptedMinOut = FHE.asEuint128(payload.encryptedMinOutInput);
        uint256 swapId = nextSwapId++;

        _swapIntents[swapId] = SwapIntent({
            trader: payload.trader,
            poolId: poolId,
            encryptedMinOut: encryptedMinOut,
            nonce: payload.nonce,
            createdAtBlock: block.number,
            state: SwapState.IntentCaptured
        });

        pendingSwapIdByTrader[payload.trader] = swapId;
        pendingSwapIdBySender[sender] = swapId;

        FHE.allowThis(_swapIntents[swapId].encryptedMinOut);
        FHE.allow(_swapIntents[swapId].encryptedMinOut, payload.trader);

        emit IntentCaptured(swapId, payload.trader, poolId, payload.nonce, block.number);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 swapId = pendingSwapIdBySender[sender];
        if (swapId == 0) revert MissingIntent(sender);

        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.state != SwapState.IntentCaptured) {
            revert InvalidState(swapId, SwapState.IntentCaptured, intent.state);
        }

        uint128 actualAmountOut = _extractActualAmountOut(delta, params.zeroForOne);
        ebool minimumCheck = _queueSlippageCheck(actualAmountOut, intent.encryptedMinOut);

        _slippageOutcomes[swapId] = SlippageOutcome({
            actualAmountOut: actualAmountOut,
            minimumAmountOut: 0,
            surplusAmountOut: 0,
            passed: false
        });
        _minimumCheckBySwapId[swapId] = minimumCheck;

        intent.state = SwapState.SettledPendingReveal;

        _settlementRecords[swapId] = SettlementRecord({
            swapId: swapId,
            delta0: delta.amount0(),
            delta1: delta.amount1(),
            amountSpecified: params.amountSpecified,
            settledAtBlock: block.number,
            decryptReadyBlock: block.number + revealDelayBlocks
        });

        pendingSwapIdBySender[sender] = 0;
        pendingSwapIdByTrader[intent.trader] = 0;

        emit SettlementRecorded(
            swapId,
            intent.trader,
            _settlementRecords[swapId].delta0,
            _settlementRecords[swapId].delta1,
            _settlementRecords[swapId].amountSpecified,
            _settlementRecords[swapId].settledAtBlock
        );
        emit RevealReady(swapId, intent.trader, _settlementRecords[swapId].decryptReadyBlock);

        return (BaseHook.afterSwap.selector, 0);
    }

    function finalizeSlippageCheck(uint256 swapId) public {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);

        SlippageOutcome storage outcome = _slippageOutcomes[swapId];
        if (outcome.passed) {
            return;
        }

        ebool minimumCheck = _minimumCheckBySwapId[swapId];
        if (ebool.unwrap(minimumCheck) == 0) revert SlippageCheckPending(swapId);

        (bool passed, bool comparisonReady) = FHE.getDecryptResultSafe(minimumCheck);
        if (!comparisonReady) revert SlippageCheckPending(swapId);

        bool minimumReady;
        (outcome.minimumAmountOut, minimumReady) = FHE.getDecryptResultSafe(intent.encryptedMinOut);
        if (!minimumReady) revert SlippageCheckPending(swapId);

        if (!passed) {
            revert FillBelowEncryptedMinimum(swapId, outcome.actualAmountOut, outcome.minimumAmountOut);
        }

        if (outcome.actualAmountOut > outcome.minimumAmountOut) {
            outcome.surplusAmountOut = outcome.actualAmountOut - outcome.minimumAmountOut;
        }

        outcome.passed = true;
        _minimumCheckBySwapId[swapId] = ebool.wrap(0);

        if (surplusVault != address(0) && intent.trader == surplusVault) {
            IGhostVault(surplusVault).recordSurplus(swapId, outcome.surplusAmountOut, intent.trader);
            emit SurplusForwardedToVault(swapId, surplusVault, outcome.surplusAmountOut);
        }

        emit SlippageChecked(swapId, outcome.actualAmountOut, outcome.minimumAmountOut, outcome.surplusAmountOut, true);
    }

    function revealSwapDetails(uint256 swapId) external override {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);

        bool callerAuthorized = msg.sender == intent.trader
            || authorizedRevealers[msg.sender]
            || authorizedRevealersByTrader[intent.trader][msg.sender];
        if (!callerAuthorized) {
            revert Unauthorized(msg.sender);
        }

        if (intent.state == SwapState.RevealedToAuthorized) revert AlreadyRevealed(swapId);

        if (intent.state != SwapState.SettledPendingReveal && intent.state != SwapState.DecryptReady) {
            revert InvalidState(swapId, SwapState.SettledPendingReveal, intent.state);
        }

        SettlementRecord storage record = _settlementRecords[swapId];

        if (block.number < record.decryptReadyBlock) {
            revert RevealNotReady(swapId, record.decryptReadyBlock, block.number);
        }

        if (!_slippageOutcomes[swapId].passed) {
            finalizeSlippageCheck(swapId);
        }

        if (intent.state == SwapState.SettledPendingReveal) {
            intent.state = SwapState.DecryptReady;
        }

        intent.state = SwapState.RevealedToAuthorized;

        emit Revealed(
            swapId,
            msg.sender,
            intent.trader,
            record.delta0,
            record.delta1,
            record.amountSpecified,
            record.settledAtBlock
        );
    }

    function submitSolverBid(uint256 swapId, InEuint128 calldata encryptedBidInput) external {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);
        if (intent.state == SwapState.RevealedToAuthorized) {
            revert SolverAuctionClosed(swapId, intent.state);
        }

        SolverAuction storage auction = _solverAuctions[swapId];
        if (auction.finalized) revert SolverAuctionAlreadyFinalized(swapId);
        if (auction.queued) revert SolverAuctionAlreadyQueued(swapId);
        if (_solverHasBid[swapId][msg.sender]) revert DuplicateSolverBid(swapId, msg.sender);

        euint128 encryptedBidAmountOut = FHE.asEuint128(encryptedBidInput);
        FHE.allowThis(encryptedBidAmountOut);

        _solverBids[swapId].push(
            SolverBid({solver: msg.sender, encryptedAmountOut: encryptedBidAmountOut, submittedAtBlock: block.number})
        );

        _solverHasBid[swapId][msg.sender] = true;
        auction.bidCount = _solverBids[swapId].length;

        emit SolverBidSubmitted(swapId, msg.sender, _solverBids[swapId].length - 1);
    }

    function queueSolverAuction(uint256 swapId) public {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);
        if (intent.state == SwapState.RevealedToAuthorized) {
            revert SolverAuctionClosed(swapId, intent.state);
        }

        SolverAuction storage auction = _solverAuctions[swapId];
        if (auction.finalized) revert SolverAuctionAlreadyFinalized(swapId);
        if (auction.queued) revert SolverAuctionAlreadyQueued(swapId);

        uint256 bidCount = _solverBids[swapId].length;
        if (bidCount == 0) revert SolverAuctionNoBids(swapId);

        euint128 winningEncryptedBid = _solverBids[swapId][0].encryptedAmountOut;
        for (uint256 i = 1; i < bidCount; i++) {
            winningEncryptedBid = FHE.max(winningEncryptedBid, _solverBids[swapId][i].encryptedAmountOut);
        }

        _winningEncryptedBidBySwapId[swapId] = winningEncryptedBid;
        FHE.allowThis(winningEncryptedBid);
        FHE.decrypt(winningEncryptedBid);

        ebool[] storage winningBidMatches = _winningBidMatchesBySwapId[swapId];
        for (uint256 i = 0; i < bidCount; i++) {
            ebool isWinningBid = FHE.eq(_solverBids[swapId][i].encryptedAmountOut, winningEncryptedBid);
            winningBidMatches.push(isWinningBid);
            FHE.allowThis(isWinningBid);
            FHE.decrypt(isWinningBid);
        }

        auction.bidCount = bidCount;
        auction.queued = true;

        emit SolverAuctionQueued(swapId, bidCount);
    }

    function finalizeSolverAuction(uint256 swapId) public {
        SolverAuction storage auction = _solverAuctions[swapId];
        if (!auction.queued) revert SolverAuctionNotQueued(swapId);
        if (auction.finalized) {
            return;
        }

        bool winningBidReady;
        (auction.winningBidAmountOut, winningBidReady) = FHE.getDecryptResultSafe(_winningEncryptedBidBySwapId[swapId]);
        if (!winningBidReady) revert SolverAuctionPending(swapId);

        ebool[] storage winningBidMatches = _winningBidMatchesBySwapId[swapId];
        bool winnerResolved;

        for (uint256 i = 0; i < winningBidMatches.length; i++) {
            bool isWinningBid;
            bool winningFlagReady;

            (isWinningBid, winningFlagReady) = FHE.getDecryptResultSafe(winningBidMatches[i]);
            if (!winningFlagReady) revert SolverAuctionPending(swapId);

            if (!winnerResolved && isWinningBid) {
                auction.winner = _solverBids[swapId][i].solver;
                winnerResolved = true;
            }
        }

        if (!winnerResolved) revert SolverAuctionWinnerNotFound(swapId);

        auction.finalized = true;

        emit SolverAuctionFinalized(swapId, auction.winner, auction.winningBidAmountOut, auction.bidCount);
    }

    function setAuthorizedRevealer(address revealer, bool isAuthorized) external {
        if (msg.sender == owner) {
            authorizedRevealers[revealer] = isAuthorized;
        } else {
            authorizedRevealersByTrader[msg.sender][revealer] = isAuthorized;
        }

        emit AuthorizedRevealerSet(revealer, isAuthorized);
    }

    function setSurplusVault(address vault) external onlyOwner {
        surplusVault = vault;
        emit SurplusVaultSet(vault);
    }

    function getSwapIntent(uint256 swapId) external view returns (address, bytes32, uint256, uint256, SwapState) {
        SwapIntent storage intent = _swapIntents[swapId];
        return (intent.trader, intent.poolId, intent.nonce, intent.createdAtBlock, intent.state);
    }

    function getEncryptedMinOut(uint256 swapId) external view returns (euint128) {
        return _swapIntents[swapId].encryptedMinOut;
    }

    function getSettlementRecord(uint256 swapId)
        external
        view
        returns (uint256, int128, int128, int256, uint256, uint256)
    {
        SettlementRecord storage record = _settlementRecords[swapId];
        return (
            record.swapId,
            record.delta0,
            record.delta1,
            record.amountSpecified,
            record.settledAtBlock,
            record.decryptReadyBlock
        );
    }

    function getSlippageOutcome(uint256 swapId) external view returns (uint128, uint128, uint128, bool) {
        SlippageOutcome storage outcome = _slippageOutcomes[swapId];
        return (outcome.actualAmountOut, outcome.minimumAmountOut, outcome.surplusAmountOut, outcome.passed);
    }

    function getSolverAuction(uint256 swapId) external view returns (SolverAuction memory) {
        return _solverAuctions[swapId];
    }

    function getSolverBidCount(uint256 swapId) external view returns (uint256) {
        return _solverBids[swapId].length;
    }

    function _decodeHookData(bytes calldata hookData) internal pure returns (HookDataPayload memory payload) {
        if (hookData.length == 0) revert InvalidHookData();
        (payload.encryptedMinOutInput, payload.nonce, payload.trader, payload.deadline, payload.traderSignature) =
            abi.decode(hookData, (InEuint128, uint256, address, uint256, bytes));
    }

    function _verifyIntentSignature(HookDataPayload memory payload, address sender, bytes32 poolId) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                INTENT_AUTHORIZATION_TYPEHASH,
                payload.trader,
                sender,
                poolId,
                payload.nonce,
                payload.deadline,
                payload.encryptedMinOutInput.ctHash
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);

        if (payload.trader.code.length > 0) {
            try IERC1271(payload.trader).isValidSignature(digest, payload.traderSignature) returns (bytes4 magicValue) {
                if (magicValue != IERC1271.isValidSignature.selector) {
                    revert InvalidIntentSignature(address(0), payload.trader);
                }
            } catch {
                revert InvalidIntentSignature(address(0), payload.trader);
            }

            return;
        }

        (address recovered, ECDSA.RecoverError recoverError,) =
            ECDSA.tryRecover(digest, payload.traderSignature);

        if (recoverError != ECDSA.RecoverError.NoError || recovered != payload.trader) {
            revert InvalidIntentSignature(recovered, payload.trader);
        }
    }

    function _extractActualAmountOut(BalanceDelta delta, bool zeroForOne) internal pure returns (uint128) {
        int128 rawAmountOut = zeroForOne ? delta.amount1() : delta.amount0();
        if (rawAmountOut <= 0) return 0;
        return uint128(rawAmountOut);
    }

    function _queueSlippageCheck(uint128 actualAmountOut, euint128 encryptedMinOut) internal returns (ebool minimumCheck) {
        euint128 encryptedActualAmountOut = FHE.asEuint128(actualAmountOut);
        minimumCheck = FHE.gte(encryptedActualAmountOut, encryptedMinOut);

        FHE.allowThis(minimumCheck);
        FHE.decrypt(minimumCheck);
        FHE.allowThis(encryptedMinOut);
        FHE.decrypt(encryptedMinOut);
    }
}
