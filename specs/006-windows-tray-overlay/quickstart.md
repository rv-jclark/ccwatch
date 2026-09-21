# Quickstart — validating Windows support for the tray and the overlay

How to prove this feature works, story by story. Every scenario names the
command, what to look for, and what a *wrong* answer looks like — because most
of the failures here are silent, and "it printed something" is not a pass.

Prerequisites, shapes and probe behaviour are in
[contracts/probe-layer.md](./contracts/probe-layer.md),
[contracts/bar-document.md](./contracts/bar-document.md) and
[contracts/tray-app.md](./contracts/tray-app.md).

---

## 0. Prerequisites

**On macOS** (the refactor gate, US4 — needs nothing new):

```bash
./tests/run.sh                    # shellcheck, then the assertions
./bin/ccwatch doctor              # now includes the platform/probe block
./bin/ccwatch once                # one paint against the real ~/.claude
CCWATCH_PROFILE=1 ./bin/ccwatch --json >/dev/null   # per-stage timings
```

**On Windows** (Git for Windows bash, **not** WSL — see research D1):

```bash
uname -s                          # expect MINGW64_NT-… or MSYS_NT-…
jq --version                      # required
python3 --version || python --version || py -3 --version   # one must answer
cygpath -w "$HOME"                # required for the path seam
powershell -NoProfile -Command '$PSVersionTable.PSVersion'
```

For the tray app: the .NET 8 SDK, and the WebView2 runtime (default on
Windows 11; `build.ps1` names the installer when it is missing).

---

## 1. US1 — the read path tells the truth or says what it could not measure

### 1a. The fleet is reported, and the count is right

```bash
./bin/ccwatch once
./bin/ccwatch --json | jq '.sessions | length'
ls ~/.claude/sessions/*.json | wc -l
```

**Pass**: every live session appears with its status word, its age and the
measurement beside the verdict, and the count matches the number of registry
files whose process is running.

**The failure to watch for**: `No live Claude Code sessions` on a machine that
is plainly running several. That is the measured failure this whole feature is
shaped around — `ps` refused, 18 sessions live, 0 reported — and it is *calm*.
Nothing about the output looks wrong.

### 1b. Each probe, made unavailable in turn, is a named failure

Do these one at a time, from a shell where the shim comes first on `PATH`:

```bash
mkdir -p /tmp/brk
printf '#!/bin/sh\nexit 1\n' > /tmp/brk/stat && chmod +x /tmp/brk/stat
PATH=/tmp/brk:$PATH ./bin/ccwatch once        # transcript mtimes unavailable
PATH=/tmp/brk:$PATH ./bin/ccwatch doctor      # names it, with the reason
```

Repeat with a failing `powershell` (host + clock on Windows), a failing
`cygpath` (the path seam), and an empty `CCWATCH_PY`.

**Pass**: for each one, the affected reading is presented as a *named failure
with a reason* and `doctor` reports it as a problem. Nothing is presented as an
empty result, and nothing is presented as `0`.

**Fail**: a reading that becomes `0`, or a panel that simply disappears. Both
are failures wearing an absence's clothes (SC-002).

### 1c. The unsupported-platform path

```bash
CCWATCH_PLATFORM=unsupported ./bin/ccwatch doctor
```

**Pass**: every probe reports `failed` with "no implementation for this
platform", `doctor` exits non-zero, and nothing is invented.

### 1d. The load average, which does not exist on Windows

```bash
./bin/ccwatch --json | jq '.host'
```

**Pass** on Windows: `ram_free_mb` is a number; `load1` is `null` with an entry
in `unavailable` naming the reason; the pagefile figures are numbers, or `null`
together when the host has no pagefile.

**Fail**: `"load1": 0`, or a pagefile percentage on a host with no pagefile.
`0%` claims a pagefile exists and is empty.

### 1e. The corroborating signal still corroborates

```bash
./bin/ccwatch once ; sleep 5 ; ./bin/ccwatch once
```

**Pass**: a `HUNG?` verdict still shows both the silence and the CPU reading. No
verdict is escalated because the second signal was unavailable — where the CPU
figure could not be read, the row says so and is not escalated (principle I,
principle VI).

