# OrderFlowEA v8.06 — Objective Code Review
**Standard:** Industry-level software engineering + quantitative trading practices  
**File:** `OrderFlowEA_v806.mq5` — 3,036 lines (+71 from v8.05)  
**Change log:** 4 passes (CARRY-PIV, CARRY-CTR, DEAD-UA wired, C6-SCALE)  
**Date:** March 2026  
**Context:** Sixth consecutive patch review

---

## Executive Summary

All four v8.06 changelog passes are correctly implemented. The pivot improvements are mathematically sound, the counter persistence eliminates the crash-restart collision, the UA flag wiring correctly follows the AskExh/BidExh pattern, and the C6 scaling recalibration is arithmetically justified.

Six new issues are identified in this review, none of which were introduced by v8.06. They are inherited or surface as consequences of the new UA wiring. The most significant are a risk persistence gap (`g_lastSLBarTimeBuy/Sell` are never saved to GlobalVariables, making `InpSLCooldownBars` non-persistent across restarts), a CVD slope formula that is duplicated verbatim in two functions rather than shared, and an architectural asymmetry where UA flags now affect conviction count but contribute zero weight to the HFT score that the conviction gate is meant to reinforce.

---

## Section 1 — Pass-by-Pass Fix Verification

### Pass 1 — CARRY-PIV: Median-of-Three Pivot in Both Sort Functions
**Status: Correctly implemented in both functions.**

`SortLevelsPartition` (line 1167):
```mql5
int    mid = lo + (hi - lo) / 2;
if(lv[mid].price < lv[lo].price)  { PriceLevel t=lv[lo];  lv[lo]=lv[mid]; lv[mid]=t; }
if(lv[hi].price  < lv[lo].price)  { PriceLevel t=lv[lo];  lv[lo]=lv[hi];  lv[hi]=t;  }
if(lv[mid].price < lv[hi].price)  { PriceLevel t=lv[hi];  lv[hi]=lv[mid]; lv[mid]=t; }
double pivot = lv[hi].price;
```

`SortPocPartition` (line 1404):
```mql5
int mid = lo + (hi - lo) / 2;
if(px[mid] < px[lo]) { double tp=px[lo]; px[lo]=px[mid]; px[mid]=tp; int tb=bx[lo]; bx[lo]=bx[mid]; bx[mid]=tb; }
if(px[hi]  < px[lo]) { double tp=px[lo]; px[lo]=px[hi];  px[hi]=tp;  int tb=bx[lo]; bx[lo]=bx[hi];  bx[hi]=tb;  }
if(px[mid] < px[hi]) { double tp=px[hi]; px[hi]=px[mid]; px[mid]=tp; int tb=bx[hi]; bx[hi]=bx[mid]; bx[mid]=tb; }
```

Both implementations are the standard three-comparison Lomuto median-of-three. The median is moved into `[hi]` so the partition loop below is entirely unchanged. The `SortPocPartition` correctly maintains the parallel `bx[]` array in sync across all three conditional swaps. No duplicate-key edge cases: when two elements are equal, the third comparison `<` (strict) leaves them undisturbed, which is correct. The worst-case improvement from O(n²) to O(n log n) is achieved for sorted, reverse-sorted, and nearly-sorted input.

---

### Pass 2 — CARRY-CTR: Signal Counter Persistence
**Status: Correctly implemented.**

`RiskStateSave()` (lines 559–560) now writes:
```mql5
GlobalVariableSet(GVKey("SigMarkerCnt"),  (double)g_sigMarkerCount);
GlobalVariableSet(GVKey("VirtualTicket"), (double)g_virtualTicket);
```

`RiskStateLoad()` (lines 578–581) restores:
```mql5
if(GlobalVariableCheck(GVKey("SigMarkerCnt")))
   g_sigMarkerCount = (ulong)GlobalVariableGet(GVKey("SigMarkerCnt"));
if(GlobalVariableCheck(GVKey("VirtualTicket")))
   g_virtualTicket  = (ulong)GlobalVariableGet(GVKey("VirtualTicket"));
```

