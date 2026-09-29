# Security

## Reporting

Please report anything with a security dimension privately, via GitHub's
[private vulnerability reporting][pvr] on this repository, rather than in a
public issue.

[pvr]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

## What this tool touches, so you can judge the risk yourself

`ccwatch` runs entirely on your machine as your user. It has no account, no
telemetry, and makes no network request of its own except through `gh` for the
deploy panel.

**It reads:**

- `~/.claude/sessions/<pid>.json` — the live session registry
- `~/.claude/projects/**/*.jsonl` — session transcripts
- `<repo>/specs/*/.pipeline/state.json` — the spec-run pipeline overlay
- `git remote` and the current branch, per working directory
- the JSON payload Claude Code hands a statusline command, if you install the
  wrapper

**It writes:** its own event log and caches under `~/.claude/ccwatch/`, a
CPU-sample cache in `$TMPDIR`, and — only when you run `install-hooks` or
`install-statusline` and confirm the diff it shows you — `~/.claude/settings.json`,
after taking a timestamped backup.

**It never** reads or requests your OAuth token or any other credential. The
usage figures come from the payload Claude Code already pushes to a statusline
command, specifically so that a monitoring tool never has to handle a
credential in order to display a percentage.

## Transcripts are the sensitive part

Session transcripts contain whole tool outputs and file contents — which means
source, secrets that were printed, whatever an agent happened to `cat`. Two
places had to be designed around that:

- `ccwatch convo` and the browser views read a **bounded byte tail**, keep
  assistant and user text truncated, reduce a tool *use* to its name and a short
  argument summary, and reduce a tool *result* to its **size, never its
  content**.
- `ccwatch serve` binds `127.0.0.1` only. What it serves still discloses which
  repositories you work in and fragments of messages between sessions, so treat
  the page as you would your terminal.
- The transcript panel **renders that text as markdown**, which makes it markup
  handling over untrusted input, so: `web/md.js` escapes every character before
  it adds a single tag, has no sanitise-afterwards pass, and splits lines on
  code spans rather than using a placeholder a transcript could forge. A
  `<script>` or `<img onerror=…>` in a file an agent read is displayed as the
  text it is. The escaping is asserted by tests verified to fail with it
  removed.
- **A markdown link is rendered as text, never as an anchor.** A clickable link
  in that panel would be a one-click outbound request carrying content derived
  from a transcript; the label and the URL are shown so you can read and copy
  them, and no scheme is exempted.

## The send endpoint

`ccwatch serve` can inject a message into a running session. **Binding to
loopback is not a security boundary for this** — any page open in your browser
can POST to `127.0.0.1`, and without a real gate a random site could inject
prompts into every agent you have running. Two independent checks close it:

1. a **per-run token**, generated at startup and injected into the page ccwatch
   itself serves — same-origin policy stops another site reading that HTML;
2. an **`Origin` check**, because browsers attach `Origin` to cross-origin POSTs.

Both are asserted by tests verified to fail with either check removed. Neither
may be weakened on the grounds that the other exists. `ccwatch serve
--read-only` removes the endpoint entirely and serves no token.

Messages injected this way arrive in the receiver as an ordinary user turn
labelled `from: ccwatch`, and Claude Code wraps them with its own warning that a
peer cannot grant permission escalation. `ccwatch` does not and cannot answer a
permission prompt or an `AskUserQuestion` dialog on your behalf — see the
"You can read the question" section of `docs/DESIGN.md`.

## Unsupported interfaces

`ccwatch` reads two things Claude Code does not document as public interfaces:
the session registry and the transcript JSONL. A Claude Code upgrade may move
either. `ccwatch doctor` cross-checks its own parse against the supported
`claude agents --json` so that you find out from a failing check rather than
from an empty, confident table.
