//+------------------------------------------------------------------+
//|                                                     Bookmap.mq5  |
//|   Bookmap — Chart-Aligned Heatmap + Concentric Trade Rings       |
//|   Tick volume per price level rendered on chart candle positions  |
//+------------------------------------------------------------------+
#property copyright "Ali Magdy"
#property version   "2.00"
#property description "Bookmap — Heatmap + Concentric Ring Trade Visualization"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- Inputs
input group "Data & Aggregation"
input int    InpCellPts         = 10;    // Price cell size (points)
input int    InpHistoryBars     = 100;   // Bars of history to preload

input group "Display — Bubbles"
input bool   InpShowBubbles     = true;  // Show trade bubbles
input int    InpMaxBubbleR      = 40;    // Max bubble radius (px)
input int    InpMinBubbleR      = 6;     // Min bubble radius (px)
input int    InpRingCount       = 5;     // Concentric rings per bubble
input int    InpRingThickness   = 2;     // Ring line thickness

input group "Display — Heatmap"
input uchar  InpHeatAlpha       = 60;    // Heatmap cell max alpha (0=off, 255=full)
input bool   InpShowBidAsk      = true;  // Show best bid/ask dots

input group "Colors — Heatmap Ramp"
input color  InpC0 = C'4,6,18';         // Empty (dark)
input color  InpC1 = C'0,25,75';        // Very low (dark blue)
input color  InpC2 = C'0,70,140';       // Low (blue)
input color  InpC3 = C'0,140,160';      // Medium-low (teal)
input color  InpC4 = C'0,180,120';      // Medium (cyan-green)
input color  InpC5 = C'200,160,0';      // Medium-high (amber)
input color  InpC6 = C'220,70,0';       // High (orange-red)
input color  InpC7 = C'200,0,0';        // Extreme (red)

input group "Colors — Overlays"
input color  InpBuyColor  = C'30,210,60';   // Buy bubble rings
input color  InpSellColor = C'210,30,30';   // Sell bubble rings

//--- Per-price-level data within a bar
struct CellData
  {
   double   price;
   long     vol_bid;
   long     vol_ask;
   long     vol_total;
  };

//--- Aggregated bar data
struct BarData
  {
   datetime  bar_time;
   double    high;
   double    low;
   double    best_bid;
   double    best_ask;
   bool      is_bullish;
   long      total_vol;
   long      total_delta;
   int       cell_count;
   CellData  cells[];
  };

//--- Aggregated trade bubble per bar per price level
struct BarBubble
  {
   datetime  bar_time;
   double    price;
   long      buy_vol;
   long      sell_vol;
  };

//--- Globals
CCanvas       canvas;
string        g_name       = "BM_Canvas";
BarData       g_bars[];
BarBubble     g_bubbles[];
int           g_barCnt     = 0;
int           g_bubbleCnt  = 0;
double        g_step;
long          g_chart;
int           g_sub;
bool          g_hasTrades;
double        g_prevBid    = 0.0;
bool          g_dirty      = false;
int           g_opacity    = 255;
bool          g_visible    = true;
bool          g_showBubbles;
long          g_lastTickMsc = 0;
ulong         g_lastRenderMs = 0;
double        g_normVol    = 1.0;
double        g_normBubVol = 1.0;
int           g_mouseX = -1, g_mouseY = -1;
bool          g_needsReload = false;

color g_ramp[8];

//--- Panel
#define BM_BTN_W        46
#define BM_BTN_GAP      3
#define BM_PAD          3
#define BM_PANEL_H      24
#define BM_MARGIN       5
#define BM_THROTTLE_MS  33

int g_pX1, g_pY1, g_pX2, g_pY2;
int g_bCellX1, g_bCellY1, g_bCellX2, g_bCellY2;
int g_bOpaX1,  g_bOpaY1,  g_bOpaX2,  g_bOpaY2;
int g_bTrdX1,  g_bTrdY1,  g_bTrdX2,  g_bTrdY2;
int g_bShowX1, g_bShowY1, g_bShowX2, g_bShowY2;
int g_bRldX1,  g_bRldY1,  g_bRldX2,  g_bRldY2;
int g_bClrX1,  g_bClrY1,  g_bClrX2,  g_bClrY2;

//+------------------------------------------------------------------+
bool HitTest(int mx,int my,int x1,int y1,int x2,int y2)
  { return(mx>=x1&&mx<=x2&&my>=y1&&my<=y2); }

