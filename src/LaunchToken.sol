// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Pocket (PCKT) launch token
/// @notice Fixed-supply ERC-20. The whole supply of 1,000,000,000 PCKT (10^27 minor units, 18 decimals)
///         is minted once to the deployer in the constructor. There is no owner, no mint, no burn hook,
///         no pause, no blocklist, no fee and no upgrade path: after construction the only state changes
///         are ordinary transfers and approvals.
/// @dev Deployed by the IdentityMD ProjectFactory, which therefore receives the supply and splits it
///      between the launch pool and the reward distributor. No constructor arguments.
contract LaunchToken is ERC20 {
    /// @notice Exactly 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Pocket", "PCKT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
