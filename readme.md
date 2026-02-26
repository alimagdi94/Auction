# Auction Trading Toolkit

This toolkit provides a set of professional, institutional-grade indicators and utilities for MetaTrader 5 (MT5), focusing on advanced trade execution, order flow, and volume analysis.

## Components

### 1. Chart Trader (`CT.mq5`)
A Professional Chart Trader utility designed for fast, production-ready trade execution and management.
**Key Features:**
- **Execution:** Seamless Market and Pending order execution.
- **Risk Management:** Dynamic Risk-based or Manual lot sizing, quick assignable SL/TP.
- **On-Chart Visuals:** Drag-and-drop Visual SL/TP lines on the chart, zone tracking.
- **UI Interface:** Drag-and-dock panel functionality with a minimal, scalable grayscale design. 
- **Advanced Trade Management:** Scale-out options, automatic position flipping/reversals.
- **Keymapping:** Complete hotkey coverage for nearly all major actions (Buy, Sell, Close All, Scale Out, Toggle Exec Mode, Panel minimize, etc.).

### 2. Footprint Chart (`FP.mq5`)
An industry-standard Footprint (Bid x Ask Cluster) chart indicator that models Sierra / Bookmap-style footprints.
**Key Features:**
- **Tick-by-Tick Analysis:** Analyzes tick data to build Bid (Sell) vs. Ask (Buy) volume clusters.
- **Imbalance Detection:** Highlights diagonal imbalances (Ask@N vs Bid@N+1 / Bid@N vs Ask@N-1).
- **Core Order Flow Metrics:** Automatically calculates Point of Control (POC) and Value Area (VA) per bar (default 70%).
- **Performance:** Optimized ~30 FPS CCanvas rendering with visual throttling to prevent UI lag.
- **Interactive Controls:** Features an on-chart panel to adjust zoom, scaling, cell size (ticks), imbalances ratio, and layout opacity on the fly. 

### 3. Volume Profile (`VP.mq5`)
A dynamic Volume Profile indicator for tracking volume distribution and identifying critical price levels.
**Key Features:**
- **Multiple Data Models:** Zero-lag tick data support or OHLCV timeframe data (Close, Even, Triangual Distribution).
- **Dynamic Recalculations:** Live ticking updates, dynamically adapting the profile to new incoming volume.
- **Value Area (VA):** Displays VAH/VAL and Value Area with distinct colors for Up vs. Down volume (VA 70%).
- **Point of Control (POC):** Clearly visualizes the Point of Control line over the profile hierarchy.
- **Visuals & Interactivity:** Left/Right profile alignments, filled histograms, customizable text rendering, and an interactive drag-and-drop selector box (`VP_Selector`) for custom range profiling.

## Installation

1. Open your MetaTrader 5 Data Folder (`File -> Open Data Folder`).
2. Copy `CT.mq5` into your `MQL5/Experts/` directory (since it handles trade execution). 
3. Copy `FP.mq5` and `VP.mq5` into your `MQL5/Indicators/` directory.
4. Open the MetaEditor (`F4`) and compile all three `.mq5` files.
5. Drag and drop onto any chart.
   - **Important:** Ensure the "Allow Algo Trading" setting is enabled in your MT5 Terminal for Chart Trader execution to function correctly.