# Next iteration brief — `WIP/OrderFlowAlpha.mq5`

You are working on an MQL5 EA under `c:\Users\Ali\Desktop\auction\X\WIP`.

The current state:
- Signal engine (`ComputeOFScore`, `ComputeCVDSlope`, `ComputeHFTSignal`, `EvalAndFireSignal`) is aligned with v8.20 and uses **time-based spacing** via `g_lastSignalBarTime + iBarShift(...)`.
- Trading engine (`PlaceOrders`, `ManagePositions`, `trade_Send`, `CheckRiskConditions`) is unified and analysis-safe (no real orders in `g_analysisMode`).
- UI (footprint rendering, panel, signal markers) is production-quality and should not be visually altered.

This iteration is small but important: **finish cleaning up legacy signal-gating state and improve observability** so the behavior is predictable in production.

## Hard constraints
- Do **not** change:
  - Footprint/volume rendering or panel layout.
  - `DrawSignalMarkersPass()` geometry/layout and tooltip content.
  - Trading behavior in `PlaceOrders` / `ManagePositions` (no new order logic).
- Do **not** weaken any existing risk gates or conviction/threshold logic.

## TDL (do in this order)

1. **Make `g_lastSignalBarTime` the sole signal-spacing gate**
   - `EvalAndFireSignal()` already uses `g_lastSignalBarTime` and ignores `g_lastSignalBar`.
   - Update all places that intend to “reset the signal frequency gate” to operate on the **time-based** variable:
     - `OnInit()` seeding.
     - Signal history purge helper that currently sets `g_lastSignalBar = -9999`.
     - Panel edit handlers that change:
       - `g_signalFreqBars` (frequency input edit).
       - `g_signalThreshold` (threshold input edit).
     - The signal enable/disable toggle (signals button).
   - For each of these, ensure that:
     - `g_lastSignalBarTime` is reset to `0` (or an equivalent “no prior signal” sentinel).
     - Any references to resetting `g_lastSignalBar` as a gate are removed or updated to comments that refer to `g_lastSignalBarTime` instead.

2. **Remove or neutralize dead `g_lastSignalBar` state**
   - If, after step 1, `g_lastSignalBar` is no longer read anywhere:
     - Remove the variable and its resets, and fix any comments that refer to it.
   - If you decide to keep it for UI-only purposes, make that explicit in comments and ensure it is not used as a logic gate anywhere.

3. **Improve signal observability (logging) without changing UI**
   - `EvalAndFireSignal()` logs **suppressed** signals via `LogSignal(...)`, but successful signals are only visible indirectly via trading logs/orders.
   - Add a single `LogSignal(...)` call when a signal passes all gates, with content structurally similar to v8.20 (symbol, TF, HFT/OFS, conviction label/components, bar time).
   - This log must **not** change sounds or chart-arrow creation; it should be **journal-only**.

## Acceptance criteria
- All “reset frequency gate” actions now operate on `g_lastSignalBarTime`, not the legacy `g_lastSignalBar` index.
- Either:
  - `g_lastSignalBar` is removed completely, or
  - It is clearly documented as non-functional/visual-only state and not used for gating.
- Successful signals emit a clear `LogSignal(...)` entry, while visual and trading behavior remains unchanged.

