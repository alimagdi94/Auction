//+------------------------------------------------------------------+
//|  OrderFlowEA_v605.mq5                                            |
//|  Order Flow EA — Pure Trading Engine v6.05                        |
//|  No canvas, no UI objects — Journal + chart markers only          |
//|                                                                    |
//|  Production fixes from v6.04:                                     |
//|  [FIX-DRAW] EvalAndFireSignal(): signals were never drawn on the  |
//|    chart. Chart drawing only existed inside PlaceOrders(), which  |
//|    requires InpATEnable=true or InpAnalysisMode=true.  With both  |
//|    off, every fired signal was invisible on the chart despite     |
//|    appearing in the journal.                                      |
//|    Fix: new DrawSignalMarker() function draws a labelled arrow    |
//|    directly from EvalAndFireSignal() whenever InpShowVisuals is   |
//|    true — fully independent of auto-trading state.  Objects use  |
//|    the "SIG_" prefix so they are managed separately from trade    |
//|    markers (FP_) and analysis markers (AN_).                     |
//|                                                                    |
//|  never fire a SELL signal during backtesting):                    |
//|                                                                    |
//|  [FIX-SELL-1] Classify(): CRITICAL sell-signal backtest bug.      |
//|    The original code had `else isBuy = true` as a tie-break for  |
//|    neutral ticks (bid unchanged).  In MT5 backtesting on FX /    |
//|    synthetic instruments, the tester delivers thin tick data:     |
//|    many consecutive ticks share the SAME bid price.  Every one   |
//|    of those neutral ticks hit the else-branch and was silently    |
//|    force-classified as Buy.  This poisoned total_delta,          |
//|    OFScore, and HFTSignal into permanent positive territory,      |
//|    making the `hftScore <= -threshold` sell condition             |
//|    mathematically unreachable in backtest.  Live trading worked   |
//|    because the real-tick path (g_hasTrades=true) uses the proper  |
//|    TICK_FLAG_BUY / TICK_FLAG_SELL flags.                          |
//|    Fix: neutral ticks (bid unchanged) are now classified as       |
//|    neither buy nor sell — they are ignored in delta accounting,   |
//|    which is the correct order-flow interpretation.                |
//|                                                                    |
//|  [FIX-SELL-2] Classify(): uninitialised g_prevBid guard.         |
//|    When g_prevBid == 0.0 (EA just attached), any positive bid    |
//|    satisfies `t.bid > g_prevBid` → first tick is always Buy.     |
//|    Fix: classification is skipped when g_prevBid is uninitialised.|
//|                                                                    |
//|  [FIX-SELL-3] ReloadHistory(): signal-eval cache not cleared.    |
//|    g_sigCacheBarIdx and g_sigCacheVol were never reset on reload. |
//|    After a reload the stale cache could permanently suppress the  |
//|    first signal evaluation if bi and total_vol coincidentally     |
//|    matched the pre-reload values.                                 |
//|    Fix: both cache sentinels are reset to -1 in ReloadHistory().  |
//|                                                                    |
//|  [FIX-SELL-4] Signal frequency gate: array-index vs bar-time.    |
//|    g_lastSignalBar stored a raw g_bars[] array index.  After a   |
//|    ReloadHistory() the array is rebuilt with fewer bars, so the   |
//|    new bi could be numerically smaller than g_lastSignalBar and   |
//|    the cooldown could block signals indefinitely.                  |
//|    Fix: frequency gate now uses g_lastSignalBarTime (datetime),   |
//|    comparing elapsed bars by time lookup — robust across reloads. |
//|                                                                    |
//|  Production changes from v6.02 (core logic unchanged):            |
//|  [ANALYSIS-MODE] New "Analysis Mode" input (InpAnalysisMode).    |
//|    When enabled, the EA runs the full signal pipeline and draws   |
//|    virtual trade markers (entry arrow, SL/TP lines, label) using  |
//|    the "AN_" object namespace, but never submits a real order.    |
//|    Analysis objects are NOT deleted on deinit, so the markup      |
//|    accumulates across restarts for a clean backlog of signals.    |
//|    Each virtual trade receives a unique incrementing ID starting  |
//|    at 900 000 000 to avoid collisions with live broker tickets.   |
//|                                                                    |
//|  Changes from v6.01 (core logic unchanged):                       |
//|  [FIX-1]  PlaceOrders: moved barHigh/barLow zero-guard to the     |
//|           top of the function, BEFORE DeleteAllPending(), so       |
//|           stale pending orders are never wiped on a degenerate bar.|
//|  [FIX-2]  DeleteAllPending: snapshot all tickets into a local      |
//|           array first, then delete — prevents index invalidation   |
//|           as OrdersTotal() shrinks during the loop.                |
//|  [FIX-3]  OnChartEvent: replaced inline ReloadHistory() with       |
//|           g_needs_reload = true so the event handler is never      |
//|           blocked by a potentially long tick-history fetch.         |
//|  [FIX-4]  PlaceOrders: ATR warmup guard — CopyBuffer is only       |
//|           trusted after InpATR_Period bars have closed.            |
//|  [FIX-5]  GetBrokerFillingMode: explicit SYMBOL_FILLING_RETURN     |
//|           flag check; log a warning if the broker flag is absent.  |
//|  [FIX-6]  InsertBar: removed the redundant slot initialisation     |
//|           that preceded the shift loop in the mid-insert path.     |
//|  [FIX-7]  DrawTradeEntry / DrawTradeExit: added ChartRedraw()      |
//|           so objects appear immediately without waiting for the     |
//|           next natural repaint cycle.                              |
//|  [FIX-8]  OnInit: added validation for InpStackedImbCount >= 1,   |
//|           InpExhaustionCells >= 1 (when exhaustion is enabled),    |
//|           InpAbsorptionRatio > 0, and OFS weight sum > 0.          |
//|  [FIX-9]  CalcLot: renamed the unused slPoints parameter to        |
//|           slPointsUnused with an explanatory comment, making the   |
//|           intentional design decision explicit.                    |
//|  [FIX-10] ComputeOFScore / ComputeHFTSignal: added                |
//|           MathIsValidNumber() guards before each ratio division    |
//|           to prevent NaN/Inf propagating into the final score.     |
//|  [FIX-11] CalcLot: replaced the SL-pips-dependent tick-value      |
//|           formula with a margin-based approach.  OrderCalcMargin() |
//|           is called for 1.0 lot at the current Ask; the lot is     |
//|           AllocationAmount / MarginFor1Lot.  This produces an      |
//|           asset-specific lot on every instrument (FX, synthetics,  |
//|           indices) without requiring a Stop Loss distance.          |
//|           OnInit: removed the now-redundant guard that required    |
//|           InpSLPips > 0 when InpUseRiskPercent was enabled.        |
//+------------------------------------------------------------------+
#property copyright   "Ali Magdy"
#property version     "6.05"
#property description "Order Flow EA v6.05 — Footprint signals + Automated Trading + Analysis Mode (pure)"
#property strict

//==========================================================================
// SECTION 1: ENUMERATIONS
//==========================================================================

enum ENUM_FOOT_CHART_MODE
  {
   FOOT_CHART_VOLUME = 0,   // Volume per price level
   FOOT_CHART_DELTA  = 1,   // Delta (Ask-Bid) per price level
   FOOT_CHART_BIDASK = 2    // Bid x Ask cluster
  };

enum ENUM_ORDER_MODE
  {
   ORDER_MODE_MARKET  = 0,  // Market Order — fills instantly at current Ask/Bid
   ORDER_MODE_PENDING = 1   // Pending Order — BuyStop / SellStop above/below bar
  };

enum ENUM_SL_MODE
  {
   SL_MODE_BAR  = 0,  // Bar High/Low + Buffer
   SL_MODE_PIPS = 1,  // Fixed Pips
   SL_MODE_ATR  = 2   // ATR Multiplier
  };

enum ENUM_TP_MODE
  {
   TP_MODE_RR   = 0,  // Risk:Reward Ratio
   TP_MODE_PIPS = 1,  // Fixed Pips
   TP_MODE_ATR  = 2   // ATR Multiplier
  };

enum ENUM_LOG_MODE
  {
   LOG_SILENT      = 0, // No output whatsoever
   LOG_TRADES_ONLY = 1, // Closed trade results only (entry, exit, P&L)
   LOG_SIGNALS     = 2, // Signals + closed trades + execution errors
   LOG_FULL        = 3  // Everything: system, warnings, signals, trades
  };

//==========================================================================
// SECTION 2: INPUTS
//==========================================================================

input group "Logging"
input bool          InpLoggingEnable = true;           // Master switch: enable all journal logging
input ENUM_LOG_MODE InpLogMode       = LOG_FULL;       // Logging mode (Silent / Trades Only / Signals / Full)

input group "Data & History"
input int    InpTickSize        = 10;      // Base cell size (points)
input double InpImbalanceRatio  = 300.0;   // Imbalance Threshold (%)
input int    InpStackedImbCount = 3;       // Stacked Imbalance Min Count
input double InpAbsorptionRatio = 4.0;     // Absorption Threshold (x Avg Vol)
input int    InpHistoryBars     = 100;     // History bars to load
input double InpVAPercent       = 70.0;    // Value Area % (industry default 70)
input double InpHVNRatio        = 2.0;     // HVN Threshold (x Avg Vol)
input double InpLVNRatio        = 0.35;    // LVN Threshold (ratio of Avg Vol)

input group "Aggregation"
input ENUM_FOOT_CHART_MODE InpChartMode      = FOOT_CHART_DELTA; // Chart mode
input int                  InpTickMultiplier = 5;                // Tick multiplier (1..40)

input group "Bid/Ask Exhaustion Signal"
input bool   InpExhaustionEnable  = true;  // Enable bid/ask exhaustion detection
input int    InpExhaustionCells   = 3;     // Consecutive near-zero cells required
input double InpExhaustionZeroRat = 0.05;  // Near-zero threshold (fraction of avg vol)

input group "Order Flow Strength Score"
input double InpOFWtDelta         = 40.0;  // OFS weight: delta ratio (%)
input double InpOFWtImb           = 25.0;  // OFS weight: imbalance count (%)
input double InpOFWtStacked       = 20.0;  // OFS weight: stacked imbalance (%)
input double InpOFWtAbsorb        = 15.0;  // OFS weight: absorption (%)

input group "High Probability Signals"
input bool   InpShowSignals       = true;  // Enable signal evaluation
input int    InpSignalThreshold   = 60;    // Score Threshold (Buy >= thresh, Sell <= 100-thresh)
input int    InpSignalFreqBars    = 3;     // Min bars between repeated signals
input string InpSignalBuySound    = "alert.wav";   // Buy signal sound file
input string InpSignalSellSound   = "alert2.wav";  // Sell signal sound file


input group "Automated Trading — Strategy"
input bool          InpAnalysisMode      = false;             // Analysis Mode: draw virtual trades, no real orders
input bool          InpATEnable          = false;              // Master switch: enable automated trading
input ENUM_ORDER_MODE InpOrderMode       = ORDER_MODE_MARKET;  // Order mode: Market or Pending
input int           InpATR_Period        = 14;                 // ATR lookback period
input bool          InpSpreadFilter      = true;               // Block entries during high spread
input double        InpMaxSpread         = 3.0;                // Maximum allowable spread (Pips)
input bool          InpAllowBuy          = true;               // Allow BUY entries
input bool          InpAllowSell         = true;               // Allow SELL entries
input double        InpBufferPips        = 2.0;                // Pending entry distance (Pips)

input group "Automated Trading — Money Management"
input bool   InpUseRiskPercent    = true;   // true = dynamic risk sizing, false = fixed lot
input double InpRiskPercent       = 1.0;    // % of account balance to risk per trade
input double InpFixedLot          = 0.01;   // Fixed lot size

input group "Automated Trading — Exit"
input bool          InpUseStopLoss      = true;         // Enable hard stop-loss
input ENUM_SL_MODE  InpSLMode           = SL_MODE_BAR;  // Stop Loss mode
input double        InpSLPips           = 20.0;         // [SL: Fixed Pips] distance
input double        InpSLATRMult        = 1.5;          // [SL: ATR] multiplier

input bool          InpUseTakeProfit    = true;         // Enable hard take-profit
input ENUM_TP_MODE  InpTPMode           = TP_MODE_RR;   // Take Profit mode
input double        InpRiskRewardRatio  = 2.0;          // [TP: RR] ratio
input double        InpTPPips           = 40.0;         // [TP: Fixed Pips] distance
input double        InpTPATRMult        = 3.0;          // [TP: ATR] multiplier

input group "Automated Trading — The Guardian"
input bool   InpUseBreakEven      = true;   // Auto-move SL to break-even after trigger
input double InpBreakEvenTrigger  = 15.0;   // Pips profit required to trigger break-even
input double InpBreakEvenBuffer   = 1.0;    // Pips above entry locked in
input bool   InpUseTrailing       = true;   // Enable dynamic trailing stop
input double InpTrailStart        = 20.0;   // Pips profit required to start trailing
input double InpTrailStep         = 5.0;    // Trail heartbeat (Pips)

