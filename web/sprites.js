// ccwatch — the map's pixel art: the figures, the speech bubbles and the grass
// under the owner blocks, drawn on a 16x20 grid and turned into SVG paths.
//
// A static module beside web/md.js, web/roster.js, web/modal.js, web/alerts.js
// and web/usage.js, for the documented reason those exist: so tests/run.sh can
// require() it under node and assert on it without a browser. Pure — no DOM,
// no fetch, no timers. The page turns what this returns into elements.
//
// ⚠️ Hand-authored here, not a downloaded tileset. The first choice was the
// CC0 "Ninja Adventure" pack, and the network this was built on blocks its
// host outright ("FileHost" category), so the art is ours, in text, where a
// diff can show every pixel that changed. Swapping in a real tileset later
// means replacing the grids below; nothing outside this file draws a pixel.
//
// ⚠️ Pixels are PATHS, one per colour, with crispEdges — not a raster image
// scaled with `image-rendering: pixelated`. An <img> would need a decode that
// can still be pending when verify-ui measures the figure (a 0x0 box on a
// session that exists), and a raster cannot take its colour from a CSS token,
// so the tunic could not track the status in both themes. A path does both,
// and the SVG still scales in em with the root size as the old figure did.
//
// Every status also differs in SHAPE — a raised arm, a bubble with its own
// glyph, a hollow outline — because colour is never the only carrier of
// meaning (principle VII). The status word stays on the label and the title.
(function (root) {
  "use strict";

  var W = 16, H = 20;

  // One letter per colour slot. `.` is transparent. The slots that track the
  // status (t, T, O, g) are resolved by the caller's colour, so a theme change
  // repaints them for free; the rest are the character's own palette.
  //   o outline / eyes       s skin          h hair
  //   t tunic (status)       T tunic, shaded p trousers      b belt & boots
  //   m hammer head          w hammer handle d sweat drop
  //   O bubble rim (status)  f bubble fill   g bubble glyph
  var HEAD_OPEN = [
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....oooooo.....",
    "....ohhhhhho....",
    "...ohhhhhhhho...",
    "...ohssssssho...",
    "...ossessesso...",
    "...osssssssso...",
    "....oossssoo....",
  ];
  // Eyes shut: the pupils become two-pixel lids. Paired with the `z` bubble.
  var HEAD_SHUT = HEAD_OPEN.slice(0, 9).concat([
    "...oseesseeso...",
    "...osssssssso...",
    "....oossssoo....",
  ]);
  // Eyes dropped a row, looking at the floor, and a bead of sweat at the
  // temple. Paired with the `?` bubble: it says busy and has gone quiet.
  var HEAD_DOWN = HEAD_OPEN.slice(0, 8).concat([
    "...ohssssssho...",
    "...osssssssod...",
    "...ossessessod..",
    "....oossssoo....",
  ]);
  var TORSO = [
    "....otttttto....",
    "....oTttttTo....",
    "....oTttttTo....",
    "....obbbbbbo....",
    "....oppooppo....",
    "....oppooppo....",
    "...obbo..obbo...",
  ];

  // Arms are layers over rows 0-16, drawn after the body so they sit in front.
  function rows(at, lines) {
    var out = [];
    for (var y = 0; y < H; y++) out.push(lines[y - at] || "................");
    return out;
  }
  var ARM_L = rows(12, [
    "...o............",
    "..ot............",
    "..ot............",
    "..os............",
    "...o............",
  ]);
  var ARM_R = rows(12, [
    "............o...",
    "............to..",
    "............to..",
    "............so..",
    "............o...",
  ]);
  // The one that matters: the arm up beside the head on a session blocked on
  // you. It is its own group so the page can pump it (see .waiting .arm).
  var ARM_UP = rows(3, [
    ".............oo.",
    "............osso",
    "............otto",
    "............otto",
    "............otto",
    "............otto",
    "............otto",
    "............otto",
    "............oto.",
    "...........oto..",
  ]);
  // A hammer held up, for a session that is working.
  var ARM_WORK = rows(4, [
    "...........ommmo",
    "...........ommmo",
    "............owo.",
    ".............w..",
    ".............w..",
    ".............w..",
    ".............w..",
    "............oso.",
    "............oto.",
    "............to..",
    "............to..",
    "............so..",
    "............o...",
  ]);

  // The bubble sits top-left, clear of the raised arm on the right. A 3x5
  // glyph inside a 5x7 rim.
  function bubble(glyph) {
    var g = glyph.map(function (r) { return "O" + r.replace(/g/g, "g").replace(/\./g, "f") + "O"; });
    return rows(0, [".OOO."].concat(g, [".OOO."]).map(function (r) { return r + "...........".slice(0, W - 5); }));
  }
  var GLYPH = {
    bang:  [".g.", ".g.", ".g.", "...", ".g."],
    ask:   ["gg.", "..g", ".g.", "...", ".g."],
    sleep: ["ggg", "..g", ".g.", "g..", "ggg"],
  };

  // Which pose each map class wears. The classes are the page's own KIND
  // table's `cls`, so this adds shapes to a mapping and invents no status.
  var POSE = {
    waiting: {head: HEAD_OPEN, arms: [ARM_L], arm: ARM_UP,   bubble: "bang"},
    hung:    {head: HEAD_DOWN, arms: [ARM_L, ARM_R],         bubble: "ask"},
    busy:    {head: HEAD_OPEN, arms: [ARM_L, ARM_WORK]},
    idle:    {head: HEAD_SHUT, arms: [ARM_L, ARM_R],         bubble: "sleep"},
    quiet:   {head: HEAD_OPEN, arms: [ARM_L, ARM_R],         hollow: true},
  };

  // Layers over one another, later wins, `.` never overwrites.
  function compose(layers) {
    var grid = [];
    for (var y = 0; y < H; y++) {
      var line = "";
      for (var x = 0; x < W; x++) {
        var c = ".";
        for (var i = 0; i < layers.length; i++) {
          var ch = (layers[i][y] || "").charAt(x);
          if (ch && ch !== ".") c = ch;
        }
        line += c;
      }
      grid.push(line);
    }
    return grid;
  }

  // The cells of a grid that are drawn and touch an undrawn one (or the
  // border) on any of their four sides, as `o`: a one-pixel outline of the
  // whole silhouette.
  function edge(grid) {
    function on(x, y) { return y >= 0 && y < grid.length && x >= 0 && x < W && grid[y].charAt(x) !== "."; }
    return grid.map(function (line, y) {
      var r = "";
      for (var x = 0; x < W; x++)
        r += on(x, y) && !(on(x - 1, y) && on(x + 1, y) && on(x, y - 1) && on(x, y + 1)) ? "o" : ".";
      return r;
    });
  }

  // One path per colour letter, one rectangle per horizontal run. A 16x20
  // figure is ~120 filled pixels and ~45 runs, so this is what keeps a
  // figure at ten elements instead of a hundred on a board rebuilt every tick.
  function toPaths(grid) {
    var d = {};
    for (var y = 0; y < grid.length; y++) {
      var line = grid[y];
      for (var x = 0; x < line.length;) {
        var ch = line.charAt(x);
        if (ch === ".") { x++; continue; }
        var n = 1;
        while (line.charAt(x + n) === ch) n++;
        d[ch] = (d[ch] || "") + "M" + x + " " + y + "h" + n + "v1h-" + n + "z";
        x += n;
      }
    }
    return d;
  }

  // Who a session looks like: hair and skin from its id, so the same session
  // is the same character on every tick and in every tab, and two sessions in
  // one branch can be told apart before reading a label. FNV-1a, because it
  // is five lines and has no dependency; nothing here needs it to be strong.
  var HAIR = ["#3b2a20", "#6b3f1f", "#c8913a", "#2a2f45", "#8f2d2d", "#d9d2c3"];
  var SKIN = ["#f1c9a5", "#d9a47a", "#a86f4c", "#6e4630"];
  function hash(str) {
    var h = 0x811c9dc5;
    for (var i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h >>> 0;
  }
  function variant(sid) {
    var h = hash(String(sid || ""));
    return {hair: HAIR[h % HAIR.length], skin: SKIN[(h >>> 8) % SKIN.length]};
  }

  // The colour of each letter. `colour` is the status token the page already
  // uses for this session's label, e.g. "var(--ok)".
  function fills(colour, v) {
    return {
      o: "var(--px-line)", s: v.skin, h: v.hair,
      t: colour, T: colour, p: "#3b4252", b: "#5a3a22",
      m: "#c0c7d1", w: "#8b5a2b", d: "#7ec8ff",
      // ⚠️ A white bubble with a dark glyph, the status only on the rim. With
      // the glyph in the status colour too, rim and glyph merged at 2x and
      // `!` read as `H` and `?` as `A` — measured, at 8x, in a screenshot.
      O: colour, f: "#f4f5f7", g: "#1a1d23",
    };
  }

  // The whole figure, as the groups the page's CSS animates: `body` (bob,
  // sway), `arm` (the raised one) and `bubble` (throb). Each group is a list
  // of {ch, fill, d, opacity?}, `ch` being the colour letter it was drawn
  // from, so a test can ask what the tunic is painted with. `ctx` is 0-100 or null, and becomes a meter under
  // the feet — an RPG's bar, measuring the context window.
  function figure(cls, colour, sid, ctx) {
    var pose = POSE[cls] || POSE.quiet;
    var v = variant(sid);
    var f = fills(colour, v);
    var bodyGrid = compose([pose.head.concat(TORSO)].concat(pose.arms));
    var groups = {body: [], arm: [], bubble: []};

    function emit(into, grid, hollow) {
      if (hollow) {
        // The edge of the silhouette and nothing else, in the status colour:
        // alive, with nothing to corroborate it. ⚠️ The EDGE, not the `o`
        // pixels — those include the lines between arm and torso and between
        // the legs, and drawn alone they read as a pair of headphones.
        var d = toPaths(edge(grid)).o;
        if (d) into.push({ch: "o", fill: colour, d: d});
        return;
      }
      var paths = toPaths(grid);
      Object.keys(paths).sort().forEach(function (ch) {
        into.push({ch: ch, fill: f[ch], d: paths[ch]});
        // The shaded tunic is the tunic again under a translucent black, so
        // it darkens whatever the status colour is in either theme.
        if (ch === "T") into.push({ch: "T", fill: "#000", d: paths[ch], opacity: 0.3});
      });
    }
    emit(groups.body, bodyGrid, pose.hollow);
    if (pose.arm) emit(groups.arm, compose([pose.arm]), pose.hollow);
    if (pose.bubble) emit(groups.bubble, bubble(GLYPH[pose.bubble]), false);

    var meter = null;
    if (ctx != null) {
      var pct = Math.min(100, Math.max(0, ctx));
      // Ten cells, and any usage at all lights the first one: a bar that
      // reads empty at 4% would be a measurement drawn as an absence.
      var lit = pct === 0 ? 0 : Math.max(1, Math.round(pct / 10));
      meter = {
        x: 3, y: 19, cells: 10, lit: lit,
        fill: pct >= 80 ? "var(--bad)" : pct >= 60 ? "var(--warn)" : colour,
      };
    }
    return {w: W, h: H, groups: groups, meter: meter};
  }

  // A 16x16 grass tile for behind the owner blocks, as an SVG document for a
  // CSS background. Two shades a few percent apart: texture, never contrast —
  // the owner's name and summary are printed on top of it.
  var GRASS = [
    "................",
    "..x.............",
    "..x......x......",
    ".........x.x....",
    "................",
    "....x...........",
    "...xx.......x...",
    "............x...",
    "................",
    ".x......x.......",
    ".x.....xx.......",
    "..............x.",
    "..........x..xx.",
    "................",
    "....x...........",
    "...x........x...",
  ];
  function grassTile(base, blade) {
    var paths = toPaths(GRASS);
    return "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' width='32' height='32' shape-rendering='crispEdges'>" +
      "<rect width='16' height='16' fill='" + base + "'/>" +
      "<path fill='" + blade + "' d='" + paths.x + "'/></svg>";
  }

  var api = {
    W: W, H: H, POSE: POSE, GLYPH: GLYPH,
    compose: compose, toPaths: toPaths, hash: hash, variant: variant,
    figure: figure, grassTile: grassTile,
  };

  root.CCWATCH_SPRITES = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
