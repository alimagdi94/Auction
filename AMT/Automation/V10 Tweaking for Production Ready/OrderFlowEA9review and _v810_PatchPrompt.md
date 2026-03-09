# OrderFlowEA v8.10 — Patch Prompt for Pair Programmer LLM

**Source file:** `OrderFlowEA_v809.mq5` (3,376 lines)
**Target version:** `8.10`
**Tag:** `[V8-25]`
**Fixes:** 2 issues (1 Critical, 1 Low)

---

## To-Do List

- [ ] **LEVMAP-STALE** — Rebuild `levelMap` after `SortLevels()` in `ComputeBarSignals()` *(Critical)*
- [ ] **EXTEND-OFFSET** — Correct stale `offset` variable after downward map extension *(Low)*

---

## Background: The levelMap

`levelMap[]` was introduced in v8.08 (`TICK-SEARCH`). It maps a grid offset to an index into `levels[]`:
```
levelMap[gridIdx - levelMapBase] → index into g_bars[bi].levels[]
```

`SortLevels()` physically reorders `levels[]` by price. After the sort, every `levelMap` entry that pointed to a pre-sort index now points to a **different level**. `AccumulateTick()` has no linear-scan fallback — it trusts the map value directly. Any tick arriving on a sorted bar reads a stale index and accumulates volume into the **wrong price level**.

---

## Fix Specifications

---

### 1 · LEVMAP-STALE — levelMap corrupted by SortLevels (Critical)

**Root cause:** `ComputeBarSignals()` calls `SortLevels(g_bars[bi].levels, len)` at line ~1511, which rearranges `levels[]` in-place by price. `levelMap[]` is not updated. On the next `AccumulateTick()` call for the same bar:

```
idx = levelMap[offset]         // stale: points to pre-sort position
levels[idx].ask_vol += vol     // WRONG level gets the volume
```

**When this fires:**

1. **History load path:** `ReloadHistory()` → `LoadHistory()` → `ProcessTicks()` fills all history bars. Then `ComputeNakedPOCs()` calls `ComputeBarSignals()` on every bar (line ~1735), sorting them all. The **last** history bar is the same bar as the live current bar. Its map is now stale. The very next live tick corrupts it.

2. **Live tick path:** `EvalAndFireSignal()` calls `ComputeBarSignals(bi)` on `bi = nBars-1` (the live bar) at line ~2281. Any tick that arrives after that call and before the bar closes writes to the wrong level.

**Fix — add a `RebuildLevelMap()` helper and call it from `ComputeBarSignals()` after `SortLevels()`:**

Add this function. Place it directly above `ComputeBarSignals()`:

```mql5
// [V8-25] LEVMAP-STALE: rebuild the O(1) price→level map after SortLevels().
//    SortLevels physically reorders levels[] by price; any pre-sort levelMap
//    entry now points to the wrong levels[] slot. Called from ComputeBarSignals()
//    immediately after every SortLevels() call so AccumulateTick() sees a
//    consistent map on the next live tick for the same bar.
void RebuildLevelMap(int bi)
  {
   int len = g_bars[bi].level_count;
   int ms  = ArraySize(g_bars[bi].levelMap);

   // Clear all existing entries.
   for(int k = 0; k < ms; k++) g_bars[bi].levelMap[k] = -1;

   // Re-register every level at its correct grid offset.
   for(int i = 0; i < len; i++)
     {
      int gIdx = (int)MathRound(g_bars[bi].levels[i].price / g_step);
      int off  = gIdx - g_bars[bi].levelMapBase;
      if(off >= 0 && off < ms)
         g_bars[bi].levelMap[off] = i;
     }
  }
```

Then in `ComputeBarSignals()`, call it immediately after `SortLevels()`:

```mql5
// Current code:
if(!g_bars[bi].sorted)
  { SortLevels(g_bars[bi].levels, len); g_bars[bi].sorted = true; }

// Replace with:
if(!g_bars[bi].sorted)
  {
   SortLevels(g_bars[bi].levels, len);
   RebuildLevelMap(bi);   // [V8-25] LEVMAP-STALE: re-sync map after sort reorders levels[]
   g_bars[bi].sorted = true;
  }
```