input group "Automated Trading — Account Safety"
input double InpMaxEquityProfit   = 0.0;    // Hard profit target in account currency (0 = disabled)
input double InpMaxEquityLoss     = 0.0;    // Hard drawdown limit in account currency (0 = disabled)
input bool   InpCleanOldOrders    = true;   // Delete stale pending orders on new signal
input int    InpMaxPositions      = 1;      // Max concurrent open positions (0 = unlimited)
input ulong  InpMagic             = 20260226; // EA magic number

input group "Visuals"
input bool  InpShowVisuals     = true;              // Master switch: draw trade markers on chart
input bool  InpShowSLTPLines   = true;              // Show SL / TP horizontal dotted lines
input bool  InpShowEntryLabel  = true;              // Show conviction + score label at entry
input bool  InpShowExitLabel   = true;              // Show net P&L label at exit
input color InpVizBuyColor     = clrDodgerBlue;     // Buy arrow / label color
input color InpVizSellColor    = clrOrangeRed;      // Sell arrow / label color
input color InpVizSLColor      = clrFireBrick;      // Stop Loss line color
input color InpVizTPColor      = clrMediumSeaGreen; // Take Profit line color

//==========================================================================
// SECTION 3: DATA STRUCTURES
//==========================================================================

struct PriceLevel
  {
   double price;
   long   bid_vol;
   long   ask_vol;
   long   total_vol;
   long   delta;
   bool   is_imb_buy;
   bool   is_imb_sell;
   bool   is_absorption;
   bool   is_stacked_imb_buy;
   bool   is_stacked_imb_sell;
   bool   is_unfinished_hi;
   bool   is_unfinished_lo;
   bool   is_hvn;
   bool   is_lvn;
   bool   is_exhaustion_bid;
   bool   is_exhaustion_ask;
  };

struct FPBar
  {
   datetime   bar_time;
   long       total_vol;
   long       total_delta;
   double     high;
   double     low;
   int        poc_idx;
   int        va_lo_idx;
   int        va_hi_idx;
   bool       sorted;
   bool       is_bullish;
   int        level_count;
   bool       is_delta_divergence;
   bool       is_naked_poc;
   PriceLevel levels[];
  };

//==========================================================================
// SECTION 4: GLOBALS
//==========================================================================

// --- Core data state ---
FPBar  g_bars[];
double g_step;
double g_baseStep;
int    g_basePts  = 10;
int    g_tickMult = 1;
long   g_chart;
bool   g_hasTrades;
double g_prevBid;
double g_imbRatio;
long   g_last_tick_time_ms = 0;
bool   g_needs_reload      = false;
int    g_histBars          = 100;
double g_vaPercent         = 0.0;

// --- Signal state ---
bool     g_signalsEnabled    = true;
int      g_signalFreqBars    = 3;
int      g_signalThreshold   = 60;
int      g_lastSignalBar     = -9999;   // kept for legacy; frequency now uses time
datetime g_lastSignalBarTime = 0;       // [FIX-SELL-4] bar-time of last fired signal

// --- Automated trading state ---
bool     g_autoTrade   = false;
ulong    g_Magic       = 20260226;
datetime g_LastBarTime = 0;
int      g_handleATR   = INVALID_HANDLE;
double   g_Pip         = 0.0001;
double   g_VolMin      = 0.01;
double   g_VolMax      = 100.0;
double   g_VolStep     = 0.01;

// --- Analysis Mode state ---
//  Objects use the "AN_" namespace so they are never swept by
//  CleanupAllTradeObjects() (which only removes "FP_" objects),
//  giving the user a permanent accumulating signal diary.
bool  g_analysisMode  = false;
ulong g_virtualTicket = 900000000UL; // Start far above typical broker ticket range

// --- Signal marker state (drawn by EvalAndFireSignal, "SIG_" prefix) ---
//  [FIX-DRAW] Signal arrows are drawn independently of auto-trading.
//  Counter starts at 800 000 000 to avoid collisions with broker tickets
//  (live range) and virtual analysis tickets (900 000 000+).
ulong g_sigMarkerCount = 800000000UL;

// --- Performance caches ---
int   g_sigCacheBarIdx   = -1;   // bar index of last signal evaluation
long  g_sigCacheVol      = -1;   // total_vol at last evaluation (cache key)
ulong g_lastManageTick   = 0;    // GetTickCount64() at last ManagePositions run

#define FP_HIST_MIN        1
#define FP_HIST_MAX        5000
#define FP_MANAGE_THROTTLE 250   // ManagePositions minimum interval (ms)

//==========================================================================
// SECTION 5: LOGGING HELPERS
//==========================================================================
//
//  Five thin wrappers — each maps to a category so the mode enum drives
//  exactly what reaches the journal. The master switch short-circuits all
//  of them before any string is built, keeping silent-mode overhead zero.
//
//  Category → visible in these modes:
//    LogSystem      FULL only              (init summary, deinit, history)
//    LogWarning     FULL only              (non-fatal: ATR=0, tick value, permissions)
//    LogSignal      SIGNALS | FULL         (BUY/SELL signal fired)
//    LogTradeExec   SIGNALS | FULL         (order send result, skips, SL modify)
//    LogTradeClosed TRADES_ONLY | SIGNALS | FULL  (closed deal P&L)
//
void LogSystem(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_FULL) return;
   Print(msg);
  }

void LogWarning(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_FULL) return;
   Print("[WARN] ", msg);
  }

void LogSignal(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_SIGNALS) return;
   Print("[SIGNAL] ", msg);
  }

void LogTradeExec(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_SIGNALS) return;
   Print("[EXEC] ", msg);
  }

void LogTradeClosed(const string msg)
  {
   if(!InpLoggingEnable || InpLogMode < LOG_TRADES_ONLY) return;
   Print("[TRADE] ", msg);
  }

//==========================================================================
// SECTION 6: VISUAL HELPERS
//==========================================================================
//
//  Minimal, industry-standard chart markers:
//    • Entry arrow   (filled triangle, direction-coloured)
//    • SL / TP lines (horizontal dotted, labelled via tooltip)
//    • Entry label   (conviction reasons + HFT/OFS scores, same bar anchor)
//    • Exit arrow    (opposite colour, green = win / red = loss)
//    • Exit label    (net P&L with sign)
//
//  All objects share the "FP_" prefix so CleanupAllTradeObjects() can
//  sweep them in a single pass without maintaining a separate list.
//
//  Every function is a no-op when InpShowVisuals is false, so toggling
//  the input removes all overhead at runtime (no allocation, no draw call).
//

//--- Uniform object-name builder: "FP_<prefix>_<ticket>"
string ObjName(const string prefix, ulong ticket)
  {
   return StringFormat("FP_%s_%I64u", prefix, ticket);
  }

//--- Extract the top-3 conviction drivers from already-computed bar signals.
//    Reads bar flags directly — no recomputation of HFT components.
string GetConvictionReason(int bi, bool isBuy)
  {
   string tags[7];
   int    n   = 0;
   int    len = g_bars[bi].level_count;

   // 1. Delta divergence — highest-trust reversal flag
   if(g_bars[bi].is_delta_divergence) tags[n++] = "DeltaDiv";

   // 2. Strong net delta momentum
   if(g_bars[bi].total_vol > 0)
     {
      double dr = (double)g_bars[bi].total_delta / (double)g_bars[bi].total_vol;
      if(dr >  0.35)  tags[n++] = "BullDelta";
      else if(dr < -0.35)  tags[n++] = "BearDelta";
     }

   // 3. Scan levels for directional flags (single pass)
   bool hasSB = false, hasSS = false;
   bool exhBid= false, exhAsk= false;
   bool absLow= false, absHigh= false;
   int  chk   = MathMin(3, len / 3 + 1);

   for(int i = 0; i < len; i++)
     {
      if(g_bars[bi].levels[i].is_stacked_imb_buy)  hasSB  = true;
      if(g_bars[bi].levels[i].is_stacked_imb_sell) hasSS  = true;
      if(g_bars[bi].levels[i].is_exhaustion_bid)   exhBid = true;
      if(g_bars[bi].levels[i].is_exhaustion_ask)   exhAsk = true;
      if(i < chk && g_bars[bi].levels[i].is_absorption)             absHigh = true;
      if(i >= len - chk && g_bars[bi].levels[i].is_absorption)      absLow  = true;
     }

   if(isBuy)
     {
      if(hasSB)   tags[n++] = "StackBuy";
      if(absLow)  tags[n++] = "AbsLow";
      if(exhBid)  tags[n++] = "BidExh";
     }
   else
     {
      if(hasSS)   tags[n++] = "StackSell";
      if(absHigh) tags[n++] = "AbsHigh";
      if(exhAsk)  tags[n++] = "AskExh";
     }

   // 4. Naked POC magnet
   if(g_bars[bi].is_naked_poc) tags[n++] = "NakedPOC";

   if(n == 0) return "Mixed";
   string out = "";
   int    cap = MathMin(n, 3);
   for(int i = 0; i < cap; i++)
     { if(i > 0) out += "+"; out += tags[i]; }
   return out;
  }

//--- Place entry arrow, SL/TP lines, and conviction label on the chart
void DrawTradeEntry(ulong ticket, bool isBuy, double entryPx,
                    double sl, double tp, datetime barTime,
                    const string conviction, int hftScore, int ofsScore)
  {
   if(!InpShowVisuals) return;
   long  chart  = g_chart;
   color clrDir = isBuy ? InpVizBuyColor : InpVizSellColor;
   string dirStr = isBuy ? "BUY" : "SELL";

   // Entry arrow (Wingdings 233 = filled up-triangle, 234 = filled down-triangle)
   string arNm = ObjName("AR", ticket);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, barTime, entryPx))
     {
      ObjectSetInteger(chart, arNm, OBJPROP_ARROWCODE,   isBuy ? 233 : 234);
      ObjectSetInteger(chart, arNm, OBJPROP_COLOR,       clrDir);
      ObjectSetInteger(chart, arNm, OBJPROP_WIDTH,       2);
      ObjectSetInteger(chart, arNm, OBJPROP_SELECTABLE,  false);
      ObjectSetString( chart, arNm, OBJPROP_TOOLTIP,
         StringFormat("%s ENTRY | #%I64u\nHFT: %d  OFS: %d\nConviction: %s\nEntry: %s",
                      dirStr, ticket, hftScore, ofsScore, conviction,
                      DoubleToString(entryPx, _Digits)));
     }

   if(InpShowSLTPLines)
     {
      // SL dotted line
      if(sl > 0.0)
        {
         string slNm = ObjName("SL", ticket);
         if(ObjectCreate(chart, slNm, OBJ_HLINE, 0, 0, sl))
           {
            ObjectSetInteger(chart, slNm, OBJPROP_COLOR,      InpVizSLColor);
            ObjectSetInteger(chart, slNm, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chart, slNm, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chart, slNm, OBJPROP_SELECTABLE, false);
            ObjectSetString( chart, slNm, OBJPROP_TOOLTIP,
               StringFormat("SL | #%I64u | %s", ticket, DoubleToString(sl, _Digits)));
           }
        }
      // TP dotted line
      if(tp > 0.0)
        {
         string tpNm = ObjName("TP", ticket);
         if(ObjectCreate(chart, tpNm, OBJ_HLINE, 0, 0, tp))
           {
            ObjectSetInteger(chart, tpNm, OBJPROP_COLOR,      InpVizTPColor);
            ObjectSetInteger(chart, tpNm, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chart, tpNm, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chart, tpNm, OBJPROP_SELECTABLE, false);
            ObjectSetString( chart, tpNm, OBJPROP_TOOLTIP,
               StringFormat("TP | #%I64u | %s", ticket, DoubleToString(tp, _Digits)));
           }
        }
     }

   // Conviction label (scores + top reasons, anchored to entry price)
   if(InpShowEntryLabel)
     {
      string lbNm = ObjName("EL", ticket);
      string txt  = StringFormat("%s  HFT:%d OFS:%d\n%s",
                                 (isBuy ? "▲" : "▼"), hftScore, ofsScore, conviction);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, barTime, entryPx))
        {
         ObjectSetString( chart, lbNm, OBJPROP_TEXT,       txt);
         ObjectSetInteger(chart, lbNm, OBJPROP_COLOR,      clrDir);
         ObjectSetInteger(chart, lbNm, OBJPROP_FONTSIZE,   8);
         ObjectSetString( chart, lbNm, OBJPROP_FONT,       "Consolas");
         ObjectSetInteger(chart, lbNm, OBJPROP_ANCHOR,     isBuy ? ANCHOR_LEFT_UPPER
                                                                   : ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chart, lbNm, OBJPROP_SELECTABLE, false);
        }
     }

   // [FIX-7] Force immediate repaint so objects appear on the current tick,
   // not deferred to the next natural terminal redraw cycle.
   ChartRedraw(chart);
  }

