//+------------------------------------------------------------------+
//|                                                         foot.mq5 |
//|              Footprint (Bid x Ask Cluster) — Industry Standard   |
//+------------------------------------------------------------------+
//| Industry alignment: Sierra / Bookmap-style footprint              |
//| - Bid (sell) left | Ask (buy) right per price level               |
//| - POC = Point of Control (highest volume level)                   |
//| - Value Area = CME-style % of volume around POC (default 70%)     |
//| - Diagonal imbalance: Ask@N vs Bid@N+1 (buy), Bid@N vs Ask@N-1    |
//| - Delta bar and total volume below each bar                       |
//+------------------------------------------------------------------+
#property copyright "Trading Tool"
#property link      "https://mql5.com"
#property version   "10.00"
#property description "Footprint Chart — Tick 10-100, VA%, Imb, Refresh"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>


//--- Inputs
input group "Data & History"
input int    InpTickSize       = 10;            // Cell size (points) — 1 point = 1×_Point; click Tick to cycle 10→20→...→100→10
input double InpImbalanceRatio = 300.0;         // Imbalance Threshold (%)
input double InpAbsorptionRatio= 4.0;           // Absorption Threshold (x Avg Vol)
input int    InpHistoryBars    = 100;           // History bars to load
input double InpVAPercent      = 70.0;          // Value Area % (industry default 70)

input group "Visual Opacity"
input uchar  InpBgAlpha        = 210;           // Cell Background Alpha (0-255)
input uchar  InpVAOffAlpha     = 80;            // Alpha outside Value Area (0-255)

input group "Colors - Heatmap"
input color  InpBidBaseColor   = C'28,10,10';     // Bid (Sell) Volume Base
input color  InpBidHighColor   = C'140,40,40';    // Bid (Sell) Volume High
input color  InpAskBaseColor   = C'10,28,15';     // Ask (Buy) Volume Base
input color  InpAskHighColor   = C'40,140,60';    // Ask (Buy) Volume High
input color  InpOutOfVAColor   = C'22,22,25';     // Out of Value Area Color

input group "Colors - Highlights & UI"
input color  InpImbSellColor   = C'220,40,40';    // Sell Imbalance Color
input color  InpImbBuyColor    = C'40,220,80';    // Buy Imbalance Color
input color  InpAbsorptionColor= clrMagenta;      // Absorption Marker Color
input color  InpPOCColor       = clrYellow;       // POC Frame Color
input color  InpBullishFrame   = C'0,255,100';    // Bullish Session Frame
input color  InpBearishFrame   = C'255,40,40';    // Bearish Session Frame
input color  InpWickColor      = C'180,180,190';  // Candle Wick Color
input color  InpGridColor      = clrBlack;        // Grid Separation Color

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

//--- Globals
CCanvas  canvas;
string   g_name     = "FP_Canvas";
FPBar    g_bars[];
double   g_step;        // aggregated step = InpTickSize * _Point
long     g_chart;
int      g_sub;
bool     g_hasTrades;
double   g_prevBid;
bool     g_dirty;
bool     g_hideText;
double   g_imbRatio;    // current imbalance ratio (GUI-tunable)
int      g_opacity = 255;  // overlay opacity (runtime-tunable: 255/190/127/64)
long     g_last_tick_time_ms = 0;
ulong    g_last_render_ms    = 0;

// GUI panel & buttons
#define FP_PANEL_BTN_W      46
#define FP_PANEL_BTN_GAP    3
#define FP_PANEL_PAD        3
#define FP_PANEL_H          24
#define FP_PANEL_MARGIN     5
#define FP_RENDER_THROTTLE_MS 33   // ~30 FPS max to avoid UI lag
#define FP_MIN_CELL_H         16   // Min cell height (px) for readability
#define FP_DARK_BASE          C'30,30,38'

// Opacity cycle presets
#define FP_OPA_FULL    255
#define FP_OPA_75      190
#define FP_OPA_50      127
#define FP_OPA_25       64

// Imbalance ratio cycle presets
#define FP_IMB_LO      200.0
#define FP_IMB_MID     300.0
#define FP_IMB_HI      400.0

int g_panelX1, g_panelY1, g_panelX2, g_panelY2;
int g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2;
int g_btnImbX1,  g_btnImbY1,  g_btnImbX2,  g_btnImbY2;
int g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2;
int g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2;
int g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2;
int g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2;
int g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2;
int g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2;
int g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2;
int g_mouseX = -1, g_mouseY = -1;
double g_vaPercent = 0;   // 0 = use InpVAPercent; else runtime VA%
bool g_visible = true;

// Persistent scratch buffers
int  g_scratchY1[];
int  g_scratchY2[];
int  g_scratchCap = 0;

//+------------------------------------------------------------------+
//| Helper: point-in-rect hit test                                    |
//+------------------------------------------------------------------+
bool HitTest(int mx, int my, int x1, int y1, int x2, int y2)
{
   return (mx >= x1 && mx <= x2 && my >= y1 && my <= y2);
}

