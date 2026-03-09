# OrderFlowEA v6.05 — Production Analysis & Deployment Brief

**Author:** Ali Magdy  
**Version:** 6.05  
**Compiled:** MQL5 (MetaTrader 5)  
**Set File:** `trade_mode.set`  
**Backtest Window:** 2026-01-02 → 2026-03-05 (~2 months)

---

## 1. Architecture Overview

The EA is a **pure order-flow footprint engine** — no canvas, no graphical UI widgets. All output goes to the MT5 journal and native chart objects (`OBJ_ARROW`, `OBJ_HLINE`, `OBJ_TEXT`). It processes every tick in real time, builds an in-memory footprint book per bar, scores each bar across six order-flow dimensions, and fires market or pending orders when conviction thresholds are met.

### Processing Pipeline (top to bottom on every tick)

```
CopyTicksRange()
       │
       ▼
Classify() — TICK_FLAG_BUY/SELL (live) or bid-delta (FX/synthetics)
       │
       ▼
AccumulateTick() — fills FPBar.levels[] bid_vol / ask_vol buckets
       │
       ▼
EvalAndFireSignal() — ComputeHFTSignal() + ComputeOFScore() → alert + SIG_ marker
       │
       ▼
ManagePositions() — throttled break-even + trailing SL modifier
       │ (on new bar only)
       ▼
PlaceOrders() — ComputeHFTSignal(last closed bar) → CalcSLTP → CalcLot → OrderSend
```

---

## 2. Signal Engine — Detailed Breakdown

### 2.1 Order Flow Strength Score (OFScore, 0–100)

A weighted composite used as a secondary display metric:

| Component | Weight (set file) | Description |
|---|---|---|
| Delta ratio | 40% | Normalised cumulative delta of the bar |
| Imbalance balance | 25% | Buy-side vs sell-side diagonal imbalance cells |
| Stacked imbalance | 20% | 3+ consecutive same-direction imbalance clusters |
| Absorption | 15% | High-volume absorption at bar extremes |

Score > 50 = net bullish pressure; < 50 = net bearish. NaN/Inf divisions are explicitly guarded (`MathIsValidNumber`).

### 2.2 HFT Signal Score (primary trigger, −100 to +100)

Six components weighted in `ComputeHFTSignal()`:

| # | Component | Weight | Signal meaning |
|---|---|---|---|
| C1 | Delta ratio (bar) | 30% | Positive delta = buying pressure |
| C2 | CVD skew (Ask-vs-Bid across all levels) | 20% | Net order-book lean |
| C3 | Bar structure (bullish close + positive delta) | 15% | Price/delta agreement |
| C4 | Absorption polarity (low vs high absorption) | 15% | Who absorbed — sellers at low = bullish |
| C5 | Bid/Ask exhaustion at extremes | 10% | Exhausted sellers at low = bullish |
| C6 | 3-bar normalised CVD slope | 10% | Momentum direction over last 3 bars |

**Fire condition:**  
`hftScore >= +threshold` → **BUY** signal  
`hftScore <= −threshold` → **SELL** signal  
Threshold in trade_mode.set: **35** (default code: 60)

### 2.3 Conviction Label Tags

The `GetConvictionReason()` function assembles up to 3 human-readable tags for the chart label and journal. Examples: `BullDelta+StackBuy+NakedPOC`, `BearDelta+StackSell+AskExh`. This is the most useful diagnostic field in the journal.

---

## 3. Footprint Calculations

### Cell Size
```
g_step = InpTickSize × _Point × InpTickMultiplier
       = 10 pts × _Point × 5 = 50-point cells
```

### Imbalance Detection (diagonal footprint rule)
- **Buy imbalance:** `ask_vol[i] / bid_vol[i+1] >= 300%`
- **Sell imbalance:** `bid_vol[i] / ask_vol[i-1] >= 300%`

### Stacked Imbalance
Requires **3 consecutive** same-direction imbalance cells (InpStackedImbCount = 3).

### Absorption
Level volume > **4× average bar volume per level** (InpAbsorptionRatio = 4.0).

