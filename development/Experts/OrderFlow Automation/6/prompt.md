# Signal Engine Rewrite — OrderFlowAlpha.mq5

## Overview

Three structural bugs in the signal engine produce a persistent **buy-side bias** and prevent the scoring system from reaching full conviction. This prompt describes each bug with exact line references, the root cause, and a precise specification for the fix. **Do not change any code outside the signal engine** (tick classification, delta/CVD, component scoring, final signal composition). All trading logic, UI, risk management, and order execution must remain untouched.

---

## Bug 1: Tick Classification Bias (BUY bias on flat ticks)

### Location
`Classify()` — **Lines 1016–1041**

### Current Code (problematic)
```mql5
else
{
   if(t.bid > g_prevBid)
      isBuy = true;
   else if(t.bid < g_prevBid)
      isSell = true;
   else
      isBuy = true;   // ← BUG: flat tick forced to BUY
}
```

### Problem
When `g_hasTrades == false` (Forex / CFD symbols that report only bid/ask, no Last price), the `else` fallback for **unchanged bid** forces every flat tick to be classified as a **buy**. On low-volatility sessions where bid doesn't move tick-to-tick, this injects a large number of phantom buy ticks. The effect cascades:

- `total_delta` is biased positive on every bar
- `cumDelta` profile skews green
- OFS score inflated (delta ratio component always leans bullish)
- HFT signal C2 (delta exhaustion) biased
- HFT signal C6 (CVD slope) biased
- Final signal direction overwhelmingly BUY

### Fix Specification
**Flat ticks must be classified as neutral** — both `isBuy` and `isSell` stay `false`.

Replace the `else` branch at line 1038–1039 with:
```mql5
else
{
   if(t.bid > g_prevBid)
      isBuy = true;
   else if(t.bid < g_prevBid)
      isSell = true;
   // else: bid unchanged → neutral (isBuy=false, isSell=false)
   // Neutral ticks still contribute to total_vol via AccumulateTick
   // but do NOT add to ask_vol, bid_vol, or total_delta.
}
```

### Downstream Impact
- `AccumulateTick` (line 850) already handles the neutral case correctly:
  `g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));`
  A neutral tick adds 0 to delta but still adds `vol` to `total_vol` — this is the correct behavior.
- No changes needed in `AccumulateTick`.

---

## Bug 2: CVD Slope Is Actually a Delta-Ratio Slope (not true CVD)

### Location
`ComputeCVDSlope()` — **Lines 1349–1364**

### Current Code (problematic)
```mql5
double ComputeCVDSlope(int bi)
{
   if(bi < 2) return 0.0;
   long v0 = MathMax(1, g_bars[bi].total_vol);
   long v1 = MathMax(1, g_bars[bi-1].total_vol);
   long v2 = MathMax(1, g_bars[bi-2].total_vol);
   double nd0 = (double)g_bars[bi].total_delta   / v0;
   double nd1 = (double)g_bars[bi-1].total_delta / v1;
   double nd2 = (double)g_bars[bi-2].total_delta / v2;
   // ...
   return (2.0 * (nd0 - nd1) + (nd1 - nd2)) / 3.0;
}
```

### Problem
This computes the slope of **per-bar normalized delta** (delta/volume), NOT the slope of a **cumulative delta series**. CVD by definition is:

```
CVD[i] = CVD[i-1] + delta[i]
```

The slope should be derived from `CVD[i], CVD[i-1], CVD[i-2]`, not from independent per-bar ratios. The current implementation effectively measures "is the delta ratio accelerating?" which is a different (and noisier) signal than "is the overall cumulative buying/selling pressure trending?"

### Fix Specification
Maintain a **true running CVD series** and compute slope from that.

1. **Add a global CVD array** (or compute it inline from the `g_bars[]` array):

