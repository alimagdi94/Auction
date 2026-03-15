//+------------------------------------------------------------------+
//|                                              AuctionDelta.mq5    |
//|   Auction Delta Footprint — Sierra Chart / Jigsaw style          |
//|   Volume heatmap cells (green gradient), Bid x Ask per level     |
//|   Buy imbalance (blue fill), Sell imbalance (red right-edge bar) |
//|   POC frame, Value Area, Stacked imbalances, Unfinished auction  |
//|   Tick-size aggregation + multiplier, compact canvas overlay     |
//+------------------------------------------------------------------+
#property copyright "Ali Magdy"
#property version   "1.00"
#property description "Auction Delta Footprint — light heatmap, Bid x Ask, imbalance markers"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- Aggregation
input group "Data & Aggregation"
input int    InpTickSize        = 10;        // Base cell size (points)
input int    InpTickMultiplier  = 1;         // Tick multiplier (1–40)
input int    InpHistoryBars     = 80;        // History bars to load
input double InpVAPercent       = 70.0;      // Value Area %
input double InpImbalanceRatio  = 300.0;     // Imbalance threshold (%)
input int    InpStackedImbCount = 3;         // Stacked imbalance min count

//--- Display
input group "Display"
input bool   InpShowText        = true;      // Show Bid/Ask numbers in cells
input bool   InpShowVolBar      = true;      // Show per-bar volume/delta label
input bool   InpShowHeader      = true;      // Show info header
input uchar  InpCellAlpha       = 220;       // Cell alpha (0–255)

//--- Colors — Light Theme (Sierra Chart Auction style)
input group "Colors — Cell Backgrounds"
input color  InpClrCellLo       = C'248,255,212';  // Low-volume cell (cream)
input color  InpClrCellHi       = C'140,220,90';   // High-volume cell (deep green)
input color  InpClrOutVA        = C'235,235,220';  // Outside Value Area (pale grey-cream)
input color  InpClrImbBuy       = C'160,195,255';  // Buy imbalance fill (periwinkle blue)
input color  InpClrImbSell      = C'255,215,215';  // Sell imbalance fill (light pink)
input color  InpClrImbSellBar   = C'190,20,15';    // Sell imbalance right-edge bar (red)
input color  InpClrImbBuyBar    = C'20,100,210';   // Buy imbalance left-edge bar (blue)

input group "Colors — Markers & UI"
input color  InpClrPOC          = C'220,80,0';     // POC frame (orange)
input color  InpClrVAFrame      = C'60,140,60';    // Value Area frame (green)
input color  InpClrBullFrame    = C'40,160,60';    // Bullish bar frame
input color  InpClrBearFrame    = C'200,40,40';    // Bearish bar frame
input color  InpClrGrid         = C'160,160,140';  // Cell grid lines
input color  InpClrText         = C'20,20,20';     // Cell number text (near black)
input color  InpClrTextImb      = C'10,10,10';     // Text on imbalance cells
input color  InpClrVolLabel     = C'30,30,30';     // Per-bar volume label
input color  InpClrDeltaPos     = C'30,140,30';    // Positive delta label
input color  InpClrDeltaNeg     = C'180,30,30';    // Negative delta label
input color  InpClrHeader       = C'180,180,160';  // Header text
input color  InpClrUnfinished   = C'200,100,0';    // Unfinished auction marker
input color  InpClrAbsorption   = C'160,0,160';    // Absorption marker

//--- Sizes
input group "Sizes"
input int    InpImbBarW         = 3;         // Imbalance edge-bar width (px)
input int    InpMinCellH        = 14;        // Min cell height (px)

//--- Panel
input group "Panel"
input int    InpPanelX          = 10;        // Control panel X
input int    InpPanelY          = 30;        // Control panel Y

//--- Keymapping
input group "Keys"
input int    InpKeyTickUp       = 187;       // Cell size up  (=)
input int    InpKeyTickDn       = 189;       // Cell size down (-)
input int    InpKeyMultUp       = 221;       // Multiplier up  (])
input int    InpKeyMultDn       = 219;       // Multiplier down ([)
input int    InpKeyRefresh      = 82;        // Reload history (R)
input int    InpKeyVisible      = 72;        // Toggle visible (H)
input int    InpKeyText         = 84;        // Toggle text (T)

//=== Data Structures ===================================================

struct PriceLevel {
   double price;
   long   bid_vol;
   long   ask_vol;
   long   total_vol;
   long   delta;
   bool   is_imb_buy;
   bool   is_imb_sell;
   bool   is_stacked_buy;
   bool   is_stacked_sell;
   bool   is_unfinished_hi;
   bool   is_unfinished_lo;
   bool   is_absorption;
};

struct AuctionBar {
   datetime   bar_time;
   long       total_vol;
   long       total_delta;
   double     high;
   double     low;
   int        poc_idx;
   int        va_lo_idx;
   int        va_hi_idx;
   bool       is_bullish;
   bool       sorted;
   int        level_count;
   PriceLevel levels[];
};

//=== Globals ===========================================================

CCanvas      g_canvas;
string       g_name        = "AD_Canvas";
AuctionBar   g_bars[];
double       g_step;          // effective step = basePts * mult * _Point
double       g_baseStep;      // base step from InpTickSize * _Point
int          g_basePts;       // runtime base pts
int          g_tickMult;      // runtime multiplier
long         g_chart;
int          g_sub;
bool         g_hasTrades;
double       g_prevBid;
bool         g_dirty;
bool         g_visible       = true;
bool         g_showText;      // runtime text toggle (user can toggle via key/button)
bool         g_userHideText;  // user explicitly forced text off

double       g_imbRatio;      // runtime imbalance ratio
double       g_vaPercent;     // runtime VA%

long         g_lastTickMs    = 0;
ulong        g_lastRenderMs  = 0;
bool         g_needsReload   = false;
datetime     g_lastTesterTime= 0;

// Scratch pixel arrays
int  g_scrY1[];
int  g_scrY2[];
int  g_scrCap = 0;

// Panel geometry
#define PANEL_BTN_W    44
#define PANEL_BTN_GAP  3
#define PANEL_PAD      3
#define PANEL_H        22
#define PANEL_MARGIN   5
#define RENDER_THROTTLE_MS 33
#define MIN_CELL_H     14

// Opacity presets
#define OPA_FULL  255
#define OPA_75    190
#define OPA_50    127
#define OPA_25     64

// Imbalance cycle presets
#define IMB_LO  200.0
#define IMB_MID 300.0
#define IMB_HI  400.0

