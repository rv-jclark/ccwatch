---
name: Bug report
about: Something ccwatch reported wrongly, or would not run
labels: bug
---

## What ccwatch showed

Paste the output. If a row is wrong, the row and the `LAST` column beside it are
the useful part — that column holds the measurement behind the verdict.

```
```

## What was actually true

e.g. "the session had been finished for an hour", "that project is
`acme/checkout-api`, not `platform`".

## `ccwatch doctor`

The single most useful thing to include. Claude Code's internal file layout is
not a public interface, so an upgrade moving it is a routine cause of breakage
here, and `doctor` is built to detect exactly that.

```
$ ccwatch doctor

```

## Environment

- ccwatch version (`ccwatch --version`) or commit:
- Claude Code version:
- macOS version:
- Installed as a symlink, a copy, or run from the checkout:

## Reproducing it

If the suite is involved: does `./tests/run.sh` pass? Note that inside a
restricted sandbox around 13 assertions fail with empty output because
`mktemp -d` is denied — please re-run outside the sandbox before reporting that
as a failure.
