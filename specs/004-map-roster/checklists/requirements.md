# Specification Quality Checklist: Map — docked agent roster, severity-sorted, keyboard navigable, camera fly-to

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-08
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

Two items warrant a stated interpretation rather than a silent pass, because
this project's constitution requires the opposite of the generic guidance:

- **"No implementation details" / "written for non-technical stakeholders."**
  The Overview cites `bin/ccwatch` and `web/map.html` line numbers, and names
  `CCWATCH_MAP_CAMERA`, `titleBits` and `renderTrust`. That is deliberate and
  matches `specs/001`–`specs/003` in this repository and the constitution's
  own instruction that documentation "name the failure that motivated the
  code" and prefer "the concrete number that was measured" over an adjective.
  The evidence belongs in the Overview; the **Functional Requirements
  themselves are behavioural** — they state what must be true of the rendered
  page, not how to build it. The one exception is the persistence medium
  (the browser's local storage), which is a constraint imposed by the roadmap
  entry and by the constitution's "no new file under `~/.claude/ccwatch/`",
  not a design choice this spec is making.

- **"Success criteria are technology-agnostic."** SC-011 asserts that no
  animation loop, no additional repainting timer and no additional wholesale
  markup replacement is introduced. Those are the footprint invariants
  `feed-footprint` established and that `tests/run.sh` already asserts by
  count; they are project constraints with user-visible consequences (idle CPU
  cost, and an open inspector surviving a refresh), so they are stated as
  criteria rather than dropped. They are phrased without naming the specific
  browser APIs.

Zero `[NEEDS CLARIFICATION]` markers were needed. The roadmap entry and the
constitution between them settled every scope question; the six judgement calls
that remained are recorded in **Assumptions**, the most consequential being:
the roster covers session rows and not building badges; the gone-selection
statement is a dismissible tombstone row pinned to the top of the list; the
panel stacks above the map below a narrow breakpoint rather than truncating;
and opening a session's conversation from a roster row is explicitly left to
`map-agent-modal`, with the pre-existing pointer-only gap named rather than
quietly counted as delivered.
