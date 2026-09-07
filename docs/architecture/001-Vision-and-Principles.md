# 001 — Vision and Principles

| Field | Value |
|---|---|
| Spec ID | 001 |
| Status | Draft |
| Milestone | M0 — Foundation |
| Depends on | — |
| Consumed by | Every document in this set |
| Source | Design conversation (retrieved 2026-09-07) — https://chatgpt.com/share/6a9ed0df-2b14-83ea-a725-f8a5824bdb66 |

This document is the root of the specification set. It states what is being built and the
constraints every other document must satisfy. Nothing here describes *how* — that begins
at [003 Core Architecture](003-Core-Architecture-Specification.md).

---

## Vision

A persistent AI engineering platform running on a dedicated Linux machine at home, acting
as a standing lead engineer rather than a chat session.

The distinction matters. A chatbot answers questions from a cold start. This platform
holds continuous context on the owner's repositories, so that asking *"how is StoryThreads
going?"* from a phone returns current state — reviewed commits, flagged conflicts, a
prioritised queue — rather than a request for context.

It begins fully in the loop: it proposes, explains, and opens pull requests, and the owner
decides. It earns autonomy incrementally, through explicit and reversible gates, until it
can merge low-risk changes, watch production, and propose rollbacks on its own.

Structurally it is a team, not an assistant: role-scoped agents — PM, architect, developer,
QA, DevOps, security — coordinated by an orchestrator. The owner directs the team instead
of writing every line.

The end state is **a distribution, not a manual**. The documents describe the platform;
the repository *is* the platform. A rebuild two years from now is one bootstrap command,
not an archaeology exercise.

---

## Goals

**G1 — Persistent engineering context.** The platform holds standing context on the
owner's repositories so that questions like *"how is StoryThreads going?"* are answered
from current state, not from a cold start.

**G2 — Assistant first, autonomous later.** The system begins fully in-the-loop and earns
autonomy through explicit, reversible gates.

**G3 — Hardware-adaptive.** The platform detects the machine it is on, selects a
capability profile, and enables only components that machine can actually support.

**G4 — Diagnostic, not just prescriptive.** The platform explains *why* a configuration
was chosen, what the current hardware permits, and what specific upgrades would unlock —
with rationale, not just a shopping list.

**G5 — Reproducible from bare metal.** A fresh Ubuntu install reaches a working platform
via one bootstrap command plus validations.

**G6 — A distribution, not a manual.** The documents describe the platform; the repository
*is* the platform. Specs and implementation evolve together and never drift.

---

## Guiding Principles

Every architectural decision in this platform must satisfy all seven. A decision that
violates one is recorded in that chapter's decision log with an explicit justification.

| # | Principle | Meaning in practice |
|---|---|---|
| P1 | **Reproducible** | Any state the platform reaches can be re-reached from the repo alone. No undocumented manual steps. |
| P2 | **Modular** | Components are replaceable in isolation. Removing one degrades scope, never correctness. |
| P3 | **Observable** | Every agent action emits a trace. Nothing happens that cannot be reconstructed afterward. |
| P4 | **Secure by default** | Least privilege at rest. Secrets never in the repo. Network surface closed unless opened deliberately. |
| P5 | **Adaptive** | Behavior derives from detected hardware and declared manifest, not from hardcoded assumptions. |
| P6 | **Vendor-neutral** | No single model provider or agent CLI is load-bearing. Swapping one is a config change. |
| P7 | **Automation-first** | If a step is documented as manual, that is a temporary state with a tracked path to automation. |

### How the principles are enforced

Principles that exist only as prose decay. Each is bound to a structural mechanism
elsewhere in the specification set, so that violating it requires breaking something
concrete:

| Principle | Enforced by |
|---|---|
| P1 Reproducible | Bootstrap + validation pillars — [003 §10.1](003-Core-Architecture-Specification.md#101-four-pillars) |
| P2 Modular | Layer contracts — [003 §4.3](003-Core-Architecture-Specification.md#43-component-boundaries-contracts) |
| P3 Observable | Trace store; a gate cannot advance without it — [003 §8.2](003-Core-Architecture-Specification.md#82-promotion-criteria) |
| P4 Secure by default | Role-scoped agent permissions — [003 §7](003-Core-Architecture-Specification.md#7-agent-roster) |
| P5 Adaptive | Stage 0 discovery gates installation — [003 §5.1](003-Core-Architecture-Specification.md#51-role-gatekeeper-not-report) |
| P6 Vendor-neutral | Orchestrator is the sole caller of agent runtimes — [003 §4.3](003-Core-Architecture-Specification.md#43-component-boundaries-contracts) |
| P7 Automation-first | Manual steps carry a tracked path to automation |

---

## Non-Goals

Stated so that scope creep is visible when it happens:

- **Not a hosted product.** Single owner, single machine. Multi-tenancy is not a design constraint.
- **Not a model provider.** The platform routes to models; it does not train or serve them beyond optional local inference.
- **Not a replacement for judgment.** Autonomy is bounded by gates that the owner sets and can revoke at any time.
- **Not cloud-first.** Remote access exists, but the platform runs locally and must function without external orchestration.

---

## Definition of Done

- [x] Vision stated
- [x] Goals G1–G6 defined
- [x] Guiding principles P1–P7 defined, each bound to an enforcement mechanism
- [x] Non-goals stated
- [ ] Design review checklist passed (pending 009)

---

## Decision Log

| # | Decision | Alternatives | Rationale | Trade-offs | Revisit when |
|---|---|---|---|---|---|
| D-001a | Goals and principles owned by 001, referenced by ID elsewhere | Restate them in each document | A single definition cannot drift; `G4` and `P5` mean one thing across the set | Readers of 003 must follow a link for full text | The set stops fitting one root document |
| D-002a | Every principle bound to a structural enforcement mechanism | State principles as prose guidance | Prose principles decay; bound ones require breaking something concrete to violate | Adds a maintenance link between 001 and 003 | A principle has no mechanism and stays advisory |
| D-003a | Non-goals stated explicitly | Leave scope implicit | Makes scope creep visible at review time rather than after it lands | — | The platform's purpose genuinely changes |
