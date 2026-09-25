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

  // The comms marker: an envelope, worn over a figure's right shoulder while
  // it has sent or received a peer message recently (see web/comms.js for
  // "recently"). Its own 7x5 grid rather than a layer in the figure's, because
  // the top-right of the figure is where the raised arm and the hammer are,
  // and an envelope painted over either would cost the pose that says what
  // the session is doing. The page positions it out of flow, over the button.
  //   O rim (info)   f paper   v the flap's fold
  var ENVELOPE = [
    "OOOOOOO",
    "OvfffvO",
    "OfvfvfO",
    "OffvffO",
    "OOOOOOO",
  ];
  function comms() {
    var paths = toPaths(ENVELOPE);
    var fill = {O: "var(--info)", f: "#f4f5f7", v: "var(--px-line)"};
    return {
      w: ENVELOPE[0].length, h: ENVELOPE.length,
      parts: Object.keys(paths).sort().map(function (ch) {
        return {ch: ch, fill: fill[ch], d: paths[ch]};
      }),
    };
  }

  // The grass under the owner blocks. Two shades a few percent apart:
  // texture, never contrast — the owner's name and summary are printed on it.
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

  // ---- the world: hedges, walls, floors and rugs ---------------------------
  //
  // The three-quarter view of a 16-bit Zelda: the ground is seen from above,
  // and a wall shows its FRONT face only on the north side of whatever it
  // encloses — east, west and south walls show just their tops. That one
  // rule is the whole of the 2.5D, and it is why every frame below is taller
  // at the top than anywhere else.
  //
  //   owner   a field of grass, fenced by a hedge
  //   repo    a room in cutaway: a brick north wall casting a shadow onto a
  //           plank floor, stone caps on the other three sides. A repo with
  //           an unfinished run has SCORCHED, CRACKED bricks — a shape as
  //           well as a colour, beside the words that already say it
  //   branch  a rug on that floor, which its characters stand on
  //
  // ⚠️ Every frame is a 9-slice for CSS `border-image`, not a picture the
  // layout is fitted into. The board is ordinary flow layout on purpose (see
  // README, "a scrolling list of blocks"): it cannot lose a session off-screen,
  // and a world drawn as a fixed scene would bring back exactly the placement
  // problem the camera had. A border-image decorates whatever box flow layout
  // produced, so the map stays a list that happens to look like a place.
  //
  // Painted by rule rather than by hand: brick courses, planks and leaves are
  // regular, and a formula tiles seamlessly where a hand-drawn edge needs
  // care at every join.

  // A deterministic speckle, so the same pixel is the same leaf on every load.
  function noise(x, y, n) { return hash(x + "," + y) % n; }

  // Paint a w x h image from a function of (x, y) returning a colour or null.
  // Kept as cells so a test can ask what any pixel is without parsing SVG.
  function paint(w, h, px) {
    var cells = [];
    for (var y = 0; y < h; y++) {
      var row = [];
      for (var x = 0; x < w; x++) row.push(px(x, y) || null);
      cells.push(row);
    }
    return {w: w, h: h, cells: cells};
  }
  function toSvg(img) {
    var d = {};
    for (var y = 0; y < img.h; y++) {
      for (var x = 0; x < img.w;) {
        var c = img.cells[y][x];
        if (!c) { x++; continue; }
        var n = 1;
        while (x + n < img.w && img.cells[y][x + n] === c) n++;
        d[c] = (d[c] || "") + "M" + x + " " + y + "h" + n + "v1h-" + n + "z";
        x += n;
      }
    }
    // width/height equal to the viewBox, so a border-image-slice number is
    // one art pixel: CSS reads an SVG's slice in its intrinsic units.
    return "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 " + img.w + " " + img.h +
      "' width='" + img.w + "' height='" + img.h + "' shape-rendering='crispEdges'>" +
      Object.keys(d).sort().map(function (c) { return "<path fill='" + c + "' d='" + d[c] + "'/>"; }).join("") +
      "</svg>";
  }

  // Two palettes, because the world is printed on: the owner's name, the
  // repo slug and the branch labels sit on this grass and these floors, so
  // the dusk palette stays dark under light text and the day palette light
  // under dark text. tests/run.sh computes the contrast of the page's own
  // text tokens against every ground each one is printed on.
  var WORLD = {
    dark: {
      grass: "#121a17", blade: "#18251e",
      hedge: {top: "#2b4633", leaf: "#21392a", dark: "#15261b", line: "#0a120d"},
      wall: {cap: "#4a505c", capHi: "#575e6b", brick: "#353a45", brickHi: "#414754",
             mortar: "#262a32", line: "#0b0d12", shadow: "#0a0908"},
      scorched: {brick: "#4a2b28", brickHi: "#5b3430", mortar: "#2a1917", crack: "#0b0d12"},
      floor: {plank: "#1c1a16", grain: "#23201b", seam: "#110f0d"},
      rug: {edge: "#3b3049", dot: "#4e4061", field: "#1d1a23"},
    },
    light: {
      grass: "#f3f8f1", blade: "#e3eedf",
      hedge: {top: "#a9cf93", leaf: "#93bf7c", dark: "#79a764", line: "#4d7a3f"},
      wall: {cap: "#cfc4b4", capHi: "#ddd3c5", brick: "#bba993", brickHi: "#c9b9a4",
             mortar: "#a3927b", line: "#5c5044", shadow: "#ddd0bb"},
      scorched: {brick: "#d49a8f", brickHi: "#e0aca2", mortar: "#b07a70", crack: "#5c2e28"},
      floor: {plank: "#fbf7f0", grain: "#f5efe4", seam: "#e8dfd0"},
      // Softer than the dusk rug's contrast would suggest: at full strength
      // the daylight rugs outshouted the characters standing on them.
      rug: {edge: "#dccfeb", dot: "#cdbde2", field: "#fcfaff"},
    },
  };

  // The frames' geometry, in art pixels: the width of each side, and the
  // repeating middle. Exported so the page's border-image-slice and a test
  // read one set of numbers rather than two that could drift.
  var FRAME = {
    hedge: {t: 7, r: 3, b: 3, l: 3, m: 16},
    wall:  {t: 16, r: 4, b: 4, l: 4, m: 16},
    rug:   {t: 2, r: 2, b: 2, l: 2, m: 4},
  };
  function frameSize(f) { return {w: f.l + f.m + f.r, h: f.t + f.m + f.b}; }
  function inHole(f, x, y) { return x >= f.l && x < f.l + f.m && y >= f.t && y < f.t + f.m; }

  // The hedge round an owner's field: its top and front on the north side,
  // just its top elsewhere, and its shadow on the grass under the front.
  function hedge(p) {
    var f = FRAME.hedge, s = frameSize(f);
    return paint(s.w, s.h, function (x, y) {
      if (x === 0 || y === 0 || x === s.w - 1 || y === s.h - 1) return p.line;
      if (inHole(f, x, y)) return null;
      var inX = x >= f.l && x < f.l + f.m;
      if (inX && y >= 3 && y < f.t) {
        if (y === f.t - 1) return p.dark;               // shadow under the front
        return noise(x, y, 4) === 0 ? p.dark : p.leaf;   // the front face
      }
      if ((x === f.l - 1 || x === f.l + f.m) && y >= 3) return p.dark;
      if (inX && y === f.t + f.m) return p.dark;
      return noise(x, y, 6) === 0 ? p.leaf : p.top;      // the top of the hedge
    });
  }

  // A crack running down each 16-pixel run of bricks. Periodic with the
  // middle slice, so it repeats along the wall without a seam.
  var CRACK = {"3,0": 1, "4,1": 1, "4,2": 1, "5,3": 1, "6,4": 1, "6,5": 1,
               "11,1": 1, "12,2": 1, "11,3": 1, "12,4": 1};

  // A room's walls, cut away: the north wall's cap, its face in three brick
  // courses, the foot of the wall and its shadow on the floor; stone caps
  // on the east, west and south. Three courses and not two: at two, the
  // face read as trim along the top of a box rather than as a wall.
  function wall(p, scorched) {
    var f = FRAME.wall, s = frameSize(f);
    var b = scorched ? p.scorched || p : p;
    return paint(s.w, s.h, function (x, y) {
      if (x === 0 || y === 0 || x === s.w - 1 || y === s.h - 1) return p.line;
      if (inHole(f, x, y)) return null;
      var inX = x >= f.l && x < f.l + f.m;
      if ((x === f.l - 1 || x === f.l + f.m) && y >= 3) return p.line;   // cap rims
      if (inX && y === f.t + f.m) return p.line;
      if (inX && y >= 3 && y < f.t) {
        if (y === 3) return p.line;                  // where the cap meets the face
        if (y === f.t - 3) return p.line;            // the foot of the wall
        // ⚠️ Its shadow on the floor: a solid row, then a dithered one. A
        // single flat row was measured invisible on the dusk floor, and a
        // wall that casts no shadow reads as a stripe, not as a wall.
        if (y === f.t - 2) return p.shadow;
        if (y === f.t - 1) return (x + y) % 2 ? p.shadow : null;
        var fx = x - f.l, fy = y - 4;
        if (scorched && CRACK[fx + "," + fy]) return b.crack;
        var course = Math.floor(fy / 3), row = fy % 3;
        if (row === 2) return b.mortar;
        if ((fx + (course % 2 ? 4 : 0)) % 8 === 0) return b.mortar;
        return row === 0 ? b.brickHi : b.brick;
      }
      return noise(x, y, 5) === 0 ? p.capHi : p.cap;
    });
  }

  // A rug's woven edge. Its field is a flat background colour rather than a
  // pattern, because a branch's name is printed on it.
  function rug(p) {
    var f = FRAME.rug, s = frameSize(f);
    return paint(s.w, s.h, function (x, y) {
      if (inHole(f, x, y)) return null;
      if (x === 0 || y === 0 || x === s.w - 1 || y === s.h - 1) return p.edge;
      return (x + y) % 2 ? p.dot : p.edge;
    });
  }

  // Planks, four pixels to a board, their end joins staggered.
  function floor(p) {
    return paint(16, 16, function (x, y) {
      var board = Math.floor(y / 4);
      if (y % 4 === 3) return p.seam;
      if (x === (board * 7 + 3) % 16) return p.seam;
      return noise(x, y, 7) === 0 ? p.grain : p.plank;
    });
  }

  function grass(p) {
    return paint(16, 16, function (x, y) { return GRASS[y].charAt(x) === "x" ? p.blade : p.grass; });
  }

  // Everything the page paints for one palette, as SVG documents.
  function world(theme) {
    var p = WORLD[theme];
    return {
      grass: toSvg(grass(p)), floor: toSvg(floor(p)),
      hedge: toSvg(hedge(p.hedge)), rug: toSvg(rug(p.rug)),
      wall: toSvg(wall(p.wall, false)),
      wallScorched: toSvg(wall(Object.assign({}, p.wall, {scorched: p.scorched}), true)),
      rugField: p.rug.field,
    };
  }

  var api = {
    W: W, H: H, POSE: POSE, GLYPH: GLYPH,
    compose: compose, toPaths: toPaths, hash: hash, variant: variant,
    figure: figure, ENVELOPE: ENVELOPE, comms: comms,
    WORLD: WORLD, FRAME: FRAME, frameSize: frameSize,
    paint: paint, toSvg: toSvg, hedge: hedge, wall: wall, rug: rug, floor: floor,
    grass: grass, world: world,
  };

  root.CCWATCH_SPRITES = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
