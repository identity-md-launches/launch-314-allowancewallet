// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AllowanceWallet: weekly PCKT pocket-money accounts between a parent and a child
/// @notice A parent opens an account for a child, funds it with PCKT and sets a weekly allowance.
///         The child may pull up to the allowance per 7-day window; unspent allowance never rolls
///         over. The parent may top up, change the allowance (effective immediately) or withdraw any
///         part of the balance at any time, so the allowance is a limit on the child, not a promise
///         to the child.
/// @dev Windows are anchored at the account's opening timestamp:
///      `window = (block.timestamp - openedAt) / 7 days`. The spent counter is tagged with the window
///      it was accumulated in and is treated as zero whenever the tag differs from the current window.
///      All value moves via `SafeERC20` pull payments (`safeTransferFrom` in) and pull withdrawals
///      (`safeTransfer` to `msg.sender` out). There is no owner, no admin, no pause, no upgrade path,
///      no payable function and no receive/fallback, so the contract never holds ETH.
contract AllowanceWallet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Account {
        address parent;
        address child;
        uint64 openedAt;
        uint256 allowance;
        uint256 balance;
        /// @dev Amount withdrawn by the child in window `spentWindow`. Meaningless for other windows.
        uint256 spent;
        /// @dev Window index the `spent` counter belongs to.
        uint256 spentWindow;
    }

    // ------------------------------------------------------------------
    // Constants and immutables
    // ------------------------------------------------------------------

    /// @notice Length of one allowance window.
    uint256 public constant WINDOW = 7 days;

    /// @notice The PCKT token every account is denominated in.
    IERC20 public immutable token;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    uint256 private _accountCount;
    mapping(uint256 id => Account) private _accounts;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Opened(
        uint256 indexed id, address indexed parent, address indexed child, uint256 weeklyAllowance, uint256 deposit
    );
    event ToppedUp(uint256 indexed id, uint256 amount, uint256 newBalance);
    event AllowanceSet(uint256 indexed id, uint256 newAllowance);
    event ChildWithdrew(uint256 indexed id, uint256 amount, uint256 newBalance, uint256 window);
    event ParentWithdrew(uint256 indexed id, uint256 amount, uint256 newBalance);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ZeroToken();
    error ZeroChild();
    error ChildIsCaller();
    error NoSuchAccount(uint256 id);
    error NotParent(uint256 id, address caller);
    error NotChild(uint256 id, address caller);
    error ZeroAmount();
    error ExceedsAllowance(uint256 id, uint256 requested, uint256 remaining);
    error InsufficientBalance(uint256 id, uint256 requested, uint256 balance);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param token_ The PCKT token address (the launch token). Passed by the factory as `$token`.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        token = IERC20(token_);
    }

    // ------------------------------------------------------------------
    // Parent actions
    // ------------------------------------------------------------------

    /// @notice Open a pocket-money account. The caller becomes the parent.
    /// @param child           The child address. Must be non-zero and different from the caller.
    /// @param weeklyAllowance Maximum the child may withdraw per 7-day window (PCKT minor units).
    /// @param deposit         Opening balance pulled from the caller with `safeTransferFrom`. May be 0.
    /// @return id             The new account id (ids start at 1 and increase by one).
    function openAccount(address child, uint256 weeklyAllowance, uint256 deposit)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (child == address(0)) revert ZeroChild();
        if (child == msg.sender) revert ChildIsCaller();

        id = ++_accountCount;
        Account storage a = _accounts[id];
        a.parent = msg.sender;
        a.child = child;
        a.openedAt = uint64(block.timestamp);
        a.allowance = weeklyAllowance;
        a.balance = deposit;

        emit Opened(id, msg.sender, child, weeklyAllowance, deposit);

        if (deposit != 0) token.safeTransferFrom(msg.sender, address(this), deposit);
    }

    /// @notice Add PCKT to an account's balance. Parent only.
    function topUp(uint256 id, uint256 amount) external nonReentrant {
        Account storage a = _parentAccount(id);
        if (amount == 0) revert ZeroAmount();

        a.balance += amount;
        emit ToppedUp(id, amount, a.balance);

        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Change the weekly allowance, effective immediately. Parent only.
    /// @dev What the child already withdrew this window still counts against the new limit, so lowering
    ///      the allowance below the amount already spent leaves zero remaining until the next window.
    ///      Setting 0 freezes the child until it is raised again.
    function setAllowance(uint256 id, uint256 newAllowance) external {
        Account storage a = _parentAccount(id);
        a.allowance = newAllowance;
        emit AllowanceSet(id, newAllowance);
    }

    /// @notice Withdraw any part of the balance to the parent, at any time. Parent only.
    function parentWithdraw(uint256 id, uint256 amount) external nonReentrant {
        Account storage a = _parentAccount(id);
        if (amount == 0) revert ZeroAmount();
        if (amount > a.balance) revert InsufficientBalance(id, amount, a.balance);

        a.balance -= amount;
        emit ParentWithdrew(id, amount, a.balance);

        token.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Child actions
    // ------------------------------------------------------------------

    /// @notice Withdraw up to the remaining allowance for the current window, bounded by the balance.
    ///         Child only. Paid to the caller.
    function childWithdraw(uint256 id, uint256 amount) external nonReentrant {
        Account storage a = _existing(id);
        if (msg.sender != a.child) revert NotChild(id, msg.sender);
        if (amount == 0) revert ZeroAmount();

        uint256 window = _windowOf(a.openedAt);
        uint256 spent = a.spentWindow == window ? a.spent : 0;
        uint256 remaining = a.allowance > spent ? a.allowance - spent : 0;
        if (amount > remaining) revert ExceedsAllowance(id, amount, remaining);
        if (amount > a.balance) revert InsufficientBalance(id, amount, a.balance);

        a.spentWindow = window;
        a.spent = spent + amount;
        a.balance -= amount;
        emit ChildWithdrew(id, amount, a.balance, window);

        token.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Number of accounts opened so far. Valid ids are 1..accountCount().
    function accountCount() external view returns (uint256) {
        return _accountCount;
    }

    /// @notice Core account data.
    function account(uint256 id)
        external
        view
        returns (address parent, address child, uint256 allowance, uint256 balance, uint256 openedAt)
    {
        Account storage a = _existing(id);
        return (a.parent, a.child, a.allowance, a.balance, a.openedAt);
    }

    /// @notice Index of the current 7-day window for an account (0 for the first week).
    function currentWindow(uint256 id) external view returns (uint256) {
        return _windowOf(_existing(id).openedAt);
    }

    /// @notice Amount the child has already withdrawn in the current window.
    function spentThisWindow(uint256 id) external view returns (uint256) {
        Account storage a = _existing(id);
        return a.spentWindow == _windowOf(a.openedAt) ? a.spent : 0;
    }

    /// @notice Allowance still available to the child in the current window. Does not consider the
    ///         balance; see `childWithdrawable` for the amount a withdrawal can actually move.
    function remainingThisWindow(uint256 id) public view returns (uint256) {
        Account storage a = _existing(id);
        uint256 spent = a.spentWindow == _windowOf(a.openedAt) ? a.spent : 0;
        return a.allowance > spent ? a.allowance - spent : 0;
    }

    /// @notice The largest amount `childWithdraw` would accept right now: min(remaining, balance).
    function childWithdrawable(uint256 id) external view returns (uint256) {
        uint256 remaining = remainingThisWindow(id);
        uint256 balance = _accounts[id].balance;
        return remaining < balance ? remaining : balance;
    }

    /// @notice Timestamp at which the current window ends and the spent counter resets.
    function windowEndsAt(uint256 id) external view returns (uint256) {
        uint256 openedAt = _existing(id).openedAt;
        return openedAt + (_windowOf(openedAt) + 1) * WINDOW;
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _windowOf(uint256 openedAt) private view returns (uint256) {
        // openedAt is never in the future: it is always a past block.timestamp.
        return (block.timestamp - openedAt) / WINDOW;
    }

    function _existing(uint256 id) private view returns (Account storage a) {
        if (id == 0 || id > _accountCount) revert NoSuchAccount(id);
        a = _accounts[id];
    }

    function _parentAccount(uint256 id) private view returns (Account storage a) {
        a = _existing(id);
        if (msg.sender != a.parent) revert NotParent(id, msg.sender);
    }
}
