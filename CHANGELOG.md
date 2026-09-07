# Changelog

`ccwatch --version` prints the number in the heading below. Notable changes are
recorded here from the first public release onward.

## 1 — first public release

The whole point: a session must never be able to fail quietly.

**The live table** — every Claude Code session on the machine, sorted by how
much it needs you. A `busy` claim from the registry is corroborated against the
transcript's mtime *and* the process's CPU time before anything is called
`HUNG?`, and the measurement behind every verdict is printed next to it. An
embedded-SDK session, which publishes no status and writes no transcript, is
never escalated to a hang, because its silence measures nothing.

**Projects are repositories**, resolved from the git remote rather than the
directory name — so worktrees of one repo share a project, a repo nested inside
another is not merged into it, and deploy runs keyed `owner/name` actually
match. A directory with no remote is marked as such rather than folded into a
real repository.

**What a blocked session is asking** — `ccwatch ask` reads the pending
`AskUserQuestion` out of the transcript, with every option and its description.
The pending call is the one with no matching `tool_result`, so "unanswered" is a
fact in the file. `ccwatch convo` shows the recent conversation, with tool
results reduced to their size rather than their contents.

**Talking to a running session** — `ccwatch send` puts a message into the
session that is already running, over the per-session Unix socket Claude Code
exports to every tool call, and then watches the *receiver's* transcript to
report `delivered`, `queued` or `failed` with the real reason. Writing to a
socket is not evidence of delivery.

**Usage and context** without handing a credential to a monitoring tool:
`ccwatch install-statusline` wraps your existing statusline and records the
`rate_limits` and `context_window` figures Claude Code already pushes there. A
reading past its staleness window has its numbers **withheld**, not annotated.

**In a browser** — `ccwatch serve` gives a table and a map view where each
project is a territory and each session a figure whose appearance carries its
status. Replies from the page go through the same `ccwatch send` code path as
the terminal. The send endpoint is gated by a per-run token *and* an `Origin`
check, because loopback is not a security boundary; `--read-only` removes it
entirely.

**Deploys** — `ccwatch deploys` shows deploy-shaped workflow runs in flight and
concluded in the last 24h, and an agent can `ccwatch subscribe` itself to one
and be messaged by `ccwatch daemon` when it lands, without polling or holding a
connection open. A `gh` failure is reported with its actual message.

**After a reboot** — `ccwatch resume` rebuilds the list from transcripts, which
survive restarts, and prints the last known roster: who was live, what each was
doing when everything stopped, and the command to reopen it.

**Who is talking to whom** — `ccwatch peers` builds the graph from receivers'
transcripts, preferring the pid the socket server verified over the name the
sender asserted.

**`ccwatch doctor`** cross-checks ccwatch's own parse of an undocumented file
layout against the supported `claude agents --json`, so that a Claude Code
upgrade surfaces as a failing check rather than as an empty, confident table.

Fixed before release: `ccwatch serve` could not find its web assets when the
tool was installed as the symlink the README recommends, because the script
resolved its own location without following the link.
