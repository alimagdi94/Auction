# OrderFlowEA v8.12 — Patch Prompt for Pair Programmer LLM

**Source file:** `OrderFlowEA_v811.mq5` (3,478 lines)
**Target version:** `8.12`
**Tag:** `[V8-27]`
**Fixes:** 3 issues — all in `trade_Send()`

---

## To-Do List

- [ ] **SLTP-LOG-CLAMP** — Log the clamped SL/TP values in `PlaceOrders()` success path *(Medium)*
- [ ] **EQUITY-INPUT-VALIDATE** — Add `OnInit()` bounds check for `InpMaxEquityProfit` / `InpMaxEquityLoss` *(Low)*
- [ ] **RETCODE-SLEEP** — Replace blocking `Sleep(200)` retry with `GetTickCount64()` spin-guard *(Low)*

---

## Background

All three issues are in or directly related to `trade_Send()` in Section 14. They were not introduced by v8.11 — they pre-date the equity-halt work — but become more visible now that the trade-send path is under review.

---

## Fix Specifications

---

### 1 · SLTP-LOG-CLAMP — Success log records pre-clamp SL/TP values (Medium)

**Location:** `trade_Send()` lines ~2798–2805 and `PlaceOrders()` lines ~2975–2981.

**Problem:** `trade_Send()` silently adjusts `req.sl` / `req.tp` when the broker's minimum distance (`stopsLevel`) would be violated:

```mql5
if(sl > 0.0 && MathAbs(refPrice - sl) < minDist)
   req.sl = NormalizeDouble(...);   // clamped — no log
if(tp > 0.0 && MathAbs(refPrice - tp) < minDist)
   req.tp = NormalizeDouble(...);   // clamped — no log
```

`trade_Send()` returns the `outTicket` but does not tell the caller what values were actually sent. `PlaceOrders()` then logs using the **original** `sl` / `tp` variables passed in:

```mql5
// PlaceOrders ~line 2980 — logs UNCLAMPED values:
LogTradeExec(StringFormat(
   "ORDER PLACED ... | SL: %s | TP: %s ...",
   DoubleToString(sl, _Digits),     // ← pre-clamp
   DoubleToString(tp, _Digits),     // ← pre-clamp
   ...));
```

The FAILED path already logs `req.sl` / `req.tp` (clamped). Only the success path is wrong.
**Production risk:** Journal says `SL=1.08500` but the live order's stop is at `1.08480`. Any audit or post-trade analysis will compare against wrong values.

**Fix — pass actual values back through output parameters and log them:**

**Step 1:** Change `trade_Send()` signature to expose final SL/TP:

```mql5
// Current:
bool trade_Send(ENUM_TRADE_REQUEST_ACTIONS action,
                ENUM_ORDER_TYPE            orderType,
                double price, double sl, double tp, double lot,
                string comment, ulong &outTicket)

// Replace with:
bool trade_Send(ENUM_TRADE_REQUEST_ACTIONS action,
                ENUM_ORDER_TYPE            orderType,
                double price, double sl, double tp, double lot,
                string comment, ulong &outTicket,
                double &outSL, double &outTP)   // [V8-27] SLTP-LOG-CLAMP: actual sent values
```

**Step 2:** Inside `trade_Send()`, initialise the output params before the clamp block:

```mql5
outSL = sl;   // [V8-27] will be updated if clamped below
outTP = tp;

if(sl > 0.0 && MathAbs(refPrice - sl) < minDist)
  {
   req.sl = NormalizeDouble(
      (orderType==ORDER_TYPE_BUY_STOP || orderType==ORDER_TYPE_BUY)
      ? refPrice - minDist : refPrice + minDist, _Digits);
   outSL = req.sl;   // [V8-27] record clamped value
   LogWarning(StringFormat("SLTP-CLAMP: SL adjusted %.5f → %.5f (minDist=%.5f)",
                           sl, req.sl, minDist));  // [V8-27]
  }
if(tp > 0.0 && MathAbs(refPrice - tp) < minDist)
  {
   req.tp = NormalizeDouble(
      (orderType==ORDER_TYPE_BUY_STOP || orderType==ORDER_TYPE_BUY)
      ? refPrice + minDist : refPrice - minDist, _Digits);
   outTP = req.tp;   // [V8-27] record clamped value
   LogWarning(StringFormat("SLTP-CLAMP: TP adjusted %.5f → %.5f (minDist=%.5f)",
                           tp, req.tp, minDist));  // [V8-27]
  }
```