int  g_panX1, g_panY1, g_panX2, g_panY2;
int  g_btnSzX1,  g_btnSzY1,  g_btnSzX2,  g_btnSzY2;
int  g_btnMxX1,  g_btnMxY1,  g_btnMxX2,  g_btnMxY2;
int  g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2;
int  g_btnVAX1,  g_btnVAY1,  g_btnVAX2,  g_btnVAY2;
int  g_btnTxtX1, g_btnTxtY1, g_btnTxtX2, g_btnTxtY2;
int  g_btnRldX1, g_btnRldY1, g_btnRldX2, g_btnRldY2;
int  g_btnVisX1, g_btnVisY1, g_btnVisX2, g_btnVisY2;
int  g_btnZiX1,  g_btnZiY1,  g_btnZiX2,  g_btnZiY2;
int  g_btnZoX1,  g_btnZoY1,  g_btnZoX2,  g_btnZoY2;
int  g_mouseX = -1, g_mouseY = -1;

//=== Helpers ===========================================================

bool HitTest(int mx,int my,int x1,int y1,int x2,int y2) {
   return(mx>=x1 && mx<=x2 && my>=y1 && my<=y2);
}

uint FpARGB(color c, int a) {
   return ColorToARGB(c,(uchar)MathMin(MathMax(a,0),255));
}

color LerpColor(color a, color b, double t) {
   if(t < 0.0) t = 0.0;
   if(t > 1.0) t = 1.0;
   // MQL5 color = 0x00BBGGRR  (R in lowest byte)
   int ar = (int)( a        & 0xFF);
   int ag = (int)((a >>  8) & 0xFF);
   int ab = (int)((a >> 16) & 0xFF);
   int br = (int)( b        & 0xFF);
   int bg = (int)((b >>  8) & 0xFF);
   int bb = (int)((b >> 16) & 0xFF);
   int r  = (int)((1.0-t)*ar + t*br);
   int g  = (int)((1.0-t)*ag + t*bg);
   int bl = (int)((1.0-t)*ab + t*bb);
   return (color)(r | (g << 8) | (bl << 16));
}

// Luminance-based contrast pick — MQL5 color is BGR (R=byte0, G=byte1, B=byte2)
color ContrastText(color bg) {
   int r = (int)( bg        & 0xFF);
   int g = (int)((bg >>  8) & 0xFF);
   int b = (int)((bg >> 16) & 0xFF);
   double luma = 0.299*r + 0.587*g + 0.114*b;
   return (luma > 160) ? (color)C'20,20,20' : (color)C'240,240,240';
}

void EnsureScratch(int n) {
   if(g_scrCap < n) {
      ArrayResize(g_scrY1, n, 128);
      ArrayResize(g_scrY2, n, 128);
      g_scrCap = n;
   }
}

double NormP(double p) {
   return MathFloor(p / g_step) * g_step;
}

double GetVA()  { return g_vaPercent; }
double GetImb() { return g_imbRatio;  }

//=== Bar Management ====================================================

int FindBarIndex(datetime bt) {
   int lo=0, hi=ArraySize(g_bars)-1;
   while(lo<=hi) {
      int mid=(lo+hi)/2;
      if(g_bars[mid].bar_time==bt) return mid;
      if(g_bars[mid].bar_time < bt) lo=mid+1;
      else hi=mid-1;
   }
   return -1;
}

void InitBarSlot(int pos, datetime bt) {
   g_bars[pos].bar_time    = bt;
   g_bars[pos].total_vol   = 0;
   g_bars[pos].total_delta = 0;
   g_bars[pos].high        = 0.0;
   g_bars[pos].low         = 0.0;
   g_bars[pos].poc_idx     = -1;
   g_bars[pos].va_lo_idx   = -1;
   g_bars[pos].va_hi_idx   = -1;
   g_bars[pos].is_bullish  = true;
   g_bars[pos].sorted      = true;
   g_bars[pos].level_count = 0;
   ArrayResize(g_bars[pos].levels, 64, 64);
}

int InsertBar(datetime bt) {
   int n = ArraySize(g_bars);

   // Fast-path: chronological append
   if(n > 0 && bt > g_bars[n-1].bar_time) {
      ArrayResize(g_bars, n+1, 128);
      InitBarSlot(n, bt);
      return n;
   }

   // Find insertion point
   int pos = n;
   for(int i=n-1; i>=0; i--) {
      if(g_bars[i].bar_time == bt) return i;
      if(g_bars[i].bar_time < bt) { pos = i+1; break; }
      pos = i;
   }

   // Append blank then shift (safe deep-copy — no MQL5 struct-with-dynarray assignment)
   ArrayResize(g_bars, n+1, 128);
   ArrayResize(g_bars[n].levels, 0);

   for(int i=n; i>pos; i--) {
      g_bars[i].bar_time    = g_bars[i-1].bar_time;
      g_bars[i].total_vol   = g_bars[i-1].total_vol;
      g_bars[i].total_delta = g_bars[i-1].total_delta;
      g_bars[i].high        = g_bars[i-1].high;
      g_bars[i].low         = g_bars[i-1].low;
      g_bars[i].poc_idx     = g_bars[i-1].poc_idx;
      g_bars[i].va_lo_idx   = g_bars[i-1].va_lo_idx;
      g_bars[i].va_hi_idx   = g_bars[i-1].va_hi_idx;
      g_bars[i].is_bullish  = g_bars[i-1].is_bullish;
      g_bars[i].sorted      = g_bars[i-1].sorted;
      g_bars[i].level_count = g_bars[i-1].level_count;
      int lc = g_bars[i-1].level_count;
      ArrayResize(g_bars[i].levels, lc, 64);
      for(int k=0; k<lc; k++) g_bars[i].levels[k] = g_bars[i-1].levels[k];
   }

   InitBarSlot(pos, bt);
   return pos;
}

int GetBar(datetime bt) {
   int idx = FindBarIndex(bt);
   return (idx >= 0) ? idx : InsertBar(bt);
}

//=== Tick Classification ===============================================

void Classify(const MqlTick &t, bool &isBuy, bool &isSell) {
   isBuy  = false;
   isSell = false;
   if(g_hasTrades) {
      isBuy  = (t.flags & TICK_FLAG_BUY)  == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
      if(!isBuy && !isSell) {
         if(t.last >= t.ask)      isBuy  = true;
         else if(t.last <= t.bid) isSell = true;
      }
   } else {
      if(t.bid > g_prevBid)      isBuy  = true;
      else if(t.bid < g_prevBid) isSell = true;
      else                        isBuy  = true;
   }
}

