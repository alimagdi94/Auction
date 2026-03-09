# OrderFlowEA v8.05 — Objective Code Review
**Standard:** Industry-level software engineering + quantitative trading practices  
**File:** `OrderFlowEA_v805.mq5` — 2,965 lines (+146 from v8.04)  
**Change log:** 5 passes (RESTART-WIPE, DEAD-UA, CARRY-SCAN, CARRY-POC, CARRY-CVD)  
**Date:** March 2026  
**Context:** Fifth consecutive patch review

---

## Executive Summary

All five changelog passes are implemented correctly and represent genuine improvements across correctness, performance, and architecture. No new bugs were introduced. This is the cleanest patch cycle in the review series.

Two minor calibration notes: the CARRY-SCAN reduction is 4→3 level passes per bar close rather than the 4→2 claimed in the changelog (a counting nuance, not a logic error), and the `*3.0` scaling factor in C6 was calibrated for the old 2-point slope formula and has not been recalibrated for the 3-bar formula (output is clamped so this has no functional impact).

After five patch cycles, the EA is in a substantially clean state. The signal pipeline is correct across all six components, risk persistence is fully functional through same-day restarts, performance is no longer O(n²) at startup, and the three carried low-severity issues are the only remaining work items.

---

## Section 1 — Pass-by-Pass Fix Verification

### Pass 1 — RESTART-WIPE: g_dayStartDay Persisted
**Status: Correctly fixed.**

`g_dayStartDay` is now included in both `RiskStateSave()` and `RiskStateLoad()`:

```mql5
// RiskStateSave():
GlobalVariableSet(GVKey("DayStartDay"), (double)g_dayStartDay);   // line 524

// RiskStateLoad():
if(GlobalVariableCheck(GVKey("DayStartDay")))
   g_dayStartDay = (int)GlobalVariableGet(GVKey("DayStartDay"));  // line 539
```

The `OnInit()` sequence is correctly ordered: `g_dayStartDay = -1` at line 2726, then `RiskStateLoad()` at line 2733 overwrites it with the persisted value. `CheckNewDay()` at line 1804 gates on `dt.day == g_dayStartDay` — a same-day restart now loads, say, `g_dayStartDay = 9`, sees `9 == 9`, and returns immediately, preserving the halted state that `RiskStateLoad()` just restored.

Genuine new-day scenarios behave correctly: a restart on a new calendar day loads `g_dayStartDay = 8` (yesterday), `CheckNewDay()` sees `9 != 8`, no positions open → resets all risk state as intended.

First-ever startup (no GlobalVariables): `g_dayStartDay` remains -1 after `RiskStateLoad()`, `CheckNewDay()` fires on first tick and sets up the initial snapshot. Correct.

---

### Pass 2 — DEAD-UA: Unfinished Auction Spatial + Condition
**Status: Correctly fixed. Flags now semantically accurate. Flags remain unconsumed — see Section 2.**

```mql5
// With ascending sort: levels[0]=LOW, levels[len-1]=HIGH
g_bars[bi].levels[0].is_unfinished_lo =
   (g_bars[bi].levels[0].total_vol > 0 &&
    g_bars[bi].levels[0].bid_vol <= exhThr);           // near-zero bid at LOW ✅

g_bars[bi].levels[len-1].is_unfinished_hi =
   (g_bars[bi].levels[len-1].total_vol > 0 &&
    g_bars[bi].levels[len-1].ask_vol <= exhThr);       // near-zero ask at HIGH ✅
```

**Spatial assignment:** `is_unfinished_lo` → `levels[0]` (bar LOW), `is_unfinished_hi` → `levels[len-1]` (bar HIGH). Correct for ascending sort.

**Condition logic:** Standard footprint interpretation: near-zero ask_vol at the HIGH means buyers exhausted at the top (no sellers found); near-zero bid_vol at the LOW means sellers exhausted at the bottom (no buyers found). Both conditions now correctly capture the "single-print / failed auction" concept. The `InpExhaustionZeroRat` threshold is reused consistently with the exhaustion detection logic. Correct.

---

### Pass 3 — CARRY-SCAN: Redundant Level Scan Eliminated
**Status: Correctly implemented. Scan reduction is 4→3, not 4→2 as stated in changelog. Not a logic error.**

`ComputeHFTSignal()` now accepts an optional `preOFS = -1` parameter:

```mql5
double ComputeHFTSignal(int bi, int preOFS = -1)
  {
   ...
   double c1 = ((preOFS >= 0 ? preOFS : ComputeOFScore(bi)) - 50.0) / 50.0;
```

When `preOFS >= 0` (caller supplies a pre-computed score), the internal `ComputeOFScore()` call — and its full levels[] scan — is skipped. Both `EvalAndFireSignal()` and `PlaceOrders()` now follow the compute-once pattern:

```mql5
int    ofsScore = ComputeOFScore(bi);         // 1 pass
double hftScore = ComputeHFTSignal(bi, ofsScore);  // skips OFS rescan
```

**Actual scan count per bar close, measured by full `levels[]` iterations:**

| Call | Old | New |
|---|---|---|
| `ComputeOFScore` (C1 source) | Called twice (once internally, once explicitly in PlaceOrders) | Called once |
| `ComputeHFTSignal` C4+C5 scan | 1 pass | 1 pass |
| `GetConvictionResult` | 1 pass | 1 pass |
| **Total** | **4 passes** | **3 passes** |

The changelog describes this as "4→2" — likely counting the two _calls_ eliminated rather than residual pass count. The actual improvement is elimination of one full `len`-iteration pass per bar close. At 50–200 levels, this is a genuine win. The implementation is correct; the description is a counting nuance.

The `preOFS = -1` sentinel and `preOFS >= 0` guard are a clean, backward-compatible API design. All existing call sites that omit the parameter continue to compute OFS internally with no behavioral change.

---

### Pass 4 — CARRY-POC: O(n log n) ComputeNakedPOCs
**Status: Algorithm correct. Complexity claim is accurate for typical inputs. One inherited issue noted.**

The replacement is a textbook price-sorted binary-search algorithm:

```
Phase 1: Collect (pocPrice, barIdx) pairs into parallel arrays — O(n)
Phase 2: Sort pairs by price via SortPocPartition — O(n log n)
Phase 3: For each bar j, binary-search [bar_j.low, bar_j.high] range,
         mark any POC with barIdx < j as retested — O(n log n + T)
Phase 4: Assign is_naked_poc = !retested[barIdx] — O(n)
```

**Correctness verification:**

The `retested[]` array is indexed by **bar index** (0..n-1), not by position in the sorted POC array. Phase 3 writes `retested[pocBx[k]] = true` using the bar index stored in `pocBx[k]`, and phase 4 reads `retested[i]` using the same bar index. These are consistent.

The guard `pocBx[k] < j` correctly ensures a bar can only be marked retested by a strictly later bar, preventing a bar from self-retesting its own POC.

Bars with no valid POC (pi < 0) are excluded from the pocPx/pocBx collection in phase 1, not processed in phase 3, and skipped by the `continue` guard in phase 4. They retain `is_naked_poc = false`. Correct.

Binary search functions `NpocBinLo` and `NpocBinHi` implement standard lower_bound and upper_bound respectively. The range `[k0, k1)` correctly captures all POC prices in the closed interval `[lo, hi]`. Verified:
- `NpocBinLo`: returns first k where `arr[k] >= val` (lower_bound semantics) ✅
- `NpocBinHi`: returns first k where `arr[k] > val` (upper_bound semantics) ✅

**Complexity note:** The changelog states "O(n log n + total_marks) where total_marks ≤ n." This is slightly imprecise: phase 3's inner loop can execute more than n total iterations if many POC prices fall within multiple bars' price ranges (each retest candidate is a separate loop iteration). In practice the total is O(n log n) amortized — market structure makes it rare for a single POC price to appear in hundreds of bars' ranges. The asymptotic claim holds for typical inputs. No functional issue.

**Inherited issue:** `SortPocPartition` uses the same always-last-element pivot as `SortLevelsPartition`. The existing CARRY-PIV issue now applies to two sort functions. On nearly-sorted POC-price input (common in trending environments), both degrade toward O(n²) sort time. Still unlikely to cause a stack overflow at n ≤ 5,000, but the risk now applies to the startup sort path as well.

**Benchmark improvement:** For `InpHistoryBars = 5,000`, the double loop executed ≈12.5M price comparisons. The new algorithm performs ≈60,000 sort comparisons + ≈5,000 × log(5,000) ≈ 185,000 binary-search operations — roughly a 50× reduction.

---

### Pass 5 — CARRY-CVD: C6 3-Bar Recency-Weighted Formula
**Status: Correctly implemented in both locations. Minor calibration note.**

