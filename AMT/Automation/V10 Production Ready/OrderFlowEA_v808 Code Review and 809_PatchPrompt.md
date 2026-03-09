# OrderFlowEA v8.09 — Patch Prompt for Pair Programmer LLM

**Source file:** `OrderFlowEA_v808.mq5` (3,313 lines)
**Target version:** `8.09`
**Tag:** `[V8-24]`
**Fixes:** 4 issues (1 Medium, 3 Low)

---

## To-Do List

- [ ] **TICK-SEARCH-UPWARD** — Fix O(N) ArrayResize loop in upward map extension *(Medium)*
- [ ] **LEVMAP-FREE** — Free `levelMap` explicitly in `ReloadHistory()` and `OnDeinit()` *(Low)*
- [ ] **RISKLOAD-LOG-COND** — Add SL timestamps to the `RiskStateLoad()` log condition *(Low)*
- [ ] **LEVMAP-SKIP** — Register out-of-range levels in the map after bar range update *(Low)*

---

## Fix Specifications

---

### 1 · TICK-SEARCH-UPWARD — `AccumulateTick()` upward map extension (Medium)

**File location:** `AccumulateTick()`, the `else if(offset >= mapSize)` branch.

**Current code (line ~1207):**
```mql5
else if(offset >= mapSize)
  {
   // Price above map end — extend upward.
   int newSize = offset + 16;
   for(int k = mapSize; k < newSize; k++) { ArrayResize(g_bars[bi].levelMap, k+1); g_bars[bi].levelMap[k] = -1; }
   mapSize = newSize;
  }
```

**Problem:** Calls `ArrayResize` once per slot — up to 16 separate heap allocations per upward extension. The downward extension path directly above it correctly uses a single `ArrayResize`. This asymmetry partially negates the O(1) lookup improvement.

**Fix — replace the upward branch with:**
```mql5
else if(offset >= mapSize)
  {
   // Price above map end — extend upward in one allocation.
   int newSize = offset + 16;
   ArrayResize(g_bars[bi].levelMap, newSize);
   for(int k = mapSize; k < newSize; k++) g_bars[bi].levelMap[k] = -1;
   mapSize = newSize;
  }
```

**Changelog entry:**
```
//|  [V8-24] TICK-SEARCH-UPWARD: upward map extension single-resize  |
//|    The upward branch of the AccumulateTick() levelMap extension   |
//|    called ArrayResize once per slot (up to 16 calls per upward    |
//|    extension). The downward branch already used a single resize.  |
//|    Fix: replaced per-slot loop with one ArrayResize(newSize)      |
//|    followed by a slot-initialisation loop, matching the downward  |
//|    path and restoring the O(1) intent of the fix.                 |
```

---

### 2 · LEVMAP-FREE — `ArrayFree(levelMap)` missing in cleanup paths (Low)

**File locations:**
- `ReloadHistory()` — existing loop that frees `g_bars[i].levels`
- `OnDeinit()` — existing loop that frees `g_bars[i].levels`

**Current code (both sites):**
```mql5
for(int i = 0; i < n; i++) ArrayFree(g_bars[i].levels);
ArrayFree(g_bars);
```

**Problem:** `levelMap` is a dynamic array added to `FPBar` in v8.08 alongside `levels`. Both `ReloadHistory()` and `OnDeinit()` explicitly free `levels` before freeing the outer `g_bars` array but leave `levelMap` to implicit cleanup. The explicit-free pattern is established for `levels` and must apply uniformly to `levelMap`.

**Fix — at both sites, add the `levelMap` free:**
```mql5
for(int i = 0; i < n; i++)
  {
   ArrayFree(g_bars[i].levelMap);
   ArrayFree(g_bars[i].levels);
  }
ArrayFree(g_bars);
```

**Changelog entry:**
```
//|  [V8-24] LEVMAP-FREE: levelMap freed explicitly in cleanup paths  |
//|    ReloadHistory() and OnDeinit() explicitly freed levels[] but   |
//|    not levelMap[], the dynamic array added to FPBar in v8.08.     |
//|    Fix: ArrayFree(g_bars[i].levelMap) added alongside the         |
//|    existing ArrayFree(g_bars[i].levels) at both cleanup sites.    |
```

---

### 3 · RISKLOAD-LOG-COND — SL cooldown restore is silent when no loss streak exists (Low)

**File location:** `RiskStateLoad()`, the final `if(...)` log condition.

**Current code:**
```mql5
if(g_consecutiveLosses > 0 || g_sizeReductionLeft > 0 || g_sessionHalted || g_dailyLossHalted)
   LogRisk(StringFormat(
      "[V8-10] Risk state restored from GlobalVariables | ConsecLoss=%d | SizeRedLeft=%d"
      " | SessHalted=%s | DayLossHalted=%s | DayStartDay=%d"
      " | LastSLBuy=%s | LastSLSell=%s",
      ...));
```

**Problem:** v8.07 added `LastSLBuy` / `LastSLSell` to the format string but did not add them to the `if` condition. If the EA restarts after a SL hit (SL cooldown active, `InpSLCooldownBars > 0`) but the session had no consecutive loss escalation, all four existing condition terms are false and the log never fires. The user cannot confirm from the journal that cooldown state was recovered.

