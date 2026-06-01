// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {GhostVault} from "../src/GhostVault.sol";
import {GhostVaultPeriphery} from "../src/periphery/GhostVaultPeriphery.sol";

import {Constants} from "./base/Constants.sol";

/// @notice Deploys GhostSwap contracts to Arbitrum Sepolia (chainId 421614)
/// @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
contract DeployScript is Script, Constants {
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant STARTING_PRICE = 79228162514264337593543950336; // 1:1

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        uint256 revealDelayBlocks = vm.envOr("REVEAL_DELAY_BLOCKS", uint256(15));
        address hookOwner = vm.envOr("HOOK_OWNER", deployer);
        address cofheVerifier = vm.envAddress("COFHE_VERIFIER_ADDRESS");

        console2.log("Deploying GhostSwap to Arbitrum Sepolia...");
        console2.log("Deployer:", deployer);
        console2.log("Hook owner:", hookOwner);
        console2.log("CoFHE verifier:", cofheVerifier);
        console2.log("Reveal delay blocks:", revealDelayBlocks);

        vm.startBroadcast(deployerPk);

        // 1. Deploy PostSettleRevealHook
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(POOLMANAGER)),
            revealDelayBlocks,
            hookOwner,
            cofheVerifier
        );
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PostSettleRevealHook).creationCode, constructorArgs);

        PostSettleRevealHook hook = new PostSettleRevealHook{salt: salt}(
            IPoolManager(address(POOLMANAGER)), revealDelayBlocks, hookOwner, cofheVerifier
        );
        require(address(hook) == expectedHookAddress, "DeployScript: hook address mismatch");
        console2.log("PostSettleRevealHook deployed at:", address(hook));

        // 2. Deploy GhostVault (token1 as asset)
        address token1 = vm.envAddress("VAULT_ASSET_TOKEN");
        GhostVault vault = new GhostVault(token1, address(hook));
        console2.log("GhostVault deployed at:", address(vault));

        // 3. Deploy GhostVaultPeriphery
        address swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        require(swapRouter != address(0), "DeployScript: SWAP_ROUTER env var required");
        GhostVaultPeriphery periphery = new GhostVaultPeriphery(swapRouter, address(vault), address(hook), hookOwner);
        console2.log("GhostVaultPeriphery deployed at:", address(periphery));

        // 4. Wire: set surplus vault on hook
        hook.setSurplusVault(address(vault));
        console2.log("Surplus vault set to:", address(vault));

        // 5. Wire: set vault operator to periphery
        vault.setOperator(address(periphery));
        console2.log("Vault operator set to:", address(periphery));

        // 6. Optionally: set deployer as authorized revealer
        hook.setAuthorizedRevealer(deployer, true);
        console2.log("Deployer set as authorized revealer");

        vm.stopBroadcast();

        // Write deployment addresses to JSON
        string memory json = "deployment";
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeAddress(json, "vault", address(vault));
        vm.serializeAddress(json, "periphery", address(periphery));
        vm.serializeAddress(json, "poolManager", address(POOLMANAGER));
        vm.serializeAddress(json, "swapRouter", swapRouter);
        vm.serializeAddress(json, "cofheVerifier", cofheVerifier);
        vm.serializeUint(json, "revealDelayBlocks", revealDelayBlocks);
        vm.serializeAddress(json, "deployer", deployer);
        string memory finalJson = vm.serializeString(json, "chain", "arbitrum-sepolia");

        string memory outputPath = string.concat(vm.projectRoot(), "/deployments/arbitrum-sepolia.json");
        vm.writeFile(outputPath, finalJson);
        console2.log("Deployment addresses written to:", outputPath);
    }
}