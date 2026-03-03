// Bookmap Enhancement Patch v2 — all visual upgrades + bubble resolution cycling
const fs = require('fs');

const FILE = String.raw`c:\Users\ali.magdy\Desktop\Space\auction\orderflow.mq5`;
const buf = fs.readFileSync(FILE);
const isUTF16 = (buf[0] === 0xFF && buf[1] === 0xFE);
let txt = isUTF16 ? buf.toString('utf16le') : buf.toString('utf8');
const enc = isUTF16 ? 'utf16le' : 'utf8';
console.log(`Encoding: ${enc}, Length: ${txt.length}`);

let changes = 0;
function rep(old, nw, label) {
    if (txt.includes(old)) { txt = txt.replace(old, nw); changes++; console.log(`  [OK] ${label}`); }
    else { console.log(`  [SKIP] ${label}`); }
}

// === 1. BUBBLE COLORS — brighter ===
rep("C'30,210,60'", "C'40,240,80'", "Buy bubble -> bright green");
rep("C'210,30,30'", "C'240,50,30'", "Sell bubble -> bright red-orange");

// === 2. HEATMAP COLORS — blue/red like Bookmap ===
rep("C'15,0,20'", "C'10,15,40'", "Bid base -> deep blue");
rep("C'74,0,105'", "C'200,60,30'", "Bid high -> hot orange-red");
rep("C'0,15,15'", "C'5,20,35'", "Ask base -> deep blue-teal");
rep("C'0,64,64'", "C'20,140,200'", "Ask high -> bright cyan");

// === 3. BUBBLE DEFAULTS — start at 50pts resolution ===
rep("InpBubbleCellPts   = 200;", "InpBubbleCellPts   = 50;", "Bubble resolution default 200->50");
rep("InpMaxBubbleR      = 40;", "InpMaxBubbleR      = 60;", "Max bubble radius 40->60");
rep("InpMinBubbleR      = 8;", "InpMinBubbleR      = 10;", "Min bubble radius 8->10");
rep("InpBubbleMinPct    = 40.0;", "InpBubbleMinPct    = 20.0;", "Bubble threshold 40->20%");

// === 4. RING ALPHA — brighter ===
rep("(160 * g_opacity) / 255", "(220 * g_opacity) / 255", "Ring alpha 160->220");

// === 5. ADD g_bubblePts runtime variable ===
rep(
    "int                  g_basePts = 10; // runtime base cell size (points)",
    "int                  g_basePts = 10; // runtime base cell size (points)\r\nint                  g_bubblePts = 50; // runtime bubble resolution (points), cycles 50-100",
    "Add g_bubblePts variable"
);

// === 6. INIT g_bubblePts from input ===
rep(
    "g_bubbleStep = MathMax(1, MathMin(10000, InpBubbleCellPts)) * _Point;",
    "g_bubblePts  = MathMax(10, MathMin(10000, InpBubbleCellPts));\r\n   g_bubbleStep = g_bubblePts * _Point;",
    "Init g_bubblePts in OnInit"
);

// === 7. BUB BUTTON — cycle resolution 50->60->70->80->90->100->50 ===
rep(
    "g_showBubbles = !g_showBubbles;\r\n          g_dirty = true;",
    "// Cycle bubble resolution: 50->60->70->80->90->100->50\r\n          if(g_bubblePts >= 100)\r\n             g_bubblePts = 50;\r\n          else\r\n             g_bubblePts = g_bubblePts + 10;\r\n          g_bubbleStep = g_bubblePts * _Point;\r\n          if(g_bubbleStep < g_step) g_bubbleStep = g_step;\r\n          g_needs_reload = true;\r\n          g_dirty = true;",
    "Bub button -> cycle resolution 50-100"
);

// === 8. BUB BUTTON LABEL — show current pts instead of just "Bub" ===
rep(
    '"Bub", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);',
    'IntegerToString(g_bubblePts) + "B", FpARGB(clrWhite, 210), TA_CENTER | TA_VCENTER);',
    "Bub button label -> show resolution"
);

