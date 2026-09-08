// ccwatch — markdown for the transcript view.
//
// Claude writes markdown. Rendering it as literal text means the thing you most
// want to skim — a numbered plan, a fenced diff, a bolded conclusion — arrives
// as a wall of asterisks and backticks in a 560px drawer, and the reason you
// opened the inspector (what is this agent actually doing?) takes three reads
// instead of one.
//
// ⚠️ Every character here comes out of a transcript, which is to say out of
// arbitrary file contents and tool output. So there is one rule and it is
// absolute: ESCAPE FIRST, THEN ADD TAGS. No branch below puts a substring of
// the input into the output unescaped, and there is no "sanitise the HTML
// afterwards" pass — that is the pass that has a hole in it.
//
// ⚠️ Code spans are handled by SPLITTING the line on them, not by swapping in
// a placeholder and swapping it back. A placeholder is a string the input could
// also contain, which makes it forgeable: text carrying the sentinel would have
// its own contents spliced in after the escaping had already happened.
//
// ⚠️ And no anchors, deliberately — not even for an http(s) URL that looks
// safe. A link in this panel would be a one-click outbound request carrying
// content derived from a transcript, and transcripts are the sensitive thing
// this tool is most careful with (invariant 10). A markdown link renders as its
// label followed by the URL as text: readable, copyable, and nothing leaves the
// machine because you clicked on a conversation.
//
// Deliberately unsupported: raw HTML (the escaping drops it, which is the
// point), reference links, footnotes, tables. Tables in a narrow drawer are
// unreadable either way, and every construct added here is one more regex
// pointed at untrusted text.
//
// This lives in its own file rather than inline in map.html so the suite can
// run it under node and assert on the HTML it produces. An XSS assertion you
// cannot execute is a comment, not a test.
(function (root) {
  "use strict";

  var ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

  function esc(s) {
    return String(s === null || s === undefined ? "" : s)
      .replace(/[&<>"']/g, function (c) { return ESCAPES[c]; });
  }

  // The reducer in `ccwatch convo` collapses a tool USE to "→ name: arg", a
  // tool RESULT to "  ← N bytes", and marks thinking as "· thinking". Those are
  // ccwatch's own words rather than the model's, and they stay verbatim: a glob
  // argument like `**/*.ts` must not come back from here in italics, and a file
  // path is not a heading.
  var META = /^(?:→ |  ← |· )/;

  var FENCE_OPEN = /^ {0,3}(```+|~~~+)[ \t]*([^`~]*)$/;
  var FENCE_SHUT = /^ {0,3}(```+|~~~+)[ \t]*$/;
  var HEADING = /^ {0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$/;
  var RULE = /^ {0,3}([-*_])[ \t]*(?:\1[ \t]*){2,}$/;
  var QUOTE = /^ {0,3}>[ \t]?(.*)$/;
  var BULLET = /^([ \t]*)[-*+][ \t]+(.*)$/;
  var NUMBER = /^([ \t]*)\d{1,9}[.)][ \t]+(.*)$/;

  // Nesting is bounded because the input is not: a 1200-character turn that is
  // all "> " is 600 levels, and following it produces 600 nested elements in
  // the DOM for one turn of one session, on a panel that re-renders every five
  // seconds. Measured, so as not to overstate it — node renders that depth
  // without complaint, so this is about bounded output, not a stack overflow.
  // Past the cap the remaining markers are shown as the text they are.
  var MAX_QUOTE_DEPTH = 4;
  var MAX_LIST_DEPTH = 4;

  function isBlockStart(line) {
    return FENCE_OPEN.test(line) || META.test(line) || RULE.test(line) ||
           HEADING.test(line) || QUOTE.test(line) ||
           BULLET.test(line) || NUMBER.test(line);
  }

  // ---- inline ---------------------------------------------------------------

  // Called only on already-escaped text.
  function linkAsText(_m, label, url) {
    var u = url.replace(/[ \t]+&quot;[\s\S]*$/, "");   // drop a ("url" "title") title
    if (!u) return label;
    if (!label || label === u) return '<span class="mdurl">' + u + "</span>";
    return label + ' <span class="mdurl">(' + u + ")</span>";
  }

  function emphasise(s) {
    // Images and links alike: the label survives, the URL becomes text.
    s = s.replace(/!?\[([^\]]*)\]\(([^)\s]*(?:[ \t]+&quot;[^)]*&quot;)?)\)/g, linkAsText);

    // ⚠️ `**` before `*`, and `__` before `_`, or the two-character form gets
    // eaten one character at a time and comes out as <em>*text*</em>.
    //
    // ⚠️ No delimiter may be followed or preceded by a space. Markdown says so,
    // but the reason it matters here is arithmetic and shell globs: `2 * 3 * 4`
    // rendered as "2 <em> 3 </em> 4", and multiplication is not rare in a
    // conversation about costs and token counts.
    //
    // ⚠️ The underscore forms additionally require a SPACE inside them, so the
    // content has to be more than one word. Transcripts are full of dunders and
    // snake_case: `__init__` came out as a bold "init", and `_private` next to
    // `count_` would pair up across half a line of code. Prose italics are
    // nearly always `_more than one word_`; identifiers never are.
    return s.replace(/\*\*(?!\s)([^*\n]*[^*\s])\*\*/g, "<strong>$1</strong>")
            .replace(/(^|[^\w*])\*(?!\s)([^*\n]*[^*\s])\*(?![\w*])/g, "$1<em>$2</em>")
            .replace(/(^|[^\w_])__(?!\s)([^_\n]*[ ][^_\n]*[^_\s])__(?![\w_])/g, "$1<strong>$2</strong>")
            .replace(/(^|[^\w_])_(?!\s)([^_\n]*[ ][^_\n]*[^_\s])_(?![\w_])/g, "$1<em>$2</em>")
            .replace(/~~(?!\s)([^~\n]*[^~\s])~~/g, "<del>$1</del>");
  }

  function inline(text) {
    var raw = String(text === null || text === undefined ? "" : text);
    var re = /(`+)([^`]+)\1/g;
    var out = "", last = 0, m;
    // The split, not a placeholder: emphasis is applied to the gaps between
    // code spans, so `a * b` and `__init__` survive as written.
    while ((m = re.exec(raw)) !== null) {
      out += emphasise(esc(raw.slice(last, m.index)));
      out += "<code>" + esc(m[2]) + "</code>";
      last = re.lastIndex;
    }
    return out + emphasise(esc(raw.slice(last)));
  }

  // ---- lists ----------------------------------------------------------------

  function indentWidth(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) n += s.charAt(i) === "\t" ? 4 : 1;
    return n;
  }

  // Collect the run of list lines starting at `from` as flat items carrying
  // their indent. Nesting is worked out afterwards, in renderItems.
  function collectItems(lines, from) {
    var items = [], i = from;
    while (i < lines.length) {
      var line = lines[i];
      if (RULE.test(line)) break;              // `- - -` is a rule, not a bullet
      var m = line.match(BULLET), ordered = false;
      if (!m) { m = line.match(NUMBER); ordered = !!m; }
      if (!m) {
        // An indented non-blank line after an item is that item's second line
        // ("- do the thing\n  because of X"), not a new paragraph.
        if (items.length && line.trim() && /^[ \t]{2,}/.test(line)) {
          items[items.length - 1].text += "\n" + line.trim();
          i++;
          continue;
        }
        break;
      }
      items.push({ indent: indentWidth(m[1]), ordered: ordered, text: m[2] });
      i++;
    }
    return { items: items, next: i };
  }

  function renderList(items, from, indent, depth) {
    var ordered = items[from].ordered;
    var html = ordered ? "<ol>" : "<ul>";
    var i = from;
    while (i < items.length) {
      // A shallower item, or a switch between bullets and numbers, ends this
      // list. The caller loops, so what is left still gets rendered — dropping
      // it would silently lose half a plan.
      if (items[i].indent < indent) break;
      if (items[i].ordered !== ordered && items[i].indent === indent) break;
      var body = items[i].text.split("\n").map(inline).join("<br>");
      i++;
      var sub = "";
      if (i < items.length && items[i].indent > indent && depth < MAX_LIST_DEPTH) {
        var r = renderList(items, i, items[i].indent, depth + 1);
        sub = r.html;                     // nested inside the <li>, as HTML wants
        i = r.next > i ? r.next : i + 1;
      }
      html += "<li>" + body + sub + "</li>";
    }
    return { html: html + (ordered ? "</ol>" : "</ul>"), next: i };
  }

  function renderItems(items, depth) {
    var html = "", i = 0;
    while (i < items.length) {
      var r = renderList(items, i, items[i].indent, depth);
      html += r.html;
      // ⚠️ The guard is not decoration. Any later change that lets renderList
      // return without consuming an item turns this into an infinite loop, and
      // a render that never returns is an empty panel.
      i = r.next > i ? r.next : i + 1;
    }
    return html;
  }

  // ---- blocks ---------------------------------------------------------------

  function blocks(lines, depth) {
    var out = [], i = 0;

    while (i < lines.length) {
      var line = lines[i], m;

      if (!line.trim()) { i++; continue; }

      m = line.match(FENCE_OPEN);
      if (m) {
        var lang = m[2].trim(), body = [];
        i++;
        while (i < lines.length && !FENCE_SHUT.test(lines[i])) { body.push(lines[i]); i++; }
        if (i < lines.length) i++;                      // eat the closing fence
        // An unterminated fence is the common case, not the edge case: a turn
        // is truncated at 1200 characters, which lands mid-block most times a
        // model pastes a file. Closing it here beats rendering the rest of the
        // conversation inside a code block.
        out.push("<pre" + (lang ? ' data-lang="' + esc(lang) + '"' : "") +
                 "><code>" + esc(body.join("\n")) + "</code></pre>");
        continue;
      }

      if (META.test(line)) {
        var meta = [];
        while (i < lines.length && META.test(lines[i])) { meta.push(esc(lines[i])); i++; }
        out.push('<div class="mdmeta">' + meta.join("<br>") + "</div>");
        continue;
      }

      if (RULE.test(line)) { out.push("<hr>"); i++; continue; }

      m = line.match(HEADING);
      if (m) {
        // `#` becomes h4, not h1. Heading levels in a transcript are the
        // model's document structure, not this page's, and an h1 inside a
        // drawer is both a lie to a screen reader and 32px of shouting.
        var lvl = Math.min(6, m[1].length + 3);
        out.push("<h" + lvl + ">" + inline(m[2]) + "</h" + lvl + ">");
        i++;
        continue;
      }

      if (QUOTE.test(line)) {
        var quoted = [];
        while (i < lines.length && QUOTE.test(lines[i])) {
          quoted.push(lines[i].match(QUOTE)[1]);
          i++;
        }
        out.push(depth < MAX_QUOTE_DEPTH
          ? "<blockquote>" + blocks(quoted, depth + 1) + "</blockquote>"
          : "<p>" + quoted.map(inline).join("<br>") + "</p>");
        continue;
      }

      if (BULLET.test(line) || NUMBER.test(line)) {
        var c = collectItems(lines, i);
        if (c.items.length) {
          out.push(renderItems(c.items, depth));
          i = c.next > i ? c.next : i + 1;
          continue;
        }
      }

      var para = [];
      while (i < lines.length && lines[i].trim() && !isBlockStart(lines[i])) {
        para.push(inline(lines[i].trim()));
        i++;
      }
      // Progress guard: should the dispatch above and isBlockStart ever
      // disagree about a line, consume it rather than spin on it.
      if (!para.length) { para.push(inline(lines[i].trim())); i++; }
      out.push("<p>" + para.join("<br>") + "</p>");
    }

    return out.join("");
  }

  function render(text) {
    var s = String(text === null || text === undefined ? "" : text);
    return blocks(s.split(/\r?\n/), 0);
  }

  var api = { render: render, escapeHtml: esc };

  root.CCWATCH_MD = api;
  // node, for the assertions in tests/run.sh. The browser never sees this.
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