### Exhaustion
Top 3 cells at bar HIGH have ask_vol ≤ 5% of avg vol → Ask Exhaustion (sellers exhausted).  
Bottom 3 cells at bar LOW have bid_vol ≤ 5% of avg vol → Bid Exhaustion (buyers exhausted).

### Value Area
70% of bar volume centred around the POC, expanded outward level by level (industry standard).

### Naked POC
Any POC from a prior bar that has not been touched by a subsequent bar's high/low range is flagged as `is_naked_poc = true`. Acts as a price magnet tag on signals.

---

## 4. Trade Execution Logic

### Lot Sizing — Margin-Based (FIX-11)
```
AllocationAmount = AccountBalance × RiskPercent%
MarginFor1Lot   = OrderCalcMargin(BUY, symbol, 1.0, Ask)
Lot             = AllocationAmount / MarginFor1Lot
```
This is **instrument-aware by design** — no manual tick-value scaling needed. Works correctly across FX, indices, and Deriv synthetics (Boom/Crash/Volatility series). Falls back to `InpFixedLot` if `OrderCalcMargin` fails (market closed, symbol unavailable).

### Stop Loss — Bar Mode (SL_MODE_BAR)
```
BUY  SL = bar_low  − BufferDist
SELL SL = bar_high + BufferDist
```
BufferDist = `InpBufferPips × g_Pip` (from set file: 200 pips — see §6 for concern).

### Take Profit — Risk:Reward Mode
```
TP = Entry + (SL_Distance × RiskRewardRatio)
```
RR in set file: **60:1** — see §6 for analysis.

### Order Retry Logic
Up to **3 attempts** on `REQUOTE`, `PRICE_CHANGED`, `CONNECTION`, `TIMEOUT`. Price refreshed from `SymbolInfoTick()` on each retry.

### Break-Even
Triggered at **600 pips profit** → SL moved to `entry + 200 pips`. Only improves (never tightens a better SL).

### Trailing Stop
Activated at **1,200 pips profit**, steps in **300-pip** increments. Uses `GetTickCount64()` throttle to avoid per-tick spam.

### Position Cap
`InpMaxPositions = 1` — one open position at a time per symbol per EA instance.

---

## 5. Backtest Screenshot Analysis

![Backtest curve — Balance (blue) / Equity (green), Jan–Mar 2026]

**Observations from the equity curve:**

| Metric | Reading |
|---|---|
| Starting balance | ~10,000 (estimated from scale) |
| Peak equity | ~23,396 |
| End balance | ~19,000–21,000 |
| Worst equity trough | ~8,200 (mid-Jan, shortly after attach) |
| Deposit load at bottom | ~10% (margin utilisation — conservative) |

**Pattern analysis:**

- **Blue (Balance) curve** is a staircase — large infrequent jumps. This is consistent with a 60:1 RR strategy: many small losses absorbed until a single massive winner pays them all back.
- **Green (Equity) curve** spikes far above balance at each open-trade window, confirming positions run for a very long time before closing.
- The **deep trough in early January** (balance dropped ~20%) before the first big recovery is a significant red flag for live deployment — the EA held a loss for several bars before the trend moved in its favour.
- The **second major drawdown period** (Feb 3 → Feb 17) shows a ~30% equity drawdown from peak before recovering. On a real account this would test discipline.
- The **Deposit Load row** stays consistently at ~10%, confirming the 1% risk / margin-based lot sizing is working correctly.

---

## 6. Set File Configuration — Line-by-Line Analysis

### Decoded Settings (set file is UTF-16 LE encoded)

