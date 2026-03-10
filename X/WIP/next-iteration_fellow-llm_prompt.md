# Next iteration brief — `OrderFlowAlpha.mq5`

You are working on an MQL5 EA in `c:\Users\Ali\Desktop\auction\X`.

## Goal
Make the **signal evaluation / alerting path** production-ready and consistent with the v8.20 engine behavior, **without changing any footprint rendering, UI panel, or marker rendering style**.

## Hard constraints (do not violate)
- Do **not** change footprint/volume rendering, panel UI logic, or canvas drawing behavior.
- Do **not** change `DrawSignalMarkersPass()` “compact signal hint” semantics (direction + HFT + OFS + price) or its layout behavior.
- Preserve existing sound playback and the silent chart arrow object creation behavior in `EvalAndFireSignal()` (same arrow name format, code, color, tooltip structure).
- Keep the structure of `OnTick()`, `ManagePositions()`, `PlaceOrders()`, `OnTradeTransaction()` intact except for minimal wiring needed by the signal changes.

## What to do this iteration (focused scope)

### TDL (do in order)
1. **Port v8.20 signal gating into `EvalAndFireSignal()`**
   - Replace the current bar-index spacing gate (`g_lastSignalBar`) with the v8.20 **time-based** gate using `g_lastSignalBarTime` + `iBarShift(...)`.
   - Add the v8.20 signal-cache guard (bar index + volume) to avoid re-evaluating unchanged live bars.
   - Use `ComputeAdaptiveThreshold()` (not raw `g_signalThreshold`) for buy/sell thresholding.
   - Compute `ofsScore` once, pass it into `ComputeHFTSignal(bi, ofsScore)` to avoid redundant scans.
   - Apply buy/sell permission gating consistent with trading context (respect `InpAllowBuy` / `InpAllowSell` if that’s the project convention; do not introduce new inputs).

2. **Add v8.20 conviction diversity gate to `EvalAndFireSignal()`**
   - Call `GetConvictionResult(bi, isBuySignal)` and enforce `InpMinConvictionComp`.
   - Logging must match v8.20 wording for suppression:
     - `Signal suppressed — only %d conviction component(s) present, need %d. Label: %s`
   - If suppressed, do **not** update the frequency gate state.

3. **Keep UI actions exactly the same**
   - After a valid signal passes all gates:
     - Keep **sound playback** identical to current `EvalAndFireSignal()` (buy sound for buy, sell sound for sell).
     - Keep **chart arrow creation** identical (same object name, code, price offset, colors, tooltip format).
   - You may add additional *logging* (journal) if it does not change UI behavior.

4. **Reconcile runtime state**
   - Ensure `OnInit()` seeds the correct gate variables (move away from `g_lastSignalBar` if it becomes unused).
   - Ensure any “purge/reset” code resets the **time-based** gate (`g_lastSignalBarTime`) appropriately.
   - Remove dead state that becomes unused (only if safe and compile-confirmed).

## Notes / pitfalls to watch
- `EvalAndFireSignal()` evaluates the **live bar** (`bi = nBars-1`). This must remain.
- The project already has `g_sigCacheBarIdx` and `g_sigCacheVol` globals; use them as in v8.20.
- Threshold semantics must be symmetric:
  - `isBuySignal  = (hftScore >=  effThresh)`
  - `isSellSignal = (hftScore <= -effThresh)`
- Avoid performance regressions: do not add additional full scans of `levels[]` inside the tick path.

## Acceptance criteria
- Compiles with **no new warnings**.
- `EvalAndFireSignal()` uses:
  - `ComputeAdaptiveThreshold()`
  - `GetConvictionResult(...)` + `InpMinConvictionComp` gate
  - `g_lastSignalBarTime` + `iBarShift(...)` spacing
  - `ComputeHFTSignal(bi, ofsScore)` reuse
- Existing UI/visual output remains unchanged for:
  - footprint rendering
  - marker drawing style/format
  - sound + arrow object behavior

## Minimal test plan
- Compile in MetaEditor.
- Run in visual mode and confirm:
  - arrows still appear with same names/tooltips
  - sounds still play on valid signals
  - signal spacing respects `InpSignalFreqBars` across timeframe changes/reloads
  - lowering/raising adaptive threshold inputs changes firing behavior (without touching UI)