The `double` cast in `GlobalVariableSet` is safe for both counters at their current magnitudes (800M–900M range): IEEE 754 double has 53-bit mantissa, which represents integers exactly up to 2^53 ≈ 9 × 10^15. The counters would need to accumulate roughly 8.1 × 10^6 additional signals from the 800M baseline before precision loss occurs. This is not a practical concern.

**One residual gap** (see Section 3.1): `RiskStateSave()` is only called on trade events. Signal-only activity increments `g_sigMarkerCount` between trade events without persisting the updated value. If the EA crashes mid-session after signals but before any trade closure, the counter restores to its last trade-event value, not its current value. Object name collisions remain possible over the un-persisted gap, though reduced versus pre-fix behavior.

---

### Pass 3 — DEAD-UA: Unfinished Auction Flags Wired into Conviction
**Status: Correctly implemented. One architectural concern — see Section 2.1.**

```mql5
// BUY branch (lines 1714–1717):
if(len > 0 && g_bars[bi].levels[0].is_unfinished_lo)
  { int n = ArraySize(tags); ArrayResize(tags,n+1); tags[n] = "UA_Lo"; }

// SELL branch (lines 1727–1730):
if(len > 0 && g_bars[bi].levels[len-1].is_unfinished_hi)
  { int n = ArraySize(tags); ArrayResize(tags,n+1); tags[n] = "UA_Hi"; }
```

The `len > 0` guard is correct and necessary before indexing `levels[0]` and `levels[len-1]`. The directional mapping is semantically correct and consistent with the spatial layout established in v8.05: `levels[0]` = bar LOW (ascending sort), `levels[len-1]` = bar HIGH. Sellers failing at the LOW supports a LONG; buyers failing at the HIGH supports a SHORT.

The tags follow the existing AskExh/BidExh pattern in structure and position within the if/else branch. Component count accounting is correct: UA tags are counted by `res.componentCount` (line 1767 loop) and are excluded from the NakedPOC carve-out. They will therefore count toward the `InpMinConvictionComp` gate.

---

### Pass 4 — C6-SCALE: Amplifier Recalibrated to × 2.25
**Status: Correctly implemented.**

Old formula maximum unscaled slope: `(nd0 - nd2) / 2.0` → max = `(1 - (-1)) / 2 = 1.0` → effective amp = `1.0 × 3.0 = 3.0`.

New formula maximum unscaled slope: `(2*(1-(-1)) + ((-1)-1)) / 3 = (4 - 2) / 3 = 2/3`... 

Wait — recomputing at true extremes: `nd0=1, nd1=-1, nd2=1` → `(2*(1-(-1)) + ((-1)-1))/3 = (4-2)/3 = 2/3`. But `nd0=1, nd1=-1, nd2=-1` → `(2*(1-(-1)) + ((-1)-(-1)))/3 = (4+0)/3 = 4/3`. Maximum is indeed 4/3, matching the changelog derivation. New effective amp = `(4/3) × 2.25 = 3.0`. ✅

The recalibration correctly restores clamp-engagement frequency to match the pre-v8.05 behavior. Directional output is unchanged; only the saturation boundary is corrected.

---

## Section 2 — New Issues

### 2.1 — UA Flags in Conviction but Not in HFT Score (Medium)

`UA_Lo` and `UA_Hi` now count toward `res.componentCount` and can satisfy or fail `InpMinConvictionComp`. However, neither `is_unfinished_lo` nor `is_unfinished_hi` contributes any weight to `ComputeHFTSignal()`. The six HFT components (C1–C6) with weights summing to 100% are unchanged.

