# Specification Quality Checklist: Windows support for the taskbar tray and the overlay

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-20
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`.

**On "no implementation details" and "non-technical stakeholders".** The product
here is a command-line tool and two desktop status surfaces, so the names of the
probe programs (`ps`, `stat`, `date`, `vm_stat`, `sysctl`), the command whose
bytes both GUIs render (`ccwatch bar --no-actions`), and the shell floor the
suite enforces are the *domain vocabulary*, not leaked implementation choices —
they are what a requirement about this tool has to be able to name to be
checkable. The existing specs in `specs/` are written the same way, down to
`file:line` citations. What the spec deliberately does **not** decide is left to
`/speckit-plan`: how the probe seam is shaped in the script, which Windows
facility each probe calls, and how the tray app is structured. The one
technology named outright is the Windows web-view runtime, and it appears only
in Assumptions as an install prerequisite, which is where a dependency belongs.

**Three defaults were taken rather than asked about**, each on a stated
argument, and each is the first thing `/speckit-plan` should confirm:

1. `bin/ccwatch` stays one bash script and runs under a Git-for-Windows /
   MSYS2-class bash, not WSL and not a Windows-native rewrite — WSL cannot see
   Windows process ids, which would cost the corroborating signal behind every
   verdict, and a rewrite would be a second place computing status.
2. Scope is the read path plus the two surfaces; `send`, `kill` and peer
   messaging stay out and are shown as unavailable with the reason.
3. A Windows CI job is added, rather than shipping Windows probes that no job
   exercises.

**One constitutional constraint is changed on purpose, not broken.** The
constitution's Additional Constraints say "This is a macOS tool; CI runs on
macOS only" (`.specify/memory/constitution.md:114-115`). FR-033 makes amending
`CLAUDE.md`, `README.md` and the constitution together part of the deliverable,
so the governing document and the shipped behaviour cannot end up contradicting
each other. No numbered principle is weakened: the feature leans on IV, V, VI,
VII, XI and XII rather than trading any of them away.
