//+------------------------------------------------------------------+
//|                                                           fp.mq5 |
//|                           Footprint (Bid x Ask Cluster) Chart    |
//+------------------------------------------------------------------+
#property copyright "Trading Tool"
#property link      "https://mql5.com"
#property version   "9.00"
#property description "Industry Standard Footprint Chart — CCanvas overlay"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- Inputs
input group "Data & History"
input int    InpTickSize       = 300;           // Tick Size (points per cell)
input double InpImbalanceRatio = 300.0;         // Imbalance Threshold (%)
input int    InpHistoryBars    = 100;           // History bars to load
input double InpVAPercent      = 70.0;          // Value Area %

input group "Visual"
input int    InpFontSize       = 8;             // Base font size
input uchar  InpBgAlpha        = 210;           // Cell Background Alpha (0-255)
input uchar  InpVAOffAlpha     = 80;            // Alpha outside Value Area (0-255)

input group "Colors"
input color  InpBidColor       = C'180,60,60';  // Bid (Sell) side color
input color  InpAskColor       = C'50,160,80';  // Ask (Buy) side color
input color  InpNeutralColor   = C'50,50,60';   // Neutral / Empty cell
input color  InpPOCColor       = C'255,215,0';  // POC highlight (Gold)
input color  InpImbBuyBg       = C'0,200,80';   // Buy Imbalance marker
input color  InpImbSellBg      = C'220,40,40';  // Sell Imbalance marker
input color  InpDeltaPosColor  = C'40,180,90';  // Positive Delta
input color  InpDeltaNegColor  = C'200,50,50';  // Negative Delta

//--- Data structures
struct PriceLevel
{
   double price;
   long   bid_vol;
   long   ask_vol;
   long   total_vol;
   long   delta;
};

struct FPBar
{
   datetime   bar_time;
   long       total_vol;
   long       total_delta;
   bool       sorted;
   int        level_count;
   PriceLevel levels[];
};

//--- Globals
CCanvas  canvas;
string   g_name     = "FP_Canvas";
FPBar    g_bars[];
double   g_tick;
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
#define FP_RENDER_THROTTLE_MS 33
#define FP_MIN_CELL_H         16

int g_panelX1, g_panelY1, g_panelX2, g_panelY2;
int g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2;
int g_btnImbX1,  g_btnImbY1,  g_btnImbX2,  g_btnImbY2;
int g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2;
int g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2;
int g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2;
int g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2;
int g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2;
int g_mouseX = -1, g_mouseY = -1;
bool g_visible = true;

// Persistent scratch buffers
int  g_scratchY1[];
int  g_scratchY2[];
int  g_scratchCap = 0;

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
   for(int i = n; i > pos; i--)
      g_bars[i] = g_bars[i - 1];

   g_bars[pos].bar_time    = bt;
   g_bars[pos].total_vol   = 0;
   g_bars[pos].total_delta = 0;
   g_bars[pos].sorted      = true;
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
void Feed(datetime bt, double price, long vol, bool isBuy, bool isSell)
{
   if(bt == 0 || price == 0.0) return;
   price = NormP(price);
   int bi = GetBar(bt);

   int used = g_bars[bi].level_count;
   for(int i = 0; i < used; i++)
   {
      if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.4)
      {
         if(isBuy)  g_bars[bi].levels[i].ask_vol += vol;
         if(isSell) g_bars[bi].levels[i].bid_vol += vol;
         g_bars[bi].levels[i].total_vol += vol;
         g_bars[bi].levels[i].delta =
            g_bars[bi].levels[i].ask_vol - g_bars[bi].levels[i].bid_vol;
         g_bars[bi].total_vol += vol;
         if(isBuy)  g_bars[bi].total_delta += vol;
         if(isSell) g_bars[bi].total_delta -= vol;
         g_bars[bi].sorted = false;
         g_dirty = true;
         return;
      }
   }
   int capacity = ArraySize(g_bars[bi].levels);
   if(used >= capacity)
   {
      ArrayResize(g_bars[bi].levels, capacity + 64, 64);
      capacity = ArraySize(g_bars[bi].levels);
   }

   int idx = g_bars[bi].level_count;
   g_bars[bi].levels[idx].price     = price;
   g_bars[bi].levels[idx].ask_vol   = isBuy  ? vol : 0;
   g_bars[bi].levels[idx].bid_vol   = isSell ? vol : 0;
   g_bars[bi].levels[idx].total_vol = vol;
   g_bars[bi].levels[idx].delta     =
      g_bars[bi].levels[idx].ask_vol - g_bars[bi].levels[idx].bid_vol;
   g_bars[bi].level_count++;
   g_bars[bi].total_vol += vol;
   if(isBuy)  g_bars[bi].total_delta += vol;
   if(isSell) g_bars[bi].total_delta -= vol;
   g_bars[bi].sorted = false;
   g_dirty = true;
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

   for(int i = 0; i < copied; i++)
   {
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
      g_prevBid = ticks[i].bid;

      int shift = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
      if(shift < 0) continue;
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);
      Feed(bt, price, vol, isBuy, isSell);
   }

   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++)
   {
      SortLevels(g_bars[i].levels, g_bars[i].level_count);
      g_bars[i].sorted = true;
   }

   PrintFormat("FP: %d ticks -> %d bars", copied, n);
   g_dirty = true;
   if(copied > 0)
      g_last_tick_time_ms = ticks[copied - 1].time_msc;
   return copied;
}