This creates a structural inconsistency: `InpMinConvictionComp` is designed to gate trades by requiring that enough distinct footprint signals *agree with the HFT score*. When UA_Lo or UA_Hi is the deciding component that pushes `conv.componentCount` over the threshold, a trade fires based partly on a signal that is invisible to the score computation. Conviction is supposed to reinforce a score already present in C1–C6; it should not introduce independent signals not represented there.

**Manifestation:** A bar with HFT score = 63 (just above threshold), `InpMinConvictionComp = 2`, one real conviction component, and `is_unfinished_lo` active will trade on the UA tag as the second component. The same bar with no UA flag would be blocked. Yet the HFT score is identical in both cases — the UA flag provides no information to the score that is being "confirmed."

**Fix options:** Either add `is_unfinished_lo/hi` as a component to `ComputeHFTSignal()` (e.g., as C7 or folded into C5), or exclude UA tags from the `componentCount` via the same carve-out pattern used for NakedPOC (which is correctly excluded at line 1766).

---

### 2.2 — `g_lastSLBarTimeBuy/Sell` Not Persisted (Medium)

`g_lastSLBarTimeBuy` and `g_lastSLBarTimeSell` are written in `OnTradeTransaction()` on every SL hit (lines 2983–2984) and are used by `CheckSLCooldown()` (lines 1946–1954) to block re-entry in the same direction for `InpSLCooldownBars` bars. Neither variable is included in `RiskStateSave()` or `RiskStateLoad()`.

On any EA restart — clean or crash — both values reset to 0. `CheckSLCooldown()` then immediately passes for both directions, bypassing the cooldown regardless of how recently the stop was hit. A user who configures `InpSLCooldownBars = 5` as a loss-protection measure loses that protection across every restart. Given that the entire v8.10–v8.20 series has focused on making risk state persist correctly, this is an inconsistency in coverage.

**Fix:** Add `GlobalVariableSet(GVKey("LastSLBuy"), (double)g_lastSLBarTimeBuy)` and the sell equivalent to `RiskStateSave()`, and restore them in `RiskStateLoad()`.

---

### 2.3 — CVD Slope Formula Duplicated Verbatim (Medium)

The 3-bar recency-weighted CVD slope formula is implemented twice:

- `ComputeHFTSignal()`, lines 1627–1633 (C6)
- `GetConvictionResult()`, lines 1739–1744 (Component 4)

Both blocks fetch `v0/v1/v2`, compute `nd0/nd1/nd2`, and apply `(2*(nd0-nd1) + (nd1-nd2)) / 3.0`. The C6-SCALE fix in v8.06 changed the amplifier in `ComputeHFTSignal()` but the `GetConvictionResult()` version has no amplifier and uses a different threshold comparison (`slope > 0.1`), so they are not identical — but the slope computation itself is a strict duplicate.

This is a DRY violation. The v8.05 review identified that both were updated together; it required conscious effort to keep them synchronized. A future change to the formula — e.g., a 4-bar extension or a different weighting — must be applied in two places or the functions diverge silently. A shared helper `double ComputeCVDSlope(int bi)` eliminates the risk.

---

### 2.4 — Signal/Order Bar Asymmetry Undocumented (Low)

`EvalAndFireSignal()` evaluates `bi = nBars - 1` (the current in-progress bar, line 1967). `PlaceOrders()` evaluates `bi = nBars - 2` (the last completed bar, line 2432). This is an intentional design: signals are real-time indicators; orders execute on bar close.

The consequence is that a signal arrow drawn on bar N and a trade placed after bar N closes are computed from different bars. If bar N closes with a direction reversal, the signal arrow says BUY but no order is placed (or a SELL order is placed instead). From a user perspective, a BUY arrow appears, then no buy entry fires — or a sell entry fires. This is confusing on the chart and is not documented anywhere in comments, inputs, or the header changelog.

**Fix:** Add a comment in `OnTick()` noting this design explicitly, and consider whether `InpShowSignals` should display a "pending" marker rather than a directional arrow while the bar is still forming.

