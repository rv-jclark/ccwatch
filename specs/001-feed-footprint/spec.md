# Feature Specification: Feed — idle-aware refresh, visibility-paused polling, conditional responses

**Feature Branch**: `001-feed-footprint`

**Created**: 2026-09-07

**Status**: Draft

**Input**: Roadmap `city-map`, entry `feed-footprint` — "Reduce the standing cost of `ccwatch serve` so the interactive map that follows is built on a feed that does not bill for itself when nobody is watching."

## Overview

`ccwatch serve` collects a fresh snapshot every 2 seconds for as long as it is
running, whether or not a page is open. Measured on 2026-09-07 on a host with 18
live sessions, one snapshot takes ~2.1s warm and ~24s on a cold cache under
load, so the server holds roughly a **50% duty cycle of one core indefinitely**
— the dominant resource cost of the tool, and a cost paid entirely for nobody's
benefit when no browser is looking.

This feature makes the cost follow the attention: collection stops when nothing
is reading, resumes on demand, and an unchanged snapshot costs a watching page
nothing to re-check. It also fixes the server-side half of the reported "agents
vanish with no explanation" bug: a snapshot that timed out is currently
indistinguishable in the payload from a host that genuinely has no sessions.

It deliberately changes nothing about what is collected, nothing about any
status or verdict, and nothing about how either page looks.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Leaving the dashboard running costs nothing when nobody is looking (Priority: P1)

An engineer starts `ccwatch serve` in the morning and leaves it running all day.
For most of that day no browser tab is open on it, or the tab is buried behind
twelve others. Today that costs them half a core continuously. They want the
server to be free to leave running, so that reaching for the dashboard is never
a decision about machine load.

**Why this priority**: This is the entire point of the entry, it is the largest
single resource cost in the tool, and it is what makes the map entries that
follow affordable. It delivers value on its own with no other part of the
roadmap built.

**Independent Test**: Start the server, open no page, and observe that no
collection runs after the grace period elapses. Then request the state feed once
and observe that collection resumes. Both are observable from the outside
without any change to the pages.

**Acceptance Scenarios**:

1. **Given** the server is running and no client has read the state feed for
   longer than the idle grace period, **When** time passes, **Then** no
   snapshot, deploy or peer collection is started, and the server consumes no
   measurable processor time.
2. **Given** the feed has gone idle, **When** a client reads the state feed,
   **Then** collection resumes for all three collectors on their own cadences
   without the client's request being made to wait for a collection to finish.
3. **Given** a page is open and polling normally, **When** collection is
   running, **Then** the refresh cadence and the freshness of each panel are the
   same as before this change — going idle must not make an attended dashboard
   slower.
4. **Given** a page is open, **When** the person switches to another tab or
   window so the page is hidden, **Then** the page stops requesting the state
   feed, and after the grace period the server stops collecting.
5. **Given** a hidden page, **When** the person returns to it, **Then** the page
   requests fresh state immediately rather than waiting for its next scheduled
   poll, so what they see on return is not the picture from before they left.

---

### User Story 2 - The dashboard never presents a resumed or cached reading as current (Priority: P2)

The one thing this tool sells is that a reading on screen is true now. Pausing
collection introduces two new ways to lie: a snapshot collected before an idle
period could be presented as current, and a page holding a cached copy of an
unchanged payload could present it as freshly measured. Neither may happen.

**Why this priority**: Without this, User Story 1 is a regression disguised as
an optimisation — it trades processor time for exactly the class of wrong output
this tool exists to prevent (Constitution III). It is P2 only because it is
meaningless without P1 in place.

**Independent Test**: Read the feed immediately after an idle period and confirm
the response states either that it is warming or the true measured age of the
snapshot it is carrying. Separately, re-read the feed with the validator of a
payload already held and confirm the response is a not-modified response, then
confirm the page still displays a correct age for that panel.

**Acceptance Scenarios**:

1. **Given** the feed has been idle and the last snapshot is minutes old,
   **When** the first client request after that idle period is answered,
   **Then** the response either states that the feed is warming or states the
   true measured age of every panel it carries; it never reports an age
   computed from anything other than the moment that data was collected.
2. **Given** a client holds the current snapshot, **When** it re-reads the feed
   offering the validator it holds, **Then** the response is a not-modified
   response with no body, and the client does no parsing and no redrawing.
3. **Given** a client holds a snapshot and the collectors then produce new data,
   **When** the client re-reads the feed with its validator, **Then** it
   receives the full new payload.
4. **Given** a client has just been told its copy is unchanged, **When** the
   page states the freshness of each panel, **Then** the stated age is the true
   age of the collected data at that moment — not the age at the time the body
   was last received, and not implied to be zero.
5. **Given** the state feed is read repeatedly while no new data has been
   collected, **When** the validator is compared, **Then** it is unchanged —
   values that move on every read for reasons other than new data must not enter
   the validator, or no read would ever be answered as unchanged.

---

### User Story 3 - A slow snapshot never reads as a host with no sessions (Priority: P3)

On a loaded machine the cold collection path has been measured at 24 seconds
against a 40 second ceiling. When that ceiling is crossed, the feed currently
publishes an empty session list, and the map draws "No live sessions" — the
reported bug in which agents vanish with no explanation. A person seeing that
concludes their sessions have exited.

**Why this priority**: It is a real reported bug and a direct Constitution IV
violation, but the user-visible half of the fix (drawing the distinction) is
owned by the next roadmap entry, so this entry can only carry the fact in the
payload. Independently valuable, independently testable, lowest immediate
visibility.

**Independent Test**: Force the snapshot collection to exceed its ceiling in a
fabricated environment and inspect the feed's payload: it must be distinguishable
from the payload produced by a fabricated environment that genuinely contains no
sessions.

**Acceptance Scenarios**:

1. **Given** a snapshot collection exceeds its time ceiling, **When** the feed
   is read, **Then** the payload states that the snapshot failed and why, and is
   distinguishable from a payload describing a host that has no live sessions.
2. **Given** a snapshot collection fails or times out and an earlier snapshot
   succeeded, **When** the feed is read, **Then** the earlier snapshot's data is
   still carried with its true age, alongside the statement of the failure —
   a failure does not replace known data with emptiness.
3. **Given** a snapshot collection fails or times out and no snapshot has ever
   succeeded, **When** the feed is read, **Then** the payload does not assert an
   empty set of sessions as a fact; it states that the snapshot has not
   succeeded and why.
4. **Given** a host that genuinely has no live sessions, **When** the feed is
   read, **Then** the payload asserts an empty set of sessions with no failure
   stated, and the pages continue to show today's "No live sessions" message.
5. **Given** the cold collection path measured at 24 seconds, **When** the
   ceiling is applied, **Then** the ceiling leaves a margin large enough that
   the measured cold path does not cross it, and it can be raised by
   configuration on a slower host.

---

### Edge Cases

- **Two clients, one hidden.** One tab is visible and polling while another is
  hidden. The feed must stay active for as long as *any* client is reading; one
  hidden tab must not idle the feed out from under a visible one.
- **A client reads once and disappears.** A `curl` against the feed, or a page
  closed without warning, must leave the feed active for the grace period and
  then idle — no client can pin collection on forever by having existed once.
- **A request arrives mid-collection.** A read that lands while a collector is
  already running must be answered immediately from the last published data,
  never made to wait for the collection in flight.
- **A read arrives during the very first warm-up.** The feed must report that it
  is warming, as it does today, rather than asserting an empty result.
- **The three collectors idle and resume independently.** A stalled or slow
  collector may only make its own panel stale; idling must not couple them, and
  resuming must not gate the fast collector on the slow one.
- **Deploy and peer collectors have long cadences.** With a 60s and a 45s
  cadence against a short grace period, a resumed collector may be due
  immediately; it must not skip its wake-up and leave its panel minutes stale
  while a page watches.
- **A stale validator is offered.** A validator from a payload several
  generations old must produce a full response, not a not-modified response.
