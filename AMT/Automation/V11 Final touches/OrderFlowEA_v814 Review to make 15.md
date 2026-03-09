# OrderFlowEA — v8.15 Fix Iteration

## Context

This is `OrderFlowEA_v814.mq5`. It is a production-grade MQL5 EA (~3,600 lines)
that uses a footprint/order-flow model to generate and manage trades. The v8.14
changelog is extensive and embedded at the top of the file. The architecture is
well-structured: tick pipeline → signal computation → conviction gate → trade
execution → risk state persistence.

This iteration targets **5 confirmed bugs** found in the v8.14 code review. Apply
all fixes as a single coherent patch. Add an `[V8-29]`-style header for each fix
in the top-of-file changelog block. Increment `#property version` and `EA_VERSION`
to `"8.15"`.

---

## TDL — v8.15

| # | ID | Severity | Location | One-line summary |
|---|-----|----------|----------|------------------|
| 1 | EQUITY-HALT-RECOVER | Critical | `CheckNewDay()`, `OnInit()` | `g_equityHalted` has no recovery path |
| 2 | SPINWAIT-CPU | High | `trade_Send()`, `ManagePositions()` | 50 ms spin-wait burns 100% CPU for no gain over `Sleep()` |
| 3 | NAKED-POC-STALE | High | `OnTick()` → `IsNewBar()` block | `ComputeNakedPOCs()` never called incrementally |
| 4 | SIZE-RED-NEWDAY | High | `CheckNewDay()` | `g_sizeReductionLeft` not reset on new trading day |
| 5 | SL-SLASH-FORMAT | Medium | `OnTradeTransaction()` | `StringFind(commentTail,"sl")` misses broker format `"s/l"` |

---

## Fix 1 — EQUITY-HALT-RECOVER

**Problem**

`g_equityHalted` is set to `true` inside `CheckRiskConditions()` when either
equity guard fires. It is persisted by `RiskStateSave()` / `RiskStateLoad()`.
It is **never reset anywhere**: not in `CheckNewDay()`, not in `OnInit()`. Once
triggered, the EA never places another order for the lifetime of the MT5 terminal
unless the operator manually deletes the `FPEA_<magic>_<symbol>_EquityHalted`
GlobalVariable. There is no documented recovery path, no alert informing the trader
of this, and no way to distinguish "halted because still breached" from "halted
because it was breached three days ago and nobody noticed."

**Fix**

Inside `CheckNewDay()`, after the existing resets for `g_dailyLossHalted` and
`g_sessionHalted`, add:

```cpp
// [V8-15] EQUITY-HALT-RECOVER: equity halt resets on a new trading day so the
//    EA can resume after the account recovers overnight. Unlike session/daily-loss
//    halts, equity halt cannot self-reset intraday because the triggering condition
//    (equity >= balance ± threshold) may still be true. The new-day balance snapshot
//    fires after open positions settle, so the equity comparison will use fresh
//    post-settlement values. If the threshold is still breached on the first
//    CheckRiskConditions() of the new day, the halt is immediately re-applied.
g_equityHalted = false;
```

This resets occur in the same block that already resets `g_dailyLossHalted`,
`g_sessionHalted`, and `g_consecutiveLosses`, so the pattern is consistent.
`RiskStateSave()` is already called at the end of that block — no extra call needed.

---

## Fix 2 — SPINWAIT-CPU

**Problem**

`trade_Send()` and `ManagePositions()` both contain:

```cpp
ulong spinStart = GetTickCount64();
while(GetTickCount64() - spinStart < 50) { /* spin */ }
```

The original `Sleep(200)` was replaced in v8.27/v8.28 to "avoid blocking the tick
thread." However, a spin-wait **also blocks the tick thread** — MQL5 is
single-threaded per chart. The only difference is that the spin-wait burns 100% of
one logical CPU core for the full 50 ms per attempt (up to 150 ms across 3 retries
in `trade_Send()`). The stated benefit does not exist; the CPU cost is real.