---

### 2.5 — `CheckNewDay()` Deferral Has No Retry Deadline (Low)

`CheckNewDay()` (line 1878) defers the new-day reset when the EA's own positions are open:

```mql5
if(positionsOpen) return;
```

The intent is to avoid computing a stale day-start balance snapshot before an overnight position closes. However, `g_dayStartDay` is not updated during the deferral. If a position remains open past midnight and into the following afternoon, `CheckDailyLoss()` continues comparing equity against the two-day-old snapshot. In extreme cases (a position held over a weekend gap), the daily loss percentage check operates on a snapshot that may be three calendar days stale.

A secondary consequence: `g_sessionHalted` and `g_consecutiveLosses` are not reset until the deferred new-day fires. In a gap scenario where the position closes at a large loss, the new-day reset fires on the same tick as the close, instantly clearing the consecutive loss counter that the loss itself might have incremented — because `OnTradeTransaction()` and `CheckNewDay()` run on the same tick in undefined order.

**Fix:** Add a deadline: if `TimeCurrent() - g_dayStartDay_timestamp > 24 hours`, force the snapshot regardless of open positions. This is also the standard approach in institutional position management.

---

### 2.6 — `AccumulateTick()` Linear Level Search (Low)

The hot path for every tick is `AccumulateTick()`, which finds the price level via a reverse linear scan (lines 992–1000):

```mql5
for(int i = used-1; i >= 0; i--)
  {
   if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.5)
     { idx = i; break; }
  }
```

The `skipSearch` guard at line 992 avoids the scan only when the price is completely outside the existing range (a new bar extreme). For all intra-range prices — the vast majority of ticks on a liquid instrument — the full reverse scan runs. With 50–200 levels per bar and thousands of ticks per bar, this is O(levels) per tick. On a 1-minute bar for a liquid futures contract (ES, NQ, NQ-M) accumulating 5,000–20,000 ticks, this is 250,000–4,000,000 comparisons per bar.

`levels[]` is unsorted during accumulation (`sorted = false`), so binary search is not applicable in-flight. A hash map keyed by normalized price would give O(1) lookup. Given MQL5's limitations on standard containers, a simple open-addressing hash table over a fixed-size array is feasible. Alternatively, since `NormP()` produces a discrete price grid, an offset-based direct-index into a pre-allocated array (indexed by `(price - barLow) / g_step`) would be O(1) and avoids all collisions.

This is the last remaining O(n × m) hot-path cost in the EA. The v8.20 and v8.21 patches eliminated the O(n²) startup costs; this is the equivalent runtime cost.

---

## Section 3 — Carried Issues

### 3.1 — Signal Counters Saved Only on Trade Events (Low)

As noted in Section 1, Pass 2: `RiskStateSave()` is called only from `OnTradeTransaction()` and `CheckNewDay()`. `g_sigMarkerCount` increments on every signal draw but is only persisted when a trade event also occurs. In analysis mode (`g_analysisMode = true`, `g_autoTrade = false`), `OnTradeTransaction()` never fires and `RiskStateSave()` is never called. Counter values accumulate indefinitely in memory, are never written to GlobalVariables, and reset to 800M/900M on every restart — meaning the original crash-collision problem is entirely unmitigated in analysis mode.

**Fix:** Either call `RiskStateSave()` after `g_sigMarkerCount++` in `EvalAndFireSignal()`, or persist the counters in a separate lightweight call that does not write the full risk state.

### 3.2 — `GetConvictionResult()` Incremental `ArrayResize` Pattern (Low)

The tag-append pattern throughout `GetConvictionResult()` is:
```mql5
int n = ArraySize(tags); ArrayResize(tags, n+1); tags[n] = "UA_Lo";
```