//=== Tick Accumulation =================================================

void AccumulateTick(int bi, double price, long vol, bool isBuy, bool isSell) {
   if(price == 0.0) return;
   price = NormP(price);

   int used = g_bars[bi].level_count;
   int idx  = -1;

   bool skipSearch = (price > g_bars[bi].high + g_step || price < g_bars[bi].low - g_step);
   if(!skipSearch) {
      for(int i=used-1; i>=0; i--) {
         if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.4) {
            idx = i;
            break;
         }
      }
   }

   if(idx == -1) {
      if(used >= ArraySize(g_bars[bi].levels))
         ArrayResize(g_bars[bi].levels, used+64, 64);
      idx = used;
      g_bars[bi].levels[idx].price          = price;
      g_bars[bi].levels[idx].bid_vol        = 0;
      g_bars[bi].levels[idx].ask_vol        = 0;
      g_bars[bi].levels[idx].total_vol      = 0;
      g_bars[bi].levels[idx].delta          = 0;
      g_bars[bi].levels[idx].is_imb_buy     = false;
      g_bars[bi].levels[idx].is_imb_sell    = false;
      g_bars[bi].levels[idx].is_stacked_buy = false;
      g_bars[bi].levels[idx].is_stacked_sell= false;
      g_bars[bi].levels[idx].is_unfinished_hi= false;
      g_bars[bi].levels[idx].is_unfinished_lo= false;
      g_bars[bi].levels[idx].is_absorption  = false;
      g_bars[bi].level_count++;
   }

   if(isBuy)  g_bars[bi].levels[idx].ask_vol += vol;
   if(isSell) g_bars[bi].levels[idx].bid_vol += vol;
   g_bars[bi].levels[idx].total_vol += vol;
   g_bars[bi].levels[idx].delta = g_bars[bi].levels[idx].ask_vol - g_bars[bi].levels[idx].bid_vol;

   g_bars[bi].total_vol   += vol;
   g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));
   g_bars[bi].sorted = false;
   g_dirty = true;
}

//=== Sorting ===========================================================

void SortPartition(PriceLevel &lv[], int lo, int hi) {
   if(lo >= hi) return;
   double pivot = lv[hi].price;
   int i = lo-1;
   for(int j=lo; j<hi; j++) {
      if(lv[j].price >= pivot) {
         i++;
         PriceLevel tmp = lv[i]; lv[i] = lv[j]; lv[j] = tmp;
      }
   }
   i++;
   PriceLevel tmp = lv[i]; lv[i] = lv[hi]; lv[hi] = tmp;
   SortPartition(lv, lo, i-1);
   SortPartition(lv, i+1, hi);
}

void SortLevels(PriceLevel &lv[], int n) {
   if(n > 1) SortPartition(lv, 0, n-1);
}

//=== POC / VA ==========================================================

int FindPOC(const PriceLevel &lv[], int n) {
   int best=-1; long mx=0;
   for(int i=0; i<n; i++)
      if(lv[i].total_vol > mx) { mx=lv[i].total_vol; best=i; }
   return best;
}

void FindVA(const PriceLevel &lv[], int n, long totVol, int poc, int &lo, int &hi) {
   lo = poc; hi = poc;
   if(poc < 0) return;
   long target = (long)(totVol * GetVA() / 100.0);
   long cur    = lv[poc].total_vol;
   while(cur < target && (lo > 0 || hi < n-1)) {
      long up = 0;
      if(hi+1 < n) up += lv[hi+1].total_vol;
      if(hi+2 < n) up += lv[hi+2].total_vol;
      bool canUp = (hi < n-1);
      long dn = 0;
      if(lo-1 >= 0) dn += lv[lo-1].total_vol;
      if(lo-2 >= 0) dn += lv[lo-2].total_vol;
      bool canDn = (lo > 0);
      if(canUp && (!canDn || up >= dn)) { hi++; cur += lv[hi].total_vol; }
      else if(canDn)                    { lo--; cur += lv[lo].total_vol; }
      else break;
   }
}

//=== Signal Computation ================================================

void ComputeSignals(int bi) {
   int len = g_bars[bi].level_count;
   if(len <= 0) return;

   if(!g_bars[bi].sorted) {
      SortLevels(g_bars[bi].levels, len);
      g_bars[bi].sorted = true;
   }

   g_bars[bi].poc_idx = FindPOC(g_bars[bi].levels, len);
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, g_bars[bi].poc_idx,
          g_bars[bi].va_lo_idx, g_bars[bi].va_hi_idx);

   long avgVol = (len > 0) ? (g_bars[bi].total_vol / len) : 1;

   for(int i=0; i<len; i++) {
      g_bars[bi].levels[i].is_imb_buy      = false;
      g_bars[bi].levels[i].is_imb_sell     = false;
      g_bars[bi].levels[i].is_stacked_buy  = false;
      g_bars[bi].levels[i].is_stacked_sell = false;
      g_bars[bi].levels[i].is_unfinished_hi= false;
      g_bars[bi].levels[i].is_unfinished_lo= false;
      g_bars[bi].levels[i].is_absorption   = (g_bars[bi].levels[i].total_vol > avgVol * 4.0);

      // Diagonal imbalance — levels are sorted descending, so index i+1 is the level below
      if(i < len-1) {
         long nextBid = g_bars[bi].levels[i+1].bid_vol;
         if(nextBid > 0 && ((double)g_bars[bi].levels[i].ask_vol / nextBid)*100.0 >= GetImb())
            g_bars[bi].levels[i].is_imb_buy = true;
      }
      if(i > 0) {
         long prevAsk = g_bars[bi].levels[i-1].ask_vol;
         if(prevAsk > 0 && ((double)g_bars[bi].levels[i].bid_vol / prevAsk)*100.0 >= GetImb())
            g_bars[bi].levels[i].is_imb_sell = true;
      }
   }

   // Stacked imbalances
   int cntBuy=0, cntSell=0;
   for(int i=0; i<len; i++) {
      if(g_bars[bi].levels[i].is_imb_buy) { cntBuy++; }
      else {
         if(cntBuy >= InpStackedImbCount)
            for(int j=i-cntBuy; j<i; j++) g_bars[bi].levels[j].is_stacked_buy=true;
         cntBuy=0;
      }
      if(g_bars[bi].levels[i].is_imb_sell) { cntSell++; }
      else {
         if(cntSell >= InpStackedImbCount)
            for(int j=i-cntSell; j<i; j++) g_bars[bi].levels[j].is_stacked_sell=true;
         cntSell=0;
      }
   }
   if(cntBuy  >= InpStackedImbCount) for(int j=len-cntBuy;  j<len; j++) g_bars[bi].levels[j].is_stacked_buy =true;
   if(cntSell >= InpStackedImbCount) for(int j=len-cntSell; j<len; j++) g_bars[bi].levels[j].is_stacked_sell=true;

   // Unfinished auction (single-sided extreme)
   if(len > 1) {
      g_bars[bi].levels[0].is_unfinished_hi =
         (g_bars[bi].levels[0].bid_vol == 0 || g_bars[bi].levels[0].ask_vol == 0);
      g_bars[bi].levels[len-1].is_unfinished_lo =
         (g_bars[bi].levels[len-1].bid_vol == 0 || g_bars[bi].levels[len-1].ask_vol == 0);
   }
}

