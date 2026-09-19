// ccwatch — the per-agent modal: pure data shaping for the dialog that
// replaces #reply (contracts/modal-js.md).
//
// A fifth static module beside web/md.js, web/plots.js, web/camera.js and
// web/roster.js, for the documented reason those exist: so tests/run.sh can
// require() it under node and assert on it without a browser. Pure — no DOM,
// no fetch, no timers, no localStorage, no require, no global read. It does
// not reach for CCWATCH_ROSTER: the caller passes rowFields's output in.
(function (root) {
  "use strict";

  // §1 — frozen, independent of viewport size and of the payload
  // (contracts/modal-js.md §1).
  var FOLLOW_EPS = 8;
  var TRANSCRIPT_N = 40;

  // §12 — the page's existing duration formatter, duplicated (not imported,
  // D2) from web/roster.js's dur and the page's own (web/map.html:345-347).
  function dur(s) {
    if (s == null) return "-";
    s = Math.max(0, s);
    return s < 60 ? Math.floor(s) + "s"
      : s < 3600 ? Math.floor(s / 60) + "m"
      : s < 86400 ? Math.floor(s / 3600) + "h"
      : Math.floor(s / 86400) + "d";
  }

  // §4 statLines(fields, row, opts) → StatLine[] (contracts/modal-js.md §4,
  // data-model.md §4). Fixed order: silence, age, ctx, mem, pipeline, where,
  // sid, edge:*. Assumes a real row — panel() takes the row:null case itself
  // (M-E), since there is no row.sid to read here without one. An absent
  // fields key yields no line at all: never 0/0%/0MB/-/null (S-D).
  function statLines(fields, row, opts) {
    var edges = (opts && opts.edges) || [];
    var lines = [];
    if (row && row.waited != null) {
      lines.push({key: "silence", label: "waiting", text: dur(row.waited)});
    } else if (row && row.quiet != null) {
      lines.push({key: "silence", label: "silent", text: dur(row.quiet)});
    }
    if (fields) {
      if (fields.age != null) lines.push({key: "age", label: "age", text: fields.age});
      if (fields.ctx != null) lines.push({key: "ctx", label: "context", text: fields.ctx});
      if (fields.mem != null) lines.push({key: "mem", label: "memory", text: fields.mem});
      if (fields.pipeline != null) {
        lines.push({key: "pipeline", label: "pipeline", text: fields.pipeline});
      }
      if (fields.where != null) lines.push({key: "where", label: "repo", text: fields.where});
    }
    if (row) lines.push({key: "sid", label: "session", text: row.sid});
    edges.forEach(function (e, i) {
      lines.push({key: "edge:" + i, label: "messages", text: edgeLineText(e)});
    });
    return lines;
  }

  // §5 edgesFor(name, edges, names) → PeerEdgeLine[] (contracts/modal-js.md
  // §5, data-model.md §5). Matched by name, exactly as the map's own wire
  // drawing already does — never re-aggregated (E-C), never dropped for an
  // unrecognised far end (E-D).
  function edgesFor(name, edges, names) {
    edges = edges || [];
    names = names || [];
    var out = [];
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i];
      if (e.from !== name && e.to !== name) continue;
      var dir = e.from === name ? "out" : "in";
      var other = dir === "out" ? e.to : e.from;
      out.push({dir: dir, other: other, count: e.count, unknown: names.indexOf(other) === -1});
    }
    return out;
  }

  // The direction as a word as well as the arrow (E-H, principle VII); an
  // unknown far end reads "— not in this snapshot" rather than being dropped.
  function edgeLineText(e) {
    var arrow = e.dir === "out" ? "→ to " : "← from ";
    return arrow + e.other + " · " + e.count + " message(s)"
      + (e.unknown ? " — not in this snapshot" : "");
  }

  // §6 feedLines(cond) → {main, mainKind, unreadable}
  //
  // The modal keeps showing its readings when the feed breaks, so it has to say
  // which way it is broken — and `ok` says nothing at all, because a line that
  // appears on every refresh to confirm things are fine is a line people learn
  // to skip (principle XII).
  //
  // ⚠️ `unreadable` is a SEPARATE string, never joined into `main`. Rows that
  // could not be read is an additive fact: it is true of a healthy feed and of
  // a broken one, and folding it into the main sentence would make it look like
  // a consequence of the breakage. It is also empty for 0, null and undefined —
  // "0 registry files could not be read" is a sentence nobody needs.
  function feedLines(cond) {
    var c = cond || {};
    var out = {main: "", mainKind: "", unreadable: ""};
    if (c.trust === "feed_down") {
      out.mainKind = "down";
      // The reason is named verbatim, and the age is stated because the
      // readings are still on screen next to it.
      out.main = "the feed is down: " + (c.reason || "no reason reported")
               + " — the readings in this panel are " + dur(c.dataAge) + " old";
    } else if (c.trust === "warming") {
      out.mainKind = "warming";
      out.main = "taking the first snapshot"
               + " — nothing has been collected about this session yet";
    }
    // Worded exactly as the alert control words it (web/alerts.js), so one fact
    // does not acquire two phrasings depending on where you read it.
    if (c.unreadable != null && c.unreadable > 0) {
      out.unreadable = c.unreadable
        + " registry file(s) could not be read — run: ccwatch doctor";
    }
    return out;
  }

  // §6 goneText(name, sid) — the fifth rendering.
  //
  // ⚠️ Only reachable when the feed is trustworthy. A feed that cannot be read
  // is not evidence that a session exited, and saying "it is gone" on the
  // strength of a failed read would be inventing an exit that may not have
  // happened (principle VI). `resolveSelection` in roster.js encodes the same
  // rule.
  function goneText(name, sid) {
    return (name || "this session")
      + " is gone from the snapshot — it is no longer one of the machine's"
      + " sessions. Reopen the conversation with claude --resume " + sid;
  }

  // §8 killModel(input) → KillModel (contracts/modal-js.md §8, data-model.md
  // §8). The control is present in both states (FR-028): a disabled state
  // never opens a confirmation (K-B) and issues no request (FR-029).
  function killModel(input) {
    input = input || {};
    var row = input.row || null;
    var fields = input.fields || null;
    if (!input.canKill) {
      return {
        state: "disabled",
        reason: "killing is disabled on this server — restart it with: ccwatch serve --allow-kill",
        startLabel: "kill this session",
        confirmOpen: false,
        confirm: null,
      };
    }
    if (!row) {
      return {
        state: "disabled",
        reason: "this session is no longer in the snapshot — there is nothing to kill",
        startLabel: "kill this session",
        confirmOpen: false,
        confirm: null,
      };
    }
    var frees = null, freesNote = null;
    if (input.volatile) {
      frees = (fields && fields.mem != null) ? fields.mem : "an unknown amount";
    } else {
      freesNote = "the memory reading is no longer current, so what killing would free cannot be stated";
    }
    var confirm = {
      name: row.name,
      frees: frees,
      freesNote: freesNote,
      resume: "claude --resume " + row.sid,
      phase: (row.pipeline && row.pipeline.status === "running") ? row.pipeline.phase : null,
      busy: row.token === "busy" ? true : null,
    };
    return {
      state: "ready",
      reason: null,
      startLabel: "kill this session (frees " + (frees != null ? frees : "an unknown amount") + ")",
      confirmOpen: !!input.confirmOpen,
      confirm: confirm,
    };
  }

  // §9 sendModel(input) → SendModel (contracts/modal-js.md §9, data-model.md
  // §9). Present and disabled, never hidden (FR-026); a disabled control
  // issues no request (FR-027, wired by the page's own handler guard).
  function sendModel(input) {
    input = input || {};
    if (!input.canSend) {
      return {state: "disabled", reason: "this server was started --read-only — sending is disabled"};
    }
    if (!input.row) {
      return {state: "disabled", reason: "this session is no longer in the snapshot — there is nothing to send to"};
    }
    return {state: "ready", reason: null};
  }

  // §10 askModel(row) → AskModel (contracts/modal-js.md §10, data-model.md
  // §7). The three wordings carried over verbatim in meaning from
  // web/map.html's existing askEls (FR-021, FR-022); questions are returned
  // whole, never truncated (A-E).
  function askModel(row) {
    if (!row) return {kind: "none", note: null, how: "", questions: []};
    var qs = row.questions;
    if (qs && qs.length) {
      return {
        kind: "questions",
        note: null,
        how: "This is a dialog: it can only be answered in that session's own"
          + " terminal. A message sent from here is queued behind it and read"
          + " once the dialog is resolved — it does not answer it.",
        questions: qs,
      };
    }
    if (row.sev === 4) {
      return {
        kind: "dialog",
        note: "Waiting on you: " + (row.note || "input needed"),
        how: "No question is recorded in the transcript, so this is a dialog"
          + " (a permission prompt, for example). Its text is only in that"
          + " session's terminal.",
        questions: [],
      };
    }
    return {kind: "none", note: null, how: "", questions: []};
  }

  // §3 panel(input) → PanelModel (contracts/modal-js.md §3, data-model.md
  // §4). `header` and `stats` are composed here now (M-A, M-B, M-C, S-A);
  // `feed`/`gone` stay the fixed stubs until the later user-story phase
  // composes feedLines/goneText into this same function — not a second,
  // competing implementation.
  function panel(input) {
    input = input || {};
    var subject = input.subject || null;
    var row = input.row || null;
    var fields = input.fields || null;
    var header = {
      lead: "agent",
      name: subject ? subject.name : null,
      status: fields
        ? (fields.measure != null ? fields.word + " · " + fields.measure : fields.word)
        : null,
    };
    var stats;
    if (row) {
      var edges = edgesFor(subject ? subject.name : null, input.edges, input.names);
      stats = statLines(fields, row, {edges: edges});
    } else {
      stats = [{key: "sid", label: "session", text: subject ? subject.sid : null}];
    }
    var kill = killModel({
      row: row, fields: fields, volatile: input.volatile,
      canKill: input.canKill, confirmOpen: input.confirmOpen,
    });
    var send = sendModel({row: row, canSend: input.canSend});
    var ask = askModel(row);
    var cond = input.cond || null;
    // ⚠️ `gone` is only reachable when the feed is trustworthy. A missing row
    // means one of two very different things: the session left the machine, or
    // the read that would have found it failed. Announcing an exit on the
    // strength of a failed read invents an event that may not have happened
    // (principle VI), so a broken feed reports itself and says nothing about
    // where the session went.
    var gone = null;
    if (!row && subject && cond && cond.trust === "ok") {
      gone = goneText(subject.name, subject.sid);
    }
    return {
      header: header,
      stats: stats,
      feed: feedLines(cond),
      gone: gone,
      ask: ask,
      kill: kill,
      send: send,
    };
  }

  // §7 atBottom({scrollTop, scrollHeight, clientHeight}) → boolean
  // (contracts/modal-js.md §7, FR-018, D14). Non-finite or missing
  // measurements return true rather than throwing (B-E) — a broken
  // measurement must not wedge the conversation at the top.
  function atBottom(box) {
    box = box || {};
    var scrollTop = box.scrollTop, scrollHeight = box.scrollHeight, clientHeight = box.clientHeight;
    if (!isFinite(scrollTop) || !isFinite(scrollHeight) || !isFinite(clientHeight)) return true;
    if (scrollHeight <= clientHeight) return true;
    return scrollHeight - (scrollTop + clientHeight) <= FOLLOW_EPS;
  }

  // §11 convoMessage({row, ok, reason, turnCount}) → {message, isError}
  // (contracts/modal-js.md §11, data-model.md §11, FR-019, D15). Never
  // escalates the session's silence to a hang (C-E, principle VI).
  function convoMessage(input) {
    input = input || {};
    var row = input.row || null;
    if (row && row.entrypoint === "sdk-ts") {
      return {
        message: "this is an embedded-SDK session: it writes no transcript, so there is nothing to read here",
        isError: false,
      };
    }
    if (!input.ok) {
      return {message: "could not read the transcript: " + (input.reason || "unknown reason"), isError: true};
    }
    if (!input.turnCount) {
      return {message: "no turns in the transcript's last " + TRANSCRIPT_N + " entries yet", isError: false};
    }
    return {message: null, isError: false};
  }

  var api = {
    FOLLOW_EPS: FOLLOW_EPS,
    TRANSCRIPT_N: TRANSCRIPT_N,
    dur: dur,
    panel: panel,
    statLines: statLines,
    edgesFor: edgesFor,
    feedLines: feedLines,
    goneText: goneText,
    killModel: killModel,
    sendModel: sendModel,
    askModel: askModel,
    atBottom: atBottom,
    convoMessage: convoMessage,
  };

  root.CCWATCH_MODAL = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