```ini
; Logging
InpLoggingEnable      = true
InpLogMode            = 3          ; LOG_FULL — maximum verbosity

; Data & History
InpTickSize           = 10         ; 10-point base cells
InpImbalanceRatio     = 300.0      ; 3:1 ask/bid ratio for imbalance
InpStackedImbCount    = 3          ; 3 consecutive cells = stacked
InpAbsorptionRatio    = 4.0        ; 4× avg vol = absorption
InpHistoryBars        = 200        ; double the code default (100)
InpVAPercent          = 70.0       ; industry standard
InpHVNRatio           = 2.0
InpLVNRatio           = 0.35

; Aggregation
InpChartMode          = 1          ; Delta mode
InpTickMultiplier     = 5          ; 50-pt cells total

; Exhaustion
InpExhaustionEnable   = true
InpExhaustionCells    = 3
InpExhaustionZeroRat  = 0.05

; OFS Weights (must sum > 0)
InpOFWtDelta          = 40.0
InpOFWtImb            = 25.0
InpOFWtStacked        = 20.0
InpOFWtAbsorb         = 15.0

; Signals
InpShowSignals        = false      ; ⚠ signal alerts/sounds OFF
InpSignalThreshold    = 35         ; ⚠ much lower than code default 60
InpSignalFreqBars     = 3
InpSignalBuySound     = (empty)
InpSignalSellSound    = (empty)

; Automated Trading
InpAnalysisMode       = false      ; real orders, not virtual
InpATEnable           = true       ; AUTO-TRADING ON
InpOrderMode          = 0          ; Market orders
InpATR_Period         = 14
InpSpreadFilter       = false      ; ⚠ spread NOT filtered
InpMaxSpread          = 3.0
InpAllowBuy           = true
InpAllowSell          = true
InpBufferPips         = 200.0      ; ⚠ only relevant for pending mode — currently unused

; Money Management
InpUseRiskPercent     = true
InpRiskPercent        = 1.0        ; 1% account per trade
InpFixedLot           = 0.1

; Exit
InpUseStopLoss        = true
InpSLMode             = 0          ; SL_MODE_BAR
InpSLPips             = 200.0      ; fallback only (200 pips)
InpSLATRMult          = 15.0       ; fallback only (not in use)
InpUseTakeProfit      = true
InpTPMode             = 0          ; TP_MODE_RR
InpRiskRewardRatio    = 60.0       ; ⚠ 60:1 RR — aggressive
InpTPPips             = 40.0       ; fallback only
InpTPATRMult          = 30.0       ; fallback only

; Guardian
InpUseBreakEven       = true
InpBreakEvenTrigger   = 600.0      ; pips in profit before BE
InpBreakEvenBuffer    = 200.0      ; pips locked above entry
InpUseTrailing        = true
InpTrailStart         = 1200.0     ; pips before trailing activates
InpTrailStep          = 300.0      ; trail granularity

; Account Safety
InpMaxEquityProfit    = 0.0        ; ⚠ no hard profit target
InpMaxEquityLoss      = 0.0        ; ⚠ no hard loss limit
InpCleanOldOrders     = true
InpMaxPositions       = 1
InpMagic              = 20260226

; Visuals
InpShowVisuals        = true
InpShowSLTPLines      = true
InpShowEntryLabel     = true
InpShowExitLabel      = true
```

---

## 7. Critical Issues — Must Address Before Live Deployment

### 🔴 HIGH PRIORITY

**Issue 1: Signal threshold too low (35 vs recommended 60)**  
The code default of 60 was chosen to filter high-conviction setups only. At 35, nearly every bar with any directional lean will trigger. The backtest shows this produces frequent trades but also a deep early drawdown (mid-January). In live trading on a volatile synthetic index, a lower threshold means more entries during ambiguous market structure.  
**Recommendation:** Test 45–55 threshold range. Use Analysis Mode to compare signal density before enabling real orders.

**Issue 2: RR of 60:1 is not suitable for all instruments**  
A 60:1 reward-to-risk ratio means the EA will be wrong many more times than it is right, relying on one or two enormous winners to compensate. The backtest works because synthetic indices like Boom/Crash or Volatility 75 can sustain 1,000–10,000 pip moves. On FX pairs, this ratio would almost never reach TP, producing a slow grind of losses with rare recoveries.  
**Recommendation:**  
- Deriv synthetics (Volatility/Boom/Crash): 60:1 may be appropriate, but set `InpMaxEquityLoss` to protect against ruin.
- FX pairs: Reduce to 3:1 – 10:1.

**Issue 3: No equity loss limit set (InpMaxEquityLoss = 0)**  
With a 60:1 RR strategy, drawdown periods will be frequent and deep. Currently there is zero hard kill switch on the account. If the EA enters a bad streak with a 35 threshold, account damage can be severe before a recovery trade appears.  
**Recommendation:** Set `InpMaxEquityLoss` to ~10–15% of starting balance in account currency.