//--- Draw VIRTUAL entry markers for Analysis Mode (uses "AN_" namespace)
//    Identical layout to DrawTradeEntry but objects are prefixed "AN_" so
//    CleanupAllTradeObjects() (which only removes "FP_*") leaves them intact
//    across EA restarts, building a permanent signal diary on the chart.
void DrawAnalysisEntry(ulong vTicket, bool isBuy, double entryPx,
                       double sl, double tp, datetime barTime,
                       const string conviction, int hftScore, int ofsScore)
  {
   if(!InpShowVisuals) return;
   long  chart  = g_chart;
   color clrDir = isBuy ? InpVizBuyColor : InpVizSellColor;
   string dirStr = isBuy ? "BUY" : "SELL";

   // Entry arrow — same Wingdings codes, same size; tooltip flags as ANALYSIS
   string arNm = StringFormat("AN_AR_%I64u", vTicket);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, barTime, entryPx))
     {
      ObjectSetInteger(chart, arNm, OBJPROP_ARROWCODE,   isBuy ? 233 : 234);
      ObjectSetInteger(chart, arNm, OBJPROP_COLOR,       clrDir);
      ObjectSetInteger(chart, arNm, OBJPROP_WIDTH,       2);
      ObjectSetInteger(chart, arNm, OBJPROP_SELECTABLE,  false);
      ObjectSetString( chart, arNm, OBJPROP_TOOLTIP,
         StringFormat("[ANALYSIS] %s ENTRY | #V%I64u\nHFT: %d  OFS: %d\nConviction: %s\nEntry: %s",
                      dirStr, vTicket, hftScore, ofsScore, conviction,
                      DoubleToString(entryPx, _Digits)));
     }

   if(InpShowSLTPLines)
     {
      if(sl > 0.0)
        {
         string slNm = StringFormat("AN_SL_%I64u", vTicket);
         if(ObjectCreate(chart, slNm, OBJ_HLINE, 0, 0, sl))
           {
            ObjectSetInteger(chart, slNm, OBJPROP_COLOR,      InpVizSLColor);
            ObjectSetInteger(chart, slNm, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chart, slNm, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chart, slNm, OBJPROP_SELECTABLE, false);
            ObjectSetString( chart, slNm, OBJPROP_TOOLTIP,
               StringFormat("[ANALYSIS] SL | #V%I64u | %s", vTicket, DoubleToString(sl, _Digits)));
           }
        }
      if(tp > 0.0)
        {
         string tpNm = StringFormat("AN_TP_%I64u", vTicket);
         if(ObjectCreate(chart, tpNm, OBJ_HLINE, 0, 0, tp))
           {
            ObjectSetInteger(chart, tpNm, OBJPROP_COLOR,      InpVizTPColor);
            ObjectSetInteger(chart, tpNm, OBJPROP_STYLE,      STYLE_DOT);
            ObjectSetInteger(chart, tpNm, OBJPROP_WIDTH,      1);
            ObjectSetInteger(chart, tpNm, OBJPROP_SELECTABLE, false);
            ObjectSetString( chart, tpNm, OBJPROP_TOOLTIP,
               StringFormat("[ANALYSIS] TP | #V%I64u | %s", vTicket, DoubleToString(tp, _Digits)));
           }
        }
     }

   // Entry label — prefixed with [A] to distinguish from live trade labels
   if(InpShowEntryLabel)
     {
      string lbNm = StringFormat("AN_EL_%I64u", vTicket);
      string txt  = StringFormat("[A] %s  HFT:%d OFS:%d\n%s",
                                 (isBuy ? "▲" : "▼"), hftScore, ofsScore, conviction);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, barTime, entryPx))
        {
         ObjectSetString( chart, lbNm, OBJPROP_TEXT,       txt);
         ObjectSetInteger(chart, lbNm, OBJPROP_COLOR,      clrDir);
         ObjectSetInteger(chart, lbNm, OBJPROP_FONTSIZE,   8);
         ObjectSetString( chart, lbNm, OBJPROP_FONT,       "Consolas");
         ObjectSetInteger(chart, lbNm, OBJPROP_ANCHOR,     isBuy ? ANCHOR_LEFT_UPPER
                                                                   : ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chart, lbNm, OBJPROP_SELECTABLE, false);
        }
     }

   ChartRedraw(chart);
  }
void UpdateSLLine(ulong ticket, double newSL)
  {
   if(!InpShowVisuals || !InpShowSLTPLines) return;
   string nm = ObjName("SL", ticket);
   long   chart = g_chart;
   if(ObjectFind(chart, nm) >= 0)
      ObjectSetDouble(chart, nm, OBJPROP_PRICE, newSL);
  }

//--- Place exit arrow + P&L label; remove SL/TP lines (trade is over)
void DrawTradeExit(ulong ticket, bool wasLong, double exitPx,
                   double netPnl, datetime exitTime)
  {
   if(!InpShowVisuals) return;
   long   chart  = g_chart;
   bool   win    = (netPnl >= 0.0);
   color  clrPnl = win ? clrLime : clrOrangeRed;

   // Remove open SL/TP reference lines
   ObjectDelete(chart, ObjName("SL", ticket));
   ObjectDelete(chart, ObjName("TP", ticket));

   // Exit arrow (opposite direction to position type)
   string arNm = ObjName("XR", ticket);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, exitTime, exitPx))
     {
      ObjectSetInteger(chart, arNm, OBJPROP_ARROWCODE,   wasLong ? 234 : 233);
      ObjectSetInteger(chart, arNm, OBJPROP_COLOR,       clrPnl);
      ObjectSetInteger(chart, arNm, OBJPROP_WIDTH,       2);
      ObjectSetInteger(chart, arNm, OBJPROP_SELECTABLE,  false);
      ObjectSetString( chart, arNm, OBJPROP_TOOLTIP,
         StringFormat("EXIT | #%I64u | Net: %.2f [%s]",
                      ticket, netPnl, win ? "WIN" : "LOSS"));
     }

   // P&L label
   if(InpShowExitLabel)
     {
      string lbNm = ObjName("XL", ticket);
      string txt  = StringFormat("%s%.2f", win ? "+" : "", netPnl);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, exitTime, exitPx))
        {
         ObjectSetString( chart, lbNm, OBJPROP_TEXT,       txt);
         ObjectSetInteger(chart, lbNm, OBJPROP_COLOR,      clrPnl);
         ObjectSetInteger(chart, lbNm, OBJPROP_FONTSIZE,   9);
         ObjectSetString( chart, lbNm, OBJPROP_FONT,       "Consolas");
         ObjectSetInteger(chart, lbNm, OBJPROP_ANCHOR,     wasLong ? ANCHOR_LEFT_LOWER
                                                                     : ANCHOR_LEFT_UPPER);
         ObjectSetInteger(chart, lbNm, OBJPROP_SELECTABLE, false);
        }
     }

   // [FIX-7] Force immediate repaint.
   ChartRedraw(chart);
  }

//--- Remove all FP_ chart objects placed by this EA (used at deinit)
void CleanupAllTradeObjects()
  {
   long chart = g_chart;
   for(int i = ObjectsTotal(chart, 0, -1) - 1; i >= 0; i--)
     {
      string nm = ObjectName(chart, i, 0, -1);
      if(StringFind(nm, "FP_") == 0)
         ObjectDelete(chart, nm);
     }
  }

//--- [FIX-DRAW] Draw a signal arrow + score label directly from EvalAndFireSignal().
//    These markers are drawn whenever InpShowSignals && InpShowVisuals are both
//    true, completely independent of InpATEnable / InpAnalysisMode.
//    Objects use the "SIG_" prefix so CleanupAllTradeObjects() (FP_ namespace)
//    and analysis cleanup (AN_ namespace) leave them intact across EA restarts,
//    building a permanent signal diary even in pure signal-only mode.
void DrawSignalMarker(ulong markerId, bool isBuy, double price,
                      datetime barTime, int hftScore, int ofsScore,
                      const string conviction)
  {
   if(!InpShowVisuals) return;

   long   chart  = g_chart;
   color  clrDir = isBuy ? InpVizBuyColor : InpVizSellColor;
   string dirStr = isBuy ? "BUY" : "SELL";

   // Arrow — same Wingdings codes used by trade markers for visual consistency
   string arNm = StringFormat("SIG_AR_%I64u", markerId);
   if(ObjectCreate(chart, arNm, OBJ_ARROW, 0, barTime, price))
     {
      ObjectSetInteger(chart, arNm, OBJPROP_ARROWCODE,   isBuy ? 233 : 234);
      ObjectSetInteger(chart, arNm, OBJPROP_COLOR,       clrDir);
      ObjectSetInteger(chart, arNm, OBJPROP_WIDTH,       2);
      ObjectSetInteger(chart, arNm, OBJPROP_SELECTABLE,  false);
      ObjectSetString( chart, arNm, OBJPROP_TOOLTIP,
         StringFormat("[SIGNAL] %s | HFT: %d  OFS: %d\nConviction: %s\nPrice: %s | Bar: %s",
                      dirStr, hftScore, ofsScore, conviction,
                      DoubleToString(price, _Digits),
                      TimeToString(barTime, TIME_DATE | TIME_MINUTES)));
     }

   // Score label anchored at the signal price
   if(InpShowEntryLabel)
     {
      string lbNm = StringFormat("SIG_LB_%I64u", markerId);
      string txt  = StringFormat("%s  HFT:%d OFS:%d\n%s",
                                 isBuy ? "▲" : "▼", hftScore, ofsScore, conviction);
      if(ObjectCreate(chart, lbNm, OBJ_TEXT, 0, barTime, price))
        {
         ObjectSetString( chart, lbNm, OBJPROP_TEXT,       txt);
         ObjectSetInteger(chart, lbNm, OBJPROP_COLOR,      clrDir);
         ObjectSetInteger(chart, lbNm, OBJPROP_FONTSIZE,   8);
         ObjectSetString( chart, lbNm, OBJPROP_FONT,       "Consolas");
         ObjectSetInteger(chart, lbNm, OBJPROP_ANCHOR,     isBuy ? ANCHOR_LEFT_UPPER
                                                                   : ANCHOR_LEFT_LOWER);
         ObjectSetInteger(chart, lbNm, OBJPROP_SELECTABLE, false);
        }
     }

   ChartRedraw(chart);
  }

//==========================================================================
// SECTION 7: FORWARD DECLARATIONS
//==========================================================================

void ComputeBarSignals(int bi);

//==========================================================================
// SECTION 8: TICK PROCESSING PIPELINE
//==========================================================================

//--- Normalise price to nearest grid step
double NormP(double p)
  {
   return MathFloor(p / g_step) * g_step;
  }

//--- Binary search in sorted g_bars[]
int FindBarIndex(datetime bt)
  {
   int lo = 0, hi = ArraySize(g_bars) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if(g_bars[mid].bar_time == bt) return mid;
      if(g_bars[mid].bar_time < bt)  lo = mid + 1;
      else                            hi = mid - 1;
     }
   return -1;
  }

