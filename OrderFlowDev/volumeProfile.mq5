//+------------------------------------------------------------------+
//|                                                  VolumeProfile.mq5|
//|                                  Copyright 2025, User            |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, User"
#property link      "https://www.mql5.com"
#property version   "6.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

#include <Canvas\Canvas.mqh>

//--- Enums
enum ENUM_VP_ALIGNMENT
  {
   VP_ALIGN_LEFT   = 0, // Align Left
   VP_ALIGN_RIGHT  = 1  // Align Right
  };

enum ENUM_VP_DISTRIBUTION
  {
   VP_DIST_CLOSE      = 0,   // Close Price (Fastest)
   VP_DIST_EVEN       = 1,   // Even Distribution (H-L)
   VP_DIST_TRIANGULAR = 2    // Triangular (Weighted to Typical)
  };

enum ENUM_ROW_MODE
  {
   ROW_MODE_TICKS = 0, // Ticks per Row
   ROW_MODE_COUNT = 1  // Number of Rows
  };

//--- Input parameters ─── Data Source & Calculation ───
input group "─── DATA SOURCE ───"
sinput bool                 InpUseTicks          = true;          // Zero-Lag (Tick Data, like Footprint)
sinput bool                 InpDynamic           = true;          // Live: extend range to now, recalc every tick
sinput int                  InpLookBackBars      = 200;           // Initial LookBack Bars
sinput ENUM_TIMEFRAMES      InpDataTimeframe     = PERIOD_M1;     // Data Resolution (Bar mode only)
sinput ENUM_APPLIED_VOLUME  InpVolumeType        = VOLUME_TICK;   // Volume Type (Bar mode: Tick or Real)
sinput ENUM_VP_DISTRIBUTION InpDistribution      = VP_DIST_EVEN;  // Volume Distribution (Bar mode only)

input group "─── PROFILE LAYOUT ───"
sinput ENUM_VP_ALIGNMENT    InpAlignment         = VP_ALIGN_LEFT;  // Profile Alignment
sinput ENUM_ROW_MODE        InpRowMode           = ROW_MODE_TICKS; // Row Layout Mode
sinput int                  InpRowValue          = 10;            // Row Size (Ticks or Count)
sinput double               InpValueAreaPct      = 70.0;          // Value Area % (Standard is 70)
sinput int                  InpWidthRatio        = 40;            // Max Histogram Width %

input group "─── COLORS: VALUE AREA ───"
sinput color                InpColorVAUp         = C'40,160,80';  // VA Up Volume (Green — industry standard)
sinput color                InpColorVADown       = C'160,40,40';  // VA Down Volume (Red — industry standard)
sinput color                InpColorOutUp        = C'30,80,40';   // Outside VA Up (Dim Green)
sinput color                InpColorOutDown      = C'80,30,30';   // Outside VA Down (Dim Red)

input group "─── COLORS: POC & LINES ───"
sinput color                InpColorPOCLine      = C'255,160,0';  // POC Line Color (Amber — industry standard)
sinput int                  InpPOCWidth          = 3;             // POC Line Width (px total)
sinput bool                 InpHighlightPOCBar   = true;          // Highlight POC Bucket
sinput color                InpColorPOCBar       = C'255,180,0';  // POC Bucket Highlight (Gold)

input group "─── COLORS: VA BOUNDARIES ───"
sinput bool                 InpShowVABounds      = true;          // Show VAH/VAL Lines
sinput color                InpColorVABounds     = C'160,160,180';// VAH/VAL Color (Light Slate — clearly visible)
sinput int                  InpVAWidth           = 2;             // VAH/VAL Width (px total)

input group "─── VISUALS & LABELS ───"
sinput bool                 InpBackground        = true;          // Draw as Background
sinput bool                 InpFill              = true;          // Fill Histogram Bars
sinput uchar                InpHistAlpha         = 200;           // Histogram Opacity (0=transparent, 255=solid)
sinput bool                 InpShowValues        = true;          // Show Volume Labels
sinput color                InpValueColor        = C'220,220,220';// Volume Labels Color (bright — visible on dark charts)
sinput int                  InpValueFontSize     = 8;             // Labels Font Size
sinput color                InpColorSelector     = C'100,140,200';// Selector Box Color (Blue-grey)

input group "─── SELECTOR ───"
sinput bool                 InpHideSelector      = true;           // Hide selector box after initial load
sinput bool                 InpExtendLines       = true;           // Extend POC/VAH/VAL lines to right screen edge

input group "─── PRICE LABELS ───"
sinput bool                 InpShowKeyLabels     = true;           // Show price labels on POC / VAH / VAL
sinput int                  InpKeyLabelFontSize  = 9;              // Key-line label font size
sinput color                InpPOCLabelColor     = C'255,210,50';  // POC label color
sinput color                InpVALabelColor      = C'160,160,180'; // VAH / VAL label color

//--- Object name constants (canvas overlay + selector only)
const string RECT_NAME       = "VP_Selector";
const string BTN_SELECTOR    = "VP_BtnSelector";
const string BTN_PROFILE     = "VP_BtnProfile";

//--- Button layout
#define VP_BTN_W   68
#define VP_BTN_H   20
#define VP_BTN_GAP  4
#define VP_BTN_TOP  6
#define VP_BTN_RIGHT 80

//--- Stored profile range — allows the profile to persist after selector is hidden
datetime g_t1 = 0;
datetime g_t2 = 0;

//--- UI state flags
bool g_selectorVisible = false;  // starts hidden (matches InpHideSelector default)
bool g_vpVisible       = true;   // volume profile histogram on/off

