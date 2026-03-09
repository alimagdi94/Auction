# OrderFlowEA v8.02 — Honest Objective Code Review

**Reviewer:** Claude (Anthropic)
**Date:** March 2026
**File:** OrderFlowEA_v802.mq5
**Lines:** 2,732 (+79 from v8.01)
**Context:** Patch release applying all 6 fixes from the v8.01 review

---

## Verdict on the V8-17 Patch

All six fixes from the prior review were applied correctly. The implementations are clean, well-commented, and do exactly what was described. No regressions were introduced. This is a good patch release.

Then a new bug was found during this review that is arguably the most dangerous risk issue in the entire codebase. It was already there in v8.01 — the prior review missed it. It is described first.

---

## SECTION 1 — V8-17 FIX VERIFICATION

Each fix is confirmed correct.

**BUG 1 Fixed — POC Gravity (C3) now negated:**
```mql5
c3 = -(pocPos * 2.0 - 1.0);   // ✅ correct — POC at LOW = bullish
```

**BUG 2 Fixed — OFS absorption now location-based:**
The `absOfsLow` / `absOfsHigh` scan mirrors the C4 logic exactly. The `cAbsorb` four-case logic (both extremes = neutral) is correct and more precise than the original bar-direction proxy. ✅

**BUG 3 Fixed — DeltaDiv gated on direction:**
```mql5
bool divSupportsBuy = !g_bars[bi].is_bullish;
if((isBuy && divSupportsBuy) || (!isBuy && !divSupportsBuy))
```
Correct: a bullish bar with negative delta supports a short, not a long. ✅

**BUG 4 Fixed — g_hasTrades transition triggers reload:**
```mql5
g_needs_reload = true;  // discard proxy-classified history
```
Correctly invalidates bars built with bid-direction classification. ✅

**LogWarning/LogRisk gate fixed:**
Both now gate on `LOG_TRADES_ONLY`. Risk events are visible to any user with trade-level logging. ✅

**Risk defaults alert added:**
The `InpATEnable && !InpAnalysisMode && all-three-limits-zero` guard fires correctly. ✅

---

## SECTION 2 — NEW BUGS FOUND IN V8.02

### BUG A — g_sessionHalted NEVER RESETS (CRITICAL)

**Severity: Critical — this is a permanent trading shutdown with no recovery path**

**Location:** `OnTradeTransaction()`, line 2684; `CheckRiskConditions()`, line 1982; `CheckDailyLoss()`

**The comment in the code (line 2710):**
```mql5
// Session halt resets on the next day (not on a single win — too easy to game)
```

**The reality:** There is no code anywhere in the file that sets `g_sessionHalted = false` after it becomes `true`. `CheckDailyLoss()` resets `g_dailyLossHalted` when a new calendar day is detected. `g_sessionHalted` receives no equivalent treatment.

Worse: the V8-10 GlobalVariable persistence will *restore* `g_sessionHalted = true` on the next day's EA startup. Once the consecutive-loss halt triggers, trading is permanently disabled across restarts, across days, until someone manually edits a GlobalVariable in MT5's global variable editor — a step that is not documented anywhere.

**The code path:**
1. EA triggers `InpHaltConsecLosses` → `g_sessionHalted = true` → `RiskStateSave()` persists it.
2. `CheckRiskConditions()` checks `g_sessionHalted` and returns false on every new trade attempt.
3. Next day: `CheckDailyLoss()` runs, resets `g_dailyLossHalted`, sets new day balance. `g_sessionHalted` is untouched and still true.
4. EA restart: `RiskStateLoad()` reads `SessHalted=1` from GlobalVariables. `g_sessionHalted` is true again before any trades.

**Fix:**
```mql5
// In CheckDailyLoss(), inside the "!positionsOpen" new-day reset block:
g_dayStartDay     = dt.day;
g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
g_dailyLossHalted = false;
g_sessionHalted   = false;   // ADD THIS — reset session halt on new trading day
g_consecutiveLosses = 0;     // also reset the counter that triggered the halt
RiskStateSave();
```

Without this fix, `InpHaltConsecLosses` is functionally an "EA kill switch" rather than a session-level protection.

---

### BUG B — STALE "v8.01" VERSION STRINGS IN FOUR PLACES

**Severity: Low — no functional impact, but causes operational confusion when alerts fire**

Alerts and log strings still read "OrderFlowEA v8.01" in at least four places inside the v8.02 file. When a live alert fires in production, the version label is the first thing a trader uses to identify the running build.