//--- Insert a new FPBar slot, maintaining chronological order.
//    Uses scalar-shift + explicit level-array copy to avoid shallow-copy
//    corruption of dynamic sub-arrays (MQL5 struct assignment limitation).
int InsertBar(datetime bt)
  {
   int n = ArraySize(g_bars);

   // Fast-path: chronological append
   if(n > 0 && bt > g_bars[n - 1].bar_time)
     {
      ArrayResize(g_bars, n + 1, 128);
      g_bars[n].bar_time             = bt;
      g_bars[n].total_vol            = 0;
      g_bars[n].total_delta          = 0;
      g_bars[n].high                 = 0.0;
      g_bars[n].low                  = 0.0;
      g_bars[n].sorted               = true;
      g_bars[n].is_bullish           = true;
      g_bars[n].level_count          = 0;
      g_bars[n].poc_idx              = -1;
      g_bars[n].va_lo_idx            = -1;
      g_bars[n].va_hi_idx            = -1;
      g_bars[n].is_delta_divergence  = false;
      g_bars[n].is_naked_poc         = false;
      ArrayResize(g_bars[n].levels, 64, 64);
      return n;
     }

   // Find insertion position
   int pos = n;
   for(int i = n - 1; i >= 0; i--)
     {
      if(g_bars[i].bar_time == bt) return i;
      if(g_bars[i].bar_time < bt) { pos = i + 1; break; }
      pos = i;
     }

   ArrayResize(g_bars, n + 1, 128);

   // [FIX-6] The trailing slot (index n) does NOT need explicit initialisation
   // here — the shift loop below overwrites it unconditionally with g_bars[n-1].
   // The previous version initialised it twice (scalar fields + ArrayResize),
   // which was redundant and misleading.  We only need to clear the levels
   // sub-array so the dynamic-array handle is valid before the shift copies
   // into it via explicit element assignment.
   ArrayResize(g_bars[n].levels, 0);

   // Bubble-shift scalar fields and explicit level arrays toward the back
   for(int i = n; i > pos; i--)
     {
      g_bars[i].bar_time            = g_bars[i - 1].bar_time;
      g_bars[i].total_vol           = g_bars[i - 1].total_vol;
      g_bars[i].total_delta         = g_bars[i - 1].total_delta;
      g_bars[i].high                = g_bars[i - 1].high;
      g_bars[i].low                 = g_bars[i - 1].low;
      g_bars[i].sorted              = g_bars[i - 1].sorted;
      g_bars[i].is_bullish          = g_bars[i - 1].is_bullish;
      g_bars[i].level_count         = g_bars[i - 1].level_count;
      g_bars[i].poc_idx             = g_bars[i - 1].poc_idx;
      g_bars[i].va_lo_idx           = g_bars[i - 1].va_lo_idx;
      g_bars[i].va_hi_idx           = g_bars[i - 1].va_hi_idx;
      g_bars[i].is_delta_divergence = g_bars[i - 1].is_delta_divergence;
      g_bars[i].is_naked_poc        = g_bars[i - 1].is_naked_poc;
      int lc = g_bars[i - 1].level_count;
      ArrayResize(g_bars[i].levels, lc, 64);
      for(int k = 0; k < lc; k++)
         g_bars[i].levels[k] = g_bars[i - 1].levels[k];
     }

   // Place new bar
   g_bars[pos].bar_time            = bt;
   g_bars[pos].total_vol           = 0;
   g_bars[pos].total_delta         = 0;
   g_bars[pos].high                = 0.0;
   g_bars[pos].low                 = 0.0;
   g_bars[pos].sorted              = true;
   g_bars[pos].is_bullish          = true;
   g_bars[pos].level_count         = 0;
   g_bars[pos].poc_idx             = -1;
   g_bars[pos].va_lo_idx           = -1;
   g_bars[pos].va_hi_idx           = -1;
   g_bars[pos].is_delta_divergence = false;
   g_bars[pos].is_naked_poc        = false;
   ArrayResize(g_bars[pos].levels, 64, 64);
   return pos;
  }

int GetBar(datetime bt)
  {
   int idx = FindBarIndex(bt);
   return (idx >= 0) ? idx : InsertBar(bt);
  }

//--- Accumulate one tick into the appropriate price-level bucket
void AccumulateTick(int bi, double price, long vol, bool isBuy, bool isSell)
  {
   if(price == 0.0) return;
   price = NormP(price);

   int used = g_bars[bi].level_count;
   int idx  = -1;

   bool skipSearch = (price > g_bars[bi].high + g_step ||
                      price < g_bars[bi].low  - g_step);
   if(!skipSearch)
     {
      for(int i = used - 1; i >= 0; i--)
        {
         if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.5)
           { idx = i; break; }
        }
     }

   if(idx == -1)
     {
      if(used >= ArraySize(g_bars[bi].levels))
         ArrayResize(g_bars[bi].levels, used + 64, 64);

      idx                                          = used;
      g_bars[bi].levels[idx].price                = price;
      g_bars[bi].levels[idx].bid_vol              = 0;
      g_bars[bi].levels[idx].ask_vol              = 0;
      g_bars[bi].levels[idx].total_vol            = 0;
      g_bars[bi].levels[idx].delta                = 0;
      g_bars[bi].levels[idx].is_imb_buy           = false;
      g_bars[bi].levels[idx].is_imb_sell          = false;
      g_bars[bi].levels[idx].is_absorption         = false;
      g_bars[bi].levels[idx].is_hvn                = false;
      g_bars[bi].levels[idx].is_lvn                = false;
      g_bars[bi].levels[idx].is_stacked_imb_buy   = false;
      g_bars[bi].levels[idx].is_stacked_imb_sell  = false;
      g_bars[bi].levels[idx].is_unfinished_hi      = false;
      g_bars[bi].levels[idx].is_unfinished_lo      = false;
      g_bars[bi].levels[idx].is_exhaustion_bid     = false;
      g_bars[bi].levels[idx].is_exhaustion_ask     = false;
      g_bars[bi].level_count++;
      g_bars[bi].sorted = false;
     }

   if(isBuy)  g_bars[bi].levels[idx].ask_vol += vol;
   if(isSell) g_bars[bi].levels[idx].bid_vol += vol;

   g_bars[bi].levels[idx].total_vol += vol;
   g_bars[bi].levels[idx].delta      = g_bars[bi].levels[idx].ask_vol
                                      - g_bars[bi].levels[idx].bid_vol;

   g_bars[bi].total_vol   += vol;
   g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));
   g_bars[bi].sorted       = false;
  }

//--- Classify tick as buy or sell pressure
void Classify(const MqlTick &t, bool &isBuy, bool &isSell)
  {
   isBuy  = false;
   isSell = false;
   if(g_hasTrades)
     {
      isBuy  = (t.flags & TICK_FLAG_BUY)  == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
      if(!isBuy && !isSell)
        {
         if(t.last >= t.ask) isBuy  = true;
         else if(t.last <= t.bid) isSell = true;
        }
     }
   else
     {
      // [FIX-SELL-1] Bid-tick direction for FX / non-trades feeds.
      // REMOVED: `else isBuy = true` tie-break.  In MT5 backtest, thin tick
      // data means consecutive ticks often share the SAME bid.  That tie-break
      // forced virtually every tick to Be Buy, making total_delta permanently
      // positive and the sell threshold mathematically unreachable in backtest.
      // Live trading was unaffected because it takes the g_hasTrades=true path.
      // Neutral ticks now correctly contribute nothing to delta accounting.
      //
      // [FIX-SELL-2] Guard against uninitialised g_prevBid (0.0 at EA start).
      // Without this, the very first tick always satisfied `t.bid > 0.0` and
      // was silently forced into Buy before any real comparison existed.
      if(g_prevBid > 0.0)
        {
         if(t.bid > g_prevBid)      isBuy  = true;
         else if(t.bid < g_prevBid) isSell = true;
         // else: bid unchanged — neutral; carries no directional information
        }
     }
  }

//--- Core tick-array processor (shared by LoadHistory and OnTick)
void ProcessTicks(MqlTick &ticks[], int startIdx, int count,
                  bool skipAlreadySeen, bool updateLastTimeMs,
                  bool reset_cache = false)
  {
   static datetime current_bar_time = 0;
   static int      current_sh       = -1;
   static datetime next_bar_time    = 0;
   // OHLC cache: historical bars never change — refresh only on bar switch.
   // Live bar (sh==0) always refreshes so is_bullish / high / low stay current.
   static int    s_ohlc_sh   = -2;
   static bool   s_ohlc_bull = true;
   static double s_ohlc_high = 0.0;
   static double s_ohlc_low  = 0.0;

   if(reset_cache)
     {
      current_bar_time = 0;
      current_sh       = -1;
      next_bar_time    = 0;
      s_ohlc_sh        = -2;
     }

   if(count <= 0) return;
   int endIdx = MathMin(startIdx + count, ArraySize(ticks));

   for(int i = startIdx; i < endIdx; i++)
     {
      if(skipAlreadySeen && ticks[i].time_msc <= g_last_tick_time_ms)
         continue;

      double price;
      long   vol;
      if(g_hasTrades)
        {
         price = ticks[i].last;
         vol   = (long)ticks[i].volume;
         if(vol <= 0 || price == 0.0) continue;
        }
      else
        {
         price = ticks[i].bid;
         vol   = 1;
         if(price == 0.0) continue;
        }

      bool isBuy, isSell;
      Classify(ticks[i], isBuy, isSell);

      if(ticks[i].bid != 0.0) g_prevBid = ticks[i].bid;

      if(ticks[i].time < current_bar_time || ticks[i].time >= next_bar_time)
        {
         current_sh = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
         if(current_sh < 0) continue;
         current_bar_time = iTime(_Symbol, PERIOD_CURRENT, current_sh);
         next_bar_time    = current_bar_time + PeriodSeconds(PERIOD_CURRENT);
        }

      int      sh = current_sh;
      datetime bt = current_bar_time;
      int      bi = GetBar(bt);

      // OHLC: refresh unconditionally for the live bar (sh==0, price moves each tick),
      // cache for historical bars (values are fixed once the bar is closed).
      if(sh == 0 || sh != s_ohlc_sh)
        {
         s_ohlc_sh   = sh;
         s_ohlc_bull = (iClose(_Symbol, PERIOD_CURRENT, sh) >= iOpen(_Symbol, PERIOD_CURRENT, sh));
         s_ohlc_high = iHigh(_Symbol, PERIOD_CURRENT, sh);
         s_ohlc_low  = iLow (_Symbol, PERIOD_CURRENT, sh);
        }
      g_bars[bi].is_bullish = s_ohlc_bull;
      g_bars[bi].high       = s_ohlc_high;
      g_bars[bi].low        = s_ohlc_low;

      AccumulateTick(bi, price, vol, isBuy, isSell);

      if(updateLastTimeMs)
         g_last_tick_time_ms = ticks[i].time_msc;
     }
  }

int LoadHistory(datetime t0, datetime t1)
  {
   MqlTick ticks[];
   uint    flag   = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   int     copied = CopyTicksRange(_Symbol, ticks, flag,
                                   (long)t0 * 1000, (long)t1 * 1000);
   if(copied <= 0) return -1;

   g_prevBid = ticks[0].bid;
   ProcessTicks(ticks, 0, copied, false, true, true);
   return copied;
  }

//==========================================================================
// SECTION 9: LEVEL SORTING & PROFILE HELPERS
//==========================================================================

void SortLevelsPartition(PriceLevel &lv[], int lo, int hi)
  {
   if(lo >= hi) return;
   double pivot = lv[hi].price;
   int    i     = lo - 1;
   for(int j = lo; j < hi; j++)
     {
      if(lv[j].price >= pivot)
        { i++; PriceLevel tmp = lv[i]; lv[i] = lv[j]; lv[j] = tmp; }
     }
   i++;
   PriceLevel tmp = lv[i]; lv[i] = lv[hi]; lv[hi] = tmp;
   SortLevelsPartition(lv, lo, i - 1);
   SortLevelsPartition(lv, i + 1, hi);
  }

void SortLevels(PriceLevel &lv[], int n)
  {
   if(n > 1) SortLevelsPartition(lv, 0, n - 1);
  }

int FindPOC(const PriceLevel &lv[], int count)
  {
   int  best = -1;
   long mx   = 0;
   for(int i = 0; i < count; i++)
      if(lv[i].total_vol > mx) { mx = lv[i].total_vol; best = i; }
   return best;
  }

double GetEffectiveVAPercent()
  {
   if(g_vaPercent > 0.0) return g_vaPercent;
   return (InpVAPercent > 0.0) ? InpVAPercent : 70.0;
  }

void FindVA(const PriceLevel &lv[], int count, long totVol, int poc,
            int &lo, int &hi)
  {
   lo = poc; hi = poc;
   if(poc < 0) return;
   long target = (long)(totVol * GetEffectiveVAPercent() / 100.0);
   long cur    = lv[poc].total_vol;

   while(cur < target && (lo > 0 || hi < count - 1))
     {
      long up = 0;
      if(hi + 1 < count) up += lv[hi + 1].total_vol;
      if(hi + 2 < count) up += lv[hi + 2].total_vol;
      bool canUp = (hi < count - 1);

      long dn = 0;
      if(lo - 1 >= 0) dn += lv[lo - 1].total_vol;
      if(lo - 2 >= 0) dn += lv[lo - 2].total_vol;
      bool canDn = (lo > 0);

      if(canUp && (!canDn || up >= dn)) { hi++; cur += lv[hi].total_vol; }
      else if(canDn)                    { lo--; cur += lv[lo].total_vol; }
      else break;
     }
  }

//==========================================================================
// SECTION 10: SIGNAL COMPUTATION
//==========================================================================