//--- State
CCanvas canvas;
long   g_last_tick_time_ms = 0;   // last processed tick (for dynamic tick mode)
ulong  g_last_render_ms    = 0;   // throttle redraws
double g_prevBid           = 0.0; // for buy/sell classification (Forex)
datetime g_tester_last_time = 0;  // tester optimization throttle
//--- Compile-time constants
#define VP_RENDER_THROTTLE_MS 33   // ~30 FPS when dynamic (like live simulator)
#define VP_MAX_STEPS          5000 // Maximum number of price buckets to prevent memory/perf issues
#define VP_MIN_VOLUME         0.01 // Volume threshold below which a bucket is considered empty
#define VP_FALLBACK_RANGE_PTS 100  // Fallback price range in points when no data available
#define VP_MAX_DAYS_TICKS     30   // Prevent crash on huge tick requests

//+------------------------------------------------------------------+
//| Validated inputs (clamped to safe ranges)                         |
//+------------------------------------------------------------------+
double SafeWidthFactor()   { return MathMax(MathMin(InpWidthRatio, 100), 1) / 100.0; }
double SafeValueAreaPct()  { return MathMax(MathMin(InpValueAreaPct, 100.0), 10.0) / 100.0; }
int    SafePOCWidth()      { return MathMax(MathMin(InpPOCWidth, 5), 1); }
int    SafeVAWidth()       { return MathMax(MathMin(InpVAWidth, 5), 1); }

// Histogram bars use InpHistAlpha; key lines pass explicit alpha
uint GetARGB(color col, uchar alpha = 200)
  {
   return ColorToARGB(col, alpha);
  }

// Histogram bar ARGB — uses user-controlled opacity
uint GetHistARGB(color col)
  {
   return ColorToARGB(col, InpHistAlpha);
  }

//+------------------------------------------------------------------+
//| Hide the selector by moving it off every timeframe               |
//| Coordinates are preserved so range can still be read/updated.    |
//+------------------------------------------------------------------+
void HideSelector()
  {
   if(ObjectFind(0, RECT_NAME) < 0) return;
   ObjectSetInteger(0, RECT_NAME, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Show the selector (re-enable all timeframes + dragging)          |
//+------------------------------------------------------------------+
void ShowSelector()
  {
   if(ObjectFind(0, RECT_NAME) < 0) return;
   ObjectSetInteger(0, RECT_NAME, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_SELECTED,   true);
  }

//+------------------------------------------------------------------+
//| Create the two control buttons (top-right corner)               |
//+------------------------------------------------------------------+
void CreateButtons()
  {
   int chart_w = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

   // --- VP toggle button ---
   if(ObjectFind(0, BTN_PROFILE) < 0)
     {
      ObjectCreate(0, BTN_PROFILE, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_XDISTANCE, VP_BTN_RIGHT);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_YDISTANCE, VP_BTN_TOP);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_XSIZE,     VP_BTN_W);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_YSIZE,     VP_BTN_H);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_FONTSIZE,  8);
      ObjectSetString (0, BTN_PROFILE, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_HIDDEN,    false);
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_ZORDER,    100);
     }

   // --- Selector toggle button (positioned just left of VP button) ---
   if(ObjectFind(0, BTN_SELECTOR) < 0)
     {
      ObjectCreate(0, BTN_SELECTOR, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_XDISTANCE, VP_BTN_RIGHT + VP_BTN_W + VP_BTN_GAP);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_YDISTANCE, VP_BTN_TOP);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_XSIZE,     VP_BTN_W);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_YSIZE,     VP_BTN_H);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_FONTSIZE,  8);
      ObjectSetString (0, BTN_SELECTOR, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_HIDDEN,    false);
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_ZORDER,    100);
     }

   UpdateButtonStates();
  }

//+------------------------------------------------------------------+
//| Refresh button labels and colours to match current state         |
//+------------------------------------------------------------------+
void UpdateButtonStates()
  {
   // VP button
   if(ObjectFind(0, BTN_PROFILE) >= 0)
     {
      ObjectSetString (0, BTN_PROFILE, OBJPROP_TEXT,    g_vpVisible ? "VP  ON" : "VP  OFF");
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_BGCOLOR,
                       g_vpVisible ? C'20,90,50' : C'70,25,25');
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_COLOR,   C'220,220,225');
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_BORDER_COLOR,
                       g_vpVisible ? C'50,180,100' : C'160,50,50');
      ObjectSetInteger(0, BTN_PROFILE, OBJPROP_STATE,   false); // keep un-pressed
     }

   // Selector button
   if(ObjectFind(0, BTN_SELECTOR) >= 0)
     {
      ObjectSetString (0, BTN_SELECTOR, OBJPROP_TEXT,   g_selectorVisible ? "SEL  ON" : "SEL  OFF");
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_BGCOLOR,
                       g_selectorVisible ? C'20,60,110' : C'40,40,55');
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_COLOR,  C'220,220,225');
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_BORDER_COLOR,
                       g_selectorVisible ? C'60,130,220' : C'80,80,100');
      ObjectSetInteger(0, BTN_SELECTOR, OBJPROP_STATE,  false);
     }

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Delete both buttons                                              |
//+------------------------------------------------------------------+
void DeleteButtons()
  {
   ObjectDelete(0, BTN_PROFILE);
   ObjectDelete(0, BTN_SELECTOR);
  }

//+------------------------------------------------------------------+
//| Calculate Price Step (Resolution) Based on Mode                  |
//+------------------------------------------------------------------+
double GetResolution(double price_range)
  {
   if(InpRowMode == ROW_MODE_TICKS)
      return MathMax(InpRowValue, 1) * _Point;
   return MathMax(price_range / MathMax(InpRowValue, 1), _Point);
  }