**Step 3:** Update the **one call site** of `trade_Send()` in `PlaceOrders()`:

```mql5
// Current:
ulong ticket = 0;
bool  sent   = false;
...
sent = trade_Send(action, orderType, entry, sl, tp, lot, tag, ticket);
if(sent)
  {
   ...
   LogTradeExec(StringFormat(
      "ORDER PLACED [%s] %s | #%I64u | Entry: %s | SL: %s | TP: %s ...",
      ...
      DoubleToString(sl, _Digits),
      DoubleToString(tp, _Digits),
      ...));

// Replace the call and log with:
ulong  ticket = 0;
bool   sent   = false;
double sentSL = sl, sentTP = tp;   // [V8-27] SLTP-LOG-CLAMP: will hold actual sent values
...
sent = trade_Send(action, orderType, entry, sl, tp, lot, tag, ticket, sentSL, sentTP);
if(sent)
  {
   ...
   LogTradeExec(StringFormat(
      "ORDER PLACED [%s] %s | #%I64u | Entry: %s | SL: %s | TP: %s ...",
      ...
      DoubleToString(sentSL, _Digits),   // [V8-27] actual sent value
      DoubleToString(sentTP, _Digits),   // [V8-27] actual sent value
      ...));
```

**Changelog entry:**
```
//|  [V8-27] SLTP-LOG-CLAMP: PlaceOrders logs actual sent SL/TP      |
//|    trade_Send() may clamp SL/TP to broker minDist. The success    |
//|    log in PlaceOrders used the pre-clamp sl/tp variables, so the  |
//|    journal recorded different values than the live order. Fix:    |
//|    trade_Send() gains outSL/outTP output params; PlaceOrders logs |
//|    sentSL/sentTP; LogWarning fired on each clamp event.           |
```

---

### 2 · EQUITY-INPUT-VALIDATE — No OnInit check for equity halt thresholds (Low)

**Location:** `OnInit()` input-validation block (~line 3107), `input` declarations (~line 590).

**Problem:** All other monetary and threshold inputs have explicit `OnInit()` validation. `InpMaxEquityProfit` and `InpMaxEquityLoss` do not. Negative values are silently treated as "disabled" (the `> 0.0` guard at the call site skips them), but there is no error or warning to the trader, which could mask a data-entry mistake (e.g. typing `-3000` instead of `3000`).

**Fix — add two validation lines to the `OnInit()` input-validation block**, after the `InpHaltConsecLosses` ordering check:

```mql5
// [V8-27] EQUITY-INPUT-VALIDATE: negative values are silently treated as disabled
//    (the > 0.0 guard at the call site skips them), but a negative entry is
//    almost certainly a user error. Warn explicitly; use 0 for "disabled".
if(InpMaxEquityProfit < 0.0)
  { Alert("InpMaxEquityProfit must be >= 0 (0 = disabled)."); return INIT_PARAMETERS_INCORRECT; }
if(InpMaxEquityLoss < 0.0)
  { Alert("InpMaxEquityLoss must be >= 0 (0 = disabled)."); return INIT_PARAMETERS_INCORRECT; }
```

**Changelog entry:**
```
//|  [V8-27] EQUITY-INPUT-VALIDATE: bounds check for equity thresholds|
//|    InpMaxEquityProfit and InpMaxEquityLoss had no OnInit()         |
//|    validation. Negative values were silently ignored (> 0.0 guard)|
//|    but likely represent data-entry errors. Both now require >= 0  |
//|    (0 = disabled) with INIT_PARAMETERS_INCORRECT on violation.    |
```

---

### 3 · RETCODE-SLEEP — Blocking Sleep(200) in trade retry loop (Low)

**Location:** `trade_Send()` retry loop (~line 2808).

**Problem:** MQL5's `OnTick()` is single-threaded. `Sleep(200)` blocks the entire EA for up to 400 ms across two retries. During this window `ManagePositions()` cannot adjust trailing stops or break-even levels. On a fast-moving market during a news spike — exactly when requotes are most likely — this delay can be significant.

