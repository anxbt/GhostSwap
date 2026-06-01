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
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {FHE, ebool, euint128, InEuint128, TASK_MANAGER_ADDRESS} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {ITaskManager} from "@fhenixprotocol/cofhe-contracts/ICofhe.sol";

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
    address public immutable COFHE_VERIFIER;

    // Emergency timeout windows. Owner-settable so they can be shortened for live testnet demos.
    // Defaults match production values (~6h / ~24h / ~1h at 12s blocks).
    uint256 public CANCEL_DELAY_BLOCKS = 1800; // ~6 hours at 12s blocks
    uint256 public FALLBACK_DELAY_BLOCKS = 7200; // ~24 hours at 12s blocks
    uint256 public AUCTION_TIMEOUT_BLOCKS = 300; // ~1 hour at 12s blocks

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

    // Wave 3: FHE enforcement state
    mapping(bytes32 => uint128) internal _publishedDecryptResults; // ctHash -> decryptedValue
    mapping(bytes32 => bool) internal _decryptResultPublished; // ctHash -> published flag
    mapping(uint256 => bool) internal _encryptedMinimumEnforced; // swapId -> enforced flag

    // Wave 4: Solver auction + execution binding
    mapping(address => bool) public allowedSolvers; // solver allowlist
    mapping(uint256 => bytes32) internal _auctionWinnerCalldataHash; // swapId -> calldataHash for binding
    mapping(uint256 => bool) internal _auctionWinnerExecutionBound; // swapId -> bound flag

    address public surplusVault;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    constructor(IPoolManager _poolManager, uint256 _revealDelayBlocks, address _owner, address _cofheVerifier)
        BaseHook(_poolManager)
        EIP712("GhostSwapIntent", "1")
    {
        revealDelayBlocks = _revealDelayBlocks;
        owner = _owner;
        COFHE_VERIFIER = _cofheVerifier;
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
        if (intent.state == SwapState.EmergencyResolved) revert SwapAlreadyEmergencyResolved(swapId);

        if (intent.state != SwapState.SettledPendingReveal && intent.state != SwapState.DecryptReady) {
            revert InvalidState(swapId, SwapState.SettledPendingReveal, intent.state);
        }

        SettlementRecord storage record = _settlementRecords[swapId];

        if (block.number < record.decryptReadyBlock) {
            revert RevealNotReady(swapId, record.decryptReadyBlock, block.number);
        }

        // Finalize the encrypted slippage check only if the async CoFHE decryption is ready.
        // The reveal of trade details must not be blocked on the coprocessor: if the decrypt
        // result is not yet available, surplus is finalized later via finalizeSlippageCheck().
        // When the result IS ready, this still propagates real outcomes (e.g. FillBelowEncryptedMinimum).
        if (!_slippageOutcomes[swapId].passed) {
            ebool minimumCheck = _minimumCheckBySwapId[swapId];
            bool decryptReady = false;
            if (ebool.unwrap(minimumCheck) != 0) {
                (, decryptReady) = FHE.getDecryptResultSafe(minimumCheck);
            }
            if (decryptReady) {
                finalizeSlippageCheck(swapId);
            }
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
        auction.queuedAtBlock = block.number;

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

    /// @notice Owner-settable emergency timeout windows (in blocks).
    /// @dev Production defaults are 1800 / 7200 / 300. Shortened on testnet to demo the
    ///      cancel / auto-release / auction-cancel paths without waiting hours.
    function setEmergencyDelays(uint256 cancelBlocks, uint256 fallbackBlocks, uint256 auctionBlocks)
        external
        onlyOwner
    {
        CANCEL_DELAY_BLOCKS = cancelBlocks;
        FALLBACK_DELAY_BLOCKS = fallbackBlocks;
        AUCTION_TIMEOUT_BLOCKS = auctionBlocks;
        emit EmergencyDelaysUpdated(cancelBlocks, fallbackBlocks, auctionBlocks);
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

        // The live CoFHE coprocessor requires a ciphertext to be globally allowed before it can
        // be decrypted (createDecryptTask reverts otherwise). cofhe-contracts 0.0.13 ships no
        // FHE.allowGlobal wrapper, so call the TaskManager directly — this mirrors the 0.1.x
        // FHE.allowGlobal implementation: allowGlobal(uint256(unwrap(ctHash))).
        // FHE.decrypt() hardcodes msg.sender as the decrypt requestor; inside a v4 hook that is
        // the PoolManager, which the live coprocessor rejects. Call createDecryptTask directly
        // with this hook as the requestor (== the caller), after marking the ciphertext globally
        // decryptable. Wrapped in best-effort low-level calls so a coprocessor-side rejection
        // cannot revert the whole swap (the slippage check finalizes asynchronously).
        FHE.allowThis(minimumCheck);
        ITaskManager(TASK_MANAGER_ADDRESS).allowGlobal(ebool.unwrap(minimumCheck));
        TASK_MANAGER_ADDRESS.call(
            abi.encodeWithSelector(ITaskManager.createDecryptTask.selector, ebool.unwrap(minimumCheck), address(this))
        );
        FHE.allowThis(encryptedMinOut);
        ITaskManager(TASK_MANAGER_ADDRESS).allowGlobal(euint128.unwrap(encryptedMinOut));
        TASK_MANAGER_ADDRESS.call(
            abi.encodeWithSelector(ITaskManager.createDecryptTask.selector, euint128.unwrap(encryptedMinOut), address(this))
        );
    }

    // ===== Wave 3: FHE Enforcement & Reveal =====

    /// @notice Publish a decrypted result obtained from the CoFHE SDK (client-side decryptForTx)
    /// @dev Called to make the result available for enforcement via `enforceEncryptedMinimum`.
    ///      The signature should be validated on the client and this call is idempotent.
    /// @param ctHash The ciphertext hash being decrypted
    /// @param decryptedValue The plaintext result from CoFHE SDK `decryptForTx()`
    /// @param signature CoFHE SDK signature authorizing this decryption (for future on-chain validation)
    function publishDecryptResult(bytes32 ctHash, uint128 decryptedValue, bytes calldata signature) external {
        // Verify the signature was produced by the CoFHE verifier
        bytes32 messageHash = keccak256(abi.encodePacked(ctHash, decryptedValue));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recovered = ECDSA.recover(ethSignedHash, signature);
        if (recovered != COFHE_VERIFIER) revert InvalidCoFHESignature(recovered, COFHE_VERIFIER);

        _publishedDecryptResults[ctHash] = decryptedValue;
        _decryptResultPublished[ctHash] = true;

        emit DecryptResultPublished(ctHash, decryptedValue);
    }

    /// @notice Enforce encrypted minimum: verify actual fill >= decrypted minimum and attribute surplus
    /// @dev Called after `publishDecryptResult` confirms the decrypt. Sender can be anyone.
    ///      Reverts if actual fill < decrypted minimum. On pass, forwards surplus to vault.
    /// @param swapId The swap being enforced
    /// @param decryptedMinOut The plaintext minimum (previously published via `publishDecryptResult`)
    function enforceEncryptedMinimum(uint256 swapId, uint128 decryptedMinOut) external {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);
        if (_encryptedMinimumEnforced[swapId]) {
            // Already enforced; allow re-call but short-circuit
            return;
        }

        SlippageOutcome storage outcome = _slippageOutcomes[swapId];
        if (!outcome.passed) {
            // If slippage check hasn't passed yet, finalize it
            finalizeSlippageCheck(swapId);
        }

        // Enforce: actual >= decrypted minimum
        if (outcome.actualAmountOut < decryptedMinOut) {
            revert FillBelowEncryptedMinimum(swapId, outcome.actualAmountOut, decryptedMinOut);
        }

        // Mark as enforced
        _encryptedMinimumEnforced[swapId] = true;

        // Calculate and forward surplus to vault
        uint128 surplus = outcome.actualAmountOut - decryptedMinOut;
        if (surplus > 0 && surplusVault != address(0)) {
            // For Wave 4: if this is an auction winner execution, the vault is the trader
            IGhostVault(surplusVault).recordSurplus(swapId, surplus, intent.trader);
            emit SurplusForwardedToVault(swapId, surplusVault, surplus);
        }
    }

    /// @notice Check if a decrypted result is ready/published
    /// @param ctHash The ciphertext hash
    /// @return ready True if result has been published via `publishDecryptResult`
    function isDecryptReady(bytes32 ctHash) external view returns (bool ready) {
        return _decryptResultPublished[ctHash];
    }

    /// @notice Get a previously published decrypted result (if ready)
    /// @param ctHash The ciphertext hash
    /// @return value The decrypted value (0 if not ready)
    /// @return ready True if result is available
    function getPublishedDecryptResult(bytes32 ctHash) external view returns (uint128 value, bool ready) {
        ready = _decryptResultPublished[ctHash];
        if (ready) {
            value = _publishedDecryptResults[ctHash];
        }
    }

    // ===== Wave 4: Solver Auction + Execution Binding =====

    /// @notice Register a solver on the allowlist
    /// @dev Only owner can call. Solvers must be registered to submit bids.
    /// @param solver The solver address to allow
    function registerSolver(address solver) external onlyOwner {
        allowedSolvers[solver] = true;
        emit SolverRegistered(solver);
    }

    /// @notice Unregister a solver from the allowlist
    /// @dev Only owner can call.
    /// @param solver The solver address to remove
    function unregisterSolver(address solver) external onlyOwner {
        allowedSolvers[solver] = false;
        emit SolverUnregistered(solver);
    }

    /// @notice Check if a solver is allowed to submit bids
    /// @param solver The solver address
    /// @return True if solver is registered
    function isSolverAllowed(address solver) external view returns (bool) {
        return allowedSolvers[solver];
    }

    /// @notice Bind an auction winner's execution to a specific calldata hash
    /// @dev Called after `finalizeSolverAuction` to lock the periphery execution.
    ///      Only the auction winner can execute this intent (enforced by periphery).
    /// @param swapId The swap whose auction was finalized
    /// @param calldataHash Optional: hash of the intended router calldata for replay protection
    function bindAuctionWinnerExecution(uint256 swapId, bytes32 calldataHash) external {
        SolverAuction storage auction = _solverAuctions[swapId];
        if (!auction.finalized) revert SolverAuctionNotQueued(swapId);

        // Only owner or the winning solver can bind execution
        if (msg.sender != owner && msg.sender != auction.winner) {
            revert Unauthorized(msg.sender);
        }

        _auctionWinnerCalldataHash[swapId] = calldataHash;
        _auctionWinnerExecutionBound[swapId] = true;

        emit AuctionWinnerExecutionBound(swapId, auction.winner, calldataHash);
    }

    /// @notice Check if an auction winner's execution is bound
    /// @param swapId The swap
    /// @return bound True if bound
    /// @return winner The winning solver address
    /// @return calldataHash Optional replay-protection hash
    function getAuctionExecutionBinding(uint256 swapId)
        external
        view
        returns (bool bound, address winner, bytes32 calldataHash)
    {
        bound = _auctionWinnerExecutionBound[swapId];
        SolverAuction storage auction = _solverAuctions[swapId];
        winner = auction.winner;
        calldataHash = _auctionWinnerCalldataHash[swapId];
    }

    // ===== Emergency Resolution Functions =====

    /// @notice Cancel a stuck swap after the cancel delay has elapsed (Scenario C)
    /// @dev Only the original trader can cancel. Marks the swap as EmergencyResolved.
    ///      The swap has already settled on Uniswap — this does NOT refund tokens.
    ///      It marks the swap as resolved so the trader can proceed without the FHE result.
    /// @param swapId The swap to cancel
    function cancelStuckSwap(uint256 swapId) external {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);
        if (msg.sender != intent.trader) revert Unauthorized(msg.sender);
        if (intent.state == SwapState.RevealedToAuthorized) revert AlreadyRevealed(swapId);
        if (intent.state == SwapState.EmergencyResolved) revert SwapAlreadyEmergencyResolved(swapId);
        if (intent.state != SwapState.SettledPendingReveal && intent.state != SwapState.DecryptReady) {
            revert InvalidEmergencyState(swapId, intent.state);
        }

        uint256 cancelReadyBlock = intent.createdAtBlock + CANCEL_DELAY_BLOCKS;
        if (block.number < cancelReadyBlock) {
            revert CancelDelayNotElapsed(swapId, cancelReadyBlock, block.number);
        }

        intent.state = SwapState.EmergencyResolved;

        emit SwapEmergencyResolved(swapId, msg.sender, "cancel");
    }

    /// @notice Auto-release a stuck swap after the fallback delay has elapsed (Scenario A)
    /// @dev Anyone can call after the fallback delay. Marks the swap as EmergencyResolved.
    ///      The vault receives no surplus from this swap. Trader funds are already in their wallet.
    /// @param swapId The swap to auto-release
    function autoReleaseStuckSwap(uint256 swapId) external {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);
        if (intent.state == SwapState.RevealedToAuthorized) revert AlreadyRevealed(swapId);
        if (intent.state == SwapState.EmergencyResolved) revert SwapAlreadyEmergencyResolved(swapId);
        if (intent.state != SwapState.SettledPendingReveal && intent.state != SwapState.DecryptReady) {
            revert InvalidEmergencyState(swapId, intent.state);
        }

        uint256 fallbackReadyBlock = intent.createdAtBlock + FALLBACK_DELAY_BLOCKS;
        if (block.number < fallbackReadyBlock) {
            revert FallbackDelayNotElapsed(swapId, fallbackReadyBlock, block.number);
        }

        intent.state = SwapState.EmergencyResolved;

        emit SwapEmergencyResolved(swapId, msg.sender, "auto_release");
    }

    /// @notice Cancel a stuck solver auction after the auction timeout has elapsed (Scenario B)
    /// @dev Only the original trader can cancel. Marks the auction as cancelled and the swap as EmergencyResolved.
    ///      No swap was executed — the auction was the execution path, so cancelling it voids the trade.
    /// @param swapId The swap whose auction to cancel
    function cancelStuckAuction(uint256 swapId) external {
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);
        if (msg.sender != intent.trader) revert Unauthorized(msg.sender);

        SolverAuction storage auction = _solverAuctions[swapId];
        if (!auction.queued) revert SolverAuctionNotQueued(swapId);
        if (auction.cancelled) revert AuctionAlreadyCancelled(swapId);
        if (auction.finalized) revert SolverAuctionAlreadyFinalized(swapId);

        uint256 auctionTimeoutBlock = auction.queuedAtBlock + AUCTION_TIMEOUT_BLOCKS;
        if (block.number < auctionTimeoutBlock) {
            revert AuctionTimeoutNotElapsed(swapId, auctionTimeoutBlock, block.number);
        }

        auction.cancelled = true;
        intent.state = SwapState.EmergencyResolved;

        emit AuctionCancelled(swapId, msg.sender);
        emit SwapEmergencyResolved(swapId, msg.sender, "auction_cancel");
    }
}
