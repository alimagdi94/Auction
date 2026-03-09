# OrderFlowEA v8.00 — Technical Debt Log (TDL)
**Review Date:** March 2026  
**File:** `OrderFlowEA_v800.mq5`  
**Reviewer:** Independent code review  
**Scope:** Full source, all 2520 lines, Sections 1–15

---

## Summary

The EA is well-structured for its complexity. Sections are clearly delineated, inputs are properly described, and the v7/v8 changelog is faithfully reflected in the code. The risk framework (daily loss, consecutive loss, cooldown, conviction gate) is solid in intent. However, there are **two real bugs** that will produce wrong behaviour in production, **one documented lie** in the v8 changelog, and a collection of structural debts that will compound as the codebase grows. These are listed in order of severity.

---

## CRITICAL — Fix Before Live Deployment

### C-01 · `FindVA()` — Out-of-bounds read on lookahead
**Section 9 · Lines ~843–848**

```mql5
if(hi+1 < count) up += lv[hi+1].total_vol;
if(hi+2 < count) up += lv[hi+2].total_vol;   // guarded correctly
bool canUp = (hi < count-1);                   // ← guard is hi+1, not hi+2
```

The lookahead reads `lv[hi+2]` and `lv[lo-2]`, each with their own bounds check. The bounds checks are **correct**. This item is a false alarm upon closer inspection — `hi+2 < count` is evaluated before the access. **Verdict: not a bug.** However, the real problem is subtler: the lookahead is used to *estimate* the gain from expanding upward or downward by picking the direction that adds more volume over the *next two* levels, but the Value Area only actually expands by *one* level per iteration. This makes the expansion direction decision use information the algorithm has not yet committed to. The CME-standard Value Area algorithm only looks one level ahead per step. The current implementation introduces a directional bias toward wherever the second-next level happens to be larger, which produces a subtly non-standard Value Area on asymmetric profiles.

**Fix:** Remove the two-level lookahead. Expand by one level at a time and re-evaluate:

```mql5
double up = (hi+1 < count) ? lv[hi+1].total_vol : 0;
double dn = (lo-1 >= 0)    ? lv[lo-1].total_vol : 0;
bool canUp = (hi < count-1);
bool canDn = (lo > 0);
```

---

### C-02 · `CleanupAllTradeObjects()` — Three object families are never cleaned up
**Section 6 · Line ~540–546**

```mql5
void CleanupAllTradeObjects()
   for(int i = ObjectsTotal(chart,0,-1)-1; i >= 0; i--)
      if(StringFind(nm,"FP_") == 0) ObjectDelete(chart,nm);
```

Only objects prefixed `FP_` are deleted on deinit. The following prefixes are created but **never deleted**:

| Prefix | Created by | Count per session |
|---|---|---|
| `SIG_AR_`, `SIG_LB_` | `DrawSignalMarker()` | 1–2 per signal |
| `AN_AR_`, `AN_SL_`, `AN_TP_` | `DrawAnalysisEntry()` | 1–3 per analysis signal |

On a busy instrument with `InpShowSignals=true`, this silently accumulates hundreds of chart objects per session. MetaTrader begins noticeably degrading around 10,000 objects. The issue is invisible in short tests but compounds across restarts because objects survive chart symbol changes if the EA is re-attached.

**Fix:** Extend the cleanup loop with additional prefix checks, or standardise all object names under a single prefix (e.g. `FPEA_`).

---

### C-03 · `OnTradeTransaction()` — False SL hits on manual closes and break-even exits
**Section 15 · Lines ~2138–2143**

```mql5
bool isSLHit = (StringFind(comment, "sl") >= 0 && StringFind(comment, "tp") < 0)
               || (StringFind(comment, "sl") < 0 && StringFind(comment, "tp") < 0 && dealNet < 0.0);
```

The fallback branch fires when both "sl" and "tp" are absent from the comment **and** `dealNet < 0`. This catches:

