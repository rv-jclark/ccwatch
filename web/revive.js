// ccwatch — the revive control: one switch in the header of both pages, and the
// panel behind it that says what revive is watching and what it has sent.
//
// A static module beside web/alerts.js, for the reason those exist: the shaping
// is pure and tests/run.sh require()s it under node. The DOM half (`mount`) is
// here too rather than copied into both pages, because the same switch phrased
// two ways is two things to learn and two to keep in sync.
//
// ⚠️ It is a SWITCH, not a "run now" button. Revive is for the hours nobody is
// looking; a button you have to press to get a pass is the manual step it
// exists to remove. Turning it on writes ~/.claude/ccwatch/revive.json, which
// `ccwatch serve` reads every pass, so one click outlives this page, the serve
// and a reboot. The decisions themselves are `ccwatch revive --json` — the
// page computes none of them (principle XI).
//
// ⚠️ Every string from the server is written with textContent. A row's reason
// carries text that came from a transcript (an API error's own message), and
// this module has no business deciding which of those is safe as HTML.
(function (root) {
  "use strict";

  function dur(s) {
    if (s == null) return "-";
    s = Math.max(0, s);
    return s < 60 ? Math.floor(s) + "s"
      : s < 3600 ? Math.floor(s / 60) + "m"
      : s < 86400 ? Math.floor(s / 3600) + "h"
      : Math.floor(s / 86400) + "d";
  }

  var PAST = { ask: "asked", retry: "retried", continue: "continued" };

  // One row of the decision list, as words. The verdict is a word in every
  // state so that colour is never the only carrier (principle VII).
  function rowOf(r, live) {
    var word, cls;
    if (!r.action) { word = "waiting"; cls = "wait"; }
    else if (r.outcome) {
      word = (PAST[r.action] || r.action) + (r.outcome === "delivered" ? "" : " · " + r.outcome);
      cls = r.outcome === "failed" ? "bad" : "did";
    } else { word = (live ? "" : "would ") + r.action; cls = "would"; }
    return { name: r.name || "?", word: word, why: r.why || "", cls: cls };
  }

  // view(revive, canSend, now) — everything the control and its panel show.
  //   revive  /api/state's `revive` (null while the first pass is running)
  //   canSend whether this page was given a token (false under --read-only)
  //   now     epoch seconds, passed in so this stays pure
  function view(rev, canSend, now) {
    var v = { cls: "off", label: "revive: off", status: "", toggle: null,
              rows: [], empty: "", recent: [], sentToday: 0 };
    if (!rev) {
      v.label = "revive: …";
      v.status = "starting — the first pass has not finished";
      return v;
    }
    var recent = rev.recent || [];
    for (var i = 0; i < recent.length; i++) {
      var e = recent[i];
      if (e.outcome === "delivered" || e.outcome === "queued") v.sentToday++;
      v.recent.push({ ago: now != null && e.at != null ? dur(now - e.at) + " ago" : "",
                      target: e.target || "?",
                      word: (PAST[e.action] || e.action || "?") + (e.outcome === "delivered" ? "" : " · " + e.outcome),
                      cls: e.outcome === "failed" ? "bad" : "did", why: e.why || "" });
    }
    if (!rev.available) {
      v.cls = "na";
      v.label = "revive: unavailable";
      v.status = rev.reason || "this server cannot send";
      return v;
    }
    var on = rev.enabled === true;
    v.cls = on ? "on" : "off";
    v.label = "revive: " + (on ? "on" : "off")
      + (on && v.sentToday > 0 ? " · " + v.sentToday + " sent" : "");
    v.toggle = { text: on ? "turn off" : "turn on", on: on,
                 disabled: !canSend,
                 why: canSend ? "" : "this page has no send token" };
    var parts = [];
    parts.push(on ? "on — checks every " + dur(rev.every || 60)
                  : "off — showing what it would do while this page is open");
    if (rev.running) parts.push("pass running");
    else if (rev.pass_at != null && now != null) parts.push("last pass " + dur(now - rev.pass_at) + " ago");
    v.status = parts.join(" · ");
    // A pass that failed, or was refused, is said in words. An empty list
    // under a failure would read as "nothing stopped" (principle IV).
    if (rev.error) v.problem = "last pass failed: " + rev.error;
    else if (rev.skipped) v.problem = "last pass skipped: " + rev.skipped;
    var rows = rev.rows || [];
    var live = rev.live === true;
    for (var j = 0; j < rows.length; j++) v.rows.push(rowOf(rows[j], live));
    if (!rows.length && rev.pass_at != null && !rev.error) v.empty = "nothing stopped";
    return v;
  }

  // ---- the DOM half ------------------------------------------------------
  //
  // The stylesheet is injected from here, against the page's own colour
  // variables, so the control has exactly one definition for both pages.
  //
  // ⚠️ A fixed width, not a minimum. The label grows from "revive: off" to
  // "revive: on · 3 sent", and with a minimum the nav grew with it and wrapped
  // the header's left half onto a second line: the switch jumped 220px left
  // between two states, measured by verify-ui at 1180px. The header's height
  // did not change — the gauges on the right set it — so a "header did not
  // re-wrap" check stayed green through it. 21ch holds the longest label.
  var CSS =
    "#revivebtn{background:none;font:inherit;font-size:12px;line-height:1.2;" +
    "padding:.1rem .45rem;border-radius:4px;cursor:pointer;border:1px solid var(--line);" +
    "color:var(--dim);white-space:nowrap;width:21ch;overflow:hidden;text-overflow:ellipsis;" +
    "text-align:left;margin-left:.25rem}" +
    "#revivebtn.on{color:var(--ok);border-color:currentColor}" +
    "#revivebtn.na{opacity:.7}" +
    "dialog#revivemodal{position:fixed;margin:0;width:min(640px,94vw);" +
    "background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:.7rem;" +
    "color:var(--ink);box-shadow:0 8px 40px rgba(0,0,0,.5);overflow:auto}" +
    "dialog#revivemodal[open]{display:flex;flex-direction:column;gap:.55rem}" +
    "#revivemodal::backdrop{background:rgba(0,0,0,.35)}" +
    "#revivehead{display:flex;align-items:baseline;justify-content:space-between;gap:.6rem;" +
    "padding-bottom:.4rem;border-bottom:1px solid var(--line)}" +
    "#revivemodal button{background:none;border:1px solid var(--line);color:var(--dim);" +
    "font:inherit;font-size:12px;padding:.1rem .5rem;border-radius:4px;cursor:pointer}" +
    "#revivetoggle.off{color:var(--ok);border-color:currentColor}" +
    "#revivetoggle:disabled{opacity:.5;cursor:default}" +
    "#reviveabout,#revivestatus,.revempty{font-size:12px;color:var(--dim)}" +
    "#reviveproblem{font-size:12px;color:var(--bad)}" +
    "#reviveproblem:empty,#reviveerr:empty{display:none}" +
    "#reviveerr{font-size:12px;color:var(--bad)}" +
    // One grid for the whole list, each row's cells placed into it, so the
    // verdicts line up in a column instead of starting wherever each name ends.
    "#reviverows,#reviverecent{display:grid;grid-template-columns:auto auto 1fr;" +
    "column-gap:.7rem;row-gap:.3rem;font-size:12px;align-items:baseline}" +
    ".revrow{display:contents}.revempty{grid-column:1/-1}" +
    ".revrow .w{font-weight:600}.revrow.wait .w{color:var(--dim)}" +
    ".revrow.would .w,.revrow.did .w{color:var(--warn)}.revrow.bad .w{color:var(--bad)}" +
    ".revrow .y{color:var(--dim);overflow-wrap:anywhere}" +
    "#revivemodal h3{margin:.3rem 0 0;font-size:12px;font-weight:600;color:var(--dim)}";

  function el(doc, tag, attrs, text) {
    var n = doc.createElement(tag);
    for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) n.setAttribute(k, attrs[k]);
    if (text != null) n.textContent = text;
    return n;
  }

  // mount(slot, {token, canSend}) — builds the switch into `slot` and returns
  // {update(revive)} for the page to call on every state it receives.
  function mount(slot, opts) {
    var doc = slot.ownerDocument;
    var style = el(doc, "style", {}); style.textContent = CSS; doc.head.appendChild(style);
    var btn = el(doc, "button", { type: "button", id: "revivebtn", "aria-haspopup": "dialog",
                                  "aria-expanded": "false", "aria-controls": "revivemodal" }, "revive: …");
    slot.appendChild(btn);
    var modal = el(doc, "dialog", { id: "revivemodal", "aria-labelledby": "revivetitle" });
    var head = el(doc, "div", { id: "revivehead" });
    head.appendChild(el(doc, "strong", { id: "revivetitle" }, "revive"));
    var toggle = el(doc, "button", { type: "button", id: "revivetoggle" }, "turn on");
    var close = el(doc, "button", { type: "button", id: "reviveclose" }, "close");
    var hb = el(doc, "span", {}); hb.appendChild(toggle); hb.appendChild(doc.createTextNode(" ")); hb.appendChild(close);
    head.appendChild(hb);
    modal.appendChild(head);
    modal.appendChild(el(doc, "div", { id: "reviveabout" },
      "Types what you would have: “retry” after an API error once the API answers, " +
      "“continue” once a session limit resets, and “Are you actually done with the " +
      "work and this pause is intentional?” to a session that stopped for 10 minutes partway " +
      "through a spec-roadmap it was running. It never touches a session that is waiting on a " +
      "prompt, ended on a question, or was interrupted by you."));
    var status = el(doc, "div", { id: "revivestatus" });
    var problem = el(doc, "div", { id: "reviveproblem", role: "status" });
    var err = el(doc, "div", { id: "reviveerr", role: "alert" });
    var rows = el(doc, "div", { id: "reviverows" });
    var recentH = el(doc, "h3", {}, "sent in the last 24h");
    var recent = el(doc, "div", { id: "reviverecent" });
    [status, problem, err, rows, recentH, recent].forEach(function (n) { modal.appendChild(n); });
    doc.body.appendChild(modal);

    var current = null;
    function row(cls, a, b, c) {
      var r = el(doc, "div", { "class": "revrow " + cls });
      r.appendChild(el(doc, "span", {}, a));
      r.appendChild(el(doc, "span", { "class": "w" }, b));
      r.appendChild(el(doc, "span", { "class": "y" }, c));
      return r;
    }
    function render() {
      var v = view(current, opts.canSend, Date.now() / 1000);
      if (btn.textContent !== v.label) btn.textContent = v.label;
      btn.className = v.cls;
      btn.title = v.label + (v.status ? " — " + v.status : "");
      status.textContent = v.status;
      problem.textContent = v.problem || "";
      if (v.toggle) {
        toggle.hidden = false;
        toggle.textContent = v.toggle.text;
        toggle.className = v.toggle.on ? "on" : "off";
        toggle.disabled = v.toggle.disabled;
        toggle.title = v.toggle.why;
      } else toggle.hidden = true;
      rows.textContent = "";
      if (v.empty) rows.appendChild(el(doc, "div", { "class": "revempty" }, v.empty));
      v.rows.forEach(function (r) { rows.appendChild(row(r.cls, r.name, r.word, r.why)); });
      recent.textContent = "";
      if (!v.recent.length) recent.appendChild(el(doc, "div", { "class": "revempty" }, "nothing"));
      v.recent.forEach(function (r) { recent.appendChild(row(r.cls, r.target, r.word, r.ago + " · " + r.why)); });
    }
    // ⚠️ Anchored by the switch's LEFT edge, clamped into the window - not by
    // its right edge as the alert panel is. The switch sits in the nav, which
    // wraps to the left of the header at narrower widths; right-anchored, a
    // 640px panel under a switch at x=255 opened at x=-385, measured by
    // verify-ui at 1180px with three alerts showing.
    function open() {
      var r = btn.getBoundingClientRect(), win = doc.defaultView;
      var top = Math.round(r.bottom + 6);
      modal.style.top = top + "px";
      modal.style.right = "auto";
      modal.style.maxHeight = Math.max(80, win.innerHeight - top - 12) + "px";
      modal.showModal();
      var w = modal.getBoundingClientRect().width;
      modal.style.left = Math.max(8, Math.min(Math.round(r.left), Math.round(win.innerWidth - w - 8))) + "px";
      btn.setAttribute("aria-expanded", "true");
    }
    btn.addEventListener("click", function () { if (modal.open) modal.close(); else open(); });
    close.addEventListener("click", function () { modal.close(); });
    modal.addEventListener("click", function (e) { if (e.target === modal) modal.close(); });
    modal.addEventListener("close", function () { btn.setAttribute("aria-expanded", "false"); });
    toggle.addEventListener("click", function () {
      var want = !(current && current.enabled === true);
      toggle.disabled = true;
      err.textContent = "";
      fetch("/api/revive", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CCWatch-Token": opts.token },
        body: JSON.stringify({ enabled: want }),
      }).then(function (res) {
        return res.json().then(function (body) { return { ok: res.ok, body: body }; });
      }).then(function (r) {
        if (!r.ok) throw new Error(r.body && r.body.error || "refused");
        current = Object.assign({}, current || {}, { enabled: r.body.enabled === true });
      }).catch(function (e) {
        // The refusal is the useful part: the server says why, verbatim.
        err.textContent = "could not turn revive " + (want ? "on" : "off") + ": " + e.message;
      }).then(render);
    });
    render();
    // Kept on the module as well as returned, so `ccwatch verify-ui` can force
    // a state into the real control rather than wait for one to happen.
    api.ui = { update: function (rev) { current = rev || null; render(); },
               element: btn, modal: modal };
    return api.ui;
  }

  var api = { dur: dur, view: view, rowOf: rowOf, mount: mount };
  root.CCWATCH_REVIVE = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
