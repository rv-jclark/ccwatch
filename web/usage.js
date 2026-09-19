// ccwatch — the usage meter: what the two bars in each gauge mean, and when
// each window resets, shaped once here for both pages.
//
// A static module beside web/md.js, web/roster.js, web/modal.js and
// web/alerts.js, for the documented reason those exist: so tests/run.sh can
// require() it under node and assert on it without a browser. Pure — no DOM,
// no fetch, no timers.
//
// ⚠️ Why two bars rather than one percentage. "41% of the 5-hour limit used"
// answers nothing on its own: 41% an hour in is a problem and 41% four hours
// in is spare capacity. The second bar is how much of the window has elapsed,
// drawn directly under the first and to the same scale, so the only question
// that matters — am I burning this faster than the clock is — is a comparison
// of two lengths rather than arithmetic the reader has to do.
(function (root) {
  "use strict";

  // The length of each window, which the payload does not carry: it reports a
  // percentage and a reset instant, and the elapsed fraction cannot be derived
  // from those alone. Keyed by the payload's own field names so a window that
  // is not listed here produces no time bar rather than a wrong one.
  var WINDOW_SECONDS = {
    five_hour: 5 * 3600,
    seven_day: 7 * 86400,
    seven_day_opus: 7 * 86400,
  };

  // Eastern, as asked for, and NOT the viewer's own zone: the reset instant is
  // the same moment everywhere, and a fixed zone means two people reading the
  // same dashboard say the same time out loud. `timeZoneName` is included
  // because EDT and EST are an hour apart and a clock time without one is
  // ambiguous for half the year.
  var RESET_ZONE = "America/New_York";

  function dur(s) {
    if (s == null) return "-";
    s = Math.max(0, s);
    return s < 60 ? Math.floor(s) + "s"
      : s < 3600 ? Math.floor(s / 60) + "m"
      : s < 86400 ? Math.floor(s / 3600) + "h"
      : Math.floor(s / 86400) + "d";
  }

  // elapsedPct(key, resetsAt, now) — how much of this window has passed, as a
  // percentage, or null when that cannot be known.
  //
  // ⚠️ Three separate ways it is unknowable, and all three return null rather
  // than a number, because a bar is read as a measurement whatever is beside
  // it (principle III):
  //   - no `resets_at` in the payload: there is no window boundary to measure
  //     from, and assuming "now + 5h" would draw a bar from an invented start.
  //   - a window this module does not know the length of: a new window name
  //     ships in the payload before this file learns about it.
  //   - a reset instant already in the past: the window has ended and the
  //     reading has not caught up, so neither the elapsed fraction nor the
  //     reset clock describes the window the percentage came from.
  function elapsedPct(key, resetsAt, now) {
    var span = WINDOW_SECONDS[key];
    if (!span || resetsAt == null || typeof resetsAt !== "number") return null;
    var remaining = resetsAt - now;
    if (remaining <= 0) return null;
    if (remaining >= span) return 0;
    return ((span - remaining) / span) * 100;
  }

  // resetClock(resetsAt) — the reset instant as a wall clock in RESET_ZONE,
  // e.g. "3:45 PM EDT", or null.
  //
  // ⚠️ Wrapped in try/catch and null on failure. `Intl` with a named zone is
  // present everywhere this runs today, but a missing time-zone database is a
  // real deployment (some minimal builds ship without one) and it throws. A
  // wrong clock time is worse than no clock time, so there is no fallback to
  // the local zone — that would silently print a different hour under a label
  // the viewer reads as Eastern.
  function resetClock(resetsAt) {
    if (resetsAt == null || typeof resetsAt !== "number") return null;
    try {
      return new Intl.DateTimeFormat("en-US", {
        timeZone: RESET_ZONE,
        hour: "numeric",
        minute: "2-digit",
        timeZoneName: "short",
      }).format(new Date(resetsAt * 1000));
    } catch (e) {
      return null;
    }
  }

  // gauge(key, name, x, now) → one gauge's model, or null when the payload
  // carries nothing for that window.
  //
  // `pace` is "ahead" only when consumption is genuinely running ahead of the
  // clock, and null the rest of the time — including when the elapsed fraction
  // is unknown. Being under the clock is the normal condition and says nothing
  // (principle XII); the page prints a word for "ahead" so the comparison
  // survives NO_COLOR, a screen reader, and the two bars being similar lengths
  // (principle VII).
  function gauge(key, name, x, now) {
    if (!x || x.used_percentage == null) return null;
    var used = x.used_percentage;
    var elapsed = elapsedPct(key, x.resets_at, now);
    var out = {
      key: key,
      name: name,
      usedPct: used,
      usedText: Math.floor(used) + "%",
      elapsedPct: elapsed,
      elapsedText: null,
      pace: null,
      resetIn: null,
      resetClock: null,
      // What a screen reader gets, since a bar's length is not available to
      // one. Stated in full rather than as "41%", which would be a number
      // with no subject.
      usedLabel: Math.floor(used) + "% of the " + name + " limit used",
      elapsedLabel: null,
    };
    if (elapsed != null) {
      out.elapsedText = Math.floor(elapsed) + "%";
      out.elapsedLabel = Math.floor(elapsed) + "% of the " + name + " window elapsed";
      // A strict comparison of the two drawn lengths: what the eye is being
      // asked to compare is what the word reports.
      if (used > elapsed) out.pace = "ahead";
    }
    if (x.resets_at != null && x.resets_at > now) {
      out.resetIn = dur(x.resets_at - now);
      out.resetClock = resetClock(x.resets_at);
    }
    return out;
  }

  // gauges(usage, now) → the models, in the order the header draws them.
  // Windows absent from the payload are absent here; nothing is filled in.
  function gauges(usage, now) {
    if (!usage) return [];
    var want = [
      ["five_hour", "5h"],
      ["seven_day", "7d"],
      ["seven_day_opus", "7d opus"],
    ];
    var out = [];
    for (var i = 0; i < want.length; i++) {
      var g = gauge(want[i][0], want[i][1], usage[want[i][0]], now);
      if (g) out.push(g);
    }
    return out;
  }

  // The threshold colour for the consumption bar and its number, as a WORD the
  // stylesheet maps to a colour — never a colour string here, so the page's
  // palette stays in the page. Unchanged thresholds: the ones the terminal and
  // both views already band on.
  function band(pct) {
    return pct >= 90 ? "bad" : pct >= 70 ? "warn" : "ok";
  }

  var api = {
    WINDOW_SECONDS: WINDOW_SECONDS,
    RESET_ZONE: RESET_ZONE,
    dur: dur,
    elapsedPct: elapsedPct,
    resetClock: resetClock,
    gauge: gauge,
    gauges: gauges,
    band: band,
  };

  root.CCWATCH_USAGE = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
