//+------------------------------------------------------------------+
//|                                                    Footprint.mq5  |
//|   Footprint (Order Flow) — Production Ready v6.10                |
//|   Volume / Delta / Bid x Ask per price level                     |
//|   POC · VA% · Imbalance · Absorption · Stacked Imbalances        |
//|   HVN/LVN · Delta Divergence · Buy/Sell Ratio Stripe             |
//|   Delta Gradient · Exhaustion Signal · OFS Score                 |
//|   Tick-size aggregation · Tick Multiplier (x1..x40)              |
//|   Compact canvas overlay + control panel                         |
//|   v6.10 — Production signal fixes:                               |
//|   • FIXED: C4 absorption inversion (was boosting sells wrong)    |
//|   • FIXED: OFScore absorption now position-aware (LOW vs HIGH)   |
//|   • FIXED: DrawSignalMarkersPass now uses ComputeAdaptiveThresh  |
//|   • NEW C7: Unfinished auction at extremes (10% weight)          |
//|   • NEW: Min bar range filter (no signals on inside/flat bars)   |
//|   • NEW: Close-side confirmation filter (production grade)       |
//|   • IMPROVED: GetConvictionResult includes unfinished auction    |
//|   • IMPROVED: Arrow tooltips show full 7-component breakdown     |
//|   • IMPROVED: Hint cards show conviction label inline            |
//|   Weights: C1(28) C2(18) C3(12) C4(10) C5(10) C6(12) C7(10)    |
//+------------------------------------------------------------------+
#property copyright "Ali Magdy"
#property version   "6.10"
#property description "Footprint Chart v6.10 — Production Signal Engine · Symmetric Buy/Sell · Push Notifications"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- Chart mode (based on ClusterDelta #Footprint docs)
enum ENUM_FOOT_CHART_MODE
  {
   FOOT_CHART_VOLUME = 0,   // Volume per price level
   FOOT_CHART_DELTA  = 1,   // Delta (Ask-Bid) per price level
   FOOT_CHART_BIDASK = 2    // Bid x Ask cluster (industry standard)
  };

//--- Inputs
input group "Data & History"
input int    InpTickSize        = 10;           // Base cell size (points), 1 point = 1×_Point
input double InpImbalanceRatio  = 300.0;        // Imbalance Threshold (%)
input int    InpStackedImbCount = 3;            // Stacked Imbalance Min Count
input double InpAbsorptionRatio = 4.0;          // Absorption Threshold (x Avg Vol)
input int    InpHistoryBars     = 100;          // History bars to load
input double InpVAPercent       = 70.0;         // Value Area % (industry default 70)
input double InpHVNRatio        = 2.0;          // HVN Threshold (x Avg Vol) — High Volume Node
input double InpLVNRatio        = 0.35;         // LVN Threshold (ratio of Avg Vol) — Low Volume Node

input group "Aggregation"
input ENUM_FOOT_CHART_MODE InpChartMode      = FOOT_CHART_DELTA;                 // Chart mode (Delta=default)
input int                  InpTickMultiplier = 5;                 // Tick multiplier (1,2,5,10,20,40)

input group "Display"
input bool   InpShowText       = false;         // Show Cell Numbers (Bid/Ask/Vol/Delta text)
input bool   InpShowWick       = true;          // Show candle wick on footprint bars
input bool   InpProfileOnly    = false;         // Profile-Only mode: hide footprint, keep CumΔ profile
input uchar  InpBgAlpha        = 210;           // Cell Background Alpha (0-255)
input uchar  InpVAOffAlpha     = 80;            // Alpha outside Value Area (0-255)

input group "Colors - Heatmap"
input color  InpBidBaseColor   = C'28,6,38';    // Bid (Sell) Base — deep violet (visible floor)
input color  InpBidHighColor   = C'160,0,90';   // Bid (Sell) High — vivid magenta-crimson
input color  InpAskBaseColor   = C'4,28,28';    // Ask (Buy) Base — deep teal (visible floor)
input color  InpAskHighColor   = C'0,140,120';  // Ask (Buy) High — vivid teal-green
input color  InpOutOfVAColor   = C'14,14,18';   // Out of Value Area — near-black, minimal distraction

input group "Colors - Highlights & UI"
input color  InpImbSellColor    = C'180,30,50';   // Sell Imbalance — warm red, readable at all alphas
input color  InpImbBuyColor     = C'20,160,80';   // Buy Imbalance — vivid green, perceptually distinct
input color  InpStackedSellColor= C'200,40,60';   // Stacked Sell Zone — brighter than plain imbalance
input color  InpStackedBuyColor = C'30,190,100';  // Stacked Buy Zone — brighter than plain imbalance
input color  InpUnfinishedColor = C'80,160,255';  // Unfinished Auction — sky blue, not confused with POC
input color  InpAbsorptionColor = C'200,80,220';  // Absorption — violet-magenta, distinct from all others
input color  InpPOCColor        = C'255,220,0';   // POC Frame — amber-gold (high contrast on dark bg)
input color  InpBullishFrame    = C'40,200,100';  // Bullish Session Frame
input color  InpBearishFrame    = C'200,40,60';   // Bearish Session Frame
input color  InpWickColor       = C'130,130,145'; // Candle Wick — slightly blue-grey, stays subtle
input color  InpGridColor       = C'45,45,58';    // Grid — darkened so it never dominates
input color  InpHVNColor        = C'255,210,50';  // HVN outline — amber, matches POC family
input color  InpLVNColor        = C'80,80,105';   // LVN outline — muted indigo-grey
input color  InpDivergenceColor = C'255,140,0';   // Delta Divergence marker — pure orange

input group "Colors - Text"
input color  InpTextBaseColor   = C'150,150,165'; // Default Cell Text — slightly cool grey
input color  InpTextDarkBg      = C'230,230,235'; // Text on Dark Backgrounds — off-white (less harsh than pure white)
input color  InpTextLightBg     = C'20,20,25';    // Text on Light Backgrounds
input color  InpTextBottomVol   = C'180,180,195'; // Bottom Label: Volume — subdued, volume is context not signal
input color  InpTextBottomPos   = C'60,220,110';  // Bottom Label: Positive Delta — green
input color  InpTextBottomNeg   = C'220,60,80';   // Bottom Label: Negative Delta — red (correct BGR)

input group "Delta Gradient Background"
input bool   InpDeltaGradient     = true;           // Enable delta-magnitude gradient on bars
input uchar  InpDeltaGradMaxAlpha = 55;             // Max gradient overlay alpha — keep subtle
input color  InpDeltaGradBull     = C'20,120,60';   // Gradient tint: bullish delta (soft green)
input color  InpDeltaGradBear     = C'120,20,40';   // Gradient tint: bearish delta (soft red)

input group "Bid/Ask Exhaustion Signal"
input bool   InpExhaustionEnable  = true;           // Enable bid/ask exhaustion marker
input int    InpExhaustionCells   = 3;              // Consecutive near-zero cells required
input double InpExhaustionZeroRat = 0.05;           // Near-zero threshold (fraction of avg vol)
input color  InpExhaustionColor   = C'255,180,0';   // Exhaustion line — amber, distinct from orange divergence

input group "Order Flow Strength Score"
input bool   InpShowOFScore       = true;          // Show OFS score (0-100) below bar label
input double InpOFWtDelta         = 40.0;          // OFS weight: delta ratio (%)
input double InpOFWtImb           = 25.0;          // OFS weight: imbalance count (%)
input double InpOFWtStacked       = 20.0;          // OFS weight: stacked imbalance (%)
input double InpOFWtAbsorb        = 15.0;          // OFS weight: absorption (%)

input group "High Probability Signals"
input bool   InpShowSignals       = true;          // Show High Probability Signal markers
input int    InpSignalThreshold   = 60;            // HFT Score threshold (buy>=thresh, sell<=-thresh)
input color  InpSignalBuyColor    = C'0,220,100';  // Buy Signal Color
input color  InpSignalSellColor   = C'220,40,60';  // Sell Signal Color
input int    InpSignalFreqBars    = 3;             // Min bars between repeated signals (1=every bar)
input string InpSignalBuySound   = "alert.wav";   // Buy signal sound file (WAV, in MT5 Sounds folder)
input string InpSignalSellSound  = "alert2.wav";  // Sell signal sound file (WAV, in MT5 Sounds folder)

input group "Signal Ball Style"
input int    InpSigBallRadius    = 14;   // Signal ball max radius (px)
input int    InpSigBallMinRadius = 5;    // Signal ball min radius (px)
input int    InpSigRingCount     = 5;    // Concentric rings per ball
input int    InpSigRingThickness = 2;    // Ring line thickness

input group "Signal Filters"
input int    InpATR_Period          = 14;    // ATR period for adaptive threshold
input bool   InpAdaptiveThreshold   = false; // Scale threshold by ATR volatility
input double InpAdaptiveThreshMin   = 35.0;  // Adaptive threshold floor
input double InpAdaptiveThreshMax   = 75.0;  // Adaptive threshold ceiling
input int    InpMinConvictionComp   = 0;     // Min distinct conviction sources (0=off)
input int    InpMinBarRangePts      = 0;     // Min bar range in points before signalling (0=off). Prevents noise on inside bars
input bool   InpRequireCloseSide    = false; // Require close in upper 40% (buy) or lower 40% (sell) of bar range

input group "Notifications"
input bool   InpPushNotify          = true;  // Send MT5 Push Notification on signal (requires MetaQuotes ID in Options → Notifications)
input bool   InpPushOnlyNewBar      = true;  // Only push-notify once per bar (suppresses intra-bar repeats)

input group "Delta Mode Cell Coloring"           // Enable per-cell green/red in Delta mode
input bool   InpDeltaCellColor    = true;           // Enable per-cell green/red in Delta mode
input color  InpDeltaCellBull     = C'5,70,40';     // Delta mode: ask>bid base (dark green floor)
input color  InpDeltaCellBear     = C'70,5,20';     // Delta mode: bid>ask base (dark red floor)
input color  InpDeltaZeroLine     = C'160,100,255'; // Delta zero-line — violet, unique, clearly a reference

input group "Naked POC"
input bool   InpShowNakedPOC      = true;            // Highlight POC levels not yet retested by price
input color  InpNakedPOCColor     = C'255,80,30';    // Naked POC frame — orange-red (urgent, distinct from gold)

input group "Cumulative Delta Profile"
input bool   InpShowCumDeltaProf  = true;            // Show session cumulative delta profile (right side)
input int    InpCumDeltaProfW     = 55;              // Profile panel width (px)
input uchar  InpCumDeltaProfAlpha = 170;             // Profile bar alpha (0-255)
input color  InpCumDeltaPosColor  = C'20,160,80';    // Profile: positive cumulative delta (green)
input color  InpCumDeltaNegColor  = C'180,30,50';    // Profile: negative cumulative delta (red)
input bool   InpCumDeltaGradient  = true;            // Profile: gradient bars (origin dim → tip bright)
input bool   InpCumDeltaVPLabels  = true;            // Profile: show POC / VAH / VAL lines and labels

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
   bool   is_hvn;            // High Volume Node (>= HVN ratio x avg)
   bool   is_lvn;            // Low Volume Node  (<= LVN ratio x avg)
   bool   is_exhaustion_bid; // Bid exhaustion: bid near-zero at bar low cluster
   bool   is_exhaustion_ask; // Ask exhaustion: ask near-zero at bar high cluster
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
   bool       is_delta_divergence; // price moved up but delta fell (or vice versa)
   bool       is_naked_poc;        // POC level not yet retested by any subsequent bar
   PriceLevel levels[];
  };

// Conviction result: label string + component count for diversity gate
struct ConvictionResult
  {
   string label;
   int    componentCount;
  };

//--- Globals
CCanvas              canvas;
string               g_name     = "FP_Canvas";
FPBar                g_bars[];
double               g_step;         // aggregated step = g_baseStep * g_tickMult
double               g_baseStep;     // base step from InpTickSize
int                  g_basePts = 10; // runtime base cell size (points)
int                  g_tickMult = 1; // runtime tick multiplier
ENUM_FOOT_CHART_MODE g_mode    = FOOT_CHART_DELTA;
long                 g_chart;
int                  g_sub;
bool                 g_hasTrades;
double               g_prevBid;
bool                 g_dirty;
bool                 g_hideText;
bool                 g_userHideText = false; // user toggle: force-hide cell numbers
double               g_imbRatio;     // current imbalance ratio (GUI-tunable)
int                  g_opacity = 255;    // overlay opacity (runtime-tunable: 255/190/127/64)
long                 g_last_tick_time_ms = 0;
ulong                g_last_render_ms    = 0;
bool                 g_needs_reload = false; // state-machine flag: set in OnChartEvent, consumed in OnCalculate
datetime             g_last_tester_render_time = 0; // for Strategy Tester simulated-time throttle

// --- Signal feature globals ---
bool     g_signalsEnabled  = true;   // runtime toggle (seeded from InpShowSignals on init)
int      g_signalFreqBars  = 3;      // runtime min-bars between signals
int      g_signalThreshold = 60;     // runtime score threshold
datetime g_lastSignalBarTime = 0;    // spacing gate
int      g_sigCacheBarIdx  = -1;     // cache: avoid re-evaluation on identical tick
long     g_sigCacheVol     = -1;     // cache: last total_vol seen on live bar
datetime g_lastPushBarTime = 0;      // push gate: last bar for which a push was sent

// --- ATR for adaptive threshold ---
int      g_handleATR   = INVALID_HANDLE;
double   g_Pip         = 0.0001;     // auto-detected in OnInit

// GUI panel & buttons
#define FP_PANEL_BTN_W          46
#define FP_PANEL_BTN_GAP        3
#define FP_PANEL_PAD            3
#define FP_PANEL_H              24
#define FP_PANEL_MARGIN         5
#define FP_RENDER_THROTTLE_MS   33   // ~30 FPS max to avoid UI lag
#define FP_MIN_CELL_H           16   // Min cell height (px) for readability

// Opacity cycle presets
#define FP_OPA_FULL    255
#define FP_OPA_75      190
#define FP_OPA_50      127
#define FP_OPA_25       64

// Imbalance ratio cycle presets
#define FP_IMB_LO      200.0
#define FP_IMB_MID     300.0
#define FP_IMB_HI      400.0
#define FP_HIST_EDIT   "FP_HistEdit"   // OBJ_EDIT name for history-bars input
#define FP_HIST_MIN    1               // minimum allowed history bars
#define FP_HIST_MAX    5000            // maximum allowed history bars

int   g_panelX1, g_panelY1, g_panelX2, g_panelY2;
int   g_btnSizeX1, g_btnSizeY1, g_btnSizeX2, g_btnSizeY2;
int   g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2;
int   g_btnImbX1,  g_btnImbY1,  g_btnImbX2,  g_btnImbY2;
int   g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2;
int   g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2;
int   g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2;
int   g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2;
int   g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2;
int   g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2;
int   g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2;
int   g_btnTxtX1, g_btnTxtY1, g_btnTxtX2, g_btnTxtY2;
int   g_btnModeX1, g_btnModeY1, g_btnModeX2, g_btnModeY2;
int   g_btnProfX1, g_btnProfY1, g_btnProfX2, g_btnProfY2;
// Signal toggle button + SigFreq + SigThresh edit-box coords
int   g_btnSigX1, g_btnSigY1, g_btnSigX2, g_btnSigY2;
// OBJ_EDIT names for signal controls (suffixed with ChartID in OnInit)
string g_editFreqName   = "FP_SigFreqEdit";
string g_editThreshName = "FP_SigThreshEdit";
#define FP_SIG_FREQ_EDIT   g_editFreqName
#define FP_SIG_THRESH_EDIT g_editThreshName
// History input edit-box screen coords (updated each LayoutPanel call)
int   g_histEditX  = 0;
int   g_histEditY  = 0;
int   g_histEditW  = FP_PANEL_BTN_W;
int   g_histEditH  = FP_PANEL_H - 2 * FP_PANEL_PAD;
int   g_histBars   = 100;             // runtime history-bars count
int   g_mouseX = -1, g_mouseY = -1;
double g_vaPercent = 0;
bool   g_visible     = true;
bool   g_profileOnly = false;

// Persistent scratch buffers
int  g_scratchY1[];
int  g_scratchY2[];
int  g_scratchCap = 0;

// Cumulative delta profile data (rebuilt each render)
double g_profPrices[];   // price levels for the profile
long   g_profCumDelta[]; // cumulative delta per price level
int    g_profCount = 0;  // number of valid entries

//+------------------------------------------------------------------+
//| Helper: point-in-rect hit test                                  |
//+------------------------------------------------------------------+
bool HitTest(int mx, int my, int x1, int y1, int x2, int y2)
  {
   return (mx >= x1 && mx <= x2 && my >= y1 && my <= y2);
  }

//+------------------------------------------------------------------+
//| Helper: throttled render (avoids redundant redraws)             |
//+------------------------------------------------------------------+
void ThrottledRender()
  {
   // Strategy Tester: use simulated chart time (wall-clock barely advances)
   if(MQLInfoInteger(MQL_TESTER))
     {
      datetime now_sim = TimeCurrent();
      if(now_sim - g_last_tester_render_time >= 60)
        {
         Render();
         g_last_tester_render_time = now_sim;
        }
      return;
     }

   // Live/replay: 30 FPS wall-clock cap
   ulong now_ticks = GetTickCount();
   if(now_ticks - g_last_render_ms >= FP_RENDER_THROTTLE_MS)
     {
      Render();
      g_last_render_ms = now_ticks;
     }
  }

//+------------------------------------------------------------------+
//| Forward declarations                                            |
//+------------------------------------------------------------------+
void Render();                  // defined later — called by ThrottledRender
void ComputeBarSignals(int bi); // defined later — needed by ComputeNakedPOCs
// Signal engine forward declarations
double ComputeHFTSignal(int bi, int preOFS = -1);
double ComputeCVDSlope(int bi);
int    ComputeAdaptiveThreshold();
ConvictionResult GetConvictionResult(int bi, bool isBuy);
void   EvalAndFireSignal();
void   DrawSignalMarkersPass(int visBars, int firstVis, int barW);
void   DrawRings(int xc, int yc, int maxR, color col, int alpha);

//+------------------------------------------------------------------+
//| Naked POC: mark POC levels not yet retested by subsequent bars  |
//| A Naked POC is a high-interest price magnet — price tends to    |
//| return and fill these levels. Most useful in Delta mode.        |
//+------------------------------------------------------------------+
void ComputeNakedPOCs()
  {
   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++)
     {
      g_bars[i].is_naked_poc = false;
      // Ensure signals are computed so poc_idx is valid
      if(!g_bars[i].sorted)
         ComputeBarSignals(i);
      int pocIdx = g_bars[i].poc_idx;
      if(pocIdx < 0 || pocIdx >= g_bars[i].level_count)
         continue;

      double pocPrice = g_bars[i].levels[pocIdx].price;
      bool   retested = false;
      // Check every bar that opened AFTER this one
      for(int j = i + 1; j < n && !retested; j++)
        {
         if(pocPrice >= g_bars[j].low - g_step * 0.5 &&
            pocPrice <= g_bars[j].high + g_step * 0.5)
            retested = true;
        }
      g_bars[i].is_naked_poc = !retested;
     }
  }