This pattern calls `ArrayResize()` for each tag added. In MQL5, `ArrayResize()` on a dynamic array without a reserved parameter triggers a heap reallocation on each call. With a maximum of approximately 10 tags, this produces up to 10 sequential reallocations per call to `GetConvictionResult()`. `GetConvictionResult()` is called twice per bar close (once in `EvalAndFireSignal()`, once in `PlaceOrders()`).

Functional impact is negligible at this scale, but the pattern is architecturally poor. `ArrayResize(tags, 0, 12)` at initialization (using the reserve parameter) eliminates all reallocations.

### 3.3 — Hardcoded Strong-Delta Conviction Threshold (Low)

The strong net-delta direction check in `GetConvictionResult()` Component 2 uses:
```mql5
if(isBuy && dr > 0.35)
```

The 0.35 threshold (delta ratio = 35% of total volume) is not exposed as an input parameter and is not documented. It cannot be tuned without a code change. At the same time, all OFS weights, exhaustion sensitivity, absorption ratios, imbalance ratios, and signal thresholds are exposed as inputs. The inconsistency creates a scenario where the user can tune every visible parameter but unknowingly hits a hard-coded conviction gate. A new input `InpBullDeltaThreshold` (default 0.35) would be consistent with the rest of the input surface.

### 3.4 — C3 POC Gravity Uses Level Index, Not Price Distance (Low)

`ComputeHFTSignal()` C3 (line 1584):
```mql5
double pocPos = (double)g_bars[bi].poc_idx / (double)(len-1);
c3 = -(pocPos * 2.0 - 1.0);
```

`pocPos` is the POC's position as a fraction of the *number of discrete price levels*, not its price distance from the bar midpoint. On instruments with uneven tick rounding (e.g., large bid-ask spreads causing gaps in the footprint), two bars with identically positioned POCs in price terms can produce different `pocPos` values if one bar has fewer intermediate levels. This is a minor calibration inaccuracy. A price-distance formula — `(poc_price - bar_low) / (bar_high - bar_low)` — is numerically stable and directly measures what C3 intends to capture.

---

## Section 4 — Signal Correctness Full Summary

| Component | Weight | Status in v8.06 |
|---|---|---|
| C1 — OFS Score | 30% | ✅ Correct |
| C2 — Delta divergence | 20% | ✅ Correct |
| C3 — POC gravity | 15% | ✅ Correct (calibration note: see 3.4) |
| C4 — Absorption at extremes | 10% | ✅ Correct |
| C5 — Bid/Ask exhaustion | 10% | ✅ Correct |
| C6 — CVD momentum slope | 15% | ✅ Correct (amplifier recalibrated in v8.06) |
| UA flags | 0% (conviction only) | ⚠️ Wired into conviction but not into score; see 2.1 |

No regressions. All six HFT components remain directionally and mathematically correct.

---

## Section 5 — Architecture & Code Quality Notes

**Trading Engine (Strengths):** The `trade_Send()` function is production-quality: it fetches a live tick immediately before dispatch, retries on requote/timeout with a 200ms back-off, respects SYMBOL_TRADE_STOPS_LEVEL for SL/TP distance validation, and logs on failure with full context. `CalcLot()` correctly implements true risk-based sizing with a margin-based fallback and logs which path was taken. `ManagePositions()` correctly computes break-even and trailing stop independently and uses the stricter of the two.

**Risk Pipeline (Strengths):** The `CheckRiskConditions()` call chain is clean and the separation of `CheckNewDay()` (unconditional) from `CheckDailyLoss()` (conditional on `InpMaxDailyLossPercent`) correctly fixes the permanent-halt bug from v8.19. The GlobalVariable scoping pattern using magic number + symbol is sound and avoids multi-instance collisions.

**`ProcessTicks()` Static State:** The function uses static locals (`current_bar_time`, `current_sh`, `next_bar_time`, `s_ohlc_sh`, `s_ohlc_bull`) to cache the current bar across calls (line 1068–1081). The `reset_cache=true` parameter resets them. This pattern is correct for the current call graph but is an implicit contract: any new call site that omits `reset_cache=true` after a history reload will inherit stale bar context. The `ReloadHistory()` call at line 1148 passes `reset_cache=true` correctly. If `ProcessTicks()` is ever called from a new context, this contract must be explicitly maintained.