**Fix**

Replace both spin-wait blocks with `Sleep(10)`:

```cpp
// [V8-15] SPINWAIT-CPU: spin-wait replaced with Sleep(10).
//    The tick thread is blocked either way in MQL5's single-threaded execution
//    model. Sleep(10) yields the CPU to other processes; a busy spin does not.
//    10 ms is sufficient for a broker price refresh and reduces total retry
//    latency from ≤150 ms to ≤30 ms across three attempts.
Sleep(10);
```

Apply this change in **both** locations:
- `trade_Send()` — inside the `for(int attempt = 1; attempt <= 3; ...)` retry loop
- `ManagePositions()` — inside the `for(int attempt = 1; attempt <= 3 && !modOk; ...)` retry loop

---

## Fix 3 — NAKED-POC-STALE

**Problem**

`ComputeNakedPOCs()` is called only from `ReloadHistory()`. After startup, as new
bars complete, a subsequent bar's range may cross a prior bar's POC price — retesting
it. The `is_naked_poc` flag on the prior bar remains `true` despite the retest,
causing `GetConvictionResult()` to append the stale `"NakedPOC"` suffix in logs
and labels indefinitely until the next full reload.

**Fix**

In `OnTick()`, inside the `if(IsNewBar())` block, call `ComputeNakedPOCs()` once
per bar close, **before** `PlaceOrders()`. `PlaceOrders()` reads `is_naked_poc`
via `GetConvictionResult()`, so the order must be preserved.

```cpp
if(IsNewBar())
{
   if(g_autoTrade || g_analysisMode) RefreshSymbolInfo();
   // [V8-14] Rolling ATR baseline update (existing code — unchanged)
   if(g_atrBaselineReady && g_handleATR != INVALID_HANDLE) { ... }

   // [V8-15] NAKED-POC-STALE: recompute naked POC status on every bar close so
   //    is_naked_poc reflects actual retest history up to the current bar.
   //    ComputeNakedPOCs() is O(n log n) and runs once per bar, not per tick.
   ComputeNakedPOCs();

   PlaceOrders();
}
```

No changes to `ComputeNakedPOCs()` itself are required.

---

## Fix 4 — SIZE-RED-NEWDAY

**Problem**

`CheckNewDay()` resets `g_consecutiveLosses = 0` and `g_sessionHalted = false` on
each new calendar day. `g_sizeReductionLeft` is **not** reset. A trader who hits
the consecutive-loss limit late in a session can arrive the next morning with the
EA still trading at half-size, with no log message explaining why, indefinitely
(the counter only decrements on closed trades, and at 50% size fewer positions are
sized out naturally).

**Fix**

Inside `CheckNewDay()`, in the same block as the other resets:

```cpp
// [V8-15] SIZE-RED-NEWDAY: reset the size-reduction penalty on a new trading day.
//    The penalty phase is tied to a run of consecutive intraday losses; carrying it
//    forward to the next session silently penalises the EA for the wrong session's
//    performance. g_consecutiveLosses is already reset here; g_sizeReductionLeft
//    should follow for consistency.
g_sizeReductionLeft = 0;
```

Add this immediately after the existing `g_consecutiveLosses = 0;` line.

---

## Fix 5 — SL-SLASH-FORMAT

**Problem**

`OnTradeTransaction()` detects SL hits by searching `commentTail` for the
substring `"sl"`. The v8.22 `SL-COMMENT-CASE` fix added `StringToLower()` to
handle `"SL"` → `"sl"`, but it does **not** handle `"s/l"`, which is a common
broker comment format (e.g. MetaTrader's own built-in SL close writes `"sl"` but
third-party and institutional brokers frequently write `"s/l"`, `"stop loss"`, or
`"stop-loss"`). `StringFind(commentTail, "sl")` returns -1 for `"s/l"`, so every
SL hit by these brokers silently falls through to the neutral else-branch instead
of incrementing `g_consecutiveLosses`.

