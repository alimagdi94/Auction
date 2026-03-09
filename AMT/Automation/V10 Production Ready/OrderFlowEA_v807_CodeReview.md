# OrderFlowEA v8.07 — Objective Code Review
**Standard:** Industry-level software engineering + quantitative trading practices  
**File:** `OrderFlowEA_v807.mq5` — 3,138 lines (+101 from v8.06, +172 from v8.05)  
**Change log:** 9 passes under the V8-22 tag  
**Date:** March 2026  
**Context:** Seventh consecutive patch review; cross-referenced against `807_ChangeLog.txt`

## Section 2 — New Issues to be fixed

### 2.1 — `g_virtualTicket` Not Persisted When InpShowVisuals=false in Analysis Mode 

`CounterSave()` is called only inside the `if(InpShowVisuals)` block in `EvalAndFireSignal()` (line 2115–2123). `g_sigMarkerCount` is only incremented inside that same block, so its coverage is complete.

`g_virtualTicket` is different: it is incremented in `PlaceOrders()` at line 2624 (`g_virtualTicket++`) whenever analysis mode places a virtual order. This occurs on every new bar where the signal fires, regardless of `InpShowVisuals`. If `InpShowVisuals=false` and `g_analysisMode=true`, virtual orders accumulate but `CounterSave()` is never called. On a crash or restart, `g_virtualTicket` resets to 900M, producing name collisions with any analysis order objects still on the chart from the previous session.

The stated motivation for `CTR-ANALYSIS` was precisely that analysis mode never fires `OnTradeTransaction()`, so `RiskStateSave()` was never called. That is fully true — and `CounterSave()` fixes it for the `InpShowVisuals=true` path. But the `InpShowVisuals=false` case in analysis mode reproduces the original defect for `g_virtualTicket`.

**Fix:** Call `CounterSave()` in `PlaceOrders()` immediately after `g_virtualTicket++`, or move the `CounterSave()` call outside the `if(InpShowVisuals)` block in `EvalAndFireSignal()` and add a matching call in `PlaceOrders()`:
```mql5
// In PlaceOrders(), after: ticket = g_virtualTicket;
if(g_analysisMode) CounterSave();
```

---

### 2.2 — `InpDeltaConvThreshold` Not Validated in OnInit()

Every other threshold input in `OnInit()` is range-checked: `InpAdaptiveThreshMin`, `InpAdaptiveThreshMax`, `InpSignalThreshold` (via `MathMax(1, MathMin(99, ...))`), `InpSLPips`, `InpSLATRMult`, `InpRiskPercent`, and so on. `InpDeltaConvThreshold` has none.

The parameter represents a delta ratio in the range (0.0, 1.0). A setting outside this range produces silent misbehavior:

- `InpDeltaConvThreshold = 0.0`: `dr > 0.0` is true for any bar with a single net buy tick, making `BullDelta` fire trivially. Every bar with any net directional delta becomes a conviction component.
- `InpDeltaConvThreshold = 1.0` or `>= 1.0`: `dr > 1.0` is impossible (delta ratio is clamped to [-1, 1]), so `BullDelta` and `BearDelta` can never fire. Component 2 is silently disabled for all bars. Users who experiment with this parameter will lose conviction components without any diagnostic.
- `InpDeltaConvThreshold < 0`: negative threshold makes `dr > negative_number` trivially true for any bullish bar.

**Fix:** Add to the `OnInit()` validation block:
```mql5
if(InpDeltaConvThreshold <= 0.0 || InpDeltaConvThreshold >= 1.0)
  { Alert("InpDeltaConvThreshold must be between 0 and 1 (exclusive)."); return INIT_PARAMETERS_INCORRECT; }
```

---

### 2.3 — `g_newDayDeferStart` Not Persisted Across Restarts

`g_newDayDeferStart` is a new global variable (line 592) that tracks when the new-day deferral began. It is never included in `RiskStateSave()` or `RiskStateLoad()`.

If the EA restarts (clean or crash) while a deferral is in progress — for example, during a weekend gap with an open position — `g_newDayDeferStart` resets to 0. On the next `CheckNewDay()` call, the timer starts fresh from `TimeCurrent()` rather than from when the deferral originally began. The 24-hour deadline is effectively reset on every restart. In a worst case, repeated scheduled restarts (e.g., VPS reboots every 12 hours) could prevent the deadline from ever firing, leaving the balance snapshot perpetually stale — the exact scenario the fix was designed to prevent.

