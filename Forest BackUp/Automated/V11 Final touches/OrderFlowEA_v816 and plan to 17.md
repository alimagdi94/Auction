# OrderFlowEA v8.17 — Patch Prompt

## Context
Apply the five fixes below to `OrderFlowEA_v816.mq5` and produce `OrderFlowEA_v817.mq5`.

**Rules:**
- Bump `#property version` to `"8.17"` and `EA_VERSION` to `"8.17"`
- Add a `[V8-17]` changelog block at the top of the file header for each fix
- Do **not** change: signal computation (C1–C6), footprint pipeline, indicator handles, or any existing input parameters
- Output: `OrderFlowEA_v817.mq5`

---

## TDL

| # | Tag | Severity | Location |
|---|-----|----------|----------|
| 1 | DAYSTART-BALANCE-PERSIST | CRITICAL | `RiskStateSave()` / `RiskStateLoad()` |
| 2 | SIZERED-SL-DECREMENT | HIGH | `OnTradeTransaction()`, `isSLHit` branch |
| 3 | PENDING-EXPIRY-MULTIPOS | MEDIUM | globals / `PlaceOrders()` / `ManagePositions()` |
| 4 | RELOAD-VISUAL-LEAK | MEDIUM | `OnTick()`, `g_needs_reload` branch |
| 5 | CALCLOT-MARGIN-ORDERTYPE | LOW | `CalcLot()` signature + `PlaceOrders()` call site |

---

## Fix 1 — `[V8-17]` DAYSTART-BALANCE-PERSIST: g_dayStartBalance persisted in GlobalVariables

**Problem:** `g_dayStartBalance` is not included in `RiskStateSave/Load`. `OnInit()` always writes `g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE)` (current balance at restart time). `RiskStateLoad()` then restores `g_dayStartDay` to today, so `CheckNewDay()` returns early and `g_dayStartBalance` is never corrected. The daily loss limit is measured from the restart balance, not the true session-open balance. If the account is already down 1.5% at restart time with a 2% limit, the EA can lose a further full 2% instead of the remaining 0.5%.

### Step A — Add to `RiskStateSave()`
After the `EquityHalted` line, insert:
```cpp
   // [V8-17] DAYSTART-BALANCE-PERSIST: persist the session-open balance snapshot so a
   //    mid-session restart measures daily loss from the true open, not the restart balance.
   //    Without this, RiskStateLoad() restores g_dayStartDay = today, CheckNewDay() exits
   //    early, and g_dayStartBalance stays at the OnInit() fallback (current balance).
   GlobalVariableSet(GVKey("DayStartBal"), g_dayStartBalance);
```

### Step B — Add to `RiskStateLoad()`
After the `EquityHalted` load block (before the log condition), insert:
```cpp
   // [V8-17] DAYSTART-BALANCE-PERSIST: restore session-open balance.
   if(GlobalVariableCheck(GVKey("DayStartBal")))
      g_dayStartBalance = GlobalVariableGet(GVKey("DayStartBal"));
```

### Step C — Extend the restore log in `RiskStateLoad()`
The existing log condition already fires when any risk state is non-default; no additional change needed to the condition. Add `DayStartBal` to the format string for observability:

Find the log format string:
```cpp
         "[V8-10] Risk state restored from GlobalVariables | ConsecLoss=%d | SizeRedLeft=%d"
         " | SessHalted=%s | DayLossHalted=%s | EquityHalted=%s | DayStartDay=%d"
         " | LastSLBuy=%s | LastSLSell=%s",
```
Replace with:
```cpp
         "[V8-10] Risk state restored from GlobalVariables | ConsecLoss=%d | SizeRedLeft=%d"
         " | SessHalted=%s | DayLossHalted=%s | EquityHalted=%s | DayStartDay=%d"
         " | DayStartBal=%.2f | LastSLBuy=%s | LastSLSell=%s",  // [V8-17]
```
And add `g_dayStartBalance,` to the argument list between `g_dayStartDay,` and the `LastSLBuy` ternary.

---