//--- Phase 2: compute POC, VA, imbalances, absorption, exhaustion, divergence
void ComputeBarSignals(int bi)
  {
   int len = g_bars[bi].level_count;
   if(len <= 0) return;

   if(!g_bars[bi].sorted)
     { SortLevels(g_bars[bi].levels, len); g_bars[bi].sorted = true; }

   // 1. POC
   g_bars[bi].poc_idx = FindPOC(g_bars[bi].levels, len);

   // 2. Value Area
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, g_bars[bi].poc_idx,
          g_bars[bi].va_lo_idx, g_bars[bi].va_hi_idx);

   // 3. Imbalance & Absorption per level
   long avgVol = (len > 0) ? (g_bars[bi].total_vol / len) : 1;
   for(int i = 0; i < len; i++)
     {
      g_bars[bi].levels[i].is_imb_buy          = false;
      g_bars[bi].levels[i].is_imb_sell         = false;
      g_bars[bi].levels[i].is_stacked_imb_buy  = false;
      g_bars[bi].levels[i].is_stacked_imb_sell = false;
      g_bars[bi].levels[i].is_unfinished_hi    = false;
      g_bars[bi].levels[i].is_unfinished_lo    = false;
      g_bars[bi].levels[i].is_hvn              = false;
      g_bars[bi].levels[i].is_lvn              = false;
      g_bars[bi].levels[i].is_exhaustion_bid   = false;
      g_bars[bi].levels[i].is_exhaustion_ask   = false;
      g_bars[bi].levels[i].is_absorption =
         (g_bars[bi].levels[i].total_vol > avgVol * InpAbsorptionRatio);
      g_bars[bi].levels[i].is_hvn =
         (!g_bars[bi].levels[i].is_absorption &&
          g_bars[bi].levels[i].total_vol >= (long)(avgVol * InpHVNRatio));
      g_bars[bi].levels[i].is_lvn =
         (g_bars[bi].levels[i].total_vol > 0 &&
          g_bars[bi].levels[i].total_vol <= (long)(avgVol * InpLVNRatio));

      // Diagonal imbalance
      if(i < len - 1)
        {
         long nextBid = g_bars[bi].levels[i + 1].bid_vol;
         if(nextBid > 0 &&
            ((double)g_bars[bi].levels[i].ask_vol / nextBid) * 100.0 >= g_imbRatio)
            g_bars[bi].levels[i].is_imb_buy = true;
        }
      if(i > 0)
        {
         long prevAsk = g_bars[bi].levels[i - 1].ask_vol;
         if(prevAsk > 0 &&
            ((double)g_bars[bi].levels[i].bid_vol / prevAsk) * 100.0 >= g_imbRatio)
            g_bars[bi].levels[i].is_imb_sell = true;
        }
     }

   // 4. Stacked Imbalances
   int countBuy = 0, countSell = 0;
   for(int i = 0; i < len; i++)
     {
      if(g_bars[bi].levels[i].is_imb_buy) countBuy++;
      else
        {
         if(countBuy >= InpStackedImbCount)
            for(int j = i - countBuy; j < i; j++)
               g_bars[bi].levels[j].is_stacked_imb_buy = true;
         countBuy = 0;
        }
      if(g_bars[bi].levels[i].is_imb_sell) countSell++;
      else
        {
         if(countSell >= InpStackedImbCount)
            for(int j = i - countSell; j < i; j++)
               g_bars[bi].levels[j].is_stacked_imb_sell = true;
         countSell = 0;
        }
     }
   if(countBuy  >= InpStackedImbCount)
      for(int j = len - countBuy;  j < len; j++)
         g_bars[bi].levels[j].is_stacked_imb_buy  = true;
   if(countSell >= InpStackedImbCount)
      for(int j = len - countSell; j < len; j++)
         g_bars[bi].levels[j].is_stacked_imb_sell = true;

   // 5. Unfinished Auctions
   if(len > 1)
     {
      g_bars[bi].levels[0].is_unfinished_hi =
         (g_bars[bi].levels[0].ask_vol > 0 && g_bars[bi].levels[0].bid_vol > 0);
      g_bars[bi].levels[len - 1].is_unfinished_lo =
         (g_bars[bi].levels[len - 1].bid_vol > 0 &&
          g_bars[bi].levels[len - 1].ask_vol > 0);
     }

   // 6. Delta Divergence
   g_bars[bi].is_delta_divergence =
      ( g_bars[bi].is_bullish && g_bars[bi].total_delta < 0) ||
      (!g_bars[bi].is_bullish && g_bars[bi].total_delta > 0);

   // 7. Bid/Ask Exhaustion at bar extremes
   if(InpExhaustionEnable && len >= InpExhaustionCells)
     {
      long avgV   = MathMax(1, g_bars[bi].total_vol / len);
      long exhThr = MathMax(1L, (long)(avgV * InpExhaustionZeroRat));

      // Ask exhaustion at HIGH
      int askRun = 0;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].total_vol > 0 &&
            g_bars[bi].levels[i].ask_vol <= exhThr) askRun++;
         else break;
        }
      if(askRun >= InpExhaustionCells)
         for(int i = 0; i < askRun; i++)
            g_bars[bi].levels[i].is_exhaustion_ask = true;

      // Bid exhaustion at LOW
      int bidRun = 0;
      for(int i = len - 1; i >= 0; i--)
        {
         if(g_bars[bi].levels[i].total_vol > 0 &&
            g_bars[bi].levels[i].bid_vol <= exhThr) bidRun++;
         else break;
        }
      if(bidRun >= InpExhaustionCells)
         for(int i = len - 1; i >= len - bidRun; i--)
            g_bars[bi].levels[i].is_exhaustion_bid = true;
     }
  }

//--- Naked POC: mark POC levels not yet retested by subsequent bars
void ComputeNakedPOCs()
  {
   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++)
     {
      g_bars[i].is_naked_poc = false;
      if(!g_bars[i].sorted) ComputeBarSignals(i);
      int pocIdx = g_bars[i].poc_idx;
      if(pocIdx < 0 || pocIdx >= g_bars[i].level_count) continue;

      double pocPrice = g_bars[i].levels[pocIdx].price;
      bool   retested = false;
      for(int j = i + 1; j < n && !retested; j++)
        {
         if(pocPrice >= g_bars[j].low  - g_step * 0.5 &&
            pocPrice <= g_bars[j].high + g_step * 0.5)
            retested = true;
        }
      g_bars[i].is_naked_poc = !retested;
     }
  }

//--- Order Flow Strength Score (0–100)
//    >50 = net bullish | <50 = net bearish | 50 = neutral
int ComputeOFScore(int bi)
  {
   int  len  = g_bars[bi].level_count;
   long tvol = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0) return 50;

   // A: delta ratio [−1,+1] → [0,1]
   // [FIX-10] Guard against NaN from division before clamping.
   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio = MathMax(-1.0, MathMin(1.0, rawDr));
   double cDelta = (dRatio + 1.0) * 0.5;

   // B: directional imbalance balance
   int  imbBuy = 0, imbSell = 0;
   bool hasStackBuy = false, hasStackSell = false, hasAbsorb = false;
   for(int i = 0; i < len; i++)
     {
      if(g_bars[bi].levels[i].is_imb_buy)          imbBuy++;
      if(g_bars[bi].levels[i].is_imb_sell)         imbSell++;
      if(g_bars[bi].levels[i].is_stacked_imb_buy)  hasStackBuy  = true;
      if(g_bars[bi].levels[i].is_stacked_imb_sell) hasStackSell = true;
      if(g_bars[bi].levels[i].is_absorption)        hasAbsorb    = true;
     }
   int    totalImb = imbBuy + imbSell;
   // [FIX-10] Guard division by totalImb.
   double cImb = 0.5;
   if(totalImb > 0)
     {
      double rawImb = ((double)(imbBuy - imbSell) / (double)totalImb + 1.0) * 0.5;
      cImb = MathIsValidNumber(rawImb) ? rawImb : 0.5;
     }

   // C: stacked direction
   double cStack;
   if     (hasStackBuy  && !hasStackSell) cStack = 1.0;
   else if(hasStackSell && !hasStackBuy)  cStack = 0.0;
   else                                    cStack = 0.5;

   // D: absorption sentiment
   double cAbsorb = hasAbsorb ? (g_bars[bi].is_bullish ? 1.0 : 0.0) : 0.5;

   double wD = MathMax(0.0, InpOFWtDelta)   / 100.0;
   double wI = MathMax(0.0, InpOFWtImb)     / 100.0;
   double wS = MathMax(0.0, InpOFWtStacked) / 100.0;
   double wA = MathMax(0.0, InpOFWtAbsorb)  / 100.0;
   double wT = wD + wI + wS + wA;
   if(wT <= 0.0) wT = 1.0;   // guarded by OnInit validation; defensive fallback

   double raw   = (cDelta * wD + cImb * wI + cStack * wS + cAbsorb * wA) / wT;
   // [FIX-10] Final NaN guard before cast.
   if(!MathIsValidNumber(raw)) raw = 0.5;
   int    score = (int)(raw * 100.0 + 0.5);
   return MathMax(0, MathMin(100, score));
  }

//--- HFT Multi-Factor Signal Score: −100 (strong sell) → +100 (strong buy)
//    6 independently-sourced order-flow components:
//    1. OFS composite (delta/imbalance/absorption) — 30 %
//    2. Delta exhaustion / divergence confirmation — 20 %
//    3. POC gravity — POC position inside the bar   — 15 %
//    4. Absorption at extremes (hi/lo clusters)    — 15 %
//    5. Bid/Ask exhaustion at bar extremes          — 10 %
//    6. 3-bar normalised CVD momentum slope         — 10 %
double ComputeHFTSignal(int bi)
  {
   int  len  = g_bars[bi].level_count;
   long tvol = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0) return 0.0;

   // C1: OFS Score
   double c1 = (ComputeOFScore(bi) - 50.0) / 50.0;

   // C2: Delta exhaustion / divergence
   // [FIX-10] Guard the division.
   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio = MathMax(-1.0, MathMin(1.0, rawDr));
   double c2 = g_bars[bi].is_delta_divergence ? -dRatio : dRatio;

   // C3: POC gravity
   double c3 = 0.0;
   if(g_bars[bi].poc_idx >= 0 && len > 2)
     {
      double pocPos = (double)g_bars[bi].poc_idx / (double)(len - 1);
      c3 = pocPos * 2.0 - 1.0;  // [0,1] → [−1,+1], bottom = bullish
     }

   // C4: Absorption at extremes
   double c4 = 0.0;
   {
      int  chk = MathMin(3, len / 3 + 1);
      bool absLow = false, absHigh = false;
      for(int i = len - chk; i < len; i++)
         if(g_bars[bi].levels[i].is_absorption) absLow  = true;
      for(int i = 0; i < chk; i++)
         if(g_bars[bi].levels[i].is_absorption) absHigh = true;
      if(absLow  && !absHigh) c4 = +1.0;
      else if(absHigh && !absLow) c4 = -1.0;
     }

   // C5: Bid/Ask exhaustion at extremes
   double c5 = 0.0;
   {
      bool exhAsk = false, exhBid = false;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].is_exhaustion_ask) exhAsk = true;
         if(g_bars[bi].levels[i].is_exhaustion_bid) exhBid = true;
        }
      if(exhBid && !exhAsk) c5 = +1.0;
      if(exhAsk && !exhBid) c5 = -1.0;
     }

   // C6: 3-bar normalised CVD momentum slope
   double c6 = 0.0;
   if(bi >= 2)
     {
      long v0 = MathMax(1, g_bars[bi].total_vol);
      long v2 = MathMax(1, g_bars[bi - 2].total_vol);
      double nd0   = (double)g_bars[bi].total_delta     / v0;
      double nd2   = (double)g_bars[bi - 2].total_delta / v2;
      // [FIX-10] Guard before slope arithmetic.
      if(!MathIsValidNumber(nd0)) nd0 = 0.0;
      if(!MathIsValidNumber(nd2)) nd2 = 0.0;
      double slope = (nd0 - nd2) / 2.0;
      c6 = MathMax(-1.0, MathMin(1.0, slope * 3.0));
     }

   const double w1 = 0.30, w2 = 0.20, w3 = 0.15;
   const double w4 = 0.15, w5 = 0.10, w6 = 0.10;
   double raw = c1*w1 + c2*w2 + c3*w3 + c4*w4 + c5*w5 + c6*w6;
   // [FIX-10] Final NaN guard.
   if(!MathIsValidNumber(raw)) raw = 0.0;
   return MathMax(-1.0, MathMin(1.0, raw)) * 100.0;
  }

//==========================================================================
// SECTION 11: HISTORY MANAGEMENT
//==========================================================================

void ReloadHistory()
  {
   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++) ArrayFree(g_bars[i].levels);
   ArrayFree(g_bars);
   g_last_tick_time_ms  = 0;
   g_lastSignalBar      = -9999;
   g_lastSignalBarTime  = 0;       // [FIX-SELL-4] reset time-based frequency gate
   g_sigCacheBarIdx     = -1;      // [FIX-SELL-3] reset signal eval cache on reload
   g_sigCacheVol        = -1;      // [FIX-SELL-3]

   int bars_total = iBars(_Symbol, PERIOD_CURRENT);
   if(bars_total <= 0) return;

   int      maxShift  = MathMin(g_histBars, bars_total - 1);
   datetime startTime = iTime(_Symbol, PERIOD_CURRENT, maxShift);
   datetime endTime   = TimeCurrent();
   int loaded = LoadHistory(startTime, endTime);

   if(loaded > 0)
     {
      ComputeNakedPOCs();
      LogSystem(StringFormat("OrderFlowEA — History loaded: %d ticks across %d bars.",
                             loaded, ArraySize(g_bars)));
     }
   else
     {
      static bool s_alerted = false;
      if(!s_alerted)
        {
         Alert("OrderFlowEA: No tick data for ", _Symbol,
               ". Attach to a chart with tick history available.");
         s_alerted = true;
        }
     }
  }

