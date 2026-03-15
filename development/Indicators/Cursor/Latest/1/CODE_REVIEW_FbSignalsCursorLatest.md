# Code Review: FbSignalsCursorLatest.mq5 (Footprint Evolved v6.20)

## Scope
Industry-standard code review of the MQ5 footprint/order-flow indicator: code quality, architecture, performance, and trading logic.

---

## 1. Code Quality

### Strengths
- **Structured data**: `PriceLevel` and `FPBar` are well-defined; MQL5 dynamic-array-in-struct handling is correct (no struct assignment of FPBar to avoid shallow copy of `levels[]`).
- **Input validation**: `OnInit()` validates `_Point`, `InpTickSize`, `InpTickMultiplier`, `InpImbalanceRatio`, `InpVAPercent`, `InpCumDeltaProfW` and clamps history/weights.
- **Comments**: Critical sections (e.g. InsertBar shallow-copy warning, Naked POC, VA expansion) are documented.
- **Resource cleanup**: `OnDeinit()` removes arrows, edit control, canvas, and frees all bar levels and scratch/profile arrays.

### Issues
- **Magic numbers**: Literals used for tuning and layout (e.g. `2.25` in HFT CVD scale, `2.5` in delta gradient, `64` for signal placement arrays, `33` ms throttle). Should be named constants for maintainability.
- **Duplication**: Absorption-at-extremes logic (check low/high N levels) repeated in `ComputeOFScore`, `ComputeHFTSignal`, and `GetConvictionResult`. Signal direction (buy/sell from HFT score) duplicated in `EvalAndFireSignal` and `DrawSignalMarkersPass`.
- **Label building**: `GetConvictionResult` uses repeated `(out.label==""?"":"+")`; a small helper would improve readability.
- **Indentation**: One line (e.g. `g_bars[n].is_naked_poc`) is inconsistently indented.

---

## 2. Architecture

### Strengths
- Clear separation of phases: tick accumulation → bar signals (POC, VA, imbalance, etc.) → render. Lazy `ComputeBarSignals(bi)` via `sorted` flag avoids redundant work.
- Throttled render (wall-clock and Strategy Tester) prevents UI lag.
- Signal/push state is centralized (e.g. `g_lastSignalBarTime`, `g_sigCacheBarIdx`).

### Issues
- **Single large file**: ~3000 lines in one unit; data loading, signal math, canvas drawing, and panel UI are intertwined. No modular boundaries (MQL5 limits multi-file indicators, but logical grouping via functions/sections would help).
- **Global state**: 40+ globals make data flow and unit testing difficult. Grouping into a few structs (e.g. display state, signal state, panel geometry) would clarify ownership.

---

## 3. Performance

### Strengths
- **Render throttle**: ~30 FPS cap and tester-time-based throttle avoid redundant redraws.
- **Scratch buffers**: `g_scratchY1`/`g_scratchY2` reused for bar Y layout; capacity grown only when needed.
- **Signal cache**: `g_sigCacheBarIdx` + `g_sigCacheVol` avoid re-evaluating the same bar when volume unchanged.
- **Binary search**: `FindBarIndex` uses binary search for bar lookup.
- **Append fast-path**: `InsertBar` has a fast path for chronological append without shifting.

### Issues
- **ComputeNakedPOCs**: O(n²) over bars (each bar checks all subsequent bars for retest). Acceptable for typical history sizes; for very large histories consider early exit or spatial indexing if needed.
- **DrawBar**: Per-bar work is proportional to level count; no culling of off-screen levels (acceptable if level count per bar is modest).

---

## 4. Trading / Order Flow Logic

### Strengths
- **Concepts**: POC (max volume), VA (greedy expansion by volume), diagonal imbalance (ask vs next bid / bid vs prev ask), stacked imbalance, absorption (volume > ratio × avg), HVN/LVN, delta divergence (price vs delta), exhaustion (near-zero bid/ask at extremes), CVD slope, OFS (weighted delta/imbalance/stacked/absorption), and HFT multi-factor score are implemented in line with common order-flow practice.
- **No trading/EA code**: Indicator-only; signals are visual and push notifications — appropriate for a footprint tool.
- **Conviction filter**: `InpMinConvictionComp` allows requiring multiple components before firing a signal.

### Issues
- **Hard-coded weights**: HFT weights (e.g. 0.30, 0.20, 0.15) and CVD scale (2.25) are fixed. Making them inputs (or at least named constants) would improve transparency and tuning.
- **CVD slope**: Uses 3-bar recency weighting; no validation against alternative formulations.

---

## 5. Refactoring Plan (Sequential Passes)

| Pass | Focus | Action |
|------|--------|--------|
| 1 | Constants | Introduce named constants for HFT CVD scale, delta gradient scale, absorption check count, signal placement cap, render throttle. |
| 2 | DRY | Add helper for absorption-at-extremes (low/high) and use it in ComputeOFScore, ComputeHFTSignal, GetConvictionResult. |
| 3 | DRY | Centralize “is buy/sell signal” from HFT score + thresholds; use in EvalAndFireSignal and DrawSignalMarkersPass. |
| 4 | Readability | Simplify GetConvictionResult label building (e.g. append with separator helper). |
| 5 | Cleanup | Fix indentation and any remaining minor style issues. |

---

## 6. Refactors Applied

- **Pass 1**: Named constants added: `FP_HFT_CVD_SLOPE_SCALE` (2.25), `FP_DELTA_GRAD_MAG_SCALE` (2.5), `FP_EXTREME_LEVELS_MAX` (3), `FP_SIGNAL_PLACEMENT_MAX` (64). Replaced all corresponding magic numbers.
- **Pass 2**: `GetAbsorptionAtExtremes(bi, atLow, atHigh)` introduced; used in `ComputeOFScore`, `ComputeHFTSignal`, and `GetConvictionResult`.
- **Pass 3**: `EvalSignalDirection(hftScore, isBuy, isSell)` introduced; used in `EvalAndFireSignal` and `DrawSignalMarkersPass`.
- **Pass 4**: `AppendConvictionLabel(label, part)` introduced; used in `GetConvictionResult` for building the conviction label.
- **Pass 5**: Indentation fixed for `g_bars[n].is_naked_poc` in `InsertBar`.

*Review and refactors applied to: FbSignalsCursorLatest.mq5*
