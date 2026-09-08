# Specification Quality Checklist: Map — identity-derived world layout, incremental rendering, four distinct failure states

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

Validated on 2026-09-08. Three items warranted a judgement rather than a plain
tick, recorded here so the next phase does not have to re-derive them:

- **"No implementation details" / "no leaks"** — the *requirements* name
  behaviour only (a world space, a camera group, a payload field), never a
  library, format or mechanism. The **Overview** does cite exact code locations
  (`web/map.html:740-744`, `bin/ccwatch:188`, …) and one verified measurement.
  That is deliberate and is retained: this project's constitution requires the
  failure that motivated a change to be named concretely, and every one of those
  citations is evidence for a defect claim rather than a design instruction.
  Two mechanism-shaped words survive in **Assumptions** — browser-local storage
  for plot assignments, and a top-level snapshot field for the unreadable-rows
  count — both flagged as assumptions, both revisable by the plan phase.

- **"Written for non-technical stakeholders"** — the stakeholder for this tool
  is an engineer running Claude Code sessions, so the vocabulary is theirs
  (repository, branch, session, snapshot). No section requires reading the
  source to follow.

- **"Requirements are testable"** — two originally soft requirements were
  tightened during validation: FR-040 now names a figure-height floor, visible
  separation and a viewport size instead of "plausible number of districts";
  SC-016 now enumerates the three defects the README must name.

Two decisions in the spec are judgement calls made rather than asked, both
documented in **Assumptions** because a reviewer could reasonably want them the
other way:

1. **Plot collisions resolve hash-then-probe with the stored assignment
   authoritative**, so the city can differ between two browsers that first saw
   the same projects in a different order. The alternative — a globally
   order-independent tie-break — would have to move an already-placed building,
   which FR-010 forbids.
2. **Stale-state withholding removes the numbers and keeps the poses.** FR-029
   enumerates exactly what is withheld, and is the single place to extend if a
   reviewer decides a stale pose is as misleading as a stale percentage.

One factual correction to the roadmap entry's own description is carried in the
Overview: the entry states that `PARSE_FAILED` "only reaches the terminal
footer". It reaches nothing — the increments are lost to a subshell, verified
against a fabricated registry with one malformed file. FR-034 therefore requires
the propagation to be fixed as well as the field added, since otherwise all four
consumers would agree on zero.