Old formula (both C6 in ComputeHFTSignal and Component 4 in GetConvictionResult):
```mql5
double slope = (nd0 - nd2) / 2.0;   // never reads nd1 = bars[bi-1]
```

New formula (applied identically to both):
```mql5
double slope = (2.0 * (nd0 - nd1) + (nd1 - nd2)) / 3.0;
```

This is a recency-weighted first-order finite difference where the segment (bi → bi-1) carries twice the weight of the older segment (bi-1 → bi-2). The formula reads nd1 explicitly, making momentum reversals at bar bi-1 visible.

**Formula derivation check:** `(2*(nd0-nd1) + (nd1-nd2)) / 3 = (2*nd0 - 2*nd1 + nd1 - nd2) / 3 = (2*nd0 - nd1 - nd2) / 3`. This is a valid weighted slope estimator, biased toward the most recent bar change. Correct.

**Consistency:** The same formula is applied to both C6 in `ComputeHFTSignal()` (line 1577) and Component 4 in `GetConvictionResult()` (line 1674). The formulas are identical. The changelog's intent ("applied identically to both") is verified. ✅

**Calibration note:** The `* 3.0` amplifier at line 1578 (`c6 = MathMax(-1.0, MathMin(1.0, slope * 3.0))`) was designed for the old 2-point formula. The new formula has a different unscaled range: maximum unscaled slope is `(2*1 + (1-(-1)))/3 = 4/3` vs the old maximum of `(1-(-1))/2 = 1`. Since the result is clamped to [-1, 1], the effective sensitivity of C6 is slightly reduced under the new formula (the clamp engages earlier). This is a calibration nuance — it does not change the directional signal, only how often C6 saturates at ±1.0. No functional impact on live trading.

---

## Section 2 — Unfinished Auction: Still Dead Code

**Severity: Low**

The Pass 2 fix correctly resolves both the spatial assignment and the condition logic. However, `is_unfinished_hi` and `is_unfinished_lo` are still never consumed by `ComputeOFScore()`, `ComputeHFTSignal()`, or `GetConvictionResult()`. They are computed on every bar close and silently discarded.

The flags now represent a meaningful, correctly-labeled footprint concept with a standard market structure definition. They are five patch cycles old and have never produced trading output. A decision is needed: either wire them into a scoring function (e.g., `is_unfinished_hi` supports a SHORT; `is_unfinished_lo` supports a LONG — analogous to exhaustion), or remove the struct fields, the reset loop, and the assignment block to eliminate maintenance surface.

---

## Section 3 — Remaining Carried Issues

### 3.1 — Both Quicksorts Use Last-Element Pivot (Low)

`SortLevelsPartition` and the new `SortPocPartition` both select `px[hi]` as pivot. On nearly-sorted input (common in trending markets for level prices, and possible for sorted POC prices), both degrade to O(n²) sort time with O(n) recursion depth. At n ≤ 200 for level sort and n ≤ 5,000 for POC sort, a stack overflow is unlikely on typical VPS configurations, but the sort performance spike is real on trending instruments with many ticks per bar. Median-of-three pivot selection is a two-line change in each function.

### 3.2 — Signal Marker Counters Reset on Crash-Restart (Low)

```mql5
g_sigMarkerCount = 800000000UL;   // OnInit(), line 2718
g_virtualTicket  = 900000000UL;   // OnInit(), line 2719
```

After a terminal crash (no `OnDeinit()`), previously-created chart objects remain. On the next startup, these counters reset and `ObjectCreate()` silently fails for any name that already exists — prior-session objects stay on the chart while new signals produce no markers. Persisting these counters in GlobalVariables using the existing V8-10 scoping pattern eliminates the collision with no structural changes.

### 3.3 — C6 Scaling Factor Not Recalibrated (Low)

As noted in Pass 5: the `* 3.0` output amplifier for C6 was designed for the old 2-point formula's sensitivity range. Under the new 3-bar formula, the effective amplification before clamping is `4/3 * 3.0 = 4.0` at maximum slope vs the old `1.0 * 3.0 = 3.0`. The clamp absorbs the difference, so directional signals are unaffected, but C6 saturates at ±1.0 slightly more readily under the new formula. This is a calibration refinement rather than a bug — the scoring weights (w6=0.15) and thresholds do not need to change, but a trader relying on C6's continuous gradation near ±1.0 will see marginally more saturation.

---

## Section 4 — Signal Correctness Full Summary

