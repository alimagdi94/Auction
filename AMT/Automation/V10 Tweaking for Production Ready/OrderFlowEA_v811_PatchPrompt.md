# OrderFlowEA v8.11 — Patch Prompt for Pair Programmer LLM

**Source file:** `OrderFlowEA_v810.mq5` (3,423 lines)
**Target version:** `8.11`
**Tag:** `[V8-26]`
**Fixes:** 3 issues (1 Medium, 2 Low) — all in `CheckRiskConditions()` equity guards

---

## To-Do List

- [ ] **EQUITY-HALT-PERSIST** — Persist equity-halt state to GlobalVariables; restore on init *(Medium)*
- [ ] **EQUITY-HALT-MANAGE** — Keep `ManagePositions()` running after an equity halt *(Low)*
- [ ] **EQUITY-HALT-ALERT** — Fire `Alert()` on equity halt, consistent with other halt types *(Low)*

---

## Background

`CheckRiskConditions()` contains two equity guards introduced earlier in the codebase:

```mql5
if(InpMaxEquityProfit > 0.0 && equity >= balance + InpMaxEquityProfit)
  { LogWarning("MaxEquityProfit reached. Auto-trading halted."); g_autoTrade = false; return false; }

if(InpMaxEquityLoss > 0.0 && equity <= balance - InpMaxEquityLoss)
  { LogWarning("MaxEquityLoss hit. Auto-trading halted.");       g_autoTrade = false; return false; }
```

Three separate problems exist with this implementation, described below.

---

## Fix Specifications

---

### 1 · EQUITY-HALT-PERSIST — Equity halt not saved across restarts (Medium)

**Problem:** Both guards set `g_autoTrade = false` when triggered. `OnInit()` unconditionally resets it:
```mql5
g_autoTrade = InpATEnable;   // line ~3159 — always restores to true when ATEnable=true
```
`RiskStateSave()` and `RiskStateLoad()` have no entry for this flag. An EA restart, VPS reboot, or terminal reconnect during an active equity halt silently re-enables trading — the exact event the halt was designed to prevent.

**Fix — introduce a dedicated `g_equityHalted` boolean, persist it like the other halt flags:**

**Step 1:** Add the global variable after the existing halt flags (near line ~704):
```mql5
bool g_equityHalted = false;   // [V8-26] EQUITY-HALT-PERSIST: set by equity guards; persisted in GV
```

**Step 2:** In `RiskStateSave()`, add after the last `GlobalVariableSet` line:
```mql5
// [V8-26] EQUITY-HALT-PERSIST: persist equity halt so a restart cannot silently re-enable trading.
GlobalVariableSet(GVKey("EquityHalted"), g_equityHalted ? 1.0 : 0.0);
```

**Step 3:** In `RiskStateLoad()`, add after the `NewDayDefer` restore block and before the log condition:
```mql5
// [V8-26] EQUITY-HALT-PERSIST: restore equity halt state.
if(GlobalVariableCheck(GVKey("EquityHalted")))
   g_equityHalted = (GlobalVariableGet(GVKey("EquityHalted")) != 0.0);
```

**Step 4:** Extend the `RiskStateLoad()` log condition to include the new flag:
```mql5
if(g_consecutiveLosses > 0 || g_sizeReductionLeft > 0 ||
   g_sessionHalted || g_dailyLossHalted || g_equityHalted ||
   g_lastSLBarTimeBuy > 0 || g_lastSLBarTimeSell > 0)
```
And add `| EquityHalted=%s` to the format string with `g_equityHalted ? "YES" : "NO"`.

**Step 5:** In `OnInit()`, zero it before `RiskStateLoad()`:
```mql5
g_equityHalted = false;
RiskStateLoad();   // overwrite zeros with persisted values if present
```

**Step 6:** Replace the equity guard bodies in `CheckRiskConditions()`:
```mql5
// Replace:
if(InpMaxEquityProfit > 0.0 && equity >= balance + InpMaxEquityProfit)
  { LogWarning("MaxEquityProfit reached. Auto-trading halted."); g_autoTrade = false; return false; }

if(InpMaxEquityLoss > 0.0 && equity <= balance - InpMaxEquityLoss)
  { LogWarning("MaxEquityLoss hit. Auto-trading halted.");       g_autoTrade = false; return false; }

// With:
if(!g_equityHalted && InpMaxEquityProfit > 0.0 && equity >= balance + InpMaxEquityProfit)
  {
   g_equityHalted = true;
   RiskStateSave();
   Alert(EA_NAME " — EQUITY PROFIT TARGET HIT (+" + DoubleToString(InpMaxEquityProfit, 2)
         + "). Auto-trading halted. [V8-26]");
   LogRisk(StringFormat("EQUITY PROFIT HALT: equity=%.2f balance=%.2f threshold=+%.2f",
                        equity, balance, InpMaxEquityProfit));
  }
if(!g_equityHalted && InpMaxEquityLoss > 0.0 && equity <= balance - InpMaxEquityLoss)
  {
   g_equityHalted = true;
   RiskStateSave();
   Alert(EA_NAME " — EQUITY LOSS LIMIT HIT (-" + DoubleToString(InpMaxEquityLoss, 2)
         + "). Auto-trading halted. [V8-26]");
   LogRisk(StringFormat("EQUITY LOSS HALT: equity=%.2f balance=%.2f threshold=-%.2f",
                        equity, balance, InpMaxEquityLoss));
  }
if(g_equityHalted)
  {
   LogRisk("Equity halt active. No new entries.");
   return false;
  }
```