## Fix 2 — `[V8-17]` SIZERED-SL-DECREMENT: half-size penalty counts all trade closes

**Problem:** `g_sizeReductionLeft` decrements only in the win and neutral branches of `OnTradeTransaction`. The SL-hit branch never decrements it. The input description is "Number of trades to trade at half-size after the consecutive-loss limit" — the count must tick down on every trade close regardless of outcome. In the current code, a losing streak during the penalty phase keeps `g_sizeReductionLeft` frozen until a win occurs, extending the half-size penalty indefinitely.

**Location:** `OnTradeTransaction()`, end of the `if(isSLHit)` block.

**Current code:**
```cpp
      RiskStateSave();   // [V8-10] persist after every loss-streak change
      LogRisk(StringFormat("SL HIT #%d consecutive | %s %s | Net: %.2f",
                           g_consecutiveLosses, dir, _Symbol, dealNet));
```

**Replace with:**
```cpp
      // [V8-17] SIZERED-SL-DECREMENT: consume one penalty trade on every SL close.
      //    The "N trades at half-size" contract counts all trade closes, not only wins.
      //    Without this, a continued losing streak during the reduction phase freezes
      //    g_sizeReductionLeft until a win occurs — an indefinite unintended penalty.
      if(g_sizeReductionLeft > 0) g_sizeReductionLeft = MathMax(0, g_sizeReductionLeft - 1);
      RiskStateSave();   // [V8-10] persist after every loss-streak change
      LogRisk(StringFormat("SL HIT #%d consecutive | %s %s | Net: %.2f",
                           g_consecutiveLosses, dir, _Symbol, dealNet));
```

---

## Fix 3 — `[V8-17]` PENDING-EXPIRY-MULTIPOS: per-order pending expiry tracking

**Problem:** `g_pendingPlacedBarTime` is a single scalar. With `InpMaxPositions > 1` and `InpOrderMode == ORDER_MODE_PENDING`, placing a second order overwrites the first order's timestamp. The first order then never expires on its own — it is only removed if the second order's timer fires (triggering `DeleteAllPending()` which deletes both) or if `InpCleanOldOrders = true` fires on the next signal. With `InpCleanOldOrders = false`, stale pending orders accumulate indefinitely.

### Step A — Add parallel tracking arrays to globals
After the existing `g_pendingPlacedBarTime` declaration:
```cpp
datetime g_pendingPlacedBarTime = 0;
```
Insert immediately after:
```cpp
// [V8-17] PENDING-EXPIRY-MULTIPOS: per-ticket placement tracking replaces the scalar
//    timestamp so expiry fires independently for each pending regardless of InpMaxPositions.
ulong    g_pendingTickets[];
datetime g_pendingBarTimes[];
```

### Step B — Register each new pending in `PlaceOrders()`
Find the existing placement recording line:
```cpp
         if(!isMarket) g_pendingPlacedBarTime = g_bars[bi].bar_time;
```
Add immediately after:
```cpp
         // [V8-17] PENDING-EXPIRY-MULTIPOS: register ticket+barTime for per-order expiry.
         if(!isMarket && ticket != 0)
           {
            int pn = ArraySize(g_pendingTickets);
            ArrayResize(g_pendingTickets, pn+1);
            ArrayResize(g_pendingBarTimes, pn+1);
            g_pendingTickets[pn] = ticket;
            g_pendingBarTimes[pn] = g_bars[bi].bar_time;
           }
```

### Step C — Clear arrays whenever `DeleteAllPending()` fires in `PlaceOrders()`
Find:
```cpp
   if(!g_analysisMode && InpCleanOldOrders) DeleteAllPending();
```
Replace with:
```cpp
   if(!g_analysisMode && InpCleanOldOrders)
     {
      DeleteAllPending();
      ArrayResize(g_pendingTickets, 0);   // [V8-17] clear tracking on explicit clean
      ArrayResize(g_pendingBarTimes, 0);
     }
```