uint BmARGB(color c,int a)
  { return ColorToARGB(c,(uchar)MathMin(MathMax(a,0),255)); }

color LerpColor(color a,color b,double t)
  {
   if(t<0.0)t=0.0; if(t>1.0)t=1.0;
   int r =(int)((1.0-t)*(a&0xFF)     +t*(b&0xFF));
   int g =(int)((1.0-t)*((a>>8)&0xFF)+t*((b>>8)&0xFF));
   int bl=(int)((1.0-t)*((a>>16)&0xFF)+t*((b>>16)&0xFF));
   return(color)((bl<<16)|(g<<8)|r);
  }

double NormP(double p)
  { return MathFloor(p/g_step)*g_step; }

color HeatRamp(double v)
  {
   if(v<=0.0) return g_ramp[0];
   if(v>=1.0) return g_ramp[7];
   double pos=v*7.0;
   int    idx=(int)MathFloor(pos); if(idx>=7)idx=6;
   return LerpColor(g_ramp[idx],g_ramp[idx+1],pos-idx);
  }

//+------------------------------------------------------------------+
// Find bar index by time (binary search)
//+------------------------------------------------------------------+
int FindBar(datetime bt)
  {
   int lo=0, hi=g_barCnt-1;
   while(lo<=hi)
     {
      int mid=(lo+hi)/2;
      if(g_bars[mid].bar_time==bt) return mid;
      if(g_bars[mid].bar_time<bt) lo=mid+1; else hi=mid-1;
     }
   return -1;
  }

int GetBar(datetime bt)
  {
   int idx=FindBar(bt);
   if(idx>=0) return idx;

   // Append (fast path for chronological)
   int n=g_barCnt;
   if(n>0 && bt>g_bars[n-1].bar_time)
     {
      if(n>=ArraySize(g_bars)) ArrayResize(g_bars,n+128,128);
      g_bars[n].bar_time   = bt;
      g_bars[n].total_vol  = 0;
      g_bars[n].total_delta= 0;
      g_bars[n].cell_count = 0;
      g_bars[n].high       = 0;
      g_bars[n].low        = 0;
      g_bars[n].best_bid   = 0;
      g_bars[n].best_ask   = 0;
      g_bars[n].is_bullish = true;
      ArrayResize(g_bars[n].cells,64,64);
      g_barCnt++;
      return n;
     }

   // Insert sorted (rare)
   int pos=n;
   for(int i=n-1;i>=0;i--)
     { if(g_bars[i].bar_time<bt){pos=i+1;break;} pos=i; }

   if(n>=ArraySize(g_bars)) ArrayResize(g_bars,n+128,128);
   for(int i=n;i>pos;i--) g_bars[i]=g_bars[i-1];

   g_bars[pos].bar_time   = bt;
   g_bars[pos].total_vol  = 0;
   g_bars[pos].total_delta= 0;
   g_bars[pos].cell_count = 0;
   g_bars[pos].high       = 0;
   g_bars[pos].low        = 0;
   g_bars[pos].best_bid   = 0;
   g_bars[pos].best_ask   = 0;
   g_bars[pos].is_bullish = true;
   ArrayResize(g_bars[pos].cells,64,64);
   g_barCnt++;
   return pos;
  }

//+------------------------------------------------------------------+
int GetCell(int bi, double price)
  {
   int n=g_bars[bi].cell_count;
   for(int i=n-1;i>=0;i--)
      if(MathAbs(g_bars[bi].cells[i].price-price)<g_step*0.4)
         return i;

   if(n>=ArraySize(g_bars[bi].cells))
      ArrayResize(g_bars[bi].cells,n+64,64);

   g_bars[bi].cells[n].price     = price;
   g_bars[bi].cells[n].vol_bid   = 0;
   g_bars[bi].cells[n].vol_ask   = 0;
   g_bars[bi].cells[n].vol_total = 0;
   g_bars[bi].cell_count++;
   return n;
  }

