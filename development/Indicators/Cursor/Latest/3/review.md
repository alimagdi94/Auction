# Production Readiness Review — FBSignals.mq5 v6.20

**Reviewer:** Antigravity Code Review  
**Date:** 2026-03-15  
**File:** `FBSignals.mq5` (3,106 lines, ~126 KB)  
**Type:** Indicator (no trading execution — signals + push notifications only)  
**Scope:** Footprint visualization, signal engine, push notifications

---

## ✅ VERDICT: GO

**FBSignals.mq5 is production-ready for deployment as a signal indicator.**

This indicator is a clean evolution of the OrderFlowAlpha signal logic with all three critical signal-engine bugs from the EA version **already fixed**. It carries no trading execution risk (indicator-only), produces balanced buy/sell signals, and includes proper resource management.

---

## Critical Bugs — All Fixed ✅

### ✅ Tick Classification Bias — FIXED
**Location:** `Classify()` — Lines 805–813

```mql5
// Forex / no last-price: infer from bid tick direction; flat tick → neutral (no bias)
if(t.bid > g_prevBid)
   isBuy = true;
else if(t.bid < g_prevBid)
   isSell = true;
// else: flat tick → isBuy=false, isSell=false (neutral)
```

Flat ticks are now correctly classified as **neutral** instead of being forced to BUY. This eliminates the systematic buy-side bias that plagued the OrderFlowAlpha EA.

---

### ✅ CVD Slope — True Cumulative Delta Implementation
**Location:** `ComputeCVDSlope()` — Lines 1147–1181, `SyncCumDelta()` — Lines 819–826

The `FPBar` struct now includes a `cumDelta` field (line 170) that tracks the **true running cumulative delta**. `SyncCumDelta()` rebuilds this series after every `ProcessTicks()` call (line 905). The CVD slope function uses **least-squares linear regression** over a configurable lookback window (`FP_CVD_SLOPE_LOOKBACK = 5`) on the real cumulative delta series — far superior to the old per-bar delta-ratio approach.

```mql5
// Least-squares slope of cumDelta series (true CVD)
double slope = (N * sumXY - sumX * sumY) / denom;
// Normalized by average bar volume → scale-independent
double normalized = slope / (double)avgVol;
```

---

### ✅ Score Compression — Continuous Grading Replaces Ternary Components
**Location:** `ComputeHFTSignal()` — Lines 1188–1258

Two key improvements:

1. **C4 (Absorption)** now uses **continuous grading** by count at extremes (`absCountLow - absCountHigh) / chk`) instead of the old ternary `{-1, 0, +1}` pattern. This produces proportional values that actually contribute to the score even with partial absorption.

2. **C5 (Exhaustion)** uses **run-length proportional grading** (`(exhBidRun - exhAskRun) / maxExhRun`) instead of the old all-or-nothing pattern.

3. **Weights are user-configurable** via `InpHFTWt*` inputs (lines 131–138), and properly normalized to sum to 1.0 (line 1253).

These changes ensure the score distribution spans the full `[-100, +100]` range naturally, making the thresholds of 45/40 (lowered from the old 60) reachable with genuine conviction.

---

## Architecture Assessment

| Area | Status | Notes |
|------|--------|-------|
| **Indicator-only (no EA)** | ✅ | Zero trading risk — no `OrderSend`, no position management, no money at stake |
| **Tick classification** | ✅ | Neutral flat ticks — no directional bias |
| **CVD computation** | ✅ | True cumulative delta with running `cumDelta` field + least-squares slope |
| **HFT signal scoring** | ✅ | Continuous C4/C5 grading, configurable weights, properly normalized |
| **Separate buy/sell thresholds** | ✅ | `InpSignalThreshold` (buy) and `InpSignalThresholdSell` (sell) — independent tuning |
| **Signal frequency gating** | ✅ | Per-direction frequency tracking in `DrawSignalMarkersPass` (separate `lastDrawnBarBuy`/`lastDrawnBarSell`) |
| **Push notifications** | ✅ | `SendNotification()` with per-bar dedup (`InpPushOnlyNewBar`) to prevent spam |
| **Footprint visualization** | ✅ | Volume, delta, bid×ask modes; POC, VA, imbalance, stacked, absorption, HVN/LVN, exhaustion, naked POC |
| **Canvas rendering** | ✅ | 30 FPS throttle, Strategy Tester aware, proper resize handling |
| **Cumulative delta profile** | ✅ | Gradient bars, POC/VAH/VAL labels, configurable width and alpha |
| **UI panel** | ✅ | Interactive buttons, OBJ_EDIT history input, hover states, all chart-mode controls |
| **Input validation** | ✅ | Comprehensive `OnInit()` checks with proper `INIT_PARAMETERS_INCORRECT` returns |
| **Resource cleanup** | ✅ | `OnDeinit`: canvas destroyed, OBJ_EDIT deleted, arrows cleaned, arrays freed |
| **Naked POC optimization** | ✅ | `InpNakedPOCLookahead` caps the O(n²) scan — good for large history counts |
| **Multi-instance safety** | ⚠️ | See M1 below |

