# OrderFlowEA v8.01 — Honest Objective Code Review

**Reviewer:** Claude (Anthropic)
**Date:** March 2026
**File:** OrderFlowEA_v801.mq5
**Lines:** 2,653

---

## Executive Summary

This is a genuinely serious piece of work. The EA builds a full footprint chart engine from raw MQL5 ticks — no external library dependency — then runs a multi-component weighted signal model on top of it, complete with production-grade risk controls, indicator state persistence, and detailed logging. The architecture is well above average for retail MQL5 code. That said, there are concrete bugs in the signal math, two performance hazards in the data structures, and several key risk switches that are disabled by default, which could expose a live account to unlimited daily loss. This review identifies all of it without softening.

---

## Overall Grades

| Area | Grade | Short Comment |
|------|-------|---------------|
| Architecture & Structure | B+ | Clean sections, proper enums, good separation of concerns |
| Code Quality & Safety | B+ | Input validation is thorough; logging is excellent |
| Signal Logic Correctness | C+ | Two quantifiable bugs in the composite score; OFS direction logic is flawed |
| Risk Management Design | A- | Best-in-class feature set — but critical features are off by default |
| Performance | B- | Two O(n²) patterns; redundant level scans on every bar |
| Industry Standard Gap | B | Missing partial closes, multi-bar profile aggregation, and dynamic exit logic |

---

## SECTION 1 — BUGS (Fix These Before Live Trading)

### BUG 1 — POC Gravity (C3) Signal Is Backwards

**Location:** `ComputeHFTSignal()`, lines 1270–1275

**The code:**
```mql5
double pocPos = (double)g_bars[bi].poc_idx / (double)(len-1);
c3 = pocPos * 2.0 - 1.0;
```

**What it does:** `poc_idx` is the index into the `levels[]` array, which is sorted by price ascending (index 0 = lowest price level). So when the POC is at the bar's HIGH (idx ≈ len-1), `pocPos ≈ 1.0` and `c3 = +1.0` (bullish). When the POC is at the bar's LOW (idx ≈ 0), `c3 = -1.0` (bearish).

**Why this is wrong:** In market profile and footprint theory, a POC sitting at the HIGH of a bar is a *distribution zone* — the market spent most of its time selling at the top. This is bearish (price likely revisits the value area below). A POC at the LOW indicates accumulation at the bottom, which is bullish. The current implementation assigns the opposite signal to both cases.

**Fix:**
```mql5
// POC at LOW = bullish (accumulation); POC at HIGH = bearish (distribution)
c3 = -(pocPos * 2.0 - 1.0);
```

This is a 15% weight component. With the current bug, every bar with a high POC produces a false bullish contribution to the composite score.

---

### BUG 2 — Absorption Direction in OFS Score Is Undifferentiated

**Location:** `ComputeOFScore()`, line 1238

**The code:**
```mql5
double cAbsorb = hasAbsorb ? (g_bars[bi].is_bullish ? 1.0 : 0.0) : 0.5;
```

**What it does:** If *any* absorption is detected anywhere in the bar, the OFS score gets a full bullish signal (1.0) if the bar closed up, or a full bearish signal (0.0) if the bar closed down.

**Why this is wrong:** The HFT composite signal (C4, 10% weight) correctly distinguishes *where* the absorption is: absorption at the bar LOW is bullish (buyers absorbed selling), absorption at the bar HIGH is bearish (sellers absorbed buying). The OFS score uses bar direction as a proxy instead. This means a bar that closes up but has absorption only at the HIGH (a bearish structure) still scores `cAbsorb = 1.0` (bullish). The OFS score and HFT C4 can point in opposite directions on the same bar, degrading the signal.

**Fix:** Mirror the C4 logic:
```mql5
// Check absorption location, not just bar direction
bool absLow = false, absHigh = false;
int chk = MathMin(3, len/3+1);
for(int i = len-chk; i < len; i++) if(g_bars[bi].levels[i].is_absorption) absLow  = true;
for(int i = 0;       i < chk;  i++) if(g_bars[bi].levels[i].is_absorption) absHigh = true;
double cAbsorb = (!absLow && !absHigh) ? 0.5
               : (absLow && !absHigh)  ? 1.0
               : (absHigh && !absLow)  ? 0.0
               : 0.5;  // absorption at both extremes = neutral
```

---

### BUG 3 — DeltaDivergence Added to Conviction Regardless of Direction

