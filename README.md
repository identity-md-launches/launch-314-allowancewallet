# Pocket (PCKT) and AllowanceWallet

Sepolia project launch: a fixed-supply ERC-20 launch token plus one application contract that holds
weekly PCKT pocket-money accounts between a parent and a child.

| Contract          | File                     | Constructor args | Owner |
|-------------------|--------------------------|------------------|-------|
| `LaunchToken`     | `src/LaunchToken.sol`    | none             | none  |
| `AllowanceWallet` | `src/AllowanceWallet.sol`| `(address token)` = `$token` | none |

ABI exports: `docs/abi/LaunchToken.json`, `docs/abi/AllowanceWallet.json`.

## The allowance is not a guarantee

A parent can lower the allowance to zero or withdraw the whole balance at any moment, including in the
middle of a window and including funds the child "could" still have taken this week. The weekly
allowance is a **ceiling on the child**, never a promise to the child. The website must say this.

## LaunchToken (PCKT)

- Name `Pocket`, symbol `PCKT`, 18 decimals.
- Exactly 1,000,000,000 PCKT (10^27 minor units) minted once to `msg.sender` in the constructor.
  The ProjectFactory is that sender, so it receives the supply and splits it between the ETH/PCKT
  launch pool and the reward distributor.
- No constructor arguments, no owner, no mint, no pause, no blocklist, no fee, no upgrade. It is
  OpenZeppelin `ERC20` with a one-line constructor.

## AllowanceWallet

### Rules

- `openAccount(child, weeklyAllowance, deposit)`: caller becomes the parent. `child` must be non-zero
  and different from the caller. `deposit` (may be 0) is pulled with `safeTransferFrom` as the opening
  balance. Ids start at 1 and increase by one. A parent may open many accounts; a child may be in many;
  the same pair may have several accounts, each with its own books.
- Windows are 7-day periods anchored at the account's opening timestamp:
  `window = (block.timestamp - openedAt) / 7 days`. `windowEndsAt(id)` is the first second of the next
  window. At that second the spent counter reads as zero again; one second before it does not.
- `childWithdraw(id, amount)`: child only. Requires `amount > 0`,
  `amount <= weeklyAllowance - spentThisWindow` and `amount <= balance`. Paid to the caller.
  Unspent allowance never rolls over: after any number of skipped windows the child still has exactly
  one allowance available.
- `topUp(id, amount)`: parent only, `amount > 0`, pulled with `safeTransferFrom`.
- `setAllowance(id, newAllowance)`: parent only, effective immediately. What the child already
  withdrew this window still counts, so lowering below the spent amount leaves zero remaining until
  the next window. Setting 0 freezes the child.
- `parentWithdraw(id, amount)`: parent only, any part of the balance, at any time, paid to the caller.
- Withdrawals only ever go to `msg.sender`. There is no third-party recipient parameter anywhere.

### Views

`token()`, `WINDOW()` (604800), `accountCount()`, `account(id)` returning
`(parent, child, allowance, balance, openedAt)`, `currentWindow(id)`, `spentThisWindow(id)`,
`remainingThisWindow(id)` (allowance minus spent, ignoring balance), `childWithdrawable(id)`
(`min(remaining, balance)`, the number a child UI should show), `windowEndsAt(id)`.
All id-taking views revert with `NoSuchAccount` for id 0 or an id above `accountCount()`.

### Events

`Opened(id, parent, child, weeklyAllowance, deposit)` with id, parent and child indexed;
`ToppedUp(id, amount, newBalance)`; `AllowanceSet(id, newAllowance)`;
`ChildWithdrew(id, amount, newBalance, window)`; `ParentWithdrew(id, amount, newBalance)`.
A website builds the parent view from `Opened` filtered by parent and the child view from `Opened`
filtered by child, then reads the current numbers from the views.

### Errors

`ZeroToken`, `ZeroChild`, `ChildIsCaller`, `NoSuchAccount(id)`, `NotParent(id, caller)`,
`NotChild(id, caller)`, `ZeroAmount`, `ExceedsAllowance(id, requested, remaining)`,
`InsufficientBalance(id, requested, balance)`.

### Security properties

- Checks-effects-interactions everywhere, plus OpenZeppelin `ReentrancyGuard` on every function that
  moves tokens. All value moves through `SafeERC20`.
- No owner, admin, pause, upgrade, delegatecall, selfdestruct, payable function, `receive` or
  `fallback`. The contract can never hold ETH.
- Invariant: the contract's PCKT balance equals the sum of all account balances. PCKT sent directly
  to the contract (not through `openAccount`/`topUp`) is not credited to anyone and is stuck; there is
  no sweep function by design.