//+------------------------------------------------------------------+
//| Helper: clear bars and reload tick history from scratch         |
//+------------------------------------------------------------------+
void ReloadHistory()
  {
   g_dirty = false;

   // Purge previously placed signal arrows — recreated from fresh data
   int total = ObjectsTotal(g_chart, 0, OBJ_ARROW);
   for(int i = total - 1; i >= 0; i--)
     {
      string nm = ObjectName(g_chart, i, 0, OBJ_ARROW);
      if(StringFind(nm, "FP_Sig_") == 0)
         ObjectDelete(g_chart, nm);
     }
   g_lastSignalBarTime = 0;  // reset spacing gate after purge
   g_lastPushBarTime   = 0;  // reset push gate — fresh history should allow push on first signal
   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++)
     {
      ArrayFree(g_bars[i].levels);
     }
   ArrayFree(g_bars);
   g_last_tick_time_ms = 0;
   int bars_total = iBars(_Symbol, PERIOD_CURRENT);
   if(bars_total <= 0)
      return;
   int      maxShift  = MathMin(g_histBars, bars_total - 1);
   datetime startTime = iTime(_Symbol, PERIOD_CURRENT, maxShift);
   datetime endTime   = TimeCurrent();
   int loaded = LoadHistory(startTime, endTime);
   if(loaded > 0)
     {
      ComputeNakedPOCs(); // Mark POC levels not yet retested
      g_dirty = true;
     }
   else
     {
      static bool s_alerted = false;
      if(!s_alerted)
        {
         Alert("Footprint: No tick data for ", _Symbol, ". Click Refresh (Rld) when data is available.");
         s_alerted = true;
        }
     }
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
      if(g_bars[mid].bar_time == bt)
         return mid;
      if(g_bars[mid].bar_time < bt)
         lo = mid + 1;
      else
         hi = mid - 1;
     }
   return -1;
  }

//+------------------------------------------------------------------+
int InsertBar(datetime bt)
  {
   int n = ArraySize(g_bars);
   
   // Fast-path for chronological appending
   if(n > 0 && bt > g_bars[n - 1].bar_time)
     {
      ArrayResize(g_bars, n + 1, 128);
      g_bars[n].bar_time    = bt;
      g_bars[n].total_vol   = 0;
      g_bars[n].total_delta = 0;
      g_bars[n].high        = 0.0;
      g_bars[n].low         = 0.0;
      g_bars[n].sorted      = true;
      g_bars[n].is_bullish  = true;
      g_bars[n].level_count = 0;
      g_bars[n].poc_idx     = -1;
      g_bars[n].va_lo_idx   = -1;
      g_bars[n].va_hi_idx   = -1;
      g_bars[n].is_delta_divergence = false;
      g_bars[n].is_naked_poc        = false;
      ArrayResize(g_bars[n].levels, 64, 64);
      return n;
     }

   int pos = n;
   for(int i = n - 1; i >= 0; i--)
     {
      if(g_bars[i].bar_time == bt)
         return i;
      if(g_bars[i].bar_time < bt)
        {
         pos = i + 1;
         break;
        }
      pos = i;
     }

   // Append a fresh slot at the end, then bubble it into position.
   // We MUST NOT use struct assignment to shift elements because FPBar
   // contains a dynamic array (levels[]); MQL5 struct assignment does a
   // shallow copy of dynamic arrays, leaving both the source and the
   // destination pointing at the same buffer — corrupting memory.
   // Bubbling via ArraySwap-style pointer swap is not available in MQL5
   // for custom structs, so we instead shift the plain scalar fields and
   // move level data explicitly with ArraySwap on the levels sub-array.
   ArrayResize(g_bars, n + 1, 128);

   // Initialise the brand-new slot at the end
   g_bars[n].bar_time    = 0;
   g_bars[n].total_vol   = 0;
   g_bars[n].total_delta = 0;
   g_bars[n].high        = 0.0;
   g_bars[n].low         = 0.0;
   g_bars[n].sorted      = true;
   g_bars[n].is_bullish  = true;
   g_bars[n].level_count = 0;
   g_bars[n].poc_idx     = -1;
   g_bars[n].va_lo_idx   = -1;
   g_bars[n].va_hi_idx   = -1;
   g_bars[n].is_delta_divergence = false;
      g_bars[n].is_naked_poc        = false;
   ArrayResize(g_bars[n].levels, 0);

   // Shift scalar fields and swap dynamic arrays from n..pos+1 downward
   for(int i = n; i > pos; i--)
     {
      // Copy scalars from i-1 to i
      g_bars[i].bar_time    = g_bars[i - 1].bar_time;
      g_bars[i].total_vol   = g_bars[i - 1].total_vol;
      g_bars[i].total_delta = g_bars[i - 1].total_delta;
      g_bars[i].high        = g_bars[i - 1].high;
      g_bars[i].low         = g_bars[i - 1].low;
      g_bars[i].sorted      = g_bars[i - 1].sorted;
      g_bars[i].is_bullish  = g_bars[i - 1].is_bullish;
      g_bars[i].level_count = g_bars[i - 1].level_count;
      g_bars[i].poc_idx     = g_bars[i - 1].poc_idx;
      g_bars[i].va_lo_idx   = g_bars[i - 1].va_lo_idx;
      g_bars[i].va_hi_idx   = g_bars[i - 1].va_hi_idx;
      g_bars[i].is_delta_divergence = g_bars[i - 1].is_delta_divergence;
      // Move the dynamic levels array: copy contents then clear source
      int lc = g_bars[i - 1].level_count;
      ArrayResize(g_bars[i].levels, lc, 64);
      for(int k = 0; k < lc; k++)
         g_bars[i].levels[k] = g_bars[i - 1].levels[k];
     }

   // Place new bar at pos
   g_bars[pos].bar_time    = bt;
   g_bars[pos].total_vol   = 0;
   g_bars[pos].total_delta = 0;
   g_bars[pos].high        = 0.0;
   g_bars[pos].low         = 0.0;
   g_bars[pos].sorted      = true;
   g_bars[pos].is_bullish  = true;
   g_bars[pos].level_count = 0;
   g_bars[pos].poc_idx     = -1;
   g_bars[pos].va_lo_idx   = -1;
   g_bars[pos].va_hi_idx   = -1;
   g_bars[pos].is_delta_divergence = false;
   g_bars[pos].is_naked_poc        = false;
   ArrayResize(g_bars[pos].levels, 64, 64);
   return pos;
  }

//+------------------------------------------------------------------+
int GetBar(datetime bt)
  {
   int idx = FindBarIndex(bt);
   if(idx >= 0)
      return idx;
   return InsertBar(bt);
  }

//+------------------------------------------------------------------+
//| Phase 1: Accumulate Ticks to Price Levels                        |
//+------------------------------------------------------------------+
void AccumulateTick(int bi, double price, long vol, bool isBuy, bool isSell)
  {
   if(price == 0.0)
      return;
   price = NormP(price);

   int used = g_bars[bi].level_count;
   int idx  = -1;

   // Boundary check to skip search loop
   bool skipSearch = (price > g_bars[bi].high + g_step || price < g_bars[bi].low - g_step);

   if(!skipSearch)
     {
      // Search for existing level (optimized for recent levels)
      for(int i = used - 1; i >= 0; i--)
        {
         if(MathAbs(g_bars[bi].levels[i].price - price) < g_step * 0.4)
           {
            idx = i;
            break;
           }
        }
     }

   // Create new level if not found
   if(idx == -1)
     {
      if(used >= ArraySize(g_bars[bi].levels))
         ArrayResize(g_bars[bi].levels, used + 64, 64);

      idx                              = used;
      g_bars[bi].levels[idx].price     = price;
      g_bars[bi].levels[idx].bid_vol   = 0;
      g_bars[bi].levels[idx].ask_vol   = 0;
      g_bars[bi].levels[idx].total_vol = 0;
      g_bars[bi].levels[idx].delta     = 0;
      g_bars[bi].levels[idx].is_imb_buy          = false;
      g_bars[bi].levels[idx].is_imb_sell         = false;
      g_bars[bi].levels[idx].is_absorption        = false;
      g_bars[bi].levels[idx].is_hvn               = false;
      g_bars[bi].levels[idx].is_lvn               = false;
      g_bars[bi].levels[idx].is_stacked_imb_buy  = false;
      g_bars[bi].levels[idx].is_stacked_imb_sell = false;
      g_bars[bi].levels[idx].is_unfinished_hi    = false;
      g_bars[bi].levels[idx].is_unfinished_lo    = false;
      g_bars[bi].levels[idx].is_exhaustion_bid   = false;
      g_bars[bi].levels[idx].is_exhaustion_ask   = false;
      g_bars[bi].level_count++;
      g_bars[bi].sorted = false;
     }

   // Update metrics
   if(isBuy)
      g_bars[bi].levels[idx].ask_vol += vol;
   if(isSell)
      g_bars[bi].levels[idx].bid_vol += vol;

   g_bars[bi].levels[idx].total_vol += vol;
   g_bars[bi].levels[idx].delta      = g_bars[bi].levels[idx].ask_vol - g_bars[bi].levels[idx].bid_vol;

   g_bars[bi].total_vol   += vol;
   g_bars[bi].total_delta += (isBuy ? vol : (isSell ? -vol : 0));
   // Mark signals as stale so DrawBar will recompute on next render
   g_bars[bi].sorted = false;
   g_dirty = true;
  }

//+------------------------------------------------------------------+
//| Phase 2: Compute Bar Signals (POC, VA, Imbalance, Absorption)    |
//+------------------------------------------------------------------+
void ComputeBarSignals(int bi)
  {
   int len = g_bars[bi].level_count;
   if(len <= 0)
      return;

   if(!g_bars[bi].sorted)
     {
      SortLevels(g_bars[bi].levels, len);
      g_bars[bi].sorted = true;
     }

   // 1. POC
   g_bars[bi].poc_idx = FindPOC(g_bars[bi].levels, len);

   // 2. Value Area
   FindVA(g_bars[bi].levels, len, g_bars[bi].total_vol, g_bars[bi].poc_idx,
          g_bars[bi].va_lo_idx, g_bars[bi].va_hi_idx);

   // 3. Loop for Imbalance & Absorption
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
      g_bars[bi].levels[i].is_absorption       = (g_bars[bi].levels[i].total_vol > avgVol * InpAbsorptionRatio);
      // HVN: significantly above average; LVN: significantly below
      g_bars[bi].levels[i].is_hvn = (!g_bars[bi].levels[i].is_absorption &&
                                      g_bars[bi].levels[i].total_vol >= (long)(avgVol * InpHVNRatio));
      g_bars[bi].levels[i].is_lvn = (g_bars[bi].levels[i].total_vol > 0 &&
                                      g_bars[bi].levels[i].total_vol <= (long)(avgVol * InpLVNRatio));

      // Diagonal Imbalance
      if(i < len - 1)
        {
         long nextBid = g_bars[bi].levels[i + 1].bid_vol;
         if(nextBid > 0 && ((double)g_bars[bi].levels[i].ask_vol / nextBid) * 100.0 >= g_imbRatio)
            g_bars[bi].levels[i].is_imb_buy = true;
        }
      if(i > 0)
        {
         long prevAsk = g_bars[bi].levels[i - 1].ask_vol;
         if(prevAsk > 0 && ((double)g_bars[bi].levels[i].bid_vol / prevAsk) * 100.0 >= g_imbRatio)
            g_bars[bi].levels[i].is_imb_sell = true;
        }
     }

   // 4. Determine Stacked Imbalances
   int countBuy  = 0;
   int countSell = 0;
   for(int i = 0; i < len; i++)
     {
      // Stacked Buy
      if(g_bars[bi].levels[i].is_imb_buy)
         countBuy++;
      else
        {
         if(countBuy >= InpStackedImbCount)
           {
            for(int j = i - countBuy; j < i; j++)
               g_bars[bi].levels[j].is_stacked_imb_buy = true;
           }
         countBuy = 0;
        }

      // Stacked Sell
      if(g_bars[bi].levels[i].is_imb_sell)
         countSell++;
      else
        {
         if(countSell >= InpStackedImbCount)
           {
            for(int j = i - countSell; j < i; j++)
               g_bars[bi].levels[j].is_stacked_imb_sell = true;
           }
         countSell = 0;
        }
     }
   if(countBuy >= InpStackedImbCount)
     {
      for(int j = len - countBuy; j < len; j++)
         g_bars[bi].levels[j].is_stacked_imb_buy = true;
     }
   if(countSell >= InpStackedImbCount)
     {
      for(int j = len - countSell; j < len; j++)
         g_bars[bi].levels[j].is_stacked_imb_sell = true;
     }

   // 5. Determine Unfinished Auctions
   // Levels are sorted descending. levels[0] is High, levels[len-1] is Low.
   if(len > 1)
     {
      // Unfinished High: High has both buyers and sellers
      g_bars[bi].levels[0].is_unfinished_hi =
         (g_bars[bi].levels[0].ask_vol > 0 && g_bars[bi].levels[0].bid_vol > 0);

      // Unfinished Low: Low has both buyers and sellers
      g_bars[bi].levels[len - 1].is_unfinished_lo =
         (g_bars[bi].levels[len - 1].bid_vol > 0 && g_bars[bi].levels[len - 1].ask_vol > 0);
     }

   // 6. Delta Divergence: bullish bar with negative delta, or bearish with positive delta
   //    This flags a potential exhaustion / hidden strength signal.
   g_bars[bi].is_delta_divergence =
      (g_bars[bi].is_bullish  && g_bars[bi].total_delta < 0) ||
      (!g_bars[bi].is_bullish && g_bars[bi].total_delta > 0);

   // 7. Bid/Ask Exhaustion: one side near-zero at extremes for InpExhaustionCells+ levels
   //    Levels are sorted descending: [0]=High ... [len-1]=Low
   if(InpExhaustionEnable && len >= InpExhaustionCells)
     {
      long avgV    = MathMax(1, g_bars[bi].total_vol / len);
      long exhThr  = MathMax(1L, (long)(avgV * InpExhaustionZeroRat));

      // Ask exhaustion at bar HIGH: ask_vol near-zero at the top cluster
      // (skip levels with no volume at all — they are gaps, not exhaustion)
      int askRun = 0;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].total_vol > 0 && g_bars[bi].levels[i].ask_vol <= exhThr)
            askRun++;
         else
            break;
        }
      if(askRun >= InpExhaustionCells)
        {
         for(int i = 0; i < askRun; i++)
            g_bars[bi].levels[i].is_exhaustion_ask = true;
        }

      // Bid exhaustion at bar LOW: bid_vol near-zero at the bottom cluster
      int bidRun = 0;
      for(int i = len - 1; i >= 0; i--)
        {
         if(g_bars[bi].levels[i].total_vol > 0 && g_bars[bi].levels[i].bid_vol <= exhThr)
            bidRun++;
         else
            break;
        }
      if(bidRun >= InpExhaustionCells)
        {
         for(int i = len - 1; i >= len - bidRun; i--)
            g_bars[bi].levels[i].is_exhaustion_bid = true;
        }
     }
  }

//+------------------------------------------------------------------+
void Classify(const MqlTick &t, bool &isBuy, bool &isSell)
  {
   isBuy  = false;
   isSell = false;
   if(g_hasTrades)
     {
      isBuy  = (t.flags & TICK_FLAG_BUY) == TICK_FLAG_BUY;
      isSell = (t.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL;
      if(!isBuy && !isSell)
        {
         if(t.last >= t.ask)
            isBuy = true;
         else if(t.last <= t.bid)
            isSell = true;
        }
     }
   else
     {
      if(t.bid > g_prevBid)
         isBuy = true;
      else if(t.bid < g_prevBid)
         isSell = true;
      else
         isBuy = true;
     }
  }

//+------------------------------------------------------------------+
//| Process tick array into bars (shared by LoadHistory / OnCalculate|
//+------------------------------------------------------------------+
void ProcessTicks(MqlTick &ticks[], int startIdx, int count,
                  bool skipAlreadySeen, bool updateLastTimeMs, bool reset_cache = false)
  {
   static datetime current_bar_time = 0;
   static int current_sh = -1;
   static datetime next_bar_time = 0;

   if(reset_cache)
     {
      current_bar_time = 0;
      current_sh = -1;
      next_bar_time = 0;
     }

   if(count <= 0)
      return;
   int endIdx = startIdx + count;
   if(endIdx > ArraySize(ticks))
      endIdx = ArraySize(ticks); // Bounds check

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
         if(vol <= 0 || price == 0.0)
            continue;
        }
      else
        {
         price = ticks[i].bid;
         vol   = 1;
         if(price == 0.0)
            continue;
        }

      bool isBuy, isSell;
      Classify(ticks[i], isBuy, isSell);

      if(ticks[i].bid != 0.0)
         g_prevBid = ticks[i].bid;

      if(ticks[i].time < current_bar_time || ticks[i].time >= next_bar_time)
        {
         current_sh = iBarShift(_Symbol, PERIOD_CURRENT, ticks[i].time);
         if(current_sh < 0)
            continue;
         current_bar_time = iTime(_Symbol, PERIOD_CURRENT, current_sh);
         next_bar_time = current_bar_time + PeriodSeconds(PERIOD_CURRENT);
        }

      int      sh = current_sh;
      datetime bt = current_bar_time;
      int      bi = GetBar(bt);

      // Update dimensions and sentiment BEFORE accumulating so AccumulateTick
      // boundary checks (skipSearch) use correct high/low on first tick of bar.
      double bOpen  = iOpen(_Symbol, PERIOD_CURRENT, sh);
      double bClose = iClose(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].is_bullish = (bClose >= bOpen);
      g_bars[bi].high       = iHigh(_Symbol, PERIOD_CURRENT, sh);
      g_bars[bi].low        = iLow(_Symbol, PERIOD_CURRENT, sh);

      AccumulateTick(bi, price, vol, isBuy, isSell);

      if(updateLastTimeMs)
         g_last_tick_time_ms = ticks[i].time_msc;
     }
  }

//+------------------------------------------------------------------+
int LoadHistory(datetime t0, datetime t1)
  {
   MqlTick ticks[];
   uint    flag   = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   int     copied = CopyTicksRange(_Symbol, ticks, flag,
                                   (long)t0 * 1000, (long)t1 * 1000);
   if(copied <= 0)
      return -1;

   g_prevBid = ticks[0].bid;
   ProcessTicks(ticks, 0, copied, false, true, true);

   g_dirty = true;
   return copied;
  }

//+------------------------------------------------------------------+
//| Quicksort partition (descending by price)                        |
//+------------------------------------------------------------------+
void SortLevelsPartition(PriceLevel &lv[], int lo, int hi)
  {
   if(lo >= hi)
      return;
   double pivot = lv[hi].price;
   int    i     = lo - 1;
   for(int j = lo; j < hi; j++)
     {
      if(lv[j].price >= pivot)
        {
         i++;
         PriceLevel tmp = lv[i];
         lv[i]          = lv[j];
         lv[j]          = tmp;
        }
     }
   i++;
   PriceLevel tmp = lv[i];
   lv[i]          = lv[hi];
   lv[hi]         = tmp;

   SortLevelsPartition(lv, lo, i - 1);
   SortLevelsPartition(lv, i + 1, hi);
  }

//+------------------------------------------------------------------+
void SortLevels(PriceLevel &lv[], int n)
  {
   if(n <= 1)
      return;
   SortLevelsPartition(lv, 0, n - 1);
  }

