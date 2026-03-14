# OrderFlowAlpha v5.32 — Quant Parameter Adjustment Guide
**Live Demo Diagnostic | Account: 3519657 | Date: 2026.03.12 | Set: wider_trailing.set**

---

## 1. Executive Performance Snapshot

| Metric | Live Demo Result | Industry Benchmark | Status |
|---|---|---|---|
| Total Net Profit | **-$6,601.21** | > 0 | 🔴 FAIL |
| Starting Balance (est.) | ~$15,589 | — | — |
| Final Balance | $8,988.19 | — | — |
| Profit Factor | **0.673** | ≥ 1.5 (min), ≥ 2.0 (target) | 🔴 FAIL |
| Sharpe Ratio | **-0.131** | ≥ 1.0 (live), ≥ 0.5 (acceptable) | 🔴 FAIL |
| Recovery Factor | **-0.971** | ≥ 2.0 | 🔴 FAIL |
| Expected Payoff | **-$9.69/trade** | > $0 | 🔴 FAIL |
| Max Balance Drawdown | **43.24% ($6,797)** | ≤ 10% (strict), ≤ 20% (tolerable) | 🔴 FAIL |
| Win Rate (Overall) | **72.98%** | 45–65% (with proper R:R) | ⚠️ DISTORTED |
| Avg Win / Avg Loss | **$27.31 / $109.64** | ≥ 1.5× (RR ≥ 1.5:1) | 🔴 FAIL |
| Implied Actual R:R | **0.25:1** | ≥ 1.5:1 | 🔴 FAIL |
| Total Trades | 681 | — | — |
| Max Consecutive Losses | **6** | ≤ 3–4 | 🔴 FAIL |

### Root Cause in One Line
> The system has a **73% win rate** but still loses money. This is the definitive symptom of **inverted R:R** — winners are capped too early or positions reverse before full target, while losers run unmanaged past their theoretical stop.

---

## 2. Per-Instrument Breakdown

| Symbol | Trades | Win Rate | Net Profit | Verdict |
|---|---|---|---|---|
| VOL_10 | 56 | **37.5%** | **-$2,677.83** | 🔴 Disable immediately |
| CRASH_200 | 26 | 50.0% | -$1,214.24 | 🔴 Recalibrate or disable |
| XAUUSD | 119 | 67.2% | -$1,036.54 | 🟡 Survivable with R:R fix |
| VOL_80 | 129 | 83.7% | -$966.36 | 🔴 Classic R:R bleed |
| BOOM_200 | 19 | 57.9% | -$480.46 | 🔴 Recalibrate |
| NASDAQ-100 | 232 | 82.3% | -$614.73 | 🔴 Classic R:R bleed |
| XAGUSD | 2 | 0.0% | -$301.00 | 🔴 Remove from universe |
| XTIUSD | 1 | 0.0% | -$132.00 | 🔴 Remove from universe |
| **VOL_20** | 92 | 73.9% | **+$327.24** | ✅ Only positive carry |
| **STORM_500** | 5 | 100.0% | **+$494.71** | ✅ Too few trades to conclude |

**Actionable filter:** Disable `InpAllowBuy`/`InpAllowSell` per instrument or whitelist only VOL_20 and STORM_500 until R:R is resolved. The EA currently runs without symbol-specific parameter sets.

---

## 3. Signal Generation Parameters

### 3.1 Order Flow Strength (OFS) Score Weights

Current weights in `wider_trailing.set`:

| Component | Current Weight | Industry Range | Recommendation |
|---|---|---|---|
| `InpOFWtDelta` | 40.0% | 35–50% | ✅ Within range |
| `InpOFWtImb` | 25.0% | 20–30% | ✅ Within range |
| `InpOFWtStacked` | 20.0% | 15–25% | ✅ Within range |
| `InpOFWtAbsorb` | 15.0% | 10–20% | ✅ Within range |

> Weights must always sum to 100%. These are structurally sound. The problem is **not** signal composition — it is exit logic.

