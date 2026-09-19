// ccwatch — the alert set: "what is wrong right now", shaped once here and
// rendered identically by the map and the table view.
//
// A static module beside web/md.js, web/roster.js and web/modal.js, for the
// documented reason those exist: so tests/run.sh can require() it under node
// and assert on it without a browser. Pure — no DOM, no fetch, no timers.
//
// ⚠️ Why these conditions are collected behind one header control instead of
// being printed as banners: each was a block-level element between the header
// and the board, so the top edge of the map moved whenever one appeared or
// cleared. Measured on the map at 1180x760, against a board 676px tall: the
// feed-down banner pushed it down 32px, host pressure 50px, and the two
// together with an unreadable-registry line 81px — 12% of the map's height,
// arriving and clearing on their own while you read the figures underneath,
// because every one of them is derived from a reading collected every couple
// of seconds. A view whose geometry depends on whether the machine is
// swapping cannot be compared against itself from one glance to the next.
//
// ⚠️ What is NOT being done here is softening the conditions. Each one is still
// stated in words, and the worst of them is stated in the header where the
// banner used to be — a collapsed control that reads "2 alerts" would make a
// failure look like an absence, which is the one thing this tool may not do
// (principle IV). The count is the accessory; the sentence is the point. The
// measurement behind each verdict (principle II) moves one click away, and
// nothing appears at all while there is nothing wrong (principle XII).
(function (root) {
  "use strict";

  // The page's duration formatter, as in web/roster.js §2 — copied rather than
  // imported because these modules are plain scripts with no load order
  // between them, and a second formatter is what would make one age read two
  // ways depending on which module printed it.
  function dur(s) {
    if (s == null) return "-";
    s = Math.max(0, s);
    return s < 60 ? Math.floor(s) + "s"
      : s < 3600 ? Math.floor(s / 60) + "m"
      : s < 86400 ? Math.floor(s / 3600) + "h"
      : Math.floor(s / 86400) + "d";
  }

  // Severity rank, low is worse. A WORD, never a number, because the page's
  // CSS class and the trigger's own prefix read this same value — colour is
  // never the only carrier of a severity (principle VII).
  var SEV_RANK = {bad: 0, warn: 1, info: 2};

  // specs/004-map-roster/data-model.md §5 — the pages' trust model. Computed
  // fresh from the read outcome and the payload fields it produced, and from
  // nothing else: there is no flag to latch and no reload needed to clear one.
  // `fetchFailure` is the thrown message when the read itself failed (a
  // network error or `!res.ok`); otherwise it is null and `s` is a parsed body.
  //
  // ⚠️ Lives here, in the one module both pages load, because the table view
  // used to decide the same question its own way — a try/catch that wrote a
  // sentence into the footer — and two renderings that judge independently
  // whether the feed can be believed will eventually disagree, with no way for
  // a reader to tell which of them is lying (principle XI).
  function feedCondition(s, fetchFailure) {
    var ca = (s && s.collected_at) || {};
    var dataAge = ca.snapshot != null ? (Date.now() / 1000 - ca.snapshot) : null;
    var unreadable = s ? s.parse_failed : null;
    if (fetchFailure)
      return {trust: "feed_down", reason: fetchFailure, dataAge: dataAge,
              unreadable: unreadable, empty: false};
    if (s.warming)
      return {trust: "warming", reason: null, dataAge: null,
              unreadable: unreadable, empty: false};
    if (s.snapshot_ok === false)
      return {trust: "feed_down", reason: s.snapshot_error || s.error || "snapshot failed",
              dataAge: dataAge, unreadable: unreadable, empty: false};
    return {
      trust: "ok", reason: null, dataAge: dataAge, unreadable: unreadable,
      empty: !s.error && (s.sessions || []).length === 0,
    };
  }

  // alerts({cond, host, volatile}) → {items, trigger}
  //
  // `items` is in severity order, worst first, and `trigger` describes the
  // collapsed control — null when there is nothing to say, so the control is
  // absent rather than reassuring.
  //
  // ⚠️ `cond.empty` is deliberately NOT an item. Zero sessions is a normal
  // condition, not a failure: the machine is simply idle, and a control that
  // lights up for it is a control that has lit up for nothing by the time a
  // real condition arrives (principle XII). Each page states it where a reader
  // looks for sessions — the roster panel on the map, the Sessions section in
  // the table view — and neither is a banner over the board.
  function alerts(input) {
    var i = input || {};
    var cond = i.cond || {};
    var host = i.host || null;
    var isVolatile = !!i.volatile;
    var items = [];

    // (a) The read failed, or the collector did. The reason is named verbatim
    // and the age of what is still on screen is stated beside it, because the
    // readings are retained, not current.
    if (cond.trust === "feed_down") {
      items.push({
        key: "feed_down",
        sev: "bad",
        headline: "the feed is down",
        text: "the feed is down: " + (cond.reason || "no reason reported")
          + " — is `ccwatch serve` still running? showing session data from "
          + dur(cond.dataAge) + " ago",
      });
    }

    // (b) Nothing has been collected yet. Not a failure and not reassurance:
    // it says the view has nothing behind it yet, which is why it ranks below
    // the two that say the view is wrong.
    if (cond.trust === "warming") {
      items.push({
        key: "warming",
        sev: "info",
        headline: "taking the first snapshot",
        text: "taking the first snapshot — no session data has been collected yet",
      });
    }

    // (c) Additive: it can accompany any of the others, and it is empty for 0,
    // null and absent, because "0 registry files could not be read" is a
    // sentence nobody needs. Worded exactly as roster.js and modal.js word it,
    // so one fact does not acquire three phrasings.
    if (cond.unreadable > 0) {
      items.push({
        key: "unreadable",
        sev: "warn",
        headline: cond.unreadable + " registry file(s) unreadable",
        text: cond.unreadable
          + " registry file(s) could not be read — run: ccwatch doctor",
      });
    }

    // A session killed by the OS leaves the same trace as one that exited
    // cleanly, so without this the dashboard can say an agent is gone but not
    // why.
    if (host && host.pressure) {
      // Every memory figure here is in the VOLATILE set (data-model.md §5):
      // the pressure itself still appears at its own threshold, but the
      // numbers behind it are withheld, not annotated, while the feed is not
      // fully trusted (principle III).
      var pressure = "host under memory pressure — ";
      if (!isVolatile) {
        pressure += "readings withheld while the feed is unreliable.";
      } else {
        pressure += "swap " + host.swap_used_pct + "% used ("
          + host.swap_used_mb + "/" + host.swap_total_mb + "MB), "
          + host.ram_free_mb + "MB RAM free.";
      }
      pressure += " The OS may kill sessions, and a killed session looks"
        + " exactly like a clean exit.";
      // The sessions' own share is stated, so "would killing agents help" is a
      // number rather than a hunch. Usually it is a small fraction of the
      // total, and it is withheld with the rest of the volatile readings.
      if (isVolatile && host.sessions_mb != null) {
        pressure += " Sessions account for " + host.sessions_mb + "MB of it ("
          + (host.idle_mb || 0) + "MB of that idle).";
      }
      items.push({
        key: "host_pressure",
        sev: "bad",
        headline: "host under memory pressure",
        text: pressure,
      });
    }

    // ⚠️ Built in the trust model's own (a)/(b)/(c)-then-host order above and
    // SORTED here, rather than pushed in severity order — which would make
    // this sort a no-op, and an assertion about the ordering one that could
    // not fail. `warming` is info and `unreadable` is warn, so an unsorted set
    // really does come out with a host that may be killing sessions listed
    // under a note about registry files. A stable sort keeps two conditions of
    // equal severity in the order the model states them.
    items.sort(function (a, b) { return SEV_RANK[a.sev] - SEV_RANK[b.sev]; });
    // Order is then carried as a field rather than by position, because the
    // map reconciles these nodes by key and never moves an existing one (the
    // sorted order is a `style.order` written on each update).
    for (var n = 0; n < items.length; n++) items[n].order = n;

    return {items: items, trigger: triggerOf(items)};
  }

  // The collapsed control. It names the worst condition in that condition's
  // own words — never a bare count — and carries a "!" for anything that says
  // the view is wrong, matching the terminal's own marker (bin/ccwatch's
  // `! host under memory pressure`) so the severity survives NO_COLOR, a
  // screen reader and a monochrome screen.
  function triggerOf(items) {
    if (!items.length) return null;
    var worst = items[0];
    var more = items.length - 1;
    var headlines = [];
    for (var n = 0; n < items.length; n++) headlines.push(items[n].headline);
    return {
      sev: worst.sev,
      text: (worst.sev === "info" ? "" : "! ") + worst.headline
        + (more > 0 ? " +" + more : ""),
      // The accessible name spells out what "+1" abbreviates: a truncated
      // trigger and a screen reader must both reach the whole list.
      label: items.length + (items.length === 1 ? " alert: " : " alerts: ")
        + headlines.join(", ") + " — show details",
    };
  }

  var api = {
    SEV_RANK: SEV_RANK,
    dur: dur,
    feedCondition: feedCondition,
    alerts: alerts,
    triggerOf: triggerOf,
  };

  root.CCWATCH_ALERTS = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
