## What this changes

## Why

If it fixes a bug, what did the wrong output look like? A sentence naming the
failure belongs in a comment next to the code as well, so it does not come back.

## Checklist

- [ ] `./tests/run.sh` passes (outside a restricted sandbox — `mktemp -d` is
      needed, and being denied it fails ~13 assertions with empty output)
- [ ] New assertions were **mutation-checked**: the implementation was broken in
      the specific way each assertion describes and the assertion was confirmed
      to fail
- [ ] A row was added to the mutation table in `docs/DESIGN.md`
- [ ] `shellcheck -x -S warning` is clean (the suite runs it)
- [ ] No bash 4 constructs — macOS ships bash 3.2, and the suite greps for them
- [ ] Any new output degrades honestly when its signal is unavailable: it says
      so rather than rendering an empty or stale panel
- [ ] Examples in documentation and fixtures are generic — no real session
      names, repository slugs, feature ids or costs
