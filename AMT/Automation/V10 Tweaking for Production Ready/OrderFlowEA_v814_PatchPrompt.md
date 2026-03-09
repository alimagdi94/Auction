# OrderFlowEA v8.14 — Patch Prompt for Pair Programmer LLM

**Source file:** `OrderFlowEA_v813.mq5` (3,571 lines)
**Target version:** `8.14`
**Tag:** `[V8-29]`
**Fixes:** 2 issues — one High severity in `OnTradeTransaction()`, one Very Low dead variable cleanup

---

## To-Do List

- [ ] **ABSLOW-SL-FP** — Fix `AbsLow` conviction label causing false SL-hit detection in `OnTradeTransaction()` *(High)*
- [ ] **DEAD-VAR-SIGBAR** — Remove unused global variable `g_lastSignalBar` *(Very Low)*

---

## Background

Both issues are independent. `ABSLOW-SL-FP` is a silent risk management corruption bug that has existed since the conviction label system was introduced — it causes `g_consecutiveLosses` to increment incorrectly whenever a position tagged with `AbsLow` closes at TP or is manually closed, potentially triggering a spurious session halt. `DEAD-VAR-SIGBAR` is a harmless dead variable that has never been used as a read operand.

---

## Fix Specifications

---

### 1 · ABSLOW-SL-FP — False SL-hit detection from `AbsLow` label (High)

**Location:** `OnTradeTransaction()`, the `isSLHit` computation, ~line 3509.

**Root cause:**

The SL detection for EA-owned orders uses a bare substring search across the entire lowercased deal comment:

```mql5
bool isSLHit = isOurOrder
               ? (StringFind(commentLower, "sl") >= 0 && StringFind(commentLower, "tp") < 0)
               : (dealNet < 0.0);
```

The order comment format is:

```
FP_Buy_MKT_HFT72|AbsLow+StackBuy|T65|14:30
```

When a broker appends its exit reason (e.g. `" [sl]"` or `" [tp]"`), the full closing-deal comment becomes:

```
FP_Buy_MKT_HFT72|AbsLow+StackBuy|T65|14:30 [tp]
```

The label token `AbsLow` lowercases to `abslow`, which contains the substring `sl` at position 2. `StringFind(commentLower, "sl")` returns a non-negative value even when the actual exit is a TP close or manual close. Because the label is in the middle of the comment, `"sl"` is found in `"abslow"` **before** any broker-appended suffix is considered.

**Result:** Any position whose conviction label includes `AbsLow` is permanently misclassified as an SL hit, inflating `g_consecutiveLosses`, potentially triggering an erroneous session halt, and corrupting the size-reduction state.

`AbsLow` is a routine bullish conviction signal (absorption at bar low). It appears frequently in normal trading conditions.

**Fix — scope the SL/TP search to the tail after the last `|` separator:**

The last pipe-delimited segment of our comment is always the bar timestamp (`HH:MM`). The broker appends its exit notation after this, so the SL/TP indicator always appears in the tail. Scoping the search to the tail after the last `|` avoids matching labels in earlier segments.

Replace the `isSLHit` / `isTPHit` computation block with:

```mql5
   // [V8-29] ABSLOW-SL-FP: the previous bare StringFind(commentLower,"sl") matched "sl"
   //    inside the conviction label "abslow" (lowercase of "AbsLow"), misclassifying
   //    every TP or manual close on an AbsLow-tagged order as an SL hit. This silently
   //    inflated g_consecutiveLosses and could trigger a spurious session halt.
   //    Fix: scope the SL/TP keyword search to the tail after the last "|" separator.
   //    Our comment format is "FP_Dir_Type_HFTn|Label|Tn|HH:MM"; the broker appends
   //    its exit reason after the last segment, so scanning only the tail is sufficient.
   string commentTail = commentLower;
   {
    int p = -1, cur = 0;
    while((cur = StringFind(commentLower, "|", cur)) >= 0) { p = cur; cur++; }
    if(p >= 0) commentTail = StringSubstr(commentLower, p + 1);
   }
   bool isSLHit = isOurOrder
                  ? (StringFind(commentTail, "sl") >= 0 && StringFind(commentTail, "tp") < 0)
                  : (dealNet < 0.0);
   bool isTPHit = (StringFind(commentTail, "tp") >= 0);
```