```mql5
// Option A: Compute inline in ComputeCVDSlope (no new globals needed)
double ComputeCVDSlope(int bi)
{
   if(bi < 2) return 0.0;

   // Build true CVD values for bars [bi-2], [bi-1], [bi]
   // by summing total_delta from bar 0 up to each bar index.
   // For efficiency, only compute the 3 CVD values we need:
   long cvd0 = 0, cvd1 = 0, cvd2 = 0;
   for(int k = 0; k <= bi; k++)
   {
      if(k <= bi - 2) cvd2 += g_bars[k].total_delta;  // up to bi-2 (will be overwritten correctly below)
      if(k <= bi - 1) cvd1 += g_bars[k].total_delta;
      cvd0 += g_bars[k].total_delta;
   }
   // Actually simpler and correct:
   // cvd2 = sum of total_delta from bar 0..bi-2
   // cvd1 = cvd2 + g_bars[bi-1].total_delta
   // cvd0 = cvd1 + g_bars[bi].total_delta

   // Normalize by average volume of the 3 bars to keep scale in [-1, 1] range
   double avgVol = (double)(MathMax(1, g_bars[bi].total_vol)
                          + MathMax(1, g_bars[bi-1].total_vol)
                          + MathMax(1, g_bars[bi-2].total_vol)) / 3.0;
   if(avgVol < 1.0) avgVol = 1.0;

   double n0 = (double)cvd0 / avgVol;
   double n1 = (double)cvd1 / avgVol;
   double n2 = (double)cvd2 / avgVol;

   // Recency-weighted finite difference (same weighting as before)
   return (2.0 * (n0 - n1) + (n1 - n2)) / 3.0;
}
```

**Note:** The simpler O(1) approach is preferred if performance matters:

```mql5
double ComputeCVDSlope(int bi)
{
   if(bi < 2) return 0.0;

   // CVD differences:
   // cvd[bi]   - cvd[bi-1] = g_bars[bi].total_delta
   // cvd[bi-1] - cvd[bi-2] = g_bars[bi-1].total_delta
   // We don't need absolute CVD values — only differences for slope.
   long d0 = g_bars[bi].total_delta;     // CVD change over last bar
   long d1 = g_bars[bi-1].total_delta;   // CVD change over bar before that

   double avgVol = (double)(MathMax(1, g_bars[bi].total_vol)
                          + MathMax(1, g_bars[bi-1].total_vol)
                          + MathMax(1, g_bars[bi-2].total_vol)) / 3.0;
   if(avgVol < 1.0) avgVol = 1.0;

   double nd0 = (double)d0 / avgVol;
   double nd1 = (double)d1 / avgVol;

   // Recency-weighted slope: 2× recent change + 1× prior change
   return (2.0 * nd0 + nd1) / 3.0;
}
```

**IMPORTANT:** After fixing Bug 1 (neutral flat ticks), the `total_delta` values flowing into CVD will be significantly cleaner — the CVD slope will no longer be inflated by phantom buy volume.

---

## Bug 3: Score Compression / Dead-Zone Threshold Problem

### Location
`ComputeHFTSignal()` — **Lines 1366–1441**, specifically the weighting at line 1437–1440.

### Current Code
```mql5
const double w1=0.30, w2=0.20, w3=0.15, w4=0.10, w5=0.10, w6=0.15;
double raw = c1*w1 + c2*w2 + c3*w3 + c4*w4 + c5*w5 + c6*w6;
// ...
return MathMax(-1.0, MathMin(1.0, raw)) * 100.0;
```

### Problem
Each component is in `[-1, +1]`, but:

- **C4 (absorption)** returns exactly `-1, 0, or +1` — and `0` is the most common case (no absorption at extremes). When C4 = 0, its 10% weight contributes nothing.
- **C5 (exhaustion)** same ternary pattern — usually `0`.
- **C3 (POC gravity)** is often near `0` when POC is mid-bar.

With 20–35% of the weight budget effectively dead (returning 0) most of the time, the maximum achievable weighted score is often only **~65–70** out of 100 even with perfect alignment on all *non-zero* components. Against thresholds of `60` (strong) / `55` (weak from adaptive), the engine struggles to generate signals — and when it does, BUY signals dominate due to Bug 1.