//+------------------------------------------------------------------+
//| Helper: throttled render (avoids redundant redraws)               |
//+------------------------------------------------------------------+
void ThrottledRender()
{
   ulong now_ticks = GetTickCount();
   if(now_ticks - g_last_render_ms >= FP_RENDER_THROTTLE_MS)
   {
      Render();
      g_last_render_ms = now_ticks;
   }
}

//+------------------------------------------------------------------+
//| Helper: clear bars and reload tick history from scratch            |
//+------------------------------------------------------------------+
void ReloadHistory()
{
   ArrayFree(g_bars);
   int maxShift = MathMin(InpHistoryBars, iBars(_Symbol, PERIOD_CURRENT) - 1);
   datetime startTime = iTime(_Symbol, PERIOD_CURRENT, maxShift);
   datetime endTime   = TimeCurrent();
   LoadHistory(startTime, endTime);
   g_dirty = true;
}

//+------------------------------------------------------------------+
double NormP(double p)
{
   return MathFloor(p / g_step) * g_step;
}

//+------------------------------------------------------------------+
int FindBarIndex(datetime bt)
{
   int lo = 0, hi = ArraySize(g_bars) - 1;
   while(lo <= hi)
   {
      int mid = (lo + hi) / 2;
      if(g_bars[mid].bar_time == bt) return mid;
      if(g_bars[mid].bar_time < bt) lo = mid + 1;
      else hi = mid - 1;
   }
   return -1;
}

//+------------------------------------------------------------------+
int InsertBar(datetime bt)
{
   int n = ArraySize(g_bars);
   int pos = n;
   for(int i = n - 1; i >= 0; i--)
   {
      if(g_bars[i].bar_time == bt) return i;
      if(g_bars[i].bar_time < bt) { pos = i + 1; break; }
      pos = i;
   }

   ArrayResize(g_bars, n + 1, 128);
   // Explicit copy so each bar keeps its own levels[] (no shared refs after struct assign)
   for(int i = n; i > pos; i--)
   {
      g_bars[i].bar_time    = g_bars[i - 1].bar_time;
      g_bars[i].total_vol   = g_bars[i - 1].total_vol;
      g_bars[i].total_delta = g_bars[i - 1].total_delta;
      g_bars[i].sorted      = g_bars[i - 1].sorted;
      g_bars[i].level_count = g_bars[i - 1].level_count;
      int cap = ArraySize(g_bars[i - 1].levels);
      ArrayResize(g_bars[i].levels, MathMax(cap, 64), 64);
      if(cap > 0)
         ArrayCopy(g_bars[i].levels, g_bars[i - 1].levels, 0, 0, cap);
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

//+------------------------------------------------------------------+
int GetBar(datetime bt)
{
   int idx = FindBarIndex(bt);
   if(idx >= 0) return idx;
   return InsertBar(bt);
}

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Phase 1: Accumulate Ticks to Price Levels                       |
//+------------------------------------------------------------------+
void AccumulateTick(int bi, double price, long vol, bool isBuy, bool isSell)
{
   if(price == 0.0) return;
   price = NormP(price);
   
   int used = g_bars[bi].level_count;
   int idx = -1;

   // Search for existing level (optimized for recent levels)
   for(int i = used - 1; i >= 0; i--)
   {
      if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.4)
      {
         idx = i;
         break;
      }
   }

   // Create new level if not found
   if(idx == -1)
   {
      if(used >= ArraySize(g_bars[bi].levels))
         ArrayResize(g_bars[bi].levels, used + 64, 64);
      
      idx = used;
      g_bars[bi].levels[idx].price = price;
      g_bars[bi].levels[idx].bid_vol = 0;
      g_bars[bi].levels[idx].ask_vol = 0;
      g_bars[bi].levels[idx].total_vol = 0;
      g_bars[bi].levels[idx].delta = 0;
      g_bars[bi].level_count++;
      g_bars[bi].sorted = false;
   }

   // Update metrics
   if(isBuy)  g_bars[bi].levels[idx].ask_vol += vol;
   if(isSell) g_bars[bi].levels[idx].bid_vol += vol;
   
   g_bars[bi].levels[idx].total_vol += vol;
   g_bars[bi].levels[idx].delta = g_bars[bi].levels[idx].ask_vol - g_bars[bi].levels[idx].bid_vol;
   
   g_bars[bi].total_vol += vol;
   g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));
   g_dirty = true;
}

