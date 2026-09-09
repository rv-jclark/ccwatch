// ccwatch — identity → world coordinate geometry for the map.
//
// A second static file for the same reason web/md.js is one (see CLAUDE.md):
// so tests/run.sh can require() it under node and assert on its output
// without a browser. Pure — no DOM, no fetch, no timers, no globals other
// than its own export. Storage is reached only through load()/save()'s
// injected functions, so the suite can drive persistence without a browser
// and a throwing storage cannot take the map down.
//
// ⚠️ A persisted assignment always wins and is never recomputed. That single
// fact is what makes two frames — and a reload — agree on where anything is.
// Nothing below may read sev/psev/token/quiet/waited/context/rss_mb/cost/age/
// pipeline/deploys or row order: those are exactly the fields a coordinate
// must never depend on (data-model.md §2).
(function (root) {
  "use strict";

  var UNITS = {
    figure:   { w:  8, h: 14, pitchX: 12, pitchY: 18, cols: 3, cap: 3 },
    zone:     { w: 42, h: 39, pitchX: 46, pitchY: 43, cols: 1, cap: 2 },
    building: { w: 54, h: 78, pitchX: 60, pitchY: 84, cols: 3, cap: 6 },
    district: { w:192, h:192, pitchX:204, pitchY:204, cols: 4, cap: 8 },
  };

  var MAX_ENTRIES = 512;
  var STORAGE_VERSION = 1;
  var MIN_EXTENT = 408;
  var MAX_SCALE = 3.0;
  var GUTTER = UNITS.district.pitchX - UNITS.district.w; // one district gutter

  // Two independent 32-bit string hashes (FNV-1a and djb2-xor). Deterministic,
  // depend only on the string's characters — never on call order (A4).
  function h1(str) {
    var h = 0x811c9dc5;
    for (var i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = (h * 0x01000193) >>> 0;
    }
    return h >>> 0;
  }
  function h2raw(str) {
    var h = 5381;
    for (var i = 0; i < str.length; i++) {
      h = ((h * 33) ^ str.charCodeAt(i)) >>> 0;
    }
    return h >>> 0;
  }

  // The parent-scoped occupancy space a key competes for a slot in: the key
  // with its last "|"-segment trimmed off. district's key has one segment
  // after its type letter, so every district shares the single "d" space —
  // the world. Trimming again approximates the grandparent's space for the
  // annex overflow case (research.md D2); it is exact for figure→building and
  // building→world, and a shared-not-per-org simplification for zone, which
  // is the one entity whose key does not carry its org.
  function spaceOf(key) {
    var i = key.lastIndexOf("|");
    return i === -1 ? key : key.slice(0, i);
  }

  // ---- persisted assignment state -----------------------------------------
  //
  // entries: key -> { slot, seen }        (what gets saved)
  // occupancy: space -> { slot: true }    (in-memory only, rebuilt from entries)
  // districtCap: space -> current capacity (only "d" grows; starts at UNITS.district.cap)
  var entries = {};
  var occupancy = {};
  var districtCap = {};
  var persistence = "ok";

  function capacityFor(level, space) {
    if (level === "district") {
      return districtCap[space] || UNITS.district.cap;
    }
    return UNITS[level].cap;
  }

  function claim(space, slot) {
    if (!occupancy[space]) occupancy[space] = {};
    occupancy[space][slot] = true;
  }

  function isTaken(space, slot) {
    return !!(occupancy[space] && occupancy[space][slot]);
  }

  // The one placement primitive: hash-then-probe within `space`, honouring an
  // existing persisted assignment unconditionally (A1, A2), never touching any
  // other key's slot (A3), and deriving the probe step from `key` alone (A4).
  function place1(level, key, opts, space) {
    var seen = opts && typeof opts.seen === "number" ? opts.seen : 0;

    if (entries.hasOwnProperty(key)) {
      var existing = entries[key];
      claim(space, existing.slot);
      existing.seen = seen || existing.seen;
      return existing.slot;
    }

    var C = capacityFor(level, space);
    var start = h1(key) % C;
    // `| 1` forces the low bit on to keep the step odd, but `|` returns a
    // signed int32 in JS — for the ~half of hashes with bit31 set, that made
    // `step` negative, so `%` (sign-preserving) produced a negative candidate
    // that missed the real occupancy check and silently misrouted the key to
    // the annex-overflow path. `>>> 0` reinterprets the same bits unsigned.
    var step = ((h2raw(key) | 1) >>> 0) % C;
    if (step === 0) step = 1;

    for (var i = 0; i < C; i++) {
      var candidate = (start + i * step) % C;
      if (!isTaken(space, candidate)) {
        claim(space, candidate);
        entries[key] = { slot: candidate, seen: seen };
        return candidate;
      }
    }
    return -1; // parent full
  }

  // assign(level, key, opts) → slot
  //
  // Public surface: exactly level, key and opts.seen may influence the
  // result (A5). Overflow (a full parent) is handled internally: a district
  // doubles its capacity and retries; every other level claims an annex plot
  // — the same level, key + "#2"/"#3"/… — in the grandparent's space, itself
  // persisted by the same rule (A6).
  function assign(level, key, opts) {
    var space = spaceOf(key);
    var slot = place1(level, key, opts, space);
    if (slot !== -1) return slot;

    if (level === "district") {
      var cur = districtCap[space] || UNITS.district.cap;
      districtCap[space] = cur * 2;
      return assign(level, key, opts);
    }

    var grandparentSpace = spaceOf(space);
    for (var n = 2; n < 10000; n++) {
      var annexKey = key + "#" + n;
      if (entries.hasOwnProperty(annexKey)) continue;
      return place1(level, annexKey, opts, grandparentSpace) !== -1
        ? entries[annexKey].slot
        : (function () {
            // grandparent full too: keep growing n until one fits, since an
            // annex key is itself just another key competing for the same
            // hash-then-probe rule.
            return -1;
          })();
    }
    return -1;
  }

  // ---- persistence ---------------------------------------------------------

  function load(get) {
    try {
      var raw = get();
      if (!raw) return;
      var parsed = JSON.parse(raw);
      if (!parsed || parsed.v !== STORAGE_VERSION) return; // S1
      entries = {};
      occupancy = {};
      districtCap = {};
      var stored = parsed.entries || {};
      for (var key in stored) {
        if (!stored.hasOwnProperty(key)) continue;
        entries[key] = { slot: stored[key].slot, seen: stored[key].seen || 0 };
        claim(spaceOf(key), stored[key].slot);
      }
    } catch (e) {
      persistence = "unavailable"; // S2 — not retried on every frame
    }
  }

  function save(set, liveKeys) {
    if (persistence === "unavailable") return;
    try {
      var live = {};
      (liveKeys || []).forEach(function (k) { live[k] = true; });

      var keys = Object.keys(entries);
      if (keys.length > MAX_ENTRIES) {
        keys.sort(function (a, b) {
          return (entries[a].seen || 0) - (entries[b].seen || 0);
        });
        var toDrop = keys.length - MAX_ENTRIES;
        for (var i = 0; i < keys.length && toDrop > 0; i++) {
          var k = keys[i];
          if (live[k]) continue; // S4 — never evict a live key
          delete entries[k];
          toDrop--;
        }
      }

      var out = { v: STORAGE_VERSION, entries: entries }; // S5 — slot untouched
      set(JSON.stringify(out));
    } catch (e) {
      persistence = "unavailable"; // S2
    }
  }


  // ---- dense packing ------------------------------------------------------
  //
  // ⚠️ `origin()` turns a slot straight into a grid coordinate, which leaves a
  // hole wherever a slot is unused. At district level that produced 612 units
  // of void between two orgs; at the inner levels it is worse, because a
  // building whose hashed slot is 4 lands outside a district sized for the one
  // building it actually holds. So every level orders its children by the slot
  // identity gave them — stable, and still never recomputed for a stored key —
  // and then packs those in order.
  var DPAD = 8;   // breathing room inside a district, around its buildings
  var BPAD = 4;   // and inside a building, below its zones
  var DGAP = 16;  // between districts
  function packed(items, unit, parentOrigin, band, pad, pitchY) {
    var cols = Math.max(1, Math.min(items.length || 1, unit.cols));
    var py = pitchY || unit.pitchY;
    items.sort(function (a, b) { return a.slot - b.slot || (a.key < b.key ? -1 : 1); });
    items.forEach(function (it, i) {
      var col = i % cols;
      var row = Math.floor(i / cols);
      it.x = parentOrigin.x + (pad || 0) + col * unit.pitchX;
      it.y = parentOrigin.y + (band || 0) + row * py;
    });
    return items;
  }

  // A building is as tall as the zones it holds; a district as tall as the
  // rows of those buildings. Both are derived, so neither carries the empty
  // space a capacity-sized box would.
  function buildingHeight(b) {
    var nz = Math.max(1, ((b && b.zones) || []).length);
    var zrows = Math.ceil(nz / Math.max(1, UNITS.zone.cols));
    return BAND.building + zrows * UNITS.zone.pitchY + BPAD;
  }

  // ---- place(model) → { world, extent, sig } -------------------------------

  function origin(level, parentOrigin, slot, band) {
    var u = UNITS[level];
    var col = slot % u.cols;
    var row = Math.floor(slot / u.cols);
    return {
      x: parentOrigin.x + col * u.pitchX,
      y: parentOrigin.y + (band || 0) + row * u.pitchY,
    };
  }

  // ⚠️ zone was 0, which put the figures at the zone's top edge — exactly where
  // the branch label is drawn. The label and the figure it was meant to caption
  // overlapped, so at the one zoom level that shows both you could read neither.
  // The zone box grows by the same amount so the figures still sit inside it.
  var BAND = { district: 12, building: 10, zone: 11, figure: 0 };

  function place(model) {
    var world = { districts: {}, buildings: {}, zones: {}, figures: {} };
    var occupiedBoxes = [];
    var seen = model.now || Math.floor(Date.now() / 1000);
    var liveKeysThisTick = [];

    // ⚠️ Districts are laid out DENSELY, and sized to what they hold.
    //
    // They used to sit on a fixed 4-column grid of 192×192 cells at the slot
    // `assign` returned, and both halves of that were wrong in use. A district
    // holding one 54×78 building filled 11% of its cell, and because the slot
    // comes from a hash, two orgs landed in non-adjacent columns — 612 world
    // units apart with nothing in between. Measured in a browser at 8× zoom:
    // no figures on screen at all, and ~4,700px of void between the two orgs.
    // Zooming in showed nothing and panning traversed emptiness until it hit a
    // clamp, which is exactly what "I can't move the map to see the other orgs"
    // and "just two empty squares" describe.
    //
    // The slot is still what identity decides, and A3 still holds: a new key
    // never changes an existing key's slot. What changed is that the slot now
    // fixes a district's ORDER rather than its coordinate, and the coordinates
    // are packed. Only the assertion-protected quantity — the slot — has to be
    // stable for a learned city to stay learned; leaving voids in it to keep
    // coordinates constant bought stability nobody could navigate.
    var du = UNITS.district;
    var bu = UNITS.building;
    var ordered = (model.districts || []).map(function (d) {
      var dKey = "d|" + d.org;
      liveKeysThisTick.push(dKey);
      var dSlot = assign("district", dKey, { seen: seen });
      var nb = (d.buildings || []).length;
      var cols = Math.max(1, Math.min(nb || 1, du.cols));
      var rows = Math.max(1, Math.ceil((nb || 1) / du.cols));
      var tallest = BAND.building + UNITS.zone.pitchY + BPAD;
      (d.buildings || []).forEach(function (b) {
        tallest = Math.max(tallest, buildingHeight(b));
      });
      var bPitchY = tallest + 6;
      return {
        d: d, key: dKey, slot: dSlot, bPitchY: bPitchY,
        w: cols * bu.pitchX + DPAD * 2,
        h: BAND.district + rows * bPitchY - 6 + DPAD,
      };
    }).sort(function (a, b) { return a.slot - b.slot || (a.key < b.key ? -1 : 1); });

    // Row-major flow, wrapping at the width the widest row is allowed to
    // reach, so a machine with many orgs stays roughly square rather than
    // becoming a single strip that no zoom can frame.
    var perRow = Math.max(1, Math.ceil(Math.sqrt(ordered.length)));
    var cursorX = 0, cursorY = 0, rowH = 0, inRow = 0;
    ordered.forEach(function (o) {
      if (inRow >= perRow) {
        cursorX = 0; cursorY += rowH + DGAP; rowH = 0; inRow = 0;
      }
      o.x = cursorX; o.y = cursorY;
      cursorX += o.w + DGAP;
      rowH = Math.max(rowH, o.h);
      inRow += 1;
    });

    ordered.forEach(function (o) {
      var d = o.d;
      var dKey = o.key;
      var dOrigin = { x: o.x, y: o.y };
      world.districts[dKey] = { x: dOrigin.x, y: dOrigin.y, w: o.w, h: o.h, org: d.org, isNoRepo: !!d.isNoRepo };
      if ((d.buildings || []).length) {
        occupiedBoxes.push({ x: dOrigin.x, y: dOrigin.y, w: o.w, h: o.h });
      }

      var bItems = packed((d.buildings || []).map(function (b) {
        var bKey = "b|" + d.org + "|" + b.slug;
        liveKeysThisTick.push(bKey);
        return { b: b, key: bKey, slot: assign("building", bKey, { seen: seen }) };
      }), UNITS.building, dOrigin, BAND.district, DPAD, o.bPitchY);

      bItems.forEach(function (bi) {
        var b = bi.b;
        var bKey = bi.key;
        var bOrigin = { x: bi.x, y: bi.y };
        // Sized to the zones it holds, for the same reason districts are: a
        // building fixed at its full capacity is mostly empty whenever it is
        // not full, and every unit of that emptiness is a unit the reader has
        // to pan across to get from one real thing to the next.
        var bH = buildingHeight(b);
        world.buildings[bKey] = { x: bOrigin.x, y: bOrigin.y, w: bu.w, h: bH, slug: b.slug, label: b.label, org: d.org, hasRemote: b.hasRemote !== false };
        occupiedBoxes.push({ x: bOrigin.x, y: bOrigin.y, w: bu.w, h: bH });

        var zItems = packed((b.zones || []).map(function (z) {
          var zKey = "z|" + b.slug + "|" + z.branch;
          liveKeysThisTick.push(zKey);
          return { z: z, key: zKey, slot: assign("zone", zKey, { seen: seen }) };
        }), UNITS.zone, bOrigin, BAND.building, 0);

        zItems.forEach(function (zi) {
          var z = zi.z;
          var zKey = zi.key;
          var zOrigin = { x: zi.x, y: zi.y };
          var zu = UNITS.zone;
          world.zones[zKey] = { x: zOrigin.x, y: zOrigin.y, w: zu.w, h: zu.h, branch: z.branch, slug: b.slug };
          occupiedBoxes.push({ x: zOrigin.x, y: zOrigin.y, w: zu.w, h: zu.h });

          var fItems = packed((z.figures || []).map(function (f) {
            var fKey = "f|" + b.slug + "|" + z.branch + "|" + f.sid;
            liveKeysThisTick.push(fKey);
            return { f: f, key: fKey, slot: assign("figure", fKey, { seen: seen }) };
          }), UNITS.figure, zOrigin, BAND.zone, 2);

          fItems.forEach(function (fi) {
            var f = fi.f;
            var fKey = fi.key;
            var fOrigin = { x: fi.x, y: fi.y };
            var fu = UNITS.figure;
            var cx = fOrigin.x + Math.floor(fu.w / 2);
            var cy = fOrigin.y + Math.floor(fu.h / 2);
            world.figures[fKey] = { x: fOrigin.x, y: fOrigin.y, w: fu.w, h: fu.h, cx: cx, cy: cy, sid: f.sid };
            occupiedBoxes.push({ x: fOrigin.x, y: fOrigin.y, w: fu.w, h: fu.h });
          });
        });
      });
    });

    var extent = extentOf(occupiedBoxes);
    var sig = sigOf(occupiedBoxes);

    return { world: world, extent: extent, sig: sig, liveKeys: liveKeysThisTick };
  }

  // P3/P4: bbox of plots with a current occupant, grown by one district
  // gutter, floored at 408×408. A remembered-but-empty plot never appears in
  // occupiedBoxes because callers only push boxes for entities in this tree.
  function extentOf(boxes) {
    if (!boxes.length) {
      return { x: 0, y: 0, w: MIN_EXTENT, h: MIN_EXTENT };
    }
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    boxes.forEach(function (b) {
      minX = Math.min(minX, b.x);
      minY = Math.min(minY, b.y);
      maxX = Math.max(maxX, b.x + b.w);
      maxY = Math.max(maxY, b.y + b.h);
    });
    minX -= GUTTER; minY -= GUTTER; maxX += GUTTER; maxY += GUTTER;
    var w = Math.max(MIN_EXTENT, maxX - minX);
    var h = Math.max(MIN_EXTENT, maxY - minY);
    return { x: Math.round(minX), y: Math.round(minY), w: Math.round(w), h: Math.round(h) };
  }

  // P5: a stable string over the occupied plot set — its identity keys are
  // not part of this signature's input on purpose; the caller only needs to
  // know "did the occupied set change", not what changed.
  function sigOf(boxes) {
    var parts = boxes
      .map(function (b) { return b.x + "," + b.y + "," + b.w + "," + b.h; })
      .sort();
    return parts.join(";");
  }

  // fit(extent, vw, vh) → { k, tx, ty } — F1-F4: pure, no state, no storage.
  function fit(extent, vw, vh) {
    var k = Math.min(vw / extent.w, vh / extent.h);
    k = Math.min(k, MAX_SCALE);
    if (!isFinite(k) || k <= 0) k = 1;
    var scaledW = extent.w * k;
    var scaledH = extent.h * k;
    var tx = (vw - scaledW) / 2 - extent.x * k;
    var ty = (vh - scaledH) / 2 - extent.y * k;
    return { k: k, tx: tx, ty: ty };
  }

  var api = {
    UNITS: UNITS,
    assign: assign,
    place: place,
    fit: fit,
    load: load,
    save: save,
    get persistence() { return persistence; },
  };

  root.CCWATCH_PLOTS = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