This follows the exact same pattern as `g_dayStartDay` (fixed in v8.20), `g_lastSLBarTimeBuy/Sell` (fixed in this release), and the other datetime globals. It should be treated consistently.

**Fix:** Add to `RiskStateSave()`:
```mql5
GlobalVariableSet(GVKey("NewDayDefer"), (double)g_newDayDeferStart);
```
And to `RiskStateLoad()`:
```mql5
if(GlobalVariableCheck(GVKey("NewDayDefer")))
   g_newDayDeferStart = (datetime)GlobalVariableGet(GVKey("NewDayDefer"));
```

---

### 2.4 — Orphaned DEAD-UA Changelog Block in File Header

Lines 65–71 contain the body text of the v8.21 DEAD-UA entry without a `[VX-XX]` tag prefix:

```
//|    is_unfinished_hi and is_unfinished_lo were correctly computed  |
//|    since v8.05 but never fed into any scoring function (five      |
//|    patch cycles of dead code). Fix: added UA_Hi and UA_Lo tags   |
//|    to GetConvictionResult() folsing the existing AskExh/BidExh |
//|    pattern. UA_Hi at bar HIGH supports SHORT; UA_Lo at bar LOW   |
//|    supports LONG.                                                 |
```

This block was separated from its `[V8-21] DEAD-UA WIRED:` prefix when the `SL-COMMENT-CASE` block was inserted above it. The text is a dangling orphan: it describes the v8.21 DEAD-UA fix but appears as free-floating body copy with no header. The v8.21 DEAD-UA entry appears nowhere else in the changelog. The historical record is incomplete and the block looks like an in-progress entry to anyone reading the header.

**Fix:** Either prefix the block with `[V8-21] DEAD-UA WIRED:` to restore the original entry, or remove it and rely on the `UA-SCORE` (v8.22) entry — which describes the architectural resolution — as the complete record.

---

## Section 3 — Carried Issues (Unchanged from v8.06)

### 3.1 — C3 POC Gravity Uses Level Index, Not Price Distance (Low)

`ComputeHFTSignal()` C3 (line 1682):
```mql5
double pocPos = (double)g_bars[bi].poc_idx / (double)(len-1);
```

`pocPos` is a fraction of the number of discrete price levels, not the POC's actual price distance from the bar midpoint. On instruments with non-uniform level density (gaps caused by wide spreads, low-liquidity ticks, or price rounding), two bars with identically positioned POCs by price produce different `pocPos` values if one bar has fewer intermediate levels. A price-based formula is numerically more stable and directly measures the intended signal:

```mql5
double pocPos = (g_bars[bi].levels[g_bars[bi].poc_idx].price - g_bars[bi].low)
              / (g_bars[bi].high - g_bars[bi].low + g_step);
```

---

### 3.2 — `AccumulateTick()` Linear Level Search (Low)

The tick hot path (lines 1074–1080) scans levels in reverse linear order for every intra-range price:

```mql5
for(int i = used-1; i >= 0; i--)
  {
   if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.5)
     { idx = i; break; }
  }
```

This is O(levels) per tick for all in-range prices. On liquid futures contracts accumulating thousands of ticks per bar across 50–200 levels, this amounts to millions of comparisons per bar — the last O(n × m) hot path remaining in the EA after the v8.20 and v8.21 startup optimizations.

An O(1) direct-index lookup is straightforward since `NormP(price)` produces a discrete grid:
```mql5
int levelIdx = (int)MathRound((price - g_bars[bi].low) / g_step);
```
This requires a fixed-size lookup array reset on each new bar, but eliminates the search entirely.

---

### 3.3 — Signal/Order Bar Asymmetry Undocumented (Low)

`EvalAndFireSignal()` uses `bi = nBars - 1` (current live bar). `PlaceOrders()` uses `bi = nBars - 2` (last completed bar). This is intentional: signals are real-time alerts; orders execute on bar close confirmation. However it is undocumented in inputs, comments, or the header. A user observing a BUY arrow on bar N that does not produce a buy entry can have no explanation from the EA logs alone if bar N closes bearish.

---

## Section 4 — Signal Correctness Scorecard

