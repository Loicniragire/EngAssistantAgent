# 003 — Core Architecture Specification

| Field | Value |
|---|---|
| Spec ID | 003 |
| Status | Draft |
| Milestone | M1 — Core Architecture |
| Supersedes | — |
| Depends on | [001 Vision and Principles](001-Vision-and-Principles.md) (goals, principles), [002 Hardware Assessment](002-Hardware-Assessment.md) (profiles, capability matrix) |
| Source | Design conversation (retrieved 2026-09-07) — https://chatgpt.com/share/6a9ed0df-2b14-83ea-a725-f8a5824bdb66 |

---

## 1. Purpose and Scope

### 1.1 What this document is

This is the **core architecture specification** for the Engineering Assistant Agent
platform: a persistent, self-hosted AI engineering system running on a Linux box at
home, acting first as an assistant and progressively as an autonomous lead engineer.

It defines the platform's structure — layers, components, contracts, agent roles, and
autonomy model — at a level detailed enough that every downstream document can be
written against it without renegotiating fundamentals.

### 1.2 What this document is not

It is deliberately **not** the full 150–300 page platform manual. The design
conversation settled explicitly on modular, incrementally-completed specs that roll up
to a final document, rather than one monolith written in a single pass. This spec is
one such module: it *specifies* the downstream documents and their definitions of done
rather than *containing* them.