- **A validator is offered for a payload that reports a failure.** The
  distinction between failed and empty must survive the not-modified path — a
  client must never hold a "no sessions" body while the feed knows the snapshot
  is failing.
- **The page is hidden at the moment it loads.** A page opened in a background
  tab must not poll until it becomes visible, and must fetch on becoming
  visible.
- **A person watching an agent's conversation switches away.** Periodic
  transcript re-reads for an open conversation must pause with the page and
  resume on return.
- **Reduced motion.** The status-carrying motion that remains must stay
  suppressed under a reduced-motion preference, as it is today.
- **A slow test machine.** An assertion that depends on wall-clock timing must
  state a skip reason rather than fail when the host cannot supply the timing it
  needs.

## Requirements *(mandatory)*

### Functional Requirements

**Idle-aware collection**

- **FR-001**: The server MUST stop starting new collections for all three
  collectors — sessions snapshot, deploys, peers — once no client has read the
  state feed for longer than a defined idle grace period.
- **FR-002**: The server MUST resume collection on the next read of the state
  feed, and each collector MUST resume on its own existing cadence,
  independently of the others.
- **FR-003**: A read of the state feed MUST be answered from already-published
  data without waiting for any collection, whether the feed is active, idle or
  resuming.
- **FR-004**: A collection already in flight when the feed goes idle MUST be
  allowed to finish and publish; idling stops the *next* collection, it does not
  abandon work already done.
- **FR-005**: The idle grace period MUST be long enough that a page polling on
  its normal cadence never idles the feed, and MUST be overridable by
  configuration in the same manner as the tool's other tunables.
- **FR-006**: Reads of endpoints other than the state feed MUST NOT be required
  to keep the feed active; the state feed is the signal of attention.

**Truthful freshness**

- **FR-007**: The state payload MUST carry the true age of each panel's data,
  measured from when that data was collected, at all times — including the first
  read after an idle period.
- **FR-008**: The state payload MUST state whether the feed has never yet
  produced a snapshot (warming), so a page can say so rather than draw an empty
  result, as it does today.
- **FR-009**: The feature MUST NOT remove, weaken or annotate around any
  existing staleness withholding: readings dropped today for being past their
  staleness window MUST still be dropped.

**Conditional responses**

- **FR-010**: The state feed MUST carry a strong validator for the payload it
  returns.
- **FR-011**: The state feed MUST answer a read that offers a validator matching
  the current payload with a not-modified response carrying no body.
- **FR-012**: The validator MUST change when and only when the collected content
  changes; per-request values that move on every read MUST NOT contribute to it,
  or no read could ever be answered as unchanged.
- **FR-013**: After a not-modified response, the true age of each panel MUST
  still be derivable by the page, so a not-modified response can never cause a
  cached reading to be presented as freshly measured.
- **FR-014**: The response's caching directives MUST permit the client to store
  the payload for revalidation while forbidding its use without revalidating.
- **FR-015**: Both pages MUST request the state feed in a way that participates
  in revalidation rather than one that forbids storage outright.

**Client pauses when unattended**

- **FR-016**: Both the table view and the map view MUST stop all periodic
  requesting while the page is hidden, and MUST resume when it becomes visible.
- **FR-017**: On becoming visible, both pages MUST request state once
  immediately, before resuming their normal cadence.
- **FR-018**: The pause MUST cover every periodic request a page makes,
  including periodic re-reads of an open conversation.
- **FR-019**: A page that loads while hidden MUST NOT begin polling until it
  becomes visible.

**No animation loop**

- **FR-020**: Neither page may contain an animation-frame loop or a repainting
  timer; all rendering MUST be driven by an event — new data, an input, hover or
  focus.
- **FR-021**: Declarative motion is permitted only on figures whose motion
  carries a status signal, MUST NOT be used decoratively, and MUST remain
  suppressed under a reduced-motion preference.
- **FR-022**: The test suite MUST guard FR-020 so a later entry cannot
  reintroduce a loop unnoticed.

**A failed snapshot is not an empty one**