- Any **manual close** at a small loss (e.g., the trader closing a breakeven position that drifted slightly negative due to spread/commission).
- Any close via the MT5 terminal "Close" button.
- A **break-even stop** triggered after the break-even move, where the exit comment is broker-generated (e.g., "stop loss" in some locales, or entirely blank), and the net is negative due to commission.
- `StringFind()` is **case-sensitive** in MQL5. A broker using `"SL"` or `"Stop Loss"` bypasses the primary check, correctly falling to the fallback — but then any accidental negative close also falls through.

The result: `g_consecutiveLosses` is incremented on events that are not stop-loss hits, potentially triggering spurious size reductions or session halts.

**Fix:** Tag the EA's own orders with a deterministic comment substring that is unambiguous (e.g., the existing `FP_Buy_MKT_...` tag already includes enough information). Match on that prefix instead of relying on broker-generated comments.

```mql5
// Primary: did we place this order (tag starts with "FP_")?
bool isOurOrder = (StringFind(comment, "FP_") == 0);
// If comment was stripped by broker, fall back to deal profit only
bool isSLHit = isOurOrder
               ? (StringFind(comment, "sl") >= 0 && StringFind(comment, "tp") < 0)
               : (dealNet < 0.0);
```

---

## HIGH — Incorrect Documented Behaviour

### H-01 · `CheckDailyLoss()` — V8-05 changelog claim does not match implementation
**Changelog lines ~49–52, implementation lines ~1273–1284**

The v8 header explicitly states:

> *"CheckDailyLoss() now snapshots balance at the first tick of the new day **only after pending close orders settle**"*

The actual code:

```mql5
if(dt.day != g_dayStartDay)
  {
   g_dayStartDay     = dt.day;
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);  // ← immediate snapshot
```

There is **no check for open positions or pending orders settling**. The snapshot is taken at the first call to `CheckDailyLoss()` on the new calendar day, which is the first tick of the new day — identical to the v7 behaviour the changelog claims to have fixed. If an overnight position closes at the day open (e.g., gap open triggers TP/SL), the balance snapshot reflects the settled result only if that close happens before the first tick that triggers `CheckDailyLoss()`. In practice this is a race condition.

**Fix:** Gate the snapshot on `PositionsTotal() == 0 && OrdersTotal() == 0` for this magic number, or defer the snapshot by 1 bar.

---

### H-02 · `CheckSessionTime()` — "UTC" comment is incorrect
**Section 12 · Line ~1258**

```mql5
// Returns true if current server time falls inside the active session window.
```

The input description says `"UTC server hour"`. The code uses `TimeCurrent()`, which is **broker server time**, not UTC. These differ for brokers on EET/EEST (UTC+2/+3), which includes most MT5 brokers. A user setting `InpSessionStartHour=7` expecting 07:00 UTC will get 07:00 server time, which may be 04:00 or 05:00 UTC.

**Fix:** Either use `TimeGMT()` for a true UTC check, or correct the input description to say "server time".

---

## MEDIUM — Structural / Correctness Debt

### M-01 · `InsertBar()` — O(n²) deep copy when bars arrive out of order
**Section 8 · Lines ~618–672**

When a tick arrives for an older bar that does not exist yet (e.g., late history ticks), `InsertBar()` shifts the entire `g_bars[]` array one slot forward, performing a full field-by-field deep copy of every `FPBar`, including copying the nested `levels[]` array element-by-element for each bar shifted. With 200 bars and 64 levels each, an out-of-order insert near the beginning copies ~12,800 `PriceLevel` structs. The code is correct in behaviour but slow and fragile: any new field added to `FPBar` must be manually added to the copy block in two separate locations (the shift loop and the `pos` initialiser), or it will silently be omitted.

**Fix:** Refactor to store bar data by reference (pointer pattern via index map) or maintain a `datetime → index` dictionary to avoid structural shifts entirely.

---

### M-02 · Redundant multi-pass over `levels[]` per signal evaluation
**Sections 10, 13**

For each bar evaluation, `ComputeBarSignals()` → `ComputeOFScore()` → `ComputeHFTSignal()` → `GetConvictionResult()` are called in sequence, performing **3–4 independent passes** over `g_bars[bi].levels[]`. `ComputeHFTSignal()` re-computes delta ratio and imbalance counts already available from `ComputeOFScore()`. `GetConvictionResult()` re-computes the CVD slope formula already computed as C6 in `ComputeHFTSignal()`.

