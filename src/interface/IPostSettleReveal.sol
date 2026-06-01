// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IPostSettleReveal {
    enum SwapState {
        DraftIntent,
        IntentCaptured,
        SettledPendingReveal,
        DecryptReady,
        RevealedToAuthorized,
        EmergencyResolved
    }

    struct SwapIntent {
        address trader;
        bytes32 poolId;
        euint128 encryptedMinOut;
        uint256 nonce;
        uint256 createdAtBlock;
        SwapState state;
    }

    struct SettlementRecord {
        uint256 swapId;
        int128 delta0;
        int128 delta1;
        int256 amountSpecified;
        uint256 settledAtBlock;
        uint256 decryptReadyBlock;
    }

    struct SlippageOutcome {
        uint128 actualAmountOut;
        uint128 minimumAmountOut;
        uint128 surplusAmountOut;
        bool passed;
    }

    struct SolverAuction {
        uint256 bidCount;
        bool queued;
        bool finalized;
        bool cancelled;
        address winner;
        uint128 winningBidAmountOut;
        uint256 queuedAtBlock;
    }

    error Unauthorized(address caller);
    error InvalidState(uint256 swapId, SwapState expected, SwapState actual);
    error NonceUsed(address trader, uint256 nonce);
    error RevealNotReady(uint256 swapId, uint256 readyBlock, uint256 currentBlock);
    error AlreadyRevealed(uint256 swapId);
    error MissingIntent(address trader);
    error PendingIntentExists(address trader, uint256 swapId);
    error InvalidHookData();
    error ExpiredIntent(uint256 deadline, uint256 currentTimestamp);
    error InvalidIntentSignature(address recovered, address expectedTrader);
    error SlippageCheckPending(uint256 swapId);
    error FillBelowEncryptedMinimum(uint256 swapId, uint128 actualAmountOut, uint128 minimumAmountOut);
    error DuplicateSolverBid(uint256 swapId, address solver);
    error SolverAuctionNoBids(uint256 swapId);
    error SolverAuctionAlreadyQueued(uint256 swapId);
    error SolverAuctionNotQueued(uint256 swapId);
    error SolverAuctionPending(uint256 swapId);
    error SolverAuctionAlreadyFinalized(uint256 swapId);
    error SolverAuctionWinnerNotFound(uint256 swapId);
    error SolverAuctionClosed(uint256 swapId, SwapState state);
    error CancelDelayNotElapsed(uint256 swapId, uint256 readyBlock, uint256 currentBlock);
    error FallbackDelayNotElapsed(uint256 swapId, uint256 readyBlock, uint256 currentBlock);
    error AuctionTimeoutNotElapsed(uint256 swapId, uint256 timeoutBlock, uint256 currentBlock);
    error SwapAlreadyEmergencyResolved(uint256 swapId);
    error InvalidEmergencyState(uint256 swapId, SwapState state);
    error InvalidCoFHESignature(address recovered, address expected);
    error AuctionAlreadyCancelled(uint256 swapId);

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

    event SlippageChecked(
        uint256 indexed swapId,
        uint128 actualAmountOut,
        uint128 minimumAmountOut,
        uint128 surplusAmountOut,
        bool passed
    );

    event AuthorizedRevealerSet(address indexed revealer, bool isAuthorized);
    event SurplusVaultSet(address indexed vault);
    event SurplusForwardedToVault(uint256 indexed swapId, address indexed vault, uint128 surplusAmountOut);
    event SolverBidSubmitted(uint256 indexed swapId, address indexed solver, uint256 indexed bidIndex);
    event SolverAuctionQueued(uint256 indexed swapId, uint256 bidCount);
    event SolverAuctionFinalized(
        uint256 indexed swapId,
        address indexed winner,
        uint128 winningBidAmountOut,
        uint256 bidCount
    );

    // Wave 3: FHE Enforcement events
    event DecryptResultPublished(bytes32 indexed ctHash, uint128 decryptedValue);

    // Wave 4: Solver Auction events
    event SolverRegistered(address indexed solver);
    event SolverUnregistered(address indexed solver);
    event AuctionWinnerExecutionBound(uint256 indexed swapId, address indexed winner, bytes32 calldataHash);

    // Emergency resolution events
    event SwapEmergencyResolved(uint256 indexed swapId, address indexed caller, string reason);
    event AuctionCancelled(uint256 indexed swapId, address indexed caller);
    event EmergencyDelaysUpdated(uint256 cancelBlocks, uint256 fallbackBlocks, uint256 auctionBlocks);

    function revealSwapDetails(uint256 swapId) external;
    function finalizeSlippageCheck(uint256 swapId) external;
    function submitSolverBid(uint256 swapId, InEuint128 calldata encryptedBidInput) external;
    function queueSolverAuction(uint256 swapId) external;
    function finalizeSolverAuction(uint256 swapId) external;
    function setSurplusVault(address vault) external;

    // Wave 3: FHE Enforcement functions
    function publishDecryptResult(bytes32 ctHash, uint128 decryptedValue, bytes calldata signature) external;
    function enforceEncryptedMinimum(uint256 swapId, uint128 decryptedMinOut) external;
    function isDecryptReady(bytes32 ctHash) external view returns (bool);
    function getPublishedDecryptResult(bytes32 ctHash) external view returns (uint128, bool);

    // Wave 4: Solver management
    function registerSolver(address solver) external;
    function unregisterSolver(address solver) external;
    function isSolverAllowed(address solver) external view returns (bool);
    function bindAuctionWinnerExecution(uint256 swapId, bytes32 calldataHash) external;
    function getAuctionExecutionBinding(uint256 swapId) external view returns (bool, address, bytes32);

    function getSolverAuction(uint256 swapId) external view returns (SolverAuction memory);
    function getSolverBidCount(uint256 swapId) external view returns (uint256);
    function getSlippageOutcome(uint256 swapId) external view returns (uint128, uint128, uint128, bool);

    // Emergency resolution functions
    function cancelStuckSwap(uint256 swapId) external;
    function autoReleaseStuckSwap(uint256 swapId) external;
    function cancelStuckAuction(uint256 swapId) external;
}