- **FR-023**: The snapshot time ceiling MUST leave adequate margin over the
  measured 24s cold path, and MUST be overridable by configuration.
- **FR-024**: A snapshot that times out or otherwise fails MUST be represented
  in the payload distinguishably from a successful snapshot that found no
  sessions, and MUST state the reason for the failure.
- **FR-025**: A snapshot failure MUST leave the last successful snapshot in
  place, carried with its true age, rather than replacing it with an empty
  result.
- **FR-026**: Where no snapshot has ever succeeded, the payload MUST NOT assert
  an empty set of sessions as a fact.
- **FR-027**: The pages' current rendering MUST be preserved: a genuine absence
  of sessions still reads as it does today, and the table view still surfaces a
  stated failure as it does today. Rendering the failed/empty *distinction* is
  out of scope here and belongs to the next roadmap entry.

**Documented measurement**

- **FR-028**: The measured duty cycle MUST be recorded in the project's README
  before and after the change, for three conditions: a page open and visible, a
  page open but hidden, and no client at all. Concrete measured figures, not
  adjectives.
- **FR-029**: Any new configuration tunable MUST be documented alongside the
  existing ones, with its default and what it controls.

**Constraints carried from the project's standing rules**

- **FR-030**: No new dependency, no build step, no package manifest, and no new
  endpoint.
- **FR-031**: Shell code stays within bash 3.2 forms; embedded programs are
  passed as arguments, never on standard input; the linter stays clean at its
  current severity for both the tool and the test suite.
- **FR-032**: The write endpoints' per-run token and origin checks MUST NOT be
  weakened, and the destructive action's explicit opt-in MUST NOT be relaxed.
- **FR-033**: No collector's computation may change, and no status, severity or
  verdict may be added or altered.
- **FR-034**: Both pages MUST look and behave exactly as they do today apart
  from pausing while hidden.

**Tests**

- **FR-035**: Assertions MUST run hermetically against a fabricated
  configuration directory with the liveness probe substituted, and MUST NOT
  observe the developer's live sessions.
- **FR-036**: Idle gating, the not-modified behaviour, and the failed-versus-empty
  distinction MUST each have their own assertion.
- **FR-037**: Every new assertion MUST be mutation-checked — the implementation
  broken in the specific way the assertion describes, the assertion confirmed to
  fail, the implementation restored — and MUST add a row to the README's
  mutation table.
- **FR-038**: The suite's counted-assertion floor MUST be raised to cover the
  new assertions.
- **FR-039**: Any server a test starts MUST be reaped, so a leaked one cannot
  hold a port a later run picks.
- **FR-040**: An assertion that the host cannot supply the conditions for MUST
  skip with the reason stated rather than fail or flake.

### Key Entities

- **Snapshot**: the collected picture of every session on the host, with the
  moment it was collected, and — as this feature adds — whether the collection
  that produced it succeeded, and if not, why.
- **Panel data**: one collector's output (sessions, deploys, peers) with its own
  collection moment and its own age, so a slow collector can only make its own
  panel stale.
- **Feed state**: whether the feed has never collected (warming), is collecting,
  or has stopped for want of a reader — a fact about the feed, distinct from the
  data it carries.
- **Attention signal**: the moment of the most recent read of the state feed by
  any client, which is what keeps collection running.
- **Payload validator**: an identifier for the collected content of a payload,
  by which a client can ask whether what it holds is still current.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the server running and no client at all, sustained processor
  use attributable to the server is under 1% of one core, measured over at least
  60 seconds — down from roughly 50%.
- **SC-002**: With a page open in a hidden tab, sustained processor use is the
  same as with no client at all (under 1% of one core over 60 seconds).
- **SC-003**: With a page open and visible, the freshness of each panel and the
  interval at which the view updates are unchanged from before the change; the
  processor cost in this condition is stated as a measured figure rather than
  improved.
- **SC-004**: After an idle period, the first read of the state feed is answered
  in under 100ms, and full data resumes flowing within one collection cycle.
