//+------------------------------------------------------------------+
//|                                                    Footprint.mq5 |
//|   Footprint (Order Flow) - Production Ready                      |
//|   Strict Footprint Ladder Grid Edition                           |
//+------------------------------------------------------------------+
//
// PASS 0 — DIAGNOSIS (why current output can differ from target):
// - Single continuous grid: Fixed by per-bar col_left (Pass 1); each bar uses
//   ChartTimePriceToXY(bt,...) and col_left = x(i) + candle_step_px/2 + x_padding.
// - Scattered numbers: Fixed by one Bid/Ask pair per row in DrawGridCell (Pass 4),
//   two OBJ_LABELs per cell, monospace Consolas.
// - Coloring: Heatmap is intensity = totalVol/maxTotal, gradient; overlays (POC,
//   imbalance) applied after so they stay visible (Pass 5, 6).
// - Normalization: No clamping; bid/ask are raw from ticks; IntegerToString(bV/aV).
//
// PASS 1–7: Per-bar columns, fixed ladder step, raw tick bid/ask, one "Bid Ask" per
// cell, heatmap by intensity, POC + stacked imbalance, pooling + visible bars + events.
//
#property copyright "Ali Magdy"
#property version   "2.01"
#property description "Strict Grid-Based Footprint Chart"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Chart mode
//--- Layout alignment
enum ENUM_FOOT_ALIGN_MODE
  {
   FOOT_ALIGN_LEFT   = 0,
   FOOT_ALIGN_CENTER = 1,
   FOOT_ALIGN_RIGHT  = 2
  };

//--- Chart mode
enum ENUM_FOOT_CHART_MODE
  {
   FOOT_CHART_VOLUME = 0,
   FOOT_CHART_DELTA  = 1,
   FOOT_CHART_BIDASK = 2
  };

//--- Inputs
input group "Data & History"
input int    InpTickSize        = 10;           // Base cell size (points), 1 point = 1×_Point
input double InpImbalanceRatio  = 300.0;        // Imbalance Threshold (%)
input int    InpStackedImbCount = 3;            // Stacked Imbalance Min Count
input double InpAbsorptionRatio = 4.0;          // Absorption Threshold (x Avg Vol)
input int    InpHistoryBars     = 100;          // History bars to load
input double InpVAPercent       = 70.0;         // Value Area % (industry default 70)

input group "Aggregation"
input ENUM_FOOT_CHART_MODE InpChartMode      = FOOT_CHART_BIDASK; // Chart mode
input int                  InpTicksPerRow    = 2;                 // Ticks per row (step_price = tick_size * this; reduces fragmentation)
input int                  InpTickMultiplier = 1;                 // [Legacy] Tick multiplier (use InpTicksPerRow)

input group "Strict Grid Layout"
input ENUM_FOOT_ALIGN_MODE InpAlignMode = FOOT_ALIGN_RIGHT; // Column alignment to candle
input int    InpXOffsetPx       = 4;            // X-Offset distance from candle limit
input int    InpRowHeightPx     = 18;           // Height of each price level cell (pixels)
input int    InpFontSize        = 10;           // Font size for volume text
input int    InpCellPaddingPx   = 2;            // Padding inside cells (left/right margins)
input int    InpMaxBarsToRender = 20;           // Max bars (most recent only; rightmost on chart)
input int    InpBarGapPx        = 8;            // Gap between footprint columns
input color  InpSeparatorColor  = clrBlack;     // Bar separator line color
input color  InpBarOutlineColor = clrBlack;     // Bar column outline color

input group "Colors - Heatmap"
input color  InpBidBaseColor   = C'230,250,230';   // Bid Volume Base (Green)
input color  InpBidHighColor   = C'40,160,40';     // Bid Volume High (Green)
input color  InpAskBaseColor   = C'250,230,230';   // Ask Volume Base (Red)
input color  InpAskHighColor   = C'240,80,40';     // Ask Volume High (Red/Orange)
input color  InpOutOfVAColor   = C'200,200,200';   // Out of Value Area Color (grid cell bg)
input color  InpEmptyCellColor = C'254,254,224';   // Grid cell background with 0 volume

input group "Colors - Highlights & UI"
input color  InpImbSellColor    = clrRed;         // Sell Imbalance Border
input color  InpImbBuyColor     = clrForestGreen; // Buy Imbalance Border
input color  InpStackedSellColor= clrRed;     
input color  InpStackedBuyColor = clrForestGreen; 
input color  InpUnfinishedColor = clrDodgerBlue;  
input color  InpAbsorptionColor = clrMagenta;     
input color  InpPOCColor        = clrDarkOrange;  // POC Border Highlight
input color  InpGridLineColor   = C'235,235,235'; // Grid Cell Border Color

//--- Data structures
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
   PriceLevel levels[];
  };

//--- Strict Grid Object Pool
struct CellObjects
  {
   string bg_track;   // Solid background behind entire text + histogram
   string rect_bid;
   string rect_ask;
   string hist_name;
   string bid_name;
   string ask_name;
   string vgrid_line; // 1px vertical row separator
   string hgrid_line; // 1px horizontal row separator
   bool   active;
  };

CellObjects g_pool[];
int g_poolCount = 0;
int g_poolActive = 0;

// UI Box elements (for POC, Outlines, Stacked Imbalances)
struct HollowBoxObjects
  {
   string top_line;
   string bot_line;
   string left_line;
   string right_line;
   bool   active;
  };

HollowBoxObjects g_boxPool[];
int g_boxCount = 0;
int g_boxActive = 0;

// Bar separators (thin vertical line between footprint columns)
string g_sepNames[];
int    g_sepCount = 0;
int    g_sepActive = 0;

//--- Globals
FPBar                g_bars[];
double               g_step;         
double               g_baseStep;     
int                  g_tickMult = 1; 
ENUM_FOOT_CHART_MODE g_mode    = FOOT_CHART_BIDASK;
long                 g_chart;
int                  g_sub;
bool                 g_hasTrades;
double               g_prevBid;
bool                 g_dirty;
double               g_imbRatio;     
long                 g_last_tick_time_ms = 0;
ulong                g_last_render_ms    = 0;
bool                 g_visible   = true;
double               g_vaPercent = 0;
int                  g_yOffsetPx = 0; // Vertical offset for level panning

// UI Box coords
int g_btnUpX1, g_btnUpY1, g_btnUpX2, g_btnUpY2;
int g_btnDnX1, g_btnDnY1, g_btnDnX2, g_btnDnY2;
int g_btnCX1,  g_btnCY1,  g_btnCX2,  g_btnCY2;

#define FP_RENDER_THROTTLE_MS   33

//+------------------------------------------------------------------+
//| Math & Colors                                                    |
//+------------------------------------------------------------------+
double NormP(double p) { return MathFloor(p / g_step) * g_step; }

