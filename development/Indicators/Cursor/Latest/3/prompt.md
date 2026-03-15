# Signal Engine Review — Structural Bias Analysis & Proposed Rewrite

## Executive Summary

**All three concerns are valid and confirmed by code review.** The signal engine has a cumulative bullish bias rooted in tick classification, a misnamed CVD slope function, and a score compression problem that makes it very hard for the engine to produce strong sell signals.

---

## 1. Tick Classification Bias — CONFIRMED BUG

### The Problem

In `Classify()` (lines 783–808), when the symbol **does not** have trade ticks (`g_hasTrades == false` — typical for Forex), the fallback branch is:

```mql5
else  // Forex / no last-price
{
   if(t.bid > g_prevBid)
      isBuy = true;
   else if(t.bid < g_prevBid)
      isSell = true;
   else
      isBuy = true;   // ← FLAT TICK FORCED TO BUY
}
```

When `t.bid == g_prevBid` the tick is classified as **BUY**. This is incorrect for order-flow analysis.

### Impact Analysis

In live Forex markets, a large proportion of ticks arrive with the bid **unchanged** (especially on low-volatility pairs or during Asian session). Each of these phantom "buys" flows into:

| Downstream metric | How it's affected |
|---|---|
| `AccumulateTick()` → `ask_vol` | +1 volume attributed to ask side every flat tick |
| `total_delta` | Monotonically inflated upward |
| `ComputeOFScore()` component A (delta ratio) | Biased toward `> 0.5` → bullish |
| `ComputeHFTSignal()` component C2 (delta/div) | Biased positive |
| `ComputeCVDSlope()` | All three bars' normalized deltas skewed positive |
| `cumDelta` profile | Nearly always positive — matches your observation |
| Final signal direction | BUY signals dominate because HFT score is structurally pushed above the buy threshold |

### Recommendation

**Yes — flat ticks should be classified as neutral (neither buy nor sell).** They still carry volume for profile/POC purposes but must not influence directional metrics. The corrected fallback:

```mql5
else  // Forex / no last-price
{
   if(t.bid > g_prevBid)
      isBuy = true;
   else if(t.bid < g_prevBid)
      isSell = true;
   // else: flat tick → isBuy=false, isSell=false (neutral)
}
```

With this fix, `AccumulateTick()` already handles the neutral case correctly — it adds to `total_vol` but neither `ask_vol` nor `bid_vol`, so `total_delta` remains unaffected by flat ticks.

---

## 2. CVD Slope Implementation — CONFIRMED MISNAME / DESIGN ISSUE

### The Problem

`ComputeCVDSlope()` (lines 1131–1144):

```mql5
double ComputeCVDSlope(int bi)
{
   // ...
   double nd0 = (double)g_bars[bi].total_delta   / v0;  // normalized delta, NOT cumulative
   double nd1 = (double)g_bars[bi-1].total_delta / v1;
   double nd2 = (double)g_bars[bi-2].total_delta / v2;
   return (2.0 * (nd0 - nd1) + (nd1 - nd2)) / 3.0;
}
```

This computes a **weighted first-difference of per-bar normalized delta** — effectively a "delta acceleration" or "delta momentum slope." It is **not** a CVD (Cumulative Volume Delta) slope.

A true CVD slope would:
1. Maintain a running cumulative sum: `CVD[i] = CVD[i-1] + total_delta[i]`
2. Compute the slope of that cumulative series (e.g., linear regression slope over N bars, or simple `(CVD[i] - CVD[i-N]) / N`)

### Why It Matters

The current implementation is highly noisy because per-bar delta can swing wildly. The purpose of CVD in institutional order-flow analysis is to smooth individual bar noise and reveal **persistent** buying/selling pressure. By differencing non-cumulated values, the function discards exactly the information CVD is meant to provide.

### Recommendation

**Yes — maintain a true running CVD series and compute slope from that.** Proposed approach:

1. Add a `cumDelta` field to `FPBar` that stores the running cumulative delta up to and including that bar.
2. Compute CVD slope as a simple linear regression slope (or simpler: endpoint difference) over the last N bars of that cumulative series.

