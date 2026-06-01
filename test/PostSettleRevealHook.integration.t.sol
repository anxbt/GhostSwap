// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Deployers} from "./utils/Deployers.sol";

import {InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";

import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {IPostSettleReveal} from "../src/interface/IPostSettleReveal.sol";

contract PostSettleRevealHookIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant REVEAL_DELAY = 11;
    uint256 internal constant INTENT_DEADLINE_WINDOW = 30 minutes;
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant INTENT_AUTHORIZATION_TYPEHASH = keccak256(
        "IntentAuthorization(address trader,address sender,bytes32 poolId,uint256 nonce,uint256 deadline,uint256 ctHash)"
    );

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

    CoFheTest internal cft;
    PostSettleRevealHook internal hook;

    uint256 internal traderPk = uint256(keccak256("ghostswap-integration-trader"));
    address internal trader;
    uint256 internal cofheVerifierPk = uint256(keccak256("cofhe-verifier"));
    address internal cofheVerifier;

    function setUp() public {
        cft = new CoFheTest(false);
        trader = vm.addr(traderPk);
        cofheVerifier = vm.addr(cofheVerifierPk);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x6666 << 144));
        bytes memory constructorArgs = abi.encode(manager, REVEAL_DELAY, address(this), cofheVerifier);
        deployCodeTo("PostSettleRevealHook.sol:PostSettleRevealHook", constructorArgs, flags);
        hook = PostSettleRevealHook(flags);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        currency0.transfer(trader, 100e18);
        currency1.transfer(trader, 100e18);
        _setApprovalsFor(trader, address(Currency.unwrap(currency0)));
        _setApprovalsFor(trader, address(Currency.unwrap(currency1)));
    }

    function test_routerSwapFlowTriggersHookLifecycle() public {
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes memory hookData = _buildHookData(1, 1, address(manager), address(swapRouter), trader, traderPk, poolId);

        vm.recordLogs();

        vm.prank(trader);
        swap(key, true, -1e6, hookData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_hasEvent(logs, keccak256("IntentCaptured(uint256,address,bytes32,uint256,uint256)"), address(hook)));
        assertTrue(
            _hasEvent(logs, keccak256("SettlementRecorded(uint256,address,int128,int128,int256,uint256)"), address(hook))
        );
        assertTrue(_hasEvent(logs, keccak256("RevealReady(uint256,address,uint256)"), address(hook)));

        (address intentTrader, , , , IPostSettleReveal.SwapState stateAfterSwap) = hook.getSwapIntent(1);
        assertEq(intentTrader, trader);
        assertEq(uint256(stateAfterSwap), uint256(IPostSettleReveal.SwapState.SettledPendingReveal));

        (, int128 delta0, int128 delta1, int256 amountSpecified, uint256 settledAtBlock, uint256 readyBlock) =
            hook.getSettlementRecord(1);

        assertEq(amountSpecified, -1e6);
        assertTrue(delta0 != 0 || delta1 != 0);
        assertEq(readyBlock, settledAtBlock + REVEAL_DELAY);

        vm.expectRevert(abi.encodeWithSignature("RevealNotReady(uint256,uint256,uint256)", 1, readyBlock, block.number));
        vm.prank(trader);
        hook.revealSwapDetails(1);

        vm.roll(readyBlock);
        vm.warp(block.timestamp + 11);

        vm.recordLogs();

        vm.prank(trader);
        hook.revealSwapDetails(1);

        logs = vm.getRecordedLogs();
        assertTrue(_hasEvent(logs, keccak256("Revealed(uint256,address,address,int128,int128,int256,uint256)"), address(hook)));

        (, , , , IPostSettleReveal.SwapState finalState) = hook.getSwapIntent(1);
        assertEq(uint256(finalState), uint256(IPostSettleReveal.SwapState.RevealedToAuthorized));

        assertTrue(delta0 != 0 || delta1 != 0);
        assertEq(amountSpecified, -1e6);
        assertEq(readyBlock, settledAtBlock + REVEAL_DELAY);
    }

    function _setApprovalsFor(address user, address token) internal {
        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            vm.prank(user);
            MockERC20(token).approve(toApprove[i], Constants.MAX_UINT256);
        }
    }

    function _buildHookData(
        uint128 minOutPlaintext,
        uint256 nonce,
        address encryptionSigner,
        address sender,
        address traderAddress,
        uint256 traderPrivateKey,
        bytes32 poolId
    ) internal returns (bytes memory) {
        InEuint128 memory minOut = cft.createInEuint128(minOutPlaintext, encryptionSigner);
        uint256 deadline = block.timestamp + INTENT_DEADLINE_WINDOW;
        bytes32 digest = _intentDigest(traderAddress, sender, poolId, nonce, deadline, minOut.ctHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        return abi.encode(minOut, nonce, traderAddress, deadline, signature);
    }

    function _intentDigest(
        address traderAddress,
        address sender,
        bytes32 poolId,
        uint256 nonce,
        uint256 deadline,
        uint256 ctHash
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(INTENT_AUTHORIZATION_TYPEHASH, traderAddress, sender, poolId, nonce, deadline, ctHash)
        );

        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("GhostSwapIntent")),
                keccak256(bytes("1")),
                block.chainid,
                address(hook)
            )
        );
    }

    function _hasEvent(Vm.Log[] memory logs, bytes32 topic0, address emitter) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return true;
            }
        }
        return false;
    }
}
