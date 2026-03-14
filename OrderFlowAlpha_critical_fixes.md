# OrderFlowAlpha v5.32 — Critical Production Fixes

Two fixes only. Apply both before enabling `InpATEnable = true` on any live account.

---

## Fix 1 — HTF indicator handle leak `CheckHTFTrend()` *(stability bug)*

### What is broken
`CheckHTFTrend()` calls `iMA()` on **every tick**, creates a local handle, reads one
value, then calls `IndicatorRelease()`. This runs thousands of times per session.
A persistent global `g_htfEMAHandle` already exists and `OnDeinit()` already releases
it — but `CheckHTFTrend()` never uses it. The global is wired to nothing.

### Change 1 of 2 — `OnInit()`, after the ATR handle block (~line 4222)

Add this block immediately after:
```mq5
g_handleATR = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
```

```mq5
// Initialise persistent HTF EMA handle once — reused by CheckHTFTrend() every tick
if(InpHTFEnable && InpHTFEMA >= 2)
  {
   g_htfEMAHandle = iMA(_Symbol, InpHTFPeriod, InpHTFEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_htfEMAHandle == INVALID_HANDLE)
      Print("Footprint EA — Warning: HTF EMA handle could not be created (", GetLastError(), ").");
  }
```

### Change 2 of 2 — Replace the entire `CheckHTFTrend()` function body (~line 3615)

```mq5
bool CheckHTFTrend(bool isBuy)
  {
   if(!InpHTFEnable) return true;
   if(InpHTFEMA < 2) return true;

   // Use the persistent handle created in OnInit — never create/release per tick
   if(g_htfEMAHandle == INVALID_HANDLE) return true;

   double buf[];
   if(CopyBuffer(g_htfEMAHandle, 0, 0, 1, buf) != 1) return true;
   if(buf[0] <= 0.0) return true;

   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return isBuy ? (px >= buf[0]) : (px <= buf[0]);
  }
```

`OnDeinit()` already releases `g_htfEMAHandle` correctly — no change needed there.

---

## Fix 2 — Market order slippage at bar close *(P&L impact on every trade)*

### What is broken
`PlaceOrders()` evaluates the last closed bar then fires a **market order immediately**.
The fill price is the current Ask/Bid — not the signal bar's close. On a volatile pair
this is routinely 3–10 pips worse than the signal level, compounding across hundreds
of trades.`ORDER_MODE_PENDING` already exists in the codebase and avoids this entirely
by placing a BuyStop/SellStop at the bar's high/low + buffer, filling only if price
continues in the signal direction.

### Change 1 of 2 — Change the default order mode (~line 142)

```mq5
// Change:
input ENUM_ORDER_MODE InpOrderMode = ORDER_MODE_MARKET;

// To:
input ENUM_ORDER_MODE InpOrderMode = ORDER_MODE_PENDING;
```

### Change 2 of 2 — Add a pending entry distance guard in `PlaceOrders()`, after the pending `entry` price is calculated (~line 3840)

Prevents placing a stop so far from current price it would never fill cleanly:

```mq5
// Add immediately after entry price is set for pending mode:
if(!isMarket)
  {
   double currentPx = direction ? lv.ask : lv.bid;
   double entryDistPips = MathAbs(entry - currentPx) / g_Pip;
   double maxPips = InpBufferPips + 10.0;
   if(entryDistPips > maxPips)
     {
      LogTradeExec(StringFormat(
         "PlaceOrders: pending entry %.1f pips from price exceeds %.1f pip tolerance — skip.",
         entryDistPips, maxPips));
      return;
     }
  }