**Changelog entry:**
```
//|  [V8-25] LEVMAP-STALE: levelMap rebuilt after SortLevels()       |
//|    SortLevels() physically reorders levels[] by price. The v8.08  |
//|    levelMap (price→levels[] index) was not updated after the sort,|
//|    leaving stale indices. Any tick arriving on the same bar after  |
//|    ComputeBarSignals() would write volume to the wrong price level,|
//|    silently corrupting footprint data. This affects the live bar   |
//|    on every tick after a signal evaluation and the last history    |
//|    bar after ReloadHistory(). Fix: new RebuildLevelMap(bi) helper |
//|    clears and re-registers all levels at their sorted positions;  |
//|    called from ComputeBarSignals() immediately after SortLevels(). |
```

---

### 2 · EXTEND-OFFSET — Stale `offset` variable after downward map extension (Low)

**File location:** `AccumulateTick()`, the downward extension branch.

**Current code:**
```mql5
if(offset < 0)
  {
   // Price below map start — extend downward.
   int extend  = (-offset) + 16;
   int oldSize = mapSize;
   int newSize = oldSize + extend;
   ArrayResize(g_bars[bi].levelMap, newSize);
   for(int k = oldSize - 1; k >= 0; k--)
      g_bars[bi].levelMap[k + extend] = g_bars[bi].levelMap[k];
   for(int k = 0; k < extend; k++) g_bars[bi].levelMap[k] = -1;
   g_bars[bi].levelMapBase -= extend;
   offset   = 0;   // ← WRONG: correct new offset is (-offset_original + 16 - 1) ... see below
   mapSize  = newSize;
  }
```

**Problem:** After the extension, `levelMapBase` is decremented by `extend`. The correct new offset for the triggering price is:
```
new_offset = gridIdx - new_levelMapBase
           = gridIdx - (old_base - extend)
           = (gridIdx - old_base) + extend
           = offset_original + extend        ← not 0
```

`offset_original` is negative (e.g. `-3`), `extend = 3 + 16 = 19`, so correct new offset = `16`.  
Code sets it to `0`.

**Why currently benign:** The code sets all slots `0..extend-1` to `-1` just before. So `levelMap[0] == -1`, `levelMap[16] == -1` — both are empty. The lookup reads `-1` either way, falls through to new-level creation, and the registration block recomputes offset correctly from `gIdx`. So the final state is identical. The bug is latent, not active.

**Fix — replace `offset = 0` with the correct recalculation:**
```mql5
g_bars[bi].levelMapBase -= extend;
offset  = gridIdx - g_bars[bi].levelMapBase;   // [V8-25] EXTEND-OFFSET: recalc after base shift
mapSize = newSize;
```

**Changelog entry:**
```
//|  [V8-25] EXTEND-OFFSET: offset recalculated after downward extend |
//|    After a downward levelMap extension, offset was set to 0 rather |
//|    than recalculated against the updated levelMapBase. Currently   |
//|    benign (slot 0 is always -1 after extend so the lookup falls   |
//|    through to new-level creation, and registration uses a fresh   |
//|    gIdx computation), but the stale variable is incorrect and      |
//|    creates a subtle maintenance hazard. Fix: offset recomputed as  |
//|    gridIdx - g_bars[bi].levelMapBase after the base is updated.   |
```

---

## Version / Metadata Updates

Apply in this order:
1. Prepend both `[V8-25]` changelog entries to the file header (after the v8.24 block).
2. Change `#property version` from `"8.09"` to `"8.10"`.
3. Change `#define EA_VERSION` from `"8.09"` to `"8.10"`.
4. Update `#property description` to reference v8.10.

---

## Verification Checklist

- [ ] `RebuildLevelMap(int bi)` exists, placed directly above `ComputeBarSignals()`
- [ ] `ComputeBarSignals()` calls `RebuildLevelMap(bi)` between `SortLevels()` and `g_bars[bi].sorted = true`
- [ ] Downward extension branch sets `offset = gridIdx - g_bars[bi].levelMapBase` (not `offset = 0`)
- [ ] No other call site of `SortLevels()` exists without a matching `RebuildLevelMap()` call
- [ ] `#property version` and `EA_VERSION` both read `"8.10"`
- [ ] Line count is approximately 3,400 (+24 from 3,376)