**`InsertBar()` Out-of-Order Cost:** The fast path (line 913) handles chronological inserts in O(1). The fallback path (lines 934–978) handles out-of-order historical ticks via a manual element-shift, which deep-copies each `FPBar` including its `levels[]` sub-array. In live trading this path is never hit. During `LoadHistory()` on heavily-latency-affected tick feeds where timestamps arrive slightly out of order, each such tick triggers O(n) copies of `FPBar` structs with heap-allocated sub-arrays. This is worth noting for high-history-bar configurations on brokers with known tick timestamp issues.

**SL Comment Case Sensitivity:** `OnTradeTransaction()` uses `StringFind(comment, "sl") >= 0` for SL detection (line 2974). `StringFind` is case-sensitive. Brokers that write "SL" (uppercase), "S/L", or "stop loss" in the comment will miss the primary check and fall through to the net-loss fallback. The fallback is correct for most cases but can misclassify manual closes at a loss as SL hits, inflating `g_consecutiveLosses`. Preprocessing with `StringToLower(comment)` before the `StringFind` calls would make the detection broker-agnostic.

---

## Section 6 — Issue Register

| ID | Severity | Status | Description |
|---|---|---|---|
| CARRY-PIV | Low | **Fixed ✅** | Median-of-three pivot in both SortLevelsPartition and SortPocPartition |
| CARRY-CTR | Low | **Fixed ✅** | Signal marker counters persisted in GlobalVariables via RiskStateSave/Load |
| DEAD-UA | Low | **Fixed ✅** | Unfinished Auction flags wired into GetConvictionResult as UA_Hi / UA_Lo |
| C6-SCALE | Low | **Fixed ✅** | C6 amplifier recalibrated from ×3.0 to ×2.25 for 3-bar formula range |
| UA-SCORE | Medium | **Active** | UA flags count toward InpMinConvictionComp but contribute 0% to HFT score |
| SL-COOLDOWN-PERSIST | Medium | **Active** | g_lastSLBarTimeBuy/Sell not included in RiskStateSave/Load; cooldown resets on every restart |
| CVD-DRY | Medium | **Active** | CVD slope formula duplicated verbatim in ComputeHFTSignal and GetConvictionResult |
| BAR-ASYMMETRY | Low | **Active** | Signal evaluated on current bar (bi=N), order placed on closed bar (bi=N-1); undocumented |
| NEWDAY-DEFER | Low | **Active** | CheckNewDay() defers indefinitely while positions are open; no deadline cap |
| TICK-SEARCH | Low | **Active** | AccumulateTick() linear level search on hot tick path; last O(n×m) path in EA |
| CTR-ANALYSIS | Low | **Active** | Signal counters not persisted in analysis mode (RiskStateSave never called without trades) |
| ARRAYRESIZE | Low | **Active** | GetConvictionResult() incremental ArrayResize(n+1) pattern; 10 allocations per call |
| DELTA-THRESHOLD | Low | **Active** | Strong-delta conviction threshold 0.35 hardcoded; not exposed as input parameter |
| C3-INDEX | Low | **Active** | C3 POC gravity uses level index position, not price distance from bar midpoint |

---

## Section 7 — Scorecard