//+------------------------------------------------------------------+
//| Phase 2: Compute Bar Signals (POC, VA, Imbalance, Absorption)   |
//+------------------------------------------------------------------+
void ComputeBarSignals(int bi)
{
   int len = g_bars[bi].level_count;
   if(len <= 0) return;

   if(!g_bars[bi].sorted) { SortLevels(g_bars[bi].levels, len); g_bars[bi].sorted = true; }

   // 1. POC
   g_bars[bi].poc_idx = FindPOC(g_bars[bi].levels, len);
   
   // 2. Value Area
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, g_bars[bi].poc_idx, g_bars[bi].va_lo_idx, g_bars[bi].va_hi_idx);

   // 3. Loop for Imbalance & Absorption
   long avgVol = (len > 0) ? (g_bars[bi].total_vol / len) : 1;
   for(int i = 0; i < len; i++)
   {
      g_bars[bi].levels[i].is_imb_buy  = false;
      g_bars[bi].levels[i].is_imb_sell = false;
      g_bars[bi].levels[i].is_absorption = (g_bars[bi].levels[i].total_vol > avgVol * InpAbsorptionRatio);

      // Diagonal Imbalance
      if(i < len - 1)
      {
         long nextBid = g_bars[bi].levels[i+1].bid_vol;
         if(nextBid > 0 && ((double)g_bars[bi].levels[i].ask_vol / nextBid) * 100.0 >= g_imbRatio) 
            g_bars[bi].levels[i].is_imb_buy = true;
      }
      if(i > 0)
      {
         long prevAsk = g_bars[bi].levels[i-1].ask_vol;
         if(prevAsk > 0 && ((double)g_bars[bi].levels[i].bid_vol / prevAsk) * 100.0 >= g_imbRatio) 
            g_bars[bi].levels[i].is_imb_sell = true;
      }
   }
}

//+------------------------------------------------------------------+
void Classify(const MqlTick &t, bool &isBuy, bool &isSell)
{
   isBuy = false; isSell = false;
   if(g_hasTrades)
   {
      isBuy  = (t.flags & TICK_FLAG_BUY)  == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
      if(!isBuy && !isSell)
      {
         if(t.last >= t.ask) isBuy = true;
         else if(t.last <= t.bid) isSell = true;
      }
   }
   else
   {
      if(t.bid > g_prevBid)      isBuy  = true;
      else if(t.bid < g_prevBid) isSell = true;
      else                       isBuy  = true;
   }
}

//+------------------------------------------------------------------+
//| Process tick array into bars (single place for LoadHistory + OnCalculate)
//+------------------------------------------------------------------+
void ProcessTicks(MqlTick &ticks[], int startIdx, int count,
                  bool skipAlreadySeen, bool updateLastTimeMs)
{
   if(count <= 0) return;
   for(int i = startIdx; i < startIdx + count; i++)
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

      if(ticks[i].bid != 0.0)
         g_prevBid = ticks[i].bid;

      int sh = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
      if(sh < 0) continue;
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, sh);
      int bi = GetBar(bt);
      
      // Update dimensions and sentiment
      double bOpen  = iOpen(_Symbol, PERIOD_CURRENT, sh);
      double bClose = iClose(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].is_bullish = (bClose >= bOpen);
      g_bars[bi].high = iHigh(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].low  = iLow(_Symbol, PERIOD_CURRENT, sh);

      AccumulateTick(bi, price, vol, isBuy, isSell);
      ComputeBarSignals(bi);

      if(updateLastTimeMs)
         g_last_tick_time_ms = ticks[i].time_msc;
   }
}

//+------------------------------------------------------------------+
int LoadHistory(datetime t0, datetime t1)
{
   MqlTick ticks[];
   uint flag = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   int copied = CopyTicksRange(_Symbol, ticks, flag,
                                (long)t0 * 1000, (long)t1 * 1000);
   if(copied <= 0)
   {
      Print("FP: No ticks. copied=", copied);
      return -1;
   }

   g_prevBid = ticks[0].bid;
   ProcessTicks(ticks, 0, copied, false, true);

   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++)
   {
      SortLevels(g_bars[i].levels, g_bars[i].level_count);
      g_bars[i].sorted = true;
   }

   PrintFormat("FP: %d ticks -> %d bars", copied, n);
   g_dirty = true;
   return copied;
}

//+------------------------------------------------------------------+
//| Quicksort partition (descending by price)
//+------------------------------------------------------------------+
void SortLevelsPartition(PriceLevel &lv[], int lo, int hi)
{
   if(lo >= hi) return;
   double pivot = lv[hi].price;
   int i = lo - 1;
   for(int j = lo; j < hi; j++)
   {
      if(lv[j].price >= pivot)
      {
         i++;
         PriceLevel tmp = lv[i];
         lv[i] = lv[j];
         lv[j] = tmp;
      }
   }
   i++;
   PriceLevel tmp = lv[i];
   lv[i] = lv[hi];
   lv[hi] = tmp;

   SortLevelsPartition(lv, lo, i - 1);
   SortLevelsPartition(lv, i + 1, hi);
}

//+------------------------------------------------------------------+
void SortLevels(PriceLevel &lv[], int n)
{
   if(n <= 1) return;
   SortLevelsPartition(lv, 0, n - 1);
}

//+------------------------------------------------------------------+
int FindPOC(const PriceLevel &lv[], int count)
{
   int best = -1; long mx = 0;
   for(int i = 0; i < count; i++)
      if(lv[i].total_vol > mx) { mx = lv[i].total_vol; best = i; }
   return best;
}

//+------------------------------------------------------------------+
double GetEffectiveVAPercent()
{
   return (g_vaPercent > 0.0) ? g_vaPercent : (double)InpVAPercent;
}