- **SC-005**: A read offering the validator of an unchanged payload transfers no
  body and causes no redraw; over a minute of polling with no change on the
  host, at least 90% of reads are answered as unchanged.
- **SC-006**: In 100% of cases where the state feed reports an age for a panel,
  that age equals the true elapsed time since that data was collected, within
  the resolution the page displays — including the first read after an idle
  period and every read answered as unchanged.
- **SC-007**: A snapshot that exceeded its ceiling and a host with genuinely no
  sessions produce payloads that can be told apart by inspection alone, with no
  reference to anything outside the payload.
- **SC-008**: The snapshot ceiling is at least 3× the measured 24s cold path,
  and is adjustable without editing the tool.
- **SC-009**: Returning to a hidden tab shows data collected after the return,
  not before the departure, within one collection cycle of becoming visible.
- **SC-010**: Neither page performs any work between updates: no timer or
  animation loop remains that runs when data has not changed and nobody has
  interacted, and the suite fails if one is introduced.
- **SC-011**: The full test suite passes with the linter clean, with at least
  three new mutation-checked assertions and a matching README mutation-table row
  for each.
- **SC-012**: Both pages are pixel-identical to their current rendering for the
  same payload, apart from having stopped polling while hidden.

## Assumptions

- **Idle grace period default of 15 seconds.** Both pages poll every 3 seconds,
  so 15 seconds is five missed polls — long enough that a busy browser or a
  briefly-stalled page never idles the feed, short enough that a closed tab
  stops costing anything almost immediately. Overridable, per FR-005.
- **The refresh cadence is unchanged.** The sessions collector keeps its 2s
  cadence, deploys 60s, peers 45s. Making collection cheaper *while attended* is
  a separate question and is not in this entry; leaving the cadence alone is
  also what keeps the "page open" measurement comparable before and after.
- **Attention is inferred from reads of the state feed only.** There is no
  client registration, no heartbeat and no new endpoint — a read is the signal,
  which is why FR-006 excludes the other endpoints (a page that is only fetching
  a transcript is not asking for fresh state).
- **The snapshot ceiling becomes 90 seconds by default** — 3.75× the measured
  24s cold path — and configurable for slower hosts. The previous 40s ceiling
  was a 1.7× margin, which the measurement shows is too thin.
- **The existing payload keys stay backward-compatible.** The failure fact is
  added alongside what the payload already carries, and the table view's
  existing display of a stated error keeps working unchanged, so this entry
  needs no rendering change to be truthful.
- **The pages' own request caching must change to match the server.** A request
  that forbids storage cannot revalidate, so the client side of FR-014 is part
  of this entry, not an afterthought.
- **No animation-frame loop exists today**, and the motion that does exist
  (working, blocked, suspect) is already status-carrying and already suppressed
  under reduced motion. FR-020–FR-022 therefore lock in and guard the current
  position rather than change it — which is the point, since the entries that
  follow add a renderer.
- **Duty cycle is measured on the development host** with a live session
  population, and the README records the population size alongside the figures,
  as the existing measurements in that file do.
- **A hidden tab is the browser's report.** If a browser does not report page
  visibility, the page continues polling as it does today; no supported browser
  on this platform fails to report it.

## Dependencies

- Depends on nothing else in the roadmap; it is the first entry.
- The rendering of the failed-versus-empty distinction this entry puts in the
  payload is delivered by the next entry (`map-stable-world`). Until then the
  fact is carried but only the table view's existing error line surfaces it.
- Requires a host able to create temporary directories and bind a loopback port
  for the server assertions; in a restricted sandbox those assertions fail for
  want of `mktemp`, which is the sandbox and not a regression.

## Out of Scope

- The map's drawing model, layout, camera, roster and modal — the four entries
  that follow.
- Any change to what a collector computes, or to any status, severity or verdict.
- Making an *attended* collection cheaper (caching between collectors, trimming
  what a snapshot gathers, lengthening the cadence).
- Any new endpoint, including a push or streaming feed.
- Any change to the write endpoints' authorisation.