| Component | Weight | Status in v8.07 |
|---|---|---|
| C1 — OFS Score | 30% | ✅ Correct |
| C2 — Delta divergence | 20% | ✅ Correct |
| C3 — POC gravity | 15% | ✅ Correct (calibration note: 3.1) |
| C4 — Absorption at extremes | 10% | ✅ Correct |
| C5 — Bid/Ask exhaustion | 10% | ✅ Correct |
| C6 — CVD momentum slope | 15% | ✅ Correct; now calls `ComputeCVDSlope()` |
| Conviction gate | Gate | ✅ UA tags correctly excluded from componentCount |
| Delta threshold | Gate | ✅ Now input-driven; validation gap (2.2) |

No signal regressions. All six HFT components and the conviction gate are logically correct.

---

## Section 5 — Architecture & Code Quality Notes

**`ComputeCVDSlope()` — Extraction Quality:** The helper is correctly positioned between `ComputeOFScore()` and `ComputeHFTSignal()` (Section 10). Its guard `if(bi < 2) return 0.0` makes callers' `if(bi >= 2)` checks redundant but harmless. The function has no side effects and is purely computational. This is the textbook DRY refactor — a genuine quality improvement, not just a mechanical deduplication.

**`CounterSave()` — Function Scope:** The function writes exactly two GlobalVariables and is intentionally lightweight. It avoids the overhead of the full `RiskStateSave()` (which writes eight GlobalVariables) for a hot-path concern. The single-responsibility design is appropriate. Its placement immediately after the counter increment at line 2122 is correct — no intermediate state can corrupt the write.

**`CheckNewDay()` — Deadline Logic:** The `g_newDayDeferStart == 0` guard at line 1976 is correct: it captures only the first defer tick rather than resetting the timer on every call. The `g_newDayDeferStart = 0` reset at line 1980 (before the balance snapshot) ensures the timer is cleared whether the snapshot fires due to deadline expiry or because positions closed normally. The code handles both paths cleanly.

**`RiskStateLoad()` Restore Log:** The log message at line 653 still reads `"[V8-10] Risk state restored from GlobalVariables"` and lists only the five original v8.10 fields. The `LastSLBuy` / `LastSLSell` timestamps added in this release are not included in the log. This is a minor observability gap — a user inspecting the journal after a restart cannot confirm whether SL cooldown state was restored. Adding them to the format string would close the gap.

**`OnInit()` Init Sequence — Counter Reset Before Load:** Lines 2884–2885 reset the counters to their hardcoded defaults, then line 2899 calls `RiskStateLoad()` which overwrites them with the persisted values. The sequence is correct. However, the comment on line 2887 (`"restore from GlobalVariables if available"`) applies to all variables reset in the block above it, not just the risk state variables — the counters are correctly included in that restore. This was the CARRY-CTR fix. The sequence is fine.

---

## Section 6 — Issue Register

| ID | Severity | Status | Description |
|---|---|---|---|
| SL-COOLDOWN-PERSIST | Medium | **Fixed ✅** | g_lastSLBarTimeBuy/Sell persisted via RiskStateSave/Load |
| CVD-DRY | Medium | **Fixed ✅** | ComputeCVDSlope() helper extracted; both call sites updated |
| UA-SCORE | Medium | **Fixed ✅** | UA tags excluded from componentCount via NakedPOC carve-out pattern |
| CTR-ANALYSIS | Low | **Fixed ✅** (partial) | CounterSave() called after g_sigMarkerCount++; g_virtualTicket gap remains when InpShowVisuals=false |
| NEWDAY-DEFER | Low | **Fixed ✅** (partial) | 24h deadline implemented; g_newDayDeferStart not persisted across restarts |
| ARRAYRESIZE | Low | **Fixed ✅** (partial) | Initial 12-slot reserve correct; 10 of 14 subsequent appends omit reserve param |
| DELTA-THRESHOLD | Low | **Fixed ✅** | InpDeltaConvThreshold input added; validation gap in OnInit() remains |
| SL-COMMENT-CASE | Low | **Fixed ✅** | StringToLower applied to copy; all StringFind checks use lowercase |
| CTR-ANALYSIS-VTICKET | Low | **Active (New)** | g_virtualTicket not persisted when InpShowVisuals=false in analysis mode |
| DELTA-THRESH-VALIDATE | Low | **Active (New)** | InpDeltaConvThreshold has no bounds check in OnInit(); silent misbehavior at 0 or ≥ 1 |
| NEWDAY-DEFER-PERSIST | Low | **Active (New)** | g_newDayDeferStart not in RiskStateSave/Load; restart resets 24h deadline clock |
| CHANGELOG-ORPHAN | Very Low | **Active (New)** | Lines 65–71: DEAD-UA body text missing [V8-21] tag prefix; appears as floating block |
| ARRAYRESIZE-INCONSISTENT | Very Low | **Active (New)** | 10 of 14 tag ArrayResize calls omit reserve param after initial 12-slot reserve |
| C3-INDEX | Low | **Active (Carried)** | C3 POC gravity uses level index not price distance; inaccurate on sparse footprints |
| TICK-SEARCH | Low | **Active (Carried)** | AccumulateTick() reverse linear search; last O(n×m) hot path in tick pipeline |
| BAR-ASYMMETRY | Low | **Active (Carried)** | Signal on bi=N, order on bi=N-1; intentional but undocumented; confusing on chart |

