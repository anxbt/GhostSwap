// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {GhostVault} from "../src/GhostVault.sol";
import {GhostVaultPeriphery} from "../src/periphery/GhostVaultPeriphery.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Constants} from "./base/Constants.sol";

/// @notice Full-stack GhostSwap deployment to Arbitrum Sepolia (chainId 421614).
/// @dev Unlike Deploy.s.sol (bare protocol), this also deploys test tokens, a PoolSwapTest router
///      (the ABI the frontend speaks), initializes the v4 pool, seeds liquidity, and writes both
///      deployments/arbitrum-sepolia.json and fe/.env. Uses the canonical Sepolia PoolManager and
///      the live Fhenix CoFHE coprocessor (no mocks).
/// @dev Usage:
///      forge script script/DeploySepolia.s.sol:DeploySepoliaScript --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
contract DeploySepoliaScript is Script, Constants {
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant STARTING_PRICE = 79228162514264337593543950336; // 1:1

    struct Deployed {
        address hook;
        address vault;
        address periphery;
        address swapRouter;
        address token0;
        address token1;
    }

    function run() external {
        require(block.chainid == 421614, "DeploySepolia: expected chain id 421614 (Arbitrum Sepolia)");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        uint256 revealDelayBlocks = vm.envOr("REVEAL_DELAY_BLOCKS", uint256(15));
        address hookOwner = vm.envOr("HOOK_OWNER", deployer);
        // publishDecryptResult is off the demo critical path (legacy reveal), so a placeholder
        // (the deployer) is acceptable. Override with COFHE_VERIFIER_ADDRESS for the real verifier.
        address cofheVerifier = vm.envOr("COFHE_VERIFIER_ADDRESS", deployer);

        console2.log("Deploying GhostSwap full stack to Arbitrum Sepolia...");
        console2.log("Deployer:", deployer);
        console2.log("Hook owner:", hookOwner);
        console2.log("CoFHE verifier:", cofheVerifier);
        console2.log("PoolManager (canonical):", address(POOLMANAGER));
        console2.log("Reveal delay blocks:", revealDelayBlocks);

        vm.startBroadcast(deployerPk);
        Deployed memory d = _deploy(deployer, hookOwner, cofheVerifier, revealDelayBlocks);
        vm.stopBroadcast();

        _writeDeploymentJson(d, cofheVerifier, revealDelayBlocks, deployer);
        _writeFrontendEnv(d, deployer);

        console2.log("\nDeployment complete.");
        console2.log("Hook:", d.hook);
        console2.log("Vault:", d.vault);
        console2.log("Periphery:", d.periphery);
        console2.log("SwapRouter (PoolSwapTest):", d.swapRouter);
        console2.log("Token0:", d.token0);
        console2.log("Token1:", d.token1);
    }

    function _deploy(address deployer, address hookOwner, address cofheVerifier, uint256 revealDelayBlocks)
        internal
        returns (Deployed memory out)
    {
        // 1. Test tokens
        MockERC20 tokenA = new MockERC20("Ghost ETH", "gETH", 18);
        MockERC20 tokenB = new MockERC20("Ghost USDC", "gUSDC", 18);
        (MockERC20 token0, MockERC20 token1) =
            uint160(address(tokenA)) < uint160(address(tokenB)) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);

        // 2. Routers (PoolSwapTest is the ABI the frontend uses)
        PoolSwapTest swapRouter = new PoolSwapTest(POOLMANAGER);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(POOLMANAGER);

        // 3. Hook (mined for v4 permission bits)
        address hook = _deployHook(hookOwner, cofheVerifier, revealDelayBlocks);

        // 4. Vault + periphery, wired
        GhostVault vault = new GhostVault(address(token1), hook);
        GhostVaultPeriphery periphery =
            new GhostVaultPeriphery(address(swapRouter), address(vault), hook, hookOwner);
        vault.setOperator(address(periphery));
        PostSettleRevealHook(hook).setSurplusVault(address(vault));
        PostSettleRevealHook(hook).setAuthorizedRevealer(deployer, true);

        // 5. Pool + liquidity
        _initPoolAndLiquidity(lpRouter, token0, token1, hook);

        out = Deployed({
            hook: hook,
            vault: address(vault),
            periphery: address(periphery),
            swapRouter: address(swapRouter),
            token0: address(token0),
            token1: address(token1)
        });
    }

    function _deployHook(address hookOwner, address cofheVerifier, uint256 revealDelayBlocks)
        internal
        returns (address)
    {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(POOLMANAGER, revealDelayBlocks, hookOwner, cofheVerifier);
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PostSettleRevealHook).creationCode, constructorArgs);

        PostSettleRevealHook hook =
            new PostSettleRevealHook{salt: salt}(POOLMANAGER, revealDelayBlocks, hookOwner, cofheVerifier);
        require(address(hook) == expectedHookAddress, "DeploySepolia: hook address mismatch");
        return address(hook);
    }

    function _initPoolAndLiquidity(PoolModifyLiquidityTest lpRouter, MockERC20 token0, MockERC20 token1, address hook)
        internal
    {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        POOLMANAGER.initialize(poolKey, STARTING_PRICE);

        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        ModifyLiquidityParams memory liq = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: int256(100 ether),
            salt: bytes32(0)
        });
        lpRouter.modifyLiquidity(poolKey, liq, "");
    }

    function _writeDeploymentJson(
        Deployed memory d,
        address cofheVerifier,
        uint256 revealDelayBlocks,
        address deployer
    ) internal {
        string memory json = "deployment";
        vm.serializeAddress(json, "hook", d.hook);
        vm.serializeAddress(json, "vault", d.vault);
        vm.serializeAddress(json, "periphery", d.periphery);
        vm.serializeAddress(json, "poolManager", address(POOLMANAGER));
        vm.serializeAddress(json, "swapRouter", d.swapRouter);
        vm.serializeAddress(json, "token0", d.token0);
        vm.serializeAddress(json, "token1", d.token1);
        vm.serializeAddress(json, "cofheVerifier", cofheVerifier);
        vm.serializeUint(json, "revealDelayBlocks", revealDelayBlocks);
        vm.serializeAddress(json, "deployer", deployer);
        string memory finalJson = vm.serializeString(json, "chain", "arbitrum-sepolia");

        string memory outputPath = string.concat(vm.projectRoot(), "/deployments/arbitrum-sepolia.json");
        vm.writeFile(outputPath, finalJson);
        console2.log("Deployment addresses written to:", outputPath);
    }

    function _writeFrontendEnv(Deployed memory d, address deployer) internal {
        string memory env = "VITE_CHAIN_ID=421614\n";
        env = string.concat(env, "VITE_POST_SETTLE_HOOK=", vm.toString(d.hook), "\n");
        env = string.concat(env, "VITE_VAULT_ADDRESS=", vm.toString(d.vault), "\n");
        env = string.concat(env, "VITE_VAULT_PERIPHERY=", vm.toString(d.periphery), "\n");
        env = string.concat(env, "VITE_SWAP_ROUTER=", vm.toString(d.swapRouter), "\n");
        env = string.concat(env, "VITE_POOL_MANAGER=", vm.toString(address(POOLMANAGER)), "\n");
        env = string.concat(env, "VITE_INTENT_DEADLINE_SECONDS=1200\n");
        env = string.concat(env, "VITE_POOL_TOKEN0=", vm.toString(d.token0), "\n");
        env = string.concat(env, "VITE_POOL_TOKEN1=", vm.toString(d.token1), "\n");
        env = string.concat(env, "VITE_POOL_FEE=3000\n");
        env = string.concat(env, "VITE_POOL_TICK_SPACING=60\n");
        env = string.concat(env, "VITE_SWAP_TAKE_CLAIMS=false\n");
        env = string.concat(env, "VITE_SWAP_SETTLE_USING_BURN=false\n");
        env = string.concat(env, "VITE_TOKEN_ETH=", vm.toString(d.token0), "\n");
        env = string.concat(env, "VITE_TOKEN_ETH_DECIMALS=18\n");
        env = string.concat(env, "VITE_TOKEN_USDC=", vm.toString(d.token1), "\n");
        env = string.concat(env, "VITE_TOKEN_USDC_DECIMALS=18\n");
        env = string.concat(env, "# Demo deployer\n");
        env = string.concat(env, "# ", vm.toString(deployer), "\n");

        string memory envPath = string.concat(vm.projectRoot(), "/fe/.env");
        vm.writeFile(envPath, env);
        console2.log("Frontend env written to:", envPath);
    }
}