//+------------------------------------------------------------------+
void FindVA(const PriceLevel &lv[], int count, long totVol, int poc, int &lo, int &hi)
{
   lo = poc; hi = poc;
   if(poc < 0) return;
   long target = (long)(totVol * GetEffectiveVAPercent() / 100.0);
   long cur = lv[poc].total_vol;
   while(cur < target && (lo > 0 || hi < count - 1))
   {
      long up = (hi < count - 1) ? lv[hi + 1].total_vol : -1;
      long dn = (lo > 0)         ? lv[lo - 1].total_vol : -1;
      if(up >= dn && up != -1) { hi++; cur += up; }
      else if(dn != -1)        { lo--; cur += dn; }
      else break;
   }
}

//+------------------------------------------------------------------+
uint FpARGB(color c, int a)
{
   return ColorToARGB(c, (uchar)MathMin(MathMax(a, 0), 255));
}

color LerpColor(color a, color b, double t)
{
   if(t < 0.0) t = 0.0; if(t > 1.0) t = 1.0;
   int r  = (int)((1.0 - t) * (a & 0xFF)         + t * (b & 0xFF));
   int g  = (int)((1.0 - t) * ((a >> 8) & 0xFF)  + t * ((b >> 8) & 0xFF));
   int bl = (int)((1.0 - t) * ((a >> 16) & 0xFF) + t * ((b >> 16) & 0xFF));
   return (color)((bl << 16) | (g << 8) | r);
}

//+------------------------------------------------------------------+
void EnsureScratch(int needed)
{
   if(g_scratchCap < needed)
   {
      ArrayResize(g_scratchY1, needed, 128);
      ArrayResize(g_scratchY2, needed, 128);
      g_scratchCap = needed;
   }
}

//+------------------------------------------------------------------+
//| Industry Standard Footprint Bar Renderer                         |
//| Layout: [Bid Vol] | [Ask Vol]  per price level                   |
//| - Diagonal imbalance detection (Ask@N vs Bid@N-1)                |
//| - Yellow box for Value Area                                       |
//+------------------------------------------------------------------+
void DrawBar(int bi, int shift, int barW)
{
   int len = g_bars[bi].level_count;
   if(len == 0) return;

   ComputeBarSignals(bi); // Final check for fresh signals
   
   int pocIdx  = g_bars[bi].poc_idx;
   int vaLoIdx = g_bars[bi].va_lo_idx;
   int vaHiIdx = g_bars[bi].va_hi_idx;

   long maxLevelVol = 1;
   for(int i = 0; i < len; i++) if(g_bars[bi].levels[i].total_vol > maxLevelVol) maxLevelVol = g_bars[bi].levels[i].total_vol;

   datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);

   // --- Candle Wicks (Target matching) ---
   int wx, wy_h, wy_l;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].high, wx, wy_h);
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].low, wx, wy_l);
   uint wickCol = FpARGB(InpWickColor, (160 * g_opacity) / 255);
   canvas.LineVertical(wx, wy_h, wy_l, wickCol);

   // --- X geometry (Compact/Professional) ---
   int halfW = (int)(barW * 0.45);
   if(halfW < 14) halfW = 14;
   int xc, yd;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, xc, yd);
   int x1 = xc - halfW, x2 = xc + halfW, midX = (x1 + x2) / 2;

   // --- Y layout (Grid Snap) ---
   EnsureScratch(len);
   int natY1, natY2, tmpX;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, tmpX, natY1);
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price - g_step, tmpX, natY2);
   int cellH = MathAbs(natY2 - natY1);
   if(cellH < FP_MIN_CELL_H) cellH = FP_MIN_CELL_H;

   int midIdx = len / 2;
   int anchorY;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[midIdx].price, tmpX, anchorY);
   g_scratchY1[midIdx] = anchorY - cellH / 2;
   g_scratchY2[midIdx] = g_scratchY1[midIdx] + cellH;
   for(int i = midIdx - 1; i >= 0; i--) { g_scratchY2[i] = g_scratchY1[i + 1]; g_scratchY1[i] = g_scratchY2[i] - cellH; }
   for(int i = midIdx + 1; i < len; i++) { g_scratchY1[i] = g_scratchY2[i - 1]; g_scratchY2[i] = g_scratchY1[i] + cellH; }

   bool skipText = g_hideText || (cellH < 9);
   int opaScale = g_opacity;
   uint colWhiteText = FpARGB(clrWhite, (250 * opaScale) / 255);
   uint colBlackText = FpARGB(clrBlack, (250 * opaScale) / 255);

   if(!skipText) { canvas.FontSet("Segoe UI", (int)MathMin(11, cellH*0.58), FW_BOLD); }

   bool isBullish = g_bars[bi].is_bullish;
   color sentimentCol = isBullish ? InpBullishFrame : InpBearishFrame;

   for(int i = 0; i < len; i++)
   {
      PriceLevel pl = g_bars[bi].levels[i];
      
      // Strict Fit: Only draw levels within the bar's High/Low range
      if(pl.price < g_bars[bi].low - g_step*0.5 || pl.price > g_bars[bi].high + g_step*0.5) continue;

      int y_top = g_scratchY1[i], y_bot = g_scratchY2[i];
      bool inVA = (i >= vaLoIdx && i <= vaHiIdx);
      int alpha = inVA ? (int)InpBgAlpha : (int)InpVAOffAlpha;
      alpha = (alpha * opaScale) / 255;
      double intensity = (double)pl.total_vol / (double)maxLevelVol;

      // Desired Neon Heatmap Palettes
      color bidCol = pl.is_imb_sell ? InpImbSellColor : LerpColor(InpBidBaseColor, InpBidHighColor, intensity);
      color askCol = pl.is_imb_buy  ? InpImbBuyColor : LerpColor(InpAskBaseColor, InpAskHighColor, intensity);

      if(!inVA) { bidCol = InpOutOfVAColor; askCol = InpOutOfVAColor; }

      canvas.FillRectangle(x1, y_top, midX, y_bot, FpARGB(bidCol, alpha));
      canvas.FillRectangle(midX + 1, y_top, x2, y_bot, FpARGB(askCol, alpha));
      
      // Grid separation
      canvas.LineHorizontal(x1, x2, y_bot, FpARGB(InpGridColor, 100));
      canvas.LineVertical(midX, y_top, y_bot, FpARGB(InpGridColor, 100));

      // POC Frame (Vivid Gold)
      if(i == pocIdx) 
      {
         canvas.Rectangle(x1, y_top, x2, y_bot, FpARGB(InpPOCColor, 240));
         canvas.Rectangle(x1+1, y_top+1, x2-1, y_bot-1, FpARGB(InpPOCColor, 120));
      }

      // Absorption Marker (Vivid Magenta outline drawn thicker so it is easily seen)
      if(pl.is_absorption) 
      {
         canvas.Rectangle(x1-1, y_top-1, x2+1, y_bot+1, FpARGB(InpAbsorptionColor, 255));
         canvas.Rectangle(x1-2, y_top-2, x2+2, y_bot+2, FpARGB(InpAbsorptionColor, 255));
      }

      if(!skipText)
      {
         int yy = (y_top + y_bot) / 2;
         uint tCBid = (pl.is_imb_sell || (intensity > 0.8 && inVA)) ? colBlackText : colWhiteText;
         uint tCAsk = (pl.is_imb_buy  || (intensity > 0.8 && inVA)) ? colBlackText : colWhiteText;
         
         if(pl.bid_vol > 0) canvas.TextOut((x1+midX)/2, yy, IntegerToString(pl.bid_vol), tCBid, TA_CENTER|TA_VCENTER);
         if(pl.ask_vol > 0) canvas.TextOut((midX+1+x2)/2, yy, IntegerToString(pl.ask_vol), tCAsk, TA_CENTER|TA_VCENTER);
      }
   }

   // --- Desired Session Framing ---
   if(vaLoIdx >= 0 && vaHiIdx >= 0)
   {
      canvas.Rectangle(x1, g_scratchY1[vaLoIdx], x2, g_scratchY2[vaHiIdx], FpARGB(sentimentCol, 255));
      canvas.Rectangle(x1-1, g_scratchY1[vaLoIdx]-1, x2+1, g_scratchY2[vaHiIdx]+1, FpARGB(sentimentCol, 120));
   }
}