//+------------------------------------------------------------------+
//| Compute bucket grid: range_bottom, resolution, steps (clamped)   |
//+------------------------------------------------------------------+
void ComputeBucketGrid(double min_price, double max_price,
                       double &resolution, double &range_bottom, int &steps)
  {
   double price_range = max_price - min_price;
   if(price_range <= 0) price_range = _Point;

   resolution = GetResolution(price_range);
   range_bottom = MathFloor(min_price / resolution) * resolution;
   double range_top = MathCeil(max_price / resolution) * resolution;
   steps = (int)MathCeil((range_top - range_bottom) / resolution);
   if(steps <= 0) steps = 1;
   if(steps > VP_MAX_STEPS)
     {
      resolution = price_range / (double)VP_MAX_STEPS;
      range_bottom = MathFloor(min_price / resolution) * resolution;
      steps = VP_MAX_STEPS;
     }
  }

//+------------------------------------------------------------------+
//| Allocate and zero-initialise a pair of bucket arrays              |
//+------------------------------------------------------------------+
void InitBuckets(double &buckets_up[], double &buckets_down[], int steps)
  {
   ArrayResize(buckets_up,   steps, VP_MAX_STEPS);
   ArrayResize(buckets_down, steps, VP_MAX_STEPS);
   ArrayInitialize(buckets_up,   0.0);
   ArrayInitialize(buckets_down, 0.0);
  }

//+------------------------------------------------------------------+
//| Classify tick as buy/sell (same logic as Footprint fp.mq5)       |
//+------------------------------------------------------------------+
void ClassifyTick(const MqlTick &t, bool &isBuy, bool &isSell)
  {
   isBuy = false; isSell = false;
   bool hasTrades = (SymbolInfoDouble(Symbol(), SYMBOL_LAST) > 0.0);
   if(hasTrades)
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
//| Format volume as human-readable string (508, 1.23K, 12.5K, etc.) |
//+------------------------------------------------------------------+
string FormatVolume(double vol)
  {
   if(vol >= 1000000.0)
     {
      double m = vol / 1000000.0;
      if(m >= 100.0)     return DoubleToString(m, 0) + "M";
      else if(m >= 10.0) return DoubleToString(m, 1) + "M";
      else               return DoubleToString(m, 2) + "M";
     }
   else if(vol >= 1000.0)
     {
      double k = vol / 1000.0;
      if(k >= 100.0)     return DoubleToString(k, 0) + "K";
      else if(k >= 10.0) return DoubleToString(k, 1) + "K";
      else               return DoubleToString(k, 2) + "K";
     }
   else
     {
      return DoubleToString(vol, 0);
     }
  }

//+------------------------------------------------------------------+
//| Calculate how many rows to skip between labels to avoid overlap  |
//+------------------------------------------------------------------+
int CalcLabelSkip(int steps, double resolution)
  {
   if(steps <= 0) return 1;

   int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   double chart_price_min = ChartGetDouble(0, CHART_PRICE_MIN);
   double chart_price_max = ChartGetDouble(0, CHART_PRICE_MAX);
   double chart_price_range = chart_price_max - chart_price_min;

   if(chart_price_range <= 0 || chart_height <= 0)
      return MathMax(1, steps / 30);

   double pixels_per_point = (double)chart_height / chart_price_range;
   double pixels_per_step = pixels_per_point * resolution;

   double label_height = (double)(InpValueFontSize + 3);

   if(pixels_per_step >= label_height)
      return 1;

   int skip = (int)MathCeil(label_height / pixels_per_step);
   return MathMax(1, skip);
  }

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   int chart_width  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   canvas.CreateBitmapLabel(0, 0, "VP_Canvas", 0, 0, chart_width, chart_height, COLOR_FORMAT_ARGB_NORMALIZE);
   ObjectSetInteger(0, "VP_Canvas", OBJPROP_BACK, InpBackground);
   ObjectSetInteger(0, "VP_Canvas", OBJPROP_ZORDER, 0);
   g_tester_last_time = 0;

   if(ObjectFind(0, RECT_NAME) < 0)
      CreateSelector();

   // Seed g_t1/g_t2 from the selector's current position
   g_t1 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 0);
   g_t2 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 1);

   g_vpVisible       = true;
   g_selectorVisible = !InpHideSelector; // sync flag to input default

   CalculateAndDraw();

   if(InpHideSelector)
      HideSelector();
   else
      ShowSelector();

   CreateButtons();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   DeleteButtons();
   canvas.Destroy();
   ClearProfileObjects();
   ObjectDelete(0, RECT_NAME);
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration — dynamic: recalc on new ticks/bars    |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(ObjectFind(0, RECT_NAME) < 0)
     {
      CreateSelector();
      g_t1 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 0);
      g_t2 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 1);
      CalculateAndDraw();
      if(InpHideSelector) HideSelector();
      return rates_total;
     }

   if(prev_calculated == 0)
     {
      // Re-seed range in case selector was recreated (e.g. TF change)
      long tf = ObjectGetInteger(0, RECT_NAME, OBJPROP_TIMEFRAMES);
      if(tf != OBJ_NO_PERIODS)
        {
         g_t1 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 0);
         g_t2 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 1);
        }
      CalculateAndDraw();
      if(InpHideSelector) HideSelector();
      return rates_total;
     }

   if(InpDynamic)
     {
      bool is_tester = (bool)MQLInfoInteger(MQL_TESTER) || (bool)MQLInfoInteger(MQL_OPTIMIZATION);
      ulong now_ms = GetTickCount();

      if(is_tester)
        {
         datetime tester_now = TimeCurrent();
         if(tester_now - g_tester_last_time >= 60)
           {
            CalculateAndDraw();
            g_tester_last_time = tester_now;
           }
        }
      else if(now_ms - g_last_render_ms >= VP_RENDER_THROTTLE_MS)
        {
         CalculateAndDraw();
         g_last_render_ms = now_ms;
        }
     }
   return rates_total;
  }

