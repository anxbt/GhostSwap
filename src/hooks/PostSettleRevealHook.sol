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

import {FHE, euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {IPostSettleReveal} from "../interface/IPostSettleReveal.sol";

contract PostSettleRevealHook is BaseHook, IPostSettleReveal {
    using PoolIdLibrary for PoolKey;

    uint256 public immutable revealDelayBlocks;
    address public immutable owner;

    uint256 public nextSwapId = 1;

    mapping(uint256 => SwapIntent) internal _swapIntents;
    mapping(uint256 => SettlementRecord) internal _settlementRecords;

    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    mapping(address => uint256) public pendingSwapIdByTrader;
    mapping(address => bool) public authorizedRevealers;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    constructor(IPoolManager _poolManager, uint256 _revealDelayBlocks, address _owner) BaseHook(_poolManager) {
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

// Rejects if trader already has a pending swap intent.
// Decodes hookData as (InEuint128, uint256) via _decodeHookData.
// Rejects reused nonce per trader.
// Converts encrypted input handle and stores a new SwapIntent.
// Saves pendingSwapIdByTrader for pairing with afterSwap.
// Grants FHE access to contract and trader for encryptedMinOut.
// Emits IntentCaptured.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
       // Rejects if trader already has a pending swap intent.
        if (pendingSwapIdByTrader[sender] != 0) {
            revert PendingIntentExists(sender, pendingSwapIdByTrader[sender]);
        }

// Decodes hookData as (InEuint128, uint256) via _decodeHookData.
        (InEuint128 memory encryptedMinOutInput, uint256 nonce) = _decodeHookData(hookData);
        if (nonceUsed[sender][nonce]) revert NonceUsed(sender, nonce);

        // Nonce is marked before state writes so any re-entry or replay attempt fails early.
        nonceUsed[sender][nonce] = true;

        // Converts encrypted input handle and stores a new SwapIntent.

        euint128 encryptedMinOut = FHE.asEuint128(encryptedMinOutInput);
        uint256 swapId = nextSwapId++;
        bytes32 poolId = PoolId.unwrap(key.toId());

        _swapIntents[swapId] = SwapIntent({
            trader: sender,
            poolId: poolId,
            encryptedMinOut: encryptedMinOut,
            nonce: nonce,
            createdAtBlock: block.number,
            state: SwapState.IntentCaptured
        });

        pendingSwapIdByTrader[sender] = swapId;

        // Allow is granted immediately after assignment so the handle is usable by hook and trader.
        //Grants FHE access to contract and trader for encryptedMinOut.

        FHE.allowThis(_swapIntents[swapId].encryptedMinOut);
        FHE.allow(_swapIntents[swapId].encryptedMinOut, sender);

        emit IntentCaptured(swapId, sender, poolId, nonce, block.number);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

// Finds pending swap id for this sender.
// Ensures state was IntentCaptured.
// Moves state to SettledPendingReveal.
// Records deltas, amountSpecified, settled block, decryptReadyBlock.
// Clears pending mapping for that trader.
// Emits SettlementRecorded and RevealReady.
    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        //Finds pending swap id for this sender.
        uint256 swapId = pendingSwapIdByTrader[sender];
        if (swapId == 0) revert MissingIntent(sender);

// Ensures state was IntentCaptured.
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.state != SwapState.IntentCaptured) {
            revert InvalidState(swapId, SwapState.IntentCaptured, intent.state);
        }

// Moves state to SettledPendingReveal.
        intent.state = SwapState.SettledPendingReveal;

//Records deltas, amountSpecified, settled block, decryptReadyBlock.
        _settlementRecords[swapId] = SettlementRecord({
            swapId: swapId,
            delta0: delta.amount0(),
            delta1: delta.amount1(),
            amountSpecified: params.amountSpecified,
            settledAtBlock: block.number,
            decryptReadyBlock: block.number + revealDelayBlocks
        });

//Clears pending mapping for that trader.
        pendingSwapIdByTrader[sender] = 0;

        emit SettlementRecorded(
            swapId,
            sender,
            _settlementRecords[swapId].delta0,
            _settlementRecords[swapId].delta1,
            _settlementRecords[swapId].amountSpecified,
            _settlementRecords[swapId].settledAtBlock
        );
        emit RevealReady(swapId, sender, _settlementRecords[swapId].decryptReadyBlock);

        return (BaseHook.afterSwap.selector, 0);
    }


// Enforces controlled post-settle reveal:
// Verifies swap exists.
// Allows only trader or whitelisted revealer.
// Rejects already-revealed swap.
// Ensures valid pre-reveal state.
// Enforces block delay gate using decryptReadyBlock.
// Advances state to DecryptReady then to RevealedToAuthorized.
// Emits Revealed with settlement details.

    function revealSwapDetails(uint256 swapId) external override {

        // Verifies swap exists.
        SwapIntent storage intent = _swapIntents[swapId];
        if (intent.trader == address(0)) revert MissingIntent(msg.sender);

//Allows only trader or whitelisted revealer.
        if (msg.sender != intent.trader && !authorizedRevealers[msg.sender]) {
            revert Unauthorized(msg.sender);
        }

// Rejects already-revealed swap.
        if (intent.state == SwapState.RevealedToAuthorized) revert AlreadyRevealed(swapId);

// Ensures valid pre-reveal state.
        if (intent.state != SwapState.SettledPendingReveal && intent.state != SwapState.DecryptReady) {
            revert InvalidState(swapId, SwapState.SettledPendingReveal, intent.state);
        }

        SettlementRecord storage record = _settlementRecords[swapId];

// Enforces block delay gate using decryptReadyBlock.
        // Delay gating gives FHE decryption workflow enough blocks before reveal is allowed.
        if (block.number < record.decryptReadyBlock) {
            revert RevealNotReady(swapId, record.decryptReadyBlock, block.number);
        }

// Advances state to DecryptReady then to RevealedToAuthorized.
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

    function setAuthorizedRevealer(address revealer, bool isAuthorized) external onlyOwner {
        authorizedRevealers[revealer] = isAuthorized;
        emit AuthorizedRevealerSet(revealer, isAuthorized);
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

    function _decodeHookData(bytes calldata hookData) internal pure returns (InEuint128 memory, uint256) {
        if (hookData.length == 0) revert InvalidHookData();
        return abi.decode(hookData, (InEuint128, uint256));
    }
}