| Location | String |
|----------|--------|
| `OnInit()` line 2382 | `"OrderFlowEA v8.01: Invalid symbol point size."` |
| `OnInit()` line 2447-2448 | `"OrderFlowEA v8.01: InpATEnable=true but InpAnalysisMode=true"` |
| `CheckDailyLoss()` line 1617 | `"OrderFlowEA v8.01 — DAILY LOSS LIMIT REACHED"` |
| `EvalAndFireSignal()` line 1716 | `"OrderFlowEA v8.01 — %s \| %s %s \| HFT:"` |

The daily loss alert and signal log are the most operationally significant since they fire during normal trading. A `#define EA_VERSION "8.02"` constant at the top, referenced in all alert strings, would prevent this class of error in future versions.

---

### BUG C — HTF TREND FILTER USES BID FOR BUY DIRECTION ASSESSMENT

**Severity: Medium — produces subtly wrong trend filter decisions on wide-spread instruments**

**Location:** `CheckHTFTrend()`, approximately line 1560

```mql5
double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
bool   aligned  = isBuy ? (curPrice > emaVal) : (curPrice < emaVal);
```

For a **sell** signal, comparing bid to the EMA is correct: the bid is the reference price for short entries.

For a **buy** signal, the reference price at which a long is executed is the **ask**, not the bid. On an instrument with a 3-pip spread and the EMA sitting exactly between bid and ask, this check could pass (bid > EMA) even though the actual entry price (ask) is below the EMA — meaning the trade is entered against the trend filter's intent.

On major FX pairs with 0.5-pip spreads this is immaterial. On instruments with 3-pip+ spreads (some exotic FX, gold at brokers with wide spreads, CFDs) this matters at trend boundaries.

**Fix:**
```mql5
double curPrice = isBuy
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
```

---

### BUG D — EXHAUSTION DETECTION HAS HIGH FALSE-POSITIVE RATE AT BAR LOW

**Severity: Medium — degrades C5's signal quality silently**

**Location:** `ComputeBarSignals()`, exhaustion section

The code checks `ask_vol ≤ threshold` at the bar's **lowest price levels** (index 0 upward). When it finds enough consecutive near-zero ask cells there, it flags them as `is_exhaustion_ask`, and C5 then returns `c5 = -1.0` (bearish) when `exhAsk` is true.

The problem: on any bar where price rallied — which includes all bullish bars and most bars where the low was made early — the very lowest price levels will naturally show near-zero ask volume. Buyers do not aggressively lift offers at the bar's extreme low; price moved away from there by definition. This means `is_exhaustion_ask` will fire on most upward-moving bars purely as an artifact of price structure, not because buyers are genuinely exhausted.

The conventional footprint interpretation of "buying exhaustion" is near-zero **ask volume at the BAR HIGH** — buyers ran out of aggression at the top. Near-zero ask volume at the bar low is just normal market structure.

The bid exhaustion (`is_exhaustion_bid`) at the bar HIGH has the same problem in reverse: near-zero bid volume at the top is natural on bearish bars because sellers weren't pressing at the high — price had already moved down from there.

**What this means in practice:** C5 injects noise on a significant fraction of bars. The signal is not consistently wrong (the directions in C5 are internally consistent with the spatial logic), but it fires too frequently relative to its actual informational value.

**Fix approach:** Swap the spatial assignment. Check `ask_vol` exhaustion at the bar HIGH (standard "buying exhaustion") and `bid_vol` exhaustion at the bar LOW (standard "selling exhaustion"), then swap the C5 directional mapping accordingly:
```mql5
// ask exhaustion at HIGH = buyers ran out at the top = bearish
// bid exhaustion at LOW  = sellers ran out at the bottom = bullish
if(exhAsk && !exhBid) c5 = -1.0;
if(exhBid && !exhAsk) c5 = +1.0;
```

---

## SECTION 3 — CARRIED ISSUES FROM V8.01 (NOT YET FIXED)

These were labeled "Performance Hazards" or "Concerns" in the v8.01 review. They are not regressions in v8.02 — they simply have not been addressed yet.

### CARRY-1 — Triple Level Scan Per Bar in PlaceOrders

`PlaceOrders()` performs three full sweeps of all price levels on the signal bar every time a new bar closes:

1. `ComputeHFTSignal(bi)` → internally calls `ComputeOFScore(bi)` (full scan)
2. `ComputeOFScore(bi)` called explicitly again at line 2213 (second full scan of identical data)
3. `GetConvictionResult(bi, direction)` (third full scan)

`EvalAndFireSignal()` also double-scans: it calls `ComputeHFTSignal(bi)` then `ComputeOFScore(bi)` separately (scan 1 and 2 again). For a 50-level bar at each tick, this is hundreds of wasted iterations every tick.

The fix is to cache `hftScore`, `ofsScore`, and `conv` at bar-close time in a struct keyed by bar index + volume. The cache invalidation is already partially implemented (`g_sigCacheBarIdx` / `g_sigCacheVol`) for EvalAndFireSignal — extend it to PlaceOrders.

