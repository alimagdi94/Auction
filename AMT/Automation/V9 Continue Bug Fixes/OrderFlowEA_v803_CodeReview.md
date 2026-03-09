# OrderFlowEA v8.03 — Objective Code Review
**Standard:** Industry-level software engineering + quantitative trading practices  
**File:** `OrderFlowEA_v803.mq5` — 2,793 lines (+61 from v8.02)  
**Date:** March 2026  
**Context:** Third consecutive patch review — builds on v8.01 and v8.02 reports

---

## Executive Summary

All four V8-18 fixes compile correctly and their isolated implementations are sound. Three of them (BUG B, BUG C, and the structural part of BUG A) are unconditional improvements. However, this review uncovered a **root-cause structural defect** that was not identified in either prior review and which silently invalidates two of the bug identifications made in the v8.01 report — meaning two of the code changes applied in v8.02 are **regressions, not fixes**.

The defect: the Lomuto quicksort partition at line 1052 uses `>=` instead of `<=`, producing **descending** price order (`levels[0]` = bar HIGH, `levels[len-1]` = bar LOW). Every comment in the codebase, and two findings from the v8.01 review, assumed ascending order. The POC gravity negation introduced in v8.02 (C3, 15% signal weight) and the exhaustion direction swap introduced in v8.02 and carried into v8.03 (C5, 10% signal weight) are both based on this incorrect assumption. Both changes made previously-correct code wrong. 25% of the HFT composite score is now computing inverse signals relative to correct market structure interpretation.

The BUG A fix (session halt reset) is also scope-limited in a way that leaves the permanent-halt defect active under the EA's default parameter configuration.

---

## Section 1 — V8-18 Fix Verification

### BUG A — Session Halt Reset
**Status: Partially fixed. Scope issue remains (see Section 3).**

The core fix is implemented correctly: `g_sessionHalted = false` and `g_consecutiveLosses = 0` are now reset inside the new-day block of `CheckDailyLoss()`, alongside `g_dailyLossHalted`. The documented intent ("session halt resets on the next day") now has a working implementation. The scope limitation is a separate defect documented in Section 3.

### BUG B — Stale Version Strings
**Status: Correctly and cleanly fixed.**

```mql5
#define EA_VERSION "8.03"
#define EA_NAME    "OrderFlowEA v" EA_VERSION
```

All Alert() and log calls now use `EA_NAME`. The single source of truth is in place. No stale version strings were found in the file.

### BUG C — HTF Trend Filter Bid/Ask Price
**Status: Correctly fixed.**

```mql5
double curPrice = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
```

Long entries execute at the ASK. Using ASK for the buy-direction EMA comparison is correct. The fix is unconditional and mathematically sound.

### BUG D — Exhaustion Direction Swap
**Status: Applied as described, but the fix is a regression. See Section 2.3.**

---

## Section 2 — CRITICAL: Root Cause — Sort Order Mismatch

This is the most significant finding in this review. It was not identified in v8.01 or v8.02, and it is the root cause behind two prior bug misidentifications that have now been "fixed" into active regressions.

### 2.1 — The Quicksort Sorts Descending, Not Ascending

The partition function at lines 1045–1059:

```mql5
void SortLevelsPartition(PriceLevel &lv[], int lo, int hi)
  {
   double pivot = lv[hi].price;
   int    i     = lo - 1;
   for(int j = lo; j < hi; j++)
     {
      if(lv[j].price >= pivot)    // ← >= instead of <=
        { i++; /* swap lv[i] and lv[j] */ }
     }
   /* place pivot at i */
   SortLevelsPartition(lv, lo, i-1);
   SortLevelsPartition(lv, i+1, hi);
  }
```

The standard Lomuto partition for **ascending** sort uses `<= pivot` to place smaller elements on the left. This implementation uses `>= pivot`, placing larger elements on the left — producing **descending** order.

Hand-trace verification on `[100.0, 102.0, 101.0]`:
- pivot = 101.0; j=0: 100.0 >= 101.0? No. j=1: 102.0 >= 101.0? Yes → left side.
- Place pivot. Result: `[102.0, 101.0, 100.0]` — **descending**. ✓