### 3.2 Signal Threshold

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpSignalThreshold` | **15** | 60 | 55–70 | 🔴 **Raise to 60–65** |
| `InpShowSignals` | false | true | — | Enable for live monitoring |
| `InpSignalFreqBars` | 3 | 3 | 3–5 | ✅ Acceptable |

**Critical note:** A threshold of 15 means the EA fires on nearly any signal. At 60+ it requires genuine multi-component conviction. The current 681 trades in a single day is consistent with a threshold of 15 — a system trading at market open to close at that frequency is over-trading.

### 3.3 Imbalance & Absorption Detection

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpImbalanceRatio` | 300.0% | 300.0% | 200–400% | ✅ Mid-range, test 350 |
| `InpStackedImbCount` | 3 | 3 | 2–4 | ✅ Acceptable |
| `InpAbsorptionRatio` | 4.0× | 4.0× | 3.0–6.0× | ✅ Acceptable |
| `InpDeltaConvThreshold` | 0.35 | 0.35 | 0.30–0.50 | ✅ Acceptable, test 0.40 |

### 3.4 Delta Conviction Gate

| Parameter | Set File Value | Industry Standard | Recommendation |
|---|---|---|---|
| `InpMinConvictionComp` | **1** | **2–3** | 🟡 Raise to 2 minimum |
| `InpAdaptiveThreshold` | false | Context-dependent | Enable for volatile instruments |
| `InpAdaptiveThreshMin` | 35.0 | 40–50 | Raise floor if enabled |
| `InpAdaptiveThreshMax` | 75.0 | 70–80 | ✅ Acceptable |

---

## 4. Entry Parameters

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpATEnable` | true | false | — | ✅ Confirmed ON |
| `InpOrderMode` | 0 (Market) | 0 (Market) | Pending preferred for OF | 🟡 Test `ORDER_MODE_PENDING` |
| `InpBufferPips` | 3.0 | 2.0 | 2–5 pips | ✅ Acceptable |
| `InpSpreadFilter` | false | true | Always enabled live | 🔴 **Enable immediately** |
| `InpMaxSpread` | 3.0 pips | 3.0 pips | 1.5–2.5 (majors), 3–5 (synthetics) | Adjust per instrument |
| `InpSpreadATRRatio` | 0.0 (disabled) | 0.0 | 0.10–0.20 | Enable as secondary check |
| `InpATR_Period` | 14 | 14 | 14 (standard) | ✅ Do not change |

**Spread filter was disabled** (`InpSpreadFilter = false`). Given synthetic instruments (VOL, BOOM, CRASH) with variable spreads, this is a significant source of slippage cost that does not appear in the commission column.

---

## 5. Exit Parameters — Primary Issue

This is where the system breaks down. The `wider_trailing.set` values are extreme outliers relative to the code's own defaults and industry norms.

### 5.1 Stop Loss

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpSLMode` | 2 (ATR×Mult) | 0 (Bar High/Low) | Bar H/L preferred for OF | 🟡 Test SL_MODE_BAR first |
| `InpSLATRMult` | **3.0×** | 1.5× | 1.0–2.0× | 🔴 **Reduce to 1.5×** |
| `InpSLPips` | 20.0 | 20.0 | Instrument-dependent | ✅ Baseline acceptable |
| `InpUseStopLoss` | true | true | Always true | ✅ |

An ATR multiplier of 3.0× on volatile instruments (VOL, CRASH, BOOM) creates stops that are too wide to be covered by the current TP logic, producing the observed -$109 average loss.

### 5.2 Take Profit

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpTPMode` | 0 (RR Ratio) | 0 (RR Ratio) | RR Ratio preferred | ✅ Correct mode |
| `InpRiskRewardRatio` | **9.0** | 2.0 | **2.0–3.0 (live standard)** | 🔴 **Critical mismatch** |
| `InpTPPips` | 40.0 | 40.0 | — | Baseline only |
| `InpTPATRMult` | 3.0× | 3.0× | 2.0–4.0× | ✅ Acceptable |

**The RR ratio of 9.0 is the single most important finding.** With ATR-based stops at 3.0× and a TP at 9× that distance, the TP is being set far beyond what the market is offering intraday. Trades are breaking even or getting stopped out well before reaching a 9:1 target, producing the observed $27 average win. The system is set up for a theoretical 9:1 but achieving 0.25:1 in practice.

**Fix:** Set `InpRiskRewardRatio = 2.0` and `InpSLATRMult = 1.5`. This alone will dramatically improve the win-to-loss dollar ratio.

### 5.3 Break-Even (The Guardian)

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpUseBreakEven` | true | true | ✅ Always use | ✅ |
| `InpBreakEvenTrigger` | **200.0 pips** | 15.0 pips | 30–50% of TP distance | 🔴 **Reduce drastically** |
| `InpBreakEvenBuffer` | 20.0 pips | 1.0 pip | 1–5 pips | 🟡 Reduce to 3–5 pips |