color LerpColorOpaque(color a, color b, double t)
  {
   if(t < 0.0) t = 0.0;
   if(t > 1.0) t = 1.0;
   int r  = (int)((1.0 - t) * (a & 0xFF) + t * (b & 0xFF));
   int g  = (int)((1.0 - t) * ((a >> 8) & 0xFF) + t * ((b >> 8) & 0xFF));
   int bl = (int)((1.0 - t) * ((a >> 16) & 0xFF) + t * ((b >> 16) & 0xFF));
   return (color)((bl << 16) | (g << 8) | r);
  }

//+------------------------------------------------------------------+
//| Array Search / Sorting                                           |
//+------------------------------------------------------------------+
int FindBarIndex(datetime bt)
  {
   int lo = 0, hi = ArraySize(g_bars) - 1;
   while(lo <= hi) {
      int mid = (lo + hi) / 2;
      if(g_bars[mid].bar_time == bt) return mid;
      if(g_bars[mid].bar_time < bt) lo = mid + 1;
      else hi = mid - 1;
   }
   return -1;
  }

int InsertBar(datetime bt)
  {
   int n = ArraySize(g_bars);
   int pos = n;
   for(int i = n - 1; i >= 0; i--) {
      if(g_bars[i].bar_time == bt) return i;
      if(g_bars[i].bar_time < bt) { pos = i + 1; break; }
      pos = i;
   }
   ArrayResize(g_bars, n + 1, 128);
   for(int i = n; i > pos; i--) {
      g_bars[i].bar_time    = g_bars[i - 1].bar_time;
      g_bars[i].total_vol   = g_bars[i - 1].total_vol;
      g_bars[i].total_delta = g_bars[i - 1].total_delta;
      g_bars[i].sorted      = g_bars[i - 1].sorted;
      g_bars[i].level_count = g_bars[i - 1].level_count;
      int cap = ArraySize(g_bars[i - 1].levels);
      ArrayResize(g_bars[i].levels, MathMax(cap, 64), 64);
      if(cap > 0) ArrayCopy(g_bars[i].levels, g_bars[i - 1].levels, 0, 0, cap);
   }
   g_bars[pos].bar_time    = bt;
   g_bars[pos].total_vol   = 0;
   g_bars[pos].total_delta = 0;
   g_bars[pos].sorted      = true;
   g_bars[pos].is_bullish  = true;
   g_bars[pos].level_count = 0;
   ArrayResize(g_bars[pos].levels, 64, 64);
   return pos;
  }

int GetBar(datetime bt)
  {
   int idx = FindBarIndex(bt);
   if(idx >= 0) return idx;
   return InsertBar(bt);
  }

void SortLevelsPartition(PriceLevel &lv[], int lo, int hi)
  {
   if(lo >= hi) return;
   double pivot = lv[hi].price;
   int i = lo - 1;
   for(int j = lo; j < hi; j++) {
      if(lv[j].price >= pivot) {
         i++;
         PriceLevel tmp = lv[i]; lv[i] = lv[j]; lv[j] = tmp;
      }
   }
   i++;
   PriceLevel tmp = lv[i]; lv[i] = lv[hi]; lv[hi] = tmp;
   SortLevelsPartition(lv, lo, i - 1);
   SortLevelsPartition(lv, i + 1, hi);
  }

void SortLevels(PriceLevel &lv[], int n)
  {
   if(n <= 1) return;
   SortLevelsPartition(lv, 0, n - 1);
  }

int FindPOC(const PriceLevel &lv[], int count)
  {
   int best = -1; long mx = 0;
   for(int i = 0; i < count; i++) {
      if(lv[i].total_vol > mx) { mx = lv[i].total_vol; best = i; }
   }
   return best;
  }

double GetEffectiveVAPercent() { return (g_vaPercent > 0.0) ? g_vaPercent : InpVAPercent; }

void FindVA(const PriceLevel &lv[], int count, long totVol, int poc, int &lo, int &hi)
  {
   lo = poc; hi = poc;
   if(poc < 0) return;
   long target = (long)(totVol * GetEffectiveVAPercent() / 100.0);
   long cur = lv[poc].total_vol;
   while(cur < target && (lo > 0 || hi < count - 1)) {
      long up = (hi < count - 1) ? lv[hi + 1].total_vol : -1;
      long dn = (lo > 0) ? lv[lo - 1].total_vol : -1;
      if(up >= dn && up != -1) { hi++; cur += up; }
      else if(dn != -1) { lo--; cur += dn; }
      else break;
   }
  }

//+------------------------------------------------------------------+
//| Tick Accumulator / Processing                                    |
//+------------------------------------------------------------------+
void AccumulateTick(int bi, double price, long vol, bool isBuy, bool isSell)
  {
   if(price == 0.0) return;
   price = NormP(price);
   int used = g_bars[bi].level_count;
   int idx  = -1;
   for(int i = used - 1; i >= 0; i--) {
      if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.4) {
         idx = i; break;
      }
   }
   if(idx == -1) {
      if(used >= ArraySize(g_bars[bi].levels))
         ArrayResize(g_bars[bi].levels, used + 64, 64);
      idx = used;
      g_bars[bi].levels[idx].price     = price;
      g_bars[bi].levels[idx].bid_vol   = 0;
      g_bars[bi].levels[idx].ask_vol   = 0;
      g_bars[bi].levels[idx].total_vol = 0;
      g_bars[bi].levels[idx].delta     = 0;
      g_bars[bi].levels[idx].is_stacked_imb_buy  = false;
      g_bars[bi].levels[idx].is_stacked_imb_sell = false;
      g_bars[bi].levels[idx].is_unfinished_hi    = false;
      g_bars[bi].levels[idx].is_unfinished_lo    = false;
      g_bars[bi].level_count++;
      g_bars[bi].sorted = false;
   }
   if(isBuy)  g_bars[bi].levels[idx].ask_vol += vol;
   if(isSell) g_bars[bi].levels[idx].bid_vol += vol;
   g_bars[bi].levels[idx].total_vol += vol;
   g_bars[bi].levels[idx].delta = g_bars[bi].levels[idx].ask_vol - g_bars[bi].levels[idx].bid_vol;
   g_bars[bi].total_vol += vol;
   g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));
   g_dirty = true;
  }