//+------------------------------------------------------------------+
int FindPOC(const PriceLevel &lv[], int count)
  {
   int  best = -1;
   long mx   = 0;
   for(int i = 0; i < count; i++)
      if(lv[i].total_vol > mx)
        {
         mx   = lv[i].total_vol;
         best = i;
        }
   return best;
  }

//+------------------------------------------------------------------+
double GetEffectiveVAPercent()
  {
   if(g_vaPercent > 0.0)
      return g_vaPercent;
   return (InpVAPercent > 0.0) ? InpVAPercent : 70.0;
  }

//+------------------------------------------------------------------+
void FindVA(const PriceLevel &lv[], int count, long totVol, int poc, int &lo, int &hi)
  {
   lo = poc;
   hi = poc;
   if(poc < 0)
      return;
   long target = (long)(totVol * GetEffectiveVAPercent() / 100.0);
   long cur    = lv[poc].total_vol;

   // Dual-row expansion: compare sum of two rows above vs below, expand toward higher volume
   while(cur < target && (lo > 0 || hi < count - 1))
     {
      // Sum of the two rows above hi
      long up = 0;
      if(hi + 1 < count) up += lv[hi + 1].total_vol;
      if(hi + 2 < count) up += lv[hi + 2].total_vol;
      bool canUp = (hi < count - 1);

      // Sum of the two rows below lo
      long dn = 0;
      if(lo - 1 >= 0) dn += lv[lo - 1].total_vol;
      if(lo - 2 >= 0) dn += lv[lo - 2].total_vol;
      bool canDn = (lo > 0);

      if(canUp && (!canDn || up >= dn))
        {
         hi++;
         cur += lv[hi].total_vol;
        }
      else if(canDn)
        {
         lo--;
         cur += lv[lo].total_vol;
        }
      else
         break;
     }
  }

//+------------------------------------------------------------------+
uint FpARGB(color c, int a)
  {
   return ColorToARGB(c, (uchar)MathMin(MathMax(a, 0), 255));
  }

//+------------------------------------------------------------------+
//| Helper: luminance-based dark/light detection                     |
//+------------------------------------------------------------------+
bool IsColorDark(color c)
  {
   int r = (c) & 0xFF;
   int g = (c >> 8) & 0xFF;
   int b = (c >> 16) & 0xFF;
   // Standard perceived luminance formula
   double luma = 0.299 * r + 0.587 * g + 0.114 * b;
   return (luma < 128.0); // True if dark
  }

color LerpColor(color a, color b, double t)
  {
   if(t < 0.0)
      t = 0.0;
   if(t > 1.0)
      t = 1.0;
   int r  = (int)((1.0 - t) * (a & 0xFF) + t * (b & 0xFF));
   int g  = (int)((1.0 - t) * ((a >> 8) & 0xFF) + t * ((b >> 8) & 0xFF));
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
//| Order Flow Strength Score (0-100).                              |
//|   >50 = net bullish  |  <50 = net bearish  |  50 = neutral      |
//|                                                                  |
//| SORT IS DESCENDING: levels[0]=bar HIGH, levels[len-1]=bar LOW   |
//|                                                                  |
//| Component breakdown:                                            |
//|  A. Delta ratio       — directional by sign          [0..1]     |
//|  B. Imbalance balance — (buyImb-sellImb)/total       [0..1]     |
//|  C. Stacked imbalance — buy=1.0, sell=0.0, mixed=0.5            |
//|  D. Absorption (position-aware) — LOW=1.0, HIGH=0.0, both=0.5  |
//+------------------------------------------------------------------+
int ComputeOFScore(int bi)
  {
   int  len   = g_bars[bi].level_count;
   long tvol  = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0)
      return 50;

   // A: delta ratio [-1,+1] → [0,1]
   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio = MathMax(-1.0, MathMin(1.0, rawDr));
   double cDelta = (dRatio + 1.0) * 0.5;

   // B: directional imbalance balance → [0,1]
   int  imbBuy = 0, imbSell = 0;
   bool hasStackBuy = false, hasStackSell = false;
   for(int i = 0; i < len; i++)
     {
      if(g_bars[bi].levels[i].is_imb_buy)          imbBuy++;
      if(g_bars[bi].levels[i].is_imb_sell)         imbSell++;
      if(g_bars[bi].levels[i].is_stacked_imb_buy)  hasStackBuy  = true;
      if(g_bars[bi].levels[i].is_stacked_imb_sell) hasStackSell = true;
     }
   int totalImb = imbBuy + imbSell;
   double cImb = 0.5;
   if(totalImb > 0)
     {
      double rawImb = ((double)(imbBuy - imbSell) / (double)totalImb + 1.0) * 0.5;
      cImb = MathIsValidNumber(rawImb) ? rawImb : 0.5;
     }

   // C: stacked imbalance direction → [0,1]
   double cStack;
   if     (hasStackBuy  && !hasStackSell) cStack = 1.0;
   else if(hasStackSell && !hasStackBuy)  cStack = 0.0;
   else                                    cStack = 0.5;

   // D: position-aware absorption — where in the bar range it occurs matters
   // DESCENDING sort: levels[0]=HIGH, levels[len-1]=LOW
   //   absorption at LOW  (support)    → bullish conviction  → 1.0
   //   absorption at HIGH (resistance) → bearish conviction  → 0.0
   //   both or neither                 → neutral             → 0.5
   bool absHigh = false, absLow = false;
   {
      int chkA = MathMin(3, len/3 + 1);
      for(int i = 0;        i < chkA; i++) if(g_bars[bi].levels[i].is_absorption) absHigh = true;
      for(int i = len-chkA; i < len;  i++) if(g_bars[bi].levels[i].is_absorption) absLow  = true;
     }
   double cAbsorb = (!absLow && !absHigh) ? 0.5
                  : ( absLow && !absHigh)  ? 1.0
                  : (!absLow &&  absHigh)  ? 0.0
                  : 0.5;   // absorption at both extremes = contested = neutral

   double wD = MathMax(0.0, InpOFWtDelta)   / 100.0;
   double wI = MathMax(0.0, InpOFWtImb)     / 100.0;
   double wS = MathMax(0.0, InpOFWtStacked) / 100.0;
   double wA = MathMax(0.0, InpOFWtAbsorb)  / 100.0;
   double wT = wD + wI + wS + wA;
   if(wT <= 0.0) wT = 1.0;

   double raw   = (cDelta * wD + cImb * wI + cStack * wS + cAbsorb * wA) / wT;
   if(!MathIsValidNumber(raw)) raw = 0.5;
   int    score = (int)(raw * 100.0 + 0.5);
   return MathMax(0, MathMin(100, score));
  }

//+------------------------------------------------------------------+
//| CVD Slope — 3-bar recency-weighted cumulative delta momentum     |
//| Returns a signed slope normalised per-bar by total volume.      |
//+------------------------------------------------------------------+
double ComputeCVDSlope(int bi)
  {
   if(bi < 2) return 0.0;
   long v0 = MathMax(1, g_bars[bi].total_vol);
   long v1 = MathMax(1, g_bars[bi-1].total_vol);
   long v2 = MathMax(1, g_bars[bi-2].total_vol);
   double nd0 = (double)g_bars[bi].total_delta   / v0;
   double nd1 = (double)g_bars[bi-1].total_delta / v1;
   double nd2 = (double)g_bars[bi-2].total_delta / v2;
   if(!MathIsValidNumber(nd0)) nd0 = 0.0;
   if(!MathIsValidNumber(nd1)) nd1 = 0.0;
   if(!MathIsValidNumber(nd2)) nd2 = 0.0;
   return (2.0 * (nd0 - nd1) + (nd1 - nd2)) / 3.0;
  }

//+------------------------------------------------------------------+
//| HFT Multi-Factor Signal Score                                    |
//| Returns -100 (strong sell) to +100 (strong buy).               |
//| 6 independently-sourced order-flow components:                  |
//|   C1 OFS ratio (30%) · C2 Delta exhaustion/divergence (20%)    |
//|   C3 POC gravity (15%) · C4 Absorption extremes (10%)          |
//|   C5 Bid/Ask exhaustion (10%) · C6 CVD momentum slope (15%)    |
//+------------------------------------------------------------------+
double ComputeHFTSignal(int bi, int preOFS = -1)
  {
   int  len  = g_bars[bi].level_count;
   long tvol = g_bars[bi].total_vol;
   if(len == 0 || tvol == 0) return 0.0;

   // C1: OFS Score (30%)
   double c1 = ((preOFS >= 0 ? preOFS : ComputeOFScore(bi)) - 50.0) / 50.0;

   // C2: Delta exhaustion / divergence (20%)
   double rawDr = (double)g_bars[bi].total_delta / (double)tvol;
   if(!MathIsValidNumber(rawDr)) rawDr = 0.0;
   double dRatio2 = MathMax(-1.0, MathMin(1.0, rawDr));
   double c2 = g_bars[bi].is_delta_divergence ? -dRatio2 : dRatio2;

   // C3: POC gravity (15%) — POC position within bar range
   // levels[] is sorted price-ascending (levels[0]=bar LOW, levels[len-1]=bar HIGH)
   double c3 = 0.0;
   if(g_bars[bi].poc_idx >= 0 && len > 2)
     {
      double range  = g_bars[bi].high - g_bars[bi].low;
      double pocPos = (range > g_step)
                      ? (g_bars[bi].levels[g_bars[bi].poc_idx].price - g_bars[bi].low) / range
                      : 0.5;
      c3 = -(pocPos * 2.0 - 1.0);
     }

   // C4: Absorption at extremes (10%)
   // *** SORT IS DESCENDING: levels[0]=bar HIGH, levels[len-1]=bar LOW ***
   // Absorption at bar LOW  (support)    → large passive buyers defending → BULLISH  → +1.0
   // Absorption at bar HIGH (resistance) → large passive sellers defending → BEARISH  → -1.0
   double c4 = 0.0;
   {
      int  chk    = MathMin(3, len/3 + 1);
      bool absHigh = false;  // absorption at bar HIGH (levels[0..chk])
      bool absLow  = false;  // absorption at bar LOW  (levels[len-chk..len-1])
      for(int i = 0;        i < chk;  i++)   // HIGH end: levels[0] is highest price
         if(g_bars[bi].levels[i].is_absorption) absHigh = true;
      for(int i = len-chk; i < len;  i++)    // LOW end:  levels[len-1] is lowest price
         if(g_bars[bi].levels[i].is_absorption) absLow  = true;
      if(absLow  && !absHigh) c4 = +1.0;    // buyers absorbed at support  → bullish
      else if(absHigh && !absLow) c4 = -1.0;// sellers absorbed at resistance → bearish
     }

   // C5: Bid/Ask exhaustion (10%)
   // Ask exhaustion at HIGH → buyers dried up at resistance → BEARISH → -1.0
   // Bid exhaustion at LOW  → sellers dried up at support   → BULLISH → +1.0
   double c5 = 0.0;
   {
      bool exhAsk = false, exhBid = false;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].is_exhaustion_ask) exhAsk = true;
         if(g_bars[bi].levels[i].is_exhaustion_bid) exhBid = true;
        }
      if(exhBid && !exhAsk) c5 = +1.0;   // bid exhaustion at low → bullish
      if(exhAsk && !exhBid) c5 = -1.0;   // ask exhaustion at high → bearish
     }

   // C6: 3-bar normalised CVD momentum slope (12%)
   double c6 = 0.0;
   if(bi >= 2)
     {
      double slope = ComputeCVDSlope(bi);
      c6 = MathMax(-1.0, MathMin(1.0, slope * 2.25));
     }

   // C7: Unfinished auction at extremes (10%)
   // Unfinished at HIGH → price reached top with both sides active → buying trapped → BEARISH
   // Unfinished at LOW  → price reached bottom with both sides active → selling trapped → BULLISH
   // SORT IS DESCENDING: levels[0]=HIGH, levels[len-1]=LOW
   double c7 = 0.0;
   if(len >= 2)
     {
      bool unfHigh = g_bars[bi].levels[0].is_unfinished_hi;
      bool unfLow  = g_bars[bi].levels[len-1].is_unfinished_lo;
      if(unfLow  && !unfHigh) c7 = +1.0;   // sellers trapped at low → bullish
      else if(unfHigh && !unfLow) c7 = -1.0;// buyers trapped at high → bearish
     }

   // Weights: C1(28%) C2(18%) C3(12%) C4(10%) C5(10%) C6(12%) C7(10%) = 100%
   const double w1=0.28, w2=0.18, w3=0.12, w4=0.10, w5=0.10, w6=0.12, w7=0.10;
   double raw = c1*w1 + c2*w2 + c3*w3 + c4*w4 + c5*w5 + c6*w6 + c7*w7;
   if(!MathIsValidNumber(raw)) raw = 0.0;
   return MathMax(-1.0, MathMin(1.0, raw)) * 100.0;
  }

//+------------------------------------------------------------------+
//| Adaptive Threshold — scales signal threshold with ATR volatility |
//+------------------------------------------------------------------+
int ComputeAdaptiveThreshold()
  {
   if(!InpAdaptiveThreshold)
      return g_signalThreshold;

   int tMin = (int)MathRound(InpAdaptiveThreshMin);
   int tMax = (int)MathRound(InpAdaptiveThreshMax);
   if(tMin < 1)  tMin = 1;
   if(tMax > 99) tMax = 99;
   if(tMin >= tMax)
      return g_signalThreshold;

   double atrVal = 0.0;
   if(g_handleATR != INVALID_HANDLE)
     {
      double atrBuf[];
      if(CopyBuffer(g_handleATR, 0, 1, 1, atrBuf) == 1)
         atrVal = atrBuf[0];
     }
   if(atrVal <= 0.0)
      return g_signalThreshold;

   double atrPips = atrVal / (g_Pip > 0.0 ? g_Pip : _Point);
   double lo = 5.0, hi = 50.0;
   double x  = (atrPips - lo) / (hi - lo);
   if(x < 0.0) x = 0.0;
   if(x > 1.0) x = 1.0;

   int thr = (int)MathRound(tMin + x * (tMax - tMin));
   return MathMax(1, MathMin(99, thr));
  }

//+------------------------------------------------------------------+
//| GetConvictionResult — label and component count from bar flags   |
//| SORT IS DESCENDING: levels[0]=HIGH, levels[len-1]=LOW            |
//+------------------------------------------------------------------+
ConvictionResult GetConvictionResult(int bi, bool isBuy)
  {
   ConvictionResult out;
   out.label = "";
   out.componentCount = 0;

   if(bi < 0 || bi >= ArraySize(g_bars)) return out;
   if(!g_bars[bi].sorted) ComputeBarSignals(bi);

   // Component: Delta divergence (signal that the move may be fading)
   if(g_bars[bi].is_delta_divergence)
     { out.label += (out.label==""?"":"+") + string("DeltaDiv"); out.componentCount++; }

   // Component: Naked POC — unfilled high-volume magnet from prior bar
   if(g_bars[bi].is_naked_poc)
     { out.label += (out.label==""?"":"+") + string("NakedPOC"); out.componentCount++; }

   // Component: directional stacked imbalance present
   bool hasStackDir = false;
   for(int i = 0; i < g_bars[bi].level_count; i++)
     {
      if( isBuy && g_bars[bi].levels[i].is_stacked_imb_buy)  { hasStackDir=true; break; }
      if(!isBuy && g_bars[bi].levels[i].is_stacked_imb_sell) { hasStackDir=true; break; }
     }
   if(hasStackDir)
     { out.label += (out.label==""?"":"+") + string(isBuy ? "StackBuy" : "StackSell"); out.componentCount++; }

   // Component: absorption at the correct extreme for the signal direction
   // DESCENDING sort: levels[0]=HIGH, levels[len-1]=LOW
   //   Buy signal needs absorption at LOW (support)
   //   Sell signal needs absorption at HIGH (resistance)
   bool absHigh=false, absLow=false;
   int  len  = g_bars[bi].level_count;
   int  chk  = MathMin(3, len/3 + 1);
   for(int i = 0;     i < chk; i++) if(i < len && g_bars[bi].levels[i].is_absorption) absHigh = true;
   for(int i = len-chk; i < len; i++) if(i >= 0 && g_bars[bi].levels[i].is_absorption) absLow = true;
   if((isBuy && absLow) || (!isBuy && absHigh))
     { out.label += (out.label==""?"":"+") + string(isBuy ? "AbsLow" : "AbsHigh"); out.componentCount++; }

   // Component: unfinished auction at the correct extreme
   // DESCENDING sort: levels[0]=HIGH (unfinished_hi), levels[len-1]=LOW (unfinished_lo)
   //   Buy  signal: sellers trapped at LOW (unfinished_lo) → bullish confirmation
   //   Sell signal: buyers trapped at HIGH (unfinished_hi) → bearish confirmation
   if(len >= 2)
     {
      bool unfBull = g_bars[bi].levels[len-1].is_unfinished_lo;  // sellers trapped at low
      bool unfBear = g_bars[bi].levels[0].is_unfinished_hi;      // buyers trapped at high
      if((isBuy && unfBull) || (!isBuy && unfBear))
        { out.label += (out.label==""?"":"+") + string(isBuy ? "UnfLow" : "UnfHigh"); out.componentCount++; }
     }

   if(out.label == "") out.label = "Base";
   return out;
  }

//+------------------------------------------------------------------+
//| DrawRings — Bookmap-style concentric ring ball                   |
//| Bright core dot + fading rings — used for signal markers.       |
//+------------------------------------------------------------------+
void DrawRings(int xc, int yc, int maxR, color col, int alpha)
  {
   int rings = InpSigRingCount;
   if(rings < 1) rings = 1;
   int thick = InpSigRingThickness;
   if(thick < 1) thick = 1;

   for(int r = 0; r < rings; r++)
     {
      double frac = (double)(r + 1) / (double)rings;
      int rad = (int)(maxR * frac);
      if(rad < 2) rad = 2;

      int ringAlpha = (int)(alpha * (1.0 - frac * 0.5));
      if(ringAlpha < 10) ringAlpha = 10;

      for(int t = 0; t < thick; t++)
        {
         int rr = rad + t;
         if(rr > 0)
            canvas.Circle(xc, yc, rr, FpARGB(col, ringAlpha));
        }
     }
   int coreR = MathMax(1, maxR / 8);
   canvas.FillCircle(xc, yc, coreR, FpARGB(clrWhite, alpha / 2));
  }