A BE trigger of 200 pips means break-even almost never activates before the trade either hits TP or SL. At a 15-pip default, break-even protects capital early. Recommended: **set to 30–40% of your effective ATR-based SL distance**.

### 5.4 Trailing Stop

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpUseTrailing` | true | true | ✅ Recommended | ✅ |
| `InpTrailStart` | **500.0 pips** | 20.0 pips | 50–75% of TP distance | 🔴 **Reduce to 50–80 pips** |
| `InpTrailStep` | **40.0 pips** | 5.0 pips | 5–15 pips | 🔴 **Reduce to 10–15 pips** |

A 500-pip trail start on instruments averaging $27 winners means the trailing stop **never engages**. This is the core of why the set file is named "wider_trailing" — the trailing is so wide it is functionally disabled.

---

## 6. Risk & Money Management Parameters

### 6.1 Position Sizing

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpUseRiskPercent` | true | true | ✅ Always dynamic | ✅ |
| `InpRiskPercent` | **1.0%** | 1.0% | 0.5–1.0% (demo), 0.25–0.5% (live) | 🟡 Reduce to 0.5% until system is profitable |
| `InpFixedLot` | 0.1 | 0.01 | — | Dynamic mode active, this is fallback |
| `InpMaxPositions` | **3** | 1 | 1–2 concurrent | 🟡 Reduce to 1 during recalibration |

With 3 concurrent positions across correlated instruments (XAUUSD, XAGUSD, XTIUSD — all commodity risk), effective portfolio risk can exceed 3% simultaneously. This explains the -43% drawdown.

