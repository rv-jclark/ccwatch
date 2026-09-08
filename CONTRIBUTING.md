# Contributing

Bug reports and patches are welcome. The tool is one bash script with no build
step, so getting set up is a clone away.

```bash
git clone https://github.com/rv-jclark/ccwatch.git
cd ccwatch
brew install jq shellcheck    # jq is required, shellcheck for the lint step
./tests/run.sh
./bin/ccwatch doctor
```

## The one thing to know before opening a PR

**Every assertion in this repo has been mutation-checked**, and new ones are
expected to be. That means: break the implementation in the specific way your
assertion describes, run the suite, confirm your assertion *fails*, then restore
the code. An assertion that passes against a broken implementation is worse than
no assertion at all, because it gets counted as coverage. It has happened here
at least once, and the note in `README.md` about it is a warning, not a boast.

When you add an assertion, add a row to the mutation table at the bottom of
`README.md` naming the mutation and how many assertions caught it.

## What a good change looks like

- **It cannot fail quietly.** This tool exists because a dashboard that
  confidently shows nothing costs you an afternoon. A new signal needs a story
  for what happens when it is unavailable, and that story is "say so", never
  "render an empty panel". `CLAUDE.md` lists the invariants in full.
- **It measured rather than guessed.** `CCWATCH_PROFILE=1` prints per-stage
  timings. The first round of performance work here was guesswork and made
  things slower.
- **Its comment says why.** The `⚠️` comments name the failure that motivated
  the code. If you fix a bug, leave behind the sentence that stops it coming
  back.
- **It runs on stock macOS.** bash 3.2, BSD `stat`/`ps`, `jq`, `python3`. No
  bash 4 constructs — the suite greps for them. `shellcheck -x -S warning` must
  be clean.
- **It keeps documentation examples generic.** Please do not paste real session
  names, repository slugs, feature ids or costs from your own machine into the
  README or into fixtures.

## Commits

**[Conventional Commits](https://www.conventionalcommits.org), always** —
`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `perf:`, `chore:`, `ci:`,
`build:`, and `feat!:` or a `BREAKING CHANGE:` footer for a break. This is not
housekeeping: the log is the input to versioning, so a `feat:` that should have
been a `fix:` ships the wrong number, and your subject line becomes the
changelog entry a stranger reads. Write it in the imperative, about the change
someone using the tool would notice.

**Small, logically grouped commits.** One reason-to-change per commit, with
everything that belongs to that reason inside it — the implementation, its
assertion, and its row in the mutation table. Unrelated changes that happened in
the same sitting are still separate commits; an implementation without its
assertion is not a smaller commit, it is half of one. Large reformatting or
renames go on their own, so the behavioural change beside them stays readable.

Releases are automatic: merging the release PR that `release-please` maintains
bumps `CCWATCH_VERSION`, writes `CHANGELOG.md`, tags and publishes. Please do
not edit the version or the changelog by hand in a PR.

## Tests

```bash
./tests/run.sh
```

The markdown assertions run `web/md.js` under `node`, which is the one optional
tool here: without it that section skips with the reason, and the rest of the
suite is unaffected.

Everything runs against a fabricated `~/.claude`, because a suite that reads
your live sessions asserts on whatever happened to be open. If you are running
inside a restricted sandbox, expect around 13 failures with empty output — that
is `mktemp -d` being denied, not a real regression. Re-run outside the sandbox
before reporting it.

## Reporting a bug

`ccwatch doctor` output is the single most useful thing to include. Claude Code's
internal file layout is not a public interface, so "a Claude Code upgrade moved
something" is a routine cause of breakage here, and `doctor` is built to detect
exactly that. Please also include your Claude Code version and macOS version.

For anything with a security dimension, see [SECURITY.md](SECURITY.md) instead
of opening a public issue.