//+------------------------------------------------------------------+
// Find or create a bubble entry for a bar+price
//+------------------------------------------------------------------+
int GetBubble(datetime bt, double price)
  {
   // Search backwards (recent first)
   for(int i=g_bubbleCnt-1;i>=0;i--)
     {
      if(g_bubbles[i].bar_time==bt &&
         MathAbs(g_bubbles[i].price-price)<g_step*0.4)
         return i;
      if(g_bubbles[i].bar_time<bt) break;
     }

   if(g_bubbleCnt>=ArraySize(g_bubbles))
      ArrayResize(g_bubbles,g_bubbleCnt+512,512);

   g_bubbles[g_bubbleCnt].bar_time = bt;
   g_bubbles[g_bubbleCnt].price    = price;
   g_bubbles[g_bubbleCnt].buy_vol  = 0;
   g_bubbles[g_bubbleCnt].sell_vol = 0;
   g_bubbleCnt++;
   return g_bubbleCnt-1;
  }

//+------------------------------------------------------------------+
void AccumulateTick(const MqlTick &tk, bool skipOld)
  {
   if(skipOld && tk.time_msc<=g_lastTickMsc)
      return;

   double price   = 0.0;
   long   vol     = 0;
   bool   isBuy   = false;
   bool   isSell  = false;
   bool   doAccum = false;

   if(g_hasTrades)
     {
      price = (double)tk.last;
      vol   = (long)tk.volume;
      if(vol > 0 && price != 0.0)
        {
         isBuy  = (tk.flags & TICK_FLAG_BUY)  == TICK_FLAG_BUY;
         isSell = (tk.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
         if(!isBuy && !isSell){ isBuy = (price >= tk.ask); isSell = !isBuy; }
         doAccum = true;
        }
     }
   else
     {
      price = (double)tk.bid;
      vol   = 1;
      if(price != 0.0)
        {
         isBuy  = (tk.bid > g_prevBid);
         isSell = (tk.bid < g_prevBid);
         if(!isBuy && !isSell) isBuy = true;
         doAccum = true;
        }
     }

   if(doAccum)
     {
      int sh = iBarShift(_Symbol, PERIOD_CURRENT, tk.time);
      if(sh < 0) sh = 0;
      datetime bt = iTime(_Symbol, PERIOD_CURRENT, sh);
      int bi = GetBar(bt);

      double normPrice = NormP(price);
      int ci = GetCell(bi, normPrice);

      if(isBuy)  g_bars[bi].cells[ci].vol_ask += vol;
      if(isSell) g_bars[bi].cells[ci].vol_bid += vol;
      g_bars[bi].cells[ci].vol_total += vol;

      g_bars[bi].total_vol   += vol;
      g_bars[bi].total_delta += (isBuy ? vol : -vol);

      double bOpen  = iOpen(_Symbol, PERIOD_CURRENT, sh);
      double bClose = iClose(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].is_bullish = (bClose >= bOpen);
      g_bars[bi].high       = iHigh(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].low        = iLow(_Symbol, PERIOD_CURRENT, sh);

      double cv = (double)g_bars[bi].cells[ci].vol_total;
      if(cv > g_normVol) g_normVol = cv;

      // Aggregate bubble
      int bubIdx = GetBubble(bt, normPrice);
      if(isBuy)  g_bubbles[bubIdx].buy_vol  += vol;
      if(isSell) g_bubbles[bubIdx].sell_vol  += vol;
      long totalBub = g_bubbles[bubIdx].buy_vol + g_bubbles[bubIdx].sell_vol;
      if((double)totalBub > g_normBubVol) g_normBubVol = (double)totalBub;

      g_dirty = true;
     }

   if(tk.bid != 0.0)
     {
      int sh2 = iBarShift(_Symbol, PERIOD_CURRENT, tk.time);
      if(sh2 < 0) sh2 = 0;
      datetime bt2 = iTime(_Symbol, PERIOD_CURRENT, sh2);
      int bi2 = GetBar(bt2);
      if(tk.bid > 0.0) g_bars[bi2].best_bid = tk.bid;
      if(tk.ask > 0.0) g_bars[bi2].best_ask = tk.ask;
      g_prevBid = tk.bid;
     }

   if(skipOld)
      g_lastTickMsc = tk.time_msc;
  }

//+------------------------------------------------------------------+
void LoadHistory()
  {
   int bars = iBars(_Symbol, PERIOD_CURRENT);
   if(bars <= 0) return;
   int span = MathMin(InpHistoryBars, bars - 1);
   datetime t0 = iTime(_Symbol, PERIOD_CURRENT, span);
   datetime t1 = TimeCurrent();

   MqlTick ticks[];
   uint flag = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   int copied = CopyTicksRange(_Symbol, ticks, flag, (long)t0 * 1000, (long)t1 * 1000);
   if(copied <= 0) return;

   g_prevBid = (ticks[0].bid != 0.0) ? ticks[0].bid : 0.0;
   for(int i = 0; i < copied; i++)
      AccumulateTick(ticks[i], false);

   g_dirty = true;
  }

//+------------------------------------------------------------------+
void ThrottledRender()
  {
   if(MQLInfoInteger(MQL_TESTER)){Render();return;}
   ulong now = GetTickCount();
   if(now - g_lastRenderMs >= BM_THROTTLE_MS){Render(); g_lastRenderMs = now;}
  }

//+------------------------------------------------------------------+
void LayoutPanel(int cw, int ch)
  {
   int nBtn = 6;
   int panelW = BM_PAD + (BM_BTN_W * nBtn + BM_BTN_GAP * (nBtn - 1)) + BM_PAD;
   g_pX2 = cw - BM_MARGIN; g_pX1 = g_pX2 - panelW;
   g_pY1 = ch - BM_PANEL_H - BM_MARGIN; g_pY2 = g_pY1 + BM_PANEL_H;
   int bY1 = g_pY1 + BM_PAD, bY2 = g_pY2 - BM_PAD;
   int cx = g_pX1 + BM_PAD;
#define NEXTBTN(vx1,vy1,vx2,vy2) vx1=cx;vy1=bY1;vx2=cx+BM_BTN_W;vy2=bY2;cx+=BM_BTN_W+BM_BTN_GAP;
   NEXTBTN(g_bCellX1, g_bCellY1, g_bCellX2, g_bCellY2)
   NEXTBTN(g_bOpaX1,  g_bOpaY1,  g_bOpaX2,  g_bOpaY2)
   NEXTBTN(g_bTrdX1,  g_bTrdY1,  g_bTrdX2,  g_bTrdY2)
   NEXTBTN(g_bShowX1, g_bShowY1, g_bShowX2, g_bShowY2)
   NEXTBTN(g_bRldX1,  g_bRldY1,  g_bRldX2,  g_bRldY2)
   NEXTBTN(g_bClrX1,  g_bClrY1,  g_bClrX2,  g_bClrY2)
#undef NEXTBTN
  }

void DrawBtn(int x1,int y1,int x2,int y2,string lbl,
             bool hov,bool active=false,color actCol=clrNONE)
  {
   uint fill   = hov ? BmARGB(C'55,55,70',250) :
                 (active ? BmARGB(actCol,220) : BmARGB(C'35,35,45',230));
   uint border = hov ? BmARGB(C'140,140,160',255) :
                 (active ? BmARGB(actCol,255) : BmARGB(C'80,80,90',200));
   canvas.FillRectangle(x1,y1,x2,y2,fill);
   canvas.Rectangle(x1,y1,x2,y2,border);
   canvas.TextOut((x1+x2)/2,(y1+y2)/2,lbl,BmARGB(clrWhite,210),TA_CENTER|TA_VCENTER);
  }

void DrawPanel()
  {
   canvas.FillRectangle(g_pX1,g_pY1,g_pX2,g_pY2,BmARGB(C'20,20,28',200));
   canvas.Rectangle(g_pX1,g_pY1,g_pX2,g_pY2,BmARGB(C'70,70,80',200));
   canvas.FontSet("Consolas",9,FW_NORMAL);

   int cellPts = (int)MathRound(g_step / _Point);
   int opaPct  = (g_opacity * 100) / 255;

   DrawBtn(g_bCellX1,g_bCellY1,g_bCellX2,g_bCellY2,
           IntegerToString(cellPts)+"p",
           HitTest(g_mouseX,g_mouseY,g_bCellX1,g_bCellY1,g_bCellX2,g_bCellY2));
   DrawBtn(g_bOpaX1,g_bOpaY1,g_bOpaX2,g_bOpaY2,
           IntegerToString(opaPct)+"%",
           HitTest(g_mouseX,g_mouseY,g_bOpaX1,g_bOpaY1,g_bOpaX2,g_bOpaY2));
   DrawBtn(g_bTrdX1,g_bTrdY1,g_bTrdX2,g_bTrdY2,"Bub",
           HitTest(g_mouseX,g_mouseY,g_bTrdX1,g_bTrdY1,g_bTrdX2,g_bTrdY2),
           g_showBubbles,C'20,90,50');
   DrawBtn(g_bShowX1,g_bShowY1,g_bShowX2,g_bShowY2,
           g_visible?"ON":"OFF",
           HitTest(g_mouseX,g_mouseY,g_bShowX1,g_bShowY1,g_bShowX2,g_bShowY2),
           g_visible,C'20,90,50');
   DrawBtn(g_bRldX1,g_bRldY1,g_bRldX2,g_bRldY2,"Rld",
           HitTest(g_mouseX,g_mouseY,g_bRldX1,g_bRldY1,g_bRldX2,g_bRldY2));
   DrawBtn(g_bClrX1,g_bClrY1,g_bClrX2,g_bClrY2,"Clr",
           HitTest(g_mouseX,g_mouseY,g_bClrX1,g_bClrY1,g_bClrX2,g_bClrY2));
  }

//+------------------------------------------------------------------+
// Draw concentric ring circle at position
//+------------------------------------------------------------------+
void DrawRings(int xc, int yc, int maxR, color col, int alpha)
  {
   int rings = InpRingCount;
   if(rings < 1) rings = 1;
   int thick = InpRingThickness;
   if(thick < 1) thick = 1;

   for(int r = 0; r < rings; r++)
     {
      double frac = (double)(r + 1) / (double)rings;
      int rad = (int)(maxR * frac);
      if(rad < 2) rad = 2;

      // Alpha fades outward
      int ringAlpha = (int)(alpha * (1.0 - frac * 0.5));
      if(ringAlpha < 10) ringAlpha = 10;

      // Draw thick ring using multiple outline circles
      for(int t = 0; t < thick; t++)
        {
         int rr = rad + t;
         if(rr > 0)
            canvas.Circle(xc, yc, rr, BmARGB(col, ringAlpha));
        }
     }

   // Bright core dot
   int coreR = MathMax(1, maxR / 8);
   canvas.FillCircle(xc, yc, coreR, BmARGB(clrWhite, alpha / 2));
  }

//+------------------------------------------------------------------+
// Main drawing: chart-aligned heatmap + concentric ring bubbles
//+------------------------------------------------------------------+
void DrawOverlay(int cw, int ch)
  {
   if(g_barCnt <= 0) return;

   int visBars  = (int)ChartGetInteger(g_chart, CHART_VISIBLE_BARS);
   int firstVis = (int)ChartGetInteger(g_chart, CHART_FIRST_VISIBLE_BAR);
   if(visBars < 1) visBars = 1;
   int barW = cw / visBars;

   double normV = MathMax(1.0, g_normVol);
   double normB = MathMax(1.0, g_normBubVol);

   for(int v = 0; v < visBars; v++)
     {
      int shift = firstVis - v;
      if(shift < 0) continue;

      datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);
      int bi = FindBar(bt);
      if(bi < 0) continue;

      // Get X center for this bar
      int xCenter, yTmp;
      ChartTimePriceToXY(g_chart, g_sub, bt,
                         (g_bars[bi].high + g_bars[bi].low) / 2.0,
                         xCenter, yTmp);

      // ---- Heatmap cells (subtle background) ----
      if(InpHeatAlpha > 0)
        {
         for(int c = 0; c < g_bars[bi].cell_count; c++)
           {
            double p = g_bars[bi].cells[c].price;
            long   cv = g_bars[bi].cells[c].vol_total;
            if(cv <= 0) continue;

            int px, py;
            ChartTimePriceToXY(g_chart, g_sub, bt, p, px, py);

            int px2, py2;
            ChartTimePriceToXY(g_chart, g_sub, bt, p - g_step, px2, py2);
            int cellH = MathAbs(py2 - py);
            if(cellH < 1) cellH = 1;

            double intensity = MathPow((double)cv / normV, 0.5);
            if(intensity > 1.0) intensity = 1.0;

            color cc = HeatRamp(intensity);
            int alpha = (int)(InpHeatAlpha * intensity);
            if(alpha < 3) alpha = 3;
            alpha = (alpha * g_opacity) / 255;

            int halfW = barW / 2;
            if(halfW < 2) halfW = 2;
            canvas.FillRectangle(px - halfW, py, px + halfW, py + cellH,
                                 BmARGB(cc, alpha));
           }
        }
     }

   // ---- Concentric Ring Bubbles (drawn on top) ----
   if(g_showBubbles && g_bubbleCnt > 0)
     {
      for(int b = 0; b < g_bubbleCnt; b++)
        {
         datetime bt  = g_bubbles[b].bar_time;
         double   p   = g_bubbles[b].price;
         long     bvol = g_bubbles[b].buy_vol;
         long     svol = g_bubbles[b].sell_vol;
         long     tvol = bvol + svol;
         if(tvol <= 0) continue;

         // Check if this bar is visible
         int sh = iBarShift(_Symbol, PERIOD_CURRENT, bt);
         if(sh < 0 || sh > firstVis) continue;
         if(sh < firstVis - visBars) continue;

         int px, py;
         ChartTimePriceToXY(g_chart, g_sub, bt, p, px, py);

         // Radius proportional to volume
         double vr = MathPow((double)tvol / normB, 0.55);
         if(vr > 1.0) vr = 1.0;
         int maxR = InpMinBubbleR + (int)(vr * (InpMaxBubbleR - InpMinBubbleR));

         int ringAlpha = (180 * g_opacity) / 255;

         // Draw buy rings (green) if buy volume > 0
         if(bvol > 0)
           {
            double bfrac = (double)bvol / (double)tvol;
            int buyR = MathMax(InpMinBubbleR, (int)(maxR * bfrac));
            DrawRings(px, py, buyR, InpBuyColor, ringAlpha);
           }

         // Draw sell rings (red) if sell volume > 0
         if(svol > 0)
           {
            double sfrac = (double)svol / (double)tvol;
            int sellR = MathMax(InpMinBubbleR, (int)(maxR * sfrac));
            DrawRings(px, py, sellR, InpSellColor, ringAlpha);
           }
        }
     }
  }

