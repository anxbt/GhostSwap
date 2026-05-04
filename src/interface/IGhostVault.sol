// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGhostVault {
    function owner() external view returns (address);
    function operator() external view returns (address);

    function recordSurplus(uint256 swapId, uint256 surplusAmount, address trader) external;
    function claimSurplus(address receiver) external returns (uint256 claimedAmount);
    function claimableSurplusOf(address account) external view returns (uint256);
    function setOperator(address newOperator) external;
    function setOwner(address newOwner) external;
}
