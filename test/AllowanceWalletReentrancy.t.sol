// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AllowanceWallet} from "../src/AllowanceWallet.sol";

/// @dev A hostile ERC-20 that calls back into a target on every transfer and transferFrom. PCKT does
///      not do this; the test shows that even if the working currency had hooks, the wallet's
///      checks-effects-interactions ordering plus nonReentrant would hold.
contract CallbackToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentered;
    bytes public lastRevert;

    constructor() ERC20("Hook", "HOOK") {
        _mint(msg.sender, 1_000_000e18);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            reentered = ok;
            lastRevert = ret;
        }
    }
}

contract AllowanceWalletReentrancyTest is Test {
    CallbackToken internal token;
    AllowanceWallet internal wallet;
    address internal parent = makeAddr("parent");
    address internal child = makeAddr("child");

    function setUp() public {
        vm.warp(1_700_000_001);
        token = new CallbackToken();
        wallet = new AllowanceWallet(address(token));
        token.transfer(parent, 100_000e18);
        vm.prank(parent);
        token.approve(address(wallet), type(uint256).max);
    }

    function test_childWithdrawReentryIsBlocked() public {
        vm.prank(parent);
        uint256 id = wallet.openAccount(child, 10e18, 100e18);
        // During the payout transfer, try to withdraw again as the child (the callback runs as the
        // token, so also prank-free: the guard fires before any role check would).
        token.arm(address(wallet), abi.encodeCall(wallet.childWithdraw, (id, 1e18)));
        vm.prank(child);
        wallet.childWithdraw(id, 5e18);
        assertFalse(token.reentered(), "reentrant call succeeded");
        assertEq(bytes4(token.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        (,,, uint256 bal,) = wallet.account(id);
        assertEq(bal, 95e18);
        assertEq(token.balanceOf(address(wallet)), 95e18);
        assertEq(wallet.spentThisWindow(id), 5e18);
    }

    function test_parentWithdrawReentryIsBlocked() public {
        vm.prank(parent);
        uint256 id = wallet.openAccount(child, 10e18, 100e18);
        token.arm(address(wallet), abi.encodeCall(wallet.parentWithdraw, (id, 50e18)));
        vm.prank(parent);
        wallet.parentWithdraw(id, 40e18);
        assertFalse(token.reentered());
        assertEq(bytes4(token.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.balanceOf(address(wallet)), 60e18);
    }

    function test_topUpAndOpenReentryIsBlocked() public {
        vm.prank(parent);
        uint256 id = wallet.openAccount(child, 10e18, 0);
        token.arm(address(wallet), abi.encodeCall(wallet.openAccount, (child, 1, 0)));
        vm.prank(parent);
        wallet.topUp(id, 10e18);
        assertFalse(token.reentered());
        assertEq(wallet.accountCount(), 1);

        token.arm(address(wallet), abi.encodeCall(wallet.topUp, (id, 1)));
        vm.prank(parent);
        wallet.openAccount(child, 1, 5e18);
        assertFalse(token.reentered());
        assertEq(token.balanceOf(address(wallet)), 15e18);
    }

    function test_viewsDuringPayoutAlreadyReflectEffects() public {
        // Checks-effects-interactions: by the time the token is called, the state is final.
        vm.prank(parent);
        uint256 id = wallet.openAccount(child, 10e18, 100e18);
        token.arm(address(wallet), abi.encodeCall(wallet.remainingThisWindow, (id)));
        vm.prank(child);
        wallet.childWithdraw(id, 4e18);
        assertTrue(token.reentered(), "view should succeed");
        assertEq(abi.decode(token.lastRevert(), (uint256)), 6e18);
    }
}