```mql5
// During ProcessTicks / LoadHistory, after accumulating each bar:
// g_bars[bi].cumDelta = (bi > 0) ? g_bars[bi-1].cumDelta + g_bars[bi].total_delta
//                                 : g_bars[bi].total_delta;

double ComputeCVDSlope(int bi, int lookback = 5)
{
   if(bi < lookback) return 0.0;
   // Simple endpoint slope, normalized by average volume
   long avgVol = 0;
   for(int i = bi - lookback + 1; i <= bi; i++)
      avgVol += g_bars[i].total_vol;
   avgVol = MathMax(1, avgVol / lookback);

   double cvdStart = (double)g_bars[bi - lookback + 1].cumDelta;
   double cvdEnd   = (double)g_bars[bi].cumDelta;
   return (cvdEnd - cvdStart) / (lookback * avgVol);
}
```

This gives a genuine CVD trend signal: a persistently positive slope means sustained buying pressure, even if individual bars oscillate.

---

## 3. Score Compression / Threshold Issue — CONFIRMED DESIGN PROBLEM

### The Problem

The HFT score (lines 1151–1217) is a weighted sum of 6 components, each mapped to `[-1, +1]`, then scaled to `[-100, +100]`:

| Component | Weight (default) | Behavior |
|---|---|---|
| C1: OFS | 30% | Continuous `[-1,+1]` — works well |
| C2: Delta/Div | 20% | Continuous `[-1,+1]` — works well |
| C3: POC position | 15% | Continuous `[-1,+1]` — works well |
| C4: Absorption | 10% | **Ternary: {-1, 0, +1}** — often 0 |
| C5: Exhaustion | 10% | **Ternary: {-1, 0, +1}** — often 0 |
| C6: CVD slope | 15% | Continuous but tiny range — often ≈ 0 |

**The problem:** C4 and C5 together account for 20% of the weight and are usually 0 (absorption and exhaustion are rare events). C6 in its current form is also frequently ≈ 0 because the un-cumulated normalized delta differences are tiny.

This means the effective score is often driven by only ~65% of its theoretical weight (C1 + C2 + C3). The maximum achievable score in practice is roughly `65 × 1.0 = 65`, which barely clears the buy threshold of 60 and rarely reaches conviction.

For sells, it's even worse: the flat-tick BUY bias keeps C1 and C2 structurally positive, so the raw score struggles to go below ~-30, far from the -55 sell threshold.

### Recommendation

There are three complementary fixes:

#### A) Fix the source bias first (Issue #1)
This immediately restores symmetric delta distribution, letting sell signals emerge naturally.

#### B) Rescale binary/ternary components
Instead of treating C4 and C5 as ternary `{-1, 0, +1}`, apply a softer scoring that can contribute a continuous range even when the strong signal isn't present:

```mql5
// C4: Absorption — grade by number of extreme levels with absorption
double c4 = 0.0;
int absCountLow = 0, absCountHigh = 0;
int chk = MathMin(FP_EXTREME_LEVELS_MAX, len / 3 + 1);
for(int i = len - chk; i < len; i++)
   if(i >= 0 && g_bars[bi].levels[i].is_absorption) absCountLow++;
for(int i = 0; i < chk; i++)
   if(i < len && g_bars[bi].levels[i].is_absorption) absCountHigh++;
c4 = (double)(absCountLow - absCountHigh) / MathMax(1, chk);
// Now c4 is in [-1, +1] continuously
```

#### C) Lower or auto-calibrate thresholds
With the bias fixed and components rescaled:
- A buy threshold of **45–50** and sell threshold of **40–45** would better match the actual score distribution.
- Alternatively, use **percentile-based adaptive thresholds**: track the rolling distribution of HFT scores over the last N bars and fire signals only in the top/bottom 10th percentile.

---

## 4. Proposed Clean Rewrite — Signal Engine Section

Below is a complete rewrite of the signal-critical functions. **No rendering, UI, or non-signal code is touched.** This is a drop-in replacement for the four key functions.

### 4a. `Classify()` — Neutral flat ticks

