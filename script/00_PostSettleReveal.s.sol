// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Constants} from "./base/Constants.sol";
import {PostSettleRevealHook} from "../src/hooks/PostSettleRevealHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Mines and deploys PostSettleRevealHook with the exact hook flags encoded into the address.
contract PostSettleRevealScript is Script, Constants {
    function setUp() public {}

    function run() public {
        uint256 revealDelayBlocks = vm.envOr("REVEAL_DELAY_BLOCKS", uint256(11));
        address owner = vm.envOr("HOOK_OWNER", msg.sender);
        address cofheVerifier = vm.envAddress("COFHE_VERIFIER_ADDRESS");

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(IPoolManager(POOLMANAGER), revealDelayBlocks, owner, cofheVerifier);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(PostSettleRevealHook).creationCode, constructorArgs);

        vm.broadcast();
        PostSettleRevealHook hook = new PostSettleRevealHook{salt: salt}(IPoolManager(POOLMANAGER), revealDelayBlocks, owner, cofheVerifier);
        require(address(hook) == hookAddress, "PostSettleRevealScript: hook address mismatch");
    }
}