//==========================================================================
// SECTION 12: SIGNAL EVALUATION & DISPATCH
//==========================================================================


//--- Evaluate the live bar, gate by frequency, fire sound + journal
void EvalAndFireSignal()
  {
   if(!g_signalsEnabled) return;
   int nBars = ArraySize(g_bars);
   if(nBars == 0) return;

   int bi = nBars - 1;
   if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0) return;
   if(!g_bars[bi].sorted) ComputeBarSignals(bi);

   // Perf: skip if bar data hasn't changed since last evaluation
   if(bi == g_sigCacheBarIdx && g_bars[bi].total_vol == g_sigCacheVol) return;
   g_sigCacheBarIdx = bi;
   g_sigCacheVol    = g_bars[bi].total_vol;

   // [FIX-SELL-4] Frequency gate by bar time instead of raw array index.
   // The old guard `bi - g_lastSignalBar < g_signalFreqBars` used the g_bars[]
   // array index.  After ReloadHistory() the array is rebuilt from scratch, so
   // the new bi can be numerically smaller than the stale g_lastSignalBar and
   // the subtraction wraps negative — blocking all signals indefinitely.
   // Comparing datetime values is reload-safe: we simply count how many closed
   // bars have opened since the last signal by walking the chart bar series.
   if(g_lastSignalBarTime > 0)
     {
      int barsSinceLast = iBarShift(_Symbol, PERIOD_CURRENT, g_lastSignalBarTime);
      if(barsSinceLast >= 0 && barsSinceLast < g_signalFreqBars) return;
     }

   double hftScore    = ComputeHFTSignal(bi);
   int    currentScore= ComputeOFScore(bi);

   bool isBuySignal  = (hftScore >=  (double)g_signalThreshold);
   bool isSellSignal = (hftScore <= -(double)g_signalThreshold);
   if(!isBuySignal && !isSellSignal) return;

   g_lastSignalBar     = bi;
   g_lastSignalBarTime = g_bars[bi].bar_time;   // [FIX-SELL-4]

   int    displayScore = (int)MathRound(isBuySignal ? hftScore : -hftScore);
   string dir          = isBuySignal ? "BUY" : "SELL";
   string tf           = EnumToString(Period());
   StringReplace(tf, "PERIOD_", "");
   string conviction   = GetConvictionReason(bi, isBuySignal);

   LogSignal(StringFormat(
      "OrderFlowEA — %s | %s %s | HFT: %d | OFS: %d | Conviction: %s"
      " | Price: %s | Bar: %s | NakedPOC: %s | DeltaDiv: %s",
      dir, _Symbol, tf,
      displayScore, currentScore, conviction,
      DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
      TimeToString(g_bars[bi].bar_time, TIME_DATE | TIME_MINUTES),
      (g_bars[bi].is_naked_poc        ? "YES" : "NO"),
      (g_bars[bi].is_delta_divergence ? "YES" : "NO")));

   // [FIX-DRAW] Draw the signal arrow on the chart unconditionally
   // (independent of InpATEnable / InpAnalysisMode).  Use the current
   // bid/ask mid as the price anchor so the arrow appears at the actual
   // market price, not a synthetic entry level.
   if(InpShowVisuals)
     {
      double sigPrice = isBuySignal
                        ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      DrawSignalMarker(g_sigMarkerCount++, isBuySignal, sigPrice,
                       g_bars[bi].bar_time, displayScore, currentScore, conviction);
     }

   if(isBuySignal)  PlaySound(InpSignalBuySound);
   else             PlaySound(InpSignalSellSound);

  }

//==========================================================================
// SECTION 13: AUTOMATED TRADING ENGINE
//==========================================================================

void RefreshSymbolInfo()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // Odd-digit count = sub-pip pricing (3,5,7...) → pip = 10 × _Point
   // Even-digit count (0,2,4,6)                   → pip = _Point
   g_Pip = ((digits % 2) == 1) ? _Point * 10.0 : _Point;

   g_VolMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_VolMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_VolStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(g_VolStep <= 0.0) g_VolStep = 0.01;

   LogSystem(StringFormat(
      "OrderFlowEA — SymbolInfo | %s | digits=%d | g_Pip=%.6f"
      " | VolMin=%.2f VolMax=%.2f VolStep=%.2f",
      _Symbol, digits, g_Pip, g_VolMin, g_VolMax, g_VolStep));
  }

bool IsNewBar()
  {
   datetime current = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(current == 0 || current == g_LastBarTime) return false;
   g_LastBarTime = current;
   return true;
  }

bool IsTradeAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      static datetime s_t1 = 0;
      if(TimeCurrent() - s_t1 > 60)
        { LogWarning("OrderFlowEA — Terminal trade not allowed (AutoTrading off?)."); s_t1 = TimeCurrent(); }
      return false;
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      static datetime s_t2 = 0;
      if(TimeCurrent() - s_t2 > 60)
        { LogWarning("OrderFlowEA — EA trade permission denied."); s_t2 = TimeCurrent(); }
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      static datetime s_t3 = 0;
      if(TimeCurrent() - s_t3 > 60)
        { LogWarning("OrderFlowEA — Account trade not allowed (read-only or suspended?)."); s_t3 = TimeCurrent(); }
      return false;
     }
   return true;
  }

int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
      count++;
     }
   return count;
  }

// [FIX-5] Check all three filling modes in broker-declared order.
//         SYMBOL_FILLING_RETURN is a valid flag (value 0 is NOT a flag;
//         the constant SYMBOL_FILLING_RETURN == 2 in the broker mask).
//         If none of the standard flags are set, fall back to RETURN and
//         log a warning — some brokers omit the flag entirely yet still
//         accept RETURN-mode requests.
ENUM_ORDER_TYPE_FILLING GetBrokerFillingMode()
  {
   long flags = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) != 0)    return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC) != 0)    return ORDER_FILLING_IOC;
   // SYMBOL_FILLING_RETURN is bit 2 in the broker flag mask.
   if((flags & 4) != 0)                     return ORDER_FILLING_RETURN;
   // No recognised flag set — use RETURN as the MT5 default and warn once.
   static bool s_warnedFilling = false;
   if(!s_warnedFilling)
     {
      LogWarning(StringFormat(
         "OrderFlowEA — Filling mode flags=0x%X unrecognised for %s; defaulting to RETURN.",
         flags, _Symbol));
      s_warnedFilling = true;
     }
   return ORDER_FILLING_RETURN;
  }

// CalcLot — margin-based position sizing (no Stop Loss required).
//
// [FIX-11] Replaced the previous SL-pips / tick-value formula with a
// margin-based approach that is asset-aware by construction:
//
//   Step A — AllocationAmount  = AccountBalance × (RiskPercent / 100)
//             Determines the monetary slice of equity to commit as margin.
//
//   Step B — MarginFor1Lot     = OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, Ask)
//             Asks the terminal for the exact margin cost of one lot at the
//             current Ask.  The terminal accounts for leverage, contract size,
//             and base/quote currency conversion internally, so this value is
//             correct across FX majors, exotics, indices, and Deriv synthetics
//             (boom_100, vol_80, crash_500, etc.) without any manual scaling.
//
//   LotSize = AllocationAmount / MarginFor1Lot
//
// Because MarginFor1Lot differs for every symbol (it depends on the contract
// specification AND the current price), the resulting lot will be different
// when the EA runs on boom_100 vs. vol_80 — exactly the requirement in FIX-11.
//
// The slPointsUnused parameter is retained for call-site API compatibility
// (PlaceOrders already passes slPoints) but is intentionally not used here.
//
double CalcLot(double /*slPointsUnused*/)   // accepted for call-site compatibility; intentionally unused — see design note above
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lot;

   if(InpUseRiskPercent)
     {
      // ----------------------------------------------------------------
      // Step A: Allocation — how much margin are we willing to deploy?
      // ----------------------------------------------------------------
      double allocationAmt = balance * InpRiskPercent / 100.0;

      // ----------------------------------------------------------------
      // Step B: Ask the terminal for the margin cost of exactly 1.0 lot.
      // We always use the BUY direction for the reference calculation;
      // for most instruments this is symmetric, and using a live Ask
      // price guarantees the result reflects the current market rate.
      // ----------------------------------------------------------------
      MqlTick lastTick;
      double  askPrice = 0.0;
      if(SymbolInfoTick(_Symbol, lastTick) && lastTick.ask > 0.0)
         askPrice = lastTick.ask;
      else
         askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);   // fallback

      double marginFor1Lot = 0.0;
      bool   marginOK      = OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0,
                                             askPrice, marginFor1Lot);

      if(!marginOK || marginFor1Lot <= 0.0)
        {
         // OrderCalcMargin can fail if the market is closed or the symbol
         // is not tradeable at this moment.  Fall back to fixed lot and
         // warn so the operator can investigate.
         LogWarning(StringFormat(
            "OrderFlowEA — CalcLot: OrderCalcMargin failed (ok=%s margin=%.5f err=%d)"
            " for %s — falling back to fixed lot %.2f.",
            marginOK ? "true" : "false", marginFor1Lot, GetLastError(),
            _Symbol, InpFixedLot));
         lot = InpFixedLot;
        }
      else
        {
         // Core formula: lot = Allocation($) / MarginRequiredFor1Lot($)
         lot = allocationAmt / marginFor1Lot;

         LogTradeExec(StringFormat(
            "OrderFlowEA — DynLot (Margin) | %s | Bal: %.2f"
            " | Alloc: %.1f%% = $%.2f | Margin/1lot: $%.2f | Raw lot: %.4f",
            _Symbol, balance, InpRiskPercent, allocationAmt, marginFor1Lot, lot));
        }
     }
   else
     {
      lot = InpFixedLot;
     }

   // ----------------------------------------------------------------
   // Normalise to broker volume constraints.
   // ----------------------------------------------------------------
   double step   = (g_VolStep > 0.0) ? g_VolStep : 0.01;
   double lotMin = (g_VolMin  > 0.0) ? g_VolMin  : 0.01;
   double lotMax = (g_VolMax  > 0.0) ? g_VolMax  : 100.0;

   // Floor to the nearest valid step (never round up — avoids over-allocation)
   lot = MathFloor(lot / step) * step;
   // Clamp between broker-defined min and max volumes
   lot = MathMax(lotMin, MathMin(lotMax, lot));
   // Final precision normalisation expected by OrderSend()
   lot = NormalizeDouble(lot, 2);

   LogTradeExec(StringFormat(
      "OrderFlowEA — DynLot FINAL | %s | Lot: %.2f"
      " | (VolMin=%.2f VolMax=%.2f VolStep=%.2f)",
      _Symbol, lot, lotMin, lotMax, step));

   return lot;
  }

void CalcSLTP(bool   isBuy,  double entry,   double atrVal,
              double barHigh, double barLow,  double bufDist,
              double &sl,     double &tp)
  {
   sl = 0.0;
   tp = 0.0;

   if(InpUseStopLoss)
     {
      switch(InpSLMode)
        {
         case SL_MODE_BAR:
            sl = isBuy ? NormalizeDouble(barLow  - bufDist, _Digits)
                       : NormalizeDouble(barHigh + bufDist, _Digits);
            break;
         case SL_MODE_PIPS:
            sl = isBuy ? NormalizeDouble(entry - InpSLPips * g_Pip, _Digits)
                       : NormalizeDouble(entry + InpSLPips * g_Pip, _Digits);
            break;
         case SL_MODE_ATR:
            if(atrVal > 0.0)
               sl = isBuy ? NormalizeDouble(entry - InpSLATRMult * atrVal, _Digits)
                          : NormalizeDouble(entry + InpSLATRMult * atrVal, _Digits);
            else
              {
               LogWarning(StringFormat(
                  "OrderFlowEA — CalcSLTP: ATR=0, falling back to Fixed-Pips SL (%.1f pips)",
                  InpSLPips));
               sl = isBuy ? NormalizeDouble(entry - InpSLPips * g_Pip, _Digits)
                          : NormalizeDouble(entry + InpSLPips * g_Pip, _Digits);
              }
            break;
        }
     }

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
           {
            LogWarning(StringFormat(
               "OrderFlowEA — CalcSLTP: ATR=0, falling back to Fixed-Pips TP (%.1f pips)",
               InpTPPips));
            tp = isBuy ? NormalizeDouble(entry + InpTPPips * g_Pip, _Digits)
                       : NormalizeDouble(entry - InpTPPips * g_Pip, _Digits);
           }
         break;
     }
  }

