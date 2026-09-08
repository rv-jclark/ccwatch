# ccwatch Constitution

ccwatch reports on every Claude Code session on the machine and says which one
is stuck. Its only product is a claim about state that a person will act on
without checking. Every principle below exists because breaking it produced a
specific wrong output that someone believed. They are invariants, not
preferences.

`CLAUDE.md` and `README.md` are the operative long-form statements of these
rules; this file is the version every pipeline phase reads. Where they appear to
disagree, `CLAUDE.md` wins and this file is amended to match.

## Core Principles

### I. Never make a claim on one signal (NON-NEGOTIABLE)

A status is corroborated against a second, independent signal — transcript
mtime, CPU time, a runner pid — before it is escalated. `busy` from the registry
alone is not evidence of work. Any new verdict, badge, colour, animation or
figure state must name the signals behind it and refuse to escalate on one.

### II. Print the measurement next to the verdict

`HUNG?` always shows the silence and the CPU reading that produced it. The
judgement belongs to the person reading. A column that cries wolf is a column
they stop reading, so a severity must always be accompanied by the number that
justified it.

### III. A stale reading is withheld, not annotated (NON-NEGOTIABLE)

A percentage on screen is read as current whatever is printed beside it. Usage
and context readings past their staleness window are dropped, and the header
says how old the last one was. Never render a number with an "(old)" note and
call that honest. In a live view this means the volatile numbers go and the
stable structure stays — not the reverse.

### IV. A failure must never look like an absence (NON-NEGOTIABLE)

"no deploys" and "HTTP 401: Bad credentials" are different facts and must read
differently. A `gh` failure leaves the previous cache in place rather than
replacing it with an empty list. An unreadable registry file costs one row and
is counted, so `doctor` can report it. A feed that is down, a snapshot still
warming, rows that could not be read, and a genuine absence of sessions are four
distinct facts requiring four distinct renderings. A capability that is disabled
by configuration is shown as disabled with the reason, never hidden — hiding it
reads as "not built".

### V. Never invent a status you did not read

An unrecognised value from the registry is surfaced by `doctor` rather than
falling through a default branch and being presented as though it had been
understood. No default arm may manufacture a verdict.

### VI. Say nothing rather than guess

An embedded-SDK session (`sdk-ts`) writes no transcript and publishes no status,
so its silence measures nothing and is never escalated to a hang. A directory
with no git remote is marked `no repo` rather than folded into a real
repository, and never grouped under an organisation it does not belong to.

### VII. Colour is never the only carrier of meaning

Every severity also has a distinct word, so `ccwatch once | grep HUNG` works and
so does a screen reader. `NO_COLOR` is honoured. A graphical view must carry an
equivalent textual representation of every claim it draws; a canvas or an SVG
figure is not a substitute for readable text.

### VIII. Delivery is observed, not assumed

`ccwatch send` watches the receiver's transcript for the message to land and
reports delivered / queued / failed with the real reason. Writing to a socket
proves nothing. The same standard applies to any new action: report what was
observed to happen, not what was attempted.

### IX. Loopback is not a security gate (NON-NEGOTIABLE)

Any page in the browser can POST to `127.0.0.1`. Write endpoints require both a
per-run token injected into the page ccwatch serves *and* an `Origin` check.
Neither may be weakened on the grounds that the other exists. Destructive
actions stay behind their explicit opt-in flag and their confirmation step.

### X. Transcripts are sensitive (NON-NEGOTIABLE)

Transcripts contain whole tool outputs and file contents. `convo` reads a
bounded byte tail, keeps assistant/user text truncated, reduces a tool *use* to
its name and a short argument summary, and a tool *result* to its size — never
its content. Nothing may put that content on a socket.

### XI. One code path computes status

`/api/state` invokes the commands the CLI does. Two renderings that compute
status separately will eventually disagree, and there is no way to tell which is
lying. A view may lay out, group, sort and animate what the payload says; it may
not derive a status, severity or verdict of its own.

### XII. Normal conditions are silent

A line that appears on every refresh to say things are fine is a line people
learn to skip, and then it is not there when it matters. Warnings appear at a
threshold and are absent below it — not green, absent.

