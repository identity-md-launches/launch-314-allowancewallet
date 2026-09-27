// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AllowanceWallet} from "../src/AllowanceWallet.sol";

/// @notice Fuzz tests that replay random sequences of child withdrawals, parent actions and time warps
///         against an independent reference model of the window rules.
contract AllowanceWalletFuzzTest is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant STEPS = 12;

    LaunchToken internal token;
    AllowanceWallet internal wallet;

    address internal parent = makeAddr("parent");
    address internal child = makeAddr("child");

    function setUp() public {
        vm.warp(1_700_000_001);
        token = new LaunchToken();
        wallet = new AllowanceWallet(address(token));
        token.transfer(parent, 1_000_000e18);
        vm.prank(parent);
        token.approve(address(wallet), type(uint256).max);
    }

    /// @dev Reference model: the child can take at most `allowance - spent` in the window the account
    ///      is currently in, and `spent` is zero in any window other than the one it was recorded in.
    struct Model {
        uint256 openedAt;
        uint256 allowance;
        uint256 balance;
        uint256 spent;
        uint256 spentWindow;
    }

    function _window(Model memory m) internal view returns (uint256) {
        return (block.timestamp - m.openedAt) / WEEK;
    }

    function _remaining(Model memory m) internal view returns (uint256) {
        uint256 spent = m.spentWindow == _window(m) ? m.spent : 0;
        return m.allowance > spent ? m.allowance - spent : 0;
    }

    /// @notice Random withdrawal amounts interleaved with random warps (0 to just over two weeks each):
    ///         every childWithdraw must succeed exactly when the model says so, and after every step the
    ///         contract's view functions and PCKT balance must agree with the model.
    function testFuzz_withdrawalSequencesAndWarps(
        uint256 allowance,
        uint256 deposit,
        uint256 startOffset,
        uint256[STEPS] memory amounts,
        uint32[STEPS] memory warps
    ) public {
        allowance = bound(allowance, 0, 1_000e18);
        deposit = bound(deposit, 0, 100_000e18);
        vm.warp(block.timestamp + bound(startOffset, 0, 30 days));

        vm.prank(parent);
        uint256 id = wallet.openAccount(child, allowance, deposit);
        Model memory m =
            Model({openedAt: block.timestamp, allowance: allowance, balance: deposit, spent: 0, spentWindow: 0});

        uint256 childReceived;
        for (uint256 i; i < STEPS; ++i) {
            // Warps are biased to land on and around window boundaries as well as anywhere inside.
            uint256 warp = uint256(warps[i]) % (2 * WEEK + 3);
            if (warp == 2 * WEEK + 1) warp = wallet.windowEndsAt(id) - block.timestamp; // exactly at reset
            if (warp == 2 * WEEK + 2) warp = wallet.windowEndsAt(id) - block.timestamp - 1; // one second before
            vm.warp(block.timestamp + warp);

            uint256 remaining = _remaining(m);
            // Amounts are biased around the interesting limits.
            uint256 amount = amounts[i] % 4 == 0
                ? remaining
                : amounts[i] % 4 == 1
                    ? remaining + 1
                    : amounts[i] % 4 == 2 ? m.balance : amounts[i] % (2 * allowance + 2);

            assertEq(wallet.remainingThisWindow(id), remaining, "remaining view");
            assertEq(wallet.currentWindow(id), _window(m), "window view");
            assertEq(wallet.windowEndsAt(id), m.openedAt + (_window(m) + 1) * WEEK, "windowEndsAt view");

            vm.prank(child);
            if (amount == 0) {
                vm.expectRevert(AllowanceWallet.ZeroAmount.selector);
                wallet.childWithdraw(id, amount);
            } else if (amount > remaining) {
                vm.expectRevert(
                    abi.encodeWithSelector(AllowanceWallet.ExceedsAllowance.selector, id, amount, remaining)
                );
                wallet.childWithdraw(id, amount);
            } else if (amount > m.balance) {
                vm.expectRevert(
                    abi.encodeWithSelector(AllowanceWallet.InsufficientBalance.selector, id, amount, m.balance)
                );
                wallet.childWithdraw(id, amount);
            } else {
                wallet.childWithdraw(id, amount);
                uint256 w = _window(m);
                m.spent = (m.spentWindow == w ? m.spent : 0) + amount;
                m.spentWindow = w;
                m.balance -= amount;
                childReceived += amount;
                assertLe(m.spent, m.allowance, "spent within window exceeds allowance");
            }

            (,,, uint256 bal,) = wallet.account(id);
            assertEq(bal, m.balance, "balance");
            assertEq(wallet.spentThisWindow(id), m.spentWindow == _window(m) ? m.spent : 0, "spent view");
            assertEq(token.balanceOf(address(wallet)), m.balance, "conservation");
            assertEq(token.balanceOf(child), childReceived, "child received");
        }
    }

    /// @notice Same as above but the parent interleaves top-ups, allowance changes and withdrawals, so
    ///         the mid-window allowance rules are exercised against the model too.
    function testFuzz_mixedParentAndChildActionsWithWarps(
        uint256 allowance,
        uint256 deposit,
        uint8[STEPS] memory ops,
        uint256[STEPS] memory values,
        uint32[STEPS] memory warps
    ) public {
        allowance = bound(allowance, 0, 1_000e18);
        deposit = bound(deposit, 0, 10_000e18);

        vm.prank(parent);
        uint256 id = wallet.openAccount(child, allowance, deposit);
        Model memory m =
            Model({openedAt: block.timestamp, allowance: allowance, balance: deposit, spent: 0, spentWindow: 0});

        for (uint256 i; i < STEPS; ++i) {
            vm.warp(block.timestamp + (uint256(warps[i]) % (WEEK + 1)));
            uint256 op = ops[i] % 4;
            if (op == 0) {
                // Child withdraw of a value around the remaining allowance.
                uint256 remaining = _remaining(m);
                uint256 amount = values[i] % 3 == 0 ? remaining : values[i] % (remaining + 2);
                vm.prank(child);
                if (amount == 0 || amount > remaining || amount > m.balance) {
                    vm.expectRevert();
                    wallet.childWithdraw(id, amount);
                } else {
                    wallet.childWithdraw(id, amount);
                    uint256 w = _window(m);
                    m.spent = (m.spentWindow == w ? m.spent : 0) + amount;
                    m.spentWindow = w;
                    m.balance -= amount;
                }
            } else if (op == 1) {
                uint256 amount = values[i] % 1_000e18;
                vm.prank(parent);
                if (amount == 0) {
                    vm.expectRevert(AllowanceWallet.ZeroAmount.selector);
                    wallet.topUp(id, amount);
                } else {
                    wallet.topUp(id, amount);
                    m.balance += amount;
                }
            } else if (op == 2) {
                uint256 newAllowance = values[i] % (2_000e18 + 1);
                vm.prank(parent);
                wallet.setAllowance(id, newAllowance);
                m.allowance = newAllowance; // spent is untouched
            } else {
                uint256 amount = values[i] % (m.balance + 2);
                vm.prank(parent);
                if (amount == 0 || amount > m.balance) {
                    vm.expectRevert();
                    wallet.parentWithdraw(id, amount);
                } else {
                    wallet.parentWithdraw(id, amount);
                    m.balance -= amount;
                }
            }

            (,, uint256 al, uint256 bal,) = wallet.account(id);
            assertEq(al, m.allowance, "allowance");
            assertEq(bal, m.balance, "balance");
            assertEq(wallet.remainingThisWindow(id), _remaining(m), "remaining");
            assertEq(wallet.spentThisWindow(id), m.spentWindow == _window(m) ? m.spent : 0, "spent");
            assertEq(token.balanceOf(address(wallet)), m.balance, "conservation");
        }
    }

    /// @notice For any opening time and any later time, the window index and reset time agree with the
    ///         7-day arithmetic, including exactly on the boundary.
    function testFuzz_windowArithmetic(uint64 openedAt, uint64 elapsed) public {
        openedAt = uint64(bound(openedAt, 1, type(uint48).max));
        elapsed = uint64(bound(elapsed, 0, type(uint48).max));
        vm.warp(openedAt);
        vm.prank(parent);
        uint256 id = wallet.openAccount(child, 1, 0);
        vm.warp(uint256(openedAt) + elapsed);
        uint256 expectedWindow = uint256(elapsed) / WEEK;
        assertEq(wallet.currentWindow(id), expectedWindow);
        uint256 endsAt = wallet.windowEndsAt(id);
        assertEq(endsAt, uint256(openedAt) + (expectedWindow + 1) * WEEK);
        assertGt(endsAt, block.timestamp);
        assertLe(endsAt - block.timestamp, WEEK);
        // One second before the reset is still the same window; the reset second is the next one.
        vm.warp(endsAt - 1);
        assertEq(wallet.currentWindow(id), expectedWindow);
        vm.warp(endsAt);
        assertEq(wallet.currentWindow(id), expectedWindow + 1);
    }

    /// @notice Across any number of windows the child can never take more than allowance * windowsUsed
    ///         and never more than what was deposited.
    function testFuzz_totalWithdrawnBoundedByAllowancePerWindow(
        uint256 allowance,
        uint256 deposit,
        uint8 windowsToSpan,
        uint256[STEPS] memory amounts
    ) public {
        allowance = bound(allowance, 1, 100e18);
        deposit = bound(deposit, 0, 5_000e18);
        uint256 span = uint256(windowsToSpan) % 6;
        vm.prank(parent);
        uint256 id = wallet.openAccount(child, allowance, deposit);
        uint256 start = block.timestamp;
        uint256 total;
        for (uint256 i; i < STEPS; ++i) {
            vm.warp(start + (span * WEEK * i) / STEPS);
            uint256 amount = amounts[i] % (allowance + 1);
            vm.prank(child);
            (bool ok,) = address(wallet).call(abi.encodeCall(wallet.childWithdraw, (id, amount)));
            if (ok) total += amount;
        }
        assertEq(token.balanceOf(child), total);
        assertLe(total, deposit);
        assertLe(total, allowance * (span + 1));
    }
}
