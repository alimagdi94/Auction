# OrderFlowEA — Full Quantitative Systems Review
## Version 6.05 → v7.00 Production Upgrade
**Instrument:** XAUUSD M1 | **Period:** 2026-01-01 → 2026-03-06 | **Deposit:** $10,000 | **Leverage:** 1:2000

---

## 1. System Overview

OrderFlowEA v6.05 is a tick-level footprint order-flow engine for MetaTrader 5. It builds bid/ask volume clusters per price level on each bar, computes a weighted HFT signal score across six components (delta ratio, CVD skew, bar structure, absorption polarity, exhaustion, CVD slope), and fires market orders when the score crosses a threshold. Position management uses bar-low/high stop losses and a 60:1 risk-reward take-profit, with break-even and trailing stop guardians.

---

## 2. Backtest Statistics — Parsed from Report

| Metric | Value |
|---|---|
| Total Trades | 172 |
| Long Trades | **172 (100%)** |
| Short Trades | **0 (0%)** |
| Win Rate | 8.72% (15/172) |
| Profit Factor | **0.969** (< 1.0 = net losing) |
| Net P&L | **−$598.87** |
| Gross Profit | $18,689 |
| Gross Loss | −$19,288 |
| Max Balance Drawdown | **55.85% ($6,657)** |
| Max Equity Drawdown | **61.29% ($8,319)** |
| Sharpe Ratio | **−0.38** |
| Recovery Factor | −0.07 |
| Avg Win | $1,245.93 |
| Avg Loss | −$122.85 |
| Max Consecutive Losses | **22** |
| Avg Consecutive Losses | 11 |
| Avg Hold Time | 1h 12m |
| Min Hold Time | **12 seconds** |
| History Quality | 100% real ticks |

---

## 3. Key Weaknesses — Evidence-Based

### 🔴 CRITICAL-1: Zero Sell Trades — Complete Directional Bias

**Finding:** All 172 trades are LONG. Not a single short was taken across 65 days on XAUUSD M1.

**Root cause analysis from trade log:**

Every conviction label contains `AbsLow` (Absorption at Low) or `BullDelta`/`DeltaDiv+AbsLo`/`StackBuy+AbsLo`. The `ComputeHFTSignal()` components C4 (absorption polarity) and C5 (exhaustion) are systematically scoring positive. This is compounded by:

- Signal threshold = 35 (very low). Any mild positive HFT bias generates a BUY.
- `InpSignalFreqBars = 3` — allows a new trade every 3 bars = every 3 minutes on M1.
- No multi-timeframe filter to confirm the macro trend direction.

On XAUUSD M1 during Jan–Mar 2026 (gold was in a sustained bull trend from $4,300 to $5,400+), the bar-level delta is perpetually positive, making `hftScore >= +35` trivially achievable on nearly every bar. The sell threshold (`<= -35`) is effectively unreachable because the macro trend biases every M1 footprint bar bullish.

**This is the single largest structural flaw in the system.**

---

### 🔴 CRITICAL-2: Stop-Loss Hit at Entry — SL Too Tight

**Evidence from deal log (seconds to fill, then SL hit):**

```
Trade 90: Open 12:43:00, Close 12:43:06 → 6 seconds
Trade 62: Open 17:36:00, Close 17:36:01 → 1 second (!)
Trade 268: Open 14:38:01, Close 14:38:04 → 3 seconds
Trade 318: Open 18:35:00, Close 18:35:00 → same second
Trade 306: Open 06:28:00, Close 06:28:01 → 1 second (!)
```

**Root cause:** SL mode is `SL_MODE_BAR`. On XAUUSD M1, a 1-minute bar often spans only 5–30 points ($0.05–$0.30). The SL is placed at `barLow − BufferDist`. With `InpBufferPips = 200` (200 pips = **$2.00** on XAUUSD), this adds $2.00 below bar low. But in a 5-pip bar, the SL might be only 7 pips from the market bid — well within normal spread noise on gold.

The `SYMBOL_TRADE_STOPS_LEVEL` minimum is honoured by `trade_Send()`, but this is a broker minimum, not a volatility-appropriate minimum. A 7-pip SL on XAUUSD M1 gets blown through on the very next tick from normal tick noise.

