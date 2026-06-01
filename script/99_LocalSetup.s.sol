// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {GhostVault} from "../src/GhostVault.sol";
import {GhostVaultPeriphery} from "../src/periphery/GhostVaultPeriphery.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {TaskManager} from "@fhenixprotocol/cofhe-foundry-mocks/MockTaskManager.sol";
import {ACL} from "@fhenixprotocol/cofhe-foundry-mocks/ACL.sol";
import {MockZkVerifier} from "@fhenixprotocol/cofhe-foundry-mocks/MockZkVerifier.sol";
import {MockZkVerifierSigner} from "@fhenixprotocol/cofhe-foundry-mocks/MockZkVerifierSigner.sol";
import {TASK_MANAGER_ADDRESS} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SIGNER_ADDRESS} from "@fhenixprotocol/cofhe-foundry-mocks/MockCoFHE.sol";

contract LocalSetupScript is Script {
    using CurrencyLibrary for Currency;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant STARTING_PRICE = 79228162514264337593543950336;

    struct CofheAddrs {
        address taskManager;
        address acl;
        address zkVerifier;
        address zkVerifierSigner;
    }

    struct DexAddrs {
        address manager;
        address swapRouter;
        address hook;
        address vault;
        address vaultPeriphery;
        address token0;
        address token1;
    }

    function _anvilSetCode(address target, bytes memory runtimeCode) internal {
        vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '","', vm.toString(runtimeCode), '"]'));
    }

    function _getArtifactRuntimeCode(string memory artifactPath) internal view returns (bytes memory) {
        string memory artifactJson = vm.readFile(string.concat(vm.projectRoot(), "/out/", artifactPath, ".json"));
        return vm.parseJsonBytes(artifactJson, ".deployedBytecode.object");
    }

    function run() external {
        // This script is intended for local Anvil development only.
        require(block.chainid == 31337, "LocalSetupScript: expected chain id 31337");

        address owner = vm.envOr("LOCAL_SETUP_OWNER", address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266));

        vm.startBroadcast();
        CofheAddrs memory cofhe = _deployCofhe(owner);
        DexAddrs memory dex = _deployDex(owner, cofhe.zkVerifierSigner);
        vm.stopBroadcast();

        _writeFrontendEnv(owner, dex.hook, dex.vault, dex.vaultPeriphery, dex.swapRouter, dex.token0, dex.token1);

        console2.log("\nLocal setup complete.");
        console2.log("TASK_MANAGER_ADDRESS:", cofhe.taskManager);
        console2.log("ACL proxy:", cofhe.acl);
        console2.log("MockZkVerifier:", cofhe.zkVerifier);
        console2.log("MockZkVerifierSigner:", cofhe.zkVerifierSigner);
        console2.log("PoolManager:", dex.manager);
        console2.log("SwapRouter:", dex.swapRouter);
        console2.log("PostSettleRevealHook:", dex.hook);
        console2.log("GhostVault:", dex.vault);
        console2.log("GhostVaultPeriphery:", dex.vaultPeriphery);
        console2.log("Token0:", dex.token0);
        console2.log("Token1:", dex.token1);
        console2.log("Funded owner:", owner);
    }

    function _deployCofhe(address owner) internal returns (CofheAddrs memory out) {
        _anvilSetCode(TASK_MANAGER_ADDRESS, _getArtifactRuntimeCode("MockTaskManager.sol/TaskManager"));

        TaskManager taskManager = TaskManager(TASK_MANAGER_ADDRESS);
        taskManager.initialize(owner);
        taskManager.setSecurityZones(0, 1);
        taskManager.setVerifierSigner(SIGNER_ADDRESS);

        ACL aclImplementation = new ACL();
        bytes memory aclInitData = abi.encodeWithSelector(ACL.initialize.selector, owner);
        ERC1967Proxy aclProxy = new ERC1967Proxy(address(aclImplementation), aclInitData);
        ACL acl = ACL(address(aclProxy));
        taskManager.setACLContract(address(acl));

        MockZkVerifier zkVerifier = new MockZkVerifier();
        MockZkVerifierSigner zkVerifierSigner = new MockZkVerifierSigner();

        out = CofheAddrs({
            taskManager: TASK_MANAGER_ADDRESS,
            acl: address(acl),
            zkVerifier: address(zkVerifier),
            zkVerifierSigner: address(zkVerifierSigner)
        });
    }

    function _deployDex(address owner, address cofheVerifier) internal returns (DexAddrs memory out) {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(0))));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);

        MockERC20 tokenA = new MockERC20("MockA", "MKA", 18);
        MockERC20 tokenB = new MockERC20("MockB", "MKB", 18);
        (MockERC20 token0, MockERC20 token1) =
            uint160(address(tokenA)) < uint160(address(tokenB)) ? (tokenA, tokenB) : (tokenB, tokenA);

        token0.mint(owner, 100_000 ether);
        token1.mint(owner, 100_000 ether);
        address hook = _deployHook(manager, owner, cofheVerifier);
        GhostVault vault = new GhostVault(address(token1), hook);
        GhostVaultPeriphery periphery = new GhostVaultPeriphery(address(swapRouter), address(vault), hook, owner);

        vault.setOperator(address(periphery));

        PostSettleRevealHook(hook).setSurplusVault(address(vault));
        PostSettleRevealHook(hook).setAuthorizedRevealer(owner, true);
        _initPoolAndLiquidity(manager, lpRouter, token0, token1, hook);

        out = DexAddrs({
            manager: address(manager),
            swapRouter: address(swapRouter),
            hook: hook,
            vault: address(vault),
            vaultPeriphery: address(periphery),
            token0: address(token0),
            token1: address(token1)
        });
    }

    function _deployHook(IPoolManager manager, address owner, address cofheVerifier) internal returns (address) {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(manager, uint256(11), owner, cofheVerifier);
        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PostSettleRevealHook).creationCode, constructorArgs);

        PostSettleRevealHook hook = new PostSettleRevealHook{salt: salt}(manager, 11, owner, cofheVerifier);
        require(address(hook) == expectedHookAddress, "LocalSetupScript: hook address mismatch");
        return address(hook);
    }

    function _initPoolAndLiquidity(
        IPoolManager manager,
        PoolModifyLiquidityTest lpRouter,
        MockERC20 token0,
        MockERC20 token1,
        address hook
    ) internal {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        manager.initialize(poolKey, STARTING_PRICE);

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

    function _writeFrontendEnv(
        address owner,
        address hook,
        address vault,
        address vaultPeriphery,
        address swapRouter,
        address token0,
        address token1
    ) internal {
        string memory envBody = "VITE_CHAIN_ID=31337\n";
        envBody = string.concat(envBody, "VITE_POST_SETTLE_HOOK=", vm.toString(hook), "\n");
        envBody = string.concat(envBody, "VITE_VAULT_ADDRESS=", vm.toString(vault), "\n");
        envBody = string.concat(envBody, "VITE_VAULT_PERIPHERY=", vm.toString(vaultPeriphery), "\n");
        envBody = string.concat(envBody, "VITE_SWAP_ROUTER=", vm.toString(swapRouter), "\n");
        envBody = string.concat(envBody, "VITE_INTENT_DEADLINE_SECONDS=1200\n");
        envBody = string.concat(envBody, "VITE_POOL_TOKEN0=", vm.toString(token0), "\n");
        envBody = string.concat(envBody, "VITE_POOL_TOKEN1=", vm.toString(token1), "\n");
        envBody = string.concat(envBody, "VITE_POOL_FEE=3000\n");
        envBody = string.concat(envBody, "VITE_POOL_TICK_SPACING=60\n");
        envBody = string.concat(envBody, "VITE_SWAP_TAKE_CLAIMS=false\n");
        envBody = string.concat(envBody, "VITE_SWAP_SETTLE_USING_BURN=false\n");
        envBody = string.concat(envBody, "VITE_TOKEN_ETH=", vm.toString(token0), "\n");
        envBody = string.concat(envBody, "VITE_TOKEN_ETH_DECIMALS=18\n");
        envBody = string.concat(envBody, "VITE_TOKEN_USDC=", vm.toString(token1), "\n");
        envBody = string.concat(envBody, "VITE_TOKEN_USDC_DECIMALS=18\n");
        envBody = string.concat(envBody, "VITE_TOKEN_WBTC=", vm.toString(token0), "\n");
        envBody = string.concat(envBody, "VITE_TOKEN_WBTC_DECIMALS=18\n");
        envBody = string.concat(envBody, "VITE_TOKEN_ARB=", vm.toString(token1), "\n");
        envBody = string.concat(envBody, "VITE_TOKEN_ARB_DECIMALS=18\n");
        envBody = string.concat(envBody, "# Demo wallet funded by setup\n");
        envBody = string.concat(envBody, "# ", vm.toString(owner), "\n");

        string memory envPath = string.concat(vm.projectRoot(), "/fe/.env");
        vm.writeFile(envPath, envBody);
    }
}