//+------------------------------------------------------------------+
void DrawLegend(int cw)
  {
   int lx = cw - 20, ly = 25, lh = 100, lw = 14;
   canvas.FillRectangle(lx-3, ly-3, lx+lw+3, ly+lh+20, BmARGB(C'12,12,18', 180));
   canvas.Rectangle(lx-3, ly-3, lx+lw+3, ly+lh+20, BmARGB(C'55,55,65', 140));
   for(int y = 0; y < lh; y++)
     {
      double v = 1.0 - (double)y / lh;
      canvas.LineHorizontal(lx, lx+lw, ly+y, BmARGB(HeatRamp(v), 220));
     }
   canvas.FontSet("Consolas", 7, FW_NORMAL);
   canvas.TextOut(lx+lw/2, ly+lh+3, "Vol", BmARGB(C'140,140,155', 180), TA_CENTER|TA_TOP);
  }

//+------------------------------------------------------------------+
void Render()
  {
   int cw = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(cw <= 0 || ch <= 0) return;
   if(canvas.Width() != cw || canvas.Height() != ch) canvas.Resize(cw, ch);
   canvas.Erase(0x00000000);

   if(g_barCnt == 0)
     {
      canvas.FontSet("Consolas", 11, FW_NORMAL);
      canvas.TextOut(cw/2, ch/2, "Bookmap: Loading tick data...",
                     BmARGB(C'120,120,140', 200), TA_CENTER|TA_VCENTER);
      LayoutPanel(cw, ch); DrawPanel();
      canvas.Update(); return;
     }

   // Header
   canvas.FontSet("Consolas", 9, FW_NORMAL);
   int cellPts = (int)MathRound(g_step / _Point);
   int opaPct  = (g_opacity * 100) / 255;
   string hdr = "BOOKMAP  Cell:" + IntegerToString(cellPts) + "p" +
                "  Bars:" + IntegerToString(g_barCnt) +
                "  Bubbles:" + IntegerToString(g_bubbleCnt) +
                "  Opa:" + IntegerToString(opaPct) + "%";
   canvas.TextOut(5, 5, hdr, BmARGB(C'160,160,170', 180), TA_LEFT|TA_TOP);

   LayoutPanel(cw, ch);
   DrawPanel();
   if(!g_visible){canvas.Update(); g_dirty = false; return;}
   DrawOverlay(cw, ch);
   DrawLegend(cw);
   canvas.Update();
   g_dirty = false;
  }