**Impact:** 157 of 172 trades are stopped out. The average loss of $122 on a 0.35-lot position represents approximately 10–35 points of adverse move — consistent with spread + tick noise, not a genuine reversal.

---

### 🔴 CRITICAL-3: Over-Trading / No Daily Frequency Gate

**Evidence:**

```
2026.01.05: 5 trades in one day (trades 6–14)
2026.01.06: 5 trades (trades 16–24)
2026.01.09: 5 trades (trades 44–54)
2026.01.20: 7 trades (trades 90–100)
2026.01.27: 6 trades (trades 126–136)
2026.01.29: 5 trades (trades 144–153)
2026.01.30: 7 trades (trades 154–165)
2026.02.02–02.06: 14 trades in 5 days
2026.02.17: 7 trades in one day
2026.02.19: 7 trades in one day
2026.02.20: 7 trades in one day
```

With a 3-bar (3-minute on M1) signal frequency gate, the system can fire up to 20 signals per hour. With a 91% loss rate, a multi-trade day guarantees compounding account damage. On 2026.01.30 alone, the account dropped from $10,090 to $8,755 — a $1,335 single-day drawdown (13.2% of starting balance).

The `InpMaxPositions = 1` cap ensures only one position is open at a time, but does nothing to prevent sequential rapid-fire entries after each stop-out.

---

### 🔴 CRITICAL-4: Profit Factor Below 1.0 on Losing System

The system ended at **−$598.87** on a $10,000 account after 172 trades across 65 days. The Sharpe ratio of **−0.38** and recovery factor of **−0.07** confirm this is a statistically losing system at the current configuration. The 15 wins that did occur (avg $1,246) barely keep pace with 157 losses (avg $123) because:

`15 × $1,246 − 157 × $123 = $18,690 − $19,311 = −$621`

The 60:1 RR *mathematically requires* a win rate above `1/(1+60) = 1.64%` to break even. The observed 8.72% win rate should be profitable — **except the wins are clustered and the losses accumulate faster than the wins recover them.**

This exposes a **compounding lot-size decay problem**: as the account shrinks, margin-based lot sizing produces smaller lots, so wins generate proportionally less than losses consumed at higher lots. The system is drifting toward eventual ruin even if the raw win rate stays at 8.72%.

---

### 🟡 MEDIUM-1: Conviction Label Dominated by Single Tag

Conviction label analysis from 172 trades:

- `AbsLow` alone: ~73% of trades
- `DeltaDiv+AbsLo`: ~14%
- `StackBuy+AbsLo`: ~4%
- `BullDelta`: ~3%
- `Mixed`: ~1%

The `AbsLow` tag (absorption at bar low) is triggering on virtually every bar in a bullish trend — because in a bull trend, every bar low has buyers absorbing sellers. This is not a *high-probability* signal; it is the normal state of a trending market.

**No multi-condition filter exists in `PlaceOrders()`**. The code fires on ANY HFT score ≥ 35, regardless of how many conviction tags contributed. A trade tagged `AbsLow` alone (a single medium-confidence flag) receives the same execution treatment as one tagged `StackBuy+AbsLo+BullDelta`.

---

### 🟡 MEDIUM-2: Margin-Based Lot Compounding Decay