**Note:** Do NOT remove `g_autoTrade = false` from the old guards until after the new `g_equityHalted` is in place. Once `g_equityHalted` gates `CheckRiskConditions()`, the `g_autoTrade = false` lines must be **removed** since the new design gates only new entries (not ManagePositions — see fix 2).

**Changelog entry:**
```
//|  [V8-26] EQUITY-HALT-PERSIST: equity halt state persisted to GV  |
//|    The equity profit/loss guards set g_autoTrade=false but never  |
//|    called RiskStateSave(). OnInit() always resets g_autoTrade=    |
//|    InpATEnable, so any restart silently re-enabled trading during |
//|    an active halt. Fix: dedicated g_equityHalted flag added to    |
//|    RiskStateSave/Load using the established GVKey pattern.        |
```

---

### 2 · EQUITY-HALT-MANAGE — Equity halt stops ManagePositions (Low)

**Problem:** The old equity guard set `g_autoTrade = false`. `ManagePositions()` guards on this flag:
```mql5
void ManagePositions()
  {
   if(!g_autoTrade) return;   // ← returns immediately after equity halt
```

This stops break-even moves and trailing stops on **already-open positions** when an equity halt fires — the opposite of the intended protection. The other halt types (`g_dailyLossHalted`, `g_sessionHalted`) only gate `CheckRiskConditions()` and do not affect position management.

**Fix:** Once `g_equityHalted` replaces the `g_autoTrade = false` approach (fix 1 above), `ManagePositions()` naturally keeps running. **No separate code change is required** — this fix is satisfied by correctly implementing fix 1 (not setting `g_autoTrade = false` in the equity guard).

Verify after fix 1 is applied: `ManagePositions()` must still guard on `g_autoTrade` (for the `InpATEnable = false` case), but must **not** be blocked by equity halt.

**Changelog entry:**
```
//|  [V8-26] EQUITY-HALT-MANAGE: ManagePositions unaffected by halt  |
//|    The old equity halt set g_autoTrade=false, which also blocked  |
//|    ManagePositions() — stopping break-even and trailing stop moves|
//|    on open positions. Other halt types (daily loss, session halt) |
//|    do not affect position management. Fix: equity halt now uses   |
//|    g_equityHalted (gating only CheckRiskConditions), leaving      |
//|    ManagePositions() unaffected.                                  |
```

---

### 3 · EQUITY-HALT-ALERT — No Alert() on equity halt (Low)

**Problem:** Both equity guards call only `LogWarning()`. Every other halt type fires an `Alert()`:
- `g_dailyLossHalted`: `Alert(EA_NAME " — DAILY LOSS LIMIT REACHED ...")`
- `g_sessionHalted`: `Alert(EA_NAME " — SESSION HALTED: ...")`

`LogWarning()` writes to the MT5 journal only; `Alert()` shows a popup and plays a sound. A live equity halt silently terminates new entries with no notification to the trader.

**Fix:** Already addressed in fix 1 above — both `Alert()` calls are included in the new guard bodies. **No additional change required** once fix 1 is applied.

**Changelog entry:**
```
//|  [V8-26] EQUITY-HALT-ALERT: Alert() fired on equity halt         |
//|    The equity guards used LogWarning() only. Every other halt     |
//|    type (daily loss, session halt) fires an Alert() popup. A live |
//|    equity halt silently stopped entries with no trader            |
//|    notification. Fix: Alert() added to both equity guard bodies,  |
//|    consistent with the established halt-notification pattern.     |
```

---

## Version / Metadata Updates

Apply in this order:
1. Prepend all three `[V8-26]` changelog entries to the file header (after the v8.25 block).
2. Change `#property version` from `"8.10"` to `"8.11"`.
3. Change `#define EA_VERSION` from `"8.10"` to `"8.11"`.
4. Update `#property description` to reference v8.11.

---

## Verification Checklist

- [ ] `g_equityHalted` declared as a global `bool`, initialised to `false`
- [ ] `RiskStateSave()` writes `GVKey("EquityHalted")`
- [ ] `RiskStateLoad()` reads and restores `g_equityHalted`
- [ ] `RiskStateLoad()` log condition includes `|| g_equityHalted`
- [ ] `OnInit()` zeroes `g_equityHalted` before calling `RiskStateLoad()`
- [ ] `CheckRiskConditions()` equity guard bodies: set `g_equityHalted=true`, call `RiskStateSave()`, fire `Alert()`, call `LogRisk()` — do **not** set `g_autoTrade = false`
- [ ] `g_autoTrade = false` removed from both old equity guard bodies
- [ ] `ManagePositions()` is NOT guarded on `g_equityHalted` — only on `g_autoTrade`
- [ ] Both `Alert()` calls include the halt value and `[V8-26]` tag
- [ ] `#property version` and `EA_VERSION` both read `"8.11"`
- [ ] Line count is approximately 3,445 (+22 from 3,423)