//+------------------------------------------------------------------+
//| EvalAndFireSignal                                               |
//| Evaluates the live bar, applies spacing + conviction gating,    |
//| fires sound alert + places a chart OBJ_ARROW for each signal.   |
//| Called from Render() — no canvas interaction here.             |
//+------------------------------------------------------------------+
void EvalAndFireSignal()
  {
   if(!g_signalsEnabled)
      return;
   int nBars = ArraySize(g_bars);
   if(nBars == 0)
      return;

   int bi = nBars - 1;   // live (forming) bar
   if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0)
      return;

   if(!g_bars[bi].sorted)
      ComputeBarSignals(bi);

   // Cache guard: skip re-evaluation at identical volume
   if(bi == g_sigCacheBarIdx && g_bars[bi].total_vol == g_sigCacheVol)
      return;
   g_sigCacheBarIdx = bi;
   g_sigCacheVol    = g_bars[bi].total_vol;

   // ── Production filter 1: minimum bar range ────────────────────────
   // Don't fire on inside bars / flat market — no real order flow present
   if(InpMinBarRangePts > 0)
     {
      double rangePts = (g_bars[bi].high - g_bars[bi].low) / _Point;
      if(rangePts < (double)InpMinBarRangePts)
         return;
     }

   // Time-based spacing gate
   if(g_lastSignalBarTime > 0)
     {
      int barsSinceLast = iBarShift(_Symbol, PERIOD_CURRENT, g_lastSignalBarTime);
      if(barsSinceLast >= 0 && barsSinceLast < g_signalFreqBars)
         return;
     }

   int    ofsScore = ComputeOFScore(bi);
   double hftScore = ComputeHFTSignal(bi, ofsScore);

   int effThresh = ComputeAdaptiveThreshold();

   bool isBuySignal  = (hftScore >=  (double)effThresh);
   bool isSellSignal = (hftScore <= -(double)effThresh);
   if(!isBuySignal && !isSellSignal)
      return;

   // ── Production filter 2: close must confirm direction ────────────
   // For buys: close should be in upper 40% of bar (bullish close confirms strength)
   // For sells: close should be in lower 40% of bar (bearish close confirms weakness)
   // This eliminates signals where price reversed intra-bar after the order flow formed
   if(InpRequireCloseSide && g_bars[bi].high > g_bars[bi].low)
     {
      int sh = iBarShift(_Symbol, PERIOD_CURRENT, g_bars[bi].bar_time);
      if(sh >= 0)
        {
         double cls   = iClose(_Symbol, PERIOD_CURRENT, sh);
         double range = g_bars[bi].high - g_bars[bi].low;
         double pos   = (cls - g_bars[bi].low) / range;  // 0=at low, 1=at high
         if(isBuySignal  && pos < 0.60) { isBuySignal  = false; }
         if(isSellSignal && pos > 0.40) { isSellSignal = false; }
         if(!isBuySignal && !isSellSignal) return;
        }
     }

   // Conviction diversity gate
   ConvictionResult conv = GetConvictionResult(bi, isBuySignal);
   if(conv.componentCount < InpMinConvictionComp)
      return;

   g_lastSignalBarTime = g_bars[bi].bar_time;

   int displayScore = (int)MathRound(isBuySignal ? hftScore : -hftScore);

   // ── Sound alert ──────────────────────────────────────────────────
   if(isBuySignal)
      PlaySound(InpSignalBuySound);
   else
      PlaySound(InpSignalSellSound);

   // ── MT5 Push Notification ─────────────────────────────────────────
   // Delivered to the MetaTrader 5 mobile app.
   // Prerequisites:
   //   1. MetaTrader 5 app installed and logged in on your phone.
   //   2. Your MetaQuotes ID entered in:
   //      Terminal → Tools → Options → Notifications → MetaQuotes ID
   //   3. "Enable Push Notifications" checkbox ticked in the same panel.
   //
   // InpPushOnlyNewBar = true  → at most ONE push per candle open,
   //                            prevents your phone buzzing every tick
   //                            while the bar is still forming.
   // InpPushOnlyNewBar = false → push fires on every qualifying tick
   //                            (useful for scalping on very fast charts).
   if(InpPushNotify)
     {
      bool sendPush = true;
      if(InpPushOnlyNewBar && g_lastPushBarTime == g_bars[bi].bar_time)
         sendPush = false;   // already pushed for this bar — skip

      if(sendPush)
        {
         string tf = EnumToString(Period());
         StringReplace(tf, "PERIOD_", "");

         // NakedPOC and DeltaDiv flags add context traders look for
         string nakedStr = g_bars[bi].is_naked_poc        ? " NakedPOC" : "";
         string divStr   = g_bars[bi].is_delta_divergence ? " DeltaDiv" : "";
         string flagStr  = (StringLen(nakedStr) + StringLen(divStr) > 0)
                           ? StringFormat(" [%s%s ]", nakedStr, divStr) : "";

         string pushMsg = StringFormat(
            "%s %s  %s %s%s\n"
            "HFT: %d  |  OFS: %d  |  Thresh: %d\n"
            "Conv: %s\n"
            "Price: %s  |  %s",
            isBuySignal ? "\xE2\x96\xB2" : "\xE2\x96\xBC",   // ▲ / ▼  (UTF-8 safe)
            isBuySignal ? "BUY" : "SELL",
            _Symbol, tf, flagStr,
            displayScore, ofsScore, effThresh,
            conv.label,
            DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
            TimeToString(g_bars[bi].bar_time, TIME_DATE|TIME_MINUTES));

         if(!SendNotification(pushMsg))
            Print("Footprint v6 — Push notification failed (error=", GetLastError(),
                  "). Go to Tools → Options → Notifications and verify your MetaQuotes ID.");
         else
            g_lastPushBarTime = g_bars[bi].bar_time;
        }
     }

   // Chart arrow — unique name per bar_time prevents duplicate objects on same bar
   string objName = StringFormat("FP_Sig_%s_%I64d",
                                 isBuySignal ? "B" : "S",
                                 (long)g_bars[bi].bar_time);

   if(ObjectFind(g_chart, objName) < 0)
     {
      double arrowPrice = isBuySignal ? g_bars[bi].low  - g_step * 2.0
                                      : g_bars[bi].high + g_step * 2.0;
      color  arrowCol   = isBuySignal ? InpSignalBuyColor : InpSignalSellColor;

      if(ObjectCreate(g_chart, objName, OBJ_ARROW, 0,
                      g_bars[bi].bar_time, arrowPrice))
        {
         ObjectSetInteger(g_chart, objName, OBJPROP_ARROWCODE,  108);
         ObjectSetInteger(g_chart, objName, OBJPROP_COLOR,      arrowCol);
         ObjectSetInteger(g_chart, objName, OBJPROP_WIDTH,      2);
         ObjectSetInteger(g_chart, objName, OBJPROP_BACK,       false);
         ObjectSetInteger(g_chart, objName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(g_chart, objName, OBJPROP_HIDDEN,     false);
         ObjectSetString( g_chart, objName, OBJPROP_TOOLTIP,
                          StringFormat(
                          "%s SIGNAL  %s\n"
                          "HFT: %d  OFS: %d  Thresh: %d\n"
                          "Conviction: %s (%d src)\n"
                          "NakedPOC: %s  DeltaDiv: %s\n"
                          "Price: %s  Bar: %s",
                          isBuySignal ? "BUY" : "SELL",
                          _Symbol,
                          displayScore, ofsScore, effThresh,
                          conv.label, conv.componentCount,
                          g_bars[bi].is_naked_poc        ? "YES" : "NO",
                          g_bars[bi].is_delta_divergence ? "YES" : "NO",
                          DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
                          TimeToString(g_bars[bi].bar_time, TIME_DATE|TIME_MINUTES)));
        }
     }
  }

//+------------------------------------------------------------------+
//| DrawSignalMarkersPass                                           |
//| Visual-only pass: renders signal ring + compact hint card for   |
//| every qualifying bar in the visible window.                     |
//| Decoupled from DrawBar so it works even in profile-only mode.  |
//+------------------------------------------------------------------+
void DrawSignalMarkersPass(int visBars, int firstVis, int barW)
  {
   if(!g_signalsEnabled)
      return;

   int cw = canvas.Width();
   int ch = canvas.Height();

   int lastDrawnBar = -9999;

   // Compact hint overlap avoidance arrays
   int placedCount = 0;
   int placedX[64];
   int placedY[64];
   int placedHalfW[64];

   for(int v = 0; v < visBars; v++)
     {
      int shift = firstVis - v;
      if(shift < 0)
         continue;

      datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);
      if(bt == 0) continue;
      int bi = FindBarIndex(bt);
      if(bi < 0) continue;
      if(g_bars[bi].level_count == 0 || g_bars[bi].total_vol == 0)
         continue;

      if(!g_bars[bi].sorted)
         ComputeBarSignals(bi);

      bool freqGatePass = (bi - lastDrawnBar >= g_signalFreqBars);
      if(!freqGatePass)
         continue;

      int    ofsScore    = ComputeOFScore(bi);
      double hftScore    = ComputeHFTSignal(bi, ofsScore);
      int    effThr      = ComputeAdaptiveThreshold();   // match EvalAndFireSignal exactly
      bool   isBuySignal = (hftScore >=  (double)effThr);
      bool   isSellSignal= (hftScore <= -(double)effThr);
      if(!isBuySignal && !isSellSignal)
         continue;

      // ── Mirror production filters from EvalAndFireSignal ─────────
      if(InpMinBarRangePts > 0)
        {
         double rangePts = (g_bars[bi].high - g_bars[bi].low) / _Point;
         if(rangePts < (double)InpMinBarRangePts) continue;
        }
      if(InpRequireCloseSide && g_bars[bi].high > g_bars[bi].low)
        {
         double cls   = iClose(_Symbol, PERIOD_CURRENT, shift);
         double range = g_bars[bi].high - g_bars[bi].low;
         double pos   = (cls - g_bars[bi].low) / range;
         if(isBuySignal  && pos < 0.60) isBuySignal  = false;
         if(isSellSignal && pos > 0.40) isSellSignal = false;
         if(!isBuySignal && !isSellSignal) continue;
        }

      // Conviction diversity visual gate (same as fire gate)
      if(InpMinConvictionComp > 0)
        {
         ConvictionResult cv = GetConvictionResult(bi, isBuySignal);
         if(cv.componentCount < InpMinConvictionComp) continue;
        }

      lastDrawnBar = bi;

      // Bar geometry
      int wx, wy_h, wy_l, tmpX, tmpY;
      ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].high, wx, wy_h);
      ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].low,  tmpX, wy_l);
      ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, tmpX, tmpY);

      int halfW  = (int)(barW * 0.45);
      if(halfW < 14) halfW = 14;
      int barCX  = tmpX;
      int barTop = MathMin(wy_h, wy_l);
      int barBot = MathMax(wy_h, wy_l);

      color sigColor = isBuySignal ? InpSignalBuyColor : InpSignalSellColor;
      int   opaScale = g_opacity;

      // Draw Bookmap-style ring ball above/below the bar
      int ballRadius = MathMax(InpSigBallMinRadius,
                               MathMin(InpSigBallRadius, barW / 2));
      int ballY = isBuySignal ? (barBot + ballRadius + 4)
                              : (barTop - ballRadius - 4);
      if(ballY > 4 && ballY < ch - 4)
         DrawRings(barCX, ballY, ballRadius, sigColor, (230 * opaScale) / 255);

      // Compact hint text with conviction label
      uint   cText   = FpARGB(sigColor, 245);
      uint   cShadow = FpARGB(clrBlack, 170);
      int    hftDisp = (int)MathRound(isBuySignal ? hftScore : -hftScore);
      string arrowStr = isBuySignal ? ShortToString(0x25B2) : ShortToString(0x25BC);
      double px       = iClose(_Symbol, PERIOD_CURRENT, shift);
      string pxStr    = DoubleToString(px, _Digits);
      ConvictionResult cvDisp = GetConvictionResult(bi, isBuySignal);
      string hint = StringFormat("%s HFT:%d OFS:%d | %s @ %s",
                                 arrowStr, hftDisp, ofsScore,
                                 cvDisp.label, pxStr);

      int fontSize = 10;
      if(barW >= 18)      fontSize = 13;
      else if(barW >= 12) fontSize = 11;
      canvas.FontSet("Consolas", fontSize, FW_BOLD);

      int twHint = 0, thHint = 0;
      canvas.TextSize(hint, twHint, thHint);
      int boxW = (twHint > 0 ? twHint : barW * 2);
      int boxH = (thHint > 0 ? thHint : 12);
      const int gapY  = 2;
      const int stepY = 12;

      int hx = barCX;
      int hy = isBuySignal ? (barBot + ballRadius * 2 + gapY + 6)
                           : (barTop - ballRadius * 2 - boxH - gapY - 6);

      int halfBoxW = boxW / 2;
      if(hx < 2 + halfBoxW) hx = 2 + halfBoxW;
      if(hx > cw - 2 - halfBoxW) hx = cw - 2 - halfBoxW;
      if(hy < 2) hy = 2;
      if(hy > ch - boxH - 2) hy = ch - boxH - 2;

      // Avoid overlapping with previously placed hints
      int tries = 0;
      while(tries < 10)
        {
         bool conflict = false;
         int  maxCheck = MathMin(placedCount, 64);
         for(int i = 0; i < maxCheck; i++)
           {
            int minDx = halfBoxW + placedHalfW[i] + 2;
            if(MathAbs(hx - placedX[i]) <= minDx && MathAbs(hy - placedY[i]) <= (boxH + 1))
              { conflict = true; break; }
           }
         if(!conflict) break;
         hy += isBuySignal ? stepY : -stepY;
         if(hy < 2 || hy > ch - boxH - 2) break;
         tries++;
        }

      if(placedCount < 64)
        {
         placedX[placedCount] = hx;
         placedY[placedCount] = hy;
         placedHalfW[placedCount] = halfBoxW;
         placedCount++;
        }

      canvas.TextOut(hx + 1, hy + 1, hint, cShadow, TA_CENTER | TA_TOP);
      canvas.TextOut(hx,     hy,     hint, cText,   TA_CENTER | TA_TOP);
     }
  }

