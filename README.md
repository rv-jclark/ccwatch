# ccwatch

[![ci](https://github.com/rv-jclark/ccwatch/actions/workflows/ci.yml/badge.svg)](https://github.com/rv-jclark/ccwatch/actions/workflows/ci.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Every Claude Code session on this machine, and which one is stuck.

```
NAME                  PROJECT            STATUS         AGE   LAST
checkout-api-d9       checkout-api       * waiting      3m    permission to run rm 3m
web-app-fc            web-app            ! HUNG?        4d    quiet 41m
pricing-84            pricing            + sdk          5m    no status published
  \_ 011-usage-report  analyze/running  opus  $11.15
infra-38              infra              ~ sdk-ts       4d    cpu moving
infra-e6              infra              - idle         1d    14m ago

UNFINISHED RUNS — stopped in the last 24h, and no live session is holding them
  specify/failed       314-cohort-capacity  opus  $55.19
      9h ago  claude --resume 15dbe4c0-58ef-4ace-8b21-f633c37caa85

19 live · 1 waiting on you · 1 suspect · 3 unfinished run(s)
```

If you run several Claude Code sessions at once, ccwatch answers three
questions:

- **Which one is waiting on me?** It also shows what the session is asking.
- **Which one says "busy" but has actually stopped?** Claude Code's own
  `claude agents` never re-checks `busy`. ccwatch checks it against the
  transcript and the process's CPU time, and shows the reading next to the
  verdict so you can judge it.
- **What was I in the middle of before the reboot?** `claude agents` is empty
  after a restart. ccwatch rebuilds the list from transcripts.

You can see this as a terminal table, a menu bar item with an always-on-top
overlay, or a dashboard in the browser. All three show the same verdicts
because they run the same code.

## Install

**macOS only.** Windows support is in progress and does not work yet, so don't
set this up for someone on Windows.

```bash
xcode-select --install     # once per Mac: git, python3 and swiftc all come from this
brew install jq            # the one dependency macOS doesn't ship

git clone https://github.com/rv-jclark/ccwatch.git ~/code/ccwatch
cd ~/code/ccwatch
./bin/ccwatch setup        # puts `ccwatch` on your PATH and checks the result
```

Clone it somewhere you mean to keep it. `setup` links to the checkout rather
than copying it, so `git pull` is how you upgrade, and moving or deleting the
checkout breaks the command.

`setup` puts the link in the first writable directory among `~/.local/bin`,
`/opt/homebrew/bin` and `/usr/local/bin`. It then **runs** the link to check
that it works, and prints the `export PATH=…` line to add if that directory
isn't on your `PATH`. Don't use `sudo`. Pass `--bin-dir DIR` to choose the
directory yourself.

Then confirm that ccwatch can see your sessions:

```bash
ccwatch doctor
```

### Optional: see more

Each of these prints the exact change it will make to
`~/.claude/settings.json` and asks before writing. It also backs the file up
first.

```bash
ccwatch install-statusline   # rate-limit usage and per-session context fill
ccwatch install-hooks        # record prompts that open and close between refreshes
```

Without the statusline, the usage figures and the `CTX` column stay blank.
`install-statusline` wraps whatever statusline you already have and keeps it.
Without the hooks, ccwatch can miss a prompt that was answered or dismissed
between two refreshes.

### The menu bar app

```bash
./app/build.sh --install --run   # build, copy into /Applications, launch
```

This adds a `cc` item to the menu bar. Its menu lists anything that needs you
and opens an always-on-top overlay of the map or the full dashboard. Tick
**Open at Login** in that menu to keep it running.

- **Install it; don't run it from `app/build/`.** `build.sh` wipes that
  directory on every build, and a login item that points there disappears with
  it.
- **Rebuild after moving the checkout.** The app records the checkout's path
  when it is built, because a GUI app doesn't get your shell's `PATH`.
- **Build it on the machine that will run it.** A build copied from another
  Mac has only an ad-hoc signature. Gatekeeper then blocks it until you allow
  it under **System Settings → Privacy & Security → Open Anyway**.

## Your first five minutes

```bash
ccwatch                 # the live table; q or Ctrl-C to quit
ccwatch serve --open    # the same thing in a browser, plus a map view
```

Open a Claude Code session in another terminal and it appears in the table
within a couple of seconds. Ask it something that needs your permission and its
row turns to `* waiting`, with the reason in `LAST`.

### Reading the status column

| Status | Meaning | What to do |
|---|---|---|
| `* waiting` | Blocked on you. `LAST` says on what, and for how long. | `ccwatch ask` shows the question. Answer it in that session's terminal. |
| `! HUNG?` | Says it is busy, but the transcript has stopped growing and the CPU has stopped moving. | Look at it. A long network wait can look like this, so `LAST` shows the reading. |
| `! HUNG!!` | The same, silent for more than 3× the threshold. | Very likely stuck. |
| `! SDK STALE?` | A headless `claude -p` run has gone quiet. | Check whatever launched it. |
| `! NO TRANSCRIPT` | Claims to be working, but has no transcript to back that up. | Look at it. |
| `+ busy` / `+ sdk` | Working, and a second signal confirms it. | Nothing. |
| `~ sdk-ts` | Embedded in another program. It publishes no status, so it is never called hung. | Nothing. |
| `~ shell` | Dropped to a shell. | Nothing. |
| `- idle` | Waiting for a prompt, with nothing pending. | Nothing. |

Every status has a word as well as a colour, so `ccwatch once | grep HUNG`
works, `NO_COLOR=1` works, and screen readers work.

Rows can have two extra parts:

- **An indented sub-row** (`\_ 011-usage-report  analyze/running`) is a
  [spec-run](https://github.com/rv-jclark/speckit-pipeline) pipeline phase that
  the session is driving. `plan/CRASHED` means the phase is still marked
  running, but its runner process is gone.
- **`UNFINISHED RUNS`** lists pipeline runs that stopped in the last 24 hours
  with no live session attached. Each comes with the `claude --resume` command
  to pick it back up.

### A warning line under the table

A warning line appears **only** when something is wrong, and is absent the
rest of the time. The one you are most likely to see is:

```
! host under memory pressure  swap 95% used (26155/27648MB), 58MB RAM free
  — the OS may kill sessions, and a killed session looks exactly like a clean exit
```

## Everyday commands

```bash
ccwatch ask                  # what each blocked session is asking, with its options
ccwatch convo <who>          # the recent conversation of one session
ccwatch resume               # what to reopen after a crash or reboot
ccwatch resume --cd          #   ...as `cd <dir> && claude --resume <id>` lines to paste
ccwatch send <who> "<msg>"   # message a session that is already running
ccwatch revive               # nudge agents that stopped too early (see below)
ccwatch kill <who>           # stop a session; refuses when that would lose work
```

`<who>` can be a session name, a session id (8 or more characters of it) or a
pid. If a name matches more than one session, ccwatch refuses and lists the
matches instead of picking one.

A few things are worth knowing up front:

- **`ask` shows a question, but you answer it in the session's own
  terminal.** A message sent to a session with an open dialog waits in its
  queue until the dialog is dealt with. It does not answer the dialog.
- **`send` reports whether the message arrived.** It reads the receiving
  session's transcript to check, then tells you `delivered`, `queued`
  (normal if the session is mid-turn) or `could not deliver`, with the reason.
- **`revive` types what you would have typed.** Turn it on once with the
  `revive: off` switch in the dashboard's header (or `ccwatch revive
  --enable`) and `ccwatch serve` runs it every minute from then on, whether
  or not a page is open. The switch is remembered across restarts. It sends
  `retry` to a session stopped by an API error once the API answers again,
  `continue` once a session limit has reset, and *"Are you actually done with
  the work and this pause is intentional?"* to one that stopped for ten
  minutes partway through a `spec-roadmap` it was running. It leaves alone a
  session that is waiting on a prompt, ended on a question, was interrupted by
  you, still has its runner going, or has already answered that question.
  While it is off, the panel behind the switch shows what it *would* do and
  why, so you can check it against your own sessions first. `ccwatch revive`
  in a terminal does the same job without serve.
  The reasoning is in [docs/DESIGN.md](docs/DESIGN.md#unsticking-an-agent-that-stopped-too-early).
- **`kill` keeps the transcript.** It sends SIGTERM, never SIGKILL, and prints
  the `claude --resume` command for reopening the session. It refuses to stop a
  session that is mid-turn or running a pipeline phase unless you pass
  `--force`. The browser can't kill anything unless serve was started with
  `ccwatch serve --allow-kill`.

<details>
<summary>Every command</summary>

```bash
ccwatch                    # live table, refreshed until you quit (q / Ctrl-C)
ccwatch once               # draw it once — safe in a pipe or a status bar
ccwatch --json             # the same data, for scripting
ccwatch serve              # table + map in a browser (127.0.0.1 only)
    --open                 #   open it once it is up
    --port N               #   default 8787
    --read-only            #   the browser cannot send messages
    --allow-kill           #   the browser may stop sessions (off by default)
    --stop                 #   stop every serve this machine started
ccwatch bar                # one-line status for a menu bar (what the app reads)
    --title                #   just the title line, for tmux or a shell prompt
ccwatch ask [<who>]        # what each blocked session is asking
ccwatch convo [-n N] <who> # the recent conversation of one session
ccwatch resume [-n N]      # what to reopen after a crash or reboot
    --cd                   #   print pasteable `cd … && claude --resume …`
    --all                  #   ignore the 14-day window
ccwatch send <who> <msg>   # message a running session, and confirm arrival
    --dry-run              #   print the exact frames instead
ccwatch revive             # nudge sessions that stopped too early, every 60s
    --once                 #   one pass, then exit
    --dry-run              #   say what it would send, and send nothing
    --json                 #   one pass as JSON; sends only with --send
    --enable / --disable   #   the switch `ccwatch serve` runs it by
    --status
ccwatch kill <who>         # stop a session (--force to override a refusal)
ccwatch peers [--days N]   # which sessions have been messaging each other
ccwatch deploys            # CI/deploy runs in flight or finished in the last 24h
ccwatch subscribe <wf>     # (run by an agent) tell me when that deploy lands
ccwatch unsubscribe <wf>   # the reverse
ccwatch subs               # current subscriptions
ccwatch daemon             # deliver deploy notifications while you are away
ccwatch log [N]            # recent hook events (needs install-hooks)
ccwatch setup              # put ccwatch on PATH, once, from the checkout
ccwatch install-hooks      # record prompts between polls
ccwatch install-statusline # record rate limits and context fill
ccwatch doctor             # check that ccwatch's own view is trustworthy
ccwatch verify-ui          # render the pages in headless Chrome and check them
ccwatch --version
```

</details>

### Deploys (optional, needs `gh`)

If the GitHub CLI is installed and signed in, `ccwatch deploys` and the
dashboard show deploy-shaped workflow runs for every repo you have a session
in. An agent can run `ccwatch subscribe deploy-production` inside its own
session. `ccwatch daemon` then messages that session when the run finishes, so
the agent doesn't have to poll.

## Troubleshooting

**`ccwatch: command not found`.** `setup` printed an `export PATH=…` line. Add
it to `~/.zshrc`, then open a **new** terminal.

**`ccwatch needs 'jq' on PATH`.** Run `brew install jq`.

**The table is empty, or says `No live Claude Code sessions`, while sessions
are running.** Run `ccwatch doctor`. ccwatch reads Claude Code files that are
not a public interface, and `doctor` compares its own reading against
`claude agents --json`. If the two disagree, a Claude Code upgrade has probably
moved something, and that is a ccwatch bug to report.

**The menu bar shows `cc ?`.** ccwatch couldn't take a reading, so it shows
`?` instead of a number it can't vouch for. Open the menu to see the reason.
It usually means `ps` was refused, most often inside a sandbox.

**The menu bar shows `cc !` and `ccwatch not found`.** The checkout moved, or
`setup` was never run. Run `./bin/ccwatch setup`, then
`./app/build.sh --install`.

**Usage percentages are missing.** One of these applies:

- You haven't run `ccwatch install-statusline`.
- No *interactive* session has reported in the last 10 minutes. Headless
  sessions have no statusline, so they never report.
- Your sessions report different figures, and ccwatch hides a number it knows
  may be wrong. `ccwatch doctor` lists each session's reading. The usual cause
  is sessions signed in to different accounts.

**`ccwatch serve` says `could not bind 127.0.0.1:8787 — … Address already in
use`.** Another serve is already running. Open `http://127.0.0.1:8787` directly, or run
`ccwatch serve --stop`. The menu bar app uses a serve that is already running
and doesn't start a second one.

**The dashboard stopped updating after I left it alone.** A serve that nobody
reads for 30 minutes exits, so forgotten servers don't pile up. An open tab or
the menu bar app keeps it alive. `CCWATCH_SERVE_IDLE_EXIT=0` turns this off.

## What it reads and writes

ccwatch **reads** these parts of `~/.claude`:

- the session registry
- the transcripts
- pipeline state files
- the statusline payload, if you installed the wrapper

`convo` and `ask` read only the end of a transcript. They truncate the text and
reduce tool results to a size, never showing their content. The dashboard
listens only on `127.0.0.1`. Sending from it needs both a per-run token and a
same-origin check.

It **writes** only these:

- its own state and caches, in `~/.claude/ccwatch/`
- a CPU-sample cache, in `$TMPDIR`
- `~/.claude/settings.json`, but only when you run `install-hooks` or
  `install-statusline` and confirm the change

[SECURITY.md](SECURITY.md) has the full list.

## Requirements

| | |
|---|---|
| macOS | `stat -f` and `ps -o lstart=` are used in their BSD forms |
| `bash` 3.2+ | the version macOS ships |
| `jq` | `brew install jq`, the only dependency macOS doesn't include |
| `python3` | from the Xcode Command Line Tools. Used for the dashboard, `send` and date parsing |
| `git` | optional. Groups sessions by repository instead of folder name |
| `gh` | optional. The deploy panel; without it the panel says it is absent |
| Xcode CLT | only to build the menu bar app. The CLI and the dashboard need no compiler |

No minimum Claude Code version is pinned. `ccwatch doctor` is how you find out
that an upgrade has broken something.

<details>
<summary>Configuration (environment variables, all optional)</summary>

| Variable | Default | |
|---|---|---|
| `CCWATCH_BUSY_STALE` | `600` | seconds of transcript silence before `busy` is suspect |
| `CCWATCH_SDK_STALE` | `900` | the same for headless `claude -p` sessions |
| `CCWATCH_CPU_MIN_GAP` | `1.5` | minimum seconds between CPU samples for a delta to count |
| `CCWATCH_CTX_STALE` | `120` | how old a context reading may be before it is dropped |
| `CCWATCH_USAGE_STALE` | `600` | how old a usage reading may be before its numbers are withheld |
| `CCWATCH_USAGE_AGREE_WINDOW` | `120` | how close together two usage readings must be before disagreeing about the same window means anything, rather than being drift as usage accrues |
| `CCWATCH_USAGE_TOLERANCE` | `5` | how many percentage points two readings taken that close may differ by before the figure is withheld and the range reported |
| `CCWATCH_REPO_TTL` | `21600` | how long a directory's resolved repo is cached |
| `CCWATCH_TAIL_BYTES` | `400000` | how much of a transcript `convo` reads |
| `CCWATCH_SWAP_WARN` | `80` | swap percentage at which the host is called out |
| `CCWATCH_KILL_GRACE` | `8` | seconds to wait for a killed session to exit |
| `CCWATCH_TAIL_TEXT` | `1200` | how much of one turn's text `convo` keeps |
| `CCWATCH_ASK_BYTES` | `600000` | cap on the seek back to the last question |
| `CCWATCH_DEPLOY_LIMIT` | `20` | runs requested per repo from `gh` |
| `CCWATCH_REFRESH` | `2` | seconds between repaints |
| `CCWATCH_RESUME_DAYS` | `14` | how far back `ccwatch resume` looks |
| `CCWATCH_UNFINISHED_HOURS` | `24` | how recent an unfinished run must be to appear in the live table |
| `CCWATCH_SEND_VERIFY` | `10` | seconds to wait for a sent message to appear in the receiver |
| `CCWATCH_SEND_AS` | `ccwatch` | how sent messages identify themselves |
| `CCWATCH_REVIVE_AFTER` | `600` | seconds a session that paused mid-roadmap is left before `revive` asks |
| `CCWATCH_REVIVE_RETRY_AFTER` | `60` | seconds after an API error before the first `retry`; doubles each time |
| `CCWATCH_REVIVE_MAX_RETRIES` | `6` | retries before `revive` gives up on a session |
| `CCWATCH_REVIVE_MAX_ASKS` | `3` | how many times one stretch of work may be asked whether it is done |
| `CCWATCH_REVIVE_RESUMED` | `10` | tool calls after an ask that count as the work resuming; fewer means it answered, and is not asked again until you write |
| `CCWATCH_REVIVE_LIMIT_GRACE` | `120` | seconds past a session limit's reset before `continue` is sent |
| `CCWATCH_REVIVE_INTERVAL` | `60` | seconds between `revive` passes |
| `CCWATCH_REVIVE_ASK` | *Are you actually done…* | the question `revive` asks; also how it recognises its own earlier asks |
| `CCWATCH_REVIVE_NET` | `api.anthropic.com:443` | what "the API is reachable again" is tested against |
| `CCWATCH_DEPLOY_PATTERN` | `deploy\|release\|rollback\|publish\|promote` | which workflows count as deploys |
| `CCWATCH_DEPLOY_TTL` | `60` | seconds to cache `gh` results |
| `CCWATCH_PORT` | `8787` | port for `ccwatch serve`, and the one `ccwatch bar` probes to decide whether to link to a dashboard or offer to start one |
| `CCWATCH_IDLE_GRACE` | `15` | seconds `/api/state` may go unread before `ccwatch serve` stops collecting |
| `CCWATCH_SERVE_IDLE_EXIT` | `1800` | seconds `/api/state` may go unread before `ccwatch serve` exits. `0` disables it |
| `CCWATCH_SNAPSHOT_TIMEOUT` | `90` | seconds the snapshot collector may run before it is reported as a failed collection |
| `CCWATCH_TRANSCRIPT_TIMEOUT` | `30` | seconds a transcript read may take before the panel is told it was given up on |
| `CCWATCH_SNAPSHOT_CADENCE` | `2` | seconds between snapshot collections while the feed is being read |
| `CCWATCH_CHROME` | | path to a Chrome/Chromium binary for `ccwatch verify-ui` |
| `CCWATCH_HOME` | `~/.claude/ccwatch` | where the event log and usage feed live |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | which Claude Code config directory to read |
| `CCWATCH_PROFILE` | | print per-stage timings to stderr |
| `NO_COLOR` | | disable colour |

</details>

## Upgrade and uninstall

**Upgrade:**

```bash
cd ~/code/ccwatch && git pull
./app/build.sh --install          # only if you use the menu bar app
```

**Uninstall.** If you use the menu bar app, first untick **Open at Login** in
its menu and choose **Quit ccwatch**. Otherwise the login item outlives the app
it points at. Then:

```bash
ccwatch serve --stop                  # any serve still running
rm "$(command -v ccwatch)"            # the PATH symlink, wherever setup put it
rm -rf ~/.claude/ccwatch              # runtime state
rm -rf /Applications/ccwatch.app      # the app, if you installed it
```

If you installed hooks or the statusline wrapper, they are entries in
`~/.claude/settings.json`: remove the ones that name `ccwatch`. Each install
left a backup beside it, named `settings.json.ccwatch-backup.<timestamp>`. The
checkout itself is yours to delete.

## How it works, and why

[docs/DESIGN.md](docs/DESIGN.md) explains the reasoning behind every verdict:
why `busy` is never trusted on its own, why a stale reading is hidden rather
than labelled, and what the map is drawn from. It also records the bugs that
shaped each rule. Read it before changing anything.

## Contributing

Patches are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Every assertion
in the suite has been mutation-checked, and new ones are expected to be too.
[CLAUDE.md](CLAUDE.md) sets out the rules that must not be broken. Report
security issues through [SECURITY.md](SECURITY.md), not in a public issue.

```bash
./tests/run.sh    # shellcheck, then the whole assertion suite
```

## Licence

MIT. See [LICENSE](LICENSE).