### Fix Specification

Two complementary changes:

#### A. Rescale the weighted score to use the full [-100, +100] range

After computing the raw weighted average, **amplify by the inverse of the maximum theoretically achievable score** (accounting for typical zero-contribution components), or more practically: apply a scaling factor so the score distribution actually spans the decision range.

```mql5
// After computing raw weighted average:
double raw = c1*w1 + c2*w2 + c3*w3 + c4*w4 + c5*w5 + c6*w6;

// Count how many components contributed a non-zero value
int activeCount = 0;
double activeWeight = 0.0;
if(MathAbs(c1) > 0.001) { activeCount++; activeWeight += w1; }
if(MathAbs(c2) > 0.001) { activeCount++; activeWeight += w2; }
if(MathAbs(c3) > 0.001) { activeCount++; activeWeight += w3; }
if(MathAbs(c4) > 0.001) { activeCount++; activeWeight += w4; }
if(MathAbs(c5) > 0.001) { activeCount++; activeWeight += w5; }
if(MathAbs(c6) > 0.001) { activeCount++; activeWeight += w6; }

// Rescale: if only 60% of weight is active, divide by 0.6 to restore full range
if(activeWeight > 0.0 && activeCount >= 2)
   raw = raw / activeWeight;

return MathMax(-1.0, MathMin(1.0, raw)) * 100.0;
```

This ensures that a signal with 3 strong confirming components can still reach the threshold, even if the other 3 components are dormant/neutral.

#### B. Lower the default threshold

Consider reducing `InpSignalThreshold` default from **60** to **50**, or use the adaptive threshold with a lower floor (`InpAdaptiveThreshMin` from 35 to 30). This can be a parameter-level change in the `input` declarations — no logic change needed.

**Alternatively**, if you prefer not to change defaults, the rescaling in (A) alone should be sufficient to let the score naturally reach 60 when conviction is present.

---

## Summary of Changes Required

| # | File Section | Lines | Change |
|---|---|---|---|
| 1 | `Classify()` | 1038–1039 | Remove `else isBuy = true;` — leave flat ticks as neutral |
| 2 | `ComputeCVDSlope()` | 1349–1364 | Use true CVD differences (raw `total_delta`) instead of per-bar `delta/volume` ratios; normalize by avg volume of the 3-bar window |
| 3 | `ComputeHFTSignal()` | 1436–1440 | Add active-weight rescaling so dormant (zero) components don't compress the score range |

### What NOT to Change
- `ComputeOFScore()` — separate from HFT signal, used for display; leave as-is
- `AccumulateTick()` — already handles neutral ticks correctly
- `ComputeBarSignals()` — not part of this fix
- `PlaceOrders()` — order execution logic stays the same
- `EvalAndFireSignal()` — signal gating logic stays the same
- `GetConvictionResult()` — conviction labeling stays the same
- All UI rendering code — stays the same
- All risk management / position management — stays the same
- All input parameter declarations — stay the same (unless threshold default is intentionally lowered)

### Testing Checklist
After applying the fixes:

1. **Flat tick neutrality**: Run on a Forex pair (no Last price). Confirm that during low-volatility periods, `total_delta` on bars is close to zero (not systematically positive).
2. **CVD slope accuracy**: Print `ComputeCVDSlope()` values for a few bars and verify they correlate with the visual cumulative delta profile slope.
3. **Score distribution**: Log `hftScore` over 50+ bars. Verify:
   - Scores reach both positive AND negative 60+ with roughly equal frequency
   - The signal is not overwhelmingly BUY anymore
4. **Signal balance**: Over a backtest period, count BUY vs SELL signals. Should be approximately balanced on ranging markets.
5. **No regression**: Existing trades on symbols WITH Last price data (`g_hasTrades == true`) should be unaffected by Bug 1 fix (the `if(g_hasTrades)` branch is not modified).