**Location:** `GetConvictionResult()`, lines 1337–1342

**The code:**
```mql5
if(g_bars[bi].is_delta_divergence)
{
   tags[n] = "DeltaDiv";
}
```

**What it does:** `DeltaDiv` is added to the conviction tag list unconditionally, regardless of whether `isBuy` is true or false.

**Why this is flawed:** Delta divergence means the bar closed up but delta was negative (or vice versa). This is a *reversal* signal. If the bar closed up with negative delta (`is_bullish=true`, `total_delta<0`), delta divergence supports a SHORT entry (price likely to fall back toward delta). But the conviction label adds "DeltaDiv" to the LONG entry conviction count just as freely as to the SHORT count.

**Fix:**
```mql5
if(g_bars[bi].is_delta_divergence)
{
    // DeltaDiv on a bullish bar supports SHORT; on a bearish bar supports LONG
    bool divSupportsBuy = !g_bars[bi].is_bullish;
    if((isBuy && divSupportsBuy) || (!isBuy && !divSupportsBuy))
    {
        tags[n] = "DeltaDiv";
    }
}
```

---

### BUG 4 — g_hasTrades Re-check Does Not Trigger History Reload

**Location:** `OnTick()`, lines 2486–2490

**The code:**
```mql5
if(!g_hasTrades && SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0)
{
    g_hasTrades = true;
    LogSystem("g_hasTrades re-checked...");
}
```

**What it does:** If the EA started at session open when `SYMBOL_LAST` was zero, it was running in bid-tick proxy mode (classifying ticks from bid direction change, not TICK_FLAG). When `SYMBOL_LAST` becomes available, the flag is flipped — but all history bars that were built during the proxy window contain misclassified tick data (ask_vol/bid_vol based on bid direction, not actual aggressor side).

**Fix:** Trigger a full history reload when `g_hasTrades` transitions:
```mql5
if(!g_hasTrades && SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0)
{
    g_hasTrades = true;
    g_needs_reload = true;  // discard proxy-classified history
    LogSystem("g_hasTrades re-checked: forcing history reload to reclassify ticks.");
}
```

---

## SECTION 2 — PERFORMANCE HAZARDS

### HAZARD 1 — InsertBar Struct Copy Is O(n²) on Out-of-Order Bars

**Location:** `InsertBar()`, lines 760–779

When a bar must be inserted in the middle of the `g_bars[]` array (out-of-order delivery), the code shifts existing bars upward one-by-one in a manual loop, including copying the inner `levels[]` dynamic array element-by-element. On a 200-bar history load, this is manageable. If `InpHistoryBars` is set to 1000–5000 (the max is 5000), this becomes O(n²) at startup.

**Fix:** Redesign `g_bars` to use an index mapping instead of physical position ordering, or sort once after `LoadHistory()` completes rather than maintaining sorted order on every insert. In practice for normal use (InpHistoryBars ≤ 500), this is tolerable.

---

### HAZARD 2 — Redundant Full Level Scans Per Bar

Every time `PlaceOrders()` runs (once per bar close), it calls:
1. `ComputeHFTSignal(bi)` — scans all levels for C4, C5; calls `ComputeOFScore(bi)` which scans all levels again for delta, imbalances, stacked, absorption
2. `ComputeOFScore(bi)` again explicitly at line 2148
3. `GetConvictionResult(bi, direction)` — third full scan of all levels

For a 50-level bar (typical on 5-minute EURUSD), this is ~150 redundant iterations, all on the same unchanged bar. The OFS score and conviction should be cached at bar-close time and reused.

**Fix:** Compute and cache `hftScore`, `ofsScore`, and `conv` once in `ComputeBarSignals()`. Retrieve from cache in `PlaceOrders()` and `EvalAndFireSignal()`.

---

### HAZARD 3 — ComputeNakedPOCs Is O(n²) in Bar Count

**Location:** `ComputeNakedPOCs()`, lines 1183–1201

For each bar `i`, the function scans all bars `j > i` to check if the POC price was retested. For 200 bars this is 20,000 comparisons. For 5,000 bars (max history) this is 12.5 million comparisons at startup. This runs on every `ReloadHistory()` call.

**Fix:** Build a price → last_bar_seen lookup during the single forward pass that loads ticks, and determine POC retest in O(n) total.

---

## SECTION 3 — SIGNAL ARCHITECTURE CONCERNS

### CONCERN 1 — All Signal Evaluation on Last Closed Bar Only