//+------------------------------------------------------------------+
void SortLevels(PriceLevel &lv[], int n)
{
   if(n <= 1) return;
   for(int i = 1; i < n; i++)
   {
      PriceLevel k = lv[i];
      int j = i - 1;
      while(j >= 0 && lv[j].price < k.price) { lv[j + 1] = lv[j]; j--; }
      lv[j + 1] = k;
   }
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
void FindVA(const PriceLevel &lv[], int count, long totVol, int poc, int &lo, int &hi)
{
   lo = poc; hi = poc;
   if(poc < 0) return;
   long target = (long)(totVol * InpVAPercent / 100.0);
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
//| - Volume heatmap intensity per side                               |
//| - Clean POC line                                                  |
//| - Value Area shading                                              |
//+------------------------------------------------------------------+
void DrawBar(int bi, int shift, int barW)
{
   int len = g_bars[bi].level_count;
   if(len == 0) return;

   if(!g_bars[bi].sorted)
   {
      SortLevels(g_bars[bi].levels, g_bars[bi].level_count);
      g_bars[bi].sorted = true;
   }

   int poc = FindPOC(g_bars[bi].levels, len);
   int vaLo, vaHi;
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, poc, vaLo, vaHi);

   datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);

   // --- X geometry ---
   int halfW = (int)(barW * 0.46);
   if(halfW < 20) halfW = 20;

   int xc, yd;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, xc, yd);
   int x1 = xc - halfW;
   int x2 = xc + halfW;
   int cellW = x2 - x1;
   int midX = (x1 + x2) / 2;

   // --- Y layout ---
   int natY1, natY2, tmpX;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, tmpX, natY1);
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price - g_step, tmpX, natY2);
   int nativeCellH = MathAbs(natY2 - natY1);
   if(nativeCellH < 1) nativeCellH = 1;
   int cellH = (nativeCellH < FP_MIN_CELL_H) ? FP_MIN_CELL_H : nativeCellH;

   int midIdx = len / 2;
   int anchorY;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[midIdx].price, tmpX, anchorY);

   EnsureScratch(len);

   g_scratchY1[midIdx] = anchorY - cellH / 2;
   g_scratchY2[midIdx] = g_scratchY1[midIdx] + cellH;

   for(int i = midIdx - 1; i >= 0; i--)
   {
      g_scratchY2[i] = g_scratchY1[i + 1];
      g_scratchY1[i] = g_scratchY2[i] - cellH;
   }
   for(int i = midIdx + 1; i < len; i++)
   {
      g_scratchY1[i] = g_scratchY2[i - 1];
      g_scratchY2[i] = g_scratchY1[i] + cellH;
   }

   bool skipText = g_hideText || (cellH < 10) || (cellW < 24);

   // Max volumes for intensity scaling (separate per side for better contrast)
   long maxBidVol = 1, maxAskVol = 1;
   for(int i = 0; i < len; i++)
   {
      if(g_bars[bi].levels[i].bid_vol > maxBidVol)
         maxBidVol = g_bars[bi].levels[i].bid_vol;
      if(g_bars[bi].levels[i].ask_vol > maxAskVol)
         maxAskVol = g_bars[bi].levels[i].ask_vol;
   }

   // Pre-compute constant colors with opacity applied
   color darkBase = C'30,30,38';
   int opaScale = g_opacity;  // master opacity
   uint colDivider   = FpARGB(C'60,60,70', (180 * opaScale) / 255);
   uint colCellBorder= FpARGB(C'45,45,55', (140 * opaScale) / 255);
   uint colPOC       = FpARGB(InpPOCColor, opaScale);
   uint colWhiteText = FpARGB(clrWhite, (220 * opaScale) / 255);
   uint colDimText   = FpARGB(C'140,140,150', (200 * opaScale) / 255);
   uint colImbBuyTxt = FpARGB(InpImbBuyBg, opaScale);
   uint colImbSellTxt= FpARGB(InpImbSellBg, opaScale);

   // Font setup
   int fs = 0;
   if(!skipText)
   {
      fs = (int)(cellH * 0.60);
      if(fs < 6) fs = 6;
      if(fs > 13) fs = 13;
      int fsByWidth = (int)(cellW / 4.0);
      if(fsByWidth < fs) fs = MathMax(6, fsByWidth);
      canvas.FontSet("Consolas", fs, FW_NORMAL);
   }

   // ============================================================
   // SINGLE PASS: Industry standard split Bid | Ask layout
   // ============================================================
   // Pre-compute text centers (invariant across loop)
   int leftCenter  = (x1 + midX) / 2;
   int rightCenter = (midX + x2) / 2;
   int imbStripeW  = MathMax(2, cellW / 30);  // scale stripe with cell width
   uint colImbSellStripe = FpARGB(InpImbSellBg, (220 * opaScale) / 255);
   uint colImbBuyStripe  = FpARGB(InpImbBuyBg,  (220 * opaScale) / 255);
   double invMaxBid = 1.0 / (double)maxBidVol;
   double invMaxAsk = 1.0 / (double)maxAskVol;

   for(int i = 0; i < len; i++)
   {
      int y_top = g_scratchY1[i];
      int y_bot = g_scratchY2[i];

      // Cache level data in locals (avoids repeated struct+array access)
      long lv_bid = g_bars[bi].levels[i].bid_vol;
      long lv_ask = g_bars[bi].levels[i].ask_vol;

      bool inVA = (i >= vaLo && i <= vaHi);
      int alpha = inVA ? (int)InpBgAlpha : (int)InpVAOffAlpha;
      alpha = (alpha * opaScale) / 255;  // apply master opacity

      // --- Diagonal Imbalance Detection (industry standard) ---
      bool isAskImb = false;
      bool isBidImb = false;
      if(i < len - 1)
      {
         long nextBid = g_bars[bi].levels[i + 1].bid_vol;
         if(nextBid > 0 && (double)lv_ask / (double)nextBid * 100.0 > g_imbRatio)
            isAskImb = true;
      }
      if(i > 0)
      {
         long prevAsk = g_bars[bi].levels[i - 1].ask_vol;
         if(prevAsk > 0 && (double)lv_bid / (double)prevAsk * 100.0 > g_imbRatio)
            isBidImb = true;
      }

      // --- LEFT HALF: Bid (Sell) Volume ---
      {
         color bidBg = darkBase;
         if(lv_bid > 0)
            bidBg = LerpColor(darkBase, InpBidColor, (double)lv_bid * invMaxBid * 0.8);

         canvas.FillRectangle(x1, y_top, midX - 1, y_bot, FpARGB(bidBg, alpha));

         if(isBidImb)
            canvas.FillRectangle(x1, y_top, x1 + imbStripeW, y_bot, colImbSellStripe);
      }

      // --- RIGHT HALF: Ask (Buy) Volume ---
      {
         color askBg = darkBase;
         if(lv_ask > 0)
            askBg = LerpColor(darkBase, InpAskColor, (double)lv_ask * invMaxAsk * 0.8);

         canvas.FillRectangle(midX + 1, y_top, x2, y_bot, FpARGB(askBg, alpha));

         if(isAskImb)
            canvas.FillRectangle(x2 - imbStripeW, y_top, x2, y_bot, colImbBuyStripe);
      }

      // --- Center divider line ---
      canvas.Line(midX, y_top, midX, y_bot, colDivider);

      // --- Subtle horizontal separator (bottom of cell) ---
      canvas.Line(x1, y_bot, x2, y_bot, colCellBorder);

      // --- POC ---
      if(i == poc)
      {
         canvas.Line(x1, y_top, x1, y_bot, colPOC);
         canvas.Line(x2, y_top, x2, y_bot, colPOC);
         canvas.Line(x1, y_top, x2, y_top, colPOC);
         canvas.Line(x1, y_bot, x2, y_bot, colPOC);
      }

      // --- Text: Bid vol on left, Ask vol on right ---
      if(!skipText)
      {
         int yy = (y_top + y_bot) / 2;

         if(lv_bid > 0)
         {
            uint bidTCol = isBidImb ? colImbSellTxt : colWhiteText;
            canvas.TextOut(leftCenter, yy, IntegerToString(lv_bid), bidTCol, TA_CENTER | TA_VCENTER);
         }

         if(lv_ask > 0)
         {
            uint askTCol = isAskImb ? colImbBuyTxt : colWhiteText;
            canvas.TextOut(rightCenter, yy, IntegerToString(lv_ask), askTCol, TA_CENTER | TA_VCENTER);
         }
      }
   }

   // ============================================================
   // Summary Row: Delta bar (clean, industry standard)
   // ============================================================
   int lastCellBot = g_scratchY2[len - 1];
   int sy = lastCellBot + 2;
   int sh = skipText ? 12 : 16;

   long d = g_bars[bi].total_delta;
   color dc = (d >= 0) ? InpDeltaPosColor : InpDeltaNegColor;

   canvas.FillRectangle(x1, sy, x2, sy + sh, FpARGB(dc, (180 * opaScale) / 255));
   canvas.Line(x1, sy, x2, sy, colCellBorder);

   if(!skipText)
   {
      canvas.FontSet("Consolas", 9, FW_NORMAL);
      string deltaStr = (d >= 0 ? "+" : "") + IntegerToString(d);
      canvas.TextOut(xc, sy + sh / 2, deltaStr,
                     FpARGB(clrWhite, (240 * opaScale) / 255), TA_CENTER | TA_VCENTER);

      sy += sh + 1;
      canvas.FillRectangle(x1, sy, x2, sy + sh - 2, FpARGB(C'35,35,42', (180 * opaScale) / 255));
      canvas.TextOut(xc, sy + (sh - 2) / 2,
                     "V:" + IntegerToString(g_bars[bi].total_vol),
                     colDimText, TA_CENTER | TA_VCENTER);
   }
   else
   {
      canvas.FontSet("Consolas", 7, FW_NORMAL);
      canvas.TextOut(xc, sy + sh / 2, IntegerToString(d),
                     FpARGB(clrWhite, (230 * opaScale) / 255), TA_CENTER | TA_VCENTER);
   }
}

