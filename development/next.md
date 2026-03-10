### Goal

You are a senior MQL5 engineer and quantitative trading developer.  
Your task is to review and update `OrderFlowAlpha.mq5` (Footprint / Order Flow EA v5.32) to:

- **Eliminate production-blocking bugs and edge cases**
- **Harden the automated trading engine for live execution on real-money accounts**
- **Preserve the existing trading intent and signal logic**

Do **not** change the core trading idea or signal philosophy; focus on correctness, robustness, and safety.

---

### Scope & Constraints

- **Language / Platform**: MQL5 Expert Advisor (`OrderFlowAlpha.mq5`).
- **Core components (do not remove, only improve)**:
  - Footprint rendering & UI (canvas, panel, controls).
  - Order flow scoring and signals: `ComputeOFScore`, `ComputeHFTSignal`, `GetConvictionResult`, etc.
  - Automated trading engine: `OnTick`, `PlaceOrders`, `ManagePositions`, `CalcLot`, `CalcSLTP`, risk filters.
  - Analysis mode vs live trading mode.
- **Style**:
  - Keep existing naming conventions, logging style, and structuring.
  - Avoid adding unnecessary comments; only explain non-obvious design decisions.
  - Prefer small, focused helper functions for complex checks rather than large monoliths.

---

### Files

- Primary EA file: `X/WIP/OrderFlowAlpha.mq5` (single large file containing:
  - Inputs, structs, globals
  - Rendering and UI helpers
  - Order flow and signal computation
  - Trading engine and risk logic
  - `OnInit`, `OnTick`, `OnDeinit`, `OnChartEvent`)

Assume this file is **authoritative**. If you need helpers, add them inside this file unless there is already a clear include pattern.

---

### Key Areas to Audit and Fix

#### 1. Symbol & Broker Property Safety

- **Review** how symbol properties are loaded and cached (pip size, lot step, min/max volume, tick value, stops level).
  - Ensure that for all properties (pip size, lot step, tick value, etc.), **zero or invalid values are handled gracefully**:
    - Provide safe fallbacks (e.g. `g_VolStep`, `g_VolMin`, `g_VolMax`, `g_TickSize`) with clear logs.
    - Avoid hidden `0.0` values that later cause division by zero or invalid risk calculations.
- Confirm that `RefreshSymbolInfo` (or equivalent) is:
  - Called at least on `OnInit` and at any places where symbols or trading conditions may change (e.g. new bar when auto-trade or analysis mode is on).
  - Checks errors on `SymbolInfo*` calls and logs them consistently when something fails.

#### 2. Risk-Based Sizing (`CalcLot`)

- In `CalcLot(double slPoints)` and the wrapper `CalcLot(double slDistPoints, bool isBuy)`:
  - Verify the formula `lot = riskAmt / (slPoints * g_TickSize)` is **correct given how `g_TickSize` is defined**:
    - Confirm `g_TickSize` truly represents *money per point per 1 lot* for the symbol.
    - If not, adjust the computation so a risk percent corresponds to money-at-risk per trade as intended.
  - Ensure `slPoints` cannot be zero when `InpUseRiskPercent` is true:
    - If SL is disabled or not set, fall back explicitly to fixed lot sizing with a clear log entry.
  - Check that:
    - Lot size rounding to step (`g_VolStep`) is safe (no division-by-zero) and works for non-standard steps (e.g. 0.1, 0.01, 0.001).
    - Clamping to `[g_VolMin, g_VolMax]` is always applied and uses valid, non-zero defaults if broker values are missing.
  - Confirm the **direction-aware wrapper** (which applies consecutive-loss-based size reduction) cannot produce lot sizes below broker minimum, and handles all combinations of `InpMaxConsecLosses`, `InpHaltConsecLosses`, and `InpSizeReductionTrades` reliably.

#### 3. SL/TP Computation (`CalcSLTP`)

- In `CalcSLTP`:
  - Confirm that **all SL/TP modes** (`BAR`, `PIPS`, `ATR`) produce prices respecting:
    - Symbol digits / normalization
    - Reasonable distances (no micro-SL/TP inside spread or below stops level).
  - Where ATR-based SL/TP falls back to fixed pips (`ATR == 0`), ensure:
    - Fallback path is always safe (no negative or zero distances).
    - Logs are informative but not spammy.
  - Consider explicitly validating that the final `sl`/`tp` are **at least `SYMBOL_TRADE_STOPS_LEVEL` away** from price for market entries and from pending price for stop entries **before** sending orders; if not, adjust or skip the order with a log.

#### 4. Order Placement (`PlaceOrders`)

- In `PlaceOrders`:
  - Confirm the early exits are correct and exhaustive:
    - `g_autoTrade` / `g_analysisMode` gating.
    - `IsTradeAllowed()` (including trading context and session).
    - `g_bars` size and `level_count` / `total_vol` checks.
    - Adaptive threshold and conviction component count checks.
  - Verify **risk and session filters**:
    - `CheckRiskConditions(direction)`, `CheckSessionTime()`, `CheckHTFTrend(direction)`:
      - Ensure that in **live mode** all relevant filters are enforced before sending a trade.
      - Confirm that in **analysis mode**, filters match the intended “simulation” behavior (e.g. still respect session and HTF filters if desired).
  - For the market vs pending logic:
    - Ensure pending entry prices are always at valid distances:
      - Above market for BUY_STOP, below for SELL_STOP.
      - Respect broker stops level.
      - Skip or adjust if not feasible in current spread/volatility.
  - Confirm that order placement via `trade_Send`:
    - Handles all error codes properly (requotes, connection issues, timeouts, invalid stops, invalid volume).
    - Retries transient errors with bounded backoff where appropriate.
    - Logs failures with enough context (symbol, direction, size, SL/TP, error code).