**Issue 4: Spread filter disabled (InpSpreadFilter = false)**  
On real broker accounts, especially during news events or session opens, spreads on synthetic indices can widen significantly. Entering on a 3-5 pip spread when your SL might be only 50 pips (bar mode on a small bar) will immediately push the trade into a loss at open.  
**Recommendation:** Enable `InpSpreadFilter = true` and calibrate `InpMaxSpread` to your instrument's typical spread + 50% buffer.

---

### 🟡 MEDIUM PRIORITY

**Issue 5: InpBufferPips = 200 pips — dangerously large if order mode is ever changed to Pending**  
Currently `InpOrderMode = 0` (Market), so the 200-pip buffer for pending entry placement is never used. However, if someone switches to Pending mode without adjusting this value, buy-stop orders would be placed 200 pips above bar high — far outside realistic entry distance.  
**Recommendation:** Either document this clearly or reset to a safer default (2–5 pips for FX, 50–100 for synthetics).

**Issue 6: InpSLATRMult = 15.0 — extreme if SL mode is changed to ATR**  
Similarly, if `InpSLMode` is switched to `SL_MODE_ATR`, a 15× ATR stop loss on a Volatility 75 index with ATR of 500 pts would produce a 7,500-pt SL — barely distinguishable from no stop at all on a $10,000 account.  
**Recommendation:** Keep at 1.5–2.5 for ATR mode, or document it as "not in use — SL_MODE_BAR only."

**Issue 7: InpHistoryBars = 200 — memory and tick load**  
200 bars of tick history is twice the default. On volatile instruments (Volatility 75) with hundreds of ticks per minute, this significantly increases RAM and tick fetch time on each `ReloadHistory()`. Watch MT5 memory usage in the first hours of live operation.  
**Recommendation:** Profile memory use live. If no issues, keep; if reload latency is observed in journal, reduce to 100.

**Issue 8: LOG_FULL in production**  
`InpLogMode = 3` (LOG_FULL) writes every system event, every tick group summary, every signal, every order attempt to the journal. On a fast-tick instrument this produces thousands of journal lines per hour and can slow down MT5 terminal rendering.  
**Recommendation:** Switch to `LOG_TRADES_ONLY` or `LOG_SIGNALS` for live deployment. Keep LOG_FULL for debugging sessions only.

---

### 🟢 LOW PRIORITY / OBSERVATIONS

**Issue 9: InpShowSignals = false — signals are silent**  
Alerts and sounds are disabled. The EA will not produce audible alerts or visible SIG_ markers on the chart. This is intentional for a fully automated deployment but means you have no real-time alert if the EA is generating many signals rapidly.  
**Recommendation:** Leave off for live auto-trading. Enable for manual oversight sessions.

**Issue 10: Magic number hardcoded in set file (20260226)**  
The magic number appears to be a date (`2026-02-26`). This is unique and fine as long as only one instance runs per symbol. If deploying on multiple symbols simultaneously, each chart should have a different magic number to avoid cross-position management interference.

---

## 8. Pre-Production Checklist

| # | Item | Status |
|---|---|---|
| 1 | Confirm target instrument (Deriv synthetic vs FX) | Verify |
| 2 | Enable `InpSpreadFilter = true`, set max spread appropriately | Action required |
| 3 | Set `InpMaxEquityLoss` to 10–15% of start balance | Action required |
| 4 | Consider raising `InpSignalThreshold` to 45–55 | Recommended |
| 5 | Verify RR=60 is appropriate for target instrument | Verify |
| 6 | Switch `InpLogMode` to LOG_SIGNALS (2) for live | Recommended |
| 7 | Assign unique magic number per symbol if multi-chart | Required for multi |
| 8 | Run in Analysis Mode (InpAnalysisMode=true, ATEnable=false) for 1–2 days live to validate signal quality | Strongly recommended |
| 9 | Confirm tick history is available (`SymbolInfoDouble(SYMBOL_LAST) > 0`) before enabling auto-trade | Verify |
| 10 | Ensure AutoTrading button is ON in MT5 toolbar | Confirm at attach |
| 11 | Check broker filling mode — FOK/IOC/RETURN (logged at init) | Check journal on first attach |
| 12 | Verify EA compiles with `#property strict` with zero warnings | Done in v6.05 |