// === 9. BUBBLE BIAS FIX ===
rep("if(bAsk >= bBid && bAsk > 0)", "if(bAsk > bBid && bAsk > 0)", "Fix >= bias");
rep(
    "else if(bBid > 0)\r\n                   DrawRings(xc, ycr, maxR, InpSellBubbleCol, ringAlpha);",
    "else if(bBid > bAsk && bBid > 0)\r\n                   DrawRings(xc, ycr, maxR, InpSellBubbleCol, ringAlpha);\r\n                else if(bAsk > 0 || bBid > 0)\r\n                  {\r\n                   DrawRings(xc, ycr, maxR, InpBuyBubbleCol, ringAlpha / 2);\r\n                   DrawRings(xc, ycr, maxR, InpSellBubbleCol, ringAlpha / 2);\r\n                  }",
    "Sell bubble + equal case"
);

// === 10. DrawRings -> DrawBubble (filled gradient spheres) ===
const oldFunc = [
    'void DrawRings(int xc, int yc, int maxR, color col, int baseAlpha)',
    '  {',
    '   int rings = InpRingCount;',
    '   if(rings < 1) rings = 1;',
    '   int thick = InpRingThickness;',
    '   if(thick < 1) thick = 1;',
    '',
    '   double invRings = 1.0 / (double)rings;',
    '',
    '   for(int r = 0; r < rings; r++)',
    '     {',
    '      double frac = (double)(r + 1) * invRings;',
    '      int rad = (int)(maxR * frac);',
    '      if(rad < 2) rad = 2;',
    '',
    '      int ringAlpha = (int)(baseAlpha * (1.0 - frac * 0.5));',
    '      if(ringAlpha < 10) ringAlpha = 10;',
    '      uint argb = FpARGB(col, ringAlpha);',
    '',
    '      for(int t = 0; t < thick; t++)',
    '        {',
    '         int rr = rad + t;',
    '         if(rr > 0)',
    '            canvas.Circle(xc, yc, rr, argb);',
    '        }',
    '     }',
    '',
    '   // Bright core dot',
    '   int coreR = MathMax(1, maxR / 8);',
    '   canvas.FillCircle(xc, yc, coreR, FpARGB(clrWhite, baseAlpha / 2));',
    '  }'
].join('\r\n');

const newFunc = [
    'void DrawRings(int xc, int yc, int maxR, color col, int baseAlpha)',
    '  {',
    '   // Filled gradient sphere — Bookmap-style glowing orbs',
    '   if(maxR < 2) maxR = 2;',
    '   int steps = MathMin(maxR, 30);',
    '   for(int s = steps; s >= 0; s--)',
    '     {',
    '      int r = (int)((double)s / (double)steps * maxR);',
    '      if(r < 1) r = 1;',
    '      double frac = 1.0 - (double)s / (double)steps;',
    '      double intensity = frac * frac;',
    '      int alpha = (int)(baseAlpha * 0.12 + baseAlpha * 0.88 * intensity);',
    '      if(alpha > 255) alpha = 255;',
    '      if(alpha < 3) continue;',
    '      canvas.FillCircle(xc, yc, r, FpARGB(col, alpha));',
    '     }',
    '   int coreR = MathMax(2, maxR / 5);',
    '   canvas.FillCircle(xc, yc, coreR, FpARGB(clrWhite, MathMin(baseAlpha, 180)));',
    '  }'
].join('\r\n');

if (txt.includes(oldFunc)) {
    txt = txt.replace(oldFunc, newFunc);
    changes++;
    console.log("  [OK] DrawRings -> filled gradient sphere");
} else {
    console.log("  [SKIP] DrawRings replacement (not found or already changed)");
}

// === WRITE ===
if (changes > 0) {
    if (isUTF16) fs.writeFileSync(FILE, Buffer.from(txt, 'utf16le'));
    else fs.writeFileSync(FILE, txt, enc);
    console.log(`\n${changes} changes applied. Recompile in MetaEditor.`);
} else {
    console.log("\nNo changes made.");
}
