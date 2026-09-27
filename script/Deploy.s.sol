// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AllowanceWallet} from "../src/AllowanceWallet.sol";

/// @title Local reference deployment
/// @notice The production launch goes through the IdentityMD ProjectFactory using launch.json, which
///         deploys LaunchToken and then AllowanceWallet with constructorArgs ["$token"]. This script
///         reproduces that shape for a local dry run and for tests. It reads no keys and no RPC secrets.
///         The only environment input is EXPECTED_CHAIN_ID; when it is set and non-zero, the script
///         refuses to run on any other chain, and only Anvil (31337) and Sepolia (11155111) are accepted.
contract Deploy is Script {
    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    error UnexpectedChainId(uint256 expected, uint256 actual);
    error UnsupportedChainId(uint256 chainId);

    /// @notice Pure deployment logic: deploy the token, then the wallet bound to it.
    /// @dev Tests call this directly. `msg.sender` of the token constructor receives the supply, which
    ///      in production is the factory.
    function deploy() public returns (LaunchToken token, AllowanceWallet wallet) {
        token = new LaunchToken();
        wallet = new AllowanceWallet(address(token));
    }

    /// @notice Guard used by `run()`. Exposed so tests can cover it without touching the environment.
    function checkChain(uint256 expected, uint256 actual) public pure {
        if (expected == 0) return;
        if (expected != actual) revert UnexpectedChainId(expected, actual);
        if (actual != ANVIL_CHAIN_ID && actual != SEPOLIA_CHAIN_ID) revert UnsupportedChainId(actual);
    }

    function run() external returns (LaunchToken token, AllowanceWallet wallet) {
        checkChain(vm.envOr("EXPECTED_CHAIN_ID", uint256(0)), block.chainid);
        vm.startBroadcast();
        (token, wallet) = deploy();
        vm.stopBroadcast();
    }
}