//+------------------------------------------------------------------+
//| ChartEvent handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      int chart_width  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      canvas.Erase(0);
      canvas.Resize(chart_width, chart_height);
      // Recreate buttons if they were lost (e.g. chart template change)
      if(ObjectFind(0, BTN_PROFILE)  < 0 ||
         ObjectFind(0, BTN_SELECTOR) < 0)
         CreateButtons();
      if(g_t1 != 0 || g_t2 != 0)
         CalculateAndDraw();
      return;
     }

   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == BTN_PROFILE)
        {
         g_vpVisible = !g_vpVisible;
         if(!g_vpVisible)
            ClearProfileObjects(); // blank the canvas immediately
         else
            CalculateAndDraw();
         UpdateButtonStates();
         return;
        }

      if(sparam == BTN_SELECTOR)
        {
         g_selectorVisible = !g_selectorVisible;
         if(g_selectorVisible)
           {
            ShowSelector();
            // If selector was hidden, its coords are still in g_t1/g_t2 —
            // reposition selector object to match stored range
            if(ObjectFind(0, RECT_NAME) >= 0)
              {
               ObjectSetInteger(0, RECT_NAME, OBJPROP_TIME, 0, g_t1);
               ObjectSetInteger(0, RECT_NAME, OBJPROP_TIME, 1, g_t2);
              }
           }
         else
            HideSelector();
         UpdateButtonStates();
         return;
        }
     }

   // Both DRAG and CHANGE fire when the user moves or resizes the selector
   if((id == CHARTEVENT_OBJECT_DRAG || id == CHARTEVENT_OBJECT_CHANGE) &&
      sparam == RECT_NAME)
     {
      g_t1 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 0);
      g_t2 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 1);
      if(g_vpVisible)
         CalculateAndDraw();
     }
  }

//+------------------------------------------------------------------+
//| Create the interactive selection rectangle                       |
//+------------------------------------------------------------------+
void CreateSelector()
  {
   datetime time_current = TimeCurrent();
   datetime time_start   = iTime(Symbol(), PERIOD_CURRENT, InpLookBackBars);
   if(time_start == 0)
      time_start = time_current - InpLookBackBars * PeriodSeconds();

   double price_high = iHigh(Symbol(), PERIOD_CURRENT, iHighest(Symbol(), PERIOD_CURRENT, MODE_HIGH, InpLookBackBars, 0));
   double price_low  = iLow(Symbol(), PERIOD_CURRENT, iLowest(Symbol(), PERIOD_CURRENT, MODE_LOW, InpLookBackBars, 0));

   if(price_high == 0) price_high = SymbolInfoDouble(Symbol(), SYMBOL_BID) + VP_FALLBACK_RANGE_PTS * _Point;
   if(price_low  == 0) price_low  = SymbolInfoDouble(Symbol(), SYMBOL_BID) - VP_FALLBACK_RANGE_PTS * _Point;

   ObjectCreate(0, RECT_NAME, OBJ_RECTANGLE, 0, time_start, price_high, time_current, price_low);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_COLOR, InpColorSelector);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_FILL, false);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_BACK, false);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_SELECTED, true);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, RECT_NAME, OBJPROP_ZORDER, 10);
  }

//+------------------------------------------------------------------+
//| Zero-lag: build volume profile from tick data (like Footprint)    |
//| Fills buckets_up[], buckets_down[], range_bottom, resolution, steps |
//| Returns tick count or -1 on failure                               |
//+------------------------------------------------------------------+
int GatherDataTicks(datetime start_time, datetime end_time,
                    double &buckets_up[], double &buckets_down[],
                    double &range_bottom, double &resolution, int &steps)
  {
   MqlTick ticks[];
   uint    flag = (SymbolInfoDouble(Symbol(), SYMBOL_LAST) > 0.0) ? COPY_TICKS_ALL : COPY_TICKS_INFO;
   long    from_ms = (long)start_time * 1000;
   long    to_ms   = (long)end_time   * 1000;
   if(to_ms <= from_ms) to_ms = (long)TimeCurrent() * 1000;

   // Safety mechanism: limit to VP_MAX_DAYS_TICKS to prevent memory overload
   const long max_ms_span = (long)VP_MAX_DAYS_TICKS * 24 * 60 * 60 * 1000;
   if(to_ms - from_ms > max_ms_span)
     {
      Print("[VP] Warning: Range too large for Ticks. Truncated to ", VP_MAX_DAYS_TICKS, " days.");
      from_ms = to_ms - max_ms_span;
     }

   int copied = CopyTicksRange(Symbol(), ticks, flag, from_ms, to_ms);
   if(copied <= 0) return -1;

   double min_price = 0.0;
   double max_price = 0.0;
   for(int i = 0; i < copied; i++)
     {
      double p = (flag == COPY_TICKS_ALL) ? ticks[i].last : ticks[i].bid;
      if(p > 0.0)
        {
         min_price = p;
         max_price = p;
         break;
        }
     }
     
   if(min_price == 0.0) return -1; // No valid ticks to process

   for(int i = 0; i < copied; i++)
     {
      double p = (flag == COPY_TICKS_ALL) ? ticks[i].last : ticks[i].bid;
      if(p <= 0) continue;
      if(p < min_price) min_price = p;
      if(p > max_price) max_price = p;
     }

    ComputeBucketGrid(min_price, max_price, resolution, range_bottom, steps);
    InitBuckets(buckets_up, buckets_down, steps);

   g_prevBid = ticks[0].bid;
   for(int i = 0; i < copied; i++)
     {
      double price = (flag == COPY_TICKS_ALL) ? ticks[i].last : ticks[i].bid;
      long   vol   = (flag == COPY_TICKS_ALL) ? (long)ticks[i].volume : 1;
      if(price <= 0 || vol <= 0) continue;

      bool isBuy, isSell;
      ClassifyTick(ticks[i], isBuy, isSell);
      if(ticks[i].bid != 0.0) g_prevBid = ticks[i].bid;

      int idx = (int)((price - range_bottom) / resolution);
      if(idx < 0)       idx = 0;
      if(idx >= steps)  idx = steps - 1;

      if(isBuy)  buckets_up[idx]   += (double)vol;
      if(isSell) buckets_down[idx] += (double)vol;
     }

   if(copied > 0)
      g_last_tick_time_ms = (long)ticks[copied - 1].time_msc;
   return copied;
  }