### 1f. Paths, spaces and separators

On Windows, with a session whose cwd is `C:\Users\<name with a space>\code\proj`:

```bash
./bin/ccwatch --json | jq -r '.sessions[] | "\(.project)  \(.cwd)"'
```

**Pass**: `project` is `proj` — the last path segment — and `cwd` uses forward
slashes.

**Fail**: `project` reading `C:\Users\Jane Doe\code\proj`. That is the
`split("/") | last` defect research D17 records, and it makes the column
unreadable at the width it has.

---

## 2. US2 — the tray shows the worst verdict without a terminal open

### 2a. Build and run

```powershell
./app-win/build.ps1 -SelfTest    # the properties that fail invisibly
./app-win/build.ps1 -Run
```

**Pass**: the selftest prints `selftest: all checks passed`, exits 0, and its
output contains the claims listed in
[contracts/tray-app.md](./contracts/tray-app.md) — including the z-order, focus
and virtual-desktop claims *by name*.

### 2b. The tray and the terminal agree, character for character

```bash
./bin/ccwatch bar --no-actions > /tmp/bar.txt ; cat /tmp/bar.txt
```

Compare the tray's title and every status row against that file at the same
moment, with a mixture of idle, working and blocked sessions present.

**Pass**: identical, including the measurement on each row (SC-003).

**Fail**: any difference at all. Two renderings that compute status separately
will eventually disagree and there is no way to tell which is lying — a
difference here means one of them is computing rather than rendering.

### 2c. A failed snapshot is a question mark, not a zero

```bash
CCWATCH_PLATFORM=unsupported ./bin/ccwatch bar --no-actions
```

Point the app at a CLI that cannot produce a snapshot (the same override in its
environment, or a temporarily unreadable registry).

**Pass**: the title is `cc ?` and the menu states that the snapshot itself
failed and that this is not "nothing is running".

**Fail**: `cc 0`.

### 2d. The parser's two security properties

Create a session whose name contains a pipe, refresh, and read the menu.

**Pass**: the name renders as text with `¦` where the pipe was, and no menu row
became a command. The selftest asserts both against a fixed input; this is the
same claim against a real session.

### 2e. Words alone

Read the menu with a high-contrast Windows theme, and again through a screen
reader.

**Pass**: every verdict present in the visual reading is present in the textual
one (SC-005). No severity is carried by colour or icon alone.

### 2f. The CLI it could not find

Rename the checkout, restart the app.

**Pass**: the title is `cc !`, and the menu says what it looked for and where —
not an empty fleet. Restore the name; the app finds it again after a rebuild
(the build-time path is the candidate that normally wins).

### 2g. The WSL trap

On a machine with WSL installed, confirm the menu's resolved bash path is the
Git/MSYS one and not `C:\Windows\System32\bash.exe`.

**Pass**: the Git/MSYS path, and `uname -s` through it reports `MINGW*`/`MSYS*`.

**Fail**: `System32\bash.exe` — which produces a confidently empty fleet, since
a WSL shell cannot see Windows process ids.

---

## 3. US3 — the overlay over a maximised window

All four of these are **manual**, and deliberately so: a selftest can assert the
style bits, and it cannot assert that the window was visible.

| Do | Pass | The silent failure |
|---|---|---|
| Open the overlay, maximise another application over it | the overlay stays visible | a wrong z-order looks perfect until something covers it |
| Switch to another virtual desktop | the overlay is visible there too | it appears to have vanished |
| Type in a terminal, click the overlay, keep typing | the caret stays in the terminal and the keystrokes land there | focus theft is only discovered by the keystroke that went astray |
| Click a link in the overlay that opens a new window | the default browser opens it | the click is swallowed in silence — the worst outcome |

Then the two server cases:

```bash
./bin/ccwatch serve --port 8787    # in a terminal, before opening the overlay
```

**Pass**: the app *adopts* it and the menu labels it "not started by this app".
It does not start a second one and does not fight for the port.

With no server at all, open the overlay.

**Pass**: it says no server is answering. It does not present an empty map.

Known limitation to verify is *stated*, not absent: an exclusive-fullscreen
Direct3D application can cover the overlay. The README says so; nothing in the
app claims otherwise.

