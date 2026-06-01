// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IGhostVault} from "../interface/IGhostVault.sol";
import {IPostSettleReveal} from "../interface/IPostSettleReveal.sol";

/// @title GhostVaultPeriphery
/// @notice Lightweight periphery that queues and executes router call intents on behalf of the vault
/// @dev The periphery preserves caller semantics for the hooked router by delegating execution to `swapRouter`.
///      Authorization is granted to the configured `owner`, the vault owner, and the vault operator.
contract GhostVaultPeriphery {
    using SafeERC20 for IERC20;

    /// @dev Represents a queued router intent submitted by an authorized controller
    struct QueuedIntent {
        address queuedBy; // who queued this intent
        uint256 queuedAtBlock; // block when queued
        uint256 notBeforeBlock; // earliest block allowed to execute
        uint256 deadline; // optional unix timestamp deadline for execution (0 = no deadline)
        uint256 swapId; // Wave 4: swapId for auction gating (0 = no auction gating)
        bytes routerCallData; // calldata forwarded to `swapRouter` on execute
        bool executed; // has the intent been executed
        bool cancelled; // has the intent been cancelled
    }

    // Configuration
    address public immutable swapRouter; // contract that actually executes router semantics
    address public immutable vault; // paired vault address (used for auth checks)
    address public immutable hook; // paired hook address (used for auction gating)
    address public owner; // periphery owner

    // Intent queue
    uint256 public nextIntentId = 1;
    mapping(uint256 => QueuedIntent) internal _queuedIntents;

    error Unauthorized(address caller);
    error ZeroAddress();
    error EmptyCallData();
    error InvalidIntent(uint256 intentId);
    error InvalidDeadline(uint256 deadline, uint256 currentTimestamp);
    error IntentAlreadyHandled(uint256 intentId);
    error IntentTooEarly(uint256 intentId, uint256 notBeforeBlock, uint256 currentBlock);
    error IntentExpired(uint256 intentId, uint256 deadline, uint256 currentTimestamp);
    error NativeTransferFailed();
    error AuctionWinnerMismatch(uint256 swapId, address winner, address caller);

    event OwnerSet(address indexed owner);
    event IntentQueued(
        uint256 indexed intentId,
        address indexed queuedBy,
        bytes32 indexed callDataHash,
        uint256 notBeforeBlock,
        uint256 deadline
    );
    event IntentCancelled(uint256 indexed intentId, address indexed cancelledBy);
    event IntentExecuted(uint256 indexed intentId, address indexed executedBy, bytes32 indexed resultHash);
    event TokenSwept(address indexed token, address indexed receiver, uint256 amount);
    event NativeSwept(address indexed receiver, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyAuthorizedController() {
        if (!_isAuthorized(msg.sender)) revert Unauthorized(msg.sender);
        _;
    }

    /// @param _swapRouter Router contract used to execute queued calldata
    /// @param _vault Paired `GhostVault` address used for auth checks
    /// @param _hook Paired `PostSettleRevealHook` address used for auction gating (Wave 4)
    /// @param _owner Initial owner of the periphery
    constructor(address _swapRouter, address _vault, address _hook, address _owner) {
        if (_swapRouter == address(0) || _vault == address(0) || _hook == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        swapRouter = _swapRouter;
        vault = _vault;
        hook = _hook;
        owner = _owner;

        emit OwnerSet(_owner);
    }

    receive() external payable {}

    /// @notice Queue a router call to be executed later by an authorized controller
    /// @dev `notBeforeBlock` can delay execution until a specific block. `deadline` is optional timestamp.
    ///      For Wave 4 auction-bound intents, pass `swapId` to enable winner-only execution.
    function queueIntent(bytes calldata routerCallData, uint256 notBeforeBlock, uint256 deadline, uint256 swapId)
        external
        onlyAuthorizedController
        returns (uint256 intentId)
    {
        if (routerCallData.length == 0) revert EmptyCallData();
        if (deadline != 0 && deadline < block.timestamp) {
            revert InvalidDeadline(deadline, block.timestamp);
        }

        intentId = nextIntentId++;
        _queuedIntents[intentId] = QueuedIntent({
            queuedBy: msg.sender,
            queuedAtBlock: block.number,
            notBeforeBlock: notBeforeBlock,
            deadline: deadline,
            swapId: swapId,
            routerCallData: routerCallData,
            executed: false,
            cancelled: false
        });

        emit IntentQueued(intentId, msg.sender, keccak256(routerCallData), notBeforeBlock, deadline);
    }

    /// @notice Execute a previously queued intent
    /// @dev Delegates call to `swapRouter` preserving `msg.value`. Reverts with router error on failure.
    ///      For Wave 4 auction-bound intents, enforces that only the auction winner can execute.
    function executeIntent(uint256 intentId)
        external
        payable
        onlyAuthorizedController
        returns (bytes memory resultData)
    {
        QueuedIntent storage intent = _queuedIntents[intentId];
        if (intent.queuedBy == address(0)) revert InvalidIntent(intentId);
        if (intent.executed || intent.cancelled) revert IntentAlreadyHandled(intentId);
        if (block.number < intent.notBeforeBlock) {
            revert IntentTooEarly(intentId, intent.notBeforeBlock, block.number);
        }
        if (intent.deadline != 0 && block.timestamp > intent.deadline) {
            revert IntentExpired(intentId, intent.deadline, block.timestamp);
        }

        // Wave 4: Enforce auction winner-only execution if swapId is set
        if (intent.swapId != 0) {
            (bool bound, address winner,) = IPostSettleReveal(hook).getAuctionExecutionBinding(intent.swapId);
            if (bound && winner != address(0) && msg.sender != winner) {
                revert AuctionWinnerMismatch(intent.swapId, winner, msg.sender);
            }
        }

        intent.executed = true;

        // Intent execution is delegated to the configured router to preserve hook sender semantics.
        (bool success, bytes memory returnData) = swapRouter.call{value: msg.value}(intent.routerCallData);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        emit IntentExecuted(intentId, msg.sender, keccak256(returnData));
        return returnData;
    }

    /// @notice Cancel a queued intent that has not yet been executed
    function cancelIntent(uint256 intentId) external onlyAuthorizedController {
        QueuedIntent storage intent = _queuedIntents[intentId];
        if (intent.queuedBy == address(0)) revert InvalidIntent(intentId);
        if (intent.executed || intent.cancelled) revert IntentAlreadyHandled(intentId);

        intent.cancelled = true;

        emit IntentCancelled(intentId, msg.sender);
    }

    /// @notice Read a queued intent by id
    function getIntent(uint256 intentId) external view returns (QueuedIntent memory) {
        return _queuedIntents[intentId];
    }

    /// @notice Update the periphery owner
    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        owner = newOwner;

        emit OwnerSet(newOwner);
    }

    /// @notice Sweep ERC20 tokens accidentally sent to this contract
    /// @dev Only authorized controllers may perform sweeps (owner / vault owner / vault operator)
    function sweepToken(address token, address receiver, uint256 amount) external onlyAuthorizedController {
        if (token == address(0) || receiver == address(0)) revert ZeroAddress();

        IERC20(token).safeTransfer(receiver, amount);

        emit TokenSwept(token, receiver, amount);
    }

    /// @notice Sweep native ETH accidentally sent to this contract
    function sweepNative(address payable receiver, uint256 amount) external onlyAuthorizedController {
        if (receiver == address(0)) revert ZeroAddress();

        (bool success,) = receiver.call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit NativeSwept(receiver, amount);
    }

    /// @notice Query whether `account` is authorized to control intents
    function isAuthorized(address account) external view returns (bool) {
        return _isAuthorized(account);
    }

    /// @dev Internal helper: owner || vault.owner() || vault.operator() are authorized
    function _isAuthorized(address account) internal view returns (bool) {
        if (account == owner) return true;
        if (account == IGhostVault(vault).owner()) return true;

        address vaultOperator = IGhostVault(vault).operator();
        return vaultOperator != address(0) && account == vaultOperator;
    }
}