Installation procedures, script implementations, prompt libraries, and runbooks live in
the documents named in [§10](#10-repository-structure-and-document-roadmap) and are explicitly out of scope here.

### 1.3 Scope fence

| In scope | Out of scope (specified, deferred) |
|---|---|
| Layer model and component boundaries | Step-by-step install commands |
| Agent roster and responsibilities | Prompt library contents |
| Platform manifest schema | Model routing policy tables |
| Environment discovery contract | Cost and token management |
| Autonomy gates and their promotion criteria | Disaster recovery runbook |
| Repo pillar structure and doc roadmap | Reference implementation code |

---

## 2. Goals

Owned by [001 §Goals](001-Vision-and-Principles.md#goals) and referenced here by ID.

| ID | Goal |
|---|---|
| G1 | Persistent engineering context |
| G2 | Assistant first, autonomous later |
| G3 | Hardware-adaptive |
| G4 | Diagnostic, not just prescriptive |
| G5 | Reproducible from bare metal |
| G6 | A distribution, not a manual |

---

## 3. Guiding Principles

Owned by [001 §Guiding Principles](001-Vision-and-Principles.md#guiding-principles) and
referenced here by ID. Every architectural decision in this document must satisfy all
seven; a decision that violates one is recorded in §13 with an explicit justification.

| ID | Principle | Enforced in this document by |
|---|---|---|
| P1 | Reproducible | §10.1 pillars |
| P2 | Modular | §4.3 layer contracts |
| P3 | Observable | §8.2 promotion criteria |
| P4 | Secure by default | §7 role-scoped permissions |
| P5 | Adaptive | §5.1 Stage 0 gating |
| P6 | Vendor-neutral | §4.3 orchestrator as sole caller |
| P7 | Automation-first | §10.1 reference implementation pillar |

---

## 4. System Overview

### 4.1 Layer model

```
┌─────────────────────────────────────────────────────────────┐
│  L7  Interface        Chat / voice / mobile · Slack · Signal │
├─────────────────────────────────────────────────────────────┤
│  L6  Agent Roster     PM · Architect · Dev · QA · DevOps ·   │
│                       Security                              │
├─────────────────────────────────────────────────────────────┤
│  L5  Orchestration    Dispatcher · model routing ·           │
│                       autonomy gate · simulation mode        │
├─────────────────────────────────────────────────────────────┤
│  L4  Agent Runtimes   OpenCode · Claude Code · Codex CLI ·   │
│                       Antigravity CLI                        │
├─────────────────────────────────────────────────────────────┤
│  L3  Memory           PostgreSQL · vector store ·            │
│                       decision log · trace store             │
├─────────────────────────────────────────────────────────────┤
│  L2  Integration      GitHub + Actions · scheduler           │
│                       (cron → Temporal) · Grafana            │
├─────────────────────────────────────────────────────────────┤
│  L1  Platform         Docker Compose · secrets · backups ·   │
│                       Tailscale · nginx                      │
├─────────────────────────────────────────────────────────────┤
│  L0  Host             Ubuntu · Git · SSH · hardening         │
└─────────────────────────────────────────────────────────────┘
             ▲                                    ▲
             │                                    │
   ┌─────────┴──────────┐              ┌──────────┴─────────┐
   │ Environment        │─── writes ──▶│ Platform Manifest  │
   │ Discovery (Stage 0)│◀── reads ────│ (machine-readable) │
   └────────────────────┘              └────────────────────┘
```

Environment Discovery and the Platform Manifest sit outside the layer stack because they
govern it: discovery determines what may be installed, and the manifest declares what is
installed. Both are described in [§5](#5-environment-discovery-stage-0) and
[§6](#6-platform-manifest).

### 4.2 Layer responsibilities

| Layer | Responsibility | Components (v1) |
|---|---|---|
| L0 Host | Operating system, identity, remote shell, OS hardening | Ubuntu LTS, Git, SSH, ufw, unattended-upgrades |
| L1 Platform | Container runtime, private networking, secret storage, backups, reverse proxy | Docker + Compose, Tailscale, secrets backend, restic (or equivalent), nginx |
| L2 Integration | Connections to the outside world and to time | GitHub API + Actions, cron (v1) → Temporal (later), Grafana + metrics exporters |
| L3 Memory | Durable state: repo knowledge, conversation history, decisions, traces | PostgreSQL, vector store (pgvector or standalone), trace store |
| L4 Agent Runtimes | The actual coding agents that execute work | OpenCode, Claude Code, Codex CLI, Antigravity CLI |
| L5 Orchestration | Decides *which* agent/model handles *what*, under which autonomy gate | Dispatcher service, routing policy, gate enforcement, simulation mode |
| L6 Agent Roster | Role-scoped agent definitions with distinct permissions and prompts | PM, Architect, Dev, QA, DevOps, Security |
| L7 Interface | How the owner talks to the platform, especially from mobile | Chat/voice front end, Slack or Signal notifications |

### 4.3 Component boundaries (contracts)

- **L5 → L4** is the only path to an agent runtime. Nothing else invokes a CLI directly.
  This is what makes P6 (vendor-neutral) enforceable.
- **L5 → L3** is the only writer of decision-log and trace records. Agents propose;
  the orchestrator records.
- **L6 agents do not hold credentials.** The orchestrator injects scoped, short-lived
  credentials per task from L1's secret store.
- **The manifest is the single source of configuration truth.** No component reads
  hardware facts directly at runtime; it reads the manifest.

---

## 5. Environment Discovery (Stage 0)

### 5.1 Role: gatekeeper, not report

Environment discovery is **the first stage of every installation run**, not a one-time
inventory produced at setup. Every bootstrap, upgrade, and component install begins by
re-running discovery.

The sequence is fixed:

```
detect hardware  →  select profile  →  recommend upgrades  →  enable only
                                                              compatible components
```

A component whose requirements are not met by the detected profile is **not installed**,
and the reason is reported. This is the mechanism by which P5 (adaptive) is enforced
rather than merely intended.

### 5.2 Detection surface

| Category | Facts collected |
|---|---|
| CPU | Model, physical cores, threads, base/boost clock, virtualization support |
| Memory | Total RAM, available RAM, slot count, populated slots, max supported |
| GPU | Present/absent, model, VRAM, driver version, CUDA/ROCm availability |
| Storage | Device type (NVMe/SSD/HDD), capacity, free space, sequential and random throughput |
| Network | Link speed, public reachability, existing Tailscale state |
| OS | Distribution, version, kernel, LTS status |
| Toolchain | Existing Docker, Git, Python, Node, and agent CLIs with versions |

Slot count and max supported RAM are collected specifically to support G4 — the platform
must be able to say whether an upgrade is physically possible on this machine, not just
desirable.

### 5.3 Hardware profiles

Profiles are the vocabulary the rest of the platform uses to talk about capability.

| Profile | Intent |
|---|---|
| `minimal` | Below the platform floor. Install refused. |
| `lightweight` | Single-agent, cloud-model-only operation. No local inference. |
| `mid` | Several concurrent agents, local embeddings, full memory layer. |
| `high` | Many concurrent agents plus local coding models on GPU. |

Exact thresholds are set in [002 §2](002-Hardware-Assessment.md#2-hardware-profiles),
which owns them. This spec owns only the fact that profiles exist, are selected by
discovery, and gate installation.

### 5.4 Capability matrix contract

002 expresses, for every optional platform feature, the minimum CPU, RAM, GPU/VRAM, and
disk required, and the profile at which it becomes available. The matrix is the data
Stage 0 evaluates, and a feature absent from it cannot be installed — Stage 0 has no rule
by which to enable it.

Populated in [002 §3](002-Hardware-Assessment.md#3-capability-matrix). Concurrent-agent
capacity is derived rather than tabulated; the formula is
[002 §4](002-Hardware-Assessment.md#4-concurrent-agent-capacity).

### 5.5 Upgrade recommendations

Discovery output must explain, not just enumerate. Every recommendation carries:

- **Tier** — `required` (platform cannot function), `recommended` (materially expands
  capability), or `optional` (marginal or niche gain).
- **Rationale** — the concrete capability unlocked. Model the phrasing on: *"32 GB of
  RAM doubles concurrent agent capacity and unlocks local embeddings"*; *"a discrete GPU
  enables local coding models."*
- **Binding dimension** — which constraint the upgrade lifts, and what binds next.
  More RAM for a core-bound machine is the failure mode this field prevents.
- **Feasibility** — whether this machine can physically accept the upgrade, from the
  slot/socket facts in §5.2.

Tier criteria and the standard recommendation set are
[002 §6](002-Hardware-Assessment.md#6-upgrade-recommendations).

### 5.6 Discovery report contract

Every discovery run produces:

1. **Detected specification** — the raw facts of §5.2.
2. **Selected profile** — and the specific fact that determined it.
3. **Enabled / disabled components** — each disabled entry paired with the requirement
   it failed, phrased as capability: *"can run four agents concurrently"*, *"local LLMs
   disabled due to RAM."*
4. **Upgrade recommendations** — tiered, with rationale and feasibility (§5.5).
5. **Health score** — a single figure, **never reported without its derivation**.
   The formula, weights, and bands are owned by
   [002 §5](002-Hardware-Assessment.md#5-health-score), alongside the matrix it scores
   against.
6. **Next steps** — the concrete actions this report implies.

The report is emitted in both human-readable form (pasted into 002) and machine-readable
form (consumed by the manifest).

---

## 6. Platform Manifest

### 6.1 Purpose

A single machine-readable file describing the platform's declared state. It turns the
repository from a pile of scripts into a declarative system.

The manifest is **read and written by both** the bootstrap process and the environment
discovery tool. This bidirectionality is the point:

- **Discovery writes** the detected hardware profile and the resulting component
  eligibility.
- **Bootstrap reads** the manifest to decide what to install, and **writes back** what
  it actually installed and at which version.
- **Every other component reads** the manifest instead of probing the machine.

### 6.2 Contents

| Section | Describes |
|---|---|
| `hardware_profile` | Selected profile, detected facts, discovery timestamp |
| `agents` | Which roles are enabled, their runtime binding, their permission scope |
| `runtimes` | Installed agent CLIs and versions |
| `tools` | Installed platform tooling and versions |
| `notifications` | Configured providers and their routing |
| `autonomy` | Current autonomy level per action class (§8) |
| `repositories` | Repos under management and their access mode |

### 6.3 Rules

- The manifest is version-controlled; secrets are referenced by handle, never inlined.
- A manifest change is a reviewable diff — this is how platform changes become auditable.
- Schema and validation rules are specified in **006 Platform Manifest** (see §10).

---

## 7. Agent Roster

The platform is structured as an "AI software company in a box": role-scoped agents, each
with a specific remit, coordinated rather than a single general assistant. The owner
directs the team rather than writing every line.

| Agent | Remit | Distinct permissions |
|---|---|---|
| **PM** | Coordinates work across the other agents, maintains the task queue, produces status summaries | Read all repos; write to task queue only |
| **Architect** | Design proposals, trade-off analysis, decision-log entries | Read all repos; write to docs and decision log |
| **Dev** | Implements changes on branches, opens PRs with explanation and self-review | Branch write; no merge to protected branches |
| **QA** | Runs and interprets test suites, reproduces defects, gates PRs | Read repos; write test artifacts; PR status checks |
| **DevOps** | Environment, deployment, monitoring wiring, rollback proposals | Infra config write; production actions gated by §8 |
| **Security** | Dependency and secret scanning, permission review, hardening findings | Read-only across platform; write to findings |

Role separation is a security control, not an organizational metaphor: it is how least
privilege (P4) is expressed at the agent layer.

---

## 8. Progressive Autonomy

### 8.1 Model

Autonomy is granted per **action class**, not globally, and each class advances through
gates independently. The platform starts entirely at Gate 0.

| Gate | Name | The platform may… |
|---|---|---|
| **Gate 0** | Observe | Read repos, summarize, report. No writes anywhere. |
| **Gate 1** | Propose | Create branches, run tests, open PRs with explanation, self-review, and stated trade-offs. **Never merges.** |
| **Gate 2** | Act (low-risk) | Auto-merge PRs meeting an explicit low-risk definition. Monitor production metrics. |
| **Gate 3** | Act (recoverable) | Propose rollbacks; execute pre-approved recovery actions. |

The conversation's own framing of Gate 1 is the binding one: in assistant mode the platform
*"summarizes PRs rather than merging automatically."*

### 8.2 Promotion criteria

A gate advances only when all hold:

1. A defined observation period at the current gate with no unreviewed incidents.
2. A written low-risk definition (for Gate 2) or recovery-action allowlist (for Gate 3), checked
   into the repo.
3. Every action in the class is observable (P3) and reversible.
4. The manifest records the change (§6.2 `autonomy`), making it a reviewable diff.

Gate demotion requires no criteria and may be triggered by the owner at any time.

### 8.3 Simulation mode

The platform supports a **dry-run mode that shows planned changes and recommendations
before anything runs**. Simulation is mandatory for any first execution of a newly
promoted action class, and always available on demand. It is the mechanism that makes
gate promotion safe to try.

---

## 9. Cross-Cutting Components

### 9.1 Self-evaluation

A component that continuously evaluates the platform itself: watching for outdated
components, newly released versions of the agent runtimes, and new opportunities in a
fast-moving ecosystem. It reports; it does not act on its own findings below Gate 2.

This exists because the platform's dependencies — agent CLIs and models — turn over far
faster than the platform's own architecture. Without it, the spec ages silently.

### 9.2 Decision logs

**Every specification chapter closes with a decision log.** Each entry records:

| Field | Content |
|---|---|
| Decision | What was chosen |
| Alternatives | What was considered instead |
| Rationale | Why this one |
| Trade-offs | What is given up |
| Revisit when | The condition that should reopen the decision |

### 9.3 Design review checklist

Distinct from the decision log. **Every chapter ends with a checklist** confirming the
chapter meets a uniform standard, so that quality does not drift as the document set
grows. Contents specified in 009 (see §10).

---

## 10. Repository Structure and Document Roadmap

### 10.1 Four pillars

The repository evolves along four parallel tracks:

| Pillar | Holds | Path |
|---|---|---|
| **Specifications** | The numbered spec set — this document among them | `docs/architecture/`, `docs/implementation/` |
| **Reference implementation** | Bootstrap scripts, Docker Compose, config templates | `scripts/`, `compose/`, `templates/` |
| **Validation** | Per-section validation checks, capability tests, health checks | `validation/` |
| **Operations** | Runbooks, disaster recovery, maintenance procedures | `docs/operations/` |

Only the specifications pillar exists today. The other three are created as the
milestones that need them arrive.

### 10.2 Milestones

Two phase framings were discussed. They are compatible once infrastructure is split out
of foundation, which is the reading adopted here:

| Milestone | Name | Content | Done when |
|---|---|---|---|
| **M0** | Foundation | Repo, docs structure, vision, hardware assessment | Repo exists with `docs/architecture/`; 001 and 002 stubbed and committed — *complete* |
| **M1** | Core architecture | The core architectural specs, this document first | Every M1 document in §10.3 meets the §12.2 standard; §14 open questions closed |
| **M2** | Infrastructure | Ubuntu, hardening, Docker, Git, Tailscale, secrets, backups | Bare Ubuntu reaches L0–L1 via bootstrap; validation pillar passes; Tailscale reachable remotely |
| **M3** | AI dev environment | Agent runtimes, memory layer, GitHub integration | All four agent CLIs installed and invocable; memory layer persists across restart; AS-1 passes at Gate 0 |
| **M4** | Intelligence layer | Orchestrator, agent roster, model routing | Orchestrator is the sole caller of L4; all six roles defined with scoped permissions; AS-2 passes at Gate 1 |
| **M5** | Automation and autonomy | Scheduling, monitoring, progressive autonomy gates | Simulation mode operational; Gate 2 promotion criteria met and recorded in the manifest; AS-3 and AS-4 pass |

Each milestone ends in a working system, not just a document. A milestone is not done
until its **Done when** column is satisfied and STATUS.md (§10.4) reflects it.

### 10.3 Document roadmap

Numbered `NNN-Kebab-Title`, stable from creation so cross-references never break.

| ID | Document | Milestone | Status |
|---|---|---|---|
| 001 | [Vision and Principles](001-Vision-and-Principles.md) | M0 | Draft |
| 002 | [Hardware Assessment](002-Hardware-Assessment.md) | M0 | Draft — matrix complete |
| 003 | Core Architecture Specification | M1 | **This document** |
| 004 | Environment Discovery Specification | M1 | Planned |
| 005 | Orchestrator and Model Routing | M1 | Planned |
| 006 | Platform Manifest Schema | M1 | Planned |
| 007 | Memory and Knowledge Design | M1 | Planned |
| 008 | Agent Roles and Permissions | M1 | Planned |
| 009 | Design Review Checklist | M1 | Planned |

> **Note on provenance.** The design conversation committed to "the five core
> architectural specs" as the M1 target but never enumerated them. 004–008 above are a
> **proposed** roster derived from the layers and pillars in this spec, plus 009 as a
> standard. Confirm or amend before treating the numbering as fixed.

Deferred but named, to be assigned IDs when scheduled: prompt library, cost and token
management, disaster recovery, security hardening, remote access.

### 10.4 STATUS.md

A dashboard at the repository root, **specified here and not yet created**, showing:
current milestone, completed documents, outstanding decisions, future enhancements, and
overall completion percentage. Its purpose is that any session can resume without
reconstructing where the last one stopped.

---

## 11. Acceptance Scenarios

These are requirements on the orchestrator, expressed as the scenarios the platform
exists to serve.

**AS-1 — Drive-time status (Gate 0).** The owner asks "how is StoryThreads going?" from
a phone. Before they arrive, the platform has reviewed the relevant repositories,
summarized overnight commits, flagged a merge conflict, and queued the top three tasks.
*Exercises:* L7 mobile interface, PM agent, memory layer, multi-repo read access.

**AS-2 — Overnight feature (Gate 1).** The owner requests a small feature before bed.
Overnight the platform creates a branch, runs tests, opens a PR with an explanation, and
self-reviews it — including trade-offs it noticed. It does not merge.
*Exercises:* scheduler, Dev and QA agents, GitHub integration, Gate 1 enforcement.

**AS-3 — Trusted operation (Gate 2–3).** After trust is established, the platform
auto-merges PRs meeting the low-risk definition, monitors production metrics, and
proposes rollbacks when metrics degrade.
*Exercises:* autonomy gates, DevOps agent, monitoring, simulation mode.

**AS-4 — Bare-metal rebuild (any gate).** A fresh Ubuntu install reaches an equivalent
working platform via one bootstrap command, with discovery selecting the profile and
validations confirming each section.
*Exercises:* Stage 0 discovery, manifest, reference implementation, validation pillar.

---

## 12. Definition of Done

### 12.1 For this document

- [ ] Layer model reviewed and the v1 component list confirmed
- [ ] Agent roster and permission scopes confirmed
- [ ] Autonomy gates and promotion criteria accepted
- [ ] Document roadmap (§10.3) confirmed or amended
- [ ] Decision log populated (§13)
- [ ] Design review checklist passed (pending 009)

### 12.2 Standard for every spec in this set

A specification document is done when it: states its scope fence; is consistent with the
seven principles or justifies each departure; carries a populated decision log; passes
the design review checklist; declares its own definition of done; and is cross-referenced
by stable ID from every document that depends on it.

---

## 13. Decision Log

| # | Decision | Alternatives | Rationale | Trade-offs | Revisit when |
|---|---|---|---|---|---|
| D-001 | Modular numbered specs rolling up to a final document | Single 150–300 page manual | Delivers value per milestone; each doc is independently completable and maintainable | Requires cross-reference discipline; roll-up is extra work later | The doc set exceeds ~15 documents |
| D-002 | Discovery is the first stage of every install, not a one-time report | Run discovery once at setup | Makes hardware adaptivity (P5) enforced rather than advisory; keeps the manifest honest as hardware changes | Adds latency to every install run | Discovery cost becomes material |
| D-003 | Machine-readable platform manifest as single source of config truth | Scripts probe the machine directly at each step | Repo becomes declarative and auditable; platform changes are reviewable diffs | Manifest can drift from reality if writes are skipped | Manifest and detected state diverge in practice |
| D-004 | Start at Gate 0/1; autonomy per action class | Global autonomy switch | Matches the assistant-first, autonomy-later intent; blast radius stays bounded | More gate bookkeeping | A class proves consistently safe across many cycles |
| D-005 | Orchestrator is the only caller of agent runtimes | Agents invoked directly per task | Makes vendor-neutrality (P6) structurally enforceable rather than aspirational | One more indirection; orchestrator is a single point of failure | Orchestrator becomes a throughput bottleneck |
| D-006 | Role-separated agents with distinct permissions | One general-purpose agent | Least privilege at the agent layer; clearer failure attribution | More prompt and config surface to maintain | Role overhead exceeds its safety benefit |
| D-007 | cron for v1 scheduling, Temporal later | Temporal from the start | Lowest-friction start; scheduling needs are simple at M0–M3 | A migration is required later | Workflows need retries, timeouts, or durable state |
| D-008 | Repo is the deliverable; docs describe it | Static manual as the end product | Specs and implementation evolve together and cannot drift | Higher ongoing maintenance than a frozen document | — |

---

## 14. Open Questions

1. **The five core specs.** Which five does M1 comprise? §10.3 proposes 004–008.
2. ~~**Renumbering.**~~ *Resolved:* 001 and 002 renamed to the `NNN-Kebab-Title` convention.
3. **Notification transport.** Slack or Signal for v1 — this determines the L7
   integration work in M3.
4. **Vector store.** pgvector inside the existing PostgreSQL, or a standalone store?
   Profile-dependent; blocks 007.
5. **Secret backend.** Which store fills L1's secrets role, and how are per-task scoped
   credentials minted?
6. **Low-risk PR definition.** Required before Gate 2 can be reached; who writes it?