void ComputeBarSignals(int bi)
  {
   int len = g_bars[bi].level_count;
   if(len <= 0) return;
   if(!g_bars[bi].sorted) {
      SortLevels(g_bars[bi].levels, len);
      g_bars[bi].sorted = true;
   }
   g_bars[bi].poc_idx = FindPOC(g_bars[bi].levels, len);
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, g_bars[bi].poc_idx,
          g_bars[bi].va_lo_idx, g_bars[bi].va_hi_idx);

   // Task: imbalance = Ask >= Bid*R (buy), Bid >= Ask*R (sell); R = InpImbalanceRatio as ratio (300 -> 3.0)
   double R = InpImbalanceRatio / 100.0;
   if(R < 0.1) R = 0.1;
   long avgVol = (len > 0) ? (g_bars[bi].total_vol / len) : 1;
   for(int i = 0; i < len; i++) {
      g_bars[bi].levels[i].is_imb_buy          = false;
      g_bars[bi].levels[i].is_imb_sell         = false;
      g_bars[bi].levels[i].is_stacked_imb_buy  = false;
      g_bars[bi].levels[i].is_stacked_imb_sell = false;
      g_bars[bi].levels[i].is_unfinished_hi    = false;
      g_bars[bi].levels[i].is_unfinished_lo    = false;
      g_bars[bi].levels[i].is_absorption       = (g_bars[bi].levels[i].total_vol > avgVol * InpAbsorptionRatio);

      long bv = g_bars[bi].levels[i].bid_vol;
      long av = g_bars[bi].levels[i].ask_vol;
      if(bv > 0 && av >= (long)((double)bv * R)) g_bars[bi].levels[i].is_imb_buy  = true;
      if(av > 0 && bv >= (long)((double)av * R)) g_bars[bi].levels[i].is_imb_sell = true;
   }
   int countBuy = 0, countSell = 0;
   for(int i = 0; i < len; i++) {
      if(g_bars[bi].levels[i].is_imb_buy) countBuy++;
      else {
         if(countBuy >= InpStackedImbCount)
            for(int j = i - countBuy; j < i; j++) g_bars[bi].levels[j].is_stacked_imb_buy = true;
         countBuy = 0;
      }
      if(g_bars[bi].levels[i].is_imb_sell) countSell++;
      else {
         if(countSell >= InpStackedImbCount)
            for(int j = i - countSell; j < i; j++) g_bars[bi].levels[j].is_stacked_imb_sell = true;
         countSell = 0;
      }
   }
   if(countBuy >= InpStackedImbCount)
      for(int j = len - countBuy; j < len; j++) g_bars[bi].levels[j].is_stacked_imb_buy = true;
   if(countSell >= InpStackedImbCount)
      for(int j = len - countSell; j < len; j++) g_bars[bi].levels[j].is_stacked_imb_sell = true;

   if(len > 1) {
      g_bars[bi].levels[0].is_unfinished_hi = (g_bars[bi].levels[0].ask_vol > 0 && g_bars[bi].levels[0].bid_vol > 0);
      g_bars[bi].levels[len - 1].is_unfinished_lo = (g_bars[bi].levels[len - 1].bid_vol > 0 && g_bars[bi].levels[len - 1].ask_vol > 0);
   }
  }

// PASS 3: last >= ask-eps -> askVol, last <= bid+eps -> bidVol (raw volumes, no clamping)
void Classify(const MqlTick &t, bool &isBuy, bool &isSell)
  {
   isBuy  = false;
   isSell = false;
   double eps = _Point * 0.5;
   if(g_hasTrades) {
      isBuy  = (t.flags & TICK_FLAG_BUY) == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
      if(!isBuy && !isSell) {
         if(t.ask > 0.0 && t.last >= t.ask - eps) isBuy = true;
         else if(t.bid > 0.0 && t.last <= t.bid + eps) isSell = true;
      }
   } else {
      if(t.bid > g_prevBid) isBuy = true;
      else if(t.bid < g_prevBid) isSell = true;
      else isBuy = true;
   }
  }

void ProcessTicks(MqlTick &ticks[], int startIdx, int count, bool skipAlreadySeen, bool updateLastTimeMs)
  {
   if(count <= 0) return;
   int endIdx = startIdx + count;
   if(endIdx > ArraySize(ticks)) endIdx = ArraySize(ticks);
   for(int i = startIdx; i < endIdx; i++) {
      if(skipAlreadySeen && ticks[i].time_msc <= g_last_tick_time_ms) continue;
      double price; long vol;
      if(g_hasTrades) {
         price = ticks[i].last; vol = (long)ticks[i].volume;
         if(vol <= 0 || price == 0.0) continue;
      } else {
         price = ticks[i].bid; 
         vol = (long)ticks[i].volume_real;
         if (vol <= 0) vol = (long)ticks[i].volume;
         if (vol <= 0) vol = 1; // absolute fallback
         if(price == 0.0) continue;
      }
      bool isBuy, isSell;
      Classify(ticks[i], isBuy, isSell);
      if(ticks[i].bid != 0.0) g_prevBid = ticks[i].bid;
      int sh = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
      if(sh < 0) continue;
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, sh);
      int bi = GetBar(bt);
      
      double bOpen  = iOpen(_Symbol, PERIOD_CURRENT, sh);
      double bClose = iClose(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].is_bullish = (bClose >= bOpen);
      g_bars[bi].high       = iHigh(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].low        = iLow(_Symbol, PERIOD_CURRENT, sh);

      AccumulateTick(bi, price, vol, isBuy, isSell);
      ComputeBarSignals(bi);
      if(updateLastTimeMs) g_last_tick_time_ms = ticks[i].time_msc;
   }
  }

int LoadHistory(datetime t0, datetime t1)
  {
   MqlTick ticks[];
   uint flag = COPY_TICKS_ALL; // force pulling volumes always
   int copied = CopyTicksRange(_Symbol, ticks, flag, (long)t0 * 1000, (long)t1 * 1000);
   if(copied <= 0) return -1;
   g_prevBid = ticks[0].bid;
   ProcessTicks(ticks, 0, copied, false, true);
   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++) {
      SortLevels(g_bars[i].levels, g_bars[i].level_count);
      g_bars[i].sorted = true;
   }
   g_dirty = true;
   return copied;
  }

void ReloadHistory()
  {
   g_dirty = false;
   ArrayFree(g_bars);
   g_last_tick_time_ms = 0;
   int bars_total = iBars(_Symbol, PERIOD_CURRENT);
   if(bars_total <= 0) return;
   int span = MathMin(InpHistoryBars, bars_total - 1);
   datetime startTime = iTime(_Symbol, PERIOD_CURRENT, span);
   datetime endTime   = TimeCurrent();
   int loaded = LoadHistory(startTime, endTime);
   if(loaded > 0) g_dirty = true;
  }