bool trade_OrderDelete(ulong ticket)
  {
   if(!IsTradeAllowed()) return false;
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;
   bool ok = OrderSend(req, res);
   if(!ok)
      LogTradeExec(StringFormat(
         "OrderFlowEA — OrderDelete failed: ticket=%I64u retcode=%u",
         ticket, res.retcode));
   return ok;
  }

// [FIX-2] Snapshot all matching pending-order tickets into a local array
//         BEFORE issuing any delete requests.  The original code iterated
//         OrdersTotal() in reverse while deleting, but OrdersTotal() shrinks
//         on every successful delete, so skipping tickets was possible when
//         multiple orders were present.  Snapshotting first is immune to the
//         changing pool size.
void DeleteAllPending()
  {
   ulong tickets[];
   int   tCount = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != g_Magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)        continue;
      ArrayResize(tickets, tCount + 1);
      tickets[tCount++] = ticket;
     }

   for(int i = 0; i < tCount; i++)
      trade_OrderDelete(tickets[i]);
  }

//--- Unified order-send with normalisation, fill-mode detection, retry loop
bool trade_Send(ENUM_TRADE_REQUEST_ACTIONS action,
                ENUM_ORDER_TYPE            orderType,
                double                     price,
                double                     sl,
                double                     tp,
                double                     lot,
                string                     comment,
                ulong                     &outTicket)
  {
   outTicket = 0;
   if(!IsTradeAllowed()) return false;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   MqlTick lastTick;
   if(!SymbolInfoTick(_Symbol, lastTick))
     {
      LogTradeExec(StringFormat(
         "OrderFlowEA — trade_Send: SymbolInfoTick failed (%d)", GetLastError()));
      return false;
     }
   double freshAsk = lastTick.ask;
   double freshBid = lastTick.bid;

   // Market orders: pin to live price
   if(action == TRADE_ACTION_DEAL)
     {
      if(orderType == ORDER_TYPE_BUY)  price = freshAsk;
      else if(orderType == ORDER_TYPE_SELL) price = freshBid;
     }

   // Pending orders: validate entry vs market
   if(action == TRADE_ACTION_PENDING)
     {
      if(orderType == ORDER_TYPE_BUY_STOP && price <= freshAsk)
        {
         LogTradeExec(StringFormat(
            "OrderFlowEA — BuyStop skipped: entry (%s) not above current ask (%s)",
            DoubleToString(price, _Digits), DoubleToString(freshAsk, _Digits)));
         return false;
        }
      if(orderType == ORDER_TYPE_SELL_STOP && price >= freshBid)
        {
         LogTradeExec(StringFormat(
            "OrderFlowEA — SellStop skipped: entry (%s) not below current bid (%s)",
            DoubleToString(price, _Digits), DoubleToString(freshBid, _Digits)));
         return false;
        }
     }

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = MathMax((double)stopsLevel, 1.0) * _Point;
   double refPrice   = (action == TRADE_ACTION_DEAL)
                       ? ((orderType == ORDER_TYPE_BUY) ? freshAsk : freshBid)
                       : price;

   req.action       = action;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = orderType;
   req.price        = NormalizeDouble(price, _Digits);
   req.sl           = NormalizeDouble(sl,    _Digits);
   req.tp           = NormalizeDouble(tp,    _Digits);
   req.magic        = g_Magic;
   req.comment      = comment;
   req.type_filling = GetBrokerFillingMode();
   req.expiration   = 0;

   // Enforce broker stop distance
   if(sl > 0.0)
     {
      if(MathAbs(refPrice - sl) < minDist)
         req.sl = NormalizeDouble(
            (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY)
            ? refPrice - minDist : refPrice + minDist, _Digits);
     }
   if(tp > 0.0)
     {
      if(MathAbs(refPrice - tp) < minDist)
         req.tp = NormalizeDouble(
            (orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY)
            ? refPrice + minDist : refPrice - minDist, _Digits);
     }

   // Retry on transient codes (max 3 attempts)
   bool ok = false;
   for(int attempt = 1; attempt <= 3; attempt++)
     {
      if(attempt > 1 && action == TRADE_ACTION_DEAL)
        {
         if(SymbolInfoTick(_Symbol, lastTick))
           {
            if(orderType == ORDER_TYPE_BUY)
               req.price = NormalizeDouble(lastTick.ask, _Digits);
            else if(orderType == ORDER_TYPE_SELL)
               req.price = NormalizeDouble(lastTick.bid, _Digits);
           }
        }
      ok = OrderSend(req, res);
      if(ok) break;
      uint rc = res.retcode;
      if(rc != TRADE_RETCODE_REQUOTE       &&
         rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_CONNECTION    &&
         rc != TRADE_RETCODE_TIMEOUT)
         break;
      Sleep(200);
     }

   if(!ok)
      LogTradeExec(StringFormat(
         "OrderFlowEA — OrderSend failed: retcode=%u (%s) action=%s type=%s"
         " price=%s sl=%s tp=%s lot=%.2f",
         res.retcode,
         (res.retcode == 10004 ? "REQUOTE"        :
          res.retcode == 10006 ? "REJECTED"       :
          res.retcode == 10014 ? "INVALID_VOLUME" :
          res.retcode == 10015 ? "INVALID_PRICE"  :
          res.retcode == 10016 ? "INVALID_STOPS"  :
          res.retcode == 10019 ? "NO_MONEY" : "OTHER"),
         EnumToString(action), EnumToString(orderType),
         DoubleToString(req.price,_Digits),
         DoubleToString(req.sl,   _Digits),
         DoubleToString(req.tp,   _Digits), req.volume));
   else
      outTicket = res.order;   // order ticket == position ID for market fills
   return ok;
  }

//--- Evaluate last closed bar and fire orders (once per new bar)
void PlaceOrders()
  {
   // Allow execution if live auto-trading OR analysis mode is active
   if(!g_autoTrade && !g_analysisMode) return;

   // Trade permission check is skipped in analysis mode (no real orders submitted)
   if(!g_analysisMode && !IsTradeAllowed()) return;

   // Position cap applies to live trading only
   if(!g_analysisMode && InpMaxPositions > 0 && CountOpenPositions() >= InpMaxPositions) return;

   // Equity / balance safety guards apply to live trading only
   if(!g_analysisMode)
     {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(InpMaxEquityProfit > 0.0 && equity >= balance + InpMaxEquityProfit)
        {
         LogWarning("OrderFlowEA — MaxEquityProfit reached. Auto-trading halted.");
         g_autoTrade = false;
         return;
        }
      if(InpMaxEquityLoss > 0.0 && equity <= balance - InpMaxEquityLoss)
        {
         LogWarning("OrderFlowEA — MaxEquityLoss hit. Auto-trading halted.");
         g_autoTrade = false;
         return;
        }
     }

   double spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(InpSpreadFilter && spreadPoints > InpMaxSpread * g_Pip) return;

   int nBars = ArraySize(g_bars);
   if(nBars < 2) return;

   int bi = nBars - 2;  // last closed bar
   if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0) return;
   if(!g_bars[bi].sorted) ComputeBarSignals(bi);

   // [FIX-1] Guard against a degenerate bar (no OHLC data yet) BEFORE any
   //         side-effects — most critically BEFORE DeleteAllPending().
   //         v6.00 placed this guard after DeleteAllPending() and the entry
   //         price calculation, so stale pending orders could be wiped and
   //         a wrong pending entry computed before the early-return fired.
   double barHigh = g_bars[bi].high;
   double barLow  = g_bars[bi].low;
   if(barHigh == 0.0 || barLow == 0.0)
     {
      LogWarning(StringFormat(
         "OrderFlowEA — PlaceOrders: bar[%d] has zero High/Low — skipping.",
         nBars - 2));
      return;
     }

   double hftScore = ComputeHFTSignal(bi);
   bool   isBuy    = (hftScore >=  (double)g_signalThreshold && InpAllowBuy);
   bool   isSell   = (hftScore <= -(double)g_signalThreshold && InpAllowSell);
   if(!isBuy && !isSell) return;

   if(!g_analysisMode && InpCleanOldOrders) DeleteAllPending();

   // [FIX-4] ATR warmup guard: CopyBuffer returns stale or garbage values
   //         for the first InpATR_Period closed bars.  Only trust the buffer
   //         once at least InpATR_Period + 1 bars exist on the chart.
   double atrBuf[];
   double atrVal = 0.0;
   int    barsOnChart = iBars(_Symbol, PERIOD_CURRENT);
   bool   atrReady    = (g_handleATR != INVALID_HANDLE) &&
                        (barsOnChart  > InpATR_Period + 1);
   if(atrReady && CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) == 1)
      atrVal = atrBuf[0];

   double bufDist = InpBufferPips * g_Pip;

   MqlTick lv;
   if(!SymbolInfoTick(_Symbol, lv))
     { LogTradeExec("OrderFlowEA — PlaceOrders: SymbolInfoTick failed"); return; }

   bool isMarket  = (InpOrderMode == ORDER_MODE_MARKET);
   bool direction = isBuy;

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

   int    hftInt    = (int)MathRound(MathAbs(hftScore));
   int    ofsScore  = ComputeOFScore(bi);
   string conviction= GetConvictionReason(bi, direction);

   string tag = StringFormat("FP_%s_%s_HFT%d|%s",
                             direction ? "Buy"  : "Sell",
                             isMarket  ? "MKT"  : "STP",
                             hftInt, conviction);

   ulong ticket = 0;
   bool  sent   = false;

   if(g_analysisMode)
     {
      // ── Analysis Mode ────────────────────────────────────────────────────
      // Assign a unique virtual ticket, draw markers with the "AN_" prefix,
      // and log to the journal — no order is ever submitted to the broker.
      ticket = g_virtualTicket++;

      LogTradeExec(StringFormat(
         "OrderFlowEA [ANALYSIS] VIRTUAL SIGNAL [%s] %s | #V%I64u | Entry: %s | SL: %s | TP: %s"
         " | Lot: %.2f (virtual) | HFT: %d | OFS: %d | Conviction: %s",
         direction ? "BUY" : "SELL", isMarket ? "MKT" : "STP",
         ticket,
         DoubleToString(entry,_Digits),
         DoubleToString(sl,   _Digits),
         DoubleToString(tp,   _Digits),
         lot, hftInt, ofsScore, conviction));

      DrawAnalysisEntry(ticket, direction, entry, sl, tp,
                        g_bars[bi].bar_time, conviction, hftInt, ofsScore);
     }
   else
     {
      // ── Live Trading ─────────────────────────────────────────────────────
      sent = trade_Send(action, orderType, entry, sl, tp, lot, tag, ticket);

      if(sent && ticket != 0)
        {
         LogTradeExec(StringFormat(
            "OrderFlowEA — ORDER PLACED [%s] %s | #%I64u | Entry: %s | SL: %s | TP: %s"
            " | Lot: %.2f | HFT: %d | OFS: %d | Conviction: %s",
            direction ? "BUY" : "SELL", isMarket ? "MKT" : "STP",
            ticket,
            DoubleToString(entry,_Digits),
            DoubleToString(sl,   _Digits),
            DoubleToString(tp,   _Digits),
            lot, hftInt, ofsScore, conviction));

         DrawTradeEntry(ticket, direction, entry, sl, tp,
                        g_bars[bi].bar_time, conviction, hftInt, ofsScore);
        }
     }
  }