---

## 9. Code Quality Assessment

### Strengths
- **Extensive inline documentation** — every bug fix is described with root cause, reproduction condition, and fix rationale directly in the source. Exceptional for maintenance.
- **Backtest parity fixes (FIX-SELL-1 through 4)** — the sell-signal backtest bug was a subtle but critical issue. The fix (removing the forced `isBuy` tie-break for neutral ticks) is correct and well-explained.
- **Margin-based lot sizing (FIX-11)** — the shift from pip-value to `OrderCalcMargin` is the right architecture for a multi-instrument EA. Works on synthetics that don't have standard pip values.
- **NaN/Inf guards (FIX-10)** — all ratio divisions in OFScore and HFTSignal are guarded. No division-by-zero crashes possible.
- **Reload safety (FIX-3, FIX-SELL-3, FIX-SELL-4)** — the `g_needs_reload` flag pattern and time-based frequency gate survive history reloads correctly.
- **Object namespace separation** — `FP_` (live trades), `AN_` (analysis mode), `SIG_` (signal markers) are cleanly separated and independently managed.
- **3-retry order send** — handles transient broker errors gracefully with price refresh on retry.

### Areas to Watch
- `SortLevelsPartition()` is a **recursive quicksort**. On bars with many price levels (high-volatility instruments), stack depth could become an issue if `level_count` exceeds ~500. Practically unlikely but worth monitoring.
- The `ProcessTicks()` inner loop uses `iBarShift()` on every bar-boundary crossing. This is a terminal call and can be slow on instruments with long bars and many ticks. Not a bug, but a performance consideration at scale.
- `ComputeNakedPOCs()` is O(n²) across all bars. With 200 history bars this is 200×200 = 40,000 comparisons on every `ReloadHistory()`. Acceptable for the current history size.

---

## 10. Recommended Production Set File

Below are the recommended changes to `trade_mode.set` for production deployment on **Deriv synthetic indices**:

```ini
; ── Changes from backtest set ──────────────────────────────
InpSignalThreshold    = 50         ; raised from 35 — reduce noise trades
InpSpreadFilter       = true       ; ENABLED — protect against spread spikes
InpMaxSpread          = 5.0        ; adjust to your symbol's normal spread
InpLogMode            = 2          ; LOG_SIGNALS only — reduce journal noise
InpMaxEquityLoss      = 1000.0     ; hard kill at $1,000 loss (adjust per balance)
InpBufferPips         = 50.0       ; safer default if order mode ever changes
InpSLATRMult          = 2.0        ; safer ATR multiplier if SL mode ever changes
; ── Everything else unchanged from trade_mode.set ──────────
```

For **FX pairs**, additionally change:
```ini
InpRiskRewardRatio    = 3.0        ; realistic RR for FX
InpBreakEvenTrigger   = 20.0       ; 20-pip trigger for FX
InpBreakEvenBuffer    = 2.0
InpTrailStart         = 30.0
InpTrailStep          = 5.0
InpSLPips             = 20.0       ; realistic FX fallback SL
```

---

## 11. Summary

The OrderFlowEA v6.05 is a **technically sound, well-engineered footprint analysis engine**. The v6.05 round of fixes addressed the most critical bugs (backtest sell-signal bias, reload cache corruption, frequency gate index drift) and the code is in a deployable state from a code quality perspective.

The **set file** is calibrated for **large-range synthetic instruments** (Deriv Boom/Crash/Volatility series) with a high-reward, high-patience strategy: low threshold (35), huge RR (60:1), and large pip targets (600/1200 pip guardians). The backtest shows this can produce significant gains on those instruments, but the strategy requires accepting deep intermediate drawdowns.

**The three absolute requirements before going live:**
1. Set `InpMaxEquityLoss` — there is currently no floor on account damage.
2. Enable `InpSpreadFilter` — unfiltered spread entry is a live-account risk not present in backtesting.
3. Run Analysis Mode for at least 48 hours on your live symbol before enabling real orders — verify signal quality on live ticks versus backtest ticks.