//+------------------------------------------------------------------+
//| Gather OHLCV data from the configured timeframe (Bar mode)         |
//| Returns: bar count, or -1 on failure                              |
//+------------------------------------------------------------------+
int GatherData(datetime start_time, datetime end_time,
               double &highs[], double &lows[],
               double &opens[], double &closes[],
               long   &volumes[])
  {
   ENUM_TIMEFRAMES tf = InpDataTimeframe;

   if(start_time > end_time)
     { datetime temp = start_time; start_time = end_time; end_time = temp; }

   int count = CopyHigh(Symbol(), tf, start_time, end_time, highs);
   if(count <= 0) { Print("[VP] CopyHigh failed"); return(-1); }

   if(CopyLow(Symbol(), tf, start_time, end_time, lows)     != count) { Print("[VP] CopyLow failed/mismatch");    return(-1); }
   if(CopyOpen(Symbol(), tf, start_time, end_time, opens)   != count) { Print("[VP] CopyOpen failed/mismatch");   return(-1); }
   if(CopyClose(Symbol(), tf, start_time, end_time, closes) != count) { Print("[VP] CopyClose failed/mismatch");  return(-1); }

   //--- Volume: try requested type first, fall back if it fails
   if(InpVolumeType == VOLUME_REAL)
     {
      int copied = CopyRealVolume(Symbol(), tf, start_time, end_time, volumes);
      if(copied != count)
        {
         bool all_zero = true;
         if(copied > 0)
           {
            for(int i = 0; i < copied; i++)
              { if(volumes[i] > 0) { all_zero = false; break; } }
           }

         if(copied <= 0 || all_zero)
           {
            Print("[VP] Real volume unavailable, falling back to tick volume");
            if(CopyTickVolume(Symbol(), tf, start_time, end_time, volumes) != count)
              { Print("[VP] CopyTickVolume fallback also failed"); return(-1); }
           }
         else
           {
            Print("[VP] CopyRealVolume partial: got ", copied, " of ", count);
            return(-1);
           }
        }
      else
        {
         bool all_zero = true;
         for(int i = 0; i < count; i++)
           { if(volumes[i] > 0) { all_zero = false; break; } }

         if(all_zero)
           {
            Print("[VP] Real volume is all zeros, falling back to tick volume");
            if(CopyTickVolume(Symbol(), tf, start_time, end_time, volumes) != count)
              { Print("[VP] CopyTickVolume fallback also failed"); return(-1); }
           }
        }
     }
   else
     {
      if(CopyTickVolume(Symbol(), tf, start_time, end_time, volumes) != count)
        { Print("[VP] CopyTickVolume failed"); return(-1); }
     }

   return(count);
  }

//+------------------------------------------------------------------+
//| Distribute volume to the CLOSE PRICE bucket only                 |
//+------------------------------------------------------------------+
void DistributeVolumeClose(int count,
                           const double &highs[], const double &lows[],
                           const double &opens[], const double &closes[],
                           const long   &volumes[],
                           double range_bottom, double resolution, int steps,
                           double &buckets_up[], double &buckets_down[])
  {
   for(int i = 0; i < count; i++)
     {
      double vol = (double)volumes[i];
      if(vol <= 0) continue;

      bool is_up = (closes[i] >= opens[i]);

      int idx = (int)((closes[i] - range_bottom) / resolution);
      if(idx < 0)       idx = 0;
      if(idx >= steps)  idx = steps - 1;

      if(is_up) buckets_up[idx]   += vol;
      else      buckets_down[idx] += vol;
     }
  }

//+------------------------------------------------------------------+
//| Distribute volume EVENLY across each bar's H-L range             |
//+------------------------------------------------------------------+
void DistributeVolumeEven(int count,
                          const double &highs[], const double &lows[],
                          const double &opens[], const double &closes[],
                          const long   &volumes[],
                          double range_bottom, double resolution, int steps,
                          double &buckets_up[], double &buckets_down[])
  {
   for(int i = 0; i < count; i++)
     {
      double vol = (double)volumes[i];
      if(vol <= 0) continue;

      bool   is_up = (closes[i] >= opens[i]);
      double bar_h = highs[i];
      double bar_l = lows[i];

      int idx_h = (int)((bar_h - range_bottom) / resolution);
      int idx_l = (int)((bar_l - range_bottom) / resolution);
      if(idx_l < 0)       idx_l = 0;
      if(idx_h >= steps)  idx_h = steps - 1;

      int levels_covered = idx_h - idx_l + 1;
      if(levels_covered <= 0) continue;

      double portion = vol / (double)levels_covered;

      for(int k = idx_l; k <= idx_h; k++)
        {
         if(is_up) buckets_up[k]   += portion;
         else      buckets_down[k] += portion;
        }
     }
  }

