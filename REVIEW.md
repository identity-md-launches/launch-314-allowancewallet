# Review: AllowanceWallet and LaunchToken

Scope: `src/LaunchToken.sol`, `src/AllowanceWallet.sol`, `script/Deploy.s.sol`, the test suite and
`foundry.toml`, read as an attacker against the approved workflow. This is the implementer's own
adversarial pass, recorded so the independent reviewer can start from it rather than from zero. It
does not replace the separate independent review the workflow requires.

## Attack surface walked

### Window arithmetic off-by-one

- `window = (block.timestamp - openedAt) / 7 days`; `windowEndsAt = openedAt + (window + 1) * 7 days`.
  At `t = openedAt + 7 days - 1` the division yields 0; at `t = openedAt + 7 days` it yields 1.
  Verified by `test_exactWindowBoundary` (both seconds, two consecutive boundaries) and by
  `testFuzz_windowArithmetic` for arbitrary opening times and elapsed times up to 2^48 seconds.
- `openedAt` is never in the future (it is a past `block.timestamp`), so the subtraction cannot
  underflow. Stored as `uint64`; safe for any realistic timestamp.
- The spent counter is tagged with its window index rather than reset by a write, so skipping many
  windows cannot accumulate anything and there is no "stale spent" from a previous window
  (`test_spentCounterFromOldWindowIsIgnoredNotCarried`, `test_noRolloverAcrossSkippedWindows`).
- Finding: none.

### Withdrawing more than the allowance by splitting calls or across windows

- Every `childWithdraw` recomputes `remaining = allowance - spent` (saturating) and adds the amount
  to `spent` before transferring. Splitting into N calls cannot exceed it
  (`test_childWithdrawRejectsOverAllowanceBySplitting`).
- Across windows the child gets exactly one allowance per window, never more, regardless of how many
  windows elapsed unused (`testFuzz_totalWithdrawnBoundedByAllowancePerWindow`,
  `invariant_childNeverExceedsAllowanceInAnyWindow`).
- Timing: a builder can shift `block.timestamp` by a few seconds, at most crossing one boundary a few
  seconds early. That yields one allowance slightly early, never two in one window. Documented in
  README as an accepted property.
- Finding: none.

### Cross-account confusion

- Every id-taking function resolves the account through `_existing(id)`, which rejects 0 and ids
  above `accountCount`. Role checks compare `msg.sender` to that specific account's parent or child.
- Balances are per account; the contract's total holding is never consulted for a withdrawal, so a
  parent cannot drain another account's funds even though the tokens sit in the same address
  (`test_crossAccountIsolation`, `invariant_contractBalanceEqualsSumOfAccountBalances`).
- The same parent-child pair may open several accounts; each has its own spent counter and window
  anchor (`test_accountsWithDifferentOpeningTimesHaveIndependentWindows`).
- Finding: none.

### A parent or child moving another account's PCKT

- Withdrawals are always to `msg.sender`; there is no recipient parameter.
- A stranger, the other account's parent, or the other account's child are rejected on `topUp`,
  `setAllowance`, `parentWithdraw` and `childWithdraw` (`test_roleChecks_*`, handler
  `strangerCallsEverything` in the invariant run).
- Finding: none.

### Reentrancy and token behaviour

- CEI order in all four state-changing functions: role and amount checks, storage writes, event,
  then the single external token call. `nonReentrant` on every function that calls the token.
- Tested with a hostile ERC-20 that re-enters on every transfer
  (`test/AllowanceWalletReentrancy.t.sol`): re-entry into any state-changing function reverts with
  `ReentrancyGuardReentrantCall`; a view during the payout already sees the final state.
- PCKT is OpenZeppelin `ERC20` and returns `true`; `SafeERC20` is still used so a false return or a
  no-return token cannot silently succeed. Fee-on-transfer is out of scope by the workflow
  ("the amount pulled is the amount credited") and stated in README.
- Finding (informational): tokens transferred directly to the contract are unrecoverable. This is
  by design (no sweep = no privileged role); documented.

### Constructor and factory interaction

- `LaunchToken` mints to `msg.sender` and has no other constructor behaviour, which is exactly what
  the factory checks. `AllowanceWallet(address token)` stores the token and rejects zero; it does
  not read `msg.sender`, so there is no accidental factory ownership.
- Neither runtime contains `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; wallet runtime is about 3.4 KB
  and token runtime about 1.8 KB, both far below the 24 KB EIP-170 limit.
- Both protected floor tests (`Token.protected.t.sol`, `Project.protected.t.sol`) were re-run from
  `test/scratch/` with the real creation code, CREATE2 addresses computed with `cast create2`,
  chain id 11155111 and one project contract: 8 of 8 passed.

### Arithmetic

- No `unchecked` blocks. `allowance - spent` is guarded by a `>` comparison. `a.balance += amount`
  is bounded by total supply (10^27) in practice and by `uint256` in theory.
- No division except the window index. No casts other than `uint64(block.timestamp)`.

### Environment and test hygiene

- No test reads or sets environment variables. The deploy script's `run()` reads only
  `EXPECTED_CHAIN_ID` through `vm.envOr`; its logic is in `deploy()` and `checkChain()`, both
  covered directly by tests.
- Tests use a non-round start timestamp (1,700,000,001) and fuzz opening times so boundary
  arithmetic is not accidentally aligned.
- Suite: 63 tests (44 unit, 7 token, 4 fuzz with 256 runs each, 4 reentrancy, 4 invariants with
  64 runs x 64 depth). `forge build --offline`, `forge test --offline`, `forge fmt --check` and
  `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` all pass on solc 0.8.26.

## Findings and disposition

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | Info | Stray PCKT sent directly to the wallet is stuck. | Accepted: a sweep would need a privileged role, which the workflow forbids. Documented in README. |
| 2 | Info | `remainingThisWindow` ignores the balance, so a UI showing it alone can overstate what the child can take. | Mitigated: `childWithdrawable(id)` added and documented as the number to show. |
| 3 | Info | Builder timestamp drift can open a new window a few seconds early. | Accepted: bounded to one allowance per window; parent controls the balance. Documented. |
| 4 | Info | Losing the parent key strands the balance beyond the allowance drip. | Accepted: inherent to a no-admin design. Documented under operational responsibilities. |

No findings of medium or higher severity. Nothing in this review changes the requested behaviour.

## What the tests do not cover

- Real Sepolia gas and the factory's CREATE2 flow beyond the protected floor replay.
- A malicious parent front-running a child's withdrawal with `parentWithdraw` or `setAllowance(0)`.
  This is allowed by design (the allowance is not a guarantee) and is not a bug, but the website must
  say so.
- Token semantics other than PCKT. The wallet is deployed once with the launch token and is not
  meant to be reused with other tokens.