```mql5
//+------------------------------------------------------------------+
//| Tick classification — trade flags > last-price > bid direction    |
//| Flat ticks are NEUTRAL (no side bias).                           |
//+------------------------------------------------------------------+
void Classify(const MqlTick &t, bool &isBuy, bool &isSell)
{
   isBuy  = false;
   isSell = false;

   if(g_hasTrades)
   {
      // 1. Exchange-provided flags (most reliable)
      isBuy  = (t.flags & TICK_FLAG_BUY)  == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;

      // 2. Fallback: classify by last-price vs BBO
      if(!isBuy && !isSell)
      {
         if(t.last >= t.ask)
            isBuy = true;
         else if(t.last <= t.bid)
            isSell = true;
         // else: mid-spread → neutral
      }
   }
   else
   {
      // Forex / no last-price: infer from bid tick direction
      if(t.bid > g_prevBid)
         isBuy = true;
      else if(t.bid < g_prevBid)
         isSell = true;
      // else: flat tick → neutral (no bias)
   }
}
```

### 4b. `ComputeCVDSlope()` — True cumulative delta slope

This requires a small addition to the data model: a `cumDelta` field on `FPBar`. After each bar's ticks are accumulated, set:

```mql5
// Add to FPBar struct:
//   long cumDelta;   // running cumulative delta through this bar

// After accumulating bar bi's ticks (in ProcessTicks or after LoadHistory):
//   g_bars[bi].cumDelta = (bi > 0)
//       ? g_bars[bi-1].cumDelta + g_bars[bi].total_delta
//       : g_bars[bi].total_delta;
```

Then the slope function becomes:

```mql5
//+------------------------------------------------------------------+
//| True CVD slope: linear regression over last N bars of cumDelta   |
//| Returns normalized slope ∈ roughly [-1, +1] after scaling.       |
//+------------------------------------------------------------------+
double ComputeCVDSlope(int bi, int lookback = 5)
{
   if(bi < 1) return 0.0;
   int N = MathMin(lookback, bi + 1);
   if(N < 2) return 0.0;

   // Least-squares slope of cumDelta series
   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
   for(int k = 0; k < N; k++)
   {
      double x = (double)k;
      double y = (double)g_bars[bi - N + 1 + k].cumDelta;
      sumX  += x;
      sumY  += y;
      sumXY += x * y;
      sumX2 += x * x;
   }
   double denom = N * sumX2 - sumX * sumX;
   if(MathAbs(denom) < 1e-12) return 0.0;
   double slope = (N * sumXY - sumX * sumY) / denom;

   // Normalize by average bar volume so result is scale-independent
   long avgVol = 0;
   for(int k = bi - N + 1; k <= bi; k++)
      avgVol += g_bars[k].total_vol;
   avgVol = MathMax(1, avgVol / N);

   double normalized = slope / (double)avgVol;
   if(!MathIsValidNumber(normalized)) return 0.0;
   return normalized;
}
```

### 4c. `ComputeOFScore()` — Unchanged (works correctly once delta bias is fixed)

The OFS function is well-designed—its delta ratio component (A) will naturally center around 0.5 once flat ticks stop inflating `total_delta`. No changes needed.

### 4d. `ComputeHFTSignal()` — Continuous components, better normalization

