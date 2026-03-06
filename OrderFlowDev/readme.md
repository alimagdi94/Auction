# Auction Trading Toolkit | مجموعة أدوات Auction للتداول

This toolkit provides a set of professional, institutional-grade indicators and utilities for MetaTrader 5 (MT5), focusing on advanced trade execution, order flow, and volume analysis.

توفر هذه المجموعة من الأدوات مؤشرات وأدوات احترافية لمنصة MetaTrader 5 (MT5)، مع التركيز على تنفيذ الصفقات المتقدم، وتدفق الطلبات (Order Flow)، وتحليل السيولة (Volume Analysis).

---

## Components / المكونات

### 1. Chart Trader (`charttrader`)
A Professional Chart Trader utility designed for fast, production-ready trade execution and management.
أداة تنفيذ صفقات احترافية مصممة لإدارة وتنفيذ الصفقات بسرعة وكفاءة عالية.

**Key Features / الميزات الأساسية:**
- **Execution:** Seamless Market and Pending order execution.
**التنفيذ:** تنفيذ أوامر السوق والأوامر المعلقة بسلاسة.
- **Risk Management:** Dynamic Risk-based or Manual lot sizing, quick assignable SL/TP.
**إدارة المخاطر:** تحديد حجم اللوت بناءً على المخاطرة أو يدويًا، مع تعيين سريع لمستويات وقف الخسارة وجني الأرباح.
- **On-Chart Visuals:** Drag-and-drop Visual SL/TP lines, zone tracking.
**مرئيات على الرسم البياني:** خطوط وقف الخسارة وجني الأرباح قابلة للسحب والإفلات، وتتبع المناطق.
- **UI Interface:** Drag-and-dock panel functionality with a minimal, scalable grayscale design. 
**واجهة المستخدم:** لوحة تحكم قابلة للسحب والتثبيت بتصميم عصري وبسيط.
- **Advanced Trade Management:** Scale-out options, automatic position flipping/reversals.
**إدارة متقدمة:** خيارات الخروج الجزئي وعكس المراكز تلقائيًا.
- **Keymapping:** Complete hotkey coverage for all major actions (Buy, Sell, Close All, etc.).
**مفاتيح الاختصار:** تغطية كاملة لجميع الإجراءات الرئيسية عبر لوحة المفاتيح.

---

### 2. Footprint Chart (`footprint`)
An industry-standard Footprint (Bid x Ask Cluster) chart indicator that models institutional-grade order flow.
مؤشر احترافي يحلل تدفق الطلبات (Order Flow) ويعرض تجمعات أحجام التداول (Bid/Ask).

**Key Features / الميزات الأساسية:**
- **Tick-by-Tick Analysis:** Analyzes tick data to build Bid (Sell) vs. Ask (Buy) volume clusters.
**تحليل التكات:** تحليل بيانات التكات لبناء تجمعات أحجام الشراء والبيع.
- **Imbalance Detection:** Highlights diagonal imbalances for aggressive buyer/seller identification.
**كشف عدم التوازن:** تمييز مناطق عدم التوازن القطري لتحديد المشترين والبائعين العدوانيين.
- **Core Order Flow Metrics:** Automatically calculates Point of Control (POC) and Value Area (VA).
**مقاييس تدفق الطلبات:** حساب تلقائي لنقطة التحكم (POC) ومنطقة القيمة (VA).
- **Performance:** Optimized CCanvas rendering with visual throttling to ensure zero UI lag.
**الأداء:** رندر سريع ومحسن لتجنب بطء الواجهة أثناء التداول النشط.
- **Interactive Controls:** Toggle cell numbers (Txt), adjust zoom, scaling, and imbalance ratios on the fly.
**تحكم تفاعلي:** إمكانية إخفاء الأرقام، تعديل الزوم، ونسب عدم التوازن بشكل مباشر.

---

### 3. Volume Profile (`volumeProfile`)
A dynamic Volume Profile indicator for tracking volume distribution and identifying high-liquidity zones.
مؤشر ديناميكي لتوزيع السيولة وتحديد مناطق الدعم والمقاومة الحقيقية بناءً على حجم التداول.

**Key Features / الميزات الأساسية:**
- **Multiple Data Models:** Full support for zero-lag tick data for maximum precision.
**نماذج بيانات متعددة:** دعم كامل لبيانات التكات الحقيقية بدقة عالية وبدون تأخير.
- **Dynamic Updates:** Live ticking updates, dynamically adapting to new incoming volume.
**تحديثات ديناميكية:** تحديثات مباشرة للبروفايل مع كل سيولة جديدة تدخل السوق.
- **Value Area (VA):** Displays VAH/VAL with distinct colors for volume distribution hierarchy.
**منطقة القيمة (VA):** عرض مستويات VAH/VAL مع تمييز لوني لتوزيع السيولة.
- **Point of Control (POC):** Clearly visualizes the Point of Control (most active price level).
**نقطة التحكم (POC):** تحديد واضح لأكثر مستوى سعري شهد سيولة.
- **Interactive Selector:** Interactive drag-and-drop box for custom range profiling.
**الاختيار التفاعلي:** صندوق تفاعلي قابل للسحب لتحديد نطاق سعري معين وتحليله.

---

## Installation / التثبيت

1. Open MetaTrader 5 Data Folder (`File -> Open Data Folder`).
افتح مجلد بيانات MetaTrader 5 (ملف -> فتح مجلد البيانات).
2. Copy `charttrader` into `MQL5/Experts/`.
انسخ `charttrader` إلى مجلد `MQL5/Experts/`.
3. Copy `footprint` and `volumeProfile` into `MQL5/Indicators/`.
انسخ `footprint` و `volumeProfile` إلى مجلد `MQL5/Indicators/`.
4. Compile the files in MetaEditor (`F4`).
قم بعمل Compile للملفات في MetaEditor (F4).
5. Ensure **"Allow Algo Trading"** is enabled for Chart Trader functionality.
تأكد من تفعيل **"Allow Algo Trading"** ليعمل منفذ الصفقات بشكل صحيح.