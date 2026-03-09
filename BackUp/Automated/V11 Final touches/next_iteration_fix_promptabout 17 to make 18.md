# Next Iteration Fix Prompt — OrderFlowEA_v817.mq5

You are patching **only the next iteration** of `OrderFlowEA_v817.mq5`.

Work like a senior MQL5 engineer reviewing a live trading EA. Focus on **production-readiness, correctness, and operational safety**. Do **not** redesign the strategy. Keep existing behavior unless a bug fix requires a small, explicit change.

## Objective
Implement the fixes below with minimal surface area, preserve current inputs and trading model where possible, and add concise inline comments only where the fix is non-obvious.

## TDL

### 1) Fix monthly new-day reset bug
- `CheckNewDay()` currently compares/stores only `dt.day`.
- This breaks on month/year rollover when the calendar day number repeats (for example, Jan 5 -> Feb 5).
- Replace the day-only state with a full calendar date key that is safe across month/year boundaries.
- Update persistence accordingly.
- Acceptance: the EA must trigger a new-day reset exactly once per actual trading date, including across month/year rollovers and restarts.

### 2) Fix trade/order ticket identity mismatch in chart object lifecycle
- Entry visuals are created using the ticket returned by `trade_Send()` / `res.order`.
- Position management and exit handling use position identifiers (`PositionGetTicket`, `DEAL_POSITION_ID`).
- This causes SL/TP lines and trade objects to drift, fail to update, or fail to delete on brokers where order ticket != position ticket.
- Introduce a consistent identifier strategy for live positions.
- Ensure all of the following use the same logical key:
  - entry drawing
  - SL line updates
  - exit drawing / cleanup
  - any position-linked visual object naming
- Acceptance: live market orders have one coherent visual lifecycle from entry through trailing/breakeven updates to exit.

### 3) Re-clamp/revalidate SL/TP on retry price refresh in `trade_Send()`
- On requote / price-changed retries for market orders, `req.price` is refreshed but SL/TP are not recomputed against the new reference price.
- This can leave stops inside broker min distance or distort intended protection during fast markets.
- Recompute validation/clamping each retry using the refreshed fill price.
- Keep the caller-facing “actual sent SL/TP” logging accurate.
- Acceptance: each retry attempt sends broker-valid SL/TP relative to the current retry price, and logs the final values actually submitted.

### 4) Replace lot sizing point-value shortcut with a broker-robust risk calculation
- `CalcLot()` currently derives point value from `SYMBOL_TRADE_TICK_VALUE * (_Point / tickSize)`.
- This is not robust across CFDs, futures, non-FX symbols, or brokers with inconsistent tick-value metadata.
- Use a safer method based on `OrderCalcProfit()` (or an equivalently broker-robust approach) to estimate 1-lot loss at the proposed SL distance, then size from target risk.
- Keep the existing fallback path only if the robust path cannot be computed.
- Acceptance: risk-based sizing reflects actual account-currency loss per 1 lot for the symbol and direction.

### 5) Align account-level halt semantics with deployment model
- Daily/equity guards are evaluated from account equity/balance, but state persistence is scoped per symbol+magic.
- This creates inconsistent behavior in multi-symbol / multi-instance deployment.
- Choose one consistent model for this iteration and implement it cleanly:
  - either make the risk state explicitly account-level, or
  - make the guards clearly EA-instance scoped.
- Prefer the smallest safe change that removes cross-instance inconsistency.
- Update comments/logs to reflect the chosen model.
- Acceptance: multiple instances on the same account cannot disagree due to mixed account-level measurement and per-instance persistence.

## Implementation rules
- Keep the patch narrow and production-oriented.
- Do not change signal logic except where required by the fixes above.
- Preserve existing inputs unless a replacement is required for correctness.
- Preserve backward compatibility of logs/comments where practical.
- Add/update validation only if directly needed by the fixes above.

## Deliverables
1. The patched `OrderFlowEA_v817.mq5` code.
2. A short changelog for this iteration only.
3. A brief validation note describing how each TDL item was addressed.

## Review standard
Prioritize:
1. correctness under live execution,
2. risk-control integrity,
3. broker compatibility,
4. deterministic state behavior across restart,
5. minimal regression risk.
