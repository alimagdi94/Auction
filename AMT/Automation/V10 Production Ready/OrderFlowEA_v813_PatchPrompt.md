# OrderFlowEA v8.13 — Patch Prompt for Pair Programmer LLM

**Source file:** `OrderFlowEA_v812.mq5` (3,534 lines)
**Target version:** `8.13`
**Tag:** `[V8-28]`
**Fixes:** 2 issues — both in `ManagePositions()` and `OnInit()`

---

## To-Do List

- [ ] **MANAGE-SLEEP** — Replace `Sleep(200)` in `ManagePositions()` SL-modify retry with spin-wait *(Low)*
- [ ] **TRAIL-VALIDATE** — Add `OnInit()` bounds checks for trailing stop and break-even parameters *(Low)*

---

## Background

Both issues are continuations of work done in v8.12 (`[V8-27]`). `RETCODE-SLEEP` targeted the `trade_Send()` retry loop but the identical `Sleep(200)` pattern in `ManagePositions()` was not included in the patch spec. `TRAIL-VALIDATE` extends the existing `OnInit()` validation suite to cover the four position-management parameters that have no bounds check.

---

## Fix Specifications

---

### 1 · MANAGE-SLEEP — Sleep(200) in ManagePositions SL-modify retry (Low)

**Location:** `ManagePositions()`, the `TRADE_ACTION_SLTP` retry loop, ~line 3129.

**Problem:** The `trade_Send()` `Sleep(200)` was replaced in v8.12 (`[V8-27] RETCODE-SLEEP`). The same pattern exists in `ManagePositions()` for SL modification retries and was not included in that patch:

```mql5
for(int attempt = 1; attempt <= 3 && !modOk; attempt++)
  {
   modOk = OrderSend(req, res);
   if(!modOk)
     {
      uint rc = res.retcode;
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_CONNECTION &&
         rc != TRADE_RETCODE_TIMEOUT) break;
      Sleep(200);   // ← same problem as V8-27 — blocks tick thread up to 400 ms
     }
  }
```

`ManagePositions()` runs on every tick (subject to the 250 ms `FP_MANAGE_THROTTLE`). A failed SL modification during a fast market causes up to 400 ms of blocking. Combined with the throttle, the next `ManagePositions()` call can arrive 450 ms late — exactly when trailing stop updates are most time-critical.

**Fix — replace `Sleep(200)` with the same 50 ms spin-wait used in `trade_Send()`:**

```mql5
for(int attempt = 1; attempt <= 3 && !modOk; attempt++)
  {
   modOk = OrderSend(req, res);
   if(!modOk)
     {
      uint rc = res.retcode;
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_CONNECTION &&
         rc != TRADE_RETCODE_TIMEOUT) break;
      // [V8-28] MANAGE-SLEEP: replaced Sleep(200) with 50 ms spin-wait, consistent
      //    with [V8-27] RETCODE-SLEEP in trade_Send(). Sleep() blocks the tick thread;
      //    a 400 ms pause on a trailing-stop modify during a fast market is the worst
      //    possible time to freeze ManagePositions().
      ulong spinStart = GetTickCount64();
      while(GetTickCount64() - spinStart < 50) { /* spin */ }
     }
  }
```

**Changelog entry:**
```
//|  [V8-28] MANAGE-SLEEP: Sleep(200) in ManagePositions replaced     |
//|    The SL-modify retry in ManagePositions() used Sleep(200) —     |
//|    the same blocking pattern fixed in trade_Send() by [V8-27].    |
//|    Up to 400 ms of tick-thread blocking during a trailing-stop    |
//|    retry on a fast market defeats the purpose of position mgmt.   |
//|    Fix: replaced with a GetTickCount64() spin-wait capped at 50ms.|
```

---

### 2 · TRAIL-VALIDATE — Missing OnInit() bounds checks for position management params (Low)

**Location:** `OnInit()` input-validation block (~line 3200), guarded by `if(InpATEnable)`.

**Problem:** The existing validation suite covers SL/TP construction, lot sizing, and risk percentages when `InpATEnable` is true, but four position-management parameters have no validation:

| Parameter | Default | Risk if zero/negative |
|---|---|---|
| `InpBreakEvenTrigger` | 15.0 pips | `InpUseBreakEven=true` with trigger=0 activates BE on every tick from the first profit pip |
| `InpBreakEvenBuffer` | 2.0 pips | Zero is technically valid (BE at exact entry); negative sets SL on wrong side of entry |
| `InpTrailStep` | 5.0 pips | Zero means trailSL = curBid − 0 (for buys) = current price; SL moves to current price every tick, guaranteeing an immediate stop-out |
| `InpTrailStart` | 20.0 pips | Zero activates trailing immediately from first tick, ignoring intended activation threshold |

**Fix — add four validation checks inside the `if(InpATEnable)` block**, after the existing SL/TP validation and before the lot validation:

```mql5
// [V8-28] TRAIL-VALIDATE: validate position management params when AT is enabled.
//    Zero or negative trailing step causes trailSL = curBid (buys) on every tick —
//    instant stop-out. Negative BE buffer places the stop on the wrong side of entry.
if(InpUseBreakEven)
  {
   if(InpBreakEvenTrigger <= 0.0)
     { Alert("InpBreakEvenTrigger must be > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpBreakEvenBuffer < 0.0)
     { Alert("InpBreakEvenBuffer must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
  }
if(InpUseTrailing)
  {
   if(InpTrailStep <= 0.0)
     { Alert("InpTrailStep must be > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailStart < 0.0)
     { Alert("InpTrailStart must be >= 0."); return INIT_PARAMETERS_INCORRECT; }
  }
```

**Changelog entry:**
```
//|  [V8-28] TRAIL-VALIDATE: OnInit() bounds for trail/BE parameters  |
//|    InpTrailStep, InpTrailStart, InpBreakEvenTrigger, and           |
//|    InpBreakEvenBuffer had no OnInit() validation. InpTrailStep=0  |
//|    causes trailSL=curBid on every tick (instant stop-out).        |
//|    Negative InpBreakEvenBuffer places BE stop on the wrong side.  |
//|    All four are now validated inside the if(InpATEnable) block,   |
//|    consistent with the existing SL/TP validation pattern.         |
```

---

## Version / Metadata Updates

Apply in this order:
1. Prepend both `[V8-28]` changelog entries to the file header (after the v8.27 block).
2. Change `#property version` from `"8.12"` to `"8.13"`.
3. Change `#define EA_VERSION` from `"8.12"` to `"8.13"`.
4. Update `#property description` to reference v8.13.

---

## Verification Checklist

- [ ] `Sleep(200)` is gone from `ManagePositions()`; spin-wait uses `GetTickCount64()` capped at 50 ms
- [ ] `Sleep(200)` does **not** reappear anywhere else in the file (`grep -n "Sleep(" ` returns zero results)
- [ ] `OnInit()` `if(InpATEnable)` block contains four new checks: `InpBreakEvenTrigger > 0`, `InpBreakEvenBuffer >= 0`, `InpTrailStep > 0`, `InpTrailStart >= 0` — each guarded by the relevant `InpUseBreakEven` / `InpUseTrailing` flag
- [ ] Both new validation checks use `return INIT_PARAMETERS_INCORRECT` (not `INIT_FAILED`)
- [ ] `#property version` and `EA_VERSION` both read `"8.13"`
- [ ] Line count is approximately 3,548 (+14 from 3,534)
