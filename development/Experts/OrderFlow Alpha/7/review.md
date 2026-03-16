## OrderFlowAlpha.mq5 v7 — Production Readiness Review

**Decision: GO for controlled production rollout**

### Scope of review
- **File**: `OrderFlowAlpha.mq5` (v5.32 footprint + v7 trading engine)
- **Focus**: signal engine correctness, risk controls, stability under live tick flow, and parameter safety (including `Hidden SL 500`–style .set profiles).

### Reasons for GO
- **Signal engine fixes applied**: 
  - Flat ticks on non-tradeable symbols are now **neutral**, removing the prior buy‑side bias in `Classify()`.
  - `ComputeCVDSlope()` uses **true cumulative delta changes**, not per‑bar delta/volume ratios, so CVD momentum aligns with visual CVD.
  - `ComputeHFTSignal()` includes **active-weight rescaling**, preventing score compression when some components are neutral and allowing both buy and sell scores to reach thresholds symmetrically.
- **Asymmetric threshold support**:
  - Separate inputs and runtime state for **buy** and **sell** thresholds (including validation in `OnInit`), so you can bias the engine conservatively in either direction without code changes.
  - Adaptive threshold logic remains conservative and falls back cleanly when ATR data is unavailable.
- **Risk and session controls are production‑grade**:
  - Hard guards for: daily loss %, equity profit/loss stops, max concurrent positions, floating-loss portfolio guard, soft stops, max hold time, and SL cooldown.
  - All risk‑critical inputs are validated in `OnInit`; misconfiguration causes a clear `INIT_PARAMETERS_INCORRECT` failure instead of undefined runtime behaviour.
  - Conviction gating (`GetConvictionResult` + `InpMinConvictionComp`) is wired through *both* alerts and order placement, so UI and execution share the same idea of “high probability”.
- **Runtime safety & performance**:
  - `OnTick()` is non‑blocking: uses bounded `CopyTicksRange`, incremental tick processing, and throttled rendering (`ThrottledRender()`), so there is no tight loop that can freeze MT5.
  - History reloads (`g_needs_reload`) and panel interactions are deferred to tick context and guarded, avoiding expensive work in chart events.
  - All trade operations go through a hardened `trade_SendCore()` with min‑distance, filling‑mode detection, and limited retries.

### Known behavioural characteristics (intended, not bugs)
- **“Stops trading” states are guard‑driven, not freezes**:
  - If `InpMaxFloatingLoss` or equity/daily‑loss limits are hit, the EA **deliberately halts new entries** via `g_equityHalted` / `g_dailyLossHalted` until re‑init; this is by design for capital protection.
  - If `InpMaxPositions` is reached, no new trades are placed until positions are closed.
  - Session and HTF filters can legitimately suppress signals/trades for long periods depending on market hours and trend.
- **Hidden SL profiles (e.g. 500‑pip soft stop)**:
  - Very wide soft stops plus a low `InpMaxFloatingLoss` can cause early **portfolio halts** even when individual trades are far from their soft stop; this is configuration‑driven, not a logic error.

### Preconditions and recommendations for production
- **Before live deployment**:
  - Verify a **symbol‑specific .set** with:
    - `InpSignalThreshold` / `InpSignalThresholdSell` tuned for the instrument and timeframe.
    - `InpMaxFloatingLoss`, `InpMaxDailyLossPercent`, and `InpMaxPositions` aligned with account size and expected drawdown for 500‑pip soft stop profiles.
    - `InpHTFEnable` / `InpSessionEnable` configured explicitly so long flat periods are understood as filter behaviour, not bugs.
  - Run at least one walk‑forward or live‑demo session to confirm:
    - Balanced BUY/SELL distribution in ranging markets.
    - No one‑sided bias on non‑Last symbols (forex) during low‑volatility hours.
    - Equity and floating‑loss guards trip as expected and are visible in logs.
- **Operational guidance**:
  - Treat equity/floating‑loss halts as **emergency brakes**; clearing them requires **re‑attaching or re‑initialising** the EA after reviewing account risk.
  - Keep MT5 logging at least at “Trades only” in production so risk and order events are auditable.

### Final verdict
With the latest v7 signal‑engine fixes, asymmetric thresholds, and extensive risk/validation guards, `OrderFlowAlpha.mq5` is **suitable for production use** on live accounts, provided:

- You deploy with **well‑tested .set files per symbol/timeframe**, and  
- You accept that the EA may **intentionally halt new entries** under configured risk‑guard conditions rather than continue trading into extreme drawdown.

Under those conditions, this build is a **GO** for controlled, monitored production rollout.

