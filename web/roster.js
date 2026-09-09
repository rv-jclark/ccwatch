// ccwatch — the roster: pure data shaping for the docked agent-list panel on
// the map (contracts/roster-js.md).
//
// A fourth static module beside web/md.js, web/plots.js and web/camera.js,
// for the documented reason those exist: so tests/run.sh can require() it
// under node and assert on it without a browser. Pure — no DOM, no fetch, no
// timers, no localStorage reference. Storage is reached only through
// injected getItem/setItem.
(function (root) {
  "use strict";

  // §1 — frozen, independent of viewport size and of the payload
  // (contracts/roster-js.md §1).
  var STORAGE_VERSION = 1;
  var WIDTH_DEFAULT = 320;
  var WIDTH_MIN = 220;
  var WIDTH_MAX_PX = 560;
  var WIDTH_MAX_FRAC = 0.45;
  var WIDTH_STEP = 16;
  var WIDTH_STEP_BIG = 64;
  var STACK_BREAKPOINT = 720;
  var NEAR_IDX = 5;
  var ASK_CHARS = 100;

  // §2 — the page's existing duration formatter (web/map.html:308-310),
  // copied here so the page can delegate to one formatter instead of two.
  function dur(s) {
    if (s == null) return "-";
    s = Math.max(0, s);
    return s < 60 ? Math.floor(s) + "s"
      : s < 3600 ? Math.floor(s / 60) + "m"
      : s < 86400 ? Math.floor(s / 3600) + "h"
      : Math.floor(s / 86400) + "d";
  }

  // §2 — the measurement, reproducing the terminal's last column
  // (bin/ccwatch:1092-1097, data-model.md §2) so the two renderings of one
  // snapshot read the same. Absent (not "-") when nothing applies (R1).
  function measureOf(row) {
    if (row.waited != null) return (row.note || "") + " " + dur(row.waited);
    if (row.note === "quiet") return "quiet " + dur(row.quiet);
    if (row.note) return row.note;
    if (row.quiet != null) return dur(row.quiet) + " ago";
    return undefined;
  }

  // §2 rowFields(row, opts) — the textual representation of one session
  // (data-model.md §1). Never derives a status: every field is either a
  // verbatim copy of a payload value or a fixed join of verbatim values.
  // Absent readings are absent keys — never 0/"0%"/"0MB"/"-"/null (R1).
  function rowFields(row, opts) {
    var volatile = !!(opts && opts.volatile);
    var out = {
      sid: row.sid,
      name: row.name,
      where: row.repo ? (row.repo + " · " + row.branch) : "no repo",
      word: row.token,
    };
    var measure = measureOf(row);
    if (measure !== undefined) out.measure = measure;
    if (row.age != null) out.age = dur(row.age);
    if (row.pipeline != null) {
      out.pipeline = row.pipeline.phase + "/"
        + (row.pipeline.crashed ? "CRASHED" : row.pipeline.status);
    }
    if (row.questions && row.questions.length) {
      var q = String(row.questions[0].question);
      out.asks = q.length > ASK_CHARS ? q.slice(0, ASK_CHARS) : q;
    }
    if (volatile && row.context != null && row.context.used_percentage != null) {
      out.ctx = "ctx " + Math.floor(row.context.used_percentage) + "%";
    }
    if (volatile && row.rss_mb != null) {
      out.mem = row.rss_mb + "MB";
    }
    return out;
  }

  // §3 titleText(row, volatile) — the figure <title> string, joining
  // rowFields's own output with " · " in titleBits's existing order
  // (word, ASKS:, measure, pipeline, age, ctx, mem) so the figure's hover
  // reading and the roster row can never state different things (FR-012).
  function titleText(row, volatile) {
    var f = rowFields(row, {volatile: volatile});
    var bits = [f.word];
    if (f.asks != null) bits.push("ASKS: " + f.asks);
    if (f.measure != null) bits.push(f.measure);
    if (f.pipeline != null) bits.push(f.pipeline);
    if (f.age != null) bits.push("age " + f.age);
    if (f.ctx != null) bits.push(f.ctx);
    if (f.mem != null) bits.push(f.mem);
    return bits.join(" · ");
  }

  // §4 keysOf(sessions) — the roster's order is s.sessions's own array order
  // (data-model.md §3, D2): no comparator lives here.
  function keysOf(sessions) {
    var keys = [];
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].sid != null) keys.push(sessions[i].sid);
    }
    return keys;
  }

  // §4 reorderPlan(currentKeys, wantedKeys) — the minimal [{key, before}]
  // move list that turns currentKeys into wantedKeys. Removal is
  // reconcile()'s job, not this function's (O-C).
  function reorderPlan(currentKeys, wantedKeys) {
    var present = {};
    for (var i = 0; i < currentKeys.length; i++) {
      if (wantedKeys.indexOf(currentKeys[i]) !== -1) present[currentKeys[i]] = true;
    }
    var seq = [];
    for (var j = 0; j < currentKeys.length; j++) {
      if (present[currentKeys[j]]) seq.push(currentKeys[j]);
    }
    var wanted = [];
    for (var k = 0; k < wantedKeys.length; k++) {
      if (present[wantedKeys[k]]) wanted.push(wantedKeys[k]);
    }
    var moves = [];
    // Walk wanted left to right; whenever the next key in `seq` (our working
    // copy of the current order) is not the key `wanted` expects there,
    // move that key to just before it — a single insertBefore per mismatch.
    for (var idx = 0; idx < wanted.length; idx++) {
      if (seq[idx] === wanted[idx]) continue;
      var key = wanted[idx];
      var pos = seq.indexOf(key);
      seq.splice(pos, 1);
      seq.splice(idx, 0, key);
      var before = idx + 1 < wanted.length ? wanted[idx + 1] : null;
      moves.push({key: key, before: before});
    }
    return moves;
  }

  // §4 focusTarget(prevSid, wantedKeys) — prevSid when still present, else
  // null (D4): roving tabindex is restored by identity, not by position.
  function focusTarget(prevSid, wantedKeys) {
    return wantedKeys.indexOf(prevSid) !== -1 ? prevSid : null;
  }

  // §4 nextFocus(keys, currentSid, key) — clamped, never wrapping (K-A, K-B);
  // a currentSid no longer present resolves to the first key (K-D); an empty
  // list resolves to null for every key (K-E).
  function nextFocus(keys, currentSid, key) {
    if (!keys.length) return null;
    if (key === "Home") return keys[0];
    if (key === "End") return keys[keys.length - 1];
    var i = keys.indexOf(currentSid);
    if (i === -1) return keys[0];
    if (key === "ArrowDown") return keys[Math.min(i + 1, keys.length - 1)];
    if (key === "ArrowUp") return keys[Math.max(i - 1, 0)];
    return keys[i];
  }

  // §5 resolveSelection(storedSid, sessions, cond) — {state, sid}
  // (data-model.md §4). "gone" is unreachable from an untrusted tick (S2):
  // a feed that cannot be read is not evidence a session exited.
  function resolveSelection(storedSid, sessions, cond) {
    if (storedSid == null) return {state: "none", sid: storedSid};
    var trust = cond && cond.trust;
    var present = false;
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].sid === storedSid) { present = true; break; }
    }
    if (present) return {state: "present", sid: storedSid};
    if (trust === "ok") return {state: "gone", sid: storedSid};
    return {state: "unknown", sid: storedSid};
  }

  // §5 flyIdx(level) — the camera rung a "far" selection flies to (D18); the
  // camera decides for itself when already mid/near (S-H).
  function flyIdx(level) {
    return level === "far" ? NEAR_IDX : null;
  }

  // §7 — the rejection table for the two stored records (data-model.md §8),
  // mirroring web/camera.js's validateView (web/camera.js:131-148).
  var SID_RE = /^[0-9a-fA-F-]{1,64}$/;

  function validateSelection(raw) {
    if (raw == null) return null;
    var obj;
    if (typeof raw === "string") {
      try { obj = JSON.parse(raw); } catch (e) { return null; }
    } else {
      obj = raw;
    }
    if (typeof obj !== "object" || obj === null || Array.isArray(obj)) return null;
    if (obj.v !== STORAGE_VERSION) return null;
    var sid = obj.sid;
    if (typeof sid !== "string" || !SID_RE.test(sid)) return null;
    return {sid: sid};
  }

  function validateWidth(raw) {
    if (raw == null) return null;
    var obj;
    if (typeof raw === "string") {
      try { obj = JSON.parse(raw); } catch (e) { return null; }
    } else {
      obj = raw;
    }
    if (typeof obj !== "object" || obj === null || Array.isArray(obj)) return null;
    if (obj.v !== STORAGE_VERSION) return null;
    var w = obj.w;
    if (typeof w !== "number" || !isFinite(w)) return null;
    return {w: w};
  }

  var persistenceState = "ok";
  function markUnavailable() {
    persistenceState = "unavailable"; // first throw only — never reset, never retried
  }

  function loadSelection(getItem) {
    var raw;
    try { raw = getItem(); } catch (e) { markUnavailable(); return null; }
    return validateSelection(raw);
  }
  function saveSelection(setItem, sid) {
    var record = JSON.stringify({v: STORAGE_VERSION, sid: sid});
    try { setItem(record); } catch (e) { markUnavailable(); }
  }
  function loadWidth(getItem) {
    var raw;
    try { raw = getItem(); } catch (e) { markUnavailable(); return null; }
    return validateWidth(raw);
  }
  function saveWidth(setItem, w) {
    var record = JSON.stringify({v: STORAGE_VERSION, w: w});
    try { setItem(record); } catch (e) { markUnavailable(); }
  }

  // §6 clampWidth(w, windowWidth) — the panel can never exceed what the
  // current window can accommodate, nor shrink below WIDTH_MIN (W-A…W-F). A
  // non-finite or non-number width is not a reading to clamp — it is
  // WIDTH_DEFAULT (W-D).
  function clampWidth(w, windowWidth) {
    if (typeof w !== "number" || !isFinite(w)) w = WIDTH_DEFAULT;
    var upper = Math.min(WIDTH_MAX_PX, WIDTH_MAX_FRAC * windowWidth);
    return Math.min(Math.max(w, WIDTH_MIN), upper);
  }

  // §6 stacked(windowWidth) — mirrors the @media breakpoint (page-roster.md
  // §2); this function is not the carrier of the stacking behaviour, the
  // media query is, but both read STACK_BREAKPOINT so they cannot drift.
  function stacked(windowWidth) {
    return windowWidth < STACK_BREAKPOINT;
  }

  // §8 statements(cond) — the roster's own rendering of the map's existing
  // FeedCondition object (data-model.md §5). No sort, no derived status:
  // every sentence is a fixed template over cond's own fields. `empty` is
  // gated on trust === "ok" *inside* this function, regardless of what the
  // caller passed for `cond.empty`, so a down or warming feed can never be
  // read as "no live sessions" (F2, FR-029, SC-007, C-F, C-G).
  function statements(cond) {
    var trust = cond && cond.trust;
    var main = "";
    var mainKind = "";
    if (trust === "feed_down") {
      mainKind = "down";
      main = "the feed is down: " + cond.reason + " — rows shown are "
        + dur(cond.dataAge) + " old";
    } else if (trust === "warming") {
      mainKind = "warming";
      main = "taking the first snapshot — no session data has been collected yet";
    }
    // R5 of entry 002, repeated here (C-D): absent or zero prints nothing,
    // never "0 registry files".
    var unreadable = cond && cond.unreadable > 0
      ? cond.unreadable + " registry file(s) could not be read — run: ccwatch doctor"
      : "";
    var empty = (trust === "ok" && cond && cond.empty)
      ? "No live sessions right now." : "";
    return {main: main, mainKind: mainKind, unreadable: unreadable, empty: empty};
  }

  // §8 goneText(sid, name) — the tombstone sentence (data-model.md §6),
  // sharing no leading clause with any string statements() can produce (C-J).
  function goneText(sid, name) {
    return (name || "That session") + " is no longer in the roster — it left the machine's session list.";
  }

  var api = {
    STORAGE_VERSION: STORAGE_VERSION,
    WIDTH_DEFAULT: WIDTH_DEFAULT,
    WIDTH_MIN: WIDTH_MIN,
    WIDTH_MAX_PX: WIDTH_MAX_PX,
    WIDTH_MAX_FRAC: WIDTH_MAX_FRAC,
    WIDTH_STEP: WIDTH_STEP,
    WIDTH_STEP_BIG: WIDTH_STEP_BIG,
    STACK_BREAKPOINT: STACK_BREAKPOINT,
    NEAR_IDX: NEAR_IDX,
    ASK_CHARS: ASK_CHARS,
    dur: dur,
    rowFields: rowFields,
    titleText: titleText,
    keysOf: keysOf,
    reorderPlan: reorderPlan,
    focusTarget: focusTarget,
    nextFocus: nextFocus,
    resolveSelection: resolveSelection,
    flyIdx: flyIdx,
    clampWidth: clampWidth,
    stacked: stacked,
    validateSelection: validateSelection,
    validateWidth: validateWidth,
    loadSelection: loadSelection,
    saveSelection: saveSelection,
    loadWidth: loadWidth,
    saveWidth: saveWidth,
    statements: statements,
    goneText: goneText,
  };
  Object.defineProperty(api, "persistence", {
    get: function () { return persistenceState; },
  });

  root.CCWATCH_ROSTER = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