//=== Tick Processing ===================================================

void ProcessTicks(MqlTick &ticks[], int startIdx, int count,
                  bool skipSeen, bool updateLastMs, bool resetCache=false) {
   static datetime cur_bt   = 0;
   static int      cur_sh   = -1;
   static datetime next_bt  = 0;

   if(resetCache) { cur_bt=0; cur_sh=-1; next_bt=0; }
   if(count <= 0) return;

   int endIdx = startIdx + count;
   if(endIdx > ArraySize(ticks)) endIdx = ArraySize(ticks);

   for(int i=startIdx; i<endIdx; i++) {
      if(skipSeen && ticks[i].time_msc <= g_lastTickMs) continue;

      double price; long vol;
      if(g_hasTrades) {
         price = ticks[i].last;
         vol   = (long)ticks[i].volume;
         if(vol <= 0 || price == 0.0) continue;
      } else {
         price = ticks[i].bid;
         vol   = 1;
         if(price == 0.0) continue;
      }

      bool isBuy, isSell;
      Classify(ticks[i], isBuy, isSell);
      if(ticks[i].bid != 0.0) g_prevBid = ticks[i].bid;

      if(ticks[i].time < cur_bt || ticks[i].time >= next_bt) {
         cur_sh = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
         if(cur_sh < 0) continue;
         cur_bt   = iTime(_Symbol, PERIOD_CURRENT, cur_sh);
         next_bt  = cur_bt + PeriodSeconds(PERIOD_CURRENT);
      }

      int bi = GetBar(cur_bt);
      g_bars[bi].is_bullish = (iClose(_Symbol,PERIOD_CURRENT,cur_sh) >= iOpen(_Symbol,PERIOD_CURRENT,cur_sh));
      g_bars[bi].high       = iHigh(_Symbol,PERIOD_CURRENT,cur_sh);
      g_bars[bi].low        = iLow(_Symbol,PERIOD_CURRENT,cur_sh);

      AccumulateTick(bi, price, vol, isBuy, isSell);

      if(updateLastMs) g_lastTickMs = ticks[i].time_msc;
   }
}

int LoadHistory(datetime t0, datetime t1) {
   MqlTick ticks[];
   uint flag = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   int copied = CopyTicksRange(_Symbol, ticks, flag, (long)t0*1000, (long)t1*1000);
   if(copied <= 0) return -1;
   g_prevBid = ticks[0].bid;
   ProcessTicks(ticks, 0, copied, false, true, true);
   g_dirty = true;
   return copied;
}

void ReloadHistory() {
   g_dirty = false;
   int n = ArraySize(g_bars);
   for(int i=0; i<n; i++) ArrayFree(g_bars[i].levels);
   ArrayFree(g_bars);
   g_lastTickMs = 0;

   int barsTot = iBars(_Symbol, PERIOD_CURRENT);
   if(barsTot <= 0) return;
   int maxShift  = MathMin(InpHistoryBars, barsTot-1);
   datetime t0   = iTime(_Symbol, PERIOD_CURRENT, maxShift);
   datetime t1   = TimeCurrent();
   int loaded    = LoadHistory(t0, t1);
   if(loaded > 0) g_dirty = true;
   else {
      static bool s_alerted = false;
      if(!s_alerted) {
         Alert("AuctionDelta: No tick data for ", _Symbol, ". Click Rld when available.");
         s_alerted = true;
      }
   }
}

//=== Bar Renderer ======================================================