//+------------------------------------------------------------------+
void ClearAll()
  {
   for(int i = 0; i < g_barCnt; i++) ArrayFree(g_bars[i].cells);
   ArrayFree(g_bars);
   ArrayFree(g_bubbles);
   g_barCnt = 0; g_bubbleCnt = 0;
   g_normVol = 1.0; g_normBubVol = 1.0;
   g_lastTickMsc = 0; g_prevBid = 0.0;
   g_dirty = true;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_step       = MathMax(1, MathMin(10000, InpCellPts)) * _Point;
   g_chart      = ChartID();
   g_sub        = 0;
   g_showBubbles= InpShowBubbles;
   g_hasTrades  = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);

   g_ramp[0]=InpC0; g_ramp[1]=InpC1; g_ramp[2]=InpC2; g_ramp[3]=InpC3;
   g_ramp[4]=InpC4; g_ramp[5]=InpC5; g_ramp[6]=InpC6; g_ramp[7]=InpC7;

   ChartSetInteger(g_chart, CHART_EVENT_MOUSE_MOVE, 1);

   int w = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(w < 1) w = 800;
   if(h < 1) h = 600;

   if(!canvas.CreateBitmapLabel(g_name, 0, 0, w, h, COLOR_FORMAT_ARGB_NORMALIZE))
     { Alert("Bookmap: Canvas creation failed."); return INIT_FAILED; }
   ObjectSetInteger(g_chart, g_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(g_chart, g_name, OBJPROP_BACK, false);
   canvas.Erase(0x00000000);
   canvas.Update();

   LoadHistory();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   canvas.Destroy();
   ObjectDelete(g_chart, g_name);
   for(int i = 0; i < g_barCnt; i++) ArrayFree(g_bars[i].cells);
   ArrayFree(g_bars);
   ArrayFree(g_bubbles);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   if(rates_total == 0) return 0;

   if(prev_calculated == 0 || rates_total < prev_calculated ||
      g_barCnt == 0 || g_needsReload)
     {
      ClearAll();
      LoadHistory();
      g_needsReload = false;
      if(g_dirty) ThrottledRender();
      return rates_total;
     }

   MqlTick ticks[];
   uint flag = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long now_msc = (long)TimeCurrent() * 1000;
   long from_msc = g_lastTickMsc;
   if(from_msc == 0) from_msc = now_msc - 60000;

   int copied = CopyTicksRange(_Symbol, ticks, flag, from_msc, now_msc);
   if(copied > 0)
     {
      if(g_prevBid == 0.0 && ticks[0].bid != 0.0)
         g_prevBid = ticks[0].bid;
      for(int i = 0; i < copied; i++)
         AccumulateTick(ticks[i], true);
     }

   if(g_dirty) ThrottledRender();
   return rates_total;
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_KEYDOWN) return;

   if(id == CHARTEVENT_CHART_CHANGE)
     { g_dirty = true; ThrottledRender(); return; }

   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      int nx = (int)lparam, ny = (int)dparam;
      bool wasN = HitTest(g_mouseX,g_mouseY,g_pX1-10,g_pY1-10,g_pX2+10,g_pY2+10);
      bool nowN = HitTest(nx,ny,g_pX1-10,g_pY1-10,g_pX2+10,g_pY2+10);
      g_mouseX = nx; g_mouseY = ny;
      if(wasN || nowN) ThrottledRender();
      return;
     }

   if(id == CHARTEVENT_CLICK)
     {
      int mx = (int)lparam, my = (int)dparam;

      if(HitTest(mx,my,g_bCellX1,g_bCellY1,g_bCellX2,g_bCellY2))
        {
         int pts = (int)MathRound(g_step / _Point);
         pts = (pts<=1)?2:(pts<=2)?5:(pts<=5)?10:(pts<=10)?20:(pts<=20)?40:1;
         g_step = pts * _Point;
         g_needsReload = true; g_dirty = true;
        }
      else if(HitTest(mx,my,g_bOpaX1,g_bOpaY1,g_bOpaX2,g_bOpaY2))
        {
         g_opacity = (g_opacity>=255)?190:(g_opacity>=190)?127:(g_opacity>=127)?64:255;
         g_dirty = true;
        }
      else if(HitTest(mx,my,g_bTrdX1,g_bTrdY1,g_bTrdX2,g_bTrdY2))
        { g_showBubbles = !g_showBubbles; g_dirty = true; }
      else if(HitTest(mx,my,g_bShowX1,g_bShowY1,g_bShowX2,g_bShowY2))
        { g_visible = !g_visible; g_dirty = true; }
      else if(HitTest(mx,my,g_bRldX1,g_bRldY1,g_bRldX2,g_bRldY2))
        { g_needsReload = true; g_dirty = true; }
      else if(HitTest(mx,my,g_bClrX1,g_bClrY1,g_bClrX2,g_bClrY2))
        { ClearAll(); }

      if(g_dirty) ThrottledRender();
     }
  }