`PlaceOrders()` hardcodes `bi = nBars - 2` (last completed bar). Orders are placed only on bar close. This is a deliberate and defensible design choice — it avoids repainting — but it means the EA cannot react intra-bar to developing order flow, which is actually the native advantage of a footprint engine. Industry-grade order flow systems typically maintain a live current-bar profile and fire when the signal threshold is crossed intra-bar on confirmation volume.

This is a design limitation, not a bug, but it significantly reduces the responsiveness that justifies the tick-processing overhead.

---

### CONCERN 2 — CVD Slope Skips the Adjacent Bar

**Location:** `ComputeHFTSignal()`, lines 1305–1314

```mql5
double nd0 = (double)g_bars[bi].total_delta   / v0;   // current bar
double nd2 = (double)g_bars[bi-2].total_delta / v2;   // 2 bars ago
double slope = (nd0 - nd2) / 2.0;
```

The slope is computed between the current bar and the bar 2 positions earlier, skipping `bars[bi-1]` (the bar immediately before). This creates a momentum reading that ignores the most recent intermediate delta. A three-point slope using `bars[bi]`, `bars[bi-1]`, `bars[bi-2]` would be more representative.

---

### CONCERN 3 — Adaptive Threshold Baseline Can Degrade Silently

**Location:** `ReloadHistory()` + `OnTick()` (V8-14)

The ATR baseline is initialised from the average of 50 ATR bars on load, then updated with EMA(alpha=2/51) each bar close. If the EA is started during a low-volatility period and there is subsequently a volatility spike, the EMA will eventually converge — but during the transition, the adaptive threshold floor (`InpAdaptiveThreshMin`) may not protect adequately because the baseline is still anchored to the old regime. There is no explicit volatility-regime-break detection.

---

## SECTION 4 — RISK MANAGEMENT AUDIT

The risk management feature set is comprehensive and genuinely well-designed. The V8-10 GlobalVariable persistence is a professional touch that few retail EAs implement.

**Critical Finding: All account protection defaults are OFF.**

| Protection | Default | Risk If Left Off |
|-----------|---------|-----------------|
| Daily Loss Limit (`InpMaxDailyLossPercent`) | 0.0 = OFF | EA will trade to zero in a bad session |
| Consecutive Loss Halt (`InpHaltConsecLosses`) | 0 = OFF | EA will keep entering during broken market conditions |
| Consecutive Loss Size Reduction (`InpMaxConsecLosses`) | 0 = OFF | No automatic size scaling after a streak |
| Equity Loss Halt (`InpMaxEquityLoss`) | 1500.0 | This one IS active but is a fixed dollar amount, not percent. On a $5,000 account it is 30% drawdown. On a $50,000 account it is 3%. Must be set relative to account size. |

**Recommendation:** The `OnInit()` validation should emit an `Alert()` warning (not just a log entry) when all three loss-limit inputs are zero, comparable to the existing [V8-12] alert for analysis+autotrade conflict. A live account running with all limits disabled is an accident waiting to happen.

### Minor Risk Issue — isSLHit Fallback on Comment-Stripped Brokers

**Location:** `OnTradeTransaction()`, line 2592

```mql5
bool isSLHit = isOurOrder
               ? (StringFind(comment, "sl") >= 0 && StringFind(comment, "tp") < 0)
               : (dealNet < 0.0);
```

If the broker strips the order comment (`isOurOrder = false`), any negative net close — including a manually closed losing position — increments `g_consecutiveLosses`. Magic number and symbol gates limit this to the EA's own trades, but if you manually close a position at a loss on the same symbol+magic, it will register as a stop hit. This is documented in the V8-06 comment but bears watching.

---

## SECTION 5 — CODE QUALITY OBSERVATIONS

**Strengths:**

The input validation in `OnInit()` is unusually thorough for MQL5 code — 30+ guard conditions covering parameter relationships (e.g. halt limit must exceed consecutive loss limit). This is industry-standard quality.

The logging system with four levels (`LOG_SILENT`, `LOG_TRADES_ONLY`, `LOG_SIGNALS`, `LOG_FULL`) is well-designed and consistent. The `[EXEC]`, `[SIGNAL]`, `[RISK]`, `[TRADE]` prefixes make filtering the MT5 journal practical.

The three-attempt retry with price refresh in `trade_Send()` correctly handles requote and timeout retcodes. The 200ms sleep between attempts is appropriate.