#### 5. Position Management (`ManagePositions`)

- In `ManagePositions`:
  - Validate the **tick throttling** (`FP_MANAGE_THROTTLE`) is effective and cannot overflow/wrap in a problematic way.
  - Confirm the **min distance** (`SYMBOL_TRADE_STOPS_LEVEL`) check is correctly enforced for:
    - Break-even moves.
    - Trailing stop updates.
  - Review the break-even logic:
    - Ensure it behaves correctly when initial SL is zero vs non-zero.
    - Avoid scenarios where BE never activates due to initial SL configuration, while the user expects it to.
  - Review trailing logic:
    - Verify that trailing never moves SL **away from safety** (only ratchets in favorable direction).
    - Ensure it does not conflict with break-even:
      - The existing guard that logs “trail suppressed by BE” should be correct and not too spammy.
  - Ensure that:
    - Modifications (`TRADE_ACTION_SLTP`) are retried on transient errors only.
    - On persistent failure, logs include position ID, ticket, old SL/TP, and attempted new SL.

#### 6. Pending Order Tracking & Expiry

- Review the arrays `g_pendingTickets` and `g_pendingBarTimes`:
  - Ensure index management when deleting entries is correct (no off-by-one bugs, no leaks or stale references).
  - Make sure **pending expiry** (`InpPendingExpiryBars`) is robust when:
    - Bars are missing or `iBarShift` returns `-1`.
    - Timeframes change (`CHARTEVENT_CHART_CHANGE`).
  - Check that stale pending orders are cleaned when:
    - New signals arrive and `InpCleanOldOrders` is true.
    - Session or risk conditions change (e.g. daily loss hit).

#### 7. Risk Controls & Daily Limits

- Inspect the implementations of:
  - `InpMaxDailyLossPercent`
  - `InpMaxEquityLoss`, `InpMaxEquityProfit`
  - `InpMaxConsecLosses`, `InpHaltConsecLosses`, `InpSizeReductionTrades`
- Ensure these are:
  - Calculated against a consistent reference (e.g. start-of-day balance/equity).
  - **Persisted across EA restarts** as intended via `RiskStateSave` / `RiskStateLoad` (or equivalent).
  - Correctly reset at logical boundaries (e.g. new trading day / session).
- If any of these controls are partially implemented or inconsistent, complete or correct them so that:
  - After hitting a halt condition, trading truly stops until the next intended reset.
  - After size reduction period, size correctly returns to normal, without oscillations or drift.

#### 8. State Persistence & Restart Behavior

- Review all persistence-related functions (`RiskStateSave`, `RiskStateLoad`, `CounterSave`, etc.):
  - Ensure they are called at the right times (`OnInit`, `OnDeinit`, and any necessary intermediate points).
  - Confirm data is stored and restored consistently (no mismatches in formats or fields).
  - Make restart behavior **predictable**:
    - No unintended duplicate signals or positions right after restart.
    - Consecutive-loss and daily-limit gates are preserved correctly across terminal restarts.

#### 9. Performance & Rendering

- Verify that:
  - `CopyTicksRange` in `OnTick` is using correct time units and `g_last_tick_time_ms` is updated in the tick-processing chain to avoid overlap or gaps.
  - Rendering functions (`ThrottledRender`, `Render`, `DrawPanel`, `DrawCumDeltaProfile`) cannot be called in a way that causes unnecessary CPU spikes or race-like behavior.
  - Arrays (`g_bars`, `g_scratchY*`, profile data) are resized and freed safely; no potential large-leak or fragmentation patterns when parameters change frequently.

#### 10. Logging & Diagnostics

- Make logging consistent and production-usable:
  - Trading logs (`LogTradeExec`, etc.) should be:
    - Informative on errors and important transitions (enabling/disabling auto-trade, hitting risk limits, failed modifications, etc.).
    - Not excessively noisy on every tick or small adjustment.
  - Consider adding **guarded debug logs** around critical branches that are hard to reproduce (e.g. ATR fallback, invalid broker properties), but keep them light enough for live accounts.

---

### What to Deliver

When you modify `OrderFlowAlpha.mq5`, ensure you:

- **Preserve the EA’s public interface**:
  - Do not rename user-visible input parameters or change their semantics without strong reason.
- **Do not alter the fundamental trading strategy**:
  - Signals and scoring logic should remain conceptually the same; changes should be limited to correctness and safety.
- **Add or adjust code only where needed**:
  - Prefer local, minimal yet robust fixes over wide refactors.
- **Compile without errors or warnings** in MetaEditor for MQL5.

Finally, provide a brief internal summary (as comments near the top of the file or a small changelog block) listing:

- The functional bugs fixed.
- Important risk/edge-case improvements made.
- Any behavioral changes users should be aware of (e.g. stricter risk halts, safer pending placement).