---

## 4. US4 — nothing changes for the macOS operator

The gate on shipping any of the above.

```bash
git stash list                                    # know what is yours first
./bin/ccwatch --json > /tmp/before.json           # BEFORE the extraction
# ... after the extraction ...
./bin/ccwatch --json > /tmp/after.json
diff <(jq -S 'del(.at, .sessions[].age, .sessions[].cpu)' /tmp/before.json) \
     <(jq -S 'del(.at, .sessions[].age, .sessions[].cpu)' /tmp/after.json)
```

**Pass**: empty diff — the payload shape and every non-time-varying value are
identical (SC-007).

```bash
./tests/run.sh 2>&1 | tail -20
./app/build.sh --selftest
./bin/ccwatch bar | head -5
```

**Pass**: green; the tally is at or above the floor; the skip list contains no
new skip that hides a Windows-only path; the macOS app's selftest still passes;
`bar`'s bytes are unchanged.

**Pass** on a macOS machine with no Windows toolchain: the `app-win` checks skip
**with the reason**, exactly as the macOS app's checks already do.

```bash
CCWATCH_FAKE_PS=tests/fixtures/ps-sample ./bin/ccwatch --json | jq '.sessions | length'
```

**Pass**: unchanged. `CCWATCH_FAKE_PS` is still the one liveness seam, on either
platform, and the existing fixtures work untouched.

---

## 5. Selection and outcomes, from either platform

These run anywhere and are what makes probe selection assertable without two
machines (research D2):

```bash
CCWATCH_PLATFORM=windows ./bin/ccwatch doctor | sed -n '/^platform/,/^$/p'
CCWATCH_PLATFORM=macos   ./bin/ccwatch doctor | sed -n '/^platform/,/^$/p'
```

**Pass**: the block names the platform, the interpreter, and the implementation
selected for each of the six probes, with an outcome for each — including the
healthy ones. The question it answers is "which probes produced this view", and
a report listing only problems cannot answer it.

---

## 6. Mutation-checking, which is not optional

Every new assertion must have been **seen to fail** against the specific break
it describes (FR-030, SC-008). An assertion that has never failed has not been
tested, it has only been run. The procedure, per assertion:

1. Break the implementation in exactly the way the assertion describes.
2. Run the suite. **Confirm the assertion goes red.**
3. Restore.
4. Add a row to the mutation table in `README.md`.

The breaks worth doing here, because each one is a real mistake somebody could
make:

| Break | The assertion that must go red |
|---|---|
| make the Windows `proc` control query use `$$` instead of `/proc/self/winpid` | the "says nothing rather than reporting an empty machine" assertion |
| fold `ERROR_ACCESS_DENIED` into "not running" | the denied-pid count in `doctor`'s probe report |
| report `load1: 0` instead of `null` | the unavailable-versus-zero assertion |
| report a pagefile percentage with no pagefile | the same, for the pagefile fields |
| drop the clock validation and trust candidate 1 | the DST-boundary agreement with `web/usage.js` |
| split the bar line on the last ` | ` | the injection-document claims in both selftests |
| drop a line carrying an unknown parameter | the unknown-parameter claim |
| remove `WS_EX_NOACTIVATE` | the focus claim in the Windows selftest |
| remove the `System32\bash.exe` exclusion | the WSL-trap claim |
| remove the CRLF strip | the unrecognised-status assertion |
| skip the `cwd` forward-slash normalisation | the project-column assertion |

And raise `TALLY_FLOOR` by the number of new assertions that *always* run —
not the ones behind a built app, a Windows host or an optional tool. A floor
counting those writes one machine's configuration into the suite, which is the
thing a floor must not do.

---

## 7. The CI record

```
.github/workflows/ci.yml   macos-latest (unchanged, owns lint)
                           windows-latest (new)
```

**Pass**: both jobs print which platform they tested and which implementation
each probe selected, and the suite's skip list is read rather than assumed. A
probe that was never exercised is visible in that report (SC-011) — because a
skip is quiet by design, and a job that skipped every Windows probe looks
exactly like one that exercised them.

Also assert, as CI already does for macOS: nothing was left listening when the
suite exited.
