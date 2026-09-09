# Specification Quality Checklist: Map — per-agent modal with stats, conversation, chat, and a visible kill gate

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

Three items pass with a stated interpretation rather than silently, because
this project's constitution asks for the opposite of the generic guidance.
The same three were recorded against `specs/004-map-roster`.

- **"No implementation details" / "written for non-technical stakeholders."**
  The Overview cites `web/map.html` and `bin/ccwatch` line numbers and names
  `renderKill`, `rowFields`, `computeFeedCondition` and `VOLATILE`. That is
  deliberate and matches `specs/001`–`specs/004` in this repository and the
  constitution's own instruction that documentation "name the failure that
  motivated the code". The four endpoint names (`/api/state`,
  `/api/transcript`, `/api/send`, `/api/kill`) and the flag name
  `ccwatch serve --allow-kill` are not design choices this spec is making —
  they are fixed existing surfaces, and in the `--allow-kill` case the flag
  name is itself part of the user-visible requirement (FR-028). The
  **Functional Requirements are behavioural**: they state what must be true of
  the rendered page and of the messages a reader sees, not how to build it.

- **"Success criteria are technology-agnostic."** SC-010 and SC-011 assert that
  no build step, dependency, endpoint, additional periodic timer or animation
  loop is introduced, and that a hidden tab does no periodic work. Those are
  the footprint invariants `feed-footprint` established, which `tests/run.sh`
  already asserts by count, and they have direct user-visible consequences
  (idle CPU cost, and an open panel surviving a refresh). They are stated as
  criteria rather than dropped, and are phrased without naming browser APIs.

- **FR-050 is a testability requirement, not a design one.** It requires the
  modal's rendering decisions to be exercisable outside a browser because the
  constitution's hermetic-test and mutation-check rules cannot otherwise be
  satisfied for FR-028 (the disabled kill control), which FR-053 gives an
  assertion of its own. It names no module and no file; where that logic lives
  is the plan phase's decision.

Zero `[NEEDS CLARIFICATION]` markers were needed. The roadmap entry, the
constitution and the four already-fixed endpoints settled every scope
question. Six judgement calls were made and are recorded in **Assumptions**
rather than raised as questions:

1. The panel replaces `#reply` in place, carrying over its wording and
   reductions, rather than being rewritten — the cheapest reading of "keeps
   its current prominence" and "verbatim in meaning".
2. The stats delegate to the roster's existing shaping so the modal and the
   roster row cannot state different things for one snapshot.
3. "Follows only when already at the bottom" is partly new: the current page
   preserves scroll position but does not follow new turns. Both properties
   are specified.
4. Opening from a roster row is a distinct affordance from selecting it,
   because entry 004 gave row activation a different meaning and this entry is
   told not to change the roster.
5. Peer edges are matched by session name, as the map's wire drawing already
   does.
6. The vanished-session case reuses the roster's tombstone wording pattern
   rather than inventing a fifth sentence shape.

One point of honesty about scope, flagged for the plan phase rather than left
implicit: the roadmap entry says the conversation's "scroll behaviour that only
follows when already at the bottom" should be *kept*, and no such following
behaviour exists in `web/map.html` today (`web/map.html:1098-1100` records that
scroll position is simply never disturbed). FR-018 specifies both halves. This
is within the entry's own bullet 2 and needs no change outside the panel.