//+------------------------------------------------------------------+
//| Layout panel and button coordinates (no drawing)
//+------------------------------------------------------------------+
void LayoutPanel(int cw, int ch)
{
   int panelH = FP_PANEL_H;
   int btnW   = FP_PANEL_BTN_W;
   int btnGap = FP_PANEL_BTN_GAP;
   int pad    = FP_PANEL_PAD;
   int panelW = pad + (btnW * 9 + btnGap * 8) + pad;

   g_panelX2 = cw - FP_PANEL_MARGIN;
   g_panelX1 = g_panelX2 - panelW;
   g_panelY1 = ch - panelH - FP_PANEL_MARGIN;
   g_panelY2 = g_panelY1 + panelH;

   g_btnZoomOutX1 = g_panelX1 + pad;
   g_btnZoomOutY1 = g_panelY1 + pad;
   g_btnZoomOutX2 = g_btnZoomOutX1 + btnW;
   g_btnZoomOutY2 = g_panelY2 - pad;

   g_btnZoomInX1  = g_btnZoomOutX2 + btnGap;
   g_btnZoomInY1  = g_btnZoomOutY1;
   g_btnZoomInX2  = g_btnZoomInX1 + btnW;
   g_btnZoomInY2  = g_btnZoomOutY2;

   g_btnScaleFixX1 = g_btnZoomInX2 + btnGap;
   g_btnScaleFixY1 = g_btnZoomOutY1;
   g_btnScaleFixX2 = g_btnScaleFixX1 + btnW;
   g_btnScaleFixY2 = g_btnZoomOutY2;

   g_btnTickX1 = g_btnScaleFixX2 + btnGap;
   g_btnTickY1 = g_btnZoomOutY1;
   g_btnTickX2 = g_btnTickX1 + btnW;
   g_btnTickY2 = g_btnZoomOutY2;

   g_btnImbX1  = g_btnTickX2 + btnGap;
   g_btnImbY1  = g_btnZoomOutY1;
   g_btnImbX2  = g_btnImbX1 + btnW;
   g_btnImbY2  = g_btnZoomOutY2;

   g_btnOpaX1  = g_btnImbX2 + btnGap;
   g_btnOpaY1  = g_btnZoomOutY1;
   g_btnOpaX2  = g_btnOpaX1 + btnW;
   g_btnOpaY2  = g_btnZoomOutY2;

   g_btnShowX1 = g_btnOpaX2 + btnGap;
   g_btnShowY1 = g_btnZoomOutY1;
   g_btnShowX2 = g_btnShowX1 + btnW;
   g_btnShowY2 = g_btnZoomOutY2;

   g_btnRefreshX1 = g_btnShowX2 + btnGap;
   g_btnRefreshY1 = g_btnZoomOutY1;
   g_btnRefreshX2 = g_btnRefreshX1 + btnW;
   g_btnRefreshY2 = g_btnZoomOutY2;

   g_btnVAX1 = g_btnRefreshX2 + btnGap;
   g_btnVAY1 = g_btnZoomOutY1;
   g_btnVAX2 = g_btnVAX1 + btnW;
   g_btnVAY2 = g_btnZoomOutY2;
}