//+------------------------------------------------------------------+
//| Footprint Bar Renderer (Volume / Delta / Bid x Ask)              |
//+------------------------------------------------------------------+
void DrawBar(int bi, int shift, int barW)
  {
   int len = g_bars[bi].level_count;
   if(len == 0)
      return;

   // Recompute signals only when needed (tick accumulation marks sorted=false)
   if(!g_bars[bi].sorted)
      ComputeBarSignals(bi);

   int pocIdx  = g_bars[bi].poc_idx;
   int vaLoIdx = g_bars[bi].va_lo_idx;
   int vaHiIdx = g_bars[bi].va_hi_idx;

   long maxLevelVol = 1;
   long maxBidVol   = 1;
   long maxAskVol   = 1;
   long maxAbsDelta = 1;
   for(int i = 0; i < len; i++)
     {
      PriceLevel plMax = g_bars[bi].levels[i];
      if(plMax.total_vol > maxLevelVol)
         maxLevelVol = plMax.total_vol;
      if(plMax.bid_vol > maxBidVol)
         maxBidVol = plMax.bid_vol;
      if(plMax.ask_vol > maxAskVol)
         maxAskVol = plMax.ask_vol;
      long ad = (plMax.delta >= 0 ? plMax.delta : -plMax.delta);
      if(ad > maxAbsDelta)
         maxAbsDelta = ad;
     }
   if(maxAbsDelta <= 0)
      maxAbsDelta = 1;

   datetime bt = iTime(_Symbol, PERIOD_CURRENT, shift);

   // Candle wicks (drawn last)
   int wx, wy_h, wy_l;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].high, wx, wy_h);
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].low, wx, wy_l);

   // --- X geometry ---
   int halfW = (int)(barW * 0.45);
   if(halfW < 14)
      halfW = 14;
   int xc, yd;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, xc, yd);
   int x1   = xc - halfW;
   int x2   = xc + halfW;
   int midX = (x1 + x2) / 2;

   // --- Y layout (grid snap) ---
   EnsureScratch(len);
   int natY1, natY2, tmpX;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price, tmpX, natY1);
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[0].price - g_step, tmpX, natY2);
   int cellH = MathAbs(natY2 - natY1);
   if(cellH < FP_MIN_CELL_H)
      cellH = FP_MIN_CELL_H;

   int midIdx = len / 2;
   int anchorY;
   ChartTimePriceToXY(g_chart, g_sub, bt, g_bars[bi].levels[midIdx].price, tmpX, anchorY);
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

   int   opaScale     = g_opacity;
   bool  isBullish    = g_bars[bi].is_bullish;
   color sentimentCol = isBullish ? InpBullishFrame : InpBearishFrame;

   // Delta Gradient — full-bar tint proportional to delta magnitude
   if(InpDeltaGradient && g_bars[bi].total_vol > 0)
     {
      double dRat   = (double)MathAbs(g_bars[bi].total_delta) / (double)g_bars[bi].total_vol;
      int    gAlpha = (int)(InpDeltaGradMaxAlpha * MathMin(1.0, dRat * 2.5));
      gAlpha        = (gAlpha * opaScale) / 255;
      color  gCol   = (g_bars[bi].total_delta >= 0) ? InpDeltaGradBull : InpDeltaGradBear;
      int    barTop = g_scratchY1[0];
      int    barBot = g_scratchY2[len - 1];
      int    bandH  = MathMax(1, (barBot - barTop) / 4);
      for(int band = 0; band < 4; band++)
        {
         int bAlpha = gAlpha - (band * gAlpha / 5);
         if(bAlpha < 0) bAlpha = 0;
         canvas.FillRectangle(x1, barTop + band * bandH,
                              x2, MathMin(barBot, barTop + (band + 1) * bandH),
                              FpARGB(gCol, bAlpha));
        }
     }

   // Font size scales with cell height and available width (min 10px to avoid blur)
   int maxH = (int)(cellH * 0.65);
   int maxW;
   if(g_mode == FOOT_CHART_BIDASK)
      maxW = (int)(halfW * 0.75);
   else
      maxW = (int)(halfW * 1.50);
   int cellFontSz = MathMin(MathMin(maxH, maxW), 36);

   // Skip text if font would be below 10px (unreadably blurry on canvas)
   bool  skipText     = g_hideText || g_userHideText || (cellFontSz < 10);

   if(!skipText)
      canvas.FontSet("Consolas", cellFontSz, FW_BOLD);

   for(int i = 0; i < len; i++)
     {
      PriceLevel pl = g_bars[bi].levels[i];

      // only within bar's high/low
      if(pl.price < g_bars[bi].low - g_step * 0.5 ||
         pl.price > g_bars[bi].high + g_step * 0.5)
         continue;

      int  y_top = g_scratchY1[i];
      int  y_bot = g_scratchY2[i];
      bool inVA  = (i >= vaLoIdx && i <= vaHiIdx);
      int  alpha = inVA ? (int)InpBgAlpha : (int)InpVAOffAlpha;
      alpha      = (alpha * opaScale) / 255;

      double levelIntensity =
         (double)pl.total_vol / (double)maxLevelVol;
      double bidIntensity =
         (maxBidVol > 0) ? (double)pl.bid_vol / (double)maxBidVol : 0.0;
      double askIntensity =
         (maxAskVol > 0) ? (double)pl.ask_vol / (double)maxAskVol : 0.0;

      // Backgrounds depending on chart mode (reference: red/green fill for imbalance)
      if(g_mode == FOOT_CHART_BIDASK)
        {
         color bidCol = LerpColor(InpBidBaseColor, InpBidHighColor, bidIntensity);
         color askCol = LerpColor(InpAskBaseColor, InpAskHighColor, askIntensity);
         if(!inVA)
           {
            bidCol = InpOutOfVAColor;
            askCol = InpOutOfVAColor;
           }
         // Imbalance: full cell fill (red sell / green buy) per reference
         if(pl.is_imb_sell)
           {
            bidCol = InpImbSellColor;
            askCol = InpImbSellColor;
           }
         if(pl.is_imb_buy)
           {
            bidCol = InpImbBuyColor;
            askCol = InpImbBuyColor;
           }

         canvas.FillRectangle(x1, y_top, midX, y_bot, FpARGB(bidCol, alpha));
         canvas.FillRectangle(midX + 1, y_top, x2, y_bot, FpARGB(askCol, alpha));
         canvas.LineHorizontal(x1, x2, y_bot, FpARGB(InpGridColor, 35));
         canvas.LineVertical(midX, y_top, y_bot, FpARGB(InpGridColor, 35));
        }
      else if(g_mode == FOOT_CHART_VOLUME)
        {
         // Directional volume coloring: ask-dominant levels glow teal, bid-dominant glow purple.
         // Imbalance cells override with their dedicated highlight color (same as BidAsk mode).
         color volCol;
         if(inVA)
           {
            if(pl.is_imb_sell)
               volCol = InpImbSellColor;
            else if(pl.is_imb_buy)
               volCol = InpImbBuyColor;
            else
              {
               double askRatio  = (pl.total_vol > 0) ? (double)pl.ask_vol / (double)pl.total_vol : 0.5;
               color  bidLerped = LerpColor(InpBidBaseColor, InpBidHighColor, levelIntensity);
               color  askLerped = LerpColor(InpAskBaseColor, InpAskHighColor, levelIntensity);
               volCol = LerpColor(bidLerped, askLerped, askRatio);
              }
           }
         else
            volCol = InpOutOfVAColor;
         canvas.FillRectangle(x1, y_top, x2, y_bot, FpARGB(volCol, alpha));
         canvas.LineHorizontal(x1, x2, y_bot, FpARGB(InpGridColor, 35));
        }
      else // FOOT_CHART_DELTA
        {
         double dNorm = (double)MathAbs(pl.delta) / (double)maxAbsDelta;
         color  base, high;
         if(InpDeltaCellColor)
           {
            // Pure delta mode: green cells where ask>bid, red where bid>ask
            base = (pl.delta >= 0) ? InpDeltaCellBull : InpDeltaCellBear;
            high = (pl.delta >= 0) ? InpImbBuyColor   : InpImbSellColor;
           }
         else
           {
            base = (pl.delta >= 0 ? InpAskBaseColor : InpBidBaseColor);
            high = (pl.delta >= 0 ? InpAskHighColor : InpBidHighColor);
           }
         color  dCol  = LerpColor(base, high, dNorm);
         if(!inVA)
            dCol = InpOutOfVAColor;
         canvas.FillRectangle(x1, y_top, x2, y_bot, FpARGB(dCol, alpha));
         canvas.LineHorizontal(x1, x2, y_bot, FpARGB(InpGridColor, 35));
        }

      // POC frame — amber-gold double rectangle
      if(i == pocIdx)
        {
         canvas.Rectangle(x1,     y_top,     x2,     y_bot,     FpARGB(InpPOCColor, 255));
         canvas.Rectangle(x1 + 1, y_top + 1, x2 - 1, y_bot - 1, FpARGB(InpPOCColor, 140));
        }

      // Naked POC — orange-red outer glow: POC not yet revisited by price
      // Drawn as a dashed outer frame (segments of 5 on, 4 off) so it remains
      // visually distinct from the solid amber POC frame inside it.
      if(InpShowNakedPOC && i == pocIdx && g_bars[bi].is_naked_poc)
        {
         int segOn = 5, segOff = 4, segLen = segOn + segOff;
         uint nPOCCol = FpARGB(InpNakedPOCColor, (220 * opaScale) / 255);
         // Top edge
         for(int sx = x1 - 2; sx < x2 + 2; sx += segLen)
            canvas.LineHorizontal(sx, MathMin(sx + segOn - 1, x2 + 2), y_top - 2, nPOCCol);
         // Bottom edge
         for(int sx = x1 - 2; sx < x2 + 2; sx += segLen)
            canvas.LineHorizontal(sx, MathMin(sx + segOn - 1, x2 + 2), y_bot + 2, nPOCCol);
         // Left edge
         for(int sy = y_top - 2; sy < y_bot + 2; sy += segLen)
            canvas.LineVertical(x1 - 2, sy, MathMin(sy + segOn - 1, y_bot + 2), nPOCCol);
         // Right edge
         for(int sy = y_top - 2; sy < y_bot + 2; sy += segLen)
            canvas.LineVertical(x2 + 2, sy, MathMin(sy + segOn - 1, y_bot + 2), nPOCCol);
        }

      // Stacked Imbalances
      // In BidAsk mode: buy on ask (right) half, sell on bid (left) half.
      // In Volume/Delta mode: full-width, buy=right 60% / sell=left 60% to remain distinguishable.
      if(pl.is_stacked_imb_buy)
        {
         int sX = (g_mode == FOOT_CHART_BIDASK) ? midX : (x1 + (x2 - x1) / 5);
         canvas.Rectangle(sX,     y_top,     x2,     y_bot, FpARGB(InpStackedBuyColor, 255));
         canvas.Rectangle(sX + 1, y_top + 1, x2 - 1, y_bot - 1, FpARGB(InpStackedBuyColor, 150));
        }
      if(pl.is_stacked_imb_sell)
        {
         int sX = (g_mode == FOOT_CHART_BIDASK) ? midX : (x2 - (x2 - x1) / 5);
         canvas.Rectangle(x1,     y_top,     sX,     y_bot, FpARGB(InpStackedSellColor, 255));
         canvas.Rectangle(x1 + 1, y_top + 1, sX - 1, y_bot - 1, FpARGB(InpStackedSellColor, 150));
        }

      // Unfinished auctions — 2px thick for visibility
      if(pl.is_unfinished_hi)
        {
         canvas.LineHorizontal(x1, x2, y_top,     FpARGB(InpUnfinishedColor, 210));
         canvas.LineHorizontal(x1, x2, y_top + 1, FpARGB(InpUnfinishedColor, 100));
        }
      if(pl.is_unfinished_lo)
        {
         canvas.LineHorizontal(x1, x2, y_bot,     FpARGB(InpUnfinishedColor, 210));
         canvas.LineHorizontal(x1, x2, y_bot - 1, FpARGB(InpUnfinishedColor, 100));
        }

      // Absorption marker — outer glow ring + softer inner ring
      if(pl.is_absorption)
        {
         canvas.Rectangle(x1 - 1, y_top - 1, x2 + 1, y_bot + 1, FpARGB(InpAbsorptionColor, 220));
         canvas.Rectangle(x1 - 2, y_top - 2, x2 + 2, y_bot + 2, FpARGB(InpAbsorptionColor, 90));
        }

      // HVN: gold inner border (two-pixel)
      if(pl.is_hvn)
        {
         canvas.Rectangle(x1 + 1, y_top + 1, x2 - 1, y_bot - 1, FpARGB(InpHVNColor, 200));
        }

      // LVN: muted dashed-style border (draw corners only)
      if(pl.is_lvn)
        {
         int cSz = MathMin(4, (x2 - x1) / 4);
         canvas.LineHorizontal(x1,        x1 + cSz, y_top, FpARGB(InpLVNColor, 180));
         canvas.LineHorizontal(x2 - cSz, x2,        y_top, FpARGB(InpLVNColor, 180));
         canvas.LineHorizontal(x1,        x1 + cSz, y_bot, FpARGB(InpLVNColor, 180));
         canvas.LineHorizontal(x2 - cSz, x2,        y_bot, FpARGB(InpLVNColor, 180));
        }

      // Text (luminance-based contrast)
      if(!skipText)
        {
         int  yy           = (y_top + y_bot) / 2;
         uint colBaseText  = FpARGB(InpTextBaseColor, (220 * opaScale) / 255);

         if(g_mode == FOOT_CHART_BIDASK)
           {
            // Determine actual cell background colors for contrast check
            color bidBgCol = LerpColor(InpBidBaseColor, InpBidHighColor, bidIntensity);
            color askBgCol = LerpColor(InpAskBaseColor, InpAskHighColor, askIntensity);
            if(!inVA)              { bidBgCol = InpOutOfVAColor; askBgCol = InpOutOfVAColor; }
            if(pl.is_imb_sell)     { bidBgCol = InpImbSellColor; askBgCol = InpImbSellColor; }
            if(pl.is_imb_buy)      { bidBgCol = InpImbBuyColor;  askBgCol = InpImbBuyColor;  }

            uint tCBid = IsColorDark(bidBgCol) ? FpARGB(InpTextDarkBg, (250 * opaScale) / 255)
                                               : FpARGB(InpTextLightBg, (250 * opaScale) / 255);
            uint tCAsk = IsColorDark(askBgCol) ? FpARGB(InpTextDarkBg, (250 * opaScale) / 255)
                                               : FpARGB(InpTextLightBg, (250 * opaScale) / 255);

            // Use base (muted) color for low-activity cells
            if(!pl.is_imb_sell && !pl.is_imb_buy && !pl.is_absorption && i != pocIdx && inVA)
              { tCBid = colBaseText; tCAsk = colBaseText; }

            if(pl.bid_vol > 0)
               canvas.TextOut((x1 + midX) / 2, yy, IntegerToString(pl.bid_vol),
                              tCBid, TA_CENTER | TA_VCENTER);
            if(pl.ask_vol > 0)
               canvas.TextOut((midX + 1 + x2) / 2, yy, IntegerToString(pl.ask_vol),
                              tCAsk, TA_CENTER | TA_VCENTER);
           }
         else if(g_mode == FOOT_CHART_VOLUME)
           {
            color volBgCol;
            if(inVA)
              {
               if(pl.is_imb_sell)
                  volBgCol = InpImbSellColor;
               else if(pl.is_imb_buy)
                  volBgCol = InpImbBuyColor;
               else
                 {
                  double askR    = (pl.total_vol > 0) ? (double)pl.ask_vol / (double)pl.total_vol : 0.5;
                  color  bLerped = LerpColor(InpBidBaseColor, InpBidHighColor, levelIntensity);
                  color  aLerped = LerpColor(InpAskBaseColor, InpAskHighColor, levelIntensity);
                  volBgCol = LerpColor(bLerped, aLerped, askR);
                 }
              }
            else
               volBgCol = InpOutOfVAColor;

            uint tCVol = IsColorDark(volBgCol) ? FpARGB(InpTextDarkBg, (250 * opaScale) / 255)
                                               : FpARGB(InpTextLightBg, (250 * opaScale) / 255);
            // Muted text for ordinary in-VA cells only
            if(!pl.is_imb_sell && !pl.is_imb_buy && !pl.is_absorption && i != pocIdx && inVA)
               tCVol = colBaseText;

            if(pl.total_vol > 0)
               canvas.TextOut((x1 + x2) / 2, yy, IntegerToString((int)pl.total_vol),
                              tCVol, TA_CENTER | TA_VCENTER);
           }
         else // DELTA
           {
            double dNorm2 = (double)MathAbs(pl.delta) / (double)maxAbsDelta;
            color  dBase2, dHigh2;
            if(InpDeltaCellColor)
              {
               dBase2 = (pl.delta >= 0) ? InpDeltaCellBull : InpDeltaCellBear;
               dHigh2 = (pl.delta >= 0) ? InpImbBuyColor   : InpImbSellColor;
              }
            else
              {
               dBase2 = (pl.delta >= 0) ? InpAskBaseColor : InpBidBaseColor;
               dHigh2 = (pl.delta >= 0) ? InpAskHighColor : InpBidHighColor;
              }
            color  dBgCol = LerpColor(dBase2, dHigh2, dNorm2);
            if(!inVA) dBgCol = InpOutOfVAColor;

            uint tCD = IsColorDark(dBgCol) ? FpARGB(InpTextDarkBg, (250 * opaScale) / 255)
                                           : FpARGB(InpTextLightBg, (250 * opaScale) / 255);
            if(dNorm2 < 0.3 && inVA)
               tCD = colBaseText;

            if(pl.delta != 0)
              {
               string dStr = (pl.delta > 0 ? "+" : "") + IntegerToString((int)pl.delta);
               canvas.TextOut((x1 + x2) / 2, yy, dStr,
                              tCD, TA_CENTER | TA_VCENTER);
           }
        }
        }  // end if(!skipText)
     }   // end for(int i = 0; i < len; i++) — per price-level loop

   // Feature 2: Bid/Ask Exhaustion markers — orange line at the cluster boundary
   if(InpExhaustionEnable)
     {
      int exhAskTop = -1, exhAskBot = -1;
      int exhBidTop = -1, exhBidBot = -1;
      for(int i = 0; i < len; i++)
        {
         if(g_bars[bi].levels[i].is_exhaustion_ask)
           {
            if(exhAskTop < 0) exhAskTop = g_scratchY1[i];
            exhAskBot = g_scratchY2[i];
           }
         if(g_bars[bi].levels[i].is_exhaustion_bid)
           {
            if(exhBidTop < 0) exhBidTop = g_scratchY1[i];
            exhBidBot = g_scratchY2[i];
           }
        }
      uint exhCol = FpARGB(InpExhaustionColor, (220 * opaScale) / 255);
      if(exhAskTop >= 0)
        {
         // Ask exhaustion at bar high: draw line at bottom of cluster (where it ended)
         int lineY = exhAskBot;
         canvas.LineHorizontal(x1, x2, lineY,       exhCol);
         canvas.LineHorizontal(x1, x2, lineY + 1,   exhCol);
         // Vertical tick marks at each end (5px tall)
         canvas.LineVertical(x1,     lineY - 2, lineY + 3, exhCol);
         canvas.LineVertical(x1 + 1, lineY - 2, lineY + 3, exhCol);
         canvas.LineVertical(x2,     lineY - 2, lineY + 3, exhCol);
         canvas.LineVertical(x2 - 1, lineY - 2, lineY + 3, exhCol);
        }
      if(exhBidTop >= 0)
        {
         // Bid exhaustion at bar low: draw line at top of cluster (where it started)
         int lineY = exhBidTop;
         canvas.LineHorizontal(x1, x2, lineY,     exhCol);
         canvas.LineHorizontal(x1, x2, lineY + 1, exhCol);
         // Vertical tick marks at each end (5px tall)
         canvas.LineVertical(x1,     lineY - 2, lineY + 3, exhCol);
         canvas.LineVertical(x1 + 1, lineY - 2, lineY + 3, exhCol);
         canvas.LineVertical(x2,     lineY - 2, lineY + 3, exhCol);
         canvas.LineVertical(x2 - 1, lineY - 2, lineY + 3, exhCol);
        }
     }

   // Feature 4: Zero-delta reference line in Delta mode
   if(g_mode == FOOT_CHART_DELTA && InpDeltaCellColor)
     {
      // Find the level with delta closest to zero
      int    zeroIdx = 0;
      long   minAbs  = MathAbs(g_bars[bi].levels[0].delta);
      for(int i = 1; i < len; i++)
        {
         long ad = MathAbs(g_bars[bi].levels[i].delta);
         if(ad < minAbs) { minAbs = ad; zeroIdx = i; }
        }
      // Check if delta crosses sign between adjacent levels
      int zY = (g_scratchY1[zeroIdx] + g_scratchY2[zeroIdx]) / 2;
      uint zCol = FpARGB(InpDeltaZeroLine, (200 * opaScale) / 255);
      // Draw a dashed-style line (segments of 4px on, 3px off)
      int segOn = 4, segOff = 3, segLen = segOn + segOff;
      int lineX = x1;
      while(lineX < x2)
        {
         int segEnd = MathMin(lineX + segOn - 1, x2);
         canvas.LineHorizontal(lineX, segEnd, zY,     zCol);
         canvas.LineHorizontal(lineX, segEnd, zY + 1, zCol);
         lineX += segLen;
        }
     }

   // Session framing (Value Area box)
   if(vaLoIdx >= 0 && vaHiIdx >= 0)
     {
      canvas.Rectangle(x1,     g_scratchY1[vaLoIdx],     x2,     g_scratchY2[vaHiIdx],     FpARGB(sentimentCol, 220));
      canvas.Rectangle(x1 - 1, g_scratchY1[vaLoIdx] - 1, x2 + 1, g_scratchY2[vaHiIdx] + 1, FpARGB(sentimentCol, 80));
     }

   // Delta Divergence marker: orange triangle at the top of the wick
   if(g_bars[bi].is_delta_divergence)
     {
      int tipY = wy_h - 5;
      int triH = 5;
      int triW = 4;
      for(int row = 0; row < triH; row++)
        {
         int hw = (triW * (triH - row)) / triH;
         canvas.LineHorizontal(wx - hw, wx + hw, tipY + row,
                               FpARGB(InpDivergenceColor, 210));
        }
     }

   // Buy/Sell ratio stripe: thin bar at the bottom edge of the bar
   //  Left portion = Ask(buy) volume, right = Bid(sell) volume
   long totalBidAsk = g_bars[bi].total_vol;
   if(totalBidAsk > 0 && len > 0)
     {
      long totalAskAll = 0, totalBidAll = 0;
      for(int i2 = 0; i2 < len; i2++)
        { totalAskAll += g_bars[bi].levels[i2].ask_vol; totalBidAll += g_bars[bi].levels[i2].bid_vol; }
      if(totalAskAll + totalBidAll > 0)
        {
         int stripeY  = g_scratchY2[len - 1] - 3;
         int stripeH  = 3;
         double askRatio = (double)totalAskAll / (totalAskAll + totalBidAll);
         int    splitX   = x1 + (int)((x2 - x1) * askRatio);
         canvas.FillRectangle(x1,          stripeY, splitX, stripeY + stripeH,
                              FpARGB(InpAskHighColor, (200 * opaScale) / 255));
         canvas.FillRectangle(splitX + 1, stripeY, x2,     stripeY + stripeH,
                              FpARGB(InpBidHighColor, (200 * opaScale) / 255));
        }
     }

   // Candle wick on top
   if(InpShowWick)
     {
      uint wickCol = FpARGB(InpWickColor, (210 * g_opacity) / 255);
      canvas.LineVertical(wx, wy_h, wy_l, wickCol);
     }

   // --- Per-bar total volume and delta labels below the bar ---
   if(!skipText)
     {
      int labelY    = g_scratchY2[len - 1] + 2;
      int maxLblH   = (int)(cellH * 0.50);
      int maxLblW   = (int)(barW * 0.25);
      int lblFontSz = MathMin(MathMin(maxLblH, maxLblW), 24);
      if(lblFontSz < 10)
         lblFontSz = 10;
      canvas.FontSet("Consolas", lblFontSz, FW_BOLD);

      // Measure text for background pills
      string volStr   = IntegerToString(g_bars[bi].total_vol);
      long   barDelta = g_bars[bi].total_delta;
      color  deltaCol = (barDelta >= 0) ? InpTextBottomPos : InpTextBottomNeg;
      string deltaStr = (barDelta >= 0 ? "+" : "") + IntegerToString(barDelta);

      int tw1 = 0, th1 = 0, tw2 = 0, th2 = 0;
      canvas.TextSize(volStr,   tw1, th1);
      canvas.TextSize(deltaStr, tw2, th2);
      int lblPad = 3;

      // Dark background pill behind volume label
      int vx = (x1 + x2) / 2;
      canvas.FillRectangle(vx - tw1 / 2 - lblPad, labelY - 1,
                           vx + tw1 / 2 + lblPad, labelY + th1 + 1,
                           FpARGB(C'10,10,14', (200 * opaScale) / 255));
      canvas.TextOut(vx, labelY, volStr,
                     FpARGB(InpTextBottomVol, (220 * opaScale) / 255), TA_CENTER | TA_TOP);

      // Dark background pill behind delta label
      int dLabelY = labelY + th1 + 2;
      canvas.FillRectangle(vx - tw2 / 2 - lblPad, dLabelY - 1,
                           vx + tw2 / 2 + lblPad, dLabelY + th2 + 1,
                           FpARGB(C'10,10,14', (200 * opaScale) / 255));
      canvas.TextOut(vx, dLabelY, deltaStr,
                     FpARGB(deltaCol, (220 * opaScale) / 255), TA_CENTER | TA_TOP);

      // Feature 3: Order Flow Strength Score (0-100)
      if(InpShowOFScore)
        {
         int    score    = ComputeOFScore(bi);
         // "OFS:75" — prefix makes it instantly distinguishable from the delta number
         string scoreStr = "OFS:" + IntegerToString(score);
         // >60 = bullish green | <40 = bearish red | 40-60 = muted neutral
         color scoreCol;
         if(score >= 60)      scoreCol = InpTextBottomPos;
         else if(score <= 40) scoreCol = InpTextBottomNeg;
         else                 scoreCol = InpTextBaseColor;
         int tw3 = 0, th3 = 0;
         canvas.TextSize(scoreStr, tw3, th3);
         int sLabelY = dLabelY + th2 + 2;
         canvas.FillRectangle(vx - tw3 / 2 - lblPad, sLabelY - 1,
                              vx + tw3 / 2 + lblPad, sLabelY + th3 + 1,
                              FpARGB(C'10,10,14', (200 * opaScale) / 255));
         canvas.TextOut(vx, sLabelY, scoreStr,
                        FpARGB(scoreCol, (220 * opaScale) / 255), TA_CENTER | TA_TOP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Layout panel and button coordinates (no drawing)                 |
//| Groups (left to right):                                          |
//|  [Bars|Sync] [Mode] [Imb|VA] [Fade|Lbl] [Z-|Z+|Lock]           |
//|  [Cell|Tick] [Sig|FreqEdit|ThreshEdit] [Viz/Hid|Prof]           |
//+------------------------------------------------------------------+
void LayoutPanel(int cw, int ch)
  {
   int btnW   = FP_PANEL_BTN_W;
   int btnGap = FP_PANEL_BTN_GAP;
   int pad    = FP_PANEL_PAD;
   // 1 history OBJ_EDIT + 13 original buttons + 1 Sig + 2 OBJ_EDITs = 17 items
   int panelW = pad + (btnW * 17 + btnGap * 16) + pad;

   g_panelX2 = cw - FP_PANEL_MARGIN;
   g_panelX1 = g_panelX2 - panelW;
   g_panelY1 = ch - FP_PANEL_H - FP_PANEL_MARGIN;
   g_panelY2 = g_panelY1 + FP_PANEL_H;

   int y1 = g_panelY1 + pad;
   int y2 = g_panelY2 - pad;
   int x  = g_panelX1 + pad;

   // Group 1: Data -----------------------------------------------
   g_histEditX = x; g_histEditY = y1;
   g_histEditW = btnW; g_histEditH = y2 - y1;
   x += btnW + btnGap;

   g_btnRefreshX1 = x; g_btnRefreshY1 = y1; g_btnRefreshX2 = x + btnW; g_btnRefreshY2 = y2;
   x += btnW + btnGap;

   // Group 2: Chart mode -----------------------------------------
   g_btnModeX1 = x; g_btnModeY1 = y1; g_btnModeX2 = x + btnW; g_btnModeY2 = y2;
   x += btnW + btnGap;

   // Group 3: Analysis -------------------------------------------
   g_btnImbX1 = x; g_btnImbY1 = y1; g_btnImbX2 = x + btnW; g_btnImbY2 = y2;
   x += btnW + btnGap;

   g_btnVAX1 = x; g_btnVAY1 = y1; g_btnVAX2 = x + btnW; g_btnVAY2 = y2;
   x += btnW + btnGap;

   // Group 4: Display --------------------------------------------
   g_btnOpaX1 = x; g_btnOpaY1 = y1; g_btnOpaX2 = x + btnW; g_btnOpaY2 = y2;
   x += btnW + btnGap;

   g_btnTxtX1 = x; g_btnTxtY1 = y1; g_btnTxtX2 = x + btnW; g_btnTxtY2 = y2;
   x += btnW + btnGap;

   // Group 5: Zoom -----------------------------------------------
   g_btnZoomOutX1 = x; g_btnZoomOutY1 = y1; g_btnZoomOutX2 = x + btnW; g_btnZoomOutY2 = y2;
   x += btnW + btnGap;

   g_btnZoomInX1 = x; g_btnZoomInY1 = y1; g_btnZoomInX2 = x + btnW; g_btnZoomInY2 = y2;
   x += btnW + btnGap;

   g_btnScaleFixX1 = x; g_btnScaleFixY1 = y1; g_btnScaleFixX2 = x + btnW; g_btnScaleFixY2 = y2;
   x += btnW + btnGap;

   // Group 6: Granularity ----------------------------------------
   g_btnSizeX1 = x; g_btnSizeY1 = y1; g_btnSizeX2 = x + btnW; g_btnSizeY2 = y2;
   x += btnW + btnGap;

   g_btnTickX1 = x; g_btnTickY1 = y1; g_btnTickX2 = x + btnW; g_btnTickY2 = y2;
   x += btnW + btnGap;

   // Group 7: Signals — Sig toggle + FreqEdit + ThreshEdit --------
   g_btnSigX1 = x; g_btnSigY1 = y1; g_btnSigX2 = x + btnW; g_btnSigY2 = y2;
   x += btnW + btnGap;

   // SigFreq OBJ_EDIT — min bars between signals
   if(ObjectFind(g_chart, FP_SIG_FREQ_EDIT) >= 0)
     {
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_YDISTANCE, y1);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_XSIZE,     btnW);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_YSIZE,     y2 - y1);
     }
   x += btnW + btnGap;

   // SigThresh OBJ_EDIT — HFT score threshold
   if(ObjectFind(g_chart, FP_SIG_THRESH_EDIT) >= 0)
     {
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_YDISTANCE, y1);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_XSIZE,     btnW);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_YSIZE,     y2 - y1);
     }
   x += btnW + btnGap;

   // Group 8: Visibility -----------------------------------------
   g_btnShowX1 = x; g_btnShowY1 = y1; g_btnShowX2 = x + btnW; g_btnShowY2 = y2;
   x += btnW + btnGap;

   // Prof — always last
   g_btnProfX1 = x; g_btnProfY1 = y1; g_btnProfX2 = x + btnW; g_btnProfY2 = y2;

   // Keep native OBJ_EDIT in sync with panel position
   if(ObjectFind(g_chart, FP_HIST_EDIT) >= 0)
     {
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_XDISTANCE, g_histEditX);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_YDISTANCE, g_histEditY);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_XSIZE,     g_histEditW);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_YSIZE,     g_histEditH);
     }
  }