`GetBrokerFillingMode()` correctly reads the `SYMBOL_FILLING_MODE` bitmask and falls back to RETURN when neither FOK nor IOC is flagged.

`CalcLot()` uses true risk-based sizing (balance × risk% ÷ SL-distance × point-value) with a margin-based fallback — this is correct and better than the fixed-lot or margin-percent approaches seen in most retail EAs.

Memory allocation for `levels[]` arrays uses a 64-element reserve on `ArrayResize()` — reduces reallocation frequency during tick accumulation. Correct approach.

**Weaknesses:**

`LogWarning()` and `LogRisk()` both gate on `LOG_FULL` (line 426, 450). This means a risk event like a session halt or consecutive loss counter increment is invisible if the user has set `InpLogMode = LOG_TRADES_ONLY`. Risk events should print at `LOG_TRADES_ONLY` minimum since they directly affect whether orders are placed.

`ManagePositions()` calls `OrderSend()` with inline `MqlTradeRequest/Result` for SL modification, bypassing the `trade_Send()` wrapper that handles retries and min-distance enforcement. The min-distance enforcement is repeated inline (correct) but the retry loop only covers REQUOTE/CONNECTION/TIMEOUT, not PRICE_CHANGED (which can occur on SL modification). This is a minor inconsistency.

The `InsertBar()` fallback path (out-of-order insertion) has 15 lines of field-by-field struct copy that could be replaced with a struct assignment (`g_bars[i] = g_bars[i-1]`). MQL5 supports struct assignment. The dynamic `levels[]` sub-array copy in the loop is still required, but the scalar field copies are unnecessary verbosity.

The signal marker counter (`g_sigMarkerCount = 800000000UL`) and virtual ticket counter (`g_virtualTicket = 900000000UL`) are reset to hardcoded values on every `OnInit()`. If the EA is restarted mid-session, it will reuse object names already on the chart, causing `ObjectCreate()` to silently fail. This is caught by V8-08's cleanup on `OnDeinit()` but not if the terminal crashes rather than deinitialising cleanly.

---

## SECTION 6 — MISSING FEATURES FOR INDUSTRY-STANDARD STATUS

The following features are standard in professional order-flow tools and are currently absent:

**Partial/Scale-Out TP:** The EA is all-in / all-out. No mechanism to close 50% at TP1 and trail the remainder. This leaves significant edge on the table on larger moves.

**Multi-Bar Volume Profile Aggregation:** The footprint engine is single-bar only. Session VPOC, developing value area across multiple bars, and composite profiles (the most powerful order flow signals) are not computed. This is a significant gap relative to tools like Bookmap or Sierra Chart's TPO/Profile charts.

**Live Current-Bar Profile:** The engine only signals on `bar[-2]` (closed bar). A current-bar live profile with a real-time OFS threshold would let the EA enter intra-bar on confirmation, which is how professional order-flow traders actually execute.

**Dynamic Exit on Adverse Delta:** If the trade direction's delta reverses while a position is open (e.g., delta was bullish at entry but turns strongly negative mid-trade), the EA does not exit early. A delta-reversal exit is standard in order-flow strategies.

**Multi-Symbol Correlation Gate:** No check for correlated position risk across symbols (e.g., simultaneous EURUSD + GBPUSD long on dollar weakness). Different EA instances on different symbols do not communicate.

**Slippage Logging:** The difference between requested entry price and actual fill price is not tracked. Over time, this data is critical for evaluating whether ATR-based entries are being filled at acceptable prices.

---

## Summary Scorecard

| Category | Score | Key Action |
|----------|-------|------------|
| Architecture | 8/10 | No structural changes needed |
| Signal Correctness | 5/10 | Fix BUG 1 (POC), BUG 2 (Absorption OFS), BUG 3 (DeltaDiv direction) |
| Risk Controls | 7/10 | Enable daily loss limit and halt limits by default; add alert when all limits are off |
| Performance | 6/10 | Consolidate 3 level-scan passes into 1; cache OFS+conviction at bar close |
| Production Readiness | 7/10 | Fix g_hasTrades reload on flag transition; fix LogWarning/LogRisk level gate |
| Industry Feature Parity | 5/10 | Add partial TP, current-bar live profile, delta-reversal exit |

**Overall: 6.3/10 — Solid foundation with fixable bugs. Production-deployable after BUG 1–3 are patched and risk defaults are enabled.**
