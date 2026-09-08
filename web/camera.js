// ccwatch — the camera: pan/zoom arithmetic, level-of-detail hysteresis and
// viewport persistence for the map.
//
// A third static file for the same reason web/md.js and web/plots.js are
// (see CLAUDE.md): so tests/run.sh can require() it under node and assert on
// it without a browser. Pure — no DOM, no fetch, no timers. Storage is
// reached only through loadView()/saveView()'s injected functions, so the
// suite can drive persistence without a browser and a throwing storage
// cannot take the map down.
(function (root) {
  "use strict";

  // §1 — frozen, index 0…7. Every entry is a whole number or the reciprocal
  // of one (FR-002), independent of viewport size and world extent.
  var LADDER = [0.25, 0.5, 1, 2, 3, 4, 6, 8];
  var WHEEL_THRESHOLD = 100;
  var PAN_STEP = 120;
  var PAN_STEP_BIG = 480;
  var DRAG_SLOP = 4;
  var STORAGE_VERSION = 1;

  // §2 — clampIdx floors non-integer input and clamps to the ladder's range,
  // so the caller can compare the returned index against the one it asked
  // for to decide whether a control is disabled (FR-017).
  function clampIdx(idx) {
    var i = Math.floor(idx);
    if (!isFinite(i)) i = 0;
    if (i < 0) i = 0;
    if (i > LADDER.length - 1) i = LADDER.length - 1;
    return i;
  }
  function scaleFor(idx) {
    return LADDER[clampIdx(idx)];
  }

  // §3 — one interval per axis, no branch: E.w·k > vw gives b < a and holds
  // the visible rectangle inside the extent; E.w·k < vw gives a < b and holds
  // the world inside the viewport (data-model.md §4).
  function clampAxis(t, k, e0, e1, v) {
    if (!isFinite(t)) return (v - (e0 + e1) * k) / 2 - e0 * k; // centred fallback
    var a = -e0 * k;
    var b = v - e1 * k;
    var lo = Math.min(a, b), hi = Math.max(a, b);
    if (t < lo) return lo;
    if (t > hi) return hi;
    return t;
  }
  function clampPan(view, extent, vw, vh) {
    if (!vw || !vh) return view;
    var k = scaleFor(view.idx);
    return {
      idx: view.idx,
      tx: clampAxis(view.tx, k, extent.x, extent.x + extent.w, vw),
      ty: clampAxis(view.ty, k, extent.y, extent.y + extent.h, vh),
    };
  }

  // §4/§5 — the largest rung both dimensions fit at, and the centred view at
  // it. `fitView` is the single answer to "no stored viewport", "an invalid
  // stored viewport", the `0` key and the fit button.
  function fitIndex(extent, vw, vh) {
    for (var i = LADDER.length - 1; i >= 0; i--) {
      var k = LADDER[i];
      if (extent.w * k <= vw && extent.h * k <= vh) return {idx: i, overflow: false};
    }
    return {idx: 0, overflow: true};
  }
  function fitView(extent, vw, vh) {
    var fi = fitIndex(extent, vw, vh);
    var k = scaleFor(fi.idx);
    var tx = (vw - extent.w * k) / 2 - extent.x * k;
    var ty = (vh - extent.h * k) / 2 - extent.y * k;
    var clamped = clampPan({idx: fi.idx, tx: tx, ty: ty}, extent, vw, vh);
    return {idx: clamped.idx, tx: clamped.tx, ty: clamped.ty, overflow: fi.overflow};
  }

  // §7 — panBy is the shared arithmetic behind both the drag path and the
  // arrow-key path (FR-005, FR-013). The caller clamps.
  function panBy(view, dx, dy) {
    return {idx: view.idx, tx: view.tx + dx, ty: view.ty + dy};
  }
  function centreOn(view, wx, wy, vw, vh, idx) {
    var i = idx == null ? view.idx : clampIdx(idx);
    var k = scaleFor(i);
    return {idx: i, tx: vw / 2 - wx * k, ty: vh / 2 - wy * k};
  }

  // §6 — one anchored zoom: the world point under (ax, ay) stays under it to
  // within a pixel (SC-004).
  function zoomTo(view, idx, ax, ay) {
    var k1 = scaleFor(view.idx);
    var wx = (ax - view.tx) / k1;
    var wy = (ay - view.ty) / k1;
    var k2 = scaleFor(idx);
    return {idx: clampIdx(idx), tx: ax - wx * k2, ty: ay - wy * k2};
  }

  // §8 — the hysteretic detail level (data-model.md §3). `prev == null` (the
  // cold mapping) resolves both bands downward, which is what makes FR-041
  // hold on a restore: the restored level always follows from the restored
  // scale alone, never from a level that no longer has a `prev`.
  function levelFor(idx, prev) {
    var i = clampIdx(idx);
    if (prev == null) {
      if (i >= 5) return "near";
      if (i >= 3) return "mid";
      return "far";
    }
    if (prev === "near") return i >= 4 ? "near" : (i >= 3 ? "mid" : "far");
    if (prev === "mid") return i >= 5 ? "near" : (i >= 2 ? "mid" : "far");
    // prev === "far"
    return i >= 5 ? "near" : (i >= 3 ? "mid" : "far");
  }

  // §9 — one wheel event, in normalised pixels. A sign change resets the
  // accumulator before adding so reversing a gesture responds immediately
  // rather than unwinding the prior direction first.
  function wheelStep(acc, event, pageHeight) {
    var dy = event.deltaY;
    var mode = event.deltaMode;
    var delta = mode === 1 ? dy * 16 : mode === 2 ? dy * (pageHeight || 0) : dy;
    if (delta !== 0 && acc !== 0 && (delta < 0) !== (acc < 0)) acc = 0;
    var next = acc + delta;
    if (Math.abs(next) >= WHEEL_THRESHOLD) {
      return {acc: 0, step: next < 0 ? -1 : 1};
    }
    return {acc: next, step: 0};
  }

  // §10 — the rejection table in data-model.md §6. Never throws.
  function validateView(raw, ladderLength) {
    if (raw == null) return null;
    var obj;
    if (typeof raw === "string") {
      try { obj = JSON.parse(raw); } catch (e) { return null; }
    } else {
      obj = raw;
    }
    if (typeof obj !== "object" || obj === null || Array.isArray(obj)) return null;
    if (obj.v !== STORAGE_VERSION) return null;
    var idx = obj.idx;
    if (typeof idx !== "number" || !isFinite(idx) || Math.floor(idx) !== idx) return null;
    if (idx < 0 || idx >= ladderLength) return null;
    var tx = obj.tx, ty = obj.ty;
    if (typeof tx !== "number" || !isFinite(tx)) return null;
    if (typeof ty !== "number" || !isFinite(ty)) return null;
    return {idx: idx, tx: tx, ty: ty};
  }

  var persistenceState = "ok";
  function loadView(getItem) {
    var raw;
    try { raw = getItem(); } catch (e) { markUnavailable(); return null; }
    return validateView(raw, LADDER.length);
  }
  function saveView(setItem, view) {
    var record = JSON.stringify({v: STORAGE_VERSION, idx: view.idx, tx: view.tx, ty: view.ty});
    try { setItem(record); } catch (e) { markUnavailable(); }
  }
  function markUnavailable() {
    persistenceState = "unavailable"; // first throw only — never reset, never retried (FR-040)
  }

  // §11 — the FR-038 intersection test, pure so the suite can assert the
  // "stored viewport far outside the world" case without a browser.
  function visibleWorldRect(view, vw, vh) {
    var k = scaleFor(view.idx);
    return {x: -view.tx / k, y: -view.ty / k, w: vw / k, h: vh / k};
  }
  function intersects(a, b) {
    if (![a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h].every(isFinite)) return false;
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  }

  var api = {
    LADDER: LADDER,
    WHEEL_THRESHOLD: WHEEL_THRESHOLD,
    PAN_STEP: PAN_STEP,
    PAN_STEP_BIG: PAN_STEP_BIG,
    DRAG_SLOP: DRAG_SLOP,
    STORAGE_VERSION: STORAGE_VERSION,
    scaleFor: scaleFor,
    clampIdx: clampIdx,
    clampPan: clampPan,
    fitIndex: fitIndex,
    fitView: fitView,
    zoomTo: zoomTo,
    panBy: panBy,
    centreOn: centreOn,
    levelFor: levelFor,
    wheelStep: wheelStep,
    validateView: validateView,
    loadView: loadView,
    saveView: saveView,
    visibleWorldRect: visibleWorldRect,
    intersects: intersects,
  };
  Object.defineProperty(api, "persistence", {
    get: function () { return persistenceState; },
  });

  root.CCWATCH_CAMERA = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