//+------------------------------------------------------------------+
//| Strict Grid Object Pool Manager                                  |
//+------------------------------------------------------------------+
void InitPool(int required)
  {
   if(required <= g_poolCount) return;
   int old = g_poolCount;
   g_poolCount = required;
   ArrayResize(g_pool, g_poolCount);
   for(int i = old; i < g_poolCount; i++) {
      g_pool[i].bg_track  = "FP_BG_" + IntegerToString(i);
      g_pool[i].rect_bid  = "FP_RB_" + IntegerToString(i);
      g_pool[i].rect_ask  = "FP_RA_" + IntegerToString(i);
      g_pool[i].hist_name = "FP_H_" + IntegerToString(i);
      g_pool[i].bid_name  = "FP_B_" + IntegerToString(i);
      g_pool[i].ask_name  = "FP_A_" + IntegerToString(i);
      g_pool[i].vgrid_line = "FP_VG_" + IntegerToString(i);
      g_pool[i].hgrid_line = "FP_HG_" + IntegerToString(i);
      g_pool[i].active    = false;
      
      // Full Track Background
      ObjectCreate(g_chart, g_pool[i].bg_track, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].bg_track, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].bg_track, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, g_pool[i].bg_track, OBJPROP_BACK, true);
      ObjectSetInteger(g_chart, g_pool[i].bg_track, OBJPROP_WIDTH, 0);
      ObjectSetInteger(g_chart, g_pool[i].bg_track, OBJPROP_XDISTANCE, -1000);

      // Bid Background Left Half
      ObjectCreate(g_chart, g_pool[i].rect_bid, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].rect_bid, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].rect_bid, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, g_pool[i].rect_bid, OBJPROP_BACK, true);
      ObjectSetInteger(g_chart, g_pool[i].rect_bid, OBJPROP_WIDTH, 0);
      ObjectSetInteger(g_chart, g_pool[i].rect_bid, OBJPROP_XDISTANCE, -1000);

      // Ask Background Right Half
      ObjectCreate(g_chart, g_pool[i].rect_ask, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].rect_ask, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].rect_ask, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, g_pool[i].rect_ask, OBJPROP_BACK, true);
      ObjectSetInteger(g_chart, g_pool[i].rect_ask, OBJPROP_WIDTH, 0);
      ObjectSetInteger(g_chart, g_pool[i].rect_ask, OBJPROP_XDISTANCE, -1000);

      // Right Histogram
      ObjectCreate(g_chart, g_pool[i].hist_name, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].hist_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].hist_name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, g_pool[i].hist_name, OBJPROP_BACK, true);
      ObjectSetInteger(g_chart, g_pool[i].hist_name, OBJPROP_WIDTH, 0); 
      ObjectSetInteger(g_chart, g_pool[i].hist_name, OBJPROP_XDISTANCE, -1000);

      // Revert Dotted to Label for solid support
      ObjectCreate(g_chart, g_pool[i].hgrid_line, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].hgrid_line, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].hgrid_line, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, g_pool[i].hgrid_line, OBJPROP_BACK, false);
      ObjectSetInteger(g_chart, g_pool[i].hgrid_line, OBJPROP_WIDTH, 0); 
      ObjectSetInteger(g_chart, g_pool[i].hgrid_line, OBJPROP_XDISTANCE, -1000);
      
      // Revert Dotted to Label for solid support
      ObjectCreate(g_chart, g_pool[i].vgrid_line, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].vgrid_line, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].vgrid_line, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, g_pool[i].vgrid_line, OBJPROP_BACK, false);
      ObjectSetInteger(g_chart, g_pool[i].vgrid_line, OBJPROP_WIDTH, 0); 
      ObjectSetInteger(g_chart, g_pool[i].vgrid_line, OBJPROP_XDISTANCE, -1000);
      
      ObjectCreate(g_chart, g_pool[i].bid_name, OBJ_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].bid_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].bid_name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].bid_name, OBJPROP_BACK, false);
      ObjectSetString(g_chart, g_pool[i].bid_name, OBJPROP_TEXT, " ");
      ObjectSetInteger(g_chart, g_pool[i].bid_name, OBJPROP_XDISTANCE, -1000);
      
      ObjectCreate(g_chart, g_pool[i].ask_name, OBJ_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_pool[i].ask_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].ask_name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_pool[i].ask_name, OBJPROP_BACK, false);
      ObjectSetString(g_chart, g_pool[i].ask_name, OBJPROP_TEXT, " ");
      ObjectSetInteger(g_chart, g_pool[i].ask_name, OBJPROP_XDISTANCE, -1000);
   }
  }

void ResetPool() { g_poolActive = 0; }

void HideUnusedPool()
  {
   for(int i = g_poolActive; i < g_poolCount; i++) {
      if(!g_pool[i].active) continue;
      ObjectSetInteger(g_chart, g_pool[i].bg_track, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].rect_bid, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].rect_ask, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].hist_name, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].bid_name, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].ask_name, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].vgrid_line, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_pool[i].hgrid_line, OBJPROP_XDISTANCE, -1000);
      g_pool[i].active = false;
   }
  }

int GetNextCell()
  {
   if(g_poolActive >= g_poolCount) InitPool(g_poolCount + 1000);
   int idx = g_poolActive++;
   g_pool[idx].active = true;
   return idx;
  }