On a 200-level bar, each pass iterates 200 elements. At tick rate on a busy instrument, this adds up. More importantly, having the same formula in two places (CVD slope appears in both `ComputeHFTSignal()` C6 and `GetConvictionResult()` Component 4) creates a maintenance hazard — a threshold change in one copy is silently not applied to the other.

**Fix:** Compute a single `BarAnalysisResult` struct from one pass and pass it to all consumers.

---

### M-03 · Risk state is not persisted across EA restarts
**Section 15 · `OnInit()` lines ~2015–2022**

```mql5
g_consecutiveLosses  = 0;
g_sizeReductionLeft  = 0;
g_sessionHalted      = false;
g_dailyLossHalted    = false;
```

All risk counters reset to zero on every `OnInit()`. If MT5 restarts mid-session, disconnects, or the EA is accidentally removed and re-attached, all consecutive loss protection resets silently. On a day where the EA had already hit 3 consecutive losses and size reduction was active, a restart wipes that state and resumes full size.

**Fix:** Persist state in a global variable file (`GlobalVariableSet` / `GlobalVariableGet`) keyed by magic number and symbol, and restore on init.

---

### M-04 · `g_hasTrades` is set once at init and never re-evaluated
**Section 15 · Line ~2027**

```mql5
g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);
```

`SYMBOL_LAST` can be zero at session open before the first trade prints, or for certain broker configurations where LAST is not forwarded for the first few seconds. If the EA initialises during this window, it will fall back to bid-change classification for the entire session, degrading footprint accuracy. There is no subsequent re-check.

**Fix:** Add a lazy re-check on first tick if `g_hasTrades == false && SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0`.

---

### M-05 · ATR baseline for adaptive threshold is computed once and never updated
**Section 11 / 12 · `ReloadHistory()` / `ComputeAdaptiveThreshold()`**

The ATR baseline (`g_atrBaseline`) is computed as a 50-bar average on history load and never updated. On a symbol transitioning between low- and high-volatility regimes (e.g., around news events or session opens), the adaptive threshold eventually becomes a ratio against a stale number. The adaptive feature silently degrades to a fixed threshold once the current ATR diverges significantly from the baseline.

**Fix:** Re-compute the baseline on a rolling basis (e.g., every N bars) or on each new bar using an exponential moving average.

---

### M-06 · Analysis mode + AutoTrade simultaneously active — no init warning
**Section 15 · `OnInit()`**

`InpAnalysisMode=true` suppresses all real order placement. `InpATEnable=true` is the "live trading enabled" flag. If a user sets both to `true` (a plausible mistake when testing), the EA silently runs in analysis mode, drawing virtual trades but placing nothing real. `OnInit()` logs the analysis mode status but does not raise an `Alert()` warning when `InpATEnable && InpAnalysisMode`.

**Fix:** Add an explicit alert:
```mql5
if(InpATEnable && InpAnalysisMode)
   Alert("OrderFlowEA: InpATEnable=true but InpAnalysisMode=true. No real orders will be placed.");
```

---

## LOW — Minor Issues and Polish

### L-01 · Negative OFS weights silently clamped to zero
**Section 10 · `ComputeOFScore()` lines ~921–924**

```mql5
double wD = MathMax(0.0, InpOFWtDelta) / 100.0;
```

A user setting a weight to `-5` (perhaps thinking a negative weight inverts the component) gets 0 silently. The init check only validates `sum > 0`, not individual values. A validation that individual weights must be `>= 0` would catch this earlier with a clear message.

---

### L-02 · `DeleteAllPending()` collects then deletes — silent failure on filled orders
**Section 14**

Pending tickets are collected into an array and then deleted in a second loop. A pending filled between collection and deletion produces a logged error but no corrective action. Not a financial risk (the order is filled as intended), but the log noise can obscure real errors.

---

### L-03 · Signal markers accumulate without cap or TTL
**Section 6 · `DrawSignalMarker()`**