//+------------------------------------------------------------------+
//| Master render                                                     |
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
   int totalBars = ArraySize(g_bars);
   if(totalBars == 0) { canvas.Update(); return; }

   g_hideText = (barW < 26);

   // Info label (top-left, subtle)
   canvas.FontSet("Consolas", 9, FW_NORMAL);
   int opaPct = (g_opacity * 100) / 255;
   string tsLabel = "Tick: " + DoubleToString(g_step, _Digits)
                    + "  Imb: " + DoubleToString(g_imbRatio, 0) + "%"
                    + "  Opa: " + IntegerToString(opaPct) + "%";
   canvas.TextOut(5, 5, tsLabel, FpARGB(C'160,160,170', 180), TA_LEFT | TA_TOP);

   // --- Control panel ---
   int panelH = FP_PANEL_H;
   int btnW   = FP_PANEL_BTN_W;
   int btnGap = FP_PANEL_BTN_GAP;
   int pad    = FP_PANEL_PAD;
   int panelW = pad + (btnW * 7 + btnGap * 6) + pad;

   g_panelX2 = cw - FP_PANEL_MARGIN;
   g_panelX1 = g_panelX2 - panelW;
   g_panelY1 = ch - panelH - FP_PANEL_MARGIN;
   g_panelY2 = g_panelY1 + panelH;

   canvas.FillRectangle(g_panelX1, g_panelY1, g_panelX2, g_panelY2, FpARGB(C'20,20,28', 200));
   canvas.Rectangle(g_panelX1, g_panelY1, g_panelX2, g_panelY2, FpARGB(C'70,70,80', 200));

   // Button positions
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

   // Hover detection
   bool hoveredTick    = (g_mouseX >= g_btnTickX1    && g_mouseX <= g_btnTickX2    &&
                          g_mouseY >= g_btnTickY1    && g_mouseY <= g_btnTickY2);
   bool hoveredImb     = (g_mouseX >= g_btnImbX1     && g_mouseX <= g_btnImbX2     &&
                          g_mouseY >= g_btnImbY1     && g_mouseY <= g_btnImbY2);
   bool hoveredZoomIn  = (g_mouseX >= g_btnZoomInX1  && g_mouseX <= g_btnZoomInX2  &&
                          g_mouseY >= g_btnZoomInY1  && g_mouseY <= g_btnZoomInY2);
   bool hoveredZoomOut = (g_mouseX >= g_btnZoomOutX1 && g_mouseX <= g_btnZoomOutX2 &&
                          g_mouseY >= g_btnZoomOutY1 && g_mouseY <= g_btnZoomOutY2);
   bool hoveredScaleFix= (g_mouseX >= g_btnScaleFixX1 && g_mouseX <= g_btnScaleFixX2 &&
                          g_mouseY >= g_btnScaleFixY1 && g_mouseY <= g_btnScaleFixY2);
   bool hoveredOpa     = (g_mouseX >= g_btnOpaX1  && g_mouseX <= g_btnOpaX2  &&
                          g_mouseY >= g_btnOpaY1  && g_mouseY <= g_btnOpaY2);
   bool hoveredShow    = (g_mouseX >= g_btnShowX1 && g_mouseX <= g_btnShowX2 &&
                          g_mouseY >= g_btnShowY1 && g_mouseY <= g_btnShowY2);

   uint baseFill   = FpARGB(C'35,35,45', 230);
   uint hoverFill  = FpARGB(C'55,55,70', 250);
   uint baseBorder = FpARGB(C'80,80,90', 200);
   uint hoverBorder= FpARGB(C'140,140,160', 255);

   bool scaleFixOn = (bool)ChartGetInteger(g_chart, CHART_SCALEFIX, 0);
   int  btnCenterX = btnW / 2;
   int  btnCenterY = g_btnZoomOutY1 + (panelH - 6) / 2;

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

   // 4. Tick size
   canvas.FillRectangle(g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2,
                        hoveredTick ? hoverFill : baseFill);
   canvas.Rectangle(g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2,
                    hoveredTick ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnTickX1 + btnCenterX, btnCenterY,
                  "Tick", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

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

   if(!g_visible)
   {
      canvas.Update();
      g_dirty = false;
      return;
   }

   for(int v = 0; v < visBars; v++)
   {
      int shift = firstVis - v;
      if(shift < 0) continue;

      datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);
      int idx = FindBarIndex(bt);
      if(idx >= 0)
         DrawBar(idx, shift, barW);
   }

   canvas.Update();
   g_dirty = false;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tick <= 0.0) g_tick = _Point;
   g_step    = InpTickSize * _Point;
   g_chart   = ChartID();
   g_sub     = 0;
   g_prevBid = 0.0;
   g_dirty   = true;
   g_hideText = false;
   g_imbRatio = InpImbalanceRatio;

   g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);
   PrintFormat("FP v8: %s  tick=%s  step=%s  mode=%s",
               _Symbol, DoubleToString(g_tick, _Digits),
               DoubleToString(g_step, _Digits),
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

   datetime startTime = iTime(_Symbol, PERIOD_CURRENT,
                              MathMin(InpHistoryBars, iBars(_Symbol, PERIOD_CURRENT) - 1));
   datetime endTime   = TimeCurrent();
   LoadHistory(startTime, endTime);

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

      for(int i = 0; i < copied; i++)
      {
         if(ticks[i].time_msc <= g_last_tick_time_ms)
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
         if(sh >= 0)
         {
            datetime bt = iTime(_Symbol, PERIOD_CURRENT, sh);
            Feed(bt, price, vol, isBuy, isSell);
         }

         g_last_tick_time_ms = ticks[i].time_msc;
      }
   }

   if(g_dirty)
   {
      ulong now_ticks = GetTickCount();
      if(now_ticks - g_last_render_ms >= FP_RENDER_THROTTLE_MS)
      {
         Render();
         g_last_render_ms = now_ticks;
      }
   }
   return rates_total;
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_KEYDOWN)
      return;

   if(id == CHARTEVENT_CHART_CHANGE)
   {
      g_dirty = true;
      Render();
   }

   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      int newMX = (int)lparam;
      int newMY = (int)dparam;

      bool wasNearPanel = (g_mouseX >= g_panelX1 - 10 && g_mouseX <= g_panelX2 + 10 &&
                           g_mouseY >= g_panelY1 - 10 && g_mouseY <= g_panelY2 + 10);
      bool nowNearPanel = (newMX >= g_panelX1 - 10 && newMX <= g_panelX2 + 10 &&
                           newMY >= g_panelY1 - 10 && newMY <= g_panelY2 + 10);

      g_mouseX = newMX;
      g_mouseY = newMY;

      if(wasNearPanel || nowNearPanel)
      {
         ulong now_ticks = GetTickCount();
         if(now_ticks - g_last_render_ms >= FP_RENDER_THROTTLE_MS)
         {
            Render();
            g_last_render_ms = now_ticks;
         }
      }
   }

   if(id == CHARTEVENT_CLICK)
   {
      int mx = (int)lparam;
      int my = (int)dparam;

      // Tick button: cycle aggregation (100 -> 500 -> 1000)
      if(mx >= g_btnTickX1 && mx <= g_btnTickX2 &&
         my >= g_btnTickY1 && my <= g_btnTickY2)
      {
         int curPoints = (int)MathRound(g_step / _Point);
         int nextPoints = 100;
         if(curPoints <= 100)      nextPoints = 500;
         else if(curPoints <= 500) nextPoints = 1000;
         else                      nextPoints = 100;

         g_step = nextPoints * _Point;
         ArrayFree(g_bars);

         datetime startTime = iTime(_Symbol, PERIOD_CURRENT,
                                    MathMin(InpHistoryBars, iBars(_Symbol, PERIOD_CURRENT) - 1));
         datetime endTime   = TimeCurrent();
         LoadHistory(startTime, endTime);
         g_dirty = true;
      }

      // Imb button: cycle imbalance ratio
      if(mx >= g_btnImbX1 && mx <= g_btnImbX2 &&
         my >= g_btnImbY1 && my <= g_btnImbY2)
      {
         if(g_imbRatio <= 200.0)      g_imbRatio = 300.0;
         else if(g_imbRatio <= 300.0) g_imbRatio = 400.0;
         else                         g_imbRatio = 200.0;

         g_dirty = true;
      }

      // Zoom-in
      if(mx >= g_btnZoomInX1 && mx <= g_btnZoomInX2 &&
         my >= g_btnZoomInY1 && my <= g_btnZoomInY2)
      {
         int scale = (int)ChartGetInteger(g_chart, CHART_SCALE, 0);
         if(scale < 5)
            ChartSetInteger(g_chart, CHART_SCALE, 0, scale + 1);
      }

      // Zoom-out
      if(mx >= g_btnZoomOutX1 && mx <= g_btnZoomOutX2 &&
         my >= g_btnZoomOutY1 && my <= g_btnZoomOutY2)
      {
         int scale = (int)ChartGetInteger(g_chart, CHART_SCALE, 0);
         if(scale > 0)
            ChartSetInteger(g_chart, CHART_SCALE, 0, scale - 1);
      }

      // Scale-fix toggle
      if(mx >= g_btnScaleFixX1 && mx <= g_btnScaleFixX2 &&
         my >= g_btnScaleFixY1 && my <= g_btnScaleFixY2)
      {
         bool on = (bool)ChartGetInteger(g_chart, CHART_SCALEFIX, 0);
         ChartSetInteger(g_chart, CHART_SCALEFIX, 0, !on);
         g_dirty = true;
      }

      // Opacity button: cycle 100% -> 75% -> 50% -> 25% -> 100%
      if(mx >= g_btnOpaX1 && mx <= g_btnOpaX2 &&
         my >= g_btnOpaY1 && my <= g_btnOpaY2)
      {
         if(g_opacity >= 255)      g_opacity = 190;   // ~75%
         else if(g_opacity >= 190)  g_opacity = 127;   // ~50%
         else if(g_opacity >= 127)  g_opacity = 64;    // ~25%
         else                       g_opacity = 255;   // 100%
         g_dirty = true;
      }

      // Show/Hide toggle
      if(mx >= g_btnShowX1 && mx <= g_btnShowX2 &&
         my >= g_btnShowY1 && my <= g_btnShowY2)
      {
         g_visible = !g_visible;
         g_dirty = true;
      }
   }
}
//+------------------------------------------------------------------+