### XIII. Position is stable; only status moves

Anything a person navigates must hold still. Layout derives from identity, never
from a volatile reading: a session changing severity may change colour, pose or
emphasis, never a coordinate or an ordering. Where volatile ordering is
genuinely useful it belongs in an explicit list, which is expected to be
ordered — never in a spatial arrangement, which is expected to be remembered.

## Additional Constraints

- **bash 3.2**, because that is what macOS ships. No `mapfile`/`readarray`, no
  `declare -A`, no `${var,,}`/`${var^^}`. The suite greps for these.
- **macOS `stat -f` and `ps -o lstart=`** in their BSD forms. This is a macOS
  tool; CI runs on macOS only.
- `python3` supplies the socket client, date parsing and the HTTP server.
  Programs are passed with `python3 -c`, never on stdin — a heredoc on stdin
  collides with the payload the program is trying to read.
- `shellcheck -x -S warning` must be clean for `bin/ccwatch` and `tests/run.sh`.
  Suppress with a narrow `# shellcheck disable=` and a stated reason, never by
  loosening the severity.
- **No build step and no dependencies to install.** `bin/ccwatch` is the whole
  tool; `web/*.html` are static pages with inline CSS and JS. No package
  manifest, no bundler, no CDN fetch at runtime.
- Runtime state lives in `~/.claude/ccwatch/` and is never committed.

## Development Workflow and Quality Gates

- `./tests/run.sh` is the only test entry point: shellcheck, then the
  assertions. In a restricted sandbox roughly 13 assertions fail with empty
  output (`resume`, `peers`, `serve`) because `mktemp` is denied — that is the
  sandbox, not a regression, and must be re-run with the sandbox off before a
  failure is believed.
- **Hermetic tests.** Every assertion runs against a fabricated `~/.claude`
  under `$WORK` via `CLAUDE_CONFIG_DIR`, with `CCWATCH_FAKE_PS` substituting the
  liveness probe. Never assert against live sessions — that is a screenshot,
  not a test.
- **Mutation-check every new assertion.** Break the implementation in the
  specific way the assertion describes, confirm the assertion fails, then
  restore, then add a row to the mutation table in `README.md`. An assertion
  that passes against a broken implementation is worse than none, because it is
  counted as coverage.
- **Fixtures must be able to fail.** A fixture where the behaviour under test
  could not have succeeded anyway passes either way; that has happened here and
  is a test defect.
- `TALLY_FLOOR` in `tests/run.sh` guards against assertions that run but are
  never counted; raise it when adding a batch.
- Reap anything a test starts. A leaked `serve` holds a port a later run may
  pick, and then that run tests the leaked binary.
- **An assertion must not encode one machine's configuration.** Where the host
  cannot supply what a test needs — no swap, a slow CPU, no `curl` — skip with
  the reason stated rather than failing. A red suite meaning "this runner is
  configured differently" costs the same attention as a real regression.
- Comments say **why**, and name the failure that motivated the code; the `⚠️`
  comments are load-bearing and are not trimmed. Prefer the concrete measured
  number over an adjective. This applies to `README.md`, which documents the
  reasoning and the bugs found, not just the flags.
- README and fixture examples stay **generic** (`acme/checkout-api`, `web-app`,
  `pricing`). No real session names, repository slugs, feature ids or costs from
  a development machine ever appear in documentation or fixtures.
- Conventional commit prefixes (`feat:`, `fix:`, `docs:`, `test:`), subject in
  the imperative describing the user-visible change. Do not commit or push
  unless asked.

## Governance

This constitution supersedes convenience. A phase that cannot satisfy a
principle stops and says so rather than shipping the violation; the violation is
not a trade-off to be silently taken. Any new severity, verdict or visual state
must state which signals corroborate it (I), print its measurement (II), read as
text (VII), and come from the payload rather than the view (XI). Any new write
endpoint or destructive action must satisfy IX and VIII.

Amendments are made to `CLAUDE.md` and mirrored here, with the failure that
motivated the change named in the commit.

**Version**: 1.0.0 | **Ratified**: 2026-09-07 | **Last Amended**: 2026-09-07