**Fix**

Replace the single `StringFind` check with a helper that tests all known formats:

```cpp
// [V8-15] SL-SLASH-FORMAT: detect all common broker SL comment formats.
//    StringFind(commentTail,"sl") misses "s/l", "stop loss", "stop-loss".
//    isTPHit already only checks "tp" so a similar expansion is applied for symmetry.
bool isSLHit = isOurOrder
               ? ( (StringFind(commentTail, "sl")         >= 0 ||
                    StringFind(commentTail, "s/l")        >= 0 ||
                    StringFind(commentTail, "stop loss")  >= 0 ||
                    StringFind(commentTail, "stop-loss")  >= 0)
                   && StringFind(commentTail, "tp") < 0
                   && StringFind(commentTail, "t/p") < 0 )
               : (dealNet < 0.0);
bool isTPHit = (StringFind(commentTail, "tp")  >= 0 ||
                StringFind(commentTail, "t/p") >= 0);
```

Replace the existing `isSLHit` and `isTPHit` declarations with the above block.

---

## Changelog Entry to Prepend

Add the following block inside the top-of-file comment, before the `[V8-29]` entry:

```
//|  [V8-15] EQUITY-HALT-RECOVER: g_equityHalted resets on new trading day     |
//|    Once set, g_equityHalted was never cleared — acting as a permanent kill   |
//|    switch with no documented recovery path. Fix: reset in CheckNewDay()      |
//|    alongside g_dailyLossHalted / g_sessionHalted. If the threshold is still  |
//|    breached at the first CheckRiskConditions() of the new day, the halt is   |
//|    immediately re-applied using the fresh post-settlement balance snapshot.   |
//|                                                                               |
//|  [V8-15] SPINWAIT-CPU: Sleep(10) replaces spin-wait in retry loops           |
//|    The spin-wait introduced in v8.27/v8.28 blocks the tick thread identically |
//|    to Sleep() in MQL5's single-threaded model, but burns 100% CPU for ≤150ms |
//|    across 3 retries. Sleep(10) is sufficient for broker price refresh.        |
//|                                                                               |
//|  [V8-15] NAKED-POC-STALE: ComputeNakedPOCs() called on every bar close       |
//|    NakedPOC labels in conviction strings and logs went stale intraday as new  |
//|    bars retested prior POC prices. Fix: call ComputeNakedPOCs() once per bar  |
//|    close in OnTick() before PlaceOrders(). Cost: O(n log n) per bar.         |
//|                                                                               |
//|  [V8-15] SIZE-RED-NEWDAY: g_sizeReductionLeft reset on new trading day       |
//|    The 50%-size penalty was not cleared in CheckNewDay(), silently carrying   |
//|    an intraday consecutive-loss penalty into the next session indefinitely.   |
//|    Fix: reset alongside g_consecutiveLosses in CheckNewDay().                 |
//|                                                                               |
//|  [V8-15] SL-SLASH-FORMAT: broker "s/l" / "stop loss" comment formats added  |
//|    StringFind(commentTail,"sl") missed brokers writing "s/l", "stop loss",   |
//|    "stop-loss". SL hits from these brokers fell through to the neutral branch,|
//|    silently failing to increment g_consecutiveLosses. Fix: all common formats |
//|    added to isSLHit; matching t/p expansion applied to isTPHit for symmetry.  |
```

---

## Files to Modify

- `OrderFlowEA_v814.mq5` → produce `OrderFlowEA_v815.mq5`

## Do Not Change

- Signal computation logic (C1–C6, OFS weights)
- Footprint pipeline (`AccumulateTick`, `ProcessTicks`, `LoadHistory`)
- Level map implementation (`levelMap`, `RebuildLevelMap`)
- Risk state persistence schema (GlobalVariable keys and structure)
- All existing input parameters and their validation
- Changelog entries for v8.29 and earlier