**Actual memory layout after every `SortLevels()` call:**

| Index | Price | Meaning |
|---|---|---|
| `levels[0]` | Highest | **bar HIGH** |
| `levels[1]` | Second highest | — |
| … | … | — |
| `levels[len-1]` | Lowest | **bar LOW** |

Every comment in the codebase asserts the opposite:
> *"levels[] is sorted price-ascending (index 0 = lowest price level)"*

These comments are universally wrong. This disconnect is the root cause of two incorrect bug identifications in the v8.01 review.

---

### 2.2 — Regression: C3 POC Gravity (15% of HFT Signal) — Introduced v8.02

**v8.01 original code:**
```mql5
double pocPos = (double)g_bars[bi].poc_idx / (double)(len-1);
c3 = +(pocPos * 2.0 - 1.0);
```

Analysis with actual **descending** sort:
- `poc_idx ≈ 0` → `levels[0]` = bar **HIGH** → distribution zone → `c3 ≈ -1.0` → bearish signal ✅
- `poc_idx ≈ len-1` → `levels[len-1]` = bar **LOW** → accumulation zone → `c3 ≈ +1.0` → bullish signal ✅

The v8.01 code was correct.

**v8.02 "fix" (now in v8.03):**
```mql5
c3 = -(pocPos * 2.0 - 1.0);   // negated
```

With actual descending sort:
- `poc_idx ≈ 0` → bar **HIGH** → distribution → `c3 ≈ +1.0` → bullish signal ❌
- `poc_idx ≈ len-1` → bar **LOW** → accumulation → `c3 ≈ -1.0` → bearish signal ❌

The negation was introduced because the v8.01 reviewer correctly understood market structure (HIGH = distribution = bearish) but incorrectly assumed ascending sort order. The fix perfectly inverted a correct signal. C3 now fires in the wrong direction on every bar with a non-central POC.

**Fix for v8.04:** Revert to `c3 = +(pocPos * 2.0 - 1.0)`.

---

### 2.3 — Regression: C5 Exhaustion Direction (10% of HFT Signal) — Introduced v8.02, Inherited v8.03

**v8.01 original exhaustion scan:**
```mql5
// Ask exhaustion
for(int i = 0; i < len; i++)     // i=0 = bar HIGH (descending) — correct ✅

// Bid exhaustion  
for(int i = len-1; i >= 0; i--) // i=len-1 = bar LOW (descending) — correct ✅
```

The v8.01 code checked ask exhaustion from the bar HIGH and bid exhaustion from the bar LOW — standard footprint interpretation.

**v8.03 "fixed" exhaustion scan:**
```mql5
// "Ask exhaustion at HIGH" — but scan starts at len-1 = bar LOW (descending) ❌
for(int i = len-1; i >= 0; i--)

// "Bid exhaustion at LOW" — but scan starts at 0 = bar HIGH (descending) ❌
for(int i = 0; i < len; i++)
```

The comments now correctly describe the *intent* ("ask exhaustion at HIGH") but the scan runs from the wrong extreme. Near-zero ask volume at the bar **LOW** now triggers "buying exhaustion at the top." Near-zero bid volume at the bar **HIGH** now triggers "selling exhaustion at the bottom." Both flags fire on structurally irrelevant extremes.

**Fix for v8.04:** Revert to the v8.01 scan directions (ask from index 0 descending, bid from index len-1 ascending). Correct the spatial comment to reflect descending layout.

---

### 2.4 — What the Descending Sort Does NOT Break

Several spatial computations are internally consistent with the actual descending layout:

| Computation | Verdict | Reason |
|---|---|---|
| OFS absorption (BUG 2 fix, v8.02) | ✅ Correct | `i < chkA` = HIGH; `i >= len-chkA` = LOW — consistent with descending |
| C4 absorption in HFTSignal | ✅ Correct | Same spatial pattern ✅ |
| GetConvictionResult absorption | ✅ Correct | Same spatial pattern ✅ |
| Diagonal imbalances | ✅ Correct | `levels[i+1]` = one price step lower — valid for either sort direction |
| Stacked imbalances | ✅ Correct | Count-based, not position-dependent |
| C2 delta divergence | ✅ Correct | Bar-level aggregates, not level-position-dependent |
| C6 CVD slope | ✅ Correct | Multi-bar bar-level aggregates |