- `openedAt` is stored as `uint64`; timestamps overflow it in year 5.8e11.

## Assumptions

- PCKT is a plain fixed-supply ERC-20 with no transfer fee, so the amount pulled is the amount
  credited. The wallet is not designed for fee-on-transfer or rebasing tokens.
- Users obtain PCKT by swapping Sepolia ETH in the ETH/PCKT launch pool the factory seeds. The wallet
  holds no PCKT at deploy and never needs any.
- Window arithmetic uses `block.timestamp`. A builder can nudge it by seconds, which can move a
  withdrawal across a window boundary a few seconds early. Since the allowance is per window and the
  parent controls the balance, the most this yields is one allowance a few seconds early.
- The workflow's generic guidance mentions burns to `0x...dEaD`; AllowanceWallet has no burn action,
  so no such transfer exists here.

## Deployment parameters

The launch goes through the IdentityMD ProjectFactory on Sepolia (chain id 11155111) using
`launch.json` written by the manifest step. Expected shape:

- launch token: `LaunchToken` (no constructor args, 18 decimals, supply 10^27)
- contracts: `[{ name: "AllowanceWallet", constructorArgs: ["$token"] }]`
- pool: no hook, paired against native ETH, fee 3000, tick spacing 60,
  `initialPrice` `79228162514264337593543950336`; the deployer derives the opening price from policy.

The factory is `msg.sender` for both constructors. Nothing in either constructor depends on that:
the token mints to `msg.sender` (which is what the factory checks), and the wallet only stores the
token address. There is no `$owner` because there is no owner.

`script/Deploy.s.sol` is a local reference only. It reads no keys and no RPC secrets; the sole
environment input is `EXPECTED_CHAIN_ID` (0 or unset disables the check; otherwise only 31337 and
11155111 are accepted). Tests call `Deploy.deploy()` directly.

## Build and test (offline)

```
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

Compiler pinned to solc 0.8.26, optimizer 200 runs, `evm_version = "paris"`, `bytecode_hash = "none"`.
Dependencies are vendored as plain files under `lib/` (forge-std 1.16.2 and the ERC20, SafeERC20 and
ReentrancyGuard subset of OpenZeppelin Contracts 5.7.0); no submodules, no network.

## Operational responsibilities

- Nobody operates the contracts. There are no privileged roles, no keepers, no oracles, no upgrades.
- Parents are responsible for their own balances: funding, allowance changes and withdrawals are
  theirs alone. Losing the parent key strands the account's balance except for what the child can
  withdraw at the allowance rate.
- Children can only ever withdraw to their own address at the allowance rate.
- The website must show that PCKT comes from the launch pool, must run an Approve step before
  `openAccount` and `topUp`, and must state that the allowance is not a guarantee.
- Tests passing is not an audit. `REVIEW.md` records the independent adversarial review that
  accompanied this implementation; a separate reviewer sees source and manifest before release.

## Test map

| Requirement                                  | Test                                                                  |
|----------------------------------------------|-----------------------------------------------------------------------|
| Exact 7-day boundary (second before / of)    | `test_exactWindowBoundary`, `testFuzz_windowArithmetic`               |
| No rollover                                  | `test_noRolloverOfUnspentAllowance`, `test_noRolloverAcrossSkippedWindows`, `test_spentCounterFromOldWindowIsIgnoredNotCarried` |
| Allowance changes mid-window                 | `test_raiseAllowanceMidWindowKeepsSpent`, `test_lowerAllowanceBelowSpentLeavesZeroUntilNextWindow`, `test_zeroAllowanceFreezesChildAndUnfreezesWhenRaised` |
| Role checks on every function                | `test_roleChecks_*`, `test_unknownIdRevertsEverywhere`                 |
| Cross-account isolation                      | `test_crossAccountIsolation`, `test_accountsWithDifferentOpeningTimesHaveIndependentWindows` |
| Conservation invariant                       | `test_contractBalanceEqualsSumOfAccountBalances`, `invariant_contractBalanceEqualsSumOfAccountBalances` |
| Fuzz over withdrawal sequences and warps     | `testFuzz_withdrawalSequencesAndWarps`, `testFuzz_mixedParentAndChildActionsWithWarps`, `testFuzz_totalWithdrawnBoundedByAllowancePerWindow` |
| Splitting calls / across windows             | `test_childWithdrawRejectsOverAllowanceBySplitting`, `invariant_childNeverExceedsAllowanceInAnyWindow` |
| Reentrancy                                   | `test/AllowanceWalletReentrancy.t.sol` (hostile callback token)        |
| Token supply and transfer                    | `test/LaunchToken.t.sol`                                               |