void DrawBar(int bi, int shift, int barW) {
   int len = g_bars[bi].level_count;
   if(len == 0) return;
   if(!g_bars[bi].sorted) ComputeSignals(bi);

   int pocIdx  = g_bars[bi].poc_idx;
   int vaLoIdx = g_bars[bi].va_lo_idx;
   int vaHiIdx = g_bars[bi].va_hi_idx;

   // Max volumes for heatmap normalisation
   long maxVol = 1;
   for(int i=0; i<len; i++)
      if(g_bars[bi].levels[i].total_vol > maxVol) maxVol = g_bars[bi].levels[i].total_vol;

   datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);

   // ── X geometry ────────────────────────────────────────────────────
   // ChartTimePriceToXY returns the CENTER x of the bar slot.
   // Leave a 1px gutter on each side so adjacent bars don't touch.
   int xc, ydummy;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, xc, ydummy);
   int gutterPx = MathMax(1, barW / 12);   // ~8% gutter each side
   int halfW    = barW / 2 - gutterPx;
   if(halfW < 4) halfW = 4;                // absolute minimum — still render at any zoom
   int x1   = xc - halfW;
   int x2   = xc + halfW;
   int midX = (x1 + x2) / 2;              // divides Bid (left) | Ask (right)

   // ── Y geometry — compute natural cell height from chart scale ─────
   // Use the price-to-pixel mapping for one step to get true cellH.
   int tmpX, natY1, natY2;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price,          tmpX, natY1);
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price - g_step, tmpX, natY2);
   int cellH = MathAbs(natY2 - natY1);
   if(cellH < InpMinCellH) cellH = InpMinCellH;

   // Build pixel Y rows: anchor off the HIGHEST price level (levels[0] is highest
   // because SortLevels sorts descending), get its chart Y, then stack downward.
   // This keeps rows tightly anchored to actual chart price positions.
   int ancY0;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, tmpX, ancY0);
   EnsureScratch(len);
   // rows increase downward — level 0 (highest price) is topmost on screen
   g_scrY1[0] = ancY0 - cellH / 2;
   g_scrY2[0] = g_scrY1[0] + cellH;
   for(int i=1; i<len; i++) {
      g_scrY1[i] = g_scrY2[i-1];
      g_scrY2[i] = g_scrY1[i] + cellH;
   }

   // ── Font sizing — based on actual cell and half-bar dimensions ────
   int fontPx   = MathMin(cellH - 2, halfW / 3);   // fit inside half-cell width
   int fontSize = MathMax(6, MathMin(fontPx, 24));
   bool drawText = g_showText && (cellH >= 10) && (halfW >= 12);
   if(drawText) g_canvas.FontSet("Consolas", fontSize, 0);

   // ── Chart viewport clip bounds ────────────────────────────────────
   int chH = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);

   // ── Draw each cell ────────────────────────────────────────────────
   for(int i=0; i<len; i++) {
      PriceLevel pl = g_bars[bi].levels[i];

      // Skip levels outside bar high/low (only if bar bounds are known)
      if(g_bars[bi].high > 0 && g_bars[bi].low > 0) {
         if(pl.price < g_bars[bi].low  - g_step * 0.5) continue;
         if(pl.price > g_bars[bi].high + g_step * 0.5) continue;
      }

      int yt = g_scrY1[i];
      int yb = g_scrY2[i];

      // Skip cells fully outside viewport
      if(yb < 0 || yt > chH) continue;

      // Clamp to viewport
      int ytc = MathMax(yt, 0);
      int ybc = MathMin(yb, chH - 1);
      if(ytc >= ybc) continue;

      // Sorted descending: va_lo_idx = smaller index (higher price), va_hi_idx = larger index (lower price)
      bool inVA = (vaLoIdx >= 0 && vaHiIdx >= 0 && i >= vaLoIdx && i <= vaHiIdx);

      // Volume heatmap intensity (0=low, 1=max)
      double intensity = (maxVol > 0) ? (double)pl.total_vol / (double)maxVol : 0.0;

      // ── Cell background ───────────────────────────────────────────
      color cellBg;
      if(!inVA) {
         cellBg = InpClrOutVA;
      } else if(pl.is_imb_buy) {
         cellBg = InpClrImbBuy;
      } else if(pl.is_imb_sell) {
         cellBg = InpClrImbSell;
      } else {
         cellBg = LerpColor(InpClrCellLo, InpClrCellHi, intensity);
      }

      g_canvas.FillRectangle(x1,    ytc, midX, ybc, FpARGB(cellBg, InpCellAlpha));
      g_canvas.FillRectangle(midX+1,ytc, x2,   ybc, FpARGB(cellBg, InpCellAlpha));

      // ── Sell imbalance: thick red bar on RIGHT edge ───────────────
      if(pl.is_imb_sell) {
         g_canvas.FillRectangle(x2 - InpImbBarW, ytc, x2, ybc, FpARGB(InpClrImbSellBar, 220));
      }
      // Buy imbalance: thin blue bar on LEFT edge
      if(pl.is_imb_buy) {
         g_canvas.FillRectangle(x1, ytc, x1 + InpImbBarW, ybc, FpARGB(InpClrImbBuyBar, 200));
      }

      // ── Grid lines ────────────────────────────────────────────────
      g_canvas.LineHorizontal(x1, x2,   ybc, FpARGB(InpClrGrid, 100));
      g_canvas.LineVertical(midX, ytc, ybc,  FpARGB(InpClrGrid,  80));

      // ── POC frame ────────────────────────────────────────────────
      if(i == pocIdx) {
         g_canvas.Rectangle(x1,   ytc,   x2,   ybc,   FpARGB(InpClrPOC, 255));
         g_canvas.Rectangle(x1+1, ytc+1, x2-1, ybc-1, FpARGB(InpClrPOC, 130));
      }

      // ── Stacked imbalance border ───────────────────────────────
      if(pl.is_stacked_buy) {
         g_canvas.Rectangle(x1,   ytc,   midX,   ybc, FpARGB(InpClrImbBuyBar,  180));
         g_canvas.Rectangle(x1+1, ytc+1, midX-1, ybc-1, FpARGB(InpClrImbBuyBar, 80));
      }
      if(pl.is_stacked_sell) {
         g_canvas.Rectangle(midX+1, ytc,   x2,   ybc, FpARGB(InpClrImbSellBar,  180));
         g_canvas.Rectangle(midX+2, ytc+1, x2-1, ybc-1, FpARGB(InpClrImbSellBar, 80));
      }

      // ── Unfinished auction dashes ─────────────────────────────
      if(pl.is_unfinished_hi) {
         for(int px=x1; px<=x2; px+=4)
            g_canvas.LineVertical(px, ytc, MathMin(ytc+2, ybc), FpARGB(InpClrUnfinished, 200));
      }
      if(pl.is_unfinished_lo) {
         for(int px=x1; px<=x2; px+=4)
            g_canvas.LineVertical(px, MathMax(ybc-2, ytc), ybc, FpARGB(InpClrUnfinished, 200));
      }

      // ── Absorption border ─────────────────────────────────────
      if(pl.is_absorption) {
         g_canvas.Rectangle(x1-1, ytc-1, x2+1, ybc+1, FpARGB(InpClrAbsorption, 200));
      }

      // ── Numbers: Bid left | Ask right ────────────────────────
      if(drawText) {
         int yy = (ytc + ybc) / 2;
         // Always use high-contrast near-black text on light cells
         uint cLeft  = FpARGB(InpClrText, 200);
         uint cRight = FpARGB(InpClrText, 200);
         if(!inVA) { cLeft = cRight = FpARGB(C'150,150,140', 180); }

         if(pl.bid_vol > 0)
            g_canvas.TextOut((x1+midX)/2, yy, IntegerToString(pl.bid_vol),
                             cLeft, TA_CENTER|TA_VCENTER);
         if(pl.ask_vol > 0)
            g_canvas.TextOut((midX+1+x2)/2, yy, IntegerToString(pl.ask_vol),
                             cRight, TA_CENTER|TA_VCENTER);
      }
   } // end level loop

   // ── Value Area frame ─────────────────────────────────────────────
   if(vaLoIdx >= 0 && vaHiIdx >= 0) {
      int vaYt = g_scrY1[vaLoIdx];   // va_lo_idx = smaller index = higher price = top on screen
      int vaYb = g_scrY2[vaHiIdx];   // va_hi_idx = larger  index = lower  price = bottom on screen
      vaYt = MathMax(vaYt, 0);
      vaYb = MathMin(vaYb, chH - 1);
      if(vaYt < vaYb) {
         color frameClr = g_bars[bi].is_bullish ? InpClrBullFrame : InpClrBearFrame;
         g_canvas.Rectangle(x1,   vaYt,   x2,   vaYb,   FpARGB(frameClr, 240));
         g_canvas.Rectangle(x1-1, vaYt-1, x2+1, vaYb+1, FpARGB(frameClr, 60));
      }
   }

   // ── Per-bar volume + delta labels below bar ───────────────────────
   if(InpShowVolBar && barW >= 20) {
      int lastIdx = len - 1;
      // find last rendered level
      while(lastIdx > 0 && g_bars[bi].high > 0 &&
            g_bars[bi].levels[lastIdx].price < g_bars[bi].low - g_step * 0.5)
         lastIdx--;
      int lblY = MathMin(g_scrY2[lastIdx] + 2, chH - 20);
      if(lblY < chH - 8) {
         int lFontSz = MathMax(7, MathMin(cellH - 2, 11));
         g_canvas.FontSet("Consolas", lFontSz, 0);

         long  delta = g_bars[bi].total_delta;
         color dClr  = (delta >= 0) ? InpClrDeltaPos : InpClrDeltaNeg;
         string volStr = IntegerToString(g_bars[bi].total_vol);
         string dStr   = (delta >= 0 ? "+" : "") + IntegerToString(delta);
         int vx = (x1 + x2) / 2;

         int tw=0, th=0;
         g_canvas.TextSize(volStr, tw, th);
         g_canvas.FillRectangle(vx-(int)(tw/2)-1, lblY,   vx+(int)(tw/2)+1, lblY+(int)th,   FpARGB(C'225,225,210', 200));
         g_canvas.TextOut(vx, lblY, volStr, FpARGB(InpClrVolLabel, 230), TA_CENTER|TA_TOP);

         int dLblY = lblY + (int)th + 1;
         g_canvas.TextSize(dStr, tw, th);
         g_canvas.FillRectangle(vx-(int)(tw/2)-1, dLblY, vx+(int)(tw/2)+1, dLblY+(int)th, FpARGB(C'225,225,210', 200));
         g_canvas.TextOut(vx, dLblY, dStr, FpARGB(dClr, 240), TA_CENTER|TA_TOP);
      }
   }
}