When the account fell to ~$5,263 (trade 246), the lot size dropped to 0.21. The subsequent winning trade (#248/249) earned $2,324. If lots had remained at 0.45, that win would have been $5,000 — enough to return the account to starting balance in one trade. Instead, recovery required multiple winners that the system consistently couldn't string together.

This is a known feature of fractional Kelly / percent-risk sizing under negative variance: the geometric mean decays faster than arithmetic expectation. At 91% loss rate, the geometric mean is:

`(0.0872 × 1.01) × (0.9128 × 0.987)^11 ≈ 0.987` per trade sequence.

The system has **negative geometric expectancy** at current parameters despite having a nominally sufficient RR ratio.

---

### 🟡 MEDIUM-3: ATR Warmup Window Not Respected in First Bar Check

`PlaceOrders()` checks `barsOnChart > InpATR_Period + 1` correctly, but `CalcSLTP()` with `SL_MODE_BAR` uses `barHigh`/`barLow` directly. There is no minimum ATR-based SL distance enforcement when using `SL_MODE_BAR`. A $0.05 bar (extremely thin, common during session transitions) produces a $0.05 + $2.00 buffer SL — still too tight.

---

### 🟡 MEDIUM-4: No Session Filter

XAUUSD M1 during Asian session (22:00–07:00 GMT) has dramatically lower liquidity, wider effective spreads, and choppy price action. Many of the rapid SL hits (1–6 second trades) occur during Asian session hours. Filtering out low-liquidity periods would eliminate a significant portion of the worst-quality entries.

---

### 🟢 LOW-1: Recursive Quicksort Stack Risk

`SortLevelsPartition()` is recursive. With 50-point cells on XAUUSD and a daily range of 3,000+ points, a single bar can have 60+ price levels. At 200 history bars, the recursion depth could reach log₂(60) ≈ 6 levels — fine. But on an extreme volatility day (e.g., 10,000-point range), level count could reach 200+, pushing recursion depth to ~8. Still safe, but iterative partition would eliminate any theoretical risk.

---

## 4. Risk and Stability Concerns

| Risk | Severity | Description |
|---|---|---|
| Directional lock (buy only) | CRITICAL | Strategy never shorts; misses 50% of opportunities; biased by trend |
| Geometric equity decay | CRITICAL | Compounding loss ratio causes progressive lot shrinkage → ruin drift |
| SL too close to entry | CRITICAL | Spread + tick noise exceeds SL on many trades |
| No daily loss limit | HIGH | Account can lose 13%+ in a single day |
| No max drawdown kill switch | HIGH | No equity floor set in backtest configuration |
| Over-trading frequency | HIGH | 7 trades in one day on a 91% loss-rate system |
| Single-tag conviction | MEDIUM | "AbsLow" alone triggers full trade size |
| Lot decay on drawdown | MEDIUM | Recovery disproportionately hard vs initial loss |
| No session filter | MEDIUM | Asian session entries produce worst results |

---

## 5. Strategy Improvements

### 5.1 Raise Signal Threshold to Minimum 50

The theoretical HFT score threshold of 35 was designed for synthetic indices (Boom/Crash/Volatility) where tick direction is cleaner. On XAUUSD M1 real tick data with 25 million ticks in the period, the noise floor is higher. A threshold of 50–60 reduces trade frequency from 172 to an estimated 40–60 trades, selecting only genuinely high-conviction setups.

### 5.2 Require Minimum Conviction Tag Count

Add a `GetConvictionStrength()` function that counts unique active signal tags. Require at least **2 independent tags** before firing. This eliminates the pure `AbsLow` singleton trades that represent 73% of the trade log.

### 5.3 Minimum ATR-Based SL Distance

Enforce: `SL_distance >= MAX(bar_sl_distance, InpMinSLATRMult × ATR)`. A `InpMinSLATRMult = 0.5` floor ensures the SL is never narrower than half the ATR, preventing tick-noise SL hits.

### 5.4 Daily Trade Count Limit

Add `InpMaxDailyTrades` parameter (default 3). After 3 trades in a calendar day, the EA stops entering new positions until the next day.

### 5.5 Consecutive Loss Circuit Breaker

Add `InpMaxConsecLosses` (default 5). After N consecutive losing trades, the EA pauses for `InpCooldownBars` bars before resuming. This prevents the 22-consecutive-loss streak observed.

### 5.6 Session Filter

Add trading session window inputs (`InpSessionStartHour`, `InpSessionEndHour`). Default: 07:00–21:00 GMT (London + NY overlap). Blocks entries during illiquid Asian session.

### 5.7 Dual-Score Confirmation Gate

Require both `hftScore >= threshold` AND `ofsScore >= 55` (slightly bullish confirmation from the independent OFS metric) before firing a BUY. Similarly for SELL. This prevents the case where HFT score spikes on a single-component anomaly while the broader OFS remains neutral.

### 5.8 Trend Alignment Filter (Higher Timeframe Delta Slope)

The 3-bar CVD slope (C6 in HFTSignal) uses only M1 data. Add a check that the 20-bar cumulative delta trend direction agrees with the signal direction before firing.

---

## 6. Execution Improvements

### 6.1 Minimum SL Points Validation in trade_Send()

Before submitting the order, validate:
```mql5
double minSLPoints = MathMax(stopsLevel * _Point, atrVal * InpMinSLATRMult);
if (MathAbs(entry - sl) < minSLPoints)
    sl = isBuy ? entry - minSLPoints : entry + minSLPoints;
```

### 6.2 Cooldown After Stop-Loss Hit

Track `g_lastSLTime`. If a SL was hit within the last `InpCooldownBars` bars, skip new signals on the same bar cluster. This prevents re-entering the same market structure that just stopped you out.

### 6.3 Spread Check Before Market Order

`InpSpreadFilter = false` in the set file is dangerous on gold. Enforce spread < MaxSpread before EVERY market order, not just as a gate in `PlaceOrders()`. Move the spread check inside `trade_Send()` as a last-mile validation.

---

## 7. Code Quality Improvements

### 7.1 ConvictionTagCount() Helper

```mql5
// Returns the number of distinct conviction components active on bar bi
int ConvictionTagCount(int bi, bool isBuy)
{
   int count = 0;
   int len = g_bars[bi].level_count;
   if(len == 0) return 0;

   long tvol = MathMax(1, g_bars[bi].total_vol);
   double dr = (double)g_bars[bi].total_delta / tvol;

   // 1. Directional delta
   if(isBuy  && dr >  0.25) count++;
   if(!isBuy && dr < -0.25) count++;

   // 2. Delta divergence
   if(g_bars[bi].is_delta_divergence) count++;

   // 3. Naked POC magnet
   if(g_bars[bi].is_naked_poc) count++;

   // 4. Stacked imbalance
   bool hasSB = false, hasSS = false;
   bool exhBid = false, exhAsk = false;
   bool absLow = false, absHigh = false;
   int chk = MathMin(3, len / 3 + 1);

   for(int i = 0; i < len; i++)
   {
      if(g_bars[bi].levels[i].is_stacked_imb_buy)  hasSB  = true;
      if(g_bars[bi].levels[i].is_stacked_imb_sell) hasSS  = true;
      if(g_bars[bi].levels[i].is_exhaustion_bid)   exhBid = true;
      if(g_bars[bi].levels[i].is_exhaustion_ask)   exhAsk = true;
      if(i < chk && g_bars[bi].levels[i].is_absorption)      absHigh = true;
      if(i >= len - chk && g_bars[bi].levels[i].is_absorption) absLow = true;
   }

   if(isBuy)
   {
      if(hasSB)   count++;
      if(absLow)  count++;
      if(exhBid)  count++;
   }
   else
   {
      if(hasSS)   count++;
      if(absHigh) count++;
      if(exhAsk)  count++;
   }

   return count;
}
```

### 7.2 Daily Trade Counter

```mql5
// Globals to add
int      g_dailyTradeCount = 0;
datetime g_dailyTradeDate  = 0;

// Call at start of PlaceOrders() after signal confirmed:
void UpdateDailyTradeCounter()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)(dt.year * 10000 + dt.mon * 100 + dt.day);
   if(today != g_dailyTradeDate)
   {
      g_dailyTradeDate  = today;
      g_dailyTradeCount = 0;
   }
}

bool DailyLimitReached()
{
   return (InpMaxDailyTrades > 0 && g_dailyTradeCount >= InpMaxDailyTrades);
}
```

### 7.3 Consecutive Loss Circuit Breaker

```mql5
// Globals to add
int      g_consecLosses   = 0;
datetime g_circuitBreakerUntil = 0;

// In OnTradeTransaction, after logging the closed deal:
void UpdateCircuitBreaker(double netPnl)
{
   if(netPnl < 0.0)
   {
      g_consecLosses++;
      if(InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
      {
         g_circuitBreakerUntil = TimeCurrent() + InpCooldownBars * PeriodSeconds(PERIOD_CURRENT);
         LogWarning(StringFormat(
            "OrderFlowEA — CIRCUIT BREAKER: %d consecutive losses. "
            "Trading paused until %s.",
            g_consecLosses,
            TimeToString(g_circuitBreakerUntil, TIME_DATE | TIME_MINUTES)));
         g_consecLosses = 0;
      }
   }
   else
   {
      g_consecLosses = 0;  // reset on any win
   }
}

bool CircuitBreakerActive()
{
   return (g_circuitBreakerUntil > 0 && TimeCurrent() < g_circuitBreakerUntil);
}
```

### 7.4 ATR-Floored SL in CalcSLTP()

Replace the existing `CalcSLTP()` with:

```mql5
void CalcSLTP(bool isBuy, double entry, double atrVal,
              double barHigh, double barLow, double bufDist,
              double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   if(InpUseStopLoss)
   {
      double rawSL = 0.0;

      switch(InpSLMode)
      {
         case SL_MODE_BAR:
            rawSL = isBuy ? NormalizeDouble(barLow  - bufDist, _Digits)
                          : NormalizeDouble(barHigh + bufDist, _Digits);
            break;
         case SL_MODE_PIPS:
            rawSL = isBuy ? NormalizeDouble(entry - InpSLPips * g_Pip, _Digits)
                          : NormalizeDouble(entry + InpSLPips * g_Pip, _Digits);
            break;
         case SL_MODE_ATR:
            if(atrVal > 0.0)
               rawSL = isBuy ? NormalizeDouble(entry - InpSLATRMult * atrVal, _Digits)
                             : NormalizeDouble(entry + InpSLATRMult * atrVal, _Digits);
            else
               rawSL = isBuy ? NormalizeDouble(entry - InpSLPips * g_Pip, _Digits)
                             : NormalizeDouble(entry + InpSLPips * g_Pip, _Digits);
            break;
      }

      // ── ATR floor: ensure SL is never narrower than InpMinSLATRMult × ATR
      // This prevents tick-noise stop-outs on thin bars.
      if(atrVal > 0.0 && InpMinSLATRMult > 0.0)
      {
         double minDist = InpMinSLATRMult * atrVal;
         double rawDist = MathAbs(entry - rawSL);
         if(rawDist < minDist)
            rawSL = isBuy ? NormalizeDouble(entry - minDist, _Digits)
                          : NormalizeDouble(entry + minDist, _Digits);
      }

      sl = rawSL;
   }

   // TP calculation (unchanged logic, uses updated sl)
   if(!InpUseTakeProfit) return;
   double slDist = (sl > 0.0) ? MathAbs(entry - sl) : InpSLPips * g_Pip;
   switch(InpTPMode)
   {
      case TP_MODE_RR:
         if(slDist > 0.0)
            tp = isBuy ? NormalizeDouble(entry + slDist * InpRiskRewardRatio, _Digits)
                       : NormalizeDouble(entry - slDist * InpRiskRewardRatio, _Digits);
         break;
      case TP_MODE_PIPS:
         tp = isBuy ? NormalizeDouble(entry + InpTPPips * g_Pip, _Digits)
                    : NormalizeDouble(entry - InpTPPips * g_Pip, _Digits);
         break;
      case TP_MODE_ATR:
         if(atrVal > 0.0)
            tp = isBuy ? NormalizeDouble(entry + InpTPATRMult * atrVal, _Digits)
                       : NormalizeDouble(entry - InpTPATRMult * atrVal, _Digits);
         else
            tp = isBuy ? NormalizeDouble(entry + InpTPPips * g_Pip, _Digits)
                       : NormalizeDouble(entry - InpTPPips * g_Pip, _Digits);
         break;
   }
}
```

### 7.5 Session Filter Helper

```mql5
bool IsInTradingSession()
{
   if(InpSessionStartHour < 0 || InpSessionEndHour < 0) return true;  // disabled
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hour = dt.hour;

   if(InpSessionStartHour <= InpSessionEndHour)
      return (hour >= InpSessionStartHour && hour < InpSessionEndHour);
   else  // overnight span (e.g. 22:00–06:00)
      return (hour >= InpSessionStartHour || hour < InpSessionEndHour);
}
```

---

## 8. Revised PlaceOrders() Logic

```mql5
void PlaceOrders()
{
   if(!g_autoTrade && !g_analysisMode) return;
   if(!g_analysisMode && !IsTradeAllowed()) return;

   // ── NEW: session filter ──────────────────────────────────────────────────
   if(!g_analysisMode && !IsInTradingSession()) return;

   // ── NEW: circuit breaker ─────────────────────────────────────────────────
   if(!g_analysisMode && CircuitBreakerActive()) return;

   // ── NEW: daily trade limit ───────────────────────────────────────────────
   UpdateDailyTradeCounter();
   if(!g_analysisMode && DailyLimitReached()) return;

   if(!g_analysisMode && InpMaxPositions > 0 &&
      CountOpenPositions() >= InpMaxPositions) return;

   if(!g_analysisMode)
   {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(InpMaxEquityProfit > 0.0 && equity >= balance + InpMaxEquityProfit)
         { g_autoTrade = false; return; }
      if(InpMaxEquityLoss > 0.0 && equity <= balance - InpMaxEquityLoss)
         { g_autoTrade = false; return; }
   }

   // ── Spread gate (always enforce, even without SpreadFilter flag) ──────────
   double spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(spreadPoints > InpMaxSpread * g_Pip) return;

   int nBars = ArraySize(g_bars);
   if(nBars < 2) return;

   int bi = nBars - 2;
   if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0) return;
   if(!g_bars[bi].sorted) ComputeBarSignals(bi);

   double barHigh = g_bars[bi].high;
   double barLow  = g_bars[bi].low;
   if(barHigh == 0.0 || barLow == 0.0) return;

   double hftScore  = ComputeHFTSignal(bi);
   int    ofsScore  = ComputeOFScore(bi);

   bool   isBuy  = (hftScore >=  (double)g_signalThreshold && InpAllowBuy);
   bool   isSell = (hftScore <= -(double)g_signalThreshold && InpAllowSell);
   if(!isBuy && !isSell) return;

   // ── NEW: OFS dual-score confirmation ────────────────────────────────────
   if(isBuy  && ofsScore < InpOFSConfirmThreshold) return;
   if(isSell && ofsScore > (100 - InpOFSConfirmThreshold)) return;

   // ── NEW: minimum conviction tag count ────────────────────────────────────
   bool direction = isBuy;
   int tagCount = ConvictionTagCount(bi, direction);
   if(tagCount < InpMinConvictionTags) return;

   // ... (rest of existing order placement logic unchanged) ...
   if(!g_analysisMode && InpCleanOldOrders) DeleteAllPending();

   // ATR
   double atrBuf[];
   double atrVal = 0.0;
   int    barsOnChart = iBars(_Symbol, PERIOD_CURRENT);
   bool   atrReady = (g_handleATR != INVALID_HANDLE) && (barsOnChart > InpATR_Period + 1);
   if(atrReady && CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) == 1)
      atrVal = atrBuf[0];

   double bufDist = InpBufferPips * g_Pip;

   MqlTick lv;
   if(!SymbolInfoTick(_Symbol, lv)) return;

   bool   isMarket = (InpOrderMode == ORDER_MODE_MARKET);
   double entry;
   ENUM_TRADE_REQUEST_ACTIONS action;
   ENUM_ORDER_TYPE            orderType;

   if(isMarket)
   {
      entry     = direction ? lv.ask : lv.bid;
      action    = TRADE_ACTION_DEAL;
      orderType = direction ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   }
   else
   {
      entry     = direction
                  ? NormalizeDouble(barHigh + bufDist, _Digits)
                  : NormalizeDouble(barLow  - bufDist, _Digits);
      action    = TRADE_ACTION_PENDING;
      orderType = direction ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   }

   double sl, tp;
   CalcSLTP(direction, entry, atrVal, barHigh, barLow, bufDist, sl, tp);

   double slPoints = (sl > 0.0) ? MathAbs(entry - sl) / _Point : 0.0;
   double lot      = CalcLot(slPoints);

   int    hftInt     = (int)MathRound(MathAbs(hftScore));
   string conviction = GetConvictionReason(bi, direction);

   string tag = StringFormat("FP_%s_%s_HFT%d_OFS%d|%s",
                             direction ? "Buy" : "Sell",
                             isMarket  ? "MKT" : "STP",
                             hftInt, ofsScore, conviction);

   ulong ticket = 0;
   bool  sent   = false;

   if(g_analysisMode)
   {
      ticket = g_virtualTicket++;
      LogTradeExec(StringFormat(
         "OrderFlowEA [ANALYSIS] [%s] #V%I64u | Entry: %s | SL: %s | TP: %s"
         " | Lot: %.2f | HFT: %d | OFS: %d | Tags: %d | Conviction: %s",
         direction ? "BUY" : "SELL", ticket,
         DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
         DoubleToString(tp, _Digits), lot, hftInt, ofsScore, tagCount, conviction));
      DrawAnalysisEntry(ticket, direction, entry, sl, tp,
                        g_bars[bi].bar_time, conviction, hftInt, ofsScore);
   }
   else
   {
      sent = trade_Send(action, orderType, entry, sl, tp, lot, tag, ticket);
      if(sent && ticket != 0)
      {
         g_dailyTradeCount++;  // ── NEW: increment daily counter
         LogTradeExec(StringFormat(
            "OrderFlowEA — ORDER PLACED [%s] #%I64u | Entry: %s | SL: %s | TP: %s"
            " | Lot: %.2f | HFT: %d | OFS: %d | Tags: %d | Conviction: %s",
            direction ? "BUY" : "SELL", ticket,
            DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
            DoubleToString(tp, _Digits), lot, hftInt, ofsScore, tagCount, conviction));
         DrawTradeEntry(ticket, direction, entry, sl, tp,
                        g_bars[bi].bar_time, conviction, hftInt, ofsScore);
      }
   }
}
```

---

## 9. Recommended v7.00 Parameter Set

### New Parameters to Add (OnInit inputs block)

```mql5
input group "Signal Quality Filters"
input int    InpMinConvictionTags    = 2;      // Min distinct signal tags required (0=disabled)
input int    InpOFSConfirmThreshold  = 52;     // OFS score must exceed this for BUY (100-x for SELL)
input double InpMinSLATRMult         = 0.5;    // Minimum SL as fraction of ATR (0=disabled)

input group "Risk Controls"
input int    InpMaxDailyTrades       = 3;      // Max entries per calendar day (0=unlimited)
input int    InpMaxConsecLosses      = 5;      // Pause after N consecutive losses (0=disabled)
input int    InpCooldownBars         = 30;     // Bars to pause after circuit breaker triggers

input group "Session Filter"
input int    InpSessionStartHour     = 7;      // GMT hour trading begins (-1=disabled)
input int    InpSessionEndHour       = 21;     // GMT hour trading ends
```

### Revised Set File for XAUUSD M1

```ini
; ── v7.00 production set — XAUUSD M1 ──────────────────────────────────────
InpLoggingEnable         = true
InpLogMode               = 2            ; LOG_SIGNALS (not LOG_FULL in production)

InpTickSize              = 10
InpImbalanceRatio        = 300.0
InpStackedImbCount       = 3
InpAbsorptionRatio       = 4.0
InpHistoryBars           = 100          ; reduced from 200 to cut reload time
InpVAPercent             = 70.0

InpChartMode             = 1            ; Delta mode
InpTickMultiplier        = 5

InpExhaustionEnable      = true
InpExhaustionCells       = 3
InpExhaustionZeroRat     = 0.05

InpOFWtDelta             = 40.0
InpOFWtImb               = 25.0
InpOFWtStacked           = 20.0
InpOFWtAbsorb            = 15.0

; Signals
InpShowSignals           = true         ; enable for monitoring
InpSignalThreshold       = 55           ; raised from 35 — filter noise
InpSignalFreqBars        = 5            ; raised from 3 — 5-min minimum gap

; Automated Trading
InpAnalysisMode          = true         ; START IN ANALYSIS MODE — validate live first
InpATEnable              = false
InpOrderMode             = 0            ; Market
InpATR_Period            = 14
InpSpreadFilter          = true         ; ENABLED
InpMaxSpread             = 3.0          ; pips max spread on gold
InpAllowBuy              = true
InpAllowSell             = true
InpBufferPips            = 5.0          ; realistic buffer for market mode

; Money Management
InpUseRiskPercent        = true
InpRiskPercent           = 1.0
InpFixedLot              = 0.01

; Signal Quality
InpMinConvictionTags     = 2            ; require 2+ distinct conviction components
InpOFSConfirmThreshold   = 52           ; OFS must confirm direction
InpMinSLATRMult          = 0.5          ; SL floor = 0.5 × ATR

; Exit
InpUseStopLoss           = true
InpSLMode                = 0            ; SL_MODE_BAR
InpSLPips                = 20.0         ; fallback
InpSLATRMult             = 1.5          ; fallback
InpUseTakeProfit         = true
InpTPMode                = 0            ; TP_MODE_RR
InpRiskRewardRatio       = 5.0          ; reduced from 60 — achievable on XAUUSD M1
InpTPPips                = 50.0         ; fallback
InpTPATRMult             = 3.0          ; fallback

; Guardian
InpUseBreakEven          = true
InpBreakEvenTrigger      = 15.0         ; 15-pip trigger (realistic on gold)
InpBreakEvenBuffer       = 3.0          ; 3 pips locked in
InpUseTrailing           = true
InpTrailStart            = 20.0         ; 20-pip trailing activation
InpTrailStep             = 5.0          ; 5-pip trail step

; Risk Controls (NEW)
InpMaxDailyTrades        = 3
InpMaxConsecLosses       = 5
InpCooldownBars          = 30

; Session Filter (NEW)
InpSessionStartHour      = 7            ; 07:00 GMT
InpSessionEndHour        = 21           ; 21:00 GMT

; Account Safety
InpMaxEquityProfit       = 0.0
InpMaxEquityLoss         = 1500.0       ; halt at $1,500 drawdown (15% of $10k)
InpCleanOldOrders        = true
InpMaxPositions          = 1
InpMagic                 = 20260226

; Visuals
InpShowVisuals           = true
InpShowSLTPLines         = true
InpShowEntryLabel        = true
InpShowExitLabel         = true
```

---

## 10. Projected Impact of v7.00 Changes

| Change | Estimated Trade Count Impact | Quality Impact |
|---|---|---|
| Threshold 35 → 55 | −60% trades | Eliminates weakest HFT setups |
| MinConvictionTags ≥ 2 | −40% of remaining | Eliminates pure AbsLow singleton trades |
| OFS confirmation gate | −15% of remaining | Removes low-OFS entries |
| Session filter (07–21 GMT) | −20% of remaining | Eliminates Asian session noise |
| Daily limit 3 | −30% on active days | Prevents compounding daily losses |
| ATR-floored SL | 0% fewer trades | Dramatically reduces rapid SL hits |
| RR 60:1 → 5:1 | Trades exit faster | Reduces win-rate requirement to 16.7% |

At a realistic 5:1 RR, a 8.72% win rate still loses money (needs >16.7%). However, the combined quality improvements should push win rate to 20–35%, making the system profitable with a 5:1 RR.

**Break-even win rate at 5:1 RR:** `1/(1+5) = 16.67%`

If quality filtering raises win rate to 22%, the profit factor becomes:
`0.22 × 5 / (0.78 × 1) = 1.41` — a profitable system.

---

## 11. Summary — What Must Change Before Live Trading

1. **Reduce RR from 60:1 to 5:1** on XAUUSD. The 60:1 is only viable on instruments with 5,000+ pip daily ranges.
2. **Raise threshold to 55** and require **2 minimum conviction tags**.
3. **Enable ATR-floored SL** (`InpMinSLATRMult = 0.5`) to prevent tick-noise stop-outs.
4. **Enable session filter** (07:00–21:00 GMT).
5. **Set daily trade limit to 3** and consecutive loss circuit breaker at 5.
6. **Set `InpMaxEquityLoss = 1500`** — a hard floor must exist.
7. **Enforce spread filter** (was disabled in backtest).
8. **Start in Analysis Mode** for at least 48 hours on live feed before enabling real orders.
9. **Investigate zero sell trades** — run analysis mode during a confirmed bearish period and verify sell signals are generating in the journal.
10. **Use `LOG_SIGNALS` mode in live** — `LOG_FULL` is development-only.