//+------------------------------------------------------------------+
//| Draw control panel background and all buttons                    |
//+------------------------------------------------------------------+
void DrawPanel()
  {
   int btnW       = FP_PANEL_BTN_W;
   int btnCenterX = btnW / 2;
   int btnCenterY = g_btnZoomOutY1 + (FP_PANEL_H - 6) / 2;

   canvas.FillRectangle(g_panelX1, g_panelY1, g_panelX2, g_panelY2,
                        FpARGB(C'20,20,28', 200));
   canvas.Rectangle(g_panelX1, g_panelY1, g_panelX2, g_panelY2,
                    FpARGB(C'70,70,80', 200));

   // Subtle group-separator lines
   // After Sync | after Mode | after VA | after Lbl | after Lock | after Tick | after ThreshEdit
   int sepY1 = g_panelY1 + 4;
   int sepY2 = g_panelY2 - 4;
   int sepAlpha = 55;
   uint sepCol = FpARGB(C'100,100,120', sepAlpha);
   int sepPositions[7];
   sepPositions[0] = g_btnRefreshX2  + FP_PANEL_BTN_GAP / 2;
   sepPositions[1] = g_btnModeX2     + FP_PANEL_BTN_GAP / 2;
   sepPositions[2] = g_btnVAX2       + FP_PANEL_BTN_GAP / 2;
   sepPositions[3] = g_btnTxtX2      + FP_PANEL_BTN_GAP / 2;
   sepPositions[4] = g_btnScaleFixX2 + FP_PANEL_BTN_GAP / 2;
   sepPositions[5] = g_btnTickX2     + FP_PANEL_BTN_GAP / 2;
   sepPositions[6] = g_btnShowX2     + FP_PANEL_BTN_GAP / 2;
   for(int s = 0; s < 7; s++)
      canvas.LineVertical(sepPositions[s], sepY1, sepY2, sepCol);

   // Hover detection
   bool hoveredSize     = HitTest(g_mouseX, g_mouseY, g_btnSizeX1,     g_btnSizeY1,     g_btnSizeX2,     g_btnSizeY2);
   bool hoveredTick     = HitTest(g_mouseX, g_mouseY, g_btnTickX1,     g_btnTickY1,     g_btnTickX2,     g_btnTickY2);
   bool hoveredImb      = HitTest(g_mouseX, g_mouseY, g_btnImbX1,      g_btnImbY1,      g_btnImbX2,      g_btnImbY2);
   bool hoveredZoomIn   = HitTest(g_mouseX, g_mouseY, g_btnZoomInX1,   g_btnZoomInY1,   g_btnZoomInX2,   g_btnZoomInY2);
   bool hoveredZoomOut  = HitTest(g_mouseX, g_mouseY, g_btnZoomOutX1,  g_btnZoomOutY1,  g_btnZoomOutX2,  g_btnZoomOutY2);
   bool hoveredScaleFix = HitTest(g_mouseX, g_mouseY, g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2);
   bool hoveredOpa      = HitTest(g_mouseX, g_mouseY, g_btnOpaX1,      g_btnOpaY1,      g_btnOpaX2,      g_btnOpaY2);
   bool hoveredShow     = HitTest(g_mouseX, g_mouseY, g_btnShowX1,     g_btnShowY1,     g_btnShowX2,     g_btnShowY2);
   bool hoveredRefresh  = HitTest(g_mouseX, g_mouseY, g_btnRefreshX1,  g_btnRefreshY1,  g_btnRefreshX2,  g_btnRefreshY2);
   bool hoveredVA       = HitTest(g_mouseX, g_mouseY, g_btnVAX1,       g_btnVAY1,       g_btnVAX2,       g_btnVAY2);
   bool hoveredTxt      = HitTest(g_mouseX, g_mouseY, g_btnTxtX1,      g_btnTxtY1,      g_btnTxtX2,      g_btnTxtY2);
   bool hoveredMode     = HitTest(g_mouseX, g_mouseY, g_btnModeX1,     g_btnModeY1,     g_btnModeX2,     g_btnModeY2);
   bool hoveredProf     = HitTest(g_mouseX, g_mouseY, g_btnProfX1,     g_btnProfY1,     g_btnProfX2,     g_btnProfY2);
   bool hoveredSig      = HitTest(g_mouseX, g_mouseY, g_btnSigX1,      g_btnSigY1,      g_btnSigX2,      g_btnSigY2);

   uint baseFill    = FpARGB(C'35,35,45', 230);
   uint hoverFill   = FpARGB(C'55,55,70', 250);
   uint baseBorder  = FpARGB(C'80,80,90', 200);
   uint hoverBorder = FpARGB(C'140,140,160', 255);

   bool scaleFixOn = (bool)ChartGetInteger(g_chart, CHART_SCALEFIX, 0);
   canvas.FontSet("Consolas", 9, FW_NORMAL);

   // --- Group 1: Data ---

   // History OBJ_EDIT — draw a thin accent border so it looks panel-native
   // The native edit box is rendered by the terminal on top; we just mark the slot
   canvas.FillRectangle(g_histEditX, g_histEditY, g_histEditX + g_histEditW, g_histEditY + g_histEditH,
                        FpARGB(C'25,25,35', 230));
   canvas.Rectangle(g_histEditX, g_histEditY, g_histEditX + g_histEditW, g_histEditY + g_histEditH,
                    FpARGB(C'80,80,100', 200));

   // Sync — reload tick data
   canvas.FillRectangle(g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2,
                        hoveredRefresh ? hoverFill : baseFill);
   canvas.Rectangle(g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2,
                    hoveredRefresh ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnRefreshX1 + btnCenterX, btnCenterY,
                  "Sync", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // --- Group 2: Mode ---

   string modeLabel;
   uint   modeFill, modeBorder;
   if(g_mode == FOOT_CHART_BIDASK)
     { modeLabel = "BxA"; modeFill = FpARGB(C'20,55,90', 230); modeBorder = FpARGB(C'60,150,230', 230); }
   else if(g_mode == FOOT_CHART_VOLUME)
     { modeLabel = "Vol"; modeFill = FpARGB(C'55,30,75', 230); modeBorder = FpARGB(C'160,80,220', 230); }
   else
     { modeLabel = "Dlt"; modeFill = FpARGB(C'60,45,10', 230); modeBorder = FpARGB(C'220,160,30', 230); }
   if(hoveredMode) { modeFill = hoverFill; modeBorder = hoverBorder; }
   canvas.FillRectangle(g_btnModeX1, g_btnModeY1, g_btnModeX2, g_btnModeY2, modeFill);
   canvas.Rectangle(g_btnModeX1, g_btnModeY1, g_btnModeX2, g_btnModeY2, modeBorder);
   canvas.TextOut(g_btnModeX1 + btnCenterX, btnCenterY,
                  modeLabel, FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // --- Group 3: Analysis ---

   // Imbalance threshold (e.g. "300%")
   canvas.FillRectangle(g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2,
                        hoveredImb ? hoverFill : baseFill);
   canvas.Rectangle(g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2,
                    hoveredImb ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnImbX1 + btnCenterX, btnCenterY,
                  IntegerToString((int)g_imbRatio) + "%", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // Value Area % (e.g. "VA70")
   canvas.FillRectangle(g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2,
                        hoveredVA ? hoverFill : baseFill);
   canvas.Rectangle(g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2,
                    hoveredVA ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnVAX1 + btnCenterX, btnCenterY,
                  "VA" + IntegerToString((int)GetEffectiveVAPercent()), FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // --- Group 4: Display ---

   // Fade — opacity (e.g. "75%")
   canvas.FillRectangle(g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2,
                        hoveredOpa ? hoverFill : baseFill);
   canvas.Rectangle(g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2,
                    hoveredOpa ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnOpaX1 + btnCenterX, btnCenterY,
                  IntegerToString((g_opacity * 100) / 255) + "%", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // Lbl — cell text labels toggle (green = on, red = off)
   uint lblFill   = g_userHideText ? FpARGB(C'90,30,30', 230)   : FpARGB(C'20,90,50', 230);
   uint lblBorder = g_userHideText ? FpARGB(C'200,80,80', 230)  : FpARGB(C'80,200,120', 230);
   if(hoveredTxt) { lblFill = hoverFill; lblBorder = hoverBorder; }
   canvas.FillRectangle(g_btnTxtX1, g_btnTxtY1, g_btnTxtX2, g_btnTxtY2, lblFill);
   canvas.Rectangle(g_btnTxtX1, g_btnTxtY1, g_btnTxtX2, g_btnTxtY2, lblBorder);
   canvas.TextOut(g_btnTxtX1 + btnCenterX, btnCenterY,
                  "Lbl", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // --- Group 5: Zoom ---

   // Z- (zoom out)
   canvas.FillRectangle(g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2,
                        hoveredZoomOut ? hoverFill : baseFill);
   canvas.Rectangle(g_btnZoomOutX1, g_btnZoomOutY1, g_btnZoomOutX2, g_btnZoomOutY2,
                    hoveredZoomOut ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnZoomOutX1 + btnCenterX, btnCenterY,
                  "Z-", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // Z+ (zoom in)
   canvas.FillRectangle(g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2,
                        hoveredZoomIn ? hoverFill : baseFill);
   canvas.Rectangle(g_btnZoomInX1, g_btnZoomInY1, g_btnZoomInX2, g_btnZoomInY2,
                    hoveredZoomIn ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnZoomInX1 + btnCenterX, btnCenterY,
                  "Z+", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // Lock — scale fix (green when active)
   uint lockFill   = scaleFixOn ? FpARGB(C'20,90,50', 230)   : baseFill;
   uint lockBorder = scaleFixOn ? FpARGB(C'80,200,120', 230) : baseBorder;
   if(hoveredScaleFix) { lockFill = hoverFill; lockBorder = hoverBorder; }
   canvas.FillRectangle(g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2, lockFill);
   canvas.Rectangle(g_btnScaleFixX1, g_btnScaleFixY1, g_btnScaleFixX2, g_btnScaleFixY2, lockBorder);
   canvas.TextOut(g_btnScaleFixX1 + btnCenterX, btnCenterY,
                  "Lock", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // --- Group 6: Granularity + Visibility ---

   // Cell size (e.g. "10p")
   canvas.FillRectangle(g_btnSizeX1, g_btnSizeY1, g_btnSizeX2, g_btnSizeY2,
                        hoveredSize ? hoverFill : baseFill);
   canvas.Rectangle(g_btnSizeX1, g_btnSizeY1, g_btnSizeX2, g_btnSizeY2,
                    hoveredSize ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnSizeX1 + btnCenterX, btnCenterY,
                  IntegerToString(g_basePts) + "p", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // Tick multiplier (e.g. "x5")
   canvas.FillRectangle(g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2,
                        hoveredTick ? hoverFill : baseFill);
   canvas.Rectangle(g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2,
                    hoveredTick ? hoverBorder : baseBorder);
   canvas.TextOut(g_btnTickX1 + btnCenterX, btnCenterY,
                  "x" + IntegerToString(g_tickMult), FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // Viz (visible) / Hid (hidden) — show/hide footprint
   uint vizFill   = g_visible ? FpARGB(C'20,90,50', 230)   : FpARGB(C'90,30,30', 230);
   uint vizBorder = g_visible ? FpARGB(C'80,200,120', 230) : FpARGB(C'200,80,80', 230);
   if(hoveredShow) { vizFill = hoverFill; vizBorder = hoverBorder; }
   canvas.FillRectangle(g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2, vizFill);
   canvas.Rectangle(g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2, vizBorder);
   canvas.TextOut(g_btnShowX1 + btnCenterX, btnCenterY,
                  g_visible ? "Viz" : "Hid", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);

   // --- Group 7: Signals ---

   // Sig toggle — green when enabled, red when disabled
   uint sigBtnFill, sigBtnBorder;
   if(g_signalsEnabled)
     { sigBtnFill = FpARGB(C'10,75,40', 230); sigBtnBorder = FpARGB(C'40,220,110', 240); }
   else
     { sigBtnFill = FpARGB(C'75,15,15', 230); sigBtnBorder = FpARGB(C'200,50,50', 240); }
   if(hoveredSig) { sigBtnFill = hoverFill; sigBtnBorder = hoverBorder; }
   canvas.FillRectangle(g_btnSigX1, g_btnSigY1, g_btnSigX2, g_btnSigY2, sigBtnFill);
   canvas.Rectangle(g_btnSigX1, g_btnSigY1, g_btnSigX2, g_btnSigY2, sigBtnBorder);
   canvas.TextOut(g_btnSigX1 + btnCenterX, btnCenterY,
                  "Sig", FpARGB(clrWhite, 215), TA_CENTER | TA_VCENTER);

   // FreqEdit slot background (OBJ_EDIT renders on top)
   if(ObjectFind(g_chart, FP_SIG_FREQ_EDIT) >= 0)
     {
      int fx1 = (int)ObjectGetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_XDISTANCE);
      int fy1 = (int)ObjectGetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_YDISTANCE);
      int fw  = (int)ObjectGetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_XSIZE);
      int fh  = (int)ObjectGetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_YSIZE);
      canvas.FillRectangle(fx1, fy1, fx1 + fw, fy1 + fh, FpARGB(C'22,22,34', 230));
      canvas.Rectangle(fx1, fy1, fx1 + fw, fy1 + fh, FpARGB(C'60,160,100', 200));
     }

   // ThreshEdit slot background (OBJ_EDIT renders on top)
   if(ObjectFind(g_chart, FP_SIG_THRESH_EDIT) >= 0)
     {
      int tx1 = (int)ObjectGetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_XDISTANCE);
      int ty1 = (int)ObjectGetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_YDISTANCE);
      int tw  = (int)ObjectGetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_XSIZE);
      int th  = (int)ObjectGetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_YSIZE);
      canvas.FillRectangle(tx1, ty1, tx1 + tw, ty1 + th, FpARGB(C'22,22,34', 230));
      canvas.Rectangle(tx1, ty1, tx1 + tw, ty1 + th, FpARGB(C'255,160,40', 200));
     }

   // --- Group 8: Prof ---

   // Prof — profile-only mode (teal when active)
   uint profFill, profBorder;
   if(g_profileOnly)
     { profFill = FpARGB(C'10,70,85', 230); profBorder = FpARGB(C'30,190,210', 230); }
   else
     { profFill = baseFill; profBorder = baseBorder; }
   if(hoveredProf) { profFill = hoverFill; profBorder = hoverBorder; }
   canvas.FillRectangle(g_btnProfX1, g_btnProfY1, g_btnProfX2, g_btnProfY2, profFill);
   canvas.Rectangle(g_btnProfX1, g_btnProfY1, g_btnProfX2, g_btnProfY2, profBorder);
   canvas.TextOut(g_btnProfX1 + btnCenterX, btnCenterY,
                  "Prof", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);
  }

//+------------------------------------------------------------------+
//| Session Cumulative Delta Profile  (Enhanced v5.3)               |
//| Bars grow from LEFT edge (original position, unchanged).        |
//| Gradient · intensity alpha · POC frame                          |
//| Volume-Profile style: VAH / VAL zone fill + POC/VAH/VAL labels  |
//+------------------------------------------------------------------+
void DrawCumDeltaProfile(int cw, int ch, int profX, int profW)
  {
   int nBars = ArraySize(g_bars);
   if(nBars == 0)
      return;

   //--- 1. Global price range ----------------------------------------
   double minP = g_bars[0].high, maxP = g_bars[0].low;
   for(int i = 0; i < nBars; i++)
     {
      if(g_bars[i].high > maxP) maxP = g_bars[i].high;
      if(g_bars[i].low  < minP) minP = g_bars[i].low;
     }
   maxP = NormP(maxP) + g_step;
   minP = NormP(minP);

   int buckets = (int)MathRound((maxP - minP) / g_step) + 1;
   if(buckets <= 0 || buckets > 2000) return;

   //--- 2. Accumulate delta per bucket --------------------------------
   ArrayResize(g_profPrices,   buckets, 0);
   ArrayResize(g_profCumDelta, buckets, 0);
   for(int k = 0; k < buckets; k++)
     {
      g_profPrices[k]   = minP + k * g_step;
      g_profCumDelta[k] = 0;
     }
   g_profCount = buckets;
   for(int i = 0; i < nBars; i++)
      for(int j = 0; j < g_bars[i].level_count; j++)
        {
         int k = (int)MathRound((g_bars[i].levels[j].price - minP) / g_step);
         if(k >= 0 && k < buckets)
            g_profCumDelta[k] += g_bars[i].levels[j].delta;
        }

   //--- 3. Stats: maxAbs, POC, total |delta| for VA calc -------------
   long maxAbsCum   = 1;
   int  pocBucket   = 0;
   long totalAbsCum = 0;
   long netCumDelta = 0;
   for(int k = 0; k < buckets; k++)
     {
      long av = MathAbs(g_profCumDelta[k]);
      totalAbsCum += av;
      if(av > maxAbsCum) { maxAbsCum = av; pocBucket = k; }
      netCumDelta += g_profCumDelta[k];
     }

   //--- 4. Value Area (standard VP logic on |cumDelta|) ---------------
   // Starting from POC, expand up/down greedily adding the larger
   // neighbour until accumulated |delta| >= VA% of total.
   double vaTarget  = totalAbsCum * (GetEffectiveVAPercent() / 100.0);
   long   vaAccum   = MathAbs(g_profCumDelta[pocBucket]);
   int    vaLo      = pocBucket;
   int    vaHi      = pocBucket;
   while(vaAccum < (long)vaTarget)
     {
      long aboveVol = (vaHi + 1 < buckets) ? MathAbs(g_profCumDelta[vaHi + 1]) : 0;
      long belowVol = (vaLo - 1 >= 0)      ? MathAbs(g_profCumDelta[vaLo - 1]) : 0;
      if(aboveVol == 0 && belowVol == 0) break;
      if(aboveVol >= belowVol)
        { vaHi++; vaAccum += aboveVol; }
      else
        { vaLo--; vaAccum += belowVol; }
     }
   // vaHi = VAH bucket index, vaLo = VAL bucket index

   //--- 5. Layout constants ------------------------------------------
   int  panelA      = (int)InpCumDeltaProfAlpha;
   int  panelBottom = ch - FP_PANEL_H - FP_PANEL_MARGIN - 2;
   int  headerH     = 22;
   int  drawW       = profW - 4;   // usable bar width (2px padding each side)
   int  barOriginX  = profX + 2;   // bars always start from left edge of panel

   //--- 6. Panel background ------------------------------------------
   canvas.FillRectangle(profX, 0, profX + profW, panelBottom,
                        FpARGB(C'10,10,16', (int)(panelA * 0.70)));
   canvas.LineVertical(profX, 0, panelBottom, FpARGB(C'60,60,78', 200));

   //--- 7. Header: "CumΔ" + net delta --------------------------------
   canvas.FontSet("Consolas", 8, FW_NORMAL);
   canvas.TextOut(profX + profW / 2, 2,
                  "CumΔ", FpARGB(C'160,160,190', 200), TA_CENTER | TA_TOP);
   color  netCol = (netCumDelta >= 0) ? InpCumDeltaPosColor : InpCumDeltaNegColor;
   string netStr = (netCumDelta >= 0 ? "+" : "") + IntegerToString(netCumDelta);
   canvas.TextOut(profX + profW / 2, 12,
                  netStr, FpARGB(netCol, 210), TA_CENTER | TA_TOP);

   //--- 8. Reference time for coordinate mapping --------------------
   datetime refTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(refTime <= 0) refTime = TimeCurrent();

   //--- 9. Compute screen Y positions for VAH / VAL / POC ----------
   //    (needed to draw the VA zone fill BEFORE bars so bars render on top)
   int pocY = -1, vahY = -1, valY = -1;
   int dummyX = 0;
   if(pocBucket >= 0)
      ChartTimePriceToXY(g_chart, g_sub, refTime, g_profPrices[pocBucket], dummyX, pocY);
   if(vaHi >= 0 && vaHi < buckets)
      ChartTimePriceToXY(g_chart, g_sub, refTime, g_profPrices[vaHi], dummyX, vahY);
   if(vaLo >= 0 && vaLo < buckets)
      ChartTimePriceToXY(g_chart, g_sub, refTime, g_profPrices[vaLo], dummyX, valY);

   //--- 10. VA zone fill (behind bars) --------------------------------
   if(InpCumDeltaVPLabels && vahY >= 0 && valY >= 0)
     {
      int vaTop = MathMin(vahY, valY);
      int vaBot = MathMax(vahY, valY);
      vaTop     = MathMax(vaTop, headerH);
      vaBot     = MathMin(vaBot, panelBottom);
      if(vaBot > vaTop)
         canvas.FillRectangle(profX + 2, vaTop, profX + profW - 2, vaBot,
                              FpARGB(C'30,50,35', 55));
     }

   //--- 11. Draw all bars -------------------------------------------
   for(int k = buckets - 1; k >= 0; k--)
     {
      if(g_profCumDelta[k] == 0) continue;

      double price = g_profPrices[k];
      int    tmpX = 0, yMid = 0;
      if(!ChartTimePriceToXY(g_chart, g_sub, refTime, price, tmpX, yMid)) continue;
      if(yMid < headerH || yMid > panelBottom) continue;

      int tmpY2 = 0;
      ChartTimePriceToXY(g_chart, g_sub, refTime, price - g_step, tmpX, tmpY2);
      int cellH = MathAbs(tmpY2 - yMid);
      if(cellH < 1) cellH = 1;
      int barH = MathMax(1, cellH - 1);

      double ratio    = (double)MathAbs(g_profCumDelta[k]) / (double)maxAbsCum;
      int    barWidth = MathMax(1, (int)(ratio * drawW));

      bool  bullish  = (g_profCumDelta[k] > 0);
      color baseCol  = bullish ? InpCumDeltaPosColor : InpCumDeltaNegColor;
      bool  isPOC    = (k == pocBucket);
      bool  inVA     = (k >= vaLo && k <= vaHi);

      // Intensity alpha
      int barAlpha = (int)(48 + ratio * (double)(panelA - 48));
      barAlpha     = MathMin(barAlpha, 255);
      // Slightly boost VA bars so zone stands out
      if(inVA && !isPOC) barAlpha = MathMin(barAlpha + 18, 255);

      int barX = barOriginX;   // all bars start from LEFT edge — original position
      int yTop = yMid - barH / 2;

      // ---- POC glow ----
      if(isPOC)
         canvas.FillRectangle(barX - 1, yTop - 1, barX + barWidth + 2, yTop + barH + 1,
                              FpARGB(baseCol, (int)(barAlpha * 0.30)));

      // ---- Gradient fill (dim at origin/left → bright at tip/right) ----
      if(InpCumDeltaGradient && barWidth >= 4)
        {
         int w1 = barWidth / 3;
         int w2 = barWidth - w1 * 2;
         int w3 = w1;
         canvas.FillRectangle(barX,          yTop, barX + w1,          yTop + barH, FpARGB(baseCol, (int)(barAlpha * 0.40)));
         canvas.FillRectangle(barX + w1,     yTop, barX + w1 + w2,     yTop + barH, FpARGB(baseCol, (int)(barAlpha * 0.74)));
         canvas.FillRectangle(barX + w1 + w2, yTop, barX + barWidth,   yTop + barH, FpARGB(baseCol, barAlpha));
         // bright 1-px tip cap
         canvas.FillRectangle(barX + barWidth - 1, yTop + 1, barX + barWidth, yTop + barH - 1,
                              FpARGB(bullish ? C'130,255,180' : C'255,130,150', (int)(barAlpha * 0.45)));
        }
      else
        {
         canvas.FillRectangle(barX, yTop, barX + barWidth, yTop + barH,
                              FpARGB(baseCol, barAlpha));
        }

      // ---- POC double frame ----
      if(isPOC)
        {
         color pocFrame = bullish ? C'55,255,135' : C'255,65,95';
         canvas.Rectangle(barX, yTop, barX + barWidth, yTop + barH,    FpARGB(pocFrame, 245));
         if(barH > 3 && barWidth > 3)
            canvas.Rectangle(barX+1, yTop+1, barX+barWidth-1, yTop+barH-1, FpARGB(pocFrame, 70));
        }
     }

   //--- 12. VP-style overlay lines + labels -------------------------
   if(InpCumDeltaVPLabels)
     {
      canvas.FontSet("Consolas", 7, FW_BOLD);
      int lblX = profX + 3;   // labels hug the left edge of the panel

      // --- POC line + label ---
      if(pocY >= headerH && pocY <= panelBottom)
        {
         bool  pocBull = (g_profCumDelta[pocBucket] > 0);
         color pocLine = pocBull ? C'60,255,140' : C'255,70,100';
         // Solid full-width line
         canvas.LineHorizontal(profX + 1, profX + profW - 1, pocY,     FpARGB(pocLine, 230));
         canvas.LineHorizontal(profX + 1, profX + profW - 1, pocY + 1, FpARGB(pocLine, 80));
         // "POC" label on left
         canvas.TextOut(lblX, pocY - 8, "POC", FpARGB(pocLine, 245), TA_LEFT | TA_TOP);
        }

      // --- VAH line + label ---
      if(vahY >= headerH && vahY <= panelBottom && vaHi != pocBucket)
        {
         // Dashed line (alternating segments)
         int segOn = 4, segOff = 3;
         for(int px = profX + 1; px < profX + profW - 1; px += segOn + segOff)
            canvas.LineHorizontal(px, MathMin(px + segOn - 1, profX + profW - 1),
                                  vahY, FpARGB(C'80,200,130', 200));
         canvas.TextOut(lblX, vahY - 8, "VAH", FpARGB(C'80,200,130', 230), TA_LEFT | TA_TOP);
        }

      // --- VAL line + label ---
      if(valY >= headerH && valY <= panelBottom && vaLo != pocBucket)
        {
         int segOn = 4, segOff = 3;
         for(int px = profX + 1; px < profX + profW - 1; px += segOn + segOff)
            canvas.LineHorizontal(px, MathMin(px + segOn - 1, profX + profW - 1),
                                  valY, FpARGB(C'80,200,130', 200));
         canvas.TextOut(lblX, valY + 2, "VAL", FpARGB(C'80,200,130', 230), TA_LEFT | TA_TOP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Draw visible footprint bars                                      |
//+------------------------------------------------------------------+
void DrawVisibleBars(int visBars, int firstVis, int barW)
  {
   for(int v = 0; v < visBars; v++)
     {
      int shift = firstVis - v;
      if(shift < 0)
         continue;

      datetime bt  = iTime(_Symbol, PERIOD_CURRENT, shift);
      int      idx = FindBarIndex(bt);
      if(idx >= 0)
         DrawBar(idx, shift, barW);
     }
  }

//+------------------------------------------------------------------+
//| Master render                                                    |
//+------------------------------------------------------------------+
void Render()
  {
   int cw = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(cw <= 0 || ch <= 0)
      return;

   if(canvas.Width() != cw || canvas.Height() != ch)
      canvas.Resize(cw, ch);

   canvas.Erase(0x00000000);

   int visBars = (int)ChartGetInteger(g_chart, CHART_VISIBLE_BARS);
   if(visBars < 1)
      visBars = 1;
   int barW     = cw / visBars;
   int firstVis = (int)ChartGetInteger(g_chart, CHART_FIRST_VISIBLE_BAR);
   if(ArraySize(g_bars) == 0)
     {
      canvas.Update();
      return;
     }

   // Auto-hide text when bars are too narrow to render readable numbers
   g_hideText = (barW < 6);

   // Summary header (Volumes / Delta / CumDelta / Min/Max Delta)
   long totalVol = 0;
   long cumDelta = 0;
   long minDelta = 0;
   long maxDelta = 0;
   long lastDelta= 0;
   bool have     = false;
   int  nBars    = ArraySize(g_bars);
   for(int i = 0; i < nBars; i++)
     {
      totalVol += g_bars[i].total_vol;
      cumDelta += g_bars[i].total_delta;
      if(!have)
        {
         minDelta = maxDelta = g_bars[i].total_delta;
         have     = true;
        }
      else
        {
         if(g_bars[i].total_delta < minDelta)
            minDelta = g_bars[i].total_delta;
         if(g_bars[i].total_delta > maxDelta)
            maxDelta = g_bars[i].total_delta;
        }
     }
   if(have)
      lastDelta = g_bars[nBars - 1].total_delta;

   string modeStr = "Bid x Ask";
   if(g_mode == FOOT_CHART_VOLUME)
      modeStr = "Volume";
   else if(g_mode == FOOT_CHART_DELTA)
      modeStr = "Delta";

   // Count divergence bars in visible window
   int divCount = 0;
   for(int i = 0; i < nBars; i++)
      if(g_bars[i].is_delta_divergence) divCount++;

   // Live HFT + OFS score for the most recent bar (shown in header)
   string hftStr = "---";
   string ofsStr = "---";
   if(nBars > 0 && g_bars[nBars-1].level_count > 0 && g_bars[nBars-1].total_vol > 0)
     {
      if(!g_bars[nBars-1].sorted) ComputeBarSignals(nBars-1);
      int  liveOFS  = ComputeOFScore(nBars-1);
      double liveHFT= ComputeHFTSignal(nBars-1, liveOFS);
      int effThr    = ComputeAdaptiveThreshold();
      hftStr = (liveHFT >= 0 ? "+" : "") + IntegerToString((int)MathRound(liveHFT))
               + "/" + IntegerToString(effThr);
      ofsStr = IntegerToString(liveOFS);
     }
   string sigState  = g_signalsEnabled
                      ? ("Sig:ON T:" + IntegerToString(g_signalThreshold)
                         + " F:" + IntegerToString(g_signalFreqBars))
                      : "Sig:OFF";
   string pushState = InpPushNotify ? (InpPushOnlyNewBar ? " Push:1/bar" : " Push:ON") : "";

   canvas.FontSet("Consolas", 9, FW_NORMAL);
   string header =
      "Mode: " + modeStr +
      "  Vol: " + IntegerToString(totalVol) +
      "  D(last): " + IntegerToString(lastDelta) +
      "  CumD: " + IntegerToString(cumDelta) +
      "  D↑: " + IntegerToString(maxDelta) +
      "  D↓: " + IntegerToString(minDelta) +
      "  Tick: " + DoubleToString(g_baseStep / _Point, 0) +
      " x" + IntegerToString(g_tickMult) +
      "  Imb: " + DoubleToString(g_imbRatio, 0) + "%" +
      "  VA: " + DoubleToString(GetEffectiveVAPercent(), 0) + "%" +
      "  Opa: " + IntegerToString((g_opacity * 100) / 255) + "%" +
      "  Bars: " + IntegerToString(nBars) +
      "  Div: " + IntegerToString(divCount) +
      "  HFT: " + hftStr +
      "  OFS: " + ofsStr +
      "  " + sigState + pushState;

   canvas.TextOut(5, 5, header, FpARGB(C'160,160,170', 180), TA_LEFT | TA_TOP);

   LayoutPanel(cw, ch);
   DrawPanel();

   if(!g_visible)
     {
      canvas.Update();
      g_dirty = false;
      return;
     }

   // In profile-only mode skip the footprint cells; the CumΔ profile still draws below
   if(!g_profileOnly)
      DrawVisibleBars(visBars, firstVis, barW);

   // Signal markers drawn unconditionally — visible in both footprint and profile-only modes
   EvalAndFireSignal();
   DrawSignalMarkersPass(visBars, firstVis, barW);

   // Cumulative Delta Profile — drawn over bars, right of canvas
   if(InpShowCumDeltaProf)
     {
      int profW = InpCumDeltaProfW;
      int profX = cw - profW - FP_PANEL_MARGIN;
      // Shift the panel leftward so they don't overlap
      // (LayoutPanel already ran; we just avoid the profile overlapping the bottom panel)
      DrawCumDeltaProfile(cw, ch, profX, profW);
     }

   canvas.Update();
   g_dirty = false;
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   // --- Input Validation ---
   if(_Point <= 0.0)
     {
      Alert("Footprint: Symbol point size is invalid. Cannot load.");
      return INIT_FAILED;
     }
   if(InpTickSize <= 0)
     {
      Alert("Footprint: InpTickSize must be >= 1. Cannot load.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTickMultiplier <= 0)
     {
      Alert("Footprint: InpTickMultiplier must be >= 1. Cannot load.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpHistoryBars <= 0)
     {
      Alert("Footprint: InpHistoryBars must be >= 1. Defaulting to 100.");
      // Don't block load — g_histBars will be clamped to FP_HIST_MIN in init below
     }
   if(InpImbalanceRatio < 100.0)
     {
      Alert("Footprint: InpImbalanceRatio must be >= 100. Cannot load.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpVAPercent <= 0.0 || InpVAPercent > 100.0)
     {
      Alert("Footprint: InpVAPercent must be between 1 and 100. Cannot load.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpCumDeltaProfW < 20)
     {
      Alert("Footprint: InpCumDeltaProfW must be >= 20px. Cannot load.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Base step in points (clamped)
   int pts = MathMax(1, MathMin(10000, InpTickSize));
   g_basePts  = pts;
   g_baseStep = g_basePts * _Point;

   // Tick multiplier (clamped 1..40)
   int mul = MathMax(1, MathMin(40, InpTickMultiplier));
   g_tickMult = mul;
   g_step     = g_baseStep * g_tickMult;

   g_mode         = InpChartMode;
   g_chart        = ChartID();
   g_sub          = 0;
   g_prevBid      = 0.0;
   g_dirty        = true;
   g_hideText     = false;
   g_userHideText = !InpShowText;
   g_imbRatio     = InpImbalanceRatio;
   g_profileOnly  = InpProfileOnly;
   g_histBars     = MathMax(FP_HIST_MIN, MathMin(FP_HIST_MAX, InpHistoryBars));
   // Seed runtime VA% so the button shows the correct value on load
   g_vaPercent    = (double)InpVAPercent;

   // --- Seed signal runtime state ---
   g_signalsEnabled    = InpShowSignals;
   g_signalFreqBars    = MathMax(1, InpSignalFreqBars);
   g_signalThreshold   = MathMax(1, MathMin(99, InpSignalThreshold));
   g_lastSignalBarTime = 0;
   g_sigCacheBarIdx    = -1;
   g_sigCacheVol       = -1;

   // Auto-detect pip size for adaptive threshold
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_Pip = (digits == 3 || digits == 5) ? _Point * 10.0 : _Point;

   // ATR handle for adaptive threshold
   g_handleATR = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
   if(g_handleATR == INVALID_HANDLE)
      Print("Footprint v6: Warning — ATR handle unavailable (", GetLastError(), "). Adaptive threshold disabled.");

   g_hasTrades = (SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0);

   // Make object names unique per chart instance (multi-chart safe)
   g_name          = "FP_Canvas_"       + IntegerToString(g_chart);
   g_editFreqName  = "FP_SigFreqEdit_"  + IntegerToString(g_chart);
   g_editThreshName= "FP_SigThreshEdit_"+ IntegerToString(g_chart);

   // Enable mouse-move events for panel hover states
   ChartSetInteger(g_chart, CHART_EVENT_MOUSE_MOVE, 1);

   int w = (int)ChartGetInteger(g_chart, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(g_chart, CHART_HEIGHT_IN_PIXELS);
   if(w < 1) w = 800;
   if(h < 1) h = 600;

   // Canvas bitmap must be created BEFORE the OBJ_EDIT so the edit box
   // sits on top in the z-order and can receive mouse focus/clicks.
   if(!canvas.CreateBitmapLabel(g_name, 0, 0, w, h,
                                COLOR_FORMAT_ARGB_NORMALIZE))
     {
      Alert("Footprint: Canvas creation failed. Chart may be too small.");
      return INIT_FAILED;
     }
   ObjectSetInteger(g_chart, g_name, OBJPROP_CORNER,  CORNER_LEFT_UPPER);
   ObjectSetInteger(g_chart, g_name, OBJPROP_BACK,    false);
   ObjectSetInteger(g_chart, g_name, OBJPROP_ZORDER,  0);   // canvas is click layer 0
   canvas.Erase(0x00000000);
   canvas.Update();

   // Create history-bars OBJ_EDIT AFTER canvas so it is drawn and
   // receives clicks on top of the canvas overlay.
   ObjectDelete(g_chart, FP_HIST_EDIT);  // clean up any stale instance
   if(ObjectCreate(g_chart, FP_HIST_EDIT, OBJ_EDIT, 0, 0, 0))
     {
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_XDISTANCE,    0);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_YDISTANCE,    0);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_XSIZE,        FP_PANEL_BTN_W);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_YSIZE,        FP_PANEL_H - 2 * FP_PANEL_PAD);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_BACK,         false);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_ZORDER,       10);  // above canvas — receives clicks
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_SELECTABLE,   false);  // prevent drag-to-move
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_SELECTED,     false);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_READONLY,     false);  // allow typing
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_ALIGN,        ALIGN_CENTER);
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_COLOR,        C'220,220,230');
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_BGCOLOR,      C'22,22,34');
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_BORDER_COLOR, C'80,80,108');
      ObjectSetInteger(g_chart, FP_HIST_EDIT, OBJPROP_FONTSIZE,     9);
      ObjectSetString( g_chart, FP_HIST_EDIT, OBJPROP_FONT,         "Consolas");
      ObjectSetString( g_chart, FP_HIST_EDIT, OBJPROP_TEXT,         IntegerToString(g_histBars));
      ObjectSetString( g_chart, FP_HIST_EDIT, OBJPROP_TOOLTIP,      "History bars to load — press Enter to apply");
     }
   else
     {
      Print("Footprint: Warning — could not create history input box (", GetLastError(), ").");
     }

   // ── SigFreq OBJ_EDIT — min bars between signal alerts ────────────
   ObjectDelete(g_chart, FP_SIG_FREQ_EDIT);
   if(ObjectCreate(g_chart, FP_SIG_FREQ_EDIT, OBJ_EDIT, 0, 0, 0))
     {
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_XDISTANCE,    0);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_YDISTANCE,    0);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_XSIZE,        FP_PANEL_BTN_W);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_YSIZE,        FP_PANEL_H - 2 * FP_PANEL_PAD);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_BACK,         false);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_ZORDER,       10);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_SELECTABLE,   false);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_SELECTED,     false);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_READONLY,     false);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_ALIGN,        ALIGN_CENTER);
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_COLOR,        C'220,220,230');
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_BGCOLOR,      C'22,22,34');
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_BORDER_COLOR, C'60,160,100');  // green — matches Sig button theme
      ObjectSetInteger(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_FONTSIZE,     9);
      ObjectSetString( g_chart, FP_SIG_FREQ_EDIT, OBJPROP_FONT,         "Consolas");
      ObjectSetString( g_chart, FP_SIG_FREQ_EDIT, OBJPROP_TEXT,         IntegerToString(g_signalFreqBars));
      ObjectSetString( g_chart, FP_SIG_FREQ_EDIT, OBJPROP_TOOLTIP,      "Min bars between signal alerts — press Enter to apply");
     }
   else
      Print("Footprint: Warning — could not create SigFreq input box (", GetLastError(), ").");

   // ── SigThresh OBJ_EDIT — HFT score threshold ─────────────────────
   ObjectDelete(g_chart, FP_SIG_THRESH_EDIT);
   if(ObjectCreate(g_chart, FP_SIG_THRESH_EDIT, OBJ_EDIT, 0, 0, 0))
     {
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_XDISTANCE,    0);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_YDISTANCE,    0);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_XSIZE,        FP_PANEL_BTN_W);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_YSIZE,        FP_PANEL_H - 2 * FP_PANEL_PAD);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_BACK,         false);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_ZORDER,       10);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_SELECTABLE,   false);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_SELECTED,     false);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_READONLY,     false);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_ALIGN,        ALIGN_CENTER);
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_COLOR,        C'220,220,230');
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_BGCOLOR,      C'22,22,34');
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_BORDER_COLOR, C'255,160,40');  // amber — matches signal theme
      ObjectSetInteger(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_FONTSIZE,     9);
      ObjectSetString( g_chart, FP_SIG_THRESH_EDIT, OBJPROP_FONT,         "Consolas");
      ObjectSetString( g_chart, FP_SIG_THRESH_EDIT, OBJPROP_TEXT,         IntegerToString(g_signalThreshold));
      ObjectSetString( g_chart, FP_SIG_THRESH_EDIT, OBJPROP_TOOLTIP,      "HFT signal score threshold (1-99) — press Enter to apply");
     }
   else
      Print("Footprint: Warning — could not create SigThresh input box (", GetLastError(), ").");

   ReloadHistory();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Remove all three panel OBJ_EDITs
   ObjectDelete(g_chart, FP_HIST_EDIT);
   ObjectDelete(g_chart, FP_SIG_FREQ_EDIT);
   ObjectDelete(g_chart, FP_SIG_THRESH_EDIT);

   // Remove all signal arrow objects placed on the chart
   int total = ObjectsTotal(g_chart, 0, OBJ_ARROW);
   for(int i = total - 1; i >= 0; i--)
     {
      string nm = ObjectName(g_chart, i, 0, OBJ_ARROW);
      if(StringFind(nm, "FP_Sig_") == 0)
         ObjectDelete(g_chart, nm);
     }

   // Release ATR indicator handle
   if(g_handleATR != INVALID_HANDLE)
     {
      IndicatorRelease(g_handleATR);
      g_handleATR = INVALID_HANDLE;
     }

   canvas.Destroy();
   ObjectDelete(g_chart, g_name);

   int n = ArraySize(g_bars);
   for(int i = 0; i < n; i++)
      ArrayFree(g_bars[i].levels);

   ArrayFree(g_bars);
   ArrayFree(g_scratchY1);
   ArrayFree(g_scratchY2);
   g_scratchCap  = 0;
   ArrayFree(g_profPrices);
   ArrayFree(g_profCumDelta);
   g_profCount = 0;
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
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
   if(rates_total == 0)
      return 0;

   // If LAST price becomes valid after init (e.g. data provider connects late),
   // switch to full tick flags and rebuild history so bars are reclassified correctly.
   if(!g_hasTrades && SymbolInfoDouble(_Symbol, SYMBOL_LAST) > 0.0)
     {
      g_hasTrades    = true;
      g_needs_reload = true;
     }

   // Handle timeframe change or full reset
   if(prev_calculated == 0 || rates_total < prev_calculated || ArraySize(g_bars) == 0)
     {
      ReloadHistory();
      if(!g_dirty) // History load failed, try again later
         return 0;
     }

   // Deferred reload: buttons set flag, heavy work executes here
   if(g_needs_reload)
     {
      g_needs_reload = false;
      ReloadHistory();
     }

   MqlTick ticks[];
   uint    flag    = g_hasTrades ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long    now_msc = (long)TimeCurrent() * 1000;
   long    from_msc= g_last_tick_time_ms;

   if(from_msc == 0)
     {
      long lookback = 60000; // 1 minute safe window
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
//| OnChartEvent                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_ENDEDIT && sparam == FP_HIST_EDIT)
     {
      // User finished editing the history-bars input — parse, clamp, reload
      string raw   = ObjectGetString(g_chart, FP_HIST_EDIT, OBJPROP_TEXT);
      int    value = (int)StringToInteger(raw);
      value        = MathMax(FP_HIST_MIN, MathMin(FP_HIST_MAX, value));
      g_histBars   = value;
      // Write the validated value back so the field shows the clamped number
      ObjectSetString(g_chart, FP_HIST_EDIT, OBJPROP_TEXT, IntegerToString(g_histBars));
      g_needs_reload = true;
      g_dirty        = true;
      Render();
      return;
     }

   // ── SigFreq edit: min bars between signals ───────────────────────
   if(id == CHARTEVENT_OBJECT_ENDEDIT && sparam == FP_SIG_FREQ_EDIT)
     {
      string rawF  = ObjectGetString(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_TEXT);
      int    freqV = (int)StringToInteger(rawF);
      freqV        = MathMax(1, MathMin(500, freqV));
      g_signalFreqBars = freqV;
      ObjectSetString(g_chart, FP_SIG_FREQ_EDIT, OBJPROP_TEXT, IntegerToString(g_signalFreqBars));
      g_lastSignalBarTime = 0;  // reset spacing gate — new freq applies immediately
      g_sigCacheBarIdx    = -1;
      g_dirty = true;
      Render();
      return;
     }

   // ── SigThresh edit: HFT score threshold ──────────────────────────
   if(id == CHARTEVENT_OBJECT_ENDEDIT && sparam == FP_SIG_THRESH_EDIT)
     {
      string rawT = ObjectGetString(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_TEXT);
      int    thrV = (int)StringToInteger(rawT);
      thrV        = MathMax(1, MathMin(99, thrV));
      g_signalThreshold = thrV;
      ObjectSetString(g_chart, FP_SIG_THRESH_EDIT, OBJPROP_TEXT, IntegerToString(g_signalThreshold));
      g_lastSignalBarTime = 0;  // reset spacing gate — new threshold may expose new signals
      g_sigCacheBarIdx    = -1;
      g_dirty = true;
      Render();
      return;
     }

   if(id == CHARTEVENT_CHART_CHANGE)
     {
      // If timeframe was changed, history needs full reload
      if(ArraySize(g_bars) > 0)
        {
         datetime expectedLastBar  = iTime(_Symbol, PERIOD_CURRENT, 0);
         int      bars_total       = iBars(_Symbol, PERIOD_CURRENT);
         int      span             = MathMin(g_histBars, bars_total - 1);
         datetime expectedFirstBar = iTime(_Symbol, PERIOD_CURRENT, span);

         if(g_bars[0].bar_time != expectedFirstBar ||
            g_bars[ArraySize(g_bars) - 1].bar_time != expectedLastBar)
            ReloadHistory();
        }
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

      // Base Cell Size button: 1p -> 2p -> 5p -> 10p -> 20p -> 40p -> 1p
      if(HitTest(mx, my, g_btnSizeX1, g_btnSizeY1, g_btnSizeX2, g_btnSizeY2))
        {
         int nextPts;
         if(g_basePts <= 1)
            nextPts = 2;
         else if(g_basePts <= 2)
            nextPts = 5;
         else if(g_basePts <= 5)
            nextPts = 10;
         else if(g_basePts <= 10)
            nextPts = 20;
         else if(g_basePts <= 20)
            nextPts = 40;
         else
            nextPts = 1;

         g_basePts      = nextPts;
         g_baseStep     = g_basePts * _Point;
         g_step         = g_baseStep * g_tickMult;
         g_needs_reload = true;
         g_dirty        = true;
         Render();
        }
      // Tick multiplier button: x1 -> x2 -> x5 -> x10 -> x20 -> x40 -> x1
      else if(HitTest(mx, my, g_btnTickX1, g_btnTickY1, g_btnTickX2, g_btnTickY2))
        {
         int nextMult;
         if(g_tickMult <= 1)
            nextMult = 2;
         else if(g_tickMult <= 2)
            nextMult = 5;
         else if(g_tickMult <= 5)
            nextMult = 10;
         else if(g_tickMult <= 10)
            nextMult = 20;
         else if(g_tickMult <= 20)
            nextMult = 40;
         else
            nextMult = 1;

         g_tickMult     = nextMult;
         g_step         = g_baseStep * g_tickMult;
         g_needs_reload = true;
         g_dirty        = true;
         Render();
        }
      // Imbalance button: cycle imbalance ratio
      else if(HitTest(mx, my, g_btnImbX1, g_btnImbY1, g_btnImbX2, g_btnImbY2))
        {
         if(g_imbRatio <= FP_IMB_LO)
            g_imbRatio = FP_IMB_MID;
         else if(g_imbRatio <= FP_IMB_MID)
            g_imbRatio = FP_IMB_HI;
         else
            g_imbRatio = FP_IMB_LO;
         // Mark all bars stale so imbalances are recomputed with the new ratio
         int n = ArraySize(g_bars);
         for(int k = 0; k < n; k++)
            g_bars[k].sorted = false;
         g_dirty = true;
         Render();
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
         // ChartSetInteger fires CHARTEVENT_CHART_CHANGE → ThrottledRender automatically
        }
      // Opacity button: cycle 100% -> 75% -> 50% -> 25% -> 100%
      else if(HitTest(mx, my, g_btnOpaX1, g_btnOpaY1, g_btnOpaX2, g_btnOpaY2))
        {
         if(g_opacity >= FP_OPA_FULL)
            g_opacity = FP_OPA_75;
         else if(g_opacity >= FP_OPA_75)
            g_opacity = FP_OPA_50;
         else if(g_opacity >= FP_OPA_50)
            g_opacity = FP_OPA_25;
         else
            g_opacity = FP_OPA_FULL;
         g_dirty = true;
         Render();
        }
      // Text toggle: hide/show cell numbers
      else if(HitTest(mx, my, g_btnTxtX1, g_btnTxtY1, g_btnTxtX2, g_btnTxtY2))
        {
         g_userHideText = !g_userHideText;
         g_dirty        = true;
         Render();
        }
      // Show/Hide toggle
      else if(HitTest(mx, my, g_btnShowX1, g_btnShowY1, g_btnShowX2, g_btnShowY2))
        {
         g_visible = !g_visible;
         g_dirty   = true;
         Render();
        }
      // Refresh: reload tick data
      else if(HitTest(mx, my, g_btnRefreshX1, g_btnRefreshY1, g_btnRefreshX2, g_btnRefreshY2))
        {
         g_needs_reload = true;
         g_dirty        = true;
         Render();
        }
      // VA%: cycle Value Area 70% -> 80% -> 90% -> 70%
      else if(HitTest(mx, my, g_btnVAX1, g_btnVAY1, g_btnVAX2, g_btnVAY2))
        {
         if(g_vaPercent < 80.0)
            g_vaPercent = 80.0;
         else if(g_vaPercent < 90.0)
            g_vaPercent = 90.0;
         else
            g_vaPercent = 70.0;
         g_dirty = true;
         Render();
        }
      // Mode cycle: Delta -> BidAsk -> Volume -> Delta (Delta is default)
      else if(HitTest(mx, my, g_btnModeX1, g_btnModeY1, g_btnModeX2, g_btnModeY2))
        {
         if(g_mode == FOOT_CHART_DELTA)       g_mode = FOOT_CHART_BIDASK;
         else if(g_mode == FOOT_CHART_BIDASK) g_mode = FOOT_CHART_VOLUME;
         else                                  g_mode = FOOT_CHART_DELTA;
         g_dirty = true;
         Render();
        }
      // Profile-Only toggle: hide footprint bars, keep CumΔ profile visible
      else if(HitTest(mx, my, g_btnProfX1, g_btnProfY1, g_btnProfX2, g_btnProfY2))
        {
         g_profileOnly = !g_profileOnly;
         g_dirty       = true;
         Render();
        }
      // Signals toggle: enable / disable HFT signal markers, sound, and push notifications
      else if(HitTest(mx, my, g_btnSigX1, g_btnSigY1, g_btnSigX2, g_btnSigY2))
        {
         g_signalsEnabled    = !g_signalsEnabled;
         g_lastSignalBarTime = 0;  // reset spacing gate on toggle
         g_lastPushBarTime   = 0;  // reset push gate so re-enabling sends immediately
         g_sigCacheBarIdx    = -1;
         g_dirty             = true;
         Render();
        }
     }
  }