void DrawGridCell(int x_left, int y_top, int barWidthPx, int fullTrackW, string sBid, string sAsk, color bgBid, color bgAsk, string bidFontStr, string askFontStr, color txtCol, int histWidthPx, color histColor)
  {
   int idx = GetNextCell();
   if(barWidthPx < 10) barWidthPx = 10;
   
   int halfW = barWidthPx / 2;
   int center_x = x_left + halfW;
   int textY = y_top + (InpRowHeightPx - InpFontSize) / 2 - 1;
   int MAX_HIST_W = fullTrackW - barWidthPx;

   // Solid Background Track purely behind histogram
   ObjectSetInteger(g_chart, g_pool[idx].bg_track, OBJPROP_XDISTANCE, x_left + barWidthPx);
   ObjectSetInteger(g_chart, g_pool[idx].bg_track, OBJPROP_YDISTANCE, y_top);
   ObjectSetInteger(g_chart, g_pool[idx].bg_track, OBJPROP_XSIZE, MAX_HIST_W);
   ObjectSetInteger(g_chart, g_pool[idx].bg_track, OBJPROP_YSIZE, InpRowHeightPx);
   ObjectSetInteger(g_chart, g_pool[idx].bg_track, OBJPROP_BGCOLOR, C'43,43,43');
   ObjectSetInteger(g_chart, g_pool[idx].bg_track, OBJPROP_COLOR, C'43,43,43');

   // Split Bid Background
   ObjectSetInteger(g_chart, g_pool[idx].rect_bid, OBJPROP_XDISTANCE, x_left);
   ObjectSetInteger(g_chart, g_pool[idx].rect_bid, OBJPROP_YDISTANCE, y_top);
   ObjectSetInteger(g_chart, g_pool[idx].rect_bid, OBJPROP_XSIZE, halfW);
   ObjectSetInteger(g_chart, g_pool[idx].rect_bid, OBJPROP_YSIZE, InpRowHeightPx);
   ObjectSetInteger(g_chart, g_pool[idx].rect_bid, OBJPROP_BGCOLOR, bgBid);
   ObjectSetInteger(g_chart, g_pool[idx].rect_bid, OBJPROP_COLOR, bgBid);

   // Split Ask Background
   ObjectSetInteger(g_chart, g_pool[idx].rect_ask, OBJPROP_XDISTANCE, center_x);
   ObjectSetInteger(g_chart, g_pool[idx].rect_ask, OBJPROP_YDISTANCE, y_top);
   ObjectSetInteger(g_chart, g_pool[idx].rect_ask, OBJPROP_XSIZE, barWidthPx - halfW);
   ObjectSetInteger(g_chart, g_pool[idx].rect_ask, OBJPROP_YSIZE, InpRowHeightPx);
   ObjectSetInteger(g_chart, g_pool[idx].rect_ask, OBJPROP_BGCOLOR, bgAsk);
   ObjectSetInteger(g_chart, g_pool[idx].rect_ask, OBJPROP_COLOR, bgAsk);

   // Histogram Overlay
   if (histWidthPx > 0) {
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_XDISTANCE, x_left + barWidthPx);
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_YDISTANCE, y_top + 4);
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_XSIZE, histWidthPx);
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_YSIZE, InpRowHeightPx - 8);
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_BGCOLOR, histColor);
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_COLOR, histColor);
   } else {
       ObjectSetInteger(g_chart, g_pool[idx].hist_name, OBJPROP_XDISTANCE, -1000);
   }

   // Solid Layout Dividers instead of thin dotted lines
   // Exact 1px vertical line in center
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_XDISTANCE, center_x);
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_YDISTANCE, y_top);
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_XSIZE, 1);
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_YSIZE, InpRowHeightPx);
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_BGCOLOR, C'180,180,180');
   ObjectSetInteger(g_chart, g_pool[idx].vgrid_line, OBJPROP_COLOR, C'180,180,180');

   // Exact 1px horizontal line along bottom spans full Track
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_XDISTANCE, x_left);
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_YDISTANCE, y_top + InpRowHeightPx - 1);
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_XSIZE, fullTrackW);
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_YSIZE, 1);
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_BGCOLOR, C'180,180,180');
   ObjectSetInteger(g_chart, g_pool[idx].hgrid_line, OBJPROP_COLOR, C'180,180,180');

   // Bid Text - Right aligned uniformly
   ObjectSetInteger(g_chart, g_pool[idx].bid_name, OBJPROP_XDISTANCE, center_x - 2);
   ObjectSetInteger(g_chart, g_pool[idx].bid_name, OBJPROP_YDISTANCE, textY);
   ObjectSetString (g_chart, g_pool[idx].bid_name, OBJPROP_TEXT, sBid);
   ObjectSetString (g_chart, g_pool[idx].bid_name, OBJPROP_FONT, bidFontStr);
   ObjectSetInteger(g_chart, g_pool[idx].bid_name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(g_chart, g_pool[idx].bid_name, OBJPROP_COLOR, txtCol);

   // Ask Text - Left aligned uniformly
   ObjectSetInteger(g_chart, g_pool[idx].ask_name, OBJPROP_XDISTANCE, center_x + 2);
   ObjectSetInteger(g_chart, g_pool[idx].ask_name, OBJPROP_YDISTANCE, textY);
   ObjectSetString (g_chart, g_pool[idx].ask_name, OBJPROP_TEXT, sAsk);
   ObjectSetString (g_chart, g_pool[idx].ask_name, OBJPROP_FONT, askFontStr);
   ObjectSetInteger(g_chart, g_pool[idx].ask_name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(g_chart, g_pool[idx].ask_name, OBJPROP_COLOR, txtCol);
  }

//+------------------------------------------------------------------+
//| UI Controls Render                                               |
//+------------------------------------------------------------------+
void LayoutUIControls(int cw, int ch)
  {
   int btnW = 30;
   int btnH = 20;
   int gap = 4;
   int marginRight = 10;
   int marginBottom = 20;

   // Layout: [ ^ ] [ v ] [ C ] positioned bot right
   g_btnCX2 = cw - marginRight;
   g_btnCX1 = g_btnCX2 - btnW;
   g_btnCY2 = ch - marginBottom;
   g_btnCY1 = g_btnCY2 - btnH; 

   g_btnDnX2 = g_btnCX1 - gap;
   g_btnDnX1 = g_btnDnX2 - btnW;
   g_btnDnY2 = g_btnCY2;
   g_btnDnY1 = g_btnCY1;

   g_btnUpX2 = g_btnDnX1 - gap;
   g_btnUpX1 = g_btnUpX2 - btnW;
   g_btnUpY2 = g_btnCY2;
   g_btnUpY1 = g_btnCY1;
  }

void CreateUIButton(string name, int x, int y, int w, int h, string text, color bg)
  {
   if(ObjectFind(g_chart, name) < 0) {
      ObjectCreate(g_chart, name, OBJ_BUTTON, g_sub, 0, 0);
      ObjectSetInteger(g_chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(g_chart, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(g_chart, name, OBJPROP_FONTSIZE, 9);
   }
   ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(g_chart, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(g_chart, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(g_chart, name, OBJPROP_YSIZE, h);
   ObjectSetString(g_chart, name, OBJPROP_TEXT, text);
   ObjectSetInteger(g_chart, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(g_chart, name, OBJPROP_BORDER_COLOR, clrDarkGray);
   ObjectSetInteger(g_chart, name, OBJPROP_STATE, false);
  }

void DrawUI()
  {
   CreateUIButton("FP_BTN_UP", g_btnUpX1, g_btnUpY1, g_btnUpX2 - g_btnUpX1, g_btnUpY2 - g_btnUpY1, "^", C'40,40,50');
   CreateUIButton("FP_BTN_DN", g_btnDnX1, g_btnDnY1, g_btnDnX2 - g_btnDnX1, g_btnDnY2 - g_btnDnY1, "v", C'40,40,50');
   CreateUIButton("FP_BTN_C",  g_btnCX1,  g_btnCY1,  g_btnCX2 - g_btnCX1,   g_btnCY2 - g_btnCY1,   "C", C'40,40,50');
  }

//+------------------------------------------------------------------+
//| Coordinate Helpers                                               |
//+------------------------------------------------------------------+
int GetBarX(datetime time)
  {
   int x, y;
   if(ChartTimePriceToXY(g_chart, g_sub, time, 0.0, x, y)) return x;
   return -1;
  }

int GetPriceY(datetime time, double price)
  {
   int x, y;
   if(ChartTimePriceToXY(g_chart, g_sub, time, price, x, y)) return y;
   return -1;
  }

// Candle pixel width (from bar time to next period); used to place footprint RIGHT of candle.
int GetCandleWidthPx(datetime bt)
  {
   datetime nextTime = bt + PeriodSeconds(PERIOD_CURRENT);
   int x0 = GetBarX(bt);
   int x1 = GetBarX(nextTime);
   if(x1 > x0) return x1 - x0;
   return 40; // fallback
  }

void InitSeparators(int required)
  {
   if(required <= g_sepCount) return;
   int old = g_sepCount;
   g_sepCount = required;
   ArrayResize(g_sepNames, g_sepCount);
   for(int i = old; i < g_sepCount; i++) {
      g_sepNames[i] = "FP_SEP_" + IntegerToString(i);
      ObjectCreate(g_chart, g_sepNames[i], OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_BACK, true);
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_XSIZE, 1);
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_BGCOLOR, InpSeparatorColor);
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_BORDER_TYPE, BORDER_FLAT);
   }
  }

void DrawSeparator(int x, int y_top, int heightPx)
  {
   if(g_sepActive >= g_sepCount) InitSeparators(g_sepCount + InpMaxBarsToRender);
   if(g_sepActive >= g_sepCount) return;
   ObjectSetInteger(g_chart, g_sepNames[g_sepActive], OBJPROP_XDISTANCE, x);
   ObjectSetInteger(g_chart, g_sepNames[g_sepActive], OBJPROP_YDISTANCE, y_top);
   ObjectSetInteger(g_chart, g_sepNames[g_sepActive], OBJPROP_YSIZE, MathMax(1, heightPx));
   g_sepActive++;
  }

void HideUnusedSeparators()
  {
   for(int i = g_sepActive; i < g_sepCount; i++)
      ObjectSetInteger(g_chart, g_sepNames[i], OBJPROP_XDISTANCE, -1000);
  }

void ObjectInitRect(string name, int zorder=0) {
    ObjectCreate(g_chart, name, OBJ_RECTANGLE_LABEL, g_sub, 0, 0);
    ObjectSetInteger(g_chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(g_chart, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(g_chart, name, OBJPROP_BACK, false);
    ObjectSetInteger(g_chart, name, OBJPROP_ZORDER, zorder);
    ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, -1000);
}

void InitBoxPool(int required)
  {
   if(required <= g_boxCount) return;
   int old = g_boxCount;
   g_boxCount = required;
   ArrayResize(g_boxPool, g_boxCount);
   for(int i = old; i < g_boxCount; i++) {
      g_boxPool[i].top_line   = "FP_BX_T_" + IntegerToString(i);
      g_boxPool[i].bot_line   = "FP_BX_B_" + IntegerToString(i);
      g_boxPool[i].left_line  = "FP_BX_L_" + IntegerToString(i);
      g_boxPool[i].right_line = "FP_BX_R_" + IntegerToString(i);
      g_boxPool[i].active     = false;

      ObjectInitRect(g_boxPool[i].top_line, 10);
      ObjectInitRect(g_boxPool[i].bot_line, 10);
      ObjectInitRect(g_boxPool[i].left_line, 10);
      ObjectInitRect(g_boxPool[i].right_line, 10);
   }
  }

void HideUnusedBoxes()
  {
   for(int i = g_boxActive; i < g_boxCount; i++) {
      ObjectSetInteger(g_chart, g_boxPool[i].top_line, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_boxPool[i].bot_line, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_boxPool[i].left_line, OBJPROP_XDISTANCE, -1000);
      ObjectSetInteger(g_chart, g_boxPool[i].right_line, OBJPROP_XDISTANCE, -1000);
   }
  }

void DrawHollowBox(int x, int y, int w, int h, int thickness, color borderCol)
  {
   if(g_boxActive >= g_boxCount) InitBoxPool(g_boxCount + 50);
   if(g_boxActive >= g_boxCount) return;
   int idx = g_boxActive++;
   g_boxPool[idx].active = true;

   // Top
   ObjectSetInteger(g_chart, g_boxPool[idx].top_line, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(g_chart, g_boxPool[idx].top_line, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(g_chart, g_boxPool[idx].top_line, OBJPROP_XSIZE, w);
   ObjectSetInteger(g_chart, g_boxPool[idx].top_line, OBJPROP_YSIZE, thickness);
   ObjectSetInteger(g_chart, g_boxPool[idx].top_line, OBJPROP_BGCOLOR, borderCol);
   ObjectSetInteger(g_chart, g_boxPool[idx].top_line, OBJPROP_COLOR, borderCol);

   // Bottom
   ObjectSetInteger(g_chart, g_boxPool[idx].bot_line, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(g_chart, g_boxPool[idx].bot_line, OBJPROP_YDISTANCE, y + h - thickness);
   ObjectSetInteger(g_chart, g_boxPool[idx].bot_line, OBJPROP_XSIZE, w);
   ObjectSetInteger(g_chart, g_boxPool[idx].bot_line, OBJPROP_YSIZE, thickness);
   ObjectSetInteger(g_chart, g_boxPool[idx].bot_line, OBJPROP_BGCOLOR, borderCol);
   ObjectSetInteger(g_chart, g_boxPool[idx].bot_line, OBJPROP_COLOR, borderCol);

   // Left
   ObjectSetInteger(g_chart, g_boxPool[idx].left_line, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(g_chart, g_boxPool[idx].left_line, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(g_chart, g_boxPool[idx].left_line, OBJPROP_XSIZE, thickness);
   ObjectSetInteger(g_chart, g_boxPool[idx].left_line, OBJPROP_YSIZE, h);
   ObjectSetInteger(g_chart, g_boxPool[idx].left_line, OBJPROP_BGCOLOR, borderCol);
   ObjectSetInteger(g_chart, g_boxPool[idx].left_line, OBJPROP_COLOR, borderCol);

   // Right
   ObjectSetInteger(g_chart, g_boxPool[idx].right_line, OBJPROP_XDISTANCE, x + w - thickness);
   ObjectSetInteger(g_chart, g_boxPool[idx].right_line, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(g_chart, g_boxPool[idx].right_line, OBJPROP_XSIZE, thickness);
   ObjectSetInteger(g_chart, g_boxPool[idx].right_line, OBJPROP_YSIZE, h);
   ObjectSetInteger(g_chart, g_boxPool[idx].right_line, OBJPROP_BGCOLOR, borderCol);
   ObjectSetInteger(g_chart, g_boxPool[idx].right_line, OBJPROP_COLOR, borderCol);
  }

//+------------------------------------------------------------------+
//| Strict Ladder Render                                             |
//+------------------------------------------------------------------+
void Render()
  {
   if(!g_visible || ArraySize(g_bars) == 0) return;
   
   int cw = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(cw <= 0 || ch <= 0) return;

   int firstVis = (int)ChartGetInteger(g_chart, CHART_FIRST_VISIBLE_BAR);
   int visBars  = (int)ChartGetInteger(g_chart, CHART_VISIBLE_BARS);
   if(visBars < 1) visBars = 1;
   
   LayoutUIControls(cw, ch);
   DrawUI();

   ResetPool();
   g_sepActive = 0;
   g_boxActive = 0;
   InitBoxPool(InpMaxBarsToRender * 12);

   int rightmostShift = firstVis - visBars + 1;
   if(rightmostShift < 0) rightmostShift = 0;
   int maxBars = MathMin(visBars, InpMaxBarsToRender);

   // Render active candles 
   for(int v = 0; v < maxBars; v++)
     {
      int shift = rightmostShift + v;
      if(shift > firstVis || shift < 0) continue;

      datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);
      int bi = FindBarIndex(bt);
      if(bi < 0 || g_bars[bi].level_count == 0 || GetBarX(bt) < 0) {
          continue;
      }

      ComputeBarSignals(bi);

      // Overwrite X coords entirely to strictly anchor over the native chart candle
      int candleX = GetBarX(bt);
      
      // Dynamic allocation tracking actual zoom level constraints
      int fullTrackW = MathMax(10, GetCandleWidthPx(bt) - InpBarGapPx);
      int barWidthPx = (int)(fullTrackW * 0.7);
      int MAX_HIST_W = fullTrackW - barWidthPx;
      
      int x_left = candleX - (fullTrackW / 2); // Center alignment taking into account histogram tail track length
      
      if(barWidthPx < 8 || x_left > cw || x_left + fullTrackW < 0) continue;

      // PASS 2: top = ceil(High/step)*step, bot = floor(Low/step)*step (exact bounds)
      double topStep = MathCeil(g_bars[bi].high / g_step) * g_step;
      double botStep = MathFloor(g_bars[bi].low / g_step) * g_step;
      int stepsNum = (int)MathRound((topStep - botStep) / g_step) + 1;

      // Strict ladder: anchor Y from bar midPrice, fixed row height in pixels (no chart-scale squeeze)
      double midPrice = NormP((g_bars[bi].high + g_bars[bi].low) / 2.0);
      int tmpX, anchorY;
      if(!ChartTimePriceToXY(g_chart, g_sub, bt, midPrice, tmpX, anchorY)) continue;

      long maxTotal = 1;
      for(int i = 0; i < g_bars[bi].level_count; i++) {
         if(g_bars[bi].levels[i].total_vol > maxTotal) maxTotal = g_bars[bi].levels[i].total_vol;
      }

      int colHeight = stepsNum * InpRowHeightPx;
      int y_top_first = anchorY - (int)MathRound((topStep - midPrice) / g_step) * InpRowHeightPx + g_yOffsetPx - InpRowHeightPx / 2;
      DrawHollowBox(x_left, y_top_first, fullTrackW, colHeight, 1, InpBarOutlineColor);

      int y_tops[]; int lvl_indices[];
      ArrayResize(y_tops, stepsNum);
      ArrayResize(lvl_indices, stepsNum);
      for(int k = 0; k < stepsNum; k++) lvl_indices[k] = -1;

      int y_top_first_actual = 0;
      for(int i = 0; i < stepsNum; i++)
        {
         double price = topStep - i * g_step;
         int diffSteps = (int)MathRound((price - midPrice) / g_step);
         int y_center = anchorY - diffSteps * InpRowHeightPx + g_yOffsetPx;
         int y_top = y_center - InpRowHeightPx / 2;
         if(i == 0) y_top_first_actual = y_top;
         y_tops[i] = y_top;
         if(y_top > ch || y_top + InpRowHeightPx < 0) continue;

         PriceLevel pl;
         ZeroMemory(pl);
         bool found = false;
         int lvlIdx = -1;
         for(int j = 0; j < g_bars[bi].level_count; j++) {
            if(MathAbs(g_bars[bi].levels[j].price - price) < g_step * 0.4) {
               pl = g_bars[bi].levels[j];
               found = true;
               lvlIdx = j;
               break;
            }
         }

         long bV = found ? pl.bid_vol : 0;
         long aV = found ? pl.ask_vol : 0;

         color bgBid     = InpEmptyCellColor; // Empty Cell
         color bgAsk     = InpEmptyCellColor; // Empty Cell
         color borderCol = InpGridLineColor;
         color txtCol    = clrBlack;
         int   histWidthPx = 0;
         color histColor = C'255,180,50'; // Yellow/Orange default
         string bidFontStr = "Arial";
         string askFontStr = "Arial";
         string sBid = " ";
         string sAsk = " ";

         if(found && (bV > 0 || aV > 0)) {
            sBid = IntegerToString(bV);
            sAsk = IntegerToString(aV);
            if(g_mode == FOOT_CHART_VOLUME && bV == 0 && aV == 0) { sBid = " "; sAsk = " "; }

            bool inVA = (lvlIdx >= g_bars[bi].va_lo_idx && lvlIdx <= g_bars[bi].va_hi_idx);
            double intensityBid = (maxTotal > 0) ? (double)bV / (double)maxTotal : 0.0;
            double intensityAsk = (maxTotal > 0) ? (double)aV / (double)maxTotal : 0.0;
            double intensityTot = (maxTotal > 0) ? (double)pl.total_vol / (double)maxTotal : 0.0;

            if (pl.is_imb_sell) { bidFontStr = "Arial Bold"; txtCol = InpImbSellColor; }
            if (pl.is_imb_buy) { askFontStr = "Arial Bold"; txtCol = InpImbBuyColor; }

            color cBaseBid = InpBidBaseColor;
            color cHighBid = InpBidHighColor;
            color cBaseAsk = InpAskBaseColor;
            color cHighAsk = InpAskHighColor;
            
            if (!inVA) { 
                cBaseBid = InpOutOfVAColor; cHighBid = InpOutOfVAColor; 
                cBaseAsk = InpOutOfVAColor; cHighAsk = InpOutOfVAColor; 
            }
            
            bgBid = LerpColorOpaque(cBaseBid, cHighBid, intensityBid);
            bgAsk = LerpColorOpaque(cBaseAsk, cHighAsk, intensityAsk);

            histWidthPx = (int)(intensityTot * MAX_HIST_W);
            if(histWidthPx < 1 && pl.total_vol > 0) histWidthPx = 1;

            if(pl.is_imb_sell) { borderCol = InpImbSellColor; }
            else if(pl.is_imb_buy) { borderCol = InpImbBuyColor; }

            if(lvlIdx == g_bars[bi].poc_idx) { 
                histColor = C'100,100,255'; // Blue override for POC
                DrawHollowBox(x_left, y_top, fullTrackW, InpRowHeightPx, 2, InpPOCColor);
            }
         }

         DrawGridCell(x_left, y_top, barWidthPx, fullTrackW, sBid, sAsk, bgBid, bgAsk, bidFontStr, askFontStr, txtCol, histWidthPx, histColor);
        }

      // Bar separator: thin vertical line between footprint columns
      int sepX = x_left + barWidthPx;
      colHeight = stepsNum * InpRowHeightPx;
      DrawSeparator(sepX, y_top_first, colHeight);

      // Draw Stacked Imbalance Rectangles
      for (int pass = 0; pass < 2; pass++) {
         bool checkingBuy = (pass == 0);
         int stackStartLvl = -1;
         for (int j = 0; j <= g_bars[bi].level_count; j++) {
            bool isStacked = false;
            if (j < g_bars[bi].level_count) {
               isStacked = checkingBuy ? g_bars[bi].levels[j].is_stacked_imb_buy : g_bars[bi].levels[j].is_stacked_imb_sell;
            }
            if (isStacked) {
               if (stackStartLvl == -1) stackStartLvl = j;
            } else {
               if (stackStartLvl != -1) {
                  int startIdx = stackStartLvl;
                  int endIdx = j - 1; // inclusive
                  double top_price = g_bars[bi].levels[startIdx].price;
                  double bot_price = g_bars[bi].levels[endIdx].price;
                  int diffTop = (int)MathRound((top_price - midPrice) / g_step);
                  int y_top_rect = anchorY - diffTop * InpRowHeightPx + g_yOffsetPx - InpRowHeightPx / 2;
                  int diffBot = (int)MathRound((bot_price - midPrice) / g_step);
                  int y_bot_rect = anchorY - diffBot * InpRowHeightPx + g_yOffsetPx + InpRowHeightPx / 2;
                  int stack_h = y_bot_rect - y_top_rect;
                  color c = checkingBuy ? InpStackedBuyColor : InpStackedSellColor;
                  DrawHollowBox(x_left, y_top_rect, barWidthPx, stack_h, 2, c);
                  stackStartLvl = -1;
               }
            }
         }
      }
     }

   HideUnusedPool();
   HideUnusedSeparators();
   HideUnusedBoxes();
   ChartRedraw();
  }

void ThrottledRender()
  {
   ulong now_ticks = GetTickCount();
   if(now_ticks - g_last_render_ms >= FP_RENDER_THROTTLE_MS) {
      Render();
      g_last_render_ms = now_ticks;
   }
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   int pts = MathMax(1, MathMin(10000, InpTickSize));
   g_baseStep = pts * _Point;
   
   int ticksPerRow = (InpTicksPerRow > 0) ? InpTicksPerRow : MathMax(1, InpTickMultiplier);
   if(ticksPerRow > 100) ticksPerRow = 100;
   g_tickMult = ticksPerRow;
   g_step     = g_baseStep * g_tickMult;
   
   g_mode     = InpChartMode;
   g_chart    = ChartID();
   g_sub      = 0;
   g_prevBid  = 0.0;
   g_dirty    = true;
   g_imbRatio = InpImbalanceRatio;
   g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);
   ChartSetInteger(g_chart, CHART_FOREGROUND, false);
   
   InitPool(InpMaxBarsToRender * 50); // initial small pool
   InitSeparators(InpMaxBarsToRender);
   ReloadHistory();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   for(int i = 0; i < g_poolCount; i++) {
      ObjectDelete(g_chart, g_pool[i].bg_track);
      ObjectDelete(g_chart, g_pool[i].rect_bid);
      ObjectDelete(g_chart, g_pool[i].rect_ask);
      ObjectDelete(g_chart, g_pool[i].hist_name);
      ObjectDelete(g_chart, g_pool[i].bid_name);
      ObjectDelete(g_chart, g_pool[i].ask_name);
      ObjectDelete(g_chart, g_pool[i].vgrid_line);
      ObjectDelete(g_chart, g_pool[i].hgrid_line);
   }
   for(int i = 0; i < g_sepCount; i++) ObjectDelete(g_chart, g_sepNames[i]);
   ObjectDelete(g_chart, "FP_BTN_UP");
   ObjectDelete(g_chart, "FP_BTN_DN");
   ObjectDelete(g_chart, "FP_BTN_C");
   ArrayFree(g_pool);
   ArrayFree(g_sepNames);
   ArrayFree(g_bars);
  }

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[], const double &open[], const double &high[], const double &low[], const double &close[], const long &tick_volume[], const long &volume[], const int &spread[])
  {
   if(rates_total == 0) return 0;
   if(prev_calculated == 0 || rates_total < prev_calculated || ArraySize(g_bars) == 0) {
      ReloadHistory();
      if(!g_dirty) return 0;
   }

   MqlTick ticks[];
   uint flag = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long now_msc = (long)TimeCurrent() * 1000;
   long from_msc = g_last_tick_time_ms;
   if(from_msc == 0) {
      long lookback = 60000;
      from_msc = (now_msc > lookback) ? now_msc - lookback : now_msc;
   }
   
   int copied = CopyTicksRange(_Symbol, ticks, flag, from_msc, now_msc);
   if(copied > 0) {
      if(g_prevBid == 0.0) g_prevBid = ticks[0].bid;
      ProcessTicks(ticks, 0, copied, true, true);
   }
   
   if(g_dirty) ThrottledRender();
   return rates_total;
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE) {
      if(ArraySize(g_bars) > 0) {
         datetime expectedLastBar  = iTime(_Symbol, PERIOD_CURRENT, 0);
         int bars_total = iBars(_Symbol, PERIOD_CURRENT);
         int span = MathMin(InpHistoryBars, bars_total - 1);
         datetime expectedFirstBar = iTime(_Symbol, PERIOD_CURRENT, span);

         if(g_bars[0].bar_time != expectedFirstBar && g_bars[ArraySize(g_bars) - 1].bar_time != expectedLastBar) {
            ReloadHistory();
         }
      }
      g_dirty = true;
      ThrottledRender();
   }
   
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sparam == "FP_BTN_UP") {
         g_yOffsetPx += InpRowHeightPx * 3; // Scroll up 3 rows
         g_dirty = true;
         ObjectSetInteger(g_chart, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == "FP_BTN_DN") {
         g_yOffsetPx -= InpRowHeightPx * 3; // Scroll down 3 rows
         g_dirty = true;
         ObjectSetInteger(g_chart, sparam, OBJPROP_STATE, false);
      }
      else if(sparam == "FP_BTN_C") {
         g_yOffsetPx = 0; // Center
         g_dirty = true;
         ObjectSetInteger(g_chart, sparam, OBJPROP_STATE, false);
      }
      if (g_dirty) ThrottledRender();
   }
  }