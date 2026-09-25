// ccwatch — which peer messages the map shows, and when.
//
// A static module beside web/roster.js and web/alerts.js, for the documented
// reason those exist: so tests/run.sh can require() it under node and assert
// on it without a browser. Pure — no DOM, no fetch, no timers. The page passes
// the clock in.
//
// ⚠️ Why this exists. The map used to draw every peer edge as a permanent line
// across the board, and `serve` reads `peers --days 2`: a pair that exchanged
// one message yesterday got the same line as a pair talking right now. So the
// lines were history drawn as though they were activity, and every one added
// crossed the owner blocks between its ends. Two rules replace them:
//
//   1. A figure that sent or received a message in the last RECENT_S seconds
//      wears a marker. It is absent below that threshold — not dimmed, absent
//      (principle XII) — so a quiet map is quiet.
//   2. The lines themselves are drawn only for the figures somebody is looking
//      at: hovered, keyboard-focused, or selected. All of their edges, of any
//      age, because at that point the history is what was asked for.
(function (root) {
  "use strict";

  // ⚠️ Two minutes, and not less, because of the cadence behind it: `serve`
  // refreshes peers every 45s at best, so a message can be most of a minute
  // old before the page first sees it. At 60s a marker could be up for 15s —
  // gone between two glances. At 120s it is up for at least 75s.
  var RECENT_S = 120;

  // A reading more than this far in the FUTURE is not a clock rounding error
  // on one machine, it is a timestamp this cannot interpret, and principle VI
  // says to say nothing rather than guess that it means "just now".
  var SKEW_S = 30;

  // Seconds since the edge's newest message, or null when `last` cannot be
  // read. Null is never treated as recent.
  function ageOf(edge, nowMs) {
    var t = Date.parse(edge && edge.last);
    if (isNaN(t)) return null;
    var s = Math.round((nowMs - t) / 1000);
    if (s < -SKEW_S) return null;
    return Math.max(0, s);
  }

  function ago(s) {
    if (s < 60) return s + "s ago";
    if (s < 3600) return Math.floor(s / 60) + "m ago";
    return Math.floor(s / 3600) + "h ago";
  }

  // name -> {sent: [{peer, age}], heard: [{peer, age}]}, for the names in
  // `onMap` only. The OTHER end need not be on the map: a figure that has just
  // messaged a session which then exited has still just been talking.
  function recent(edges, onMap, nowMs, windowS) {
    var win = windowS == null ? RECENT_S : windowS;
    var out = {};
    function slot(n) { return out[n] || (out[n] = {sent: [], heard: []}); }
    (edges || []).forEach(function (e) {
      if (!e || e.from === e.to) return;
      var a = ageOf(e, nowMs);
      if (a == null || a > win) return;
      if (onMap[e.from]) slot(e.from).sent.push({peer: e.to, age: a});
      if (onMap[e.to]) slot(e.to).heard.push({peer: e.from, age: a});
    });
    Object.keys(out).forEach(function (n) {
      out[n].sent.sort(function (x, y) { return x.age - y.age; });
      out[n].heard.sort(function (x, y) { return x.age - y.age; });
    });
    return out;
  }

  // "sent", "heard" or "both" — the marker's class, so a test (and the page's
  // own stylesheet) can tell them apart without parsing the sentence.
  function kind(entry) {
    if (!entry) return null;
    var s = entry.sent.length > 0, h = entry.heard.length > 0;
    return s && h ? "both" : s ? "sent" : h ? "heard" : null;
  }

  // The words, because the marker is a shape and a colour and neither may be
  // the only carrier of what it means (principle VII). Each part carries its
  // own measurement (principle II): who, and how long ago.
  function text(entry) {
    if (!kind(entry)) return "";
    function list(xs) {
      return xs.map(function (x) { return x.peer + " " + ago(x.age); }).join(", ");
    }
    var parts = [];
    if (entry.sent.length) parts.push("messaged " + list(entry.sent));
    if (entry.heard.length) parts.push("heard from " + list(entry.heard));
    return parts.join("; ");
  }

  // The edges to draw: those touching any of the names being looked at, with
  // both ends on the map (a line to a session that has exited is a line to
  // nowhere — the table view's peers panel lists those). Each carries `recent`
  // so the page can draw today's traffic stronger than last night's.
  function visible(edges, focus, onMap, nowMs, windowS) {
    var win = windowS == null ? RECENT_S : windowS;
    var want = {};
    (focus || []).forEach(function (n) { if (n != null) want[n] = true; });
    var out = [];
    (edges || []).forEach(function (e) {
      if (!e || e.from === e.to) return;
      if (!onMap[e.from] || !onMap[e.to]) return;
      if (!want[e.from] && !want[e.to]) return;
      var a = ageOf(e, nowMs);
      out.push({from: e.from, to: e.to, count: e.count, recent: a != null && a <= win});
    });
    return out;
  }

  // Edges with both ends on the map: the ones hovering COULD draw.
  function drawable(edges, onMap) {
    return (edges || []).filter(function (e) {
      return e && e.from !== e.to && onMap[e.from] && onMap[e.to];
    }).length;
  }

  // The footer's sentence about edges. ⚠️ Hidden by default is not the same
  // as absent, and must not read like it (principle IV): with no lines on the
  // board, the only statement that there is traffic to see is this one.
  function footText(o) {
    var parts = [];
    var edges = " message edge" + (o.drawable === 1 ? "" : "s");
    if (o.drawable > 0) {
      parts.push(o.drawn > 0
        ? "drawing " + o.drawn + " of " + o.drawable + edges
        : o.drawable + edges + " between agents on the map"
          + " — hover or select one to draw its own");
    }
    if (o.exited > 0) {
      parts.push(o.exited + (o.drawable > 0 ? " more" : " message edge" + (o.exited === 1 ? "" : "s"))
        + " involve sessions that have exited (see the table view)");
    }
    return parts.join(" · ");
  }

  var api = {
    RECENT_S: RECENT_S, SKEW_S: SKEW_S,
    ageOf: ageOf, ago: ago, recent: recent, kind: kind, text: text,
    visible: visible, drawable: drawable, footText: footText,
  };
  root.CCWATCH_COMMS = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