The OFS absorption fix (BUG 2) from the v8.01 review was genuinely correct and produces valid results. C4 and the conviction absorption logic were also always correct.

---

### 2.5 — Net Signal Correctness in v8.03

| Component | Weight | Status |
|---|---|---|
| C1 — OFS Score | 30% | ✅ Correct |
| C2 — Delta divergence | 20% | ✅ Correct |
| C3 — POC gravity | 15% | ❌ Inverted (regression from v8.02) |
| C4 — Absorption extremes | 10% | ✅ Correct |
| C5 — Bid/Ask exhaustion | 10% | ❌ Inverted (regression from v8.02) |
| C6 — CVD momentum slope | 15% | ✅ Correct |

75% of composite signal weight is correct. 25% is actively computing inverse signals relative to correct market structure interpretation.

---

## Section 3 — BUG A Fix: Scope-Conditional Session Halt Reset

**Severity: High — affects all users on default parameters**

The v8.18 fix for the permanent-halt defect places the reset inside `CheckDailyLoss()`:

```mql5
bool CheckDailyLoss()
  {
   if(InpMaxDailyLossPercent <= 0.0) return true;   // ← early exit

   ...
   if(dt.day != g_dayStartDay)
     {
      if(!positionsOpen)
        {
         g_sessionHalted   = false;   // ← fix is here, unreachable when daily % = 0
         g_consecutiveLosses = 0;
```

`InpMaxDailyLossPercent` defaults to `0.0` (disabled). When zero, `CheckDailyLoss()` returns at the first line and **never reaches the reset code**.

A user who enables `InpHaltConsecLosses = 5` while leaving `InpMaxDailyLossPercent = 0.0` (the natural default configuration — session protection without a daily percentage cap) still experiences the permanent halt. The GlobalVariable persistence from V8-10 restores `SessHalted=1` on every EA restart across days until a user manually edits a terminal GlobalVariable.

**Fix for v8.04:** Extract the new-day reset into a standalone function called from the top of `CheckRiskConditions()`, running unconditionally regardless of daily loss percentage:

```mql5
void CheckNewDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day == g_dayStartDay) return;

   bool positionsOpen = false;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk > 0 && (ulong)PositionGetInteger(POSITION_MAGIC) == g_Magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
        { positionsOpen = true; break; }
     }
   if(!positionsOpen)
     {
      g_dayStartDay       = dt.day;
      g_dayStartBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLossHalted   = false;
      g_sessionHalted     = false;
      g_consecutiveLosses = 0;
      RiskStateSave();
      LogRisk(StringFormat(
         "New day — balance snapshot: %.2f | All session risk state reset.", g_dayStartBalance));
     }
  }
```

---

## Section 4 — Unfinished Auction: Spatially Correct, Logically Wrong, Entirely Dead

**Severity: Low — zero trading impact**

```mql5
g_bars[bi].levels[0].is_unfinished_hi =
   (g_bars[bi].levels[0].ask_vol > 0 && g_bars[bi].levels[0].bid_vol > 0);
g_bars[bi].levels[len-1].is_unfinished_lo =
   (g_bars[bi].levels[len-1].bid_vol > 0 && g_bars[bi].levels[len-1].ask_vol > 0);
```

**Spatial assignment:** With the actual descending sort, `levels[0]` = bar HIGH and `levels[len-1]` = bar LOW. `is_unfinished_hi` is assigned to the HIGH and `is_unfinished_lo` to the LOW — spatially correct.

**Condition logic:** The standard footprint definition of an unfinished auction at the HIGH is near-zero ask volume at the top — buyers could not find sellers, so the market did not complete its auction at that price. The code checks `ask_vol > 0 && bid_vol > 0` (both sides active), which is almost universally true for any traded level and captures nothing meaningful about the concept.

