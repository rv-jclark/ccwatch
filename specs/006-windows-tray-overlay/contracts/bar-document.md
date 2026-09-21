# Contract — the bar document, between one CLI and three renderers

`ccwatch bar --no-actions` prints the only source of any verdict either GUI
displays (FR-016–FR-019). It already has two consumers — the macOS app
(`app/Sources/main.swift:139-201`) and the SwiftBar plugin
(`extra/swiftbar/ccwatch.10s.sh`) — and this feature adds a third. That is why
the format is written down here rather than left to be inferred from the Swift:
three renderers of one document need one set of rules, and the third one may not
choose its own dialect.

**The format does not change in this feature.** This contract states what it
already is and what a renderer must do with it.

---

## The bytes

```
<title line>
---
<item line>
<item line>
---
<item line>
```

| Line | Meaning |
|---|---|
| line 0 | the tray/menu-bar title |
| `---` | opens the menu, and separates groups within it |
| any other non-empty line | a menu item |
| trailing empty lines | ignored |

An item line is `<text>` or `<text> | <key>=<value> <key>=<value>…`.

### Rule 1 — split on the **first** ` | `, and no other

`cmd_bar` pipes every interpolated field through

```jq
def clean: (. // "") | tostring | gsub("\\|"; "¦") | gsub("[\n\r\t]"; " ");
```

so a session named `a|b` arrives as `a¦b` and exactly one separator can appear
per line. A renderer that split on the *last* ` | ` would hand an
attacker-shaped session name the parameter list back — and in the SwiftBar
vocabulary `bash=` is a parameter that makes a menu row a clickable command.

This is a security property, not tidiness. It is asserted in the macOS
selftest (`a neutralised pipe stays in the text where the CLI put it`, `no
bash= parameter is ever parsed out of a row`) and the Windows selftest asserts
the same two claims against the same input.

### Rule 2 — a parameter you do not implement leaves the line **displayed**

Unknown `key=value` pairs are kept and the item still renders as text (FR-018).
A future CLI item silently vanishing from the menu is a failure that looks like
an absence, which principle IV forbids.

### Rule 3 — a quoted value may contain spaces

`param1="two words"`. Surrounding double quotes are stripped. A renderer that
does not implement a parameter keeps the raw value.

### Rule 4 — no renderer computes anything

Every status, count, word, threshold, severity, glyph and measurement comes from
these bytes (FR-016, principle XI). A renderer may lay out, colour, order within
the document's own order, and add verbs. It may not derive a verdict, a badge or
a count.

---

## Parameters, and who implements what

| Parameter | Meaning | macOS app | SwiftBar | Windows app |
|---|---|---|---|---|
| `color=` | named, `#rrggbb`, or `light,dark` pair | yes | host | yes |
| `size=` | point size | yes | host | yes |
| `font=` | monospaced when it names Menlo/mono | yes | host | yes |
| `sfimage=` | an Apple SF Symbol name for the title | yes | host | **kept, not rendered** — no equivalent on Windows; the words carry the condition |
| `href=`, `bash=`, `param*=`, `terminal=`, `refresh=` | SwiftBar verbs | not parsed | host | **not parsed** |

`--no-actions` is what both apps pass, and it suppresses the verb rows for a
host that supplies its own (`bin/ccwatch:1459-1466`). It never affects the
status content: what a host may replace is the verbs, never a verdict.

The Windows app parsing **no** `bash=` at all is a second, independent reason no
clickable command can come out of a session name — on top of rule 1 and on top
of the CLI's `clean`.

---

## The title

| Situation | Title | Rule |
|---|---|---|
| normal | e.g. `37% · resets in 2h · 1 waiting` | rendered verbatim |
| snapshot failed | `cc ?` | **never a count** (FR-019) |
| CLI not found by the app | `cc !` | the app's own state, not the CLI's; stated as such |

When the snapshot failed, the menu must carry the sentence that says so —
`ccwatch could not read the sessions` and `This is NOT "nothing is running" —
the snapshot itself failed.` A calm item with nothing under it is what a quiet
machine and a blind tool both look like from across the room, and there is no
surrounding page to carry the reason.

`?` is not a number anyone reads as a count. That is the whole reason it was
chosen.

---

## Words, not colour

Every severity in the document carries a distinct word (`HUNG?`, `waiting`,
`idle`, …) and the measurement that justified it (`quiet 20m`) on the same line.
A renderer must keep both. Colour, glyph and icon are additions to a reading
that survives without any of them (FR-020, principles II and VII) — which is
what makes the tray legible under a high-contrast Windows theme and to a screen
reader, and what makes `ccwatch once | grep HUNG` work.

A renderer must not use colour to distinguish two items whose words are
identical, because it would then be carrying meaning the CLI did not put in the
text.

---

## Conformance — the four inputs every renderer is tested against

These are the macOS selftest's inputs. The Windows selftest uses the same ones,
so the two cannot drift apart about the format they share.

1. **A normal document** — title with `sfimage=` and `color=`, two separators,
   two monospaced severity rows carrying measurements.
   Asserts: the title is the CLI's with parameters stripped; the condition is
   still spelled out in words; both separators survive; `quiet 20m` reaches the
   menu; the severity colour is carried rather than recomputed; a Menlo row
   renders monospaced.
2. **The injection document** —
   `* evil ¦ bash=/bin/sh param1=-c  repo  idle | color=gray`.
   Asserts: `evil ¦ bash=/bin/sh` stays in the *text*; no item has a `bash=`
   parameter.
3. **Empty output** — asserts the title is `cc ?`, never a count.
4. **An unknown parameter** — asserts the line is still displayed and the
   parameter is retained (FR-018).

A renderer that passes all four has satisfied FR-017 and FR-018.

---

## What is explicitly not in this contract

- **No second format.** No machine-readable variant, no `--json` path for a
  tray, no new endpoint. A tray that read a payload and decided severity for
  itself would be the second place computing status that this whole arrangement
  exists to prevent.
- **No submenus.** The macOS `bar` section records why: a submenu is a collapsed
  badge, and it turns a crashed phase into something you have to hover to
  discover. Sub-rows are indented with spaces and stay visible.
- **No new parameters.** If a future feature needs one, the CLI adds it and
  every renderer's rule 2 means nothing breaks in the meantime.