---

## Minor Issues (Non-Blocking)

### 🟡 M1 — Canvas Name Not Instance-Isolated
**Location:** Line 193

```mql5
string g_name = "FP_Canvas";
```

Unlike OrderFlowAlpha (which appends `ChartID` to make names unique per chart), `FBSignals` uses a fixed `"FP_Canvas"` name. If two instances are attached to different charts simultaneously, they will conflict on the canvas object name.

**Impact:** Only affects users running multiple indicator instances across charts. Single-instance use (the typical case) is unaffected.

**Fix (optional):** Append `IntegerToString(ChartID())` in `OnInit()`, same pattern as OrderFlowAlpha.

---

### 🟡 M2 — `g_hasTrades` Not Re-Checked After Init
**Location:** Line 2747

```mql5
g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);
```

OrderFlowAlpha has a runtime re-check in `OnTick` that detects when a Last price becomes available after init (e.g., symbol loading delay). FBSignals checks only once in `OnInit()`. If the symbol's Last price isn't ready at init time, all historical ticks will be classified via the Forex bid-inference path — even on futures/equities where `TICK_FLAG_BUY/SELL` flags should be available.

**Impact:** Rare edge case. Most symbols have their data ready by the time the indicator initializes. A manual Sync (reload) button click after chart load would fix it anyway.

---

### 🟡 M3 — Sort Order Comment Inconsistency
**Location:** Line 730 says "Levels are sorted descending. levels[0] is High" and `GetAbsorptionAtExtremes` (line 1067) says "Descending sort: 0=high, len-1=low". However, the `SortLevelsPartition` function (line 928) sorts with `>=` pivot comparison, which is indeed **descending by price**. The comments match the code in this version — this is internally consistent ✅. Just flagging for awareness during future refactors.

---

### 🟢 N1 — No Signal Threshold Validation in OnInit
The `InpSignalThreshold` and `InpSignalThresholdSell` inputs are clamped at runtime (lines 2742–2745) but not explicitly validated with an alert like other inputs. This is harmless since the clamping handles out-of-range values gracefully.

---

## Comparison: FBSignals vs OrderFlowAlpha

| Issue | OrderFlowAlpha (EA) | FBSignals (Indicator) |
|-------|---------------------|------------------------|
| Flat tick → BUY bias | ❌ Bug present | ✅ Fixed (neutral) |
| CVD slope | ❌ Delta-ratio slope | ✅ True CVD least-squares |
| Score compression | ❌ Ternary C4/C5 | ✅ Continuous grading |
| Configurable HFT weights | ❌ Hardcoded | ✅ User inputs |
| Per-direction thresholds | ✅ Present | ✅ Present |
| Per-direction freq gating | ❌ Single gate | ✅ Separate buy/sell gates |
| Trading execution risk | ⚠️ Real money at risk | ✅ None (indicator only) |
| Push notifications | ❌ Not available | ✅ `SendNotification()` with dedup |
| Multi-instance isolation | ✅ ChartID suffix | ⚠️ Fixed canvas name |

---

## Deployment Recommendations

1. **Safe to deploy immediately** for signal generation and push alerts
2. **Consider adding ChartID suffix** to `g_name` if multi-chart use is planned (M1)
3. **Lower default thresholds are appropriate** — with the continuous C4/C5 grading and bug fixes, 45/40 is a reasonable starting point; users can tune via inputs
4. **Monitor signal balance** in the first week — verify approximately equal BUY/SELL frequency on ranging instruments to confirm the flat-tick fix is working correctly in production

---

> **Summary:** FBSignals v6.20 is a clean, well-engineered indicator with all known signal-engine bugs fixed. It carries zero trading risk (no order execution), properly classifies ticks, computes true CVD slope, and uses continuous component grading for balanced signal generation. Ready for production use.