//=== Control Panel =====================================================

void LayoutPanel(int cw, int ch) {
   int btnW  = PANEL_BTN_W;
   int gap   = PANEL_BTN_GAP;
   int pad   = PANEL_PAD;
   // 9 buttons total
   int panW  = pad + (btnW*9 + gap*8) + pad;

   g_panX2 = cw - PANEL_MARGIN;
   g_panX1 = g_panX2 - panW;
   g_panY1 = InpPanelY;
   g_panY2 = g_panY1 + PANEL_H;

   int x = g_panX1 + pad;
   int y1 = g_panY1 + pad;
   int y2 = g_panY2 - pad;

   #define NEXT_BTN(nx1,ny1,nx2,ny2) nx1=x; ny1=y1; nx2=x+btnW; ny2=y2; x+=btnW+gap;

   NEXT_BTN(g_btnZoX1,  g_btnZoY1,  g_btnZoX2,  g_btnZoY2)
   NEXT_BTN(g_btnZiX1,  g_btnZiY1,  g_btnZiX2,  g_btnZiY2)
   NEXT_BTN(g_btnSzX1,  g_btnSzY1,  g_btnSzX2,  g_btnSzY2)
   NEXT_BTN(g_btnMxX1,  g_btnMxY1,  g_btnMxX2,  g_btnMxY2)
   NEXT_BTN(g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2)
   NEXT_BTN(g_btnVAX1,  g_btnVAY1,  g_btnVAX2,  g_btnVAY2)
   NEXT_BTN(g_btnTxtX1, g_btnTxtY1, g_btnTxtX2, g_btnTxtY2)
   NEXT_BTN(g_btnVisX1, g_btnVisY1, g_btnVisX2, g_btnVisY2)
   NEXT_BTN(g_btnRldX1, g_btnRldY1, g_btnRldX2, g_btnRldY2)
   #undef NEXT_BTN
}

void DrawPanel() {
   int bCY = g_panY1 + (PANEL_H / 2);
   int bCX = PANEL_BTN_W / 2;

   g_canvas.FillRectangle(g_panX1, g_panY1, g_panX2, g_panY2, FpARGB(C'25,28,32', 210));
   g_canvas.Rectangle(    g_panX1, g_panY1, g_panX2, g_panY2, FpARGB(C'70,75,80', 200));

   uint baseFill  = FpARGB(C'38,42,48', 230);
   uint hovFill   = FpARGB(C'60,65,72', 250);
   uint baseBdr   = FpARGB(C'80,85,90', 190);
   uint hovBdr    = FpARGB(C'140,150,160',255);

   g_canvas.FontSet("Consolas", 8, 0);

   // btn data assembled inline — no local struct needed
   int   bx1[9], by1[9], bx2[9], by2[9];
   string blbl[9];
   bx1[0]=g_btnZoX1;  by1[0]=g_btnZoY1;  bx2[0]=g_btnZoX2;  by2[0]=g_btnZoY2;  blbl[0]="–";
   bx1[1]=g_btnZiX1;  by1[1]=g_btnZiY1;  bx2[1]=g_btnZiX2;  by2[1]=g_btnZiY2;  blbl[1]="+";
   bx1[2]=g_btnSzX1;  by1[2]=g_btnSzY1;  bx2[2]=g_btnSzX2;  by2[2]=g_btnSzY2;  blbl[2]=IntegerToString(g_basePts)+"p";
   bx1[3]=g_btnMxX1;  by1[3]=g_btnMxY1;  bx2[3]=g_btnMxX2;  by2[3]=g_btnMxY2;  blbl[3]="x"+IntegerToString(g_tickMult);
   bx1[4]=g_btnImbX1; by1[4]=g_btnImbY1; bx2[4]=g_btnImbX2; by2[4]=g_btnImbY2; blbl[4]="Imb";
   bx1[5]=g_btnVAX1;  by1[5]=g_btnVAY1;  bx2[5]=g_btnVAX2;  by2[5]=g_btnVAY2;  blbl[5]=IntegerToString((int)g_vaPercent)+"%";
   bx1[6]=g_btnTxtX1; by1[6]=g_btnTxtY1; bx2[6]=g_btnTxtX2; by2[6]=g_btnTxtY2; blbl[6]=(!g_userHideText) ? "Txt+" : "Txt";
   bx1[7]=g_btnVisX1; by1[7]=g_btnVisY1; bx2[7]=g_btnVisX2; by2[7]=g_btnVisY2; blbl[7]=g_visible ? "ON" : "OFF";
   bx1[8]=g_btnRldX1; by1[8]=g_btnRldY1; bx2[8]=g_btnRldX2; by2[8]=g_btnRldY2; blbl[8]="Rld";

   for(int b=0; b<9; b++) {
      bool hov = HitTest(g_mouseX, g_mouseY, bx1[b], by1[b], bx2[b], by2[b]);
      uint fill = hov ? hovFill : baseFill;
      uint bdr  = hov ? hovBdr  : baseBdr;
      if(b==6 && !g_userHideText) fill = FpARGB(C'20,70,40', 230);
      if(b==7 &&  g_visible)      fill = FpARGB(C'20,70,40', 230);
      if(b==7 && !g_visible)      fill = FpARGB(C'70,20,20', 230);

      g_canvas.FillRectangle(bx1[b], by1[b], bx2[b], by2[b], fill);
      g_canvas.Rectangle(    bx1[b], by1[b], bx2[b], by2[b], bdr);
      g_canvas.TextOut(bx1[b] + bCX, bCY, blbl[b], FpARGB(clrWhite, 210), TA_CENTER|TA_VCENTER);
   }
}