**Impact:** None. Neither `is_unfinished_hi` nor `is_unfinished_lo` is read by `ComputeOFScore()`, `ComputeHFTSignal()`, or `GetConvictionResult()`. These fields are written on every bar close and silently discarded. The struct carries two flags that contribute to memory layout but produce no signal output. This is dead code with wrong condition logic.

---

## Section 5 — Carried Performance and Architecture Issues

These were identified in prior reviews and remain unaddressed.

### 5.1 — Triple Level Scan per Bar in PlaceOrders (Medium)

On every new bar close, `PlaceOrders()` performs four complete sweeps of all price levels on the same unchanged bar data:

1. `ComputeHFTSignal(bi)` → calls `ComputeOFScore(bi)` internally (sweep 1+2)
2. `ComputeOFScore(bi)` called explicitly at line 2274 (sweep 3)
3. `GetConvictionResult(bi, direction)` (sweep 4)

`EvalAndFireSignal()` also independently double-scans. At 50–200 levels per bar, this is 400–1,600 redundant level iterations per bar close. The partial cache infrastructure (`g_sigCacheBarIdx`, `g_sigCacheVol`) exists for `EvalAndFireSignal()` — extending it to `PlaceOrders()` eliminates the redundancy entirely.

### 5.2 — ComputeNakedPOCs is O(n²) in Bar Count (Medium)

For `InpHistoryBars = 200`: ~20,000 comparisons at startup.  
For `InpHistoryBars = 5,000` (max): ~12.5 million comparisons.

This runs synchronously in `ReloadHistory()`, blocking `OnTick()` for its entire duration. On a VPS with a slow CPU or large history sets this produces a visible startup stall.

### 5.3 — C6 CVD Slope Skips Bar bi-1 (Low)

```mql5
double nd0 = (double)g_bars[bi].total_delta   / v0;   // current bar
double nd2 = (double)g_bars[bi-2].total_delta / v2;   // two bars ago
double slope = (nd0 - nd2) / 2.0;
```

`g_bars[bi-1]` is never consulted. A momentum reversal that occurred at bar `bi-1` (between the two lookback points) is entirely invisible to this slope calculation.

### 5.4 — Quicksort Degenerate Pivot (Low)

Always-last-element pivot degenerates to O(n²) with O(n) recursion depth on already-sorted input. Trending environments with monotonically increasing price levels can produce sorted arrival order. At n ≤ 200 levels this will not cause a stack overflow but can produce a sorting spike. Median-of-three pivot selection is a one-line fix.

### 5.5 — Signal Marker Counters Reset on Crash-Restart (Low)

```mql5
g_sigMarkerCount = 800000000UL;   // OnInit()
g_virtualTicket  = 900000000UL;
```

After a terminal crash (no `OnDeinit()`), orphaned chart objects remain. On the next startup the counters reset to their hardcoded values; `ObjectCreate()` silently fails for any name that already exists, leaving the prior session's stale objects on the chart while new signals produce no visual output. Persisting these counters in GlobalVariables (using the same V8-10 scoping pattern) eliminates the collision.

---

## Section 6 — What Remains Professionally Sound

The following areas continue to meet or exceed production standards and have not regressed:

**Trade execution:** `trade_Send()` retry loop with price refresh on requote, correct broker filling-mode detection, STOPS_LEVEL enforcement before submission. Sound.

**Risk persistence (V8-10):** GlobalVariable scoping by `magic + symbol`, saved on every state change, log message on restore. The mechanism is correct — only the session halt coverage is incomplete.

**Input validation:** 30+ guards in `OnInit()` with immediate rejection and clear alert messages. All four OFS weights individually validated. The `InpHaltConsecLosses > InpMaxConsecLosses` cross-guard is logically correct and prevents ambiguous configurations.

**Logging:** Four-level verbosity hierarchy correctly applied throughout. LogWarning and LogRisk now gate on `LOG_TRADES_ONLY` — risk events are visible to any user with trade-level logging enabled.

**Tick classification:** `Classify()` fallback from `TICK_FLAG` to last/bid movement is correct. The `g_hasTrades` proxy mode and forced reload on transition are correctly implemented.

**Break-even and trailing interaction:** 250ms throttle gate, STOPS_LEVEL enforcement, and V8-16 suppression log are all correctly implemented. The interaction logic correctly prevents the trailing stop from overriding a recently moved break-even stop.