**Current code:**
```mql5
bool ok = false;
for(int attempt = 1; attempt <= 3; attempt++)
  {
   if(attempt > 1 && action == TRADE_ACTION_DEAL)
     {
      if(SymbolInfoTick(_Symbol, lastTick))
        {
         if(orderType == ORDER_TYPE_BUY)  req.price = NormalizeDouble(lastTick.ask, _Digits);
         else if(orderType == ORDER_TYPE_SELL) req.price = NormalizeDouble(lastTick.bid, _Digits);
        }
     }
   ok = OrderSend(req, res);
   if(ok) break;
   uint rc = res.retcode;
   if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
      rc != TRADE_RETCODE_CONNECTION && rc != TRADE_RETCODE_TIMEOUT) break;
   Sleep(200);   // ← blocks tick thread up to 400 ms total
  }
```

**Fix — replace `Sleep(200)` with a tight `GetTickCount64()` spin-wait, capped at 50 ms:**

```mql5
bool ok = false;
for(int attempt = 1; attempt <= 3; attempt++)
  {
   if(attempt > 1 && action == TRADE_ACTION_DEAL)
     {
      if(SymbolInfoTick(_Symbol, lastTick))
        {
         if(orderType == ORDER_TYPE_BUY)  req.price = NormalizeDouble(lastTick.ask, _Digits);
         else if(orderType == ORDER_TYPE_SELL) req.price = NormalizeDouble(lastTick.bid, _Digits);
        }
     }
   ok = OrderSend(req, res);
   if(ok) break;
   uint rc = res.retcode;
   if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
      rc != TRADE_RETCODE_CONNECTION && rc != TRADE_RETCODE_TIMEOUT) break;
   // [V8-27] RETCODE-SLEEP: replaced Sleep(200) with a 50 ms spin-wait.
   //    Sleep() blocks the entire EA tick thread; a 400 ms total pause during
   //    a requote (which happens during fast markets) prevents ManagePositions()
   //    from updating trailing stops. 50 ms is sufficient for a price refresh
   //    without materially delaying position management.
   ulong spinStart = GetTickCount64();
   while(GetTickCount64() - spinStart < 50) { /* yield */ }
  }
```

**Changelog entry:**
```
//|  [V8-27] RETCODE-SLEEP: Sleep(200) replaced with 50ms spin-wait  |
//|    The retry loop in trade_Send() called Sleep(200) on requote /  |
//|    price_changed retcodes, blocking the tick thread for up to     |
//|    400 ms. During that window ManagePositions() cannot fire,      |
//|    delaying break-even and trailing stops on open positions during |
//|    the exact conditions (news, fast markets) that cause requotes. |
//|    Fix: replaced with a GetTickCount64() spin-wait capped at 50ms.|
```

---

## Version / Metadata Updates

Apply in this order:
1. Prepend all three `[V8-27]` changelog entries to the file header (after the v8.26 block).
2. Change `#property version` from `"8.11"` to `"8.12"`.
3. Change `#define EA_VERSION` from `"8.11"` to `"8.12"`.
4. Update `#property description` to reference v8.12.

---

## Verification Checklist

- [ ] `trade_Send()` signature has two new trailing `double &outSL, double &outTP` parameters
- [ ] `outSL` and `outTP` are initialised to `sl` / `tp` at the top of `trade_Send()` before the clamp block
- [ ] Both clamp branches assign to `outSL` / `outTP` AND call `LogWarning()`
- [ ] The one call site in `PlaceOrders()` declares `sentSL` / `sentTP`, passes them to `trade_Send()`, and logs them in the success path
- [ ] `OnInit()` validation block contains `InpMaxEquityProfit < 0.0` and `InpMaxEquityLoss < 0.0` checks with `INIT_PARAMETERS_INCORRECT`
- [ ] `Sleep(200)` is gone from `trade_Send()`; spin-wait uses `GetTickCount64()` with 50 ms cap
- [ ] `#property version` and `EA_VERSION` both read `"8.12"`
- [ ] Line count is approximately 3,500 (+22 from 3,478)