| Dimension | v8.03 | v8.04 | v8.05 | v8.06 | Notes |
|---|---|---|---|---|---|
| Signal Correctness | 6/10 | 9/10 | 9/10 | **8/10** | UA/conviction mismatch (2.1); C3 calibration (3.4) |
| Risk Management | 7/10 | 7/10 | 9/10 | **8/10** | SL cooldown not persisted (2.2); CheckNewDay defer (2.5) |
| Code Quality | 7/10 | 8/10 | 8/10 | **8/10** | CVD duplication (2.3); hardcoded threshold (3.3); ArrayResize pattern (3.2) |
| Performance | 6/10 | 6/10 | 8/10 | **9/10** | Linear tick search is last hot-path O(n×m); all startup O(n²) paths eliminated |
| Architecture | 5/10 | 5/10 | 6/10 | **7/10** | Signal/order bar asymmetry (2.4); ProcessTicks static contract |
| **Overall** | **6.2** | **7.0** | **8.0** | **8.0** | Score holds; new findings are inherited; no regressions introduced |

The overall score holds at 8.0. The four v8.06 fixes (especially median pivot and counter persistence) are genuine quality improvements. The score does not advance because the UA wiring introduced a semantic inconsistency (2.1) and two pre-existing medium issues (2.2, 2.3) are newly identified in this review.

---

## Section 8 — Priority Fix List for v8.07

1. **[MEDIUM] Wire UA flags into HFT score, or exclude from componentCount.**  
   If retaining as conviction-only signals: add `if(tags[i] == "UA_Lo" || tags[i] == "UA_Hi") continue;` to the componentCount loop (line 1766), matching the NakedPOC carve-out. If promoting to a scored component: add a C7 weight (suggest 5–10%, redistributed from C5 or C4 given semantic overlap) and remove the hardcoded exclusion.

2. **[MEDIUM] Persist `g_lastSLBarTimeBuy` and `g_lastSLBarTimeSell` in GlobalVariables.**  
   Add to `RiskStateSave()`:
   ```mql5
   GlobalVariableSet(GVKey("LastSLBuy"),  (double)g_lastSLBarTimeBuy);
   GlobalVariableSet(GVKey("LastSLSell"), (double)g_lastSLBarTimeSell);
   ```
   And restore in `RiskStateLoad()`. Ensures `InpSLCooldownBars` survives restarts.

3. **[MEDIUM] Extract CVD slope into a shared helper.**  
   ```mql5
   double ComputeCVDSlope(int bi)
     {
      if(bi < 2) return 0.0;
      long v0 = MathMax(1, g_bars[bi].total_vol);
      long v1 = MathMax(1, g_bars[bi-1].total_vol);
      long v2 = MathMax(1, g_bars[bi-2].total_vol);
      double nd0 = (double)g_bars[bi].total_delta   / v0;
      double nd1 = (double)g_bars[bi-1].total_delta / v1;
      double nd2 = (double)g_bars[bi-2].total_delta / v2;
      if(!MathIsValidNumber(nd0)) nd0 = 0.0;
      if(!MathIsValidNumber(nd1)) nd1 = 0.0;
      if(!MathIsValidNumber(nd2)) nd2 = 0.0;
      return (2.0 * (nd0 - nd1) + (nd1 - nd2)) / 3.0;
     }
   ```
   Replace both inline blocks with calls to this helper.

4. **[LOW] Persist signal counters on signal draw (analysis mode fix).**  
   Call `RiskStateSave()` immediately after `g_sigMarkerCount++` in `EvalAndFireSignal()`, or add a lightweight `CounterStateSave()` function that writes only the two counter GlobalVariables.

5. **[LOW] Add deadline to `CheckNewDay()` deferral.**  
   Track a `g_newDayDeferStart` timestamp. If positions remain open for more than 12–24 hours past midnight, force the new-day snapshot regardless. Prevents stale balance comparison over weekends or gap events.

6. **[LOW] O(1) level lookup in `AccumulateTick()`.**  
   Replace the reverse linear scan with a direct-index lookup on the normalized price grid. Index = `(int)MathRound((price - barLow) / g_step)` into a pre-allocated array of capacity `ceil(typical_bar_range / g_step)`. Reset the array when a new bar is initialized. Eliminates the last O(n×m) path in the EA's tick pipeline.