---

## Section 7 — Complete Issue Register

| ID | Severity | Source | Description |
|---|---|---|---|
| SORT-DIR | Critical | This review | Quicksort produces descending order; all spatial comments say ascending |
| C3-REG | High | v8.02 (carried) | POC gravity negated — 15% of HFT composite inverted |
| C5-REG | High | v8.02 (carried) | Exhaustion scan directions swapped — 10% of HFT composite inverted |
| BUG-A-SCOPE | High | This review | Session halt reset only fires when InpMaxDailyLossPercent > 0 (default = 0) |
| DEAD-UA | Low | Prior (carried) | Unfinished Auction condition wrong; flags never consumed by scoring |
| CARRY-SCAN | Medium | Prior (carried) | Triple level scan per bar in PlaceOrders |
| CARRY-POC | Medium | Prior (carried) | ComputeNakedPOCs O(n²) |
| CARRY-CVD | Low | Prior (carried) | C6 slope skips bar bi-1 |
| CARRY-PIV | Low | Prior (carried) | Quicksort last-element pivot |
| CARRY-CTR | Low | Prior (carried) | Signal marker counters reset on crash-restart |

---

## Section 8 — Scorecard

| Dimension | v8.01 | v8.02 | v8.03 | Notes |
|---|---|---|---|---|
| Signal Correctness | 5/10 | 8/10* | **6/10** | C3+C5 now inverted; 25% of composite wrong |
| Risk Management | 7/10 | 6/10 | **7/10** | BUG A partially fixed; scope issue remains |
| Code Quality | 7/10 | 7/10 | **7/10** | EA_VERSION clean; sort mismatch undocumented |
| Performance | 6/10 | 6/10 | **6/10** | No changes |
| Architecture | 5/10 | 5/10 | **5/10** | No structural changes |
| **Overall** | **6.3** | **6.4** | **6.2** | Net regression from v8.02 |

*v8.02's 8/10 for signal correctness was assigned before the sort-order discovery. The v8.02 POC and exhaustion fixes would not have been applied had the sort order been correctly identified in the v8.01 review.*

---

## Section 9 — Priority Fix List for v8.04

In order of trading impact:

1. **[CRITICAL] Resolve the sort order contract.**  
   Option A: Change `>=` to `<=` in `SortLevelsPartition()` to produce genuine ascending order. Then revert the C3 negation and exhaustion direction swap (they become correct for ascending). Correct all absorption spatial loops to use `i < chkA` for LOW and `i >= len-chkA` for HIGH.  
   Option B: Leave the descending sort as-is. Correct all comments to read "price-descending (index 0 = highest price = bar HIGH)." Then revert C3 and exhaustion (they are correct for descending). This requires fewer code changes.  
   Either option is acceptable. Ambiguity between documented and actual sort direction is a future-maintenance landmine.

2. **[HIGH] Revert C3 POC gravity negation.**  
   Restore `c3 = +(pocPos * 2.0 - 1.0)`. This is correct for the actual descending sort and was the original v8.01 implementation.

3. **[HIGH] Revert exhaustion scan directions.**  
   Restore `askRun` scanning from `i=0` descending and `bidRun` from `i=len-1` ascending. Correct the spatial comments to match the actual descending layout.

4. **[HIGH] Fix BUG A scope issue.**  
   Extract new-day state reset into a standalone `CheckNewDay()` function called unconditionally from `CheckRiskConditions()`, independent of `InpMaxDailyLossPercent`.

5. **[MEDIUM] Eliminate triple scan per bar.**  
   Cache `hftScore`, `ofsScore`, and `conv` at bar-close time keyed by `(bar_idx, total_vol)`. Remove the redundant `ComputeOFScore(bi)` call in `PlaceOrders()`.

6. **[LOW] Fix Unfinished Auction condition logic or remove it.**  
   Replace the "both sides > 0" condition with the standard single-side dominance check (ask near-zero at HIGH = unfinished high; bid near-zero at LOW = unfinished low). Wire the flags into at least one scoring function, or delete the dead code entirely.