| Component | Weight | Status in v8.05 |
|---|---|---|
| C1 — OFS Score | 30% | ✅ Correct |
| C2 — Delta divergence | 20% | ✅ Correct |
| C3 — POC gravity | 15% | ✅ Correct |
| C4 — Absorption at extremes | 10% | ✅ Correct |
| C5 — Bid/Ask exhaustion | 10% | ✅ Correct |
| C6 — CVD momentum slope | 15% | ✅ Correct (calibration note: see 3.3) |

All six HFT composite components remain correct from v8.04. No regressions.

---

## Section 5 — Issue Register

| ID | Severity | Status | Description |
|---|---|---|---|
| RESTART-WIPE | High | **Fixed ✅** | g_dayStartDay now persisted; same-day restart correctly preserves halted state |
| DEAD-UA spatial | Low | **Fixed ✅** | Spatial labels swapped; conditions replaced with near-zero aggressor check |
| CARRY-SCAN | Medium | **Fixed ✅** | Redundant OFS scan eliminated via preOFS param; 4→3 level passes per bar close |
| CARRY-POC | Medium | **Fixed ✅** | O(n²) replaced with O(n log n) binary-search algorithm |
| CARRY-CVD | Low | **Fixed ✅** | C6 and Conviction C4 now read bar bi-1 via recency-weighted 3-bar formula |
| DEAD-UA wiring | Low | **Active** | Unfinished Auction flags correctly computed but never consumed by any scoring function |
| CARRY-PIV | Low | **Active** | Last-element pivot in both SortLevelsPartition and new SortPocPartition |
| CARRY-CTR | Low | **Active** | Signal marker counters reset to hardcoded values on crash-restart |
| C6-SCALE | Low | **Active** | C6 scaling factor *3.0 calibrated for old 2-point formula; minor saturation shift under new formula |

---

## Section 6 — Scorecard

| Dimension | v8.01 | v8.02 | v8.03 | v8.04 | v8.05 | Notes |
|---|---|---|---|---|---|---|
| Signal Correctness | 5/10 | 8/10* | 6/10 | 9/10 | **9/10** | No regressions; C6 calibration note minor |
| Risk Management | 7/10 | 6/10 | 7/10 | 7/10 | **9/10** | RESTART-WIPE closed; V8-10 persistence now fully functional |
| Code Quality | 7/10 | 7/10 | 7/10 | 8/10 | **8/10** | UA now correctly documented; changelog count slightly imprecise |
| Performance | 6/10 | 6/10 | 6/10 | 6/10 | **8/10** | O(n²) startup cost eliminated; level scan reduction meaningful |
| Architecture | 5/10 | 5/10 | 5/10 | 5/10 | **6/10** | preOFS threading is clean; UA dead-code remains; pivot issue added to POC sort |
| **Overall** | **6.3** | **6.4** | **6.2** | **7.0** | **8.0** | Clean patch cycle; no new bugs |

*v8.02's score was retroactively incorrect given the sort-order discovery made in the v8.03 review.

---

## Section 7 — Priority Fix List for v8.06

1. **[LOW] Wire Unfinished Auction flags into at least one scoring function, or remove them.**  
   If retaining: `is_unfinished_hi` at the bar HIGH supports a SHORT (buyers failed at top — price will return); `is_unfinished_lo` at the bar LOW supports a LONG (sellers failed at bottom — price will return). Add to `GetConvictionResult()` as conviction tags "UA_Hi" / "UA_Lo" analogous to the existing "AskExh" / "BidExh" pattern. If removing: delete the struct fields, the two reset loops, and the assignment block in `ComputeBarSignals()`.

2. **[LOW] Apply median-of-three pivot to both sort functions.**  
   A two-line change in each of `SortLevelsPartition` and `SortPocPartition` eliminates O(n²) degenerate behavior on already-sorted or nearly-sorted input.

3. **[LOW] Persist signal marker counters in GlobalVariables.**  
   Add `g_sigMarkerCount` and `g_virtualTicket` to `RiskStateSave()`/`RiskStateLoad()` using the existing V8-10 scoping pattern. Eliminates chart-object name collisions after crash-restarts.

4. **[LOW] Recalibrate or document C6 scaling factor.**  
   Either adjust the `* 3.0` amplifier to account for the new formula's range (e.g., `* 2.25` to maintain the same clamp-engagement frequency), or add a comment documenting that the scaling is intentionally loose and relies on clamping.