//+------------------------------------------------------------------+
//| Draw control panel background and all buttons
//+------------------------------------------------------------------+
void DrawPanel()
{
   int panelH = FP_PANEL_H;
   int btnW   = FP_PANEL_BTN_W;
   int btnCenterX = btnW / 2;
   int btnCenterY = g_btnZoomOutY1 + (panelH - 6) / 2;

   canvas.FillRectangle(g_panelX1, g_panelY1, g_panelX2, g_panelY2, FpARGB(C'20,20,28', 200));
   canvas.Rectangle(g_panelX1, g_panelY1, g_panelX2, g_panelY2, FpARGB(C'70,70,80', 200));

   // Hover detection
   bool hoveredTick     = HitTest(g_mouseX, g_mouseY, g_btnTickX1,     g_btnTickY1,     g_btnTickX2,     g_btnTickY2);
   bool hoveredImb      = HitTest(g_mouseX, g_mouseY, g_btnImbX1,      g_btnImbY1,      g_btnImbX2,      g_btnImbY2);
   bool hoveredZoomIn   = HitTest(g_mouseX, g_mouseY, g_btnZoomInX1,   g_btnZoomInY1,   g_btnZoomInX2,   g_btnZoomInY2);
   bool hoveredZoomOut  = HitTest(g_mouseX, g_mouseY, g_btnZoomOutX1,  g_btnZoomOutY1,  g_btnZoomOutX2,  g_btnZoomOutY2);
   bool hoveredScaleFix = HitTest(g_mouseX, g_mouseY, g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2);
   bool hoveredOpa      = HitTest(g_mouseX, g_mouseY, g_btnOpaX1,      g_btnOpaY1,      g_btnOpaX2,      g_btnOpaY2);
   bool hoveredShow     = HitTest(g_mouseX, g_mouseY, g_btnShowX1,     g_btnShowY1,     g_btnShowX2,     g_btnShowY2);
   bool hoveredRefresh  = HitTest(g_mouseX, g_mouseY, g_btnRefreshX1,  g_btnRefreshY1,  g_btnRefreshX2,  g_btnRefreshY2);
   bool hoveredVA       = HitTest(g_mouseX, g_mouseY, g_btnVAX1,       g_btnVAY1,       g_btnVAX2,       g_btnVAY2);

   uint baseFill   = FpARGB(C'35,35,45', 230);
   uint hoverFill  = FpARGB(C'55,55,70', 250);
   uint baseBorder = FpARGB(C'80,80,90', 200);
   uint hoverBorder= FpARGB(C'140,140,160', 255);

   bool scaleFixOn = (bool)ChartGetInteger(g_chart, CHART_SCALEFIX, 0);

   canvas.FontSet("Consolas", 9, FW_NORMAL);

   // 1. Zoom Out
   canvas.FillRectangle(g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2,
                        hoveredZoomOut ? hoverFill : baseFill);
   canvas.Rectangle(g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2,
                    hoveredZoomOut ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnZoomOutX1 + btnCenterX, btnCenterY,
                  "-", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 2. Zoom In
   canvas.FillRectangle(g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2,
                        hoveredZoomIn ? hoverFill : baseFill);
   canvas.Rectangle(g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2,
                    hoveredZoomIn ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnZoomInX1 + btnCenterX, btnCenterY,
                  "+", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 3. Scale fix
   uint fixFill   = scaleFixOn ? FpARGB(C'20,90,50', 230)   : baseFill;
   uint fixBorder = scaleFixOn ? FpARGB(C'80,200,120', 230) : baseBorder;
   if(hoveredScaleFix) { fixFill = hoverFill; fixBorder = hoverBorder; }
   canvas.FillRectangle(g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2, fixFill);
   canvas.Rectangle(g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2, fixBorder);
   canvas.TextOut(g_btnScaleFixX1 + btnCenterX, btnCenterY,
                  "Fix", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 4. Tick size (displays current point value)
   canvas.FillRectangle(g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2,
                        hoveredTick ? hoverFill : baseFill);
   canvas.Rectangle(g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2,
                    hoveredTick ? hoverBorder : baseBorder);
   int tickPoints = (int)MathRound(g_step / _Point);
   canvas.TextOut(g_btnTickX1 + btnCenterX, btnCenterY,
                  IntegerToString(tickPoints), FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 5. Imbalance threshold
   canvas.FillRectangle(g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2,
                        hoveredImb ? hoverFill : baseFill);
   canvas.Rectangle(g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2,
                    hoveredImb ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnImbX1 + btnCenterX, btnCenterY,
                  "Imb", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 6. Opacity control
   canvas.FillRectangle(g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2,
                        hoveredOpa ? hoverFill : baseFill);
   canvas.Rectangle(g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2,
                    hoveredOpa ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnOpaX1 + btnCenterX, btnCenterY,
                  "Opa", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 7. Show/Hide toggle
   uint showFill   = g_visible ? FpARGB(C'20,90,50', 230)   : FpARGB(C'90,30,30', 230);
   uint showBorder = g_visible ? FpARGB(C'80,200,120', 230) : FpARGB(C'200,80,80', 230);
   if(hoveredShow) { showFill = hoverFill; showBorder = hoverBorder; }
   canvas.FillRectangle(g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2, showFill);
   canvas.Rectangle(g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2, showBorder);
   canvas.TextOut(g_btnShowX1 + btnCenterX, btnCenterY,
                  g_visible ? "ON" : "OFF", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 8. Refresh (reload tick data)
   canvas.FillRectangle(g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2,
                        hoveredRefresh ? hoverFill : baseFill);
   canvas.Rectangle(g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2,
                    hoveredRefresh ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnRefreshX1 + btnCenterX, btnCenterY,
                  "Rld", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // 9. VA% (Value Area: 70% -> 80% -> 90% -> 70%)
   canvas.FillRectangle(g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2,
                        hoveredVA ? hoverFill : baseFill);
   canvas.Rectangle(g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2,
                    hoveredVA ? hoverBorder : baseBorder);
   double vaPct = GetEffectiveVAPercent();
   canvas.TextOut(g_btnVAX1 + btnCenterX, btnCenterY,
                  IntegerToString((int)vaPct) + "%", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);
}

//+------------------------------------------------------------------+
//| Draw visible footprint bars
//+------------------------------------------------------------------+
void DrawVisibleBars(int visBars, int firstVis, int barW)
{
   for(int v = 0; v < visBars; v++)
   {
      int shift = firstVis - v;
      if(shift < 0) continue;

      datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);
      int idx = FindBarIndex(bt);
      if(idx >= 0)
         DrawBar(idx, shift, barW);
   }
}

//+------------------------------------------------------------------+
//| Master render
//+------------------------------------------------------------------+
void Render()
{
   int cw = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(cw <= 0 || ch <= 0) return;

   if(canvas.Width() != cw || canvas.Height() != ch)
      canvas.Resize(cw, ch);

   canvas.Erase(0x00000000);

   int visBars  = (int)ChartGetInteger(g_chart, CHART_VISIBLE_BARS);
   if(visBars < 1) visBars = 1;
   int barW     = cw / visBars;
   int firstVis = (int)ChartGetInteger(g_chart, CHART_FIRST_VISIBLE_BAR);
   if(ArraySize(g_bars) == 0) { canvas.Update(); return; }

   g_hideText = (barW < 26);

   canvas.FontSet("Consolas", 9, FW_NORMAL);
   int opaPct = (g_opacity * 100) / 255;
   string tsLabel = "Tick: " + DoubleToString(g_step, _Digits)
                    + "  Imb: " + DoubleToString(g_imbRatio, 0) + "%"
                    + "  VA: " + DoubleToString(GetEffectiveVAPercent(), 0) + "%"
                    + "  Opa: " + IntegerToString(opaPct) + "%";
   canvas.TextOut(5, 5, tsLabel, FpARGB(C'160,160,170', 180), TA_LEFT | TA_TOP);

   LayoutPanel(cw, ch);
   DrawPanel();

   if(!g_visible)
   {
      canvas.Update();
      g_dirty = false;
      return;
   }

   DrawVisibleBars(visBars, firstVis, barW);

   canvas.Update();
   g_dirty = false;
}

//+------------------------------------------------------------------+
int OnInit()
{

   // Use input directly (in points). Min 1, max 10000 to avoid bad aggregation.
   int pts = MathMax(1, MathMin(10000, InpTickSize));
   g_step = pts * _Point;
   g_chart   = ChartID();
   g_sub     = 0;
   g_prevBid = 0.0;
   g_dirty   = true;
   g_hideText = false;
   g_imbRatio = InpImbalanceRatio;

   g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);
   PrintFormat("FP v10: %s  step=%s  mode=%s",
               _Symbol, DoubleToString(g_step, _Digits),
               g_hasTrades ? "Trades" : "Forex");

   int w = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(w < 1) w = 800;
   if(h < 1) h = 600;

   if(!canvas.CreateBitmapLabel(g_name, 0, 0, w, h,
                                 COLOR_FORMAT_ARGB_NORMALIZE))
   {
      Print("FP ERR: Canvas creation failed");
      return INIT_FAILED;
   }
   ObjectSetInteger(g_chart, g_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(g_chart, g_name, OBJPROP_BACK, false);
   canvas.Erase(0x00000000);
   canvas.Update();

   ReloadHistory();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   canvas.Destroy();
   ObjectDelete(g_chart, g_name);
   ArrayFree(g_bars);
   ArrayFree(g_scratchY1);
   ArrayFree(g_scratchY2);
   g_scratchCap = 0;
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   MqlTick ticks[];
   uint flag = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;

   long now_msc = (long)TimeCurrent() * 1000;
   long from_msc = g_last_tick_time_ms;

   if(from_msc == 0)
   {
      long lookback = 60000;
      if(now_msc > lookback)
         from_msc = now_msc - lookback;
      else
         from_msc = now_msc;
   }

   int copied = CopyTicksRange(_Symbol, ticks, flag, from_msc, now_msc);
   if(copied > 0)
   {
      if(g_prevBid == 0.0)
         g_prevBid = ticks[0].bid;
      ProcessTicks(ticks, 0, copied, true, true);
   }

   if(g_dirty)
      ThrottledRender();
   return rates_total;
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_KEYDOWN)
      return;

   else if(id == CHARTEVENT_CHART_CHANGE)
   {
      g_dirty = true;
      ThrottledRender();
   }

   else if(id == CHARTEVENT_MOUSE_MOVE)
   {
      int newMX = (int)lparam;
      int newMY = (int)dparam;

      bool wasNearPanel = HitTest(g_mouseX, g_mouseY,
                                   g_panelX1 - 10, g_panelY1 - 10,
                                   g_panelX2 + 10, g_panelY2 + 10);
      bool nowNearPanel = HitTest(newMX, newMY,
                                   g_panelX1 - 10, g_panelY1 - 10,
                                   g_panelX2 + 10, g_panelY2 + 10);

      g_mouseX = newMX;
      g_mouseY = newMY;

      if(wasNearPanel || nowNearPanel)
         ThrottledRender();
   }

   else if(id == CHARTEVENT_CLICK)
   {
      int mx = (int)lparam;
      int my = (int)dparam;

      // Tick button: increment by 10 (10 -> 20 -> 30 -> ... -> 100 -> 10)
      if(HitTest(mx, my, g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2))
      {
         int curPoints = (int)MathRound(g_step / _Point);
         int nextPoints;
         if(curPoints >= 100)
            nextPoints = 10;
         else
         {
            nextPoints = curPoints + 10;
            if(nextPoints > 100) nextPoints = 100;
         }

         g_step = nextPoints * _Point;
         ReloadHistory();
         ThrottledRender();
      }
      // Imb button: cycle imbalance ratio
      else if(HitTest(mx, my, g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2))
      {
         if(g_imbRatio <= FP_IMB_LO)      g_imbRatio = FP_IMB_MID;
         else if(g_imbRatio <= FP_IMB_MID) g_imbRatio = FP_IMB_HI;
         else                              g_imbRatio = FP_IMB_LO;
         g_dirty = true;
      }
      // Zoom-in
      else if(HitTest(mx, my, g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2))
      {
         int scale = (int)ChartGetInteger(g_chart, CHART_SCALE, 0);
         if(scale < 5)
            ChartSetInteger(g_chart, CHART_SCALE, 0, scale + 1);
      }
      // Zoom-out
      else if(HitTest(mx, my, g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2))
      {
         int scale = (int)ChartGetInteger(g_chart, CHART_SCALE, 0);
         if(scale > 0)
            ChartSetInteger(g_chart, CHART_SCALE, 0, scale - 1);
      }
      // Scale-fix toggle
      else if(HitTest(mx, my, g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2))
      {
         bool on = (bool)ChartGetInteger(g_chart, CHART_SCALEFIX, 0);
         ChartSetInteger(g_chart, CHART_SCALEFIX, 0, !on);
         g_dirty = true;
      }
      // Opacity button: cycle 100% -> 75% -> 50% -> 25% -> 100%
      else if(HitTest(mx, my, g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2))
      {
         if(g_opacity >= FP_OPA_FULL)      g_opacity = FP_OPA_75;
         else if(g_opacity >= FP_OPA_75)   g_opacity = FP_OPA_50;
         else if(g_opacity >= FP_OPA_50)   g_opacity = FP_OPA_25;
         else                              g_opacity = FP_OPA_FULL;
         g_dirty = true;
      }
      // Show/Hide toggle
      else if(HitTest(mx, my, g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2))
      {
         g_visible = !g_visible;
         g_dirty = true;
      }
      // Refresh: reload tick data
      else if(HitTest(mx, my, g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2))
      {
         ReloadHistory();
         ThrottledRender();
      }
      // VA%: cycle Value Area 70% -> 80% -> 90% -> 70%
      else if(HitTest(mx, my, g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2))
      {
         if(g_vaPercent <= 0.0 || g_vaPercent < 70.0) g_vaPercent = 70.0;
         else if(g_vaPercent <= 70.0) g_vaPercent = 80.0;
         else if(g_vaPercent <= 80.0) g_vaPercent = 90.0;
         else g_vaPercent = 70.0;
         g_dirty = true;
      }
   }
}
//+------------------------------------------------------------------+