//+------------------------------------------------------------------+
//| Distribute volume with TRIANGULAR weighting toward Typical Price |
//+------------------------------------------------------------------+
void DistributeVolumeTriangular(int count,
                                const double &highs[], const double &lows[],
                                const double &opens[], const double &closes[],
                                const long   &volumes[],
                                double range_bottom, double resolution, int steps,
                                double &buckets_up[], double &buckets_down[])
  {
   double weights[]; // Pre-allocate outside the loop to prevent memory fragmentation
   ArrayResize(weights, VP_MAX_STEPS, VP_MAX_STEPS);

   for(int i = 0; i < count; i++)
     {
      double vol = (double)volumes[i];
      if(vol <= 0) continue;

      bool   is_up   = (closes[i] >= opens[i]);
      double bar_h   = highs[i];
      double bar_l   = lows[i];
      double typical = (bar_h + bar_l + closes[i]) / 3.0;

      int idx_h = (int)((bar_h - range_bottom) / resolution);
      int idx_l = (int)((bar_l - range_bottom) / resolution);
      if(idx_l < 0)       idx_l = 0;
      if(idx_h >= steps)  idx_h = steps - 1;

      int levels_covered = idx_h - idx_l + 1;
      if(levels_covered <= 0) continue;

      if(levels_covered == 1)
        {
         if(is_up) buckets_up[idx_l]   += vol;
         else      buckets_down[idx_l] += vol;
         continue;
        }

      double half_range = MathMax(bar_h - typical, typical - bar_l);
      if(half_range <= 0) half_range = resolution;

      double weight_sum = 0.0;

      for(int k = 0; k < levels_covered; k++)
        {
         double price_center = range_bottom + ((idx_l + k) * resolution) + (resolution / 2.0);
         double dist = MathAbs(price_center - typical);
         double w = MathMax(0.1, 1.0 - (dist / half_range));
         weights[k]  = w;
         weight_sum += w;
        }

      if(weight_sum <= 0) weight_sum = 1.0;

      for(int k = 0; k < levels_covered; k++)
        {
         double portion   = vol * (weights[k] / weight_sum);
         int    bucket_idx = idx_l + k;
         if(is_up) buckets_up[bucket_idx]   += portion;
         else      buckets_down[bucket_idx] += portion;
        }
     }
  }

//+------------------------------------------------------------------+
//| Find POC and compute Value Area indices (Industry Standard)      |
//| Algorithm: Starting from POC, add 2 rows above vs 2 rows below   |
//+------------------------------------------------------------------+
void ComputeValueArea(const double &total_volumes[], int steps,
                       int &poc_idx, double &max_total_vol,
                       int &va_high_idx, int &va_low_idx)
  {
   double grand_total_vol = 0;
   double poc_vol         = -1;
   max_total_vol          = 0;
   poc_idx                = 0;

   // 1. Find POC and Total Volume
   for(int i = 0; i < steps; i++)
     {
      grand_total_vol += total_volumes[i];
      if(total_volumes[i] > max_total_vol) max_total_vol = total_volumes[i];
      if(total_volumes[i] > poc_vol)       { poc_vol = total_volumes[i]; poc_idx = i; }
     }

   if(grand_total_vol <= 0) return;

   double va_target = grand_total_vol * SafeValueAreaPct();
   double va_accum  = total_volumes[poc_idx];
   va_high_idx = poc_idx;
   va_low_idx  = poc_idx;

   // 2. Expand outwards from POC using the 2-row comparison algorithm
   while(va_accum < va_target && (va_high_idx < steps - 1 || va_low_idx > 0))
     {
      double sum_above = 0;
      if(va_high_idx < steps - 1) sum_above += total_volumes[va_high_idx + 1];
      if(va_high_idx < steps - 2) sum_above += total_volumes[va_high_idx + 2];

      double sum_below = 0;
      if(va_low_idx > 0)          sum_below += total_volumes[va_low_idx - 1];
      if(va_low_idx > 1)          sum_below += total_volumes[va_low_idx - 2];

      if((sum_above >= sum_below || va_low_idx == 0) && va_high_idx < steps - 1)
        {
         // Add 1st from above
         va_high_idx++;
         va_accum += total_volumes[va_high_idx];
         // Add 2nd from above (if it exists and still need more)
         if(va_high_idx < steps - 1 && va_accum < va_target)
           {
            va_high_idx++;
            va_accum += total_volumes[va_high_idx];
           }
        }
      else if(va_low_idx > 0)
        {
         // Add 1st from below
         va_low_idx--;
         va_accum += total_volumes[va_low_idx];
         // Add 2nd from below (if it exists and still need more)
         if(va_low_idx > 0 && va_accum < va_target)
           {
            va_low_idx--;
            va_accum += total_volumes[va_low_idx];
           }
        }
      else break;
     }
  }

//+------------------------------------------------------------------+
//| Determine bar colors based on zone (POC / VA / Outside)          |
//+------------------------------------------------------------------+
void GetBarColors(int idx, int poc_idx, int va_low_idx, int va_high_idx,
                  color &col_up, color &col_down)
  {
   // POC bar highlight
   if(InpHighlightPOCBar && idx == poc_idx)
     {
      col_up   = InpColorPOCBar;
      col_down = InpColorPOCBar;
      return;
     }

   // Inside Value Area
   if(idx >= va_low_idx && idx <= va_high_idx)
     {
      col_up   = InpColorVAUp;
      col_down = InpColorVADown;
      return;
     }

   // Outside Value Area
   col_up   = InpColorOutUp;
   col_down = InpColorOutDown;
  }