//=== Master Render =====================================================

void Render() {
   int cw = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(cw <= 0 || ch <= 0) return;

   if(g_canvas.Width() != cw || g_canvas.Height() != ch) g_canvas.Resize(cw, ch);
   g_canvas.Erase(0x00000000);

   int visBars = (int)ChartGetInteger(g_chart, CHART_VISIBLE_BARS);
   if(visBars < 1) visBars = 1;
   int barW    = cw / visBars;
   int firstVis= (int)ChartGetInteger(g_chart, CHART_FIRST_VISIBLE_BAR);

   if(ArraySize(g_bars) == 0) { g_canvas.Update(); return; }

   // Header info bar
   if(InpShowHeader) {
      long totVol=0, cumDelta=0, minD=0, maxD=0;
      bool haveD=false;
      int nB=ArraySize(g_bars);
      for(int i=0; i<nB; i++) {
         totVol   += g_bars[i].total_vol;
         cumDelta += g_bars[i].total_delta;
         if(!haveD) { minD=maxD=g_bars[i].total_delta; haveD=true; }
         else {
            if(g_bars[i].total_delta < minD) minD=g_bars[i].total_delta;
            if(g_bars[i].total_delta > maxD) maxD=g_bars[i].total_delta;
         }
      }
      long lastD = haveD ? g_bars[nB-1].total_delta : 0;
      string hdr = StringFormat(
         "AuctionDelta  |  Cell: %dpts x%d  |  Imb: %.0f%%  |  VA: %.0f%%  |  Vol∑: %I64d  |  Δ(last): %+I64d  |  CumΔ: %+I64d",
         g_basePts, g_tickMult, g_imbRatio, g_vaPercent, totVol, lastD, cumDelta);
      g_canvas.FontSet("Consolas", 8, 0);
      g_canvas.TextOut(6, 5, hdr, FpARGB(InpClrHeader, 180), TA_LEFT|TA_TOP);
   }

   LayoutPanel(cw, ch);
   DrawPanel();

   if(g_visible) {
      // showText flag: user toggle only — actual auto-hide is handled per-bar in DrawBar
      g_showText = !g_userHideText && InpShowText;

      for(int v=0; v<visBars; v++) {
         int shift = firstVis - v;
         if(shift < 0) continue;
         datetime bt  = iTime(_Symbol, PERIOD_CURRENT, shift);
         int      idx = FindBarIndex(bt);
         if(idx >= 0) DrawBar(idx, shift, barW);
      }
   }

   g_canvas.Update();
   g_dirty = false;
}

void ThrottledRender() {
   if(MQLInfoInteger(MQL_TESTER)) {
      datetime now = TimeCurrent();
      if(now - g_lastTesterTime >= 60) { Render(); g_lastTesterTime = now; }
      return;
   }
   ulong now = GetTickCount();
   if(now - g_lastRenderMs >= RENDER_THROTTLE_MS) { Render(); g_lastRenderMs = now; }
}

//=== Lifecycle =========================================================

