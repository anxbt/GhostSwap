// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IGhostVault} from "./interface/IGhostVault.sol";

/// @title GhostVault
/// @notice Vault that holds a single ERC20 asset and attributes surplus (from the paired hook)
///         to depositors using a cumulative-per-share accounting model.
/// @dev Integrates with `PostSettleRevealHook` via `recordSurplus`. Implements `IERC1271`
///      so the vault can act as an on-chain/trusted contract-trader when needed.
contract GhostVault is IGhostVault, IERC1271 {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e18;
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant EIP1271_INVALID_VALUE = 0xffffffff;

    IERC20 public immutable asset;
    address public immutable hook;
    address public owner;
    address public operator;

    uint256 public totalShares;
    uint256 public totalManagedAssets;
    uint256 public totalSurplusCaptured;
    uint256 public totalSurplusClaimed;
    uint256 public cumulativeSurplusPerShareX18;

    // Shares and surplus accounting
    // - `shares[acct]` : number of vault shares held by account
    // - `rewardDebtX18[acct]` : tracks the account's last-observed accrued surplus (scaled by 1e18)
    // - `unclaimedSurplus[acct]` : surplus already materialized and awaiting claim
    // - `surplusRecordedForSwap[swapId]` : tracks which swaps have had their surplus recorded (idempotency)
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebtX18;
    mapping(address => uint256) public unclaimedSurplus;
    mapping(uint256 => bool) public surplusRecordedForSwap;

    error Unauthorized(address caller);
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares(address owner, uint256 requestedShares, uint256 availableShares);
    error InvalidTrader(address trader);
    error NoSharesOutstanding();
    error SurplusAlreadyRecorded(uint256 swapId);

    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdrawn(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event SurplusRecorded(
        uint256 indexed swapId,
        uint256 surplusAmount,
        uint256 totalSurplusCaptured,
        uint256 cumulativeSurplusPerShareX18
    );
    event SurplusClaimed(address indexed account, address indexed receiver, uint256 amount);
    event OwnerSet(address indexed owner);
    event OperatorSet(address indexed operator);

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    /// @notice Construct a new `GhostVault`
    /// @param _asset The ERC20 asset held by the vault
    /// @param _hook The trusted hook address that will forward surplus
    constructor(address _asset, address _hook) {
        if (_asset == address(0) || _hook == address(0)) revert ZeroAddress();
        asset = IERC20(_asset);
        hook = _hook;
        owner = msg.sender;

        emit OwnerSet(msg.sender);
    }

    /// @notice Returns current ERC20 token balance held by the vault
    /// @dev This may include both principal and unclaimed surplus sitting in the contract
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Convert an `assets` amount (ERC20 units) into vault share units
    /// @dev When vault is empty the conversion is 1:1. Uses `totalManagedAssets`/`totalShares` snapshot.
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (assets == 0) return 0;

        uint256 cachedTotalShares = totalShares;
        uint256 cachedManagedAssets = totalManagedAssets;

        if (cachedTotalShares == 0 || cachedManagedAssets == 0) {
            return assets;
        }

        return assets * cachedTotalShares / cachedManagedAssets;
    }

    /// @notice Convert `shareAmount` into underlying ERC20 assets according to current accounting
    function convertToAssets(uint256 shareAmount) public view returns (uint256) {
        if (shareAmount == 0) return 0;

        uint256 cachedTotalShares = totalShares;
        uint256 cachedManagedAssets = totalManagedAssets;

        if (cachedTotalShares == 0 || cachedManagedAssets == 0) {
            return shareAmount;
        }

        return shareAmount * cachedManagedAssets / cachedTotalShares;
    }

    /// @notice Deposit `assets` (ERC20) and receive vault shares credited to `receiver`
    /// @dev Caller must approve tokens prior to calling. `_syncAccount` updates claimable surplus
    ///      for `receiver` before changing their shares position.
    function deposit(uint256 assets, address receiver) external returns (uint256 mintedShares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _syncAccount(receiver);

        uint256 cachedManagedAssets = totalManagedAssets;
        uint256 cachedTotalShares = totalShares;

        asset.safeTransferFrom(msg.sender, address(this), assets);

        if (cachedTotalShares == 0 || cachedManagedAssets == 0) {
            mintedShares = assets;
        } else {
            mintedShares = assets * cachedTotalShares / cachedManagedAssets;
        }

        if (mintedShares == 0) revert ZeroAmount();

        shares[receiver] += mintedShares;
        totalShares = cachedTotalShares + mintedShares;
        totalManagedAssets = cachedManagedAssets + assets;
        rewardDebtX18[receiver] = _accruedSurplus(receiver);

        emit Deposited(msg.sender, receiver, assets, mintedShares);
    }

    /// @notice Withdraws underlying assets by burning `shareAmount` from `ownerAddress` and
    ///         transfers tokens to `receiver`.
    /// @dev Requires `msg.sender == ownerAddress` (external caller acts on behalf of the owner).
    function withdraw(uint256 shareAmount, address receiver, address ownerAddress)
        external
        returns (uint256 assetsOut)
    {
        if (shareAmount == 0) revert ZeroAmount();
        if (receiver == address(0) || ownerAddress == address(0)) revert ZeroAddress();
        if (msg.sender != ownerAddress) revert Unauthorized(msg.sender);

        uint256 ownerShares = shares[ownerAddress];
        if (ownerShares < shareAmount) {
            revert InsufficientShares(ownerAddress, shareAmount, ownerShares);
        }

        _syncAccount(ownerAddress);

        assetsOut = convertToAssets(shareAmount);
        if (assetsOut == 0) revert ZeroAmount();

        shares[ownerAddress] = ownerShares - shareAmount;
        totalShares -= shareAmount;
        totalManagedAssets -= assetsOut;
        rewardDebtX18[ownerAddress] = _accruedSurplus(ownerAddress);

        asset.safeTransfer(receiver, assetsOut);

        emit Withdrawn(msg.sender, receiver, ownerAddress, assetsOut, shareAmount);
    }

    /// @notice Record surplus captured from a settled swap
    /// @dev Only callable by the trusted `hook`. `trader` must be this vault (hook forwards surplus to vault address).
    ///      Idempotent: will revert if surplus is recorded twice for the same swapId (prevents accounting errors).
    function recordSurplus(uint256 swapId, uint256 surplusAmount, address trader) external onlyHook {
        if (trader != address(this)) revert InvalidTrader(trader);
        if (surplusRecordedForSwap[swapId]) revert SurplusAlreadyRecorded(swapId);
        if (surplusAmount > 0 && totalShares == 0) revert NoSharesOutstanding();

        // Mark as recorded to prevent double-recording
        surplusRecordedForSwap[swapId] = true;

        totalSurplusCaptured += surplusAmount;

        if (surplusAmount > 0 && totalShares > 0) {
            // accumulate scaled surplus per share
            cumulativeSurplusPerShareX18 += surplusAmount * PRECISION / totalShares;
        }

        emit SurplusRecorded(swapId, surplusAmount, totalSurplusCaptured, cumulativeSurplusPerShareX18);
    }

    /// @notice Claim all currently unclaimed surplus for caller and transfer to `receiver`
    /// @dev `_syncAccount` ensures accrued-but-unmaterialized surplus is moved to `unclaimedSurplus`.
    function claimSurplus(address receiver) external returns (uint256 claimedAmount) {
        if (receiver == address(0)) revert ZeroAddress();

        _syncAccount(msg.sender);

        claimedAmount = unclaimedSurplus[msg.sender];
        if (claimedAmount == 0) return 0;

        unclaimedSurplus[msg.sender] = 0;
        totalSurplusClaimed += claimedAmount;
        asset.safeTransfer(receiver, claimedAmount);

        emit SurplusClaimed(msg.sender, receiver, claimedAmount);
    }

    function surplusAttributionOf(address account) external view returns (uint256) {
        return shares[account] * cumulativeSurplusPerShareX18 / PRECISION;
    }

    function claimableSurplusOf(address account) external view returns (uint256) {
        uint256 debt = rewardDebtX18[account];
        uint256 accrued = _accruedSurplus(account);

        if (accrued <= debt) {
            return unclaimedSurplus[account];
        }

        return unclaimedSurplus[account] + (accrued - debt);
    }

    function setOperator(address newOperator) external onlyOwner {
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        (address recovered, ECDSA.RecoverError recoverError,) = ECDSA.tryRecover(hash, signature);

        if (recoverError == ECDSA.RecoverError.NoError && (recovered == owner || recovered == operator)) {
            return EIP1271_MAGIC_VALUE;
        }

        return EIP1271_INVALID_VALUE;
    }

    /// @dev Syncs `account` by calculating newly-accrued surplus and moving it to `unclaimedSurplus`.
    function _syncAccount(address account) internal {
        uint256 debt = rewardDebtX18[account];
        uint256 accrued = _accruedSurplus(account);

        if (accrued > debt) {
            unclaimedSurplus[account] += accrued - debt;
        }

        rewardDebtX18[account] = accrued;
    }

    /// @dev Compute the account's accrued surplus (shares * cumulativePerShareX18 / PRECISION)
    function _accruedSurplus(address account) internal view returns (uint256) {
        return shares[account] * cumulativeSurplusPerShareX18 / PRECISION;
    }
}
