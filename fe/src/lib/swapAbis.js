export const POOL_SWAP_TEST_ABI = [
  "function manager() view returns (address)",
  "function swap((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,(bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96) params,(bool takeClaims,bool settleUsingBurn) testSettings,bytes hookData) payable returns (int256)"
];

export const MOCK_ZK_VERIFIER_ABI = [
  "function exists() view returns (bool)",
  "function zkVerifyCalcCtHash(uint256 value,uint8 utype,address user,uint8 securityZone,uint256 chainId) view returns (uint256)",
  "function insertCtHash(uint256 ctHash,uint256 value)"
];

export const MOCK_ZK_VERIFIER_SIGNER_ABI = [
  "function zkVerifySign((uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) input,address sender) view returns ((uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature))"
];