int OnInit() {
   g_basePts  = MathMax(1, MathMin(10000, InpTickSize));
   g_baseStep = g_basePts * _Point;
   g_tickMult = MathMax(1, MathMin(40, InpTickMultiplier));
   g_step     = g_baseStep * g_tickMult;
   g_imbRatio = InpImbalanceRatio;
   g_vaPercent= InpVAPercent;
   g_showText = InpShowText;
   g_userHideText = !InpShowText;
   g_visible  = true;

   g_chart    = ChartID();
   g_sub      = 0;
   g_prevBid  = 0.0;
   g_dirty    = true;
   g_hasTrades= (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);

   ChartSetInteger(g_chart, CHART_EVENT_MOUSE_MOVE, true);

   int w = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(w < 1) w = 800;
   if(h < 1) h = 600;

   if(!g_canvas.CreateBitmapLabel(g_name, 0, 0, w, h, COLOR_FORMAT_ARGB_NORMALIZE)) {
      Alert("AuctionDelta: Canvas creation failed.");
      return INIT_FAILED;
   }
   ObjectSetInteger(g_chart, g_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(g_chart, g_name, OBJPROP_BACK, false);
   g_canvas.Erase(0x00000000);
   g_canvas.Update();

   ReloadHistory();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   g_canvas.Destroy();
   ObjectDelete(g_chart, g_name);
   int n = ArraySize(g_bars);
   for(int i=0; i<n; i++) ArrayFree(g_bars[i].levels);
   ArrayFree(g_bars);
   ArrayFree(g_scrY1);
   ArrayFree(g_scrY2);
   g_scrCap = 0;
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[],  const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[],  const int &spread[]) {
   if(rates_total == 0) return 0;

   if(prev_calculated == 0 || rates_total < prev_calculated || ArraySize(g_bars) == 0) {
      ReloadHistory();
      if(!g_dirty) return 0;
   }

   if(g_needsReload) {
      g_needsReload = false;
      ReloadHistory();
   }

   MqlTick ticks[];
   uint flag   = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long nowMsc = (long)TimeCurrent() * 1000;
   long fromMsc= g_lastTickMs;
   if(fromMsc == 0) {
      long lb = 60000;
      fromMsc = (nowMsc > lb) ? nowMsc - lb : nowMsc;
   }

   int copied = CopyTicksRange(_Symbol, ticks, flag, fromMsc, nowMsc);
   if(copied > 0) {
      if(g_prevBid == 0.0) g_prevBid = ticks[0].bid;
      ProcessTicks(ticks, 0, copied, true, true);
   }

   if(g_dirty) ThrottledRender();
   return rates_total;
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(id == CHARTEVENT_KEYDOWN) {
      int key = (int)lparam;

      if(key == InpKeyRefresh) { g_needsReload = true; g_dirty = true; }
      else if(key == InpKeyVisible) { g_visible = !g_visible; g_dirty = true; }
      else if(key == InpKeyText)    { g_userHideText = !g_userHideText; g_dirty = true; }
      else if(key == InpKeyTickUp) {
         int steps[] = {1,2,5,10,20,40,100};
         for(int s=0; s<ArraySize(steps)-1; s++)
            if(g_basePts <= steps[s]) { g_basePts=steps[s+1]; break; }
         if(g_basePts == 100) g_basePts = 100;  // cap
         g_baseStep = g_basePts * _Point;
         g_step = g_baseStep * g_tickMult;
         g_needsReload = true; g_dirty = true;
      }
      else if(key == InpKeyTickDn) {
         int steps[] = {1,2,5,10,20,40,100};
         for(int s=ArraySize(steps)-1; s>0; s--)
            if(g_basePts >= steps[s]) { g_basePts=steps[s-1]; break; }
         g_baseStep = g_basePts * _Point;
         g_step = g_baseStep * g_tickMult;
         g_needsReload = true; g_dirty = true;
      }
      else if(key == InpKeyMultUp) {
         int steps[] = {1,2,5,10,20,40};
         for(int s=0; s<ArraySize(steps)-1; s++)
            if(g_tickMult <= steps[s]) { g_tickMult=steps[s+1]; break; }
         g_step = g_baseStep * g_tickMult;
         g_needsReload = true; g_dirty = true;
      }
      else if(key == InpKeyMultDn) {
         int steps[] = {1,2,5,10,20,40};
         for(int s=ArraySize(steps)-1; s>0; s--)
            if(g_tickMult >= steps[s]) { g_tickMult=steps[s-1]; break; }
         g_step = g_baseStep * g_tickMult;
         g_needsReload = true; g_dirty = true;
      }

      if(g_dirty) ThrottledRender();
   }

   else if(id == CHARTEVENT_CHART_CHANGE) {
      if(ArraySize(g_bars) > 0) {
         int   barsTot = iBars(_Symbol, PERIOD_CURRENT);
         int   span    = MathMin(InpHistoryBars, barsTot-1);
         datetime expFirst = iTime(_Symbol, PERIOD_CURRENT, span);
         datetime expLast  = iTime(_Symbol, PERIOD_CURRENT, 0);
         if(g_bars[0].bar_time != expFirst || g_bars[ArraySize(g_bars)-1].bar_time != expLast)
            ReloadHistory();
      }
      g_dirty = true;
      ThrottledRender();
   }

   else if(id == CHARTEVENT_MOUSE_MOVE) {
      int nx = (int)lparam, ny = (int)dparam;
      bool wasNear = HitTest(g_mouseX,g_mouseY, g_panX1-8,g_panY1-8, g_panX2+8,g_panY2+8);
      bool nowNear = HitTest(nx,ny,             g_panX1-8,g_panY1-8, g_panX2+8,g_panY2+8);
      g_mouseX = nx; g_mouseY = ny;
      if(wasNear || nowNear) ThrottledRender();
   }

   else if(id == CHARTEVENT_CLICK) {
      int mx=(int)lparam, my=(int)dparam;

      if(HitTest(mx,my,g_btnZoX1,g_btnZoY1,g_btnZoX2,g_btnZoY2)) {
         int sc=(int)ChartGetInteger(g_chart,CHART_SCALE,0);
         if(sc>0) ChartSetInteger(g_chart,CHART_SCALE,0,sc-1);
      }
      else if(HitTest(mx,my,g_btnZiX1,g_btnZiY1,g_btnZiX2,g_btnZiY2)) {
         int sc=(int)ChartGetInteger(g_chart,CHART_SCALE,0);
         if(sc<5) ChartSetInteger(g_chart,CHART_SCALE,0,sc+1);
      }
      else if(HitTest(mx,my,g_btnSzX1,g_btnSzY1,g_btnSzX2,g_btnSzY2)) {
         int steps[]={1,2,5,10,20,40,100};
         bool found=false;
         for(int s=0;s<ArraySize(steps)-1;s++)
            if(g_basePts<=steps[s]) { g_basePts=steps[s+1]; found=true; break; }
         if(!found) g_basePts=1;
         g_baseStep=g_basePts*_Point; g_step=g_baseStep*g_tickMult;
         g_needsReload=true; g_dirty=true;
      }
      else if(HitTest(mx,my,g_btnMxX1,g_btnMxY1,g_btnMxX2,g_btnMxY2)) {
         int steps[]={1,2,5,10,20,40};
         bool found=false;
         for(int s=0;s<ArraySize(steps)-1;s++)
            if(g_tickMult<=steps[s]) { g_tickMult=steps[s+1]; found=true; break; }
         if(!found) g_tickMult=1;
         g_step=g_baseStep*g_tickMult;
         g_needsReload=true; g_dirty=true;
      }
      else if(HitTest(mx,my,g_btnImbX1,g_btnImbY1,g_btnImbX2,g_btnImbY2)) {
         if(g_imbRatio <= IMB_LO) g_imbRatio = IMB_MID;
         else if(g_imbRatio <= IMB_MID) g_imbRatio = IMB_HI;
         else g_imbRatio = IMB_LO;
         g_dirty=true;
      }
      else if(HitTest(mx,my,g_btnVAX1,g_btnVAY1,g_btnVAX2,g_btnVAY2)) {
         if(g_vaPercent < 80.0) g_vaPercent=80.0;
         else if(g_vaPercent < 90.0) g_vaPercent=90.0;
         else g_vaPercent=70.0;
         g_dirty=true;
      }
      else if(HitTest(mx,my,g_btnTxtX1,g_btnTxtY1,g_btnTxtX2,g_btnTxtY2)) {
         g_userHideText=!g_userHideText; g_dirty=true;
      }
      else if(HitTest(mx,my,g_btnVisX1,g_btnVisY1,g_btnVisX2,g_btnVisY2)) {
         g_visible=!g_visible; g_dirty=true;
      }
      else if(HitTest(mx,my,g_btnRldX1,g_btnRldY1,g_btnRldX2,g_btnRldY2)) {
         g_needsReload=true; g_dirty=true;
      }

      if(g_dirty) ThrottledRender();
   }
}

// Panel control strip is always rendered as it doesn't depend on g_visible