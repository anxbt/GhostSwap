// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

interface IPostSettleReveal {
    enum SwapState {
        DraftIntent,
        IntentCaptured,
        SettledPendingReveal,
        DecryptReady,
        RevealedToAuthorized
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

    error Unauthorized(address caller);
    error InvalidState(uint256 swapId, SwapState expected, SwapState actual);
    error NonceUsed(address trader, uint256 nonce);
    error RevealNotReady(uint256 swapId, uint256 readyBlock, uint256 currentBlock);
    error AlreadyRevealed(uint256 swapId);
    error MissingIntent(address trader);
    error PendingIntentExists(address trader, uint256 swapId);
    error InvalidHookData();

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

    event AuthorizedRevealerSet(address indexed revealer, bool isAuthorized);

    function revealSwapDetails(uint256 swapId) external;
}
