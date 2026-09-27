// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Pocket");
        assertEq(token.symbol(), "PCKT");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
        assertEq(token.TOTAL_SUPPLY(), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        address alice = makeAddr("alice");
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), 1_000_000_000e18 - 1_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferFromWithApproval() public {
        address alice = makeAddr("alice");
        address spender = makeAddr("spender");
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_transferRevertsWhenInsufficient() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminSelectors() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
            assertEq(token.totalSupply(), supply, sigs[i]);
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