`g_sigMarkerCount` increments from `800000000UL` and never wraps or prunes old objects. No TTL or max-count limit exists. On a trending day with `InpSignalFreqBars=1`, several hundred `SIG_AR_*`/`SIG_LB_*` objects accumulate per session. These are not cleaned by `CleanupAllTradeObjects()` (see C-02).

---

### L-04 · `InpMaxEquityProfit` / `InpMaxEquityLoss` halt by setting `g_autoTrade = false`
**Section 12 · `CheckRiskConditions()` lines ~1608–1614**

```mql5
if(InpMaxEquityProfit > 0.0 && equity >= balance + InpMaxEquityProfit)
  { LogWarning("MaxEquityProfit reached."); g_autoTrade = false; return false; }
```

Setting `g_autoTrade = false` is a permanent mutation for the session. There is no way to resume without restarting the EA. This is probably intentional for the loss case but may be surprising for the profit case — a user who wants to pause at a profit target and re-enable manually cannot do so without a restart (which resets all risk state, see M-03).

---

### L-05 · `ManagePositions()` break-even and trailing interact correctly but silently
**Section 14**

Break-even fires first and sets `newSL`. Trailing then checks `trailSL > newSL + _Point`. On a long position, this means trailing can never move the SL backward past break-even, which is the correct intended behaviour. However, there is no log message when trailing is suppressed by break-even, making it difficult to diagnose why the trailing stop didn't fire in a tester run.

---

### L-06 · `ProcessTicks()` static cache not thread-safe (non-issue now, future risk)
**Section 8**

The static local variables `current_bar_time`, `next_bar_time`, `s_ohlc_sh` in `ProcessTicks()` would be shared across parallel calls if MQL5 ever executes tick processing in parallel. MQL5 is currently single-threaded per chart, so this is not a current risk. Worth noting for future-proofing if the EA is adapted for multi-symbol use.

---

## What Is Working Well

These are genuine strengths that should be preserved as the codebase evolves:

- **Input validation in `OnInit()`** is thorough and covers virtually every combination of mode flags. The cross-parameter checks (e.g., `HaltConsecLosses > MaxConsecLosses`) are particularly good.
- **`trade_Send()` retry logic** correctly handles requotes and timeout retcodes with 3 attempts and 200ms sleep between them. Price refresh on retry for market orders is correct.
- **`GetBrokerFillingMode()`** (v8-03 fix) correctly resolves the non-existent `SYMBOL_FILLING_RETURN` bitmask and documents the reasoning clearly.
- **`CalcLot()`** true risk-based sizing using `tickValue/tickSize` for point value is correct and well-logged. The margin-based fallback is a reasonable safety net.
- **Section structure and comment quality** are well above average for MQL5 EAs. Every non-obvious decision has a reference tag (V7-xx, V8-xx).
- **`CheckRiskConditions()`** correctly separates risk concerns into discrete, composable functions rather than one monolithic guard block.

---

## Priority Order for Next Development Cycle

| # | ID | Action | Effort |
|---|---|---|---|
| 1 | C-03 | Fix SL hit detection to use own order comment prefix | 1h |
| 2 | H-01 | Fix `CheckDailyLoss()` snapshot or remove the false changelog claim | 30m |
| 3 | C-02 | Extend `CleanupAllTradeObjects()` to cover all object prefixes | 30m |
| 4 | M-03 | Persist risk counters via `GlobalVariable` | 3h |
| 5 | H-02 | Fix session time comment or switch to `TimeGMT()` | 15m |
| 6 | M-06 | Add alert when `InpATEnable && InpAnalysisMode` | 15m |
| 7 | M-04 | Add lazy re-check for `g_hasTrades` on first tick | 30m |
| 8 | M-02 | Consolidate multi-pass level analysis into single-pass struct | 4h |
| 9 | M-05 | Rolling ATR baseline update | 1h |
| 10 | M-01 | Refactor `InsertBar()` to avoid O(n²) deep copy | 4h |
| 11 | C-01 | Remove two-level lookahead from `FindVA()` | 30m |
| 12 | L-01–L-06 | Minor polish items | 2h |