//+------------------------------------------------------------------+
//| CCanvas Transition Strategy for UI Optimization:                  |
//| 1. Include <Canvas\Canvas.mqh> and create CCanvas instance.       |
//| 2. Instead of generating thousands of OBJ_RECTANGLE objects,      |
//|    create a transparent Canvas spanning the entire chart window.  |
//| 3. Use CCanvas::FillRectangle() to draw volume buckets directly   |
//|    onto the pixel buffer array in memory.                         |
//| 4. Call CCanvas::Update() exactly once per tick to push pixels.   |
//| 5. This eliminates MT5's object-handling overhead, vastly         |
//|    improving FPS and allowing complex alpha blending.             |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Draw histogram bars and value labels (zone-aware: POC / VA)       |
//+------------------------------------------------------------------+
void DrawBars(int steps, double range_bottom, double resolution,
              const double &buckets_up[], const double &buckets_down[],
              double max_total_vol,
              datetime start_time, datetime end_time,
              int poc_idx, int va_low_idx, int va_high_idx)
  {
   double max_width_factor = SafeWidthFactor();

   // Calculate label skip interval to prevent overlap
   int label_skip = 1;
   if(InpShowValues)
      label_skip = CalcLabelSkip(steps, resolution);

   canvas.Erase(0);
   // Consolas: monospace — digits align vertically across rows (industry standard for volume ladders)
   canvas.FontSet("Consolas", InpValueFontSize, FW_NORMAL);

   // 1. Query chart bounds exactly ONCE to prevent 1000s of sync calls
   int x_start = 0, y_bottom = 0;
   int x_end = 0, y_top = 0;

   ChartTimePriceToXY(0, 0, start_time, range_bottom, x_start, y_bottom);
   ChartTimePriceToXY(0, 0, end_time, range_bottom + (steps * resolution), x_end, y_top);

   // Linear interpolation coefficients
   double dY = y_top - y_bottom;
   if(steps <= 0) steps = 1; // Safeguard

   for(int i = 0; i < steps; i++)
     {
      double vol_up    = buckets_up[i];
      double vol_down  = buckets_down[i];
      double vol_total = vol_up + vol_down;

      if(vol_total <= VP_MIN_VOLUME) continue;

      // Determine colors based on zone
      color col_up_bar, col_down_bar;
      GetBarColors(i, poc_idx, va_low_idx, va_high_idx, col_up_bar, col_down_bar);

      double total_ratio  = vol_total / max_total_vol;
      double up_ratio_val = (vol_total > 0) ? vol_up / vol_total : 0.5;

      int total_width_px = (int)(MathAbs(x_end - x_start) * total_ratio * max_width_factor);
      int up_width_px    = (int)(total_width_px * up_ratio_val);
      int down_width_px  = total_width_px - up_width_px;

      // Linear interpolation for Y axis (avoids per-bucket ChartTimePriceToXY calls)
      double t_ratio1 = (double)i / (double)steps;
      double t_ratio2 = (double)(i + 1) / (double)steps;

      int y1 = y_bottom + (int)(dY * t_ratio1);
      int y2 = y_bottom + (int)(dY * t_ratio2);

      int x1 = 0, xsplit = 0, x2 = 0;

      if(InpAlignment == VP_ALIGN_LEFT)
        {
         x1     = MathMin(x_start, x_end);
         xsplit = x1 + down_width_px;
         x2     = x1 + total_width_px;
        }
      else
        {
         x2     = MathMax(x_start, x_end);
         xsplit = x2 - up_width_px;
         x1     = x2 - total_width_px;
        }

      // Down volume (Bid side — left half)
      if(vol_down > VP_MIN_VOLUME)
        {
         if(InpFill) canvas.FillRectangle(x1, y2, xsplit, y1, GetHistARGB(col_down_bar));
         else        canvas.Rectangle(x1, y2, xsplit, y1, GetHistARGB(col_down_bar));
        }

      // Up volume (Ask side — right half)
      if(vol_up > VP_MIN_VOLUME)
        {
         if(InpFill) canvas.FillRectangle(xsplit, y2, x2, y1, GetHistARGB(col_up_bar));
         else        canvas.Rectangle(xsplit, y2, x2, y1, GetHistARGB(col_up_bar));
        }

      // Volume value label — only render at spaced intervals to prevent overlap
      if(InpShowValues && (i % label_skip == 0))
        {
         int lx = (InpAlignment == VP_ALIGN_LEFT) ? x2 + 2 : x1 - 2;  // Small offset from bar edge
         int ly = y_bottom + (int)(dY * (t_ratio1 + t_ratio2) / 2.0);  // Vertical midpoint of bucket
         uint align = (InpAlignment == VP_ALIGN_LEFT) ? TA_LEFT : TA_RIGHT;
         canvas.TextOut(lx, ly - (InpValueFontSize / 2), FormatVolume(vol_total),
                        GetARGB(InpValueColor, 255), align);
        }
     }
  }

