export const POST_SETTLE_REVEAL_ABI = [
  "function nextSwapId() view returns (uint256)",
  "function getSwapIntent(uint256 swapId) view returns (address trader, bytes32 poolId, uint256 nonce, uint256 createdAtBlock, uint8 state)",
  "function getSettlementRecord(uint256 swapId) view returns (uint256 recordSwapId, int128 delta0, int128 delta1, int256 amountSpecified, uint256 settledAtBlock, uint256 decryptReadyBlock)",
  "function revealSwapDetails(uint256 swapId)",
  "function setAuthorizedRevealer(address revealer, bool isAuthorized)",
  "event IntentCaptured(uint256 indexed swapId, address indexed trader, bytes32 indexed poolId, uint256 nonce, uint256 createdAtBlock)",
  "event SettlementRecorded(uint256 indexed swapId, address indexed trader, int128 delta0, int128 delta1, int256 amountSpecified, uint256 settledAtBlock)",
  "event RevealReady(uint256 indexed swapId, address indexed trader, uint256 decryptReadyBlock)",
  "event Revealed(uint256 indexed swapId, address indexed caller, address indexed trader, int128 delta0, int128 delta1, int256 amountSpecified, uint256 settledAtBlock)",
];