### CARRY-2 — CVD Slope Skips the Immediately Adjacent Bar (C6)

C6 computes slope as `(nd[current] - nd[current-2]) / 2.0`, skipping `bars[bi-1]`. The most recent bar's delta change (from `bi-1` to `bi`) is excluded from the momentum reading. A simple 3-point slope across `bi`, `bi-1`, `bi-2` would be more representative and requires one additional lookup.

### CARRY-3 — ComputeNakedPOCs Is O(n²)

For 200 bars: 20,000 comparisons on reload. For 5,000 bars (max): 12.5 million comparisons. This runs synchronously in `ReloadHistory()`, which blocks `OnTick()` for the duration. On large history sets with slow CPUs (VPS environments), this could cause visible tick lag on startup.

### CARRY-4 — Signal Marker Counter Resets on Every Restart

`g_sigMarkerCount = 800000000UL` and `g_virtualTicket = 900000000UL` are hardcoded reset values in `OnInit()`. On a clean `OnDeinit()` the chart objects are cleaned up, so this is fine. On a terminal crash (no `OnDeinit()`), the next startup starts at the same counter values, causing `ObjectCreate()` to silently fail for any markers that weren't cleaned up before the crash. The orphaned objects remain on the chart but no new marker objects take their names.

---

## SECTION 4 — DESIGN ARCHITECTURE NOTES (UNCHANGED FROM V8.01)

These are structural limitations in the EA's design, not bugs. They represent the gap between the current implementation and what industry-standard order-flow systems offer.

**Signals fire only on the closed bar (`bi = nBars - 2`).** The tick pipeline collects live data on the current bar, but `PlaceOrders()` always evaluates the previous bar. The entire tick-processing infrastructure processes live data that is never used for actual trade entry. The EA effectively ignores the bar it is building in real time. This is the most consequential architectural constraint: all that tick collection overhead is for footprint visualization, not for entry timing.

**No partial take-profit.** All-in / all-out. The trailing stop partially addresses this but there is no mechanism to close a defined fraction at a fixed target.

**No intra-bar delta shift detection.** If a long trade is open and the current bar's delta reverses strongly negative while the bar is still forming, the EA takes no action until the next bar closes.

**Session halt reset is now documented as a known bug (BUG A above)** — formerly this was an undetected issue.

---

## SECTION 5 — WHAT'S GENUINELY GOOD

These have not changed and deserve to be restated:

The V8-17 fixes are high quality. The absorption location fix in particular (BUG 2) is more thorough than the suggested fix from the prior review — the four-case logic handling "absorption at both extremes = neutral" is correct and an improvement over the suggested patch.

The risk defaults alert (`V8-17`) is well-scoped: it gates on `InpATEnable && !InpAnalysisMode`, so it won't fire in analysis mode where no real money is at stake. The wording of the alert is clear and actionable.

The LogWarning/LogRisk gate change (`V8-17`) is the right call and correctly applied to both functions symmetrically.

The `trade_Send()` retry logic, `CalcLot()` true-risk sizing, `GetBrokerFillingMode()` bitmask handling, and input validation depth are all well-implemented and unchanged.

---

## SUMMARY SCORECARD

| Area | v8.01 Score | v8.02 Score | Change |
|------|-------------|-------------|--------|
| Signal Correctness | 5/10 | 8/10 | +3 (3 signal bugs fixed) |
| Risk Management | 7/10 | 6/10 | -1 (BUG A discovered — session halt is permanent) |
| Code Quality | 7/10 | 7/10 | = (stale strings offset patch quality) |
| Performance | 6/10 | 6/10 | = (triple scan not addressed) |
| Architecture | 5/10 | 5/10 | = (no structural changes) |

**Overall: 6.4/10 — Signal math is now substantially correct. BUG A (permanent session halt) must be fixed before enabling `InpHaltConsecLosses`.**

---

## Priority Fix List for v8.03

In order of operational risk:

1. **BUG A** — Add `g_sessionHalted = false` and `g_consecutiveLosses = 0` to the new-day reset block in `CheckDailyLoss()`. Until this is done, `InpHaltConsecLosses` should be left at 0.
2. **BUG D** — Swap exhaustion spatial assignment: check ask_vol at HIGH, bid_vol at LOW.
3. **BUG C** — Use ASK price (not BID) when evaluating HTF trend for buy signals.
4. **BUG B** — Replace the 4 hardcoded "v8.01" strings. Add a `#define EA_VERSION` constant.
5. **CARRY-1** — Cache OFS score and conviction at bar-close; eliminate the triple-scan.