### Step D — Replace the expiry block in `ManagePositions()`
Remove the existing `[V7-11]` expiry block:
```cpp
   // [V7-11] Delete stale pending orders
   if(InpPendingExpiryBars > 0 && g_pendingPlacedBarTime > 0)
     {
      int barsSincePlaced = iBarShift(_Symbol, PERIOD_CURRENT, g_pendingPlacedBarTime);
      if(barsSincePlaced >= InpPendingExpiryBars)
        {
         LogTradeExec(StringFormat("Pending expiry: %d bars elapsed (limit=%d). Deleting.", barsSincePlaced, InpPendingExpiryBars));
         DeleteAllPending();
         g_pendingPlacedBarTime = 0;
        }
     }
```
Replace with:
```cpp
   // [V7-11] / [V8-17] PENDING-EXPIRY-MULTIPOS: per-order expiry.
   //    Each registered pending is checked individually; expired tickets are deleted
   //    one-at-a-time rather than triggering a bulk DeleteAllPending().
   if(InpPendingExpiryBars > 0)
     {
      for(int pi = ArraySize(g_pendingTickets)-1; pi >= 0; pi--)
        {
         int barsSincePlaced = iBarShift(_Symbol, PERIOD_CURRENT, g_pendingBarTimes[pi]);
         if(barsSincePlaced >= InpPendingExpiryBars)
           {
            LogTradeExec(StringFormat(
               "Pending expiry: ticket=%I64u %d bars elapsed (limit=%d). Deleting.",
               g_pendingTickets[pi], barsSincePlaced, InpPendingExpiryBars));
            trade_OrderDelete(g_pendingTickets[pi]);
            int rem = ArraySize(g_pendingTickets) - 1;
            for(int k = pi; k < rem; k++)
              { g_pendingTickets[k] = g_pendingTickets[k+1];
                g_pendingBarTimes[k] = g_pendingBarTimes[k+1]; }
            ArrayResize(g_pendingTickets, rem);
            ArrayResize(g_pendingBarTimes, rem);
           }
        }
     }
```

---

## Fix 4 — `[V8-17]` RELOAD-VISUAL-LEAK: CleanupAllTradeObjects before history reload

**Problem:** `OnChartEvent(CHARTEVENT_CHART_CHANGE)` sets `g_needs_reload = true`. The `OnTick()` reload path wipes `g_bars[]` but never calls `CleanupAllTradeObjects()`. All SL/TP lines, entry arrows, exit markers, and signal labels from the prior load remain on the chart indefinitely. On an active chart with frequent timeframe switches, orphaned objects accumulate across every reload.

**Location:** `OnTick()`, the `g_needs_reload` branch.

**Current code:**
```cpp
   if(g_needs_reload)
     { g_needs_reload = false; ReloadHistory(); }
```

**Replace with:**
```cpp
   if(g_needs_reload)
     {
      g_needs_reload = false;
      CleanupAllTradeObjects();   // [V8-17] RELOAD-VISUAL-LEAK: purge stale chart
      ReloadHistory();             //    objects before rebuilding the bar array so
     }                             //    orphaned markers cannot accumulate on reload.
```

> **Note:** Do NOT add `CleanupAllTradeObjects()` to the `g_hasTrades` forced-reload path (the `g_hasTrades = true; g_needs_reload = true;` block above it) — that reload reclassifies tick data on a live session and must not wipe visual annotations for currently-open positions. The `CleanupAllTradeObjects()` call above is only reached via the chart-change path, which is the correct scope.

Actually, the `g_hasTrades` path also sets `g_needs_reload = true` and hits the same branch. To guard against wiping visuals for open positions when reclassifying on `g_hasTrades` transition, change the needs_reload block to:

```cpp
   if(g_needs_reload)
     {
      g_needs_reload = false;
      // Only clean visuals on chart-change reloads, not on g_hasTrades reclassification
      // (open positions may have live SL/TP lines that must survive tick reclassification).
      if(CountOpenPositions() == 0) CleanupAllTradeObjects();  // [V8-17] RELOAD-VISUAL-LEAK
      ReloadHistory();
     }
```

---