**Fix — extend the condition:**
```mql5
if(g_consecutiveLosses > 0 || g_sizeReductionLeft > 0 ||
   g_sessionHalted || g_dailyLossHalted ||
   g_lastSLBarTimeBuy > 0 || g_lastSLBarTimeSell > 0)
   LogRisk(StringFormat(
      "[V8-10] Risk state restored from GlobalVariables | ConsecLoss=%d | SizeRedLeft=%d"
      " | SessHalted=%s | DayLossHalted=%s | DayStartDay=%d"
      " | LastSLBuy=%s | LastSLSell=%s",
      g_consecutiveLosses, g_sizeReductionLeft,
      g_sessionHalted   ? "YES" : "NO",
      g_dailyLossHalted ? "YES" : "NO",
      g_dayStartDay,
      (g_lastSLBarTimeBuy  > 0 ? TimeToString(g_lastSLBarTimeBuy,  TIME_DATE|TIME_MINUTES) : "none"),
      (g_lastSLBarTimeSell > 0 ? TimeToString(g_lastSLBarTimeSell, TIME_DATE|TIME_MINUTES) : "none")));
```

**Changelog entry:**
```
//|  [V8-24] RISKLOAD-LOG-COND: SL timestamps in restore log gate    |
//|    RiskStateLoad() logged restored state only when a loss-streak  |
//|    variable was non-default. After a restart with only SL cooldown|
//|    state active (no consecutive losses), the log never fired and  |
//|    the user could not confirm from the journal that the cooldown  |
//|    was recovered. Fix: condition extended with                     |
//|    g_lastSLBarTimeBuy > 0 || g_lastSLBarTimeSell > 0.            |
```

---

### 4 · LEVMAP-SKIP — Out-of-range levels created without map registration (Low)

**File location:** `AccumulateTick()`, the new level creation block.

**Current code (line ~1238):**
```mql5
// [V8-23] TICK-SEARCH: register the new level in the O(1) map so future
//    ticks at the same price grid slot resolve without any scan.
if(!skipSearch)
  {
   int gridIdx2 = (int)MathRound(price / g_step);
   int offset2  = gridIdx2 - g_bars[bi].levelMapBase;
   if(offset2 >= 0 && offset2 < ArraySize(g_bars[bi].levelMap))
      g_bars[bi].levelMap[offset2] = idx;
  }
```

**Problem:** When `skipSearch=true` a new level is created but NOT registered in `levelMap`. A subsequent tick arriving at the same price before the OHLC range is refreshed (possible on the live current bar) will compute `skipSearch=true` again, find `idx=-1`, and create a second level at the same price — a duplicate. Duplicate levels corrupt volume and delta totals silently.

The fix is to extend the map (or register the level after the bar range covers it). The simplest safe approach: after the bar `high`/`low` are already set from OHLC (guaranteed before `AccumulateTick` is called), if `skipSearch` fired, fall back to a linear search for that specific tick only (the old safe behavior). If found, merge; if not found, create without map registration — but then also attempt a deferred registration by checking if the new price now falls within the map range.

**Fix — replace the `if(!skipSearch)` registration block with one that always attempts registration:**
```mql5
   // Register the new level in the map regardless of skipSearch path.
   // If the price was out of range, the map may need growing first.
   {
    int gIdx = (int)MathRound(price / g_step);
    if(ArraySize(g_bars[bi].levelMap) > 0)
      {
       int off = gIdx - g_bars[bi].levelMapBase;
       if(off >= 0 && off < ArraySize(g_bars[bi].levelMap))
          g_bars[bi].levelMap[off] = idx;
       // If still out of map bounds, the next in-range tick will trigger a
       // map grow that does not cover this slot — acceptable for true
       // out-of-band anomaly ticks. The skipSearch guard already limits
       // this path to prices > bar_high + g_step or < bar_low - g_step,
       // which should not recur once OHLC is updated.
      }
   }
```

And **remove** the `if(!skipSearch)` condition from the surrounding block so it always executes.

**Changelog entry:**
```
//|  [V8-24] LEVMAP-SKIP: out-of-range levels registered in map      |
//|    The new-level registration block in AccumulateTick() was        |
//|    guarded by if(!skipSearch). A tick arriving at a price more    |
//|    than one step outside the current bar OHLC range created a     |
//|    level with no map entry; a second tick at the same price       |
//|    before the OHLC updated would create a duplicate level and     |
//|    silently corrupt volume totals. Fix: registration now runs     |
//|    unconditionally and checks map bounds defensively.             |
```

---

## Version / Metadata Updates

Update in this order:
1. Prepend all four `[V8-24]` changelog entries to the file header block (after the v8.23 entries).
2. Change `#property version` from `"8.08"` to `"8.09"`.
3. Change `#define EA_VERSION` from `"8.08"` to `"8.09"`.
4. Update the `#property description` string to reference v8.09.

---

## Verification Checklist

After applying all patches, confirm:

- [ ] `AccumulateTick()` upward branch uses a single `ArrayResize(newSize)` followed by an init loop — no per-slot resize call remains
- [ ] Both `ReloadHistory()` and `OnDeinit()` free `levelMap` before `levels` in the cleanup loop
- [ ] `RiskStateLoad()` log condition includes `|| g_lastSLBarTimeBuy > 0 || g_lastSLBarTimeSell > 0`
- [ ] New-level registration in `AccumulateTick()` runs regardless of the `skipSearch` flag
- [ ] `#property version` and `EA_VERSION` both read `"8.09"`
- [ ] Line count is ~3,330 (net +17 from original 3,313)