//--- Real-time break-even and trailing stop management (every tick, throttled)
void ManagePositions()
  {
   if(!g_autoTrade)      return;
   if(!IsTradeAllowed()) return;

   // Throttle: only run at most once per FP_MANAGE_THROTTLE ms to reduce
   // redundant SymbolInfo calls on high-frequency tick streams.
   ulong now = GetTickCount64();  // 64-bit — no 49-day wraparound bug
   if(now - g_lastManageTick < FP_MANAGE_THROTTLE) return;
   g_lastManageTick = now;

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = MathMax((double)stopsLevel, 1.0) * _Point;

   // Snapshot bid/ask once for the whole loop instead of per-position
   double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double curAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != g_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;

      ENUM_POSITION_TYPE pType  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double             curSL  = PositionGetDouble(POSITION_SL);
      double             curTP  = PositionGetDouble(POSITION_TP);
      double             profit = (pType == POSITION_TYPE_BUY)
                                  ? (curBid - entry) / g_Pip
                                  : (entry  - curAsk) / g_Pip;

      double newSL = curSL;

      // Break-Even
      if(InpUseBreakEven && profit >= InpBreakEvenTrigger)
        {
         double beSL = (pType == POSITION_TYPE_BUY)
                       ? NormalizeDouble(entry + InpBreakEvenBuffer * g_Pip, _Digits)
                       : NormalizeDouble(entry - InpBreakEvenBuffer * g_Pip, _Digits);
         bool improvement = (pType == POSITION_TYPE_BUY)
                            ? (beSL > curSL + _Point)
                            : (beSL < curSL - _Point || curSL == 0.0);
         if(improvement)
           {
            double distEntry = (pType == POSITION_TYPE_BUY)
                               ? MathAbs(curBid - beSL) : MathAbs(curAsk - beSL);
            if(distEntry >= minDist) newSL = beSL;
           }
        }

      // Trailing Stop
      if(InpUseTrailing && profit >= InpTrailStart)
        {
         double trailSL = (pType == POSITION_TYPE_BUY)
                          ? NormalizeDouble(curBid - InpTrailStep * g_Pip, _Digits)
                          : NormalizeDouble(curAsk + InpTrailStep * g_Pip, _Digits);
         bool better = (pType == POSITION_TYPE_BUY)
                       ? (trailSL > newSL + _Point)
                       : (trailSL < newSL - _Point || newSL == 0.0);
         double distCur = (pType == POSITION_TYPE_BUY)
                          ? MathAbs(curBid - trailSL) : MathAbs(curAsk - trailSL);
         if(better && distCur >= minDist) newSL = trailSL;
        }

      if(MathAbs(newSL - curSL) > _Point / 2.0)
        {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};
         req.action   = TRADE_ACTION_SLTP;
         req.position = ticket;
         req.symbol   = _Symbol;
         req.sl       = NormalizeDouble(newSL, _Digits);
         req.tp       = NormalizeDouble(curTP, _Digits);
         req.magic    = g_Magic;

         bool modOk = false;
         for(int attempt = 1; attempt <= 3 && !modOk; attempt++)
           {
            modOk = OrderSend(req, res);
            if(!modOk)
              {
               uint rc = res.retcode;
               if(rc != TRADE_RETCODE_REQUOTE    &&
                  rc != TRADE_RETCODE_CONNECTION &&
                  rc != TRADE_RETCODE_TIMEOUT)
                  break;
               Sleep(200);
              }
           }
         if(modOk)
            UpdateSLLine(ticket, req.sl);   // keep chart line in sync
         else
            LogTradeExec(StringFormat(
               "OrderFlowEA — ManagePositions modify failed: ticket=%I64u retcode=%u newSL=%s tp=%s",
               ticket, res.retcode, DoubleToString(req.sl,_Digits), DoubleToString(req.tp,_Digits)));
        }
     }
  }

//==========================================================================
// SECTION 14: EA LIFECYCLE HANDLERS
//==========================================================================

int OnInit()
  {
   // --- Input validation ---
   if(_Point <= 0.0)
     { Alert("OrderFlowEA: Symbol point size is invalid."); return INIT_FAILED; }
   if(InpTickSize <= 0)
     { Alert("OrderFlowEA: InpTickSize must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(InpTickMultiplier <= 0)
     { Alert("OrderFlowEA: InpTickMultiplier must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(InpImbalanceRatio < 100.0)
     { Alert("OrderFlowEA: InpImbalanceRatio must be >= 100."); return INIT_PARAMETERS_INCORRECT; }
   if(InpVAPercent <= 0.0 || InpVAPercent > 100.0)
     { Alert("OrderFlowEA: InpVAPercent must be between 1 and 100."); return INIT_PARAMETERS_INCORRECT; }

   // [FIX-8] Additional input validation added in v6.01.
   if(InpStackedImbCount < 1)
     { Alert("OrderFlowEA: InpStackedImbCount must be >= 1."); return INIT_PARAMETERS_INCORRECT; }
   if(InpAbsorptionRatio <= 0.0)
     { Alert("OrderFlowEA: InpAbsorptionRatio must be > 0."); return INIT_PARAMETERS_INCORRECT; }
   if(InpExhaustionEnable && InpExhaustionCells < 1)
     { Alert("OrderFlowEA: InpExhaustionCells must be >= 1 when exhaustion detection is enabled."); return INIT_PARAMETERS_INCORRECT; }
   if(InpOFWtDelta + InpOFWtImb + InpOFWtStacked + InpOFWtAbsorb <= 0.0)
     { Alert("OrderFlowEA: OFS weights sum to zero — at least one weight must be positive."); return INIT_PARAMETERS_INCORRECT; }

   if(InpATEnable)
     {
      // [FIX-11] The lot formula no longer uses InpSLPips as a risk reference,
      // so no InpSLPips validation is required here for dynamic lot sizing.
      // InpSLPips is still validated below if the operator enables a fixed-pips
      // or ATR stop loss, because CalcSLTP() reads that field directly.

      if(InpUseStopLoss)
        {
         if((InpSLMode == SL_MODE_PIPS || InpSLMode == SL_MODE_ATR) && InpSLPips <= 0.0)
           { Alert("OrderFlowEA: InpSLPips must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if(InpSLMode == SL_MODE_ATR && InpSLATRMult <= 0.0)
           { Alert("OrderFlowEA: InpSLATRMult must be > 0."); return INIT_PARAMETERS_INCORRECT; }
        }
      if(InpUseTakeProfit)
        {
         if(InpTPMode == TP_MODE_RR && InpRiskRewardRatio <= 0.0)
           { Alert("OrderFlowEA: InpRiskRewardRatio must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if((InpTPMode == TP_MODE_PIPS || InpTPMode == TP_MODE_ATR) && InpTPPips <= 0.0)
           { Alert("OrderFlowEA: InpTPPips must be > 0."); return INIT_PARAMETERS_INCORRECT; }
         if(InpTPMode == TP_MODE_ATR && InpTPATRMult <= 0.0)
           { Alert("OrderFlowEA: InpTPATRMult must be > 0."); return INIT_PARAMETERS_INCORRECT; }
        }
      if(InpFixedLot <= 0.0 && !InpUseRiskPercent)
        { Alert("OrderFlowEA: InpFixedLot must be > 0."); return INIT_PARAMETERS_INCORRECT; }
      if(InpRiskPercent <= 0.0 && InpUseRiskPercent)
        { Alert("OrderFlowEA: InpRiskPercent must be > 0."); return INIT_PARAMETERS_INCORRECT; }
     }

   // --- Core state ---
   int pts = MathMax(1, MathMin(10000, InpTickSize));
   g_basePts  = pts;
   g_baseStep = g_basePts * _Point;

   int mul    = MathMax(1, MathMin(40, InpTickMultiplier));
   g_tickMult = mul;
   g_step     = g_baseStep * g_tickMult;

   g_chart    = ChartID();
   g_prevBid  = 0.0;
   g_imbRatio = InpImbalanceRatio;
   g_histBars = MathMax(FP_HIST_MIN, MathMin(FP_HIST_MAX, InpHistoryBars));
   g_vaPercent= (double)InpVAPercent;

   g_signalsEnabled  = InpShowSignals;
   g_signalFreqBars  = MathMax(1, InpSignalFreqBars);
   g_signalThreshold = MathMax(1, MathMin(99, InpSignalThreshold));
   g_lastSignalBar   = -9999;
   g_lastSignalBarTime = 0;

   g_autoTrade   = InpATEnable;
   g_analysisMode= InpAnalysisMode;
   g_Magic       = InpMagic;
   g_LastBarTime = 0;
   g_sigMarkerCount = 800000000UL;   // [FIX-DRAW] reset signal marker counter

   g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);

   RefreshSymbolInfo();

   g_handleATR = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
   if(g_handleATR == INVALID_HANDLE)
      LogWarning(StringFormat(
         "OrderFlowEA — ATR indicator handle could not be created (%d).", GetLastError()));

   ReloadHistory();

   LogSystem(StringFormat(
      "OrderFlowEA v6.05 — Initialised | Symbol: %s | TickSize: %dpts x%d | Step: %spts"
      " | HistoryBars: %d | AutoTrade: %s | AnalysisMode: %s | HasTrades: %s"
      " | LogMode: %s",
      _Symbol, g_basePts, g_tickMult, DoubleToString(g_step / _Point, 0),
      g_histBars,
      (g_autoTrade    ? "ON"  : "OFF"),
      (g_analysisMode ? "ON"  : "OFF"),
      (g_hasTrades    ? "YES" : "NO"),
      EnumToString(InpLogMode)));

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_handleATR != INVALID_HANDLE)
     { IndicatorRelease(g_handleATR); g_handleATR = INVALID_HANDLE; }

   CleanupAllTradeObjects();

   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++) ArrayFree(g_bars[i].levels);
   ArrayFree(g_bars);

   LogSystem(StringFormat("OrderFlowEA — Deinitialised (reason=%d).", reason));
  }

void OnTick()
  {
   // Full reload on first run or after forced flag
   if(ArraySize(g_bars) == 0)
     { ReloadHistory(); return; }

   if(g_needs_reload)
     { g_needs_reload = false; ReloadHistory(); }

   // Ingest new ticks since last seen
   MqlTick ticks[];
   uint    flag     = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long    now_msc  = (long)TimeCurrent() * 1000;
   long    from_msc = g_last_tick_time_ms;

   if(from_msc == 0)
     {
      long lookback = 60000;
      from_msc = (now_msc > lookback) ? now_msc - lookback : now_msc;
     }

   int copied = CopyTicksRange(_Symbol, ticks, flag, from_msc, now_msc);
   if(copied > 0)
     {
      if(g_prevBid == 0.0) g_prevBid = ticks[0].bid;
      ProcessTicks(ticks, 0, copied, true, true);
     }

   // Signal dispatch on live bar
   EvalAndFireSignal();

   // Automated trading + Analysis Mode
   ManagePositions();
   if(IsNewBar())
     {
      if(g_autoTrade || g_analysisMode) RefreshSymbolInfo();  // tick value needed for lot sizing
      PlaceOrders();
     }
  }

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   // [FIX-3] Set the reload flag rather than calling ReloadHistory() directly.
   //         OnChartEvent runs on the terminal UI thread; blocking it with a
   //         CopyTicksRange call (which can take hundreds of milliseconds for
   //         large histories) freezes the chart until the fetch completes.
   //         Setting g_needs_reload = true defers the reload to the next
   //         OnTick(), which executes on the EA thread where blocking is safe.
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if(ArraySize(g_bars) > 0)
        {
         int      bars_total       = iBars(_Symbol, PERIOD_CURRENT);
         int      span             = MathMin(g_histBars, bars_total - 1);
         datetime expectedFirstBar = iTime(_Symbol, PERIOD_CURRENT, span);
         datetime expectedLastBar  = iTime(_Symbol, PERIOD_CURRENT, 0);

         if(g_bars[0].bar_time != expectedFirstBar ||
            g_bars[ArraySize(g_bars) - 1].bar_time != expectedLastBar)
            g_needs_reload = true;   // processed safely in the next OnTick()
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction — captures closed deals for trade logging     |
//| Fires once per deal addition; filters by magic number and symbol |
//| so only this EA's trades on this chart appear in the journal.    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   // Only interested in completed deals added to the history
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   // Pull the deal record from history
   if(!HistoryDealSelect(trans.deal)) return;

   // Filter: must belong to this EA and this symbol
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != g_Magic) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)         return;

   // Only log closing deals (entry-side deals have DEAL_ENTRY_IN)
   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT) return;

   ENUM_DEAL_TYPE  dealType   = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double          dealPrice  = HistoryDealGetDouble(trans.deal,  DEAL_PRICE);
   double          dealVolume = HistoryDealGetDouble(trans.deal,  DEAL_VOLUME);
   double          dealProfit = HistoryDealGetDouble(trans.deal,  DEAL_PROFIT);
   double          dealSwap   = HistoryDealGetDouble(trans.deal,  DEAL_SWAP);
   double          dealComm   = HistoryDealGetDouble(trans.deal,  DEAL_COMMISSION);
   double          dealNet    = dealProfit + dealSwap + dealComm;
   datetime        dealTime   = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   ulong           ticket     = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   string          comment    = HistoryDealGetString(trans.deal,  DEAL_COMMENT);

   // DEAL_TYPE on a closing deal is the opposite of position direction:
   // closing a long = DEAL_TYPE_SELL, closing a short = DEAL_TYPE_BUY
   bool   wasLong = (dealType == DEAL_TYPE_SELL);
   string dir     = wasLong ? "LONG" : "SHORT";
   string pnlTag  = (dealNet >= 0.0) ? "WIN" : "LOSS";

   LogTradeClosed(StringFormat(
      "OrderFlowEA — CLOSED [%s] %s | Ticket: %I64u | Price: %s | Lot: %.2f"
      " | Profit: %.2f | Swap: %.2f | Comm: %.2f | Net: %.2f [%s] | Time: %s | Comment: %s",
      dir, _Symbol, ticket,
      DoubleToString(dealPrice, _Digits), dealVolume,
      dealProfit, dealSwap, dealComm, dealNet,
      pnlTag,
      TimeToString(dealTime, TIME_DATE | TIME_MINUTES),
      comment));

   // Draw exit marker and remove SL/TP lines from chart
   DrawTradeExit(ticket, wasLong, dealPrice, dealNet, dealTime);
  }