```mql5
//+------------------------------------------------------------------+
//| HFT Multi-Factor Signal Score (-100 to +100)                     |
//| All components now produce continuous [-1, +1] output.           |
//+------------------------------------------------------------------+
double ComputeHFTSignal(int bi, int preOFS = -1)
{
   int  len  = g_bars[bi].level_count;
   long tvol = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0) return 0.0;

   // C1: OFS mapped to [-1, +1] (unchanged)
   int ofs = (preOFS >= 0 ? preOFS : ComputeOFScore(bi));
   double c1 = ((double)ofs - 50.0) / 50.0;

   // C2: Delta ratio with divergence flip (unchanged)
   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio = MathMax(-1.0, MathMin(1.0, rawDr));
   double c2 = g_bars[bi].is_delta_divergence ? -dRatio : dRatio;

   // C3: POC position (unchanged)
   double c3 = 0.0;
   if(g_bars[bi].poc_idx >= 0 && len > 2)
   {
      double range  = g_bars[bi].high - g_bars[bi].low;
      double pocPos = (range > g_step)
                      ? (g_bars[bi].levels[g_bars[bi].poc_idx].price - g_bars[bi].low) / range
                      : 0.5;
      c3 = -(pocPos * 2.0 - 1.0);
   }

   // C4: Absorption — CONTINUOUS grading by count at extremes
   int chk = MathMin(FP_EXTREME_LEVELS_MAX, len / 3 + 1);
   int absCountLow = 0, absCountHigh = 0;
   for(int i = len - chk; i < len; i++)
      if(i >= 0 && g_bars[bi].levels[i].is_absorption) absCountLow++;
   for(int i = 0; i < chk; i++)
      if(i < len && g_bars[bi].levels[i].is_absorption) absCountHigh++;
   double c4 = (chk > 0)
               ? (double)(absCountLow - absCountHigh) / (double)chk
               : 0.0;

   // C5: Exhaustion — CONTINUOUS grading by run length
   int exhBidRun = 0, exhAskRun = 0;
   for(int i = 0; i < len; i++)
   {
      if(g_bars[bi].levels[i].is_exhaustion_ask) exhAskRun++;
      if(g_bars[bi].levels[i].is_exhaustion_bid) exhBidRun++;
   }
   double maxExhRun = MathMax(1.0, (double)InpExhaustionCells * 2.0);
   double c5 = ((double)exhBidRun - (double)exhAskRun) / maxExhRun;
   c5 = MathMax(-1.0, MathMin(1.0, c5));

   // C6: True CVD slope (uses cumDelta series)
   double cvdScale = (InpHFTCVDScale > 0.0) ? InpHFTCVDScale : FP_HFT_CVD_SLOPE_SCALE;
   double c6 = 0.0;
   if(bi >= 1)
   {
      double slope = ComputeCVDSlope(bi);
      c6 = MathMax(-1.0, MathMin(1.0, slope * cvdScale));
   }

   // Normalize weights
   double w1 = MathMax(0.0, InpHFTWtOFS)      / 100.0;
   double w2 = MathMax(0.0, InpHFTWtDeltaDiv) / 100.0;
   double w3 = MathMax(0.0, InpHFTWtPOC)      / 100.0;
   double w4 = MathMax(0.0, InpHFTWtAbs)      / 100.0;
   double w5 = MathMax(0.0, InpHFTWtExh)      / 100.0;
   double w6 = MathMax(0.0, InpHFTWtCVD)      / 100.0;
   double wSum = w1 + w2 + w3 + w4 + w5 + w6;
   if(wSum <= 0.0) wSum = 1.0;
   w1 /= wSum; w2 /= wSum; w3 /= wSum;
   w4 /= wSum; w5 /= wSum; w6 /= wSum;

   double raw = c1*w1 + c2*w2 + c3*w3 + c4*w4 + c5*w5 + c6*w6;
   if(!MathIsValidNumber(raw)) raw = 0.0;
   return MathMax(-100.0, MathMin(100.0, raw * 100.0));
}
```

---

## 5. Threshold Recommendation After Fixes

With the three fixes applied (neutral flat ticks, true CVD, continuous components), the score distribution will widen and center closer to 0. Recommended starting thresholds:

| Parameter | Current | Recommended |
|---|---|---|
| `InpSignalThreshold` (buy) | 60 | **45** |
| `InpSignalThresholdSell` (sell) | 55 | **40** |

These can be further tuned empirically once the bias is removed. The key insight is that the current thresholds were set while the engine had structural BUY bias — they implicitly compensated for the inflated baseline. With a zero-centered score distribution, lower thresholds will capture meaningful signals on both sides.

---

## 6. Summary of Changes

| # | What | Type | Risk |
|---|---|---|---|
| 1 | Remove `else isBuy = true` in `Classify()` | **Bug fix** | Low — removes false data |
| 2 | Add `cumDelta` to `FPBar`, rewrite `ComputeCVDSlope()` | **Feature correction** | Medium — new field, recomputation needed after load |
| 3 | Make C4/C5 continuous in `ComputeHFTSignal()` | **Enhancement** | Low — same weights, smoother output |
| 4 | Lower default thresholds to 45/40 | **Tuning** | Low — user-configurable inputs |

All four changes are independent and can be applied incrementally. **Fix #1 alone will have the most dramatic impact** on signal symmetry.