### 6.2 Account Safety

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpMaxEquityLoss` | **3000.0** | 0 (disabled) | 5–10% of balance in $ | 🟡 Set to ~$750 (5% of $15k) |
| `InpMaxEquityProfit` | 0.0 | 0 (disabled) | Optional, 10–20% daily target | Set to $500–750 for daily cap |
| `InpMaxDailyLossPercent` | **0.0** (disabled) | 0 | **2–3% daily loss limit** | 🔴 **Enable at 2.0%** |
| `InpMaxConsecLosses` | **0** (disabled) | 0 | 3–4 before size cut | 🔴 **Set to 3** |
| `InpHaltConsecLosses` | **0** (disabled) | 0 | 5–6 before full halt | 🔴 **Set to 5** |
| `InpSizeReductionTrades` | 3 | 3 | 3–5 | ✅ |
| `InpCleanOldOrders` | true | true | ✅ | ✅ |

The $3,000 hard equity loss was hit and breached (actual drawdown was $6,797). Either the parameter did not function as expected or positions in progress were not counted. Enable `InpMaxDailyLossPercent` as the primary guard.

### 6.3 Conviction & Filtering Guards

| Parameter | Set File Value | Industry Standard | Recommendation |
|---|---|---|---|
| `InpSLCooldownBars` | **0** (disabled) | 2–5 bars after SL hit | 🟡 **Set to 3** |
| `InpPendingExpiryBars` | 0 (never) | 2–3 bars | Set to 2 if using pending orders |
| `InpHTFEnable` | **false** | Recommended live | 🟡 Enable with H1 EMA 50 |
| `InpSessionEnable` | **false** | Strongly recommended | 🔴 **Enable during recalibration** |
| `InpSessionStartHour` | 7 | 7–8 (London open) | ✅ Correct if enabled |
| `InpSessionEndHour` | 17 | 16–17 (London close) | ✅ Correct if enabled |

---

## 7. Data & Aggregation Parameters

| Parameter | Set File Value | Code Default | Industry Standard | Recommendation |
|---|---|---|---|---|
| `InpTickSize` | 10 | 10 | 5–20 depending on instrument | ✅ Test 5 for XAUUSD |
| `InpTickMultiplier` | 5 | 5 | 3–10 | ✅ Acceptable |
| `InpHistoryBars` | **50** | 100 | 100–200 | 🟡 Raise to 100 for better POC/VA anchoring |
| `InpVAPercent` | 70.0% | 70.0% | **70% (CME standard)** | ✅ Do not change |
| `InpHVNRatio` | 2.0× | 2.0× | 1.5–2.5× | ✅ |
| `InpLVNRatio` | 0.35 | 0.35 | 0.25–0.50 | ✅ |

---

## 8. Prioritized Fix Sequence

Execute in order. Do not move to the next step until the previous shows stability over 50+ trades.

### Step 1 — Stop the Bleeding (Immediate)
```
InpSignalThreshold    = 60        # was 15
InpSLATRMult          = 1.5       # was 3.0
InpRiskRewardRatio    = 2.0       # was 9.0
InpMaxDailyLossPercent= 2.0       # was 0.0
InpSpreadFilter       = true      # was false
InpMaxPositions       = 1         # was 3
```

### Step 2 — Guardian Recalibration
```
InpBreakEvenTrigger   = 25.0      # was 200.0
InpBreakEvenBuffer    = 3.0       # was 20.0
InpTrailStart         = 40.0      # was 500.0
InpTrailStep          = 10.0      # was 40.0
```

### Step 3 — Conviction & Safety
```
InpMinConvictionComp  = 2         # was 1
InpSLCooldownBars     = 3         # was 0
InpMaxConsecLosses    = 3         # was 0
InpHaltConsecLosses   = 5         # was 0
InpRiskPercent        = 0.5       # was 1.0
```

### Step 4 — Instrument Whitelisting
- Remove: `XTIUSD`, `XAGUSD` (insufficient liquidity / tick resolution issues)
- Remove or paper-trade: `VOL_10` (37.5% win rate, catastrophic drawdown contributor)
- Recalibrate: `CRASH_200`, `BOOM_200` with dedicated tick size and ATR settings
- Keep active: `VOL_20`, `NASDAQ-100`, `XAUUSD` with Step 1–3 settings

### Step 5 — HTF Filter & Session Gate
```
InpHTFEnable          = true
InpHTFPeriod          = PERIOD_H1
InpHTFEMA             = 50
InpSessionEnable      = true
InpSessionStartHour   = 7
InpSessionEndHour     = 17
```

---

## 9. Industry Standard Reference Values (Quick Lookup)

| Concept | Minimum | Target | Elite |
|---|---|---|---|
| Profit Factor | 1.2 | 1.75 | ≥ 2.5 |
| Sharpe Ratio | 0.5 | 1.0 | ≥ 2.0 |
| Max Drawdown | < 20% | < 10% | < 5% |
| Win Rate (with 1.5:1 RR) | 40% | 50–60% | < 65% |
| Win Rate (with 2.5:1 RR) | 30% | 40–50% | — |
| Expected Payoff per trade | > 0 | > $15 | > $50 |
| Risk per trade | 1–2% | 0.5–1% | 0.25–0.5% |
| Recovery Factor | ≥ 1.5 | ≥ 3.0 | ≥ 5.0 |
| Max Concurrent Positions | — | 1–2 | 1 (per strategy) |
| Daily Loss Limit | 3% | 2% | 1% |

---

## 10. Notes on Commission Tracking

All trades in the report show **Commission = 0.0**. This is either:
- A broker feature (commission embedded in spread), or
- A data export issue masking actual costs

For synthetic instruments (VOL, BOOM, CRASH, STORM) the spread **is** the commission. Ensure `InpSpreadFilter` is enabled and `InpMaxSpread` is set per-instrument. The implied slippage cost is not visible in the P&L breakdown but is embedded in every trade's entry price.

---

*Generated from: `ReportHistory-3519657.xlsx` | `wider_trailing.set` | `OrderFlowAlpha.mq5 v5.32`*
*Analysis date: 2026.03.12*
