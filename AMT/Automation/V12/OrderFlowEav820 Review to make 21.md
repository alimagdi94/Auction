# Next Iteration Patch Prompt — OrderFlowEA_v820.mq5

You are patching **only the next production iteration** of this EA.

## Goal
Apply a focused hardening pass that fixes the highest-risk production issues without changing the strategy thesis, signal model, chart UX, or parameter surface more than necessary.

## Scope rules
- Keep the patch set tight and production-oriented.
- Preserve existing trading intent unless a behavior is clearly unsafe or inconsistent.
- Prefer small, auditable changes over refactors.
- Add concise comments only where they improve operational clarity.
- Do **not** introduce speculative optimizations or new features outside this iteration.

## TDL

### 1) Fix trade-operation success handling
Harden all trade operations so success is based on **broker retcode semantics**, not only the boolean return value of `OrderSend()`.

#### Required work
- Audit and fix:
  - `trade_Send()`
  - SL/TP modification flow in `ManagePositions()`
  - `trade_OrderDelete()`
- Treat an operation as successful only on the appropriate success retcodes for the action type.
- Keep retry behavior only for retryable retcodes / transient failures.
- Improve logs so every failed or ambiguous trade operation records:
  - action
  - order type / ticket / position id when applicable
  - retcode
  - requested price / SL / TP / volume
- Do not silently mark a request as successful if the server accepted the request envelope but rejected execution.

#### Acceptance criteria
- No code path reports success when `OrderSend()` returned true but the trade server did not actually execute / place / modify / delete the request.
- Retry logic remains bounded and auditable.

---

### 2) Make risk accounting internally consistent
The code comments declare an **instance-scoped** risk model, but current balance/equity logic is still polluted by other account activity.

#### Required work
- Rework daily-loss / equity-halt accounting so the chosen scope is **explicit and mathematically consistent**.
- Pick one model and implement it end-to-end:
  - either truly instance-scoped, using this EA instance’s realized + floating PnL only,
  - or explicitly account-scoped, with comments/logging/state naming updated to match.
- If instance-scoped is kept, do **not** rely on raw account balance/equity snapshots alone; account for the fact that other strategies can realize PnL intraday.
- Ensure `CheckDailyLoss()` and equity halt logic use the same scope and same baseline model.
- Update comments and logs so they no longer overstate isolation if the math is not isolated.

#### Acceptance criteria
- Daily-loss and equity-halt calculations cannot be distorted by unrelated account activity under the declared model.
- Baseline naming/comments/logging match actual behavior.

---

### 3) Strengthen duplicate-send reconciliation
Current retry dedup is improved, but it still relies on soft matching and can misidentify an older fill as the current request in scale-in or burst-trading conditions.

#### Required work
- Introduce a stronger per-request identity / correlation mechanism for live sends.
- Make retry reconciliation prefer an exact request identity over approximate matching on price/volume/direction.
- Keep compatibility with broker comment truncation limits if relevant; use the strongest safe identifier available.
- Ensure the dedupe path is still safe across:
  - requotes
  - timeouts
  - connection interruptions
  - fast sequential entries in the same direction

#### Acceptance criteria
- A prior same-symbol / same-direction / same-volume trade cannot be falsely claimed as the current retry’s fill when a more exact request identity is available.
- Logs clearly show how reconciliation was established.

---

### 4) Harden pending-order lifecycle recovery
Pending tracking is much better, but make the in-memory mirror more robust under broker-side state changes and restarts.

#### Required work
- Review the full lifecycle for pending orders:
  - placement
  - restart recovery
  - fill
  - manual deletion
  - broker expiration / rejection / disappearance
- Ensure the local tracking arrays cannot retain stale entries or drift from the live broker state.
- Ensure restart recovery does not duplicate registrations.
- Make expiry logic safe if ticket lookup fails or bar lookup returns an unexpected result.
- Add lightweight logging only where it materially improves operations/debuggability.

#### Acceptance criteria
- The pending tracking set remains a faithful mirror of live pending orders for this EA instance.
- Expiry management cannot act on stale or invalid local entries.

---

### 5) Separate entry permission from protective management semantics
Keep the current intent that open positions should still be managed even when new entries are blocked, but make the gating model explicit and robust.

#### Required work
- Review all gates affecting:
  - new entries
  - pending cleanup / expiry
  - SL/TP maintenance
  - break-even / trailing
- Ensure operational states cannot accidentally disable protective management for live exposure.
- Keep analysis mode isolated from live trade management.
- Clarify the gating model in comments so future changes do not reintroduce coupling.

#### Acceptance criteria
- New-entry blocking and live-risk management are clearly separated and consistently enforced.
- No halt/disable path unintentionally strands open risk without management.

## Deliverable format
Return:
1. the patched MQL5 code,
2. a short changelog for this iteration only,
3. a brief validation summary covering the five items above.

## Non-goals for this iteration
- No signal-model redesign.
- No footprint math rewrite.
- No cosmetic refactor of unrelated modules.
- No parameter expansion unless required for correctness.
