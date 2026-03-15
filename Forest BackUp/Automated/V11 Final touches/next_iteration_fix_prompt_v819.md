# OrderFlowEA v8.19 — Next Iteration Fix Prompt

You are patching **`OrderFlowEA_v819.mq5`** for the **next iteration only**.

## Objective
Apply a focused, production-readiness patch set that fixes the highest-priority remaining issues without changing strategy intent, signal philosophy, or unrelated code paths.

## Constraints
- Keep the patch **surgical** and backward-compatible where possible.
- Do **not** refactor for style only.
- Do **not** change entry/exit logic unless required by the tasks below.
- Preserve existing logging style and changelog style.
- Add concise inline comments only where they materially reduce future maintenance risk.
- Keep all fixes deterministic and broker-safe for live MT5 deployment.

## TDL (next iteration only)

### 1) Make account/risk halts internally consistent
The EA currently mixes **instance-scoped persistence** with **account-wide equity measurements**.

#### Required fix
- Decide and implement **one explicit model** for daily/equity halts:
  - either **account-scoped** risk governance, or
  - **EA-instance-scoped** risk governance using only this EA's attributable P&L/exposure.
- Make the implementation, variable naming, logging, and comments fully consistent with that model.
- Remove any misleading comments that claim instance scoping if the calculation is still account-wide.

#### Minimum acceptance criteria
- No comment/code mismatch remains around daily-loss/equity halt scope.
- Restart behavior remains correct.
- Halt decisions are reproducible and explainable from logs.

---

### 2) Harden retry duplicate-detection logic
The current retry reconciliation is too loose because it can match on **magic + symbol + volume** without enough trade identity.

#### Required fix
- Strengthen the ambiguous-send reconciliation in `trade_Send()`.
- Match retries using a more reliable identity set, such as a combination of:
  - direction,
  - symbol,
  - magic,
  - volume,
  - recent timestamp window,
  - request comment/tag,
  - and/or expected price proximity.
- Ensure the retry guard cannot incorrectly treat an older unrelated position/deal as the fill for the current request.

#### Minimum acceptance criteria
- A second intended trade cannot be falsely “deduped” just because another same-volume trade already exists.
- A true broker-side fill after timeout/connection ambiguity is still detected and not resent.
- Logging clearly states why a retry was suppressed.

---

### 3) Keep position management alive when entries are halted
Open-position protection should remain reliable when **new entries are blocked** for risk or operational reasons.

#### Required fix
- Review and adjust gating so that **break-even, trailing-stop, and pending-order cleanup/expiry** continue to function whenever it is safe and technically possible, even if new entries are disabled by a halt state.
- Separate **entry permission** from **position-management permission** more cleanly.
- Do not allow this change to re-enable new trade placement.

#### Minimum acceptance criteria
- Risk halts block new entries only.
- Existing positions can still be managed.
- Pending-order maintenance remains deterministic.

---

### 4) Make pending-order lifecycle recovery fully robust
Pending-order expiry recovery on init was improved, but the order lifecycle should be robust against restarts, fills, deletions, and stale in-memory state.

#### Required fix
- Audit the `g_pendingTickets` / `g_pendingBarTimes` tracking lifecycle end-to-end.
- Ensure the tracking set is correctly updated when pending orders are:
  - created,
  - deleted manually,
  - expired,
  - filled,
  - rejected,
  - or missing from broker state after restart.
- Prevent stale array entries from accumulating or causing silent no-ops.

#### Minimum acceptance criteria
- After restart, the EA tracks only real live pending orders belonging to this instance.
- Filled/deleted/missing pending orders are removed from tracking cleanly.
- Expiry logic cannot silently stop working because of stale local state.

---

### 5) Add a short verification pass for production safety
After patching, do a compact self-audit of all touched logic.

#### Required output
Provide a brief implementation note covering:
- what changed,
- why it was changed,
- any assumptions,
- and a short test checklist for:
  - restart recovery,
  - timeout/retry behavior,
  - pending expiry,
  - risk halts,
  - and position management continuity.

## Deliverable
Return:
1. the patched MQL5 code,
2. a concise summary of exactly what was changed,
3. any residual risks that should be deferred to a later iteration.