## Fix 5 — `[V8-17]` CALCLOT-MARGIN-ORDERTYPE: margin fallback uses direction-correct order type

**Problem:** `CalcLot()`'s margin-fallback path hardcodes `ORDER_TYPE_BUY` regardless of trade direction. On instruments with asymmetric margin (select futures, leveraged CFDs), sell-side margin differs from buy-side. Sell-trade lot sizes in the fallback path are calculated against the wrong margin requirement.

### Step A — Add `isBuy` parameter to `CalcLot()`
Change signature from:
```cpp
double CalcLot(double slDistPoints)
```
To:
```cpp
double CalcLot(double slDistPoints, bool isBuy = true)
```

### Step B — Fix the `OrderCalcMargin` call inside `CalcLot()`
Find:
```cpp
         bool   mok = OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, askPrice, marginFor1Lot);
```
Replace with:
```cpp
         // [V8-17] CALCLOT-MARGIN-ORDERTYPE: use direction-correct order type so sell-side
         //    margin is accurate on instruments where buy/sell margin differs.
         ENUM_ORDER_TYPE margType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         bool   mok = OrderCalcMargin(margType, _Symbol, 1.0, askPrice, marginFor1Lot);
```

### Step C — Update the call site in `PlaceOrders()`
Find:
```cpp
   double lot      = CalcLot(slPoints);   // [V7-01] true risk-based
```
Replace with:
```cpp
   double lot      = CalcLot(slPoints, direction);   // [V7-01] true risk-based; [V8-17] pass direction
```

---

## Changelog entries to prepend (inside the top comment block, before the v8.16 entries)

```
//|  [V8-17] DAYSTART-BALANCE-PERSIST: g_dayStartBalance persisted in GV           |
//|    Not included in RiskStateSave/Load. OnInit() always wrote current balance    |
//|    as the session baseline; after a mid-session restart, daily loss was measured |
//|    from the post-loss restart balance, potentially allowing the full configured   |
//|    daily drawdown on top of losses already incurred. Fix: GVKey("DayStartBal")  |
//|    added to both Save and Load; restore log extended with DayStartBal field.     |
//|                                                                                   |
//|  [V8-17] SIZERED-SL-DECREMENT: penalty counter ticks on all trade closes        |
//|    g_sizeReductionLeft only decremented on win/neutral closes; SL hits left it   |
//|    frozen. A losing streak during the penalty phase extended the half-size        |
//|    penalty indefinitely, violating the "N trades at half-size" contract.          |
//|    Fix: decrement added to the isSLHit branch of OnTradeTransaction().           |
//|                                                                                   |
//|  [V8-17] PENDING-EXPIRY-MULTIPOS: per-order pending expiry tracking             |
//|    Single scalar g_pendingPlacedBarTime was overwritten by each new pending.     |
//|    With InpMaxPositions > 1 and InpCleanOldOrders = false, earlier orders never  |
//|    expired independently. Fix: parallel arrays g_pendingTickets/g_pendingBarTimes|
//|    track per-ticket placement times; expiry loop deletes per-order, not bulk.    |
//|                                                                                   |
//|  [V8-17] RELOAD-VISUAL-LEAK: CleanupAllTradeObjects on chart-change reload      |
//|    g_needs_reload path did not call CleanupAllTradeObjects(), leaving orphaned   |
//|    SL/TP lines, arrows, and labels after every timeframe switch. Fix: cleanup    |
//|    called before ReloadHistory(), guarded by CountOpenPositions()==0 to preserve |
//|    live position annotations during g_hasTrades reclassification reloads.        |
//|                                                                                   |
//|  [V8-17] CALCLOT-MARGIN-ORDERTYPE: direction-correct margin fallback            |
//|    CalcLot() hardcoded ORDER_TYPE_BUY in the margin-fallback path regardless of  |
//|    trade direction. On instruments with asymmetric margin, sell-lot calculations  |
//|    used the wrong requirement. Fix: isBuy parameter added to CalcLot(); call     |
//|    site in PlaceOrders() passes direction; OrderCalcMargin uses correct type.    |
```
