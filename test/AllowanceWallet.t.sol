// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AllowanceWallet} from "../src/AllowanceWallet.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract AllowanceWalletTest is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant START = 1_700_000_001; // deliberately not a round number

    LaunchToken internal token;
    AllowanceWallet internal wallet;

    address internal parent = makeAddr("parent");
    address internal child = makeAddr("child");
    address internal otherParent = makeAddr("otherParent");
    address internal otherChild = makeAddr("otherChild");
    address internal stranger = makeAddr("stranger");

    event Opened(
        uint256 indexed id, address indexed parent, address indexed child, uint256 weeklyAllowance, uint256 deposit
    );
    event ToppedUp(uint256 indexed id, uint256 amount, uint256 newBalance);
    event AllowanceSet(uint256 indexed id, uint256 newAllowance);
    event ChildWithdrew(uint256 indexed id, uint256 amount, uint256 newBalance, uint256 window);
    event ParentWithdrew(uint256 indexed id, uint256 amount, uint256 newBalance);

    function setUp() public {
        vm.warp(START);
        Deploy d = new Deploy();
        (token, wallet) = d.deploy();
        // The deploy script holds the supply locally (the factory does in production); hand some out.
        vm.startPrank(address(d));
        token.transfer(parent, 1_000_000e18);
        token.transfer(otherParent, 1_000_000e18);
        token.transfer(stranger, 1_000_000e18);
        vm.stopPrank();
        vm.prank(parent);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(otherParent);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(stranger);
        token.approve(address(wallet), type(uint256).max);
    }

    function _open(address p, address c, uint256 allowance, uint256 deposit) internal returns (uint256 id) {
        vm.prank(p);
        id = wallet.openAccount(c, allowance, deposit);
    }

    function _childWithdraw(uint256 id, uint256 amount) internal {
        vm.prank(child);
        wallet.childWithdraw(id, amount);
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_constructorStoresToken() public view {
        assertEq(address(wallet.token()), address(token));
        assertEq(wallet.WINDOW(), WEEK);
        assertEq(wallet.accountCount(), 0);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(AllowanceWallet.ZeroToken.selector);
        new AllowanceWallet(address(0));
    }

    function test_noReceiveOrFallback() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(stranger);
        (ok,) = address(wallet).call{value: 1 ether}(hex"12345678");
        assertFalse(ok);
        vm.prank(stranger);
        (ok,) = address(wallet).call(hex"12345678");
        assertFalse(ok);
        assertEq(address(wallet).balance, 0);
    }

    // ------------------------------------------------------------------
    // openAccount
    // ------------------------------------------------------------------

    function test_openAccountPullsDepositAndEmits() public {
        uint256 before = token.balanceOf(parent);
        vm.expectEmit(true, true, true, true, address(wallet));
        emit Opened(1, parent, child, 50e18, 200e18);
        uint256 id = _open(parent, child, 50e18, 200e18);

        assertEq(id, 1);
        assertEq(wallet.accountCount(), 1);
        (address p, address c, uint256 allowance, uint256 balance, uint256 openedAt) = wallet.account(1);
        assertEq(p, parent);
        assertEq(c, child);
        assertEq(allowance, 50e18);
        assertEq(balance, 200e18);
        assertEq(openedAt, START);
        assertEq(token.balanceOf(parent), before - 200e18);
        assertEq(token.balanceOf(address(wallet)), 200e18);
        assertEq(wallet.currentWindow(1), 0);
        assertEq(wallet.spentThisWindow(1), 0);
        assertEq(wallet.remainingThisWindow(1), 50e18);
        assertEq(wallet.childWithdrawable(1), 50e18);
        assertEq(wallet.windowEndsAt(1), START + WEEK);
    }

    function test_openAccountWithZeroDeposit() public {
        uint256 id = _open(parent, child, 10e18, 0);
        (,,, uint256 balance,) = wallet.account(id);
        assertEq(balance, 0);
        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(wallet.childWithdrawable(id), 0);
        // Child cannot withdraw from an empty account even though the allowance is 10.
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
    }

    function test_openAccountRejectsZeroChild() public {
        vm.prank(parent);
        vm.expectRevert(AllowanceWallet.ZeroChild.selector);
        wallet.openAccount(address(0), 1e18, 0);
    }

    function test_openAccountRejectsSelfAsChild() public {
        vm.prank(parent);
        vm.expectRevert(AllowanceWallet.ChildIsCaller.selector);
        wallet.openAccount(parent, 1e18, 0);
    }

    function test_openAccountRevertsWithoutApproval() public {
        address unapproved = makeAddr("unapproved");
        deal(address(token), unapproved, 10e18);
        vm.prank(unapproved);
        vm.expectRevert();
        wallet.openAccount(child, 1e18, 10e18);
        assertEq(wallet.accountCount(), 0);
    }

    function test_openAccountRevertsWithoutBalance() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(broke);
        vm.expectRevert();
        wallet.openAccount(child, 1e18, 1);
    }

    function test_idsIncrementAndAllowManyAccounts() public {
        assertEq(_open(parent, child, 1e18, 1e18), 1);
        assertEq(_open(parent, otherChild, 2e18, 2e18), 2);
        assertEq(_open(otherParent, child, 3e18, 3e18), 3);
        assertEq(_open(parent, child, 4e18, 4e18), 4); // same pair, second account
        assertEq(wallet.accountCount(), 4);
        (address p, address c, uint256 al,,) = wallet.account(4);
        assertEq(p, parent);
        assertEq(c, child);
        assertEq(al, 4e18);
    }

    // ------------------------------------------------------------------
    // Unknown ids
    // ------------------------------------------------------------------

    function test_unknownIdRevertsEverywhere() public {
        _open(parent, child, 1e18, 1e18);
        uint256[2] memory bad = [uint256(0), uint256(2)];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory err = abi.encodeWithSelector(AllowanceWallet.NoSuchAccount.selector, bad[i]);
            vm.expectRevert(err);
            wallet.account(bad[i]);
            vm.expectRevert(err);
            wallet.remainingThisWindow(bad[i]);
            vm.expectRevert(err);
            wallet.windowEndsAt(bad[i]);
            vm.expectRevert(err);
            wallet.currentWindow(bad[i]);
            vm.expectRevert(err);
            wallet.spentThisWindow(bad[i]);
            vm.expectRevert(err);
            wallet.childWithdrawable(bad[i]);
            vm.prank(parent);
            vm.expectRevert(err);
            wallet.topUp(bad[i], 1);
            vm.prank(parent);
            vm.expectRevert(err);
            wallet.setAllowance(bad[i], 1);
            vm.prank(parent);
            vm.expectRevert(err);
            wallet.parentWithdraw(bad[i], 1);
            vm.prank(child);
            vm.expectRevert(err);
            wallet.childWithdraw(bad[i], 1);
        }
    }

    // ------------------------------------------------------------------
    // Role checks on every function
    // ------------------------------------------------------------------

    function test_roleChecks_topUp() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        address[3] memory callers = [child, otherParent, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotParent.selector, id, callers[i]));
            wallet.topUp(id, 1e18);
        }
    }

    function test_roleChecks_setAllowance() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        address[3] memory callers = [child, otherParent, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotParent.selector, id, callers[i]));
            wallet.setAllowance(id, 1e18);
        }
    }

    function test_roleChecks_parentWithdraw() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        address[3] memory callers = [child, otherParent, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotParent.selector, id, callers[i]));
            wallet.parentWithdraw(id, 1e18);
        }
    }

    function test_roleChecks_childWithdraw() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        address[3] memory callers = [parent, otherChild, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotChild.selector, id, callers[i]));
            wallet.childWithdraw(id, 1e18);
        }
    }

    // ------------------------------------------------------------------
    // topUp
    // ------------------------------------------------------------------

    function test_topUpIncreasesBalanceAndEmits() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit ToppedUp(id, 25e18, 125e18);
        vm.prank(parent);
        wallet.topUp(id, 25e18);
        (,,, uint256 balance,) = wallet.account(id);
        assertEq(balance, 125e18);
        assertEq(token.balanceOf(address(wallet)), 125e18);
    }

    function test_topUpRejectsZero() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        vm.prank(parent);
        vm.expectRevert(AllowanceWallet.ZeroAmount.selector);
        wallet.topUp(id, 0);
    }

    function test_topUpDoesNotChangeSpentOrWindow() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        _childWithdraw(id, 4e18);
        vm.prank(parent);
        wallet.topUp(id, 50e18);
        assertEq(wallet.spentThisWindow(id), 4e18);
        assertEq(wallet.remainingThisWindow(id), 6e18);
    }

    // ------------------------------------------------------------------
    // parentWithdraw
    // ------------------------------------------------------------------

    function test_parentWithdrawAnyAmountAnyTime() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        _childWithdraw(id, 10e18); // child used the whole allowance
        uint256 before = token.balanceOf(parent);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit ParentWithdrew(id, 90e18, 0);
        vm.prank(parent);
        wallet.parentWithdraw(id, 90e18);
        assertEq(token.balanceOf(parent), before + 90e18);
        (,,, uint256 balance,) = wallet.account(id);
        assertEq(balance, 0);
        assertEq(token.balanceOf(address(wallet)), 0);
        // The allowance is not a guarantee: in the next window the child has allowance but no balance.
        vm.warp(START + WEEK);
        assertEq(wallet.remainingThisWindow(id), 10e18);
        assertEq(wallet.childWithdrawable(id), 0);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, id, 1e18, 0));
        wallet.childWithdraw(id, 1e18);
    }

    function test_parentWithdrawPartial() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        vm.prank(parent);
        wallet.parentWithdraw(id, 1);
        (,,, uint256 balance,) = wallet.account(id);
        assertEq(balance, 100e18 - 1);
    }

    function test_parentWithdrawRejectsZeroAndOverdraw() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        vm.prank(parent);
        vm.expectRevert(AllowanceWallet.ZeroAmount.selector);
        wallet.parentWithdraw(id, 0);
        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, id, 100e18 + 1, 100e18));
        wallet.parentWithdraw(id, 100e18 + 1);
    }

    function test_parentWithdrawGoesOnlyToParent() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        uint256 childBefore = token.balanceOf(child);
        uint256 parentBefore = token.balanceOf(parent);
        vm.prank(parent);
        wallet.parentWithdraw(id, 100e18);
        assertEq(token.balanceOf(child), childBefore);
        assertEq(token.balanceOf(parent), parentBefore + 100e18);
    }

    // ------------------------------------------------------------------
    // childWithdraw
    // ------------------------------------------------------------------

    function test_childWithdrawHappyPathAndEmits() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        uint256 before = token.balanceOf(child);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit ChildWithdrew(id, 3e18, 97e18, 0);
        _childWithdraw(id, 3e18);
        assertEq(token.balanceOf(child), before + 3e18);
        assertEq(wallet.spentThisWindow(id), 3e18);
        assertEq(wallet.remainingThisWindow(id), 7e18);
        (,,, uint256 balance,) = wallet.account(id);
        assertEq(balance, 97e18);
    }

    function test_childWithdrawRejectsZero() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        vm.prank(child);
        vm.expectRevert(AllowanceWallet.ZeroAmount.selector);
        wallet.childWithdraw(id, 0);
    }

    function test_childWithdrawRejectsOverAllowanceInOneCall() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 10e18 + 1, 10e18));
        wallet.childWithdraw(id, 10e18 + 1);
    }

    function test_childWithdrawRejectsOverAllowanceBySplitting() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        _childWithdraw(id, 4e18);
        _childWithdraw(id, 5e18);
        _childWithdraw(id, 1e18); // exactly the allowance in three pieces
        assertEq(wallet.remainingThisWindow(id), 0);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
        // Still blocked one second before the window ends.
        vm.warp(START + WEEK - 1);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
    }

    function test_childWithdrawBoundedByBalance() public {
        uint256 id = _open(parent, child, 100e18, 30e18);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, id, 30e18 + 1, 30e18));
        wallet.childWithdraw(id, 30e18 + 1);
        _childWithdraw(id, 30e18);
        assertEq(wallet.remainingThisWindow(id), 70e18);
        assertEq(wallet.childWithdrawable(id), 0);
    }

    function test_childWithdrawGoesOnlyToChild() public {
        uint256 id = _open(parent, child, 10e18, 100e18);
        uint256 parentBefore = token.balanceOf(parent);
        _childWithdraw(id, 10e18);
        assertEq(token.balanceOf(parent), parentBefore);
        assertEq(token.balanceOf(child), 10e18);
    }

    // ------------------------------------------------------------------
    // Exact 7-day boundary and no rollover
    // ------------------------------------------------------------------

    function test_exactWindowBoundary() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 10e18);

        // The last second of window 0: still window 0, allowance exhausted.
        vm.warp(START + WEEK - 1);
        assertEq(wallet.currentWindow(id), 0);
        assertEq(wallet.remainingThisWindow(id), 0);
        assertEq(wallet.windowEndsAt(id), START + WEEK);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);

        // The first second of window 1: spent resets, the full allowance is available again.
        vm.warp(START + WEEK);
        assertEq(wallet.currentWindow(id), 1);
        assertEq(wallet.spentThisWindow(id), 0);
        assertEq(wallet.remainingThisWindow(id), 10e18);
        assertEq(wallet.windowEndsAt(id), START + 2 * WEEK);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit ChildWithdrew(id, 10e18, 980e18, 1);
        _childWithdraw(id, 10e18);
        assertEq(wallet.remainingThisWindow(id), 0);

        // And the boundary of window 2 behaves the same way.
        vm.warp(START + 2 * WEEK - 1);
        assertEq(wallet.currentWindow(id), 1);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
        vm.warp(START + 2 * WEEK);
        assertEq(wallet.currentWindow(id), 2);
        _childWithdraw(id, 10e18);
    }

    function test_windowIsAnchoredAtOpeningNotAtCalendar() public {
        vm.warp(START + 3 days + 12345);
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        uint256 opened = START + 3 days + 12345;
        assertEq(wallet.windowEndsAt(id), opened + WEEK);
        _childWithdraw(id, 10e18);
        vm.warp(opened + WEEK - 1);
        assertEq(wallet.remainingThisWindow(id), 0);
        vm.warp(opened + WEEK);
        assertEq(wallet.remainingThisWindow(id), 10e18);
    }

    function test_noRolloverOfUnspentAllowance() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 2e18); // 8 unspent in window 0
        vm.warp(START + WEEK);
        assertEq(wallet.remainingThisWindow(id), 10e18); // not 18
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 10e18 + 1, 10e18));
        wallet.childWithdraw(id, 10e18 + 1);
        _childWithdraw(id, 10e18);
    }

    function test_noRolloverAcrossSkippedWindows() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        vm.warp(START + 5 * WEEK + 100); // nothing withdrawn for five weeks
        assertEq(wallet.currentWindow(id), 5);
        assertEq(wallet.remainingThisWindow(id), 10e18); // not 60
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 10e18 + 1, 10e18));
        wallet.childWithdraw(id, 10e18 + 1);
        _childWithdraw(id, 10e18);
        assertEq(wallet.windowEndsAt(id), START + 6 * WEEK);
    }

    function test_spentCounterFromOldWindowIsIgnoredNotCarried() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 7e18);
        vm.warp(START + 3 * WEEK);
        // Old spent (7) must not reduce the new window.
        _childWithdraw(id, 10e18);
        assertEq(wallet.spentThisWindow(id), 10e18);
    }

    // ------------------------------------------------------------------
    // Allowance changes mid-window
    // ------------------------------------------------------------------

    function test_setAllowanceEmitsAndIsImmediate() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit AllowanceSet(id, 25e18);
        vm.prank(parent);
        wallet.setAllowance(id, 25e18);
        (,, uint256 allowance,,) = wallet.account(id);
        assertEq(allowance, 25e18);
        assertEq(wallet.remainingThisWindow(id), 25e18);
    }

    function test_raiseAllowanceMidWindowKeepsSpent() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 10e18);
        vm.warp(START + 3 days);
        vm.prank(parent);
        wallet.setAllowance(id, 25e18);
        assertEq(wallet.spentThisWindow(id), 10e18);
        assertEq(wallet.remainingThisWindow(id), 15e18); // 25 - 10 already spent, not 25
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 15e18 + 1, 15e18));
        wallet.childWithdraw(id, 15e18 + 1);
        _childWithdraw(id, 15e18);
        assertEq(wallet.remainingThisWindow(id), 0);
    }

    function test_lowerAllowanceBelowSpentLeavesZeroUntilNextWindow() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 8e18);
        vm.prank(parent);
        wallet.setAllowance(id, 5e18);
        assertEq(wallet.remainingThisWindow(id), 0); // saturates, no underflow
        assertEq(wallet.spentThisWindow(id), 8e18);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
        vm.warp(START + WEEK);
        assertEq(wallet.remainingThisWindow(id), 5e18);
        _childWithdraw(id, 5e18);
    }

    function test_lowerAllowanceAboveSpentKeepsDifference() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 3e18);
        vm.prank(parent);
        wallet.setAllowance(id, 5e18);
        assertEq(wallet.remainingThisWindow(id), 2e18);
        _childWithdraw(id, 2e18);
        assertEq(wallet.remainingThisWindow(id), 0);
    }

    function test_zeroAllowanceFreezesChildAndUnfreezesWhenRaised() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        vm.prank(parent);
        wallet.setAllowance(id, 0);
        assertEq(wallet.remainingThisWindow(id), 0);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
        vm.warp(START + 4 * WEEK); // still frozen in later windows
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, 1, 0));
        wallet.childWithdraw(id, 1);
        vm.prank(parent);
        wallet.setAllowance(id, 1e18);
        _childWithdraw(id, 1e18);
    }

    function test_setAllowanceDoesNotResetSpentOnRepeatedChanges() public {
        uint256 id = _open(parent, child, 10e18, 1_000e18);
        _childWithdraw(id, 6e18);
        vm.startPrank(parent);
        wallet.setAllowance(id, 0);
        wallet.setAllowance(id, 100e18);
        wallet.setAllowance(id, 10e18);
        vm.stopPrank();
        assertEq(wallet.remainingThisWindow(id), 4e18); // spent 6 still counts
    }

    // ------------------------------------------------------------------
    // Cross-account isolation
    // ------------------------------------------------------------------

    function test_crossAccountIsolation() public {
        uint256 a = _open(parent, child, 10e18, 100e18);
        uint256 b = _open(otherParent, otherChild, 20e18, 200e18);
        uint256 c = _open(parent, child, 30e18, 300e18); // same pair, separate books

        // Child of a cannot touch b.
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotChild.selector, b, child));
        wallet.childWithdraw(b, 1e18);
        // Parent of a cannot touch b.
        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotParent.selector, b, parent));
        wallet.parentWithdraw(b, 1e18);
        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotParent.selector, b, parent));
        wallet.setAllowance(b, 0);
        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.NotParent.selector, b, parent));
        wallet.topUp(b, 1e18);

        // Spending in a does not consume c's allowance, nor b's.
        _childWithdraw(a, 10e18);
        assertEq(wallet.remainingThisWindow(a), 0);
        assertEq(wallet.remainingThisWindow(c), 30e18);
        assertEq(wallet.remainingThisWindow(b), 20e18);
        _childWithdraw(c, 30e18);

        // a's balance cannot be used to pay c's withdrawals: c is drained by its parent, then the
        // child's window-1 allowance in c is blocked by c's balance, not a's.
        vm.warp(START + WEEK);
        vm.prank(parent);
        wallet.parentWithdraw(c, 270e18);
        vm.prank(child);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, c, 1, 0));
        wallet.childWithdraw(c, 1);
        _childWithdraw(a, 10e18);

        // Parent of a cannot pull more than a holds even though the contract holds b's funds.
        (,,, uint256 balA,) = wallet.account(a);
        vm.prank(parent);
        vm.expectRevert(abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, a, balA + 1, balA));
        wallet.parentWithdraw(a, balA + 1);

        // Books add up.
        (,,, uint256 balB,) = wallet.account(b);
        (,,, uint256 balC,) = wallet.account(c);
        assertEq(token.balanceOf(address(wallet)), balA + balB + balC);
        assertEq(balB, 200e18);
    }

    function test_accountsWithDifferentOpeningTimesHaveIndependentWindows() public {
        uint256 a = _open(parent, child, 10e18, 100e18);
        vm.warp(START + 2 days);
        uint256 b = _open(parent, child, 10e18, 100e18);
        _childWithdraw(a, 10e18);
        _childWithdraw(b, 10e18);
        vm.warp(START + WEEK); // a resets, b does not
        assertEq(wallet.remainingThisWindow(a), 10e18);
        assertEq(wallet.remainingThisWindow(b), 0);
        vm.warp(START + WEEK + 2 days); // now b resets
        assertEq(wallet.remainingThisWindow(b), 10e18);
    }

    // ------------------------------------------------------------------
    // Conservation
    // ------------------------------------------------------------------

    function test_contractBalanceEqualsSumOfAccountBalances() public {
        uint256 a = _open(parent, child, 10e18, 100e18);
        uint256 b = _open(otherParent, otherChild, 20e18, 0);
        _assertConserved();
        vm.prank(otherParent);
        wallet.topUp(b, 55e18);
        _assertConserved();
        _childWithdraw(a, 10e18);
        _assertConserved();
        vm.prank(otherChild);
        wallet.childWithdraw(b, 20e18);
        _assertConserved();
        vm.prank(parent);
        wallet.parentWithdraw(a, 90e18);
        _assertConserved();
        vm.warp(START + WEEK);
        vm.prank(otherChild);
        wallet.childWithdraw(b, 20e18);
        _assertConserved();
        // Stray transfers only ever increase the contract's balance above what it owes; they are stuck.
        vm.prank(stranger);
        token.transfer(address(wallet), 1e18);
        assertEq(token.balanceOf(address(wallet)), _sumBalances() + 1e18);
    }

    function _sumBalances() internal view returns (uint256 sum) {
        uint256 n = wallet.accountCount();
        for (uint256 i = 1; i <= n; ++i) {
            (,,, uint256 bal,) = wallet.account(i);
            sum += bal;
        }
    }

    function _assertConserved() internal view {
        assertEq(token.balanceOf(address(wallet)), _sumBalances(), "conservation");
    }

    // ------------------------------------------------------------------
    // Deploy script guard
    // ------------------------------------------------------------------

    function test_deployScriptChainGuard() public {
        Deploy d = new Deploy();
        d.checkChain(0, 1); // 0 disables the check
        d.checkChain(31337, 31337);
        d.checkChain(11155111, 11155111);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedChainId.selector, 11155111, 1));
        d.checkChain(11155111, 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChainId.selector, 1));
        d.checkChain(1, 1);
    }

    function test_deployScriptWiresTokenIntoWallet() public {
        Deploy d = new Deploy();
        (LaunchToken t, AllowanceWallet w) = d.deploy();
        assertEq(address(w.token()), address(t));
        assertEq(t.balanceOf(address(d)), t.totalSupply());
        assertEq(t.balanceOf(address(w)), 0);
    }
}