---

## Section 7 — Scorecard

| Dimension | v8.05 | v8.06 | v8.07 | Notes |
|---|---|---|---|---|
| Signal Correctness | 9/10 | 8/10 | **9/10** | UA-SCORE resolved; delta threshold now input-driven; C3 calibration carried |
| Risk Management | 9/10 | 8/10 | **9/10** | SL cooldown fully persistent; NewDay defer has deadline; g_newDayDeferStart persist gap |
| Code Quality | 8/10 | 8/10 | **9/10** | CVD extraction clean; delta threshold exposed; ARRAYRESIZE partially inconsistent; orphan changelog |
| Performance | 8/10 | 9/10 | **9/10** | No regressions; tick-search hot path still carried |
| Architecture | 6/10 | 7/10 | **7/10** | CounterSave() scope clean; bar asymmetry still undocumented |
| **Overall** | **8.0** | **8.0** | **8.5** | Genuine advance; most active issues are low/very-low; no medium issues remain |

---

## Section 8 — Priority Fix List for v8.08

**[LOW] 1. Persist `g_virtualTicket` in analysis mode regardless of InpShowVisuals.**  
Add a `CounterSave()` call in `PlaceOrders()` after the virtual ticket increment:
```mql5
g_virtualTicket++;
ticket = g_virtualTicket;
sent   = true;
CounterSave();   // [V8-22] persist immediately; OnTradeTransaction never fires in analysis mode
```

**[LOW] 2. Validate `InpDeltaConvThreshold` in `OnInit()`.**  
After the existing weight validation block:
```mql5
if(InpDeltaConvThreshold <= 0.0 || InpDeltaConvThreshold >= 1.0)
  { Alert("InpDeltaConvThreshold must be between 0 and 1 (exclusive)."); return INIT_PARAMETERS_INCORRECT; }
```

**[LOW] 3. Persist `g_newDayDeferStart` in `RiskStateSave()`/`RiskStateLoad()`.**  
```mql5
// In RiskStateSave():
GlobalVariableSet(GVKey("NewDayDefer"), (double)g_newDayDeferStart);

// In RiskStateLoad():
if(GlobalVariableCheck(GVKey("NewDayDefer")))
   g_newDayDeferStart = (datetime)GlobalVariableGet(GVKey("NewDayDefer"));
```

**[VERY LOW] 4. Fix orphaned DEAD-UA changelog block (lines 65–71).**  
Prefix the block with `//|  [V8-21] DEAD-UA WIRED:` to restore the original v8.21 entry, or remove it entirely.

**[LOW] 5. Add `LastSLBuy`/`LastSLSell` to `RiskStateLoad()` log message.**  
Include the restored SL timestamps in the existing log string so journal inspection confirms cooldown state was recovered after a restart.

**[LOW] 6. Standardise `ArrayResize` reserve parameter across all tag appends.**  
Apply `ArrayResize(tags, n+1, 12)` uniformly to all 14 append sites in `GetConvictionResult()`.

**[LOW — Carried] 7. Replace C3 level-index formula with price-distance formula.**  
```mql5
// Replace:
double pocPos = (double)g_bars[bi].poc_idx / (double)(len-1);
// With:
double range = g_bars[bi].high - g_bars[bi].low;
double pocPos = (range > g_step)
   ? (g_bars[bi].levels[g_bars[bi].poc_idx].price - g_bars[bi].low) / range
   : 0.5;
```

**[LOW — Carried] 8. O(1) level lookup in `AccumulateTick()`.**  
Replace the reverse linear scan with a direct-index into a per-bar lookup array keyed by normalised price grid offset. Eliminates the last O(n × m) path in the live tick pipeline.