**Verification table (all must pass):**

| Comment | `isOurOrder` | Expected `isSLHit` | Expected `isTPHit` |
|---|---|---|---|
| `FP_Buy_MKT_HFT72\|AbsLow+StackBuy\|T65\|14:30 [sl]` | true | true | false |
| `FP_Buy_MKT_HFT72\|AbsLow+StackBuy\|T65\|14:30 [tp]` | true | false | true |
| `FP_Buy_MKT_HFT72\|AbsLow+StackBuy\|T65\|14:30` | true | false | false |
| `FP_Buy_MKT_HFT72\|BullDelta\|T65\|14:30 [sl]` | true | true | false |
| `[sl]` | false | n/a (fallback path) | false |
| `sl` | false | n/a (fallback path) | false |

**Changelog entry:**
```
//|  [V8-29] ABSLOW-SL-FP: false SL-hit from "AbsLow" label in      |
//|    OnTradeTransaction() used StringFind(commentLower,"sl") across  |
//|    the full comment. The label "AbsLow" lowercases to "abslow"    |
//|    which contains "sl" at position 2 — misclassifying every TP    |
//|    or manual close on an AbsLow-tagged order as an SL hit,        |
//|    silently inflating g_consecutiveLosses and potentially          |
//|    triggering a spurious session halt.                             |
//|    Fix: scope search to commentTail (text after last "|"), where  |
//|    the broker appends its exit reason. Label tokens in earlier     |
//|    segments are no longer scanned.                                 |
```

---

### 2 · DEAD-VAR-SIGBAR — Unused global `g_lastSignalBar` (Very Low)

**Location:** Global declarations block (~line 725) and three write sites.

**Problem:** `g_lastSignalBar` (int) is declared, reset in `ReloadHistory()` and `OnInit()`, and set in `EvalAndFireSignal()` — but is **never read** anywhere. The actual signal frequency gate uses `g_lastSignalBarTime` (datetime) combined with `iBarShift()`. `g_lastSignalBar` has been a dead variable since the bar-time-based gate replaced the index-based gate.

**Fix — remove in three steps:**

1. Delete the declaration at ~line 725:
```mql5
int      g_lastSignalBar     = -9999;   // ← delete this line
```

2. Delete the reset in `ReloadHistory()` (~line 2194):
```mql5
g_lastSignalBar      = -9999;   // ← delete this line
```

3. Delete the assignment in `EvalAndFireSignal()` (~line 2431):
```mql5
g_lastSignalBar     = bi;   // ← delete this line
```

4. Delete the reset in `OnInit()` (~line 3303):
```mql5
g_lastSignalBar   = -9999;   // ← delete this line
```

**Changelog entry:**
```
//|  [V8-29] DEAD-VAR-SIGBAR: removed unused global g_lastSignalBar. |
//|    The variable was written in three places but never read.        |
//|    The signal frequency gate uses g_lastSignalBarTime + iBarShift |
//|    exclusively. Dead variable since the bar-time gate was adopted. |
```

---

## Version / Metadata Updates

Apply in this order:
1. Prepend both `[V8-29]` changelog entries to the file header (after the v8.28 block).
2. Change `#property version` from `"8.13"` to `"8.14"`.
3. Change `#define EA_VERSION` from `"8.13"` to `"8.14"`.
4. Update `#property description` to reference v8.14.

---

## Verification Checklist

- [ ] `commentTail` correctly isolates the text after the **last** `|` in the comment (loop scans forward keeping the final match)
- [ ] `isSLHit` and `isTPHit` both use `commentTail`, not `commentLower`
- [ ] The non-EA fallback path (`!isOurOrder`) is unchanged: `isSLHit = (dealNet < 0.0)`
- [ ] `g_lastSignalBar` does not appear anywhere in the file (`grep -n "g_lastSignalBar"` returns zero non-comment results)
- [ ] `g_lastSignalBarTime` is untouched (it is the active frequency-gate variable)
- [ ] `#property version` and `EA_VERSION` both read `"8.14"`
- [ ] Line count is approximately 3,569 (−4 removed lines + ~14 added lines ≈ 3,581)
