// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AllowanceWallet} from "../src/AllowanceWallet.sol";

/// @dev Drives the wallet with a small set of parents and children, random amounts and time warps,
///      and keeps ghost accounting so the invariants can compare.
contract AllowanceWalletHandler is Test {
    uint256 internal constant WEEK = 7 days;

    LaunchToken public token;
    AllowanceWallet public wallet;
    address[] public parents;
    address[] public children;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    /// @dev Per account and window: what the child has taken. Checked against the allowance in force
    ///      at the time of each withdrawal.
    mapping(uint256 id => mapping(uint256 window => uint256)) public takenInWindow;
    uint256 public maxWindowOverdraw; // stays 0 if the allowance was never breached

    constructor(LaunchToken token_, AllowanceWallet wallet_) {
        token = token_;
        wallet = wallet_;
        for (uint256 i; i < 3; ++i) {
            address p = makeAddr(string.concat("parent", vm.toString(i)));
            address c = makeAddr(string.concat("child", vm.toString(i)));
            parents.push(p);
            children.push(c);
            vm.prank(p);
            token.approve(address(wallet), type(uint256).max);
        }
    }

    function open(uint256 pSeed, uint256 cSeed, uint256 allowance, uint256 deposit) external {
        address p = parents[pSeed % parents.length];
        address c = children[cSeed % children.length];
        allowance = bound(allowance, 0, 100e18);
        deposit = bound(deposit, 0, token.balanceOf(p));
        vm.prank(p);
        wallet.openAccount(c, allowance, deposit);
        ghostDeposited += deposit;
    }

    function topUp(uint256 idSeed, uint256 amount) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        (address p,,,,) = wallet.account(id);
        amount = bound(amount, 0, token.balanceOf(p));
        vm.prank(p);
        try wallet.topUp(id, amount) {
            ghostDeposited += amount;
        } catch {}
    }

    function setAllowance(uint256 idSeed, uint256 newAllowance) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        (address p,,,,) = wallet.account(id);
        newAllowance = bound(newAllowance, 0, 200e18);
        vm.prank(p);
        wallet.setAllowance(id, newAllowance);
    }

    function parentWithdraw(uint256 idSeed, uint256 amount) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        (address p,,, uint256 bal,) = wallet.account(id);
        amount = bound(amount, 0, bal + 1);
        vm.prank(p);
        try wallet.parentWithdraw(id, amount) {
            ghostWithdrawn += amount;
        } catch {}
    }

    function childWithdraw(uint256 idSeed, uint256 amount) external {
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        (, address c, uint256 allowance, uint256 bal,) = wallet.account(id);
        uint256 remaining = wallet.remainingThisWindow(id);
        amount = bound(amount, 0, (remaining > bal ? remaining : bal) + 1);
        uint256 w = wallet.currentWindow(id);
        vm.prank(c);
        try wallet.childWithdraw(id, amount) {
            ghostWithdrawn += amount;
            takenInWindow[id][w] += amount;
            if (takenInWindow[id][w] > allowance) maxWindowOverdraw = takenInWindow[id][w] - allowance;
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 * WEEK));
    }

    function strangerCallsEverything(uint256 idSeed, uint256 amount) external {
        // A non-participant must never move funds.
        uint256 id = _pick(idSeed);
        if (id == 0) return;
        address s = makeAddr("stranger");
        vm.startPrank(s);
        try wallet.childWithdraw(id, amount) {
            revert("stranger withdrew as child");
        } catch {}
        try wallet.parentWithdraw(id, amount) {
            revert("stranger withdrew as parent");
        } catch {}
        try wallet.setAllowance(id, amount) {
            revert("stranger set allowance");
        } catch {}
        vm.stopPrank();
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        uint256 n = wallet.accountCount();
        return n == 0 ? 0 : (seed % n) + 1;
    }
}

contract AllowanceWalletInvariantTest is Test {
    LaunchToken internal token;
    AllowanceWallet internal wallet;
    AllowanceWalletHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_001);
        token = new LaunchToken();
        wallet = new AllowanceWallet(address(token));
        handler = new AllowanceWalletHandler(token, wallet);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.parents(i), 10_000e18);
        }
        targetContract(address(handler));
    }

    function invariant_contractBalanceEqualsSumOfAccountBalances() public view {
        uint256 sum;
        uint256 n = wallet.accountCount();
        for (uint256 i = 1; i <= n; ++i) {
            (,,, uint256 bal,) = wallet.account(i);
            sum += bal;
        }
        assertEq(token.balanceOf(address(wallet)), sum, "PCKT held != sum of balances");
        assertEq(sum, handler.ghostDeposited() - handler.ghostWithdrawn(), "ghost accounting");
    }

    function invariant_childNeverExceedsAllowanceInAnyWindow() public view {
        assertEq(handler.maxWindowOverdraw(), 0, "allowance breached within a window");
    }

    function invariant_remainingNeverExceedsAllowanceAndSpentNeverExceedsAllowanceAfterWithdraw() public view {
        uint256 n = wallet.accountCount();
        for (uint256 i = 1; i <= n; ++i) {
            (,, uint256 allowance,,) = wallet.account(i);
            assertLe(wallet.remainingThisWindow(i), allowance);
            assertLe(wallet.childWithdrawable(i), wallet.remainingThisWindow(i));
            assertGt(wallet.windowEndsAt(i), block.timestamp);
            assertLe(wallet.windowEndsAt(i) - block.timestamp, 7 days);
        }
    }

    function invariant_walletHoldsNoEth() public view {
        assertEq(address(wallet).balance, 0);
    }
}