//+------------------------------------------------------------------+
//| Draw POC, VAH, and VAL key lines with price labels               |
//+------------------------------------------------------------------+
void DrawKeyLines(int poc_idx, int va_high_idx, int va_low_idx,
                  double range_bottom, double resolution,
                  datetime start_time, datetime end_time, int steps)
  {
   int x_start = 0, y_bottom = 0;
   int x_end   = 0, y_top   = 0;
   ChartTimePriceToXY(0, 0, start_time, range_bottom,                    x_start, y_bottom);
   ChartTimePriceToXY(0, 0, end_time,   range_bottom + steps * resolution, x_end,   y_top);

   // When extending lines, use the full chart width as the right boundary
   int x_line_end = x_end;
   if(InpExtendLines)
      x_line_end = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

   double dY = y_top - y_bottom;
   if(steps <= 0) steps = 1;

   // --- POC ---
   int y_poc     = y_bottom + (int)(dY * ((double)poc_idx + 0.5) / (double)steps);
   int poc_half  = MathMax(SafePOCWidth() / 2, 1);
   double poc_price = range_bottom + (poc_idx + 0.5) * resolution;
   canvas.FillRectangle(x_start, y_poc - poc_half, x_line_end, y_poc + poc_half,
                        GetARGB(InpColorPOCLine, 255));
   if(InpShowKeyLabels)
     {
      canvas.FontSet("Consolas", InpKeyLabelFontSize, FW_BOLD);
      string poc_str = "POC " + DoubleToString(poc_price, _Digits);
      canvas.TextOut(x_line_end - 2, y_poc - InpKeyLabelFontSize - 2,
                     poc_str, GetARGB(InpPOCLabelColor, 255), TA_RIGHT | TA_TOP);
     }

   // --- VAH / VAL ---
   if(InpShowVABounds)
     {
      int y_vah    = y_bottom + (int)(dY * ((double)va_high_idx + 1.0) / (double)steps);
      int y_val    = y_bottom + (int)(dY * ((double)va_low_idx)         / (double)steps);
      int va_half  = MathMax(SafeVAWidth() / 2, 1);
      double vah_price = range_bottom + (va_high_idx + 1) * resolution;
      double val_price = range_bottom + va_low_idx * resolution;

      canvas.FillRectangle(x_start, y_vah - va_half, x_line_end, y_vah + va_half,
                           GetARGB(InpColorVABounds, 210));
      canvas.FillRectangle(x_start, y_val - va_half, x_line_end, y_val + va_half,
                           GetARGB(InpColorVABounds, 210));

      if(InpShowKeyLabels)
        {
         canvas.FontSet("Consolas", InpKeyLabelFontSize, FW_NORMAL);
         string vah_str = "VAH " + DoubleToString(vah_price, _Digits);
         string val_str = "VAL " + DoubleToString(val_price, _Digits);
         canvas.TextOut(x_line_end - 2, y_vah - InpKeyLabelFontSize - 2,
                        vah_str, GetARGB(InpVALabelColor, 230), TA_RIGHT | TA_TOP);
         canvas.TextOut(x_line_end - 2, y_val + 3,
                        val_str, GetARGB(InpVALabelColor, 230), TA_RIGHT | TA_TOP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Remove all profile objects (histogram, labels, key lines)         |
//+------------------------------------------------------------------+
void ClearProfileObjects()
  {
   canvas.Erase(0);
   canvas.Update();
  }

//+------------------------------------------------------------------+
//| Main orchestrator — tick (zero-lag) or bar data, then draw       |
//+------------------------------------------------------------------+
void CalculateAndDraw()
  {
   // If the profile is toggled off, leave canvas blank
   if(!g_vpVisible)
      return;
   // Read range from selector only when it is visible/selectable;
   // otherwise use g_t1/g_t2 stored from the last visible position.
   if(ObjectFind(0, RECT_NAME) >= 0)
     {
      long tf = ObjectGetInteger(0, RECT_NAME, OBJPROP_TIMEFRAMES);
      if(tf != OBJ_NO_PERIODS) // selector is currently shown — update stored range
        {
         datetime pt1 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 0);
         datetime pt2 = (datetime)ObjectGetInteger(0, RECT_NAME, OBJPROP_TIME, 1);
         g_t1 = pt1;
         g_t2 = pt2;
        }
     }

   if(g_t1 == 0 && g_t2 == 0) return; // no range set yet

   datetime start_time = MathMin(g_t1, g_t2);
   datetime end_time   = MathMax(g_t1, g_t2);

   if(InpUseTicks && InpDynamic)
     {
      datetime now_t = TimeCurrent();
      end_time = MathMax(end_time, now_t);
      // Keep stored range in sync
      if(g_t1 >= g_t2) g_t1 = now_t; else g_t2 = now_t;
      // Update the selector object coordinates even when hidden
      // so it can be shown again at the correct position
      if(ObjectFind(0, RECT_NAME) >= 0)
        {
         int end_corner = (g_t1 >= g_t2) ? 0 : 1;
         ObjectSetInteger(0, RECT_NAME, OBJPROP_TIME, end_corner, now_t);
        }
     }

   double buckets_up[], buckets_down[];
   double range_bottom = 0, resolution = _Point;
   int    steps = 0;

   if(InpUseTicks)
     {
      int tick_count = GatherDataTicks(start_time, end_time,
                                        buckets_up, buckets_down,
                                        range_bottom, resolution, steps);
      if(tick_count <= 0)
        {
         ClearProfileObjects();
         return;
        }
     }
   else
     {
      double highs[], lows[], opens[], closes[];
      long   volumes[];
      int count = GatherData(start_time, end_time, highs, lows, opens, closes, volumes);
      if(count <= 0)
        {
         ClearProfileObjects();
         return;
        }

       double max_high = highs[ArrayMaximum(highs)];
       double min_low  = lows[ArrayMinimum(lows)];

       ComputeBucketGrid(min_low, max_high, resolution, range_bottom, steps);
       InitBuckets(buckets_up, buckets_down, steps);

      if(InpDistribution == VP_DIST_CLOSE)
         DistributeVolumeClose(count, highs, lows, opens, closes, volumes,
                               range_bottom, resolution, steps, buckets_up, buckets_down);
      else if(InpDistribution == VP_DIST_TRIANGULAR)
         DistributeVolumeTriangular(count, highs, lows, opens, closes, volumes,
                                    range_bottom, resolution, steps, buckets_up, buckets_down);
      else
         DistributeVolumeEven(count, highs, lows, opens, closes, volumes,
                              range_bottom, resolution, steps, buckets_up, buckets_down);
     }

   double total_volumes[];
   ArrayResize(total_volumes, steps);
   for(int i = 0; i < steps; i++)
      total_volumes[i] = buckets_up[i] + buckets_down[i];

   int    poc_idx = 0, va_high_idx = 0, va_low_idx = 0;
   double max_total_vol = 0;
   ComputeValueArea(total_volumes, steps, poc_idx, max_total_vol, va_high_idx, va_low_idx);

   if(max_total_vol <= 0) return;

   DrawBars(steps, range_bottom, resolution, buckets_up, buckets_down,
            max_total_vol, start_time, end_time,
            poc_idx, va_low_idx, va_high_idx);

   DrawKeyLines(poc_idx, va_high_idx, va_low_idx,
                range_bottom, resolution, start_time, end_time, steps);

   canvas.Update();
  }
//+------------------------------------------------------------------+