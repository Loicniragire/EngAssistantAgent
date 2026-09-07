# 002 — Hardware Assessment

| Field | Value |
|---|---|
| Spec ID | 002 |
| Status | Draft — matrix complete, detected specification pending |
| Milestone | M0 — Foundation |
| Depends on | [001 Vision and Principles](001-Vision-and-Principles.md) |
| Consumed by | [003 Core Architecture](003-Core-Architecture-Specification.md) §5, [004 Environment Discovery](004-Environment-Discovery-Specification.md) |

---

## 1. Purpose and Scope

### 1.1 Purpose

This document **owns the capability data that governs installation**. It defines:

- the hardware profiles the platform recognises (§2),
- the capability matrix mapping every optional feature to its hardware requirements (§3),
- the concurrent-agent capacity formula (§4),
- the health score and its derivation (§5),
- the upgrade recommendation rules (§6).

[003 §5](003-Core-Architecture-Specification.md#5-environment-discovery-stage-0) makes
environment discovery the first stage of every installation run, and this document is the
data that stage evaluates. Discovery detects facts; **this document decides what those
facts permit**. A feature absent from §3 cannot be installed, because Stage 0 has no rule
by which to enable it.

### 1.2 Two halves

| Half | Content | State |
|---|---|---|
| **Governing** (§2–§6) | Profiles, matrix, formulas, upgrade rules — pure design, machine-independent | Complete |
| **Detected** (§7) | The actual specification of the target machine | Pending — fills after the discovery script runs |

The governing half was written first deliberately. Had the discovery script come first,
its hardcoded thresholds would have become the de-facto matrix and this document would
describe the script rather than govern it.

### 1.3 Out of scope

The discovery script's implementation, its output format, and its detection methods
belong to [004 Environment Discovery](004-Environment-Discovery-Specification.md). This
document specifies *what the script must decide*, not *how it detects*. 004 holds no
thresholds of its own (004 D-201) — every value it compares against is read from here.

---

## 2. Hardware Profiles

### 2.1 Definitions

A profile is selected by the **lowest-scoring** qualifying dimension — a machine with
64 GB of RAM and 4 cores is `lightweight`, not `high`. This is deliberate: the binding
constraint determines real capability, and an optimistic profile would enable components
the machine cannot actually run.

| Profile | RAM | Cores / threads | GPU | Storage | Intent |
|---|---|---|---|---|---|
| `minimal` | < 8 GB | < 4 threads | — | — | **Below platform floor.** Install refused. |
| `lightweight` | ≥ 8 GB | ≥ 4 cores / 4 threads | none required | ≥ 128 GB SSD | Single-agent, cloud-model-only. No local inference. |
| `mid` | ≥ 32 GB | ≥ 8 cores / 16 threads | optional | ≥ 512 GB NVMe | Several concurrent agents, local embeddings, full memory and monitoring layers. |
| `high` | ≥ 64 GB | ≥ 12 cores / 24 threads | scored separately (§2.4) | ≥ 1 TB NVMe | Many concurrent agents plus local coding models on GPU. |

### 2.2 Platform floor

Below `lightweight` the platform will not install. The floor exists because the base
stack (§4.1) reserves 4 GB before a single agent runs; on 4 GB of total RAM there is
nothing left to orchestrate, and on 6 GB only a single agent fits with no headroom for a
build. Stage 0 reports the shortfall and the upgrade required to clear it rather than
attempting a degraded install.

### 2.3 Reported vs. nominal memory

Thresholds in §2.1 are nominal — "32 GB" means a machine with 32 GB installed. The kernel
reports less: `MemTotal` excludes firmware and integrated-graphics reservations, so a
32 GiB machine typically reports 30.5–31.5 GiB. Compared literally, every machine would
fail the threshold matching its own label.

**A dimension qualifies at threshold T when the reported value is ≥ 0.95 × T.** The 5%
allowance covers observed reservation overhead without spanning the gap to the next
threshold — the smallest step in §2.1 is 8 → 32 GB, far wider than 5%.

This rule applies to memory only. Core counts, VRAM, and disk capacity are reported
without comparable reservation loss and are compared exactly.

### 2.4 GPU handling

**GPU never gates profile selection at any level**, `high` included. A machine with the
RAM, cores, and disk for `high` is `high` without a GPU; it simply has F-08…F-10 disabled
by the matrix. A `mid` machine with a 16 GB GPU gains local coding models (§3, F-08)
without becoming `high` — it lacks the RAM and cores to sustain `high`'s agent
concurrency. Profile governs breadth; the matrix governs local inference specifically.

---

## 3. Capability Matrix

Every optional feature, with the minimum it needs. Stage 0 evaluates this table row by
row against detected facts and enables only rows that pass.

| ID | Feature | Min RAM | Min cores | VRAM | Disk | Min profile |
|---|---|---|---|---|---|---|
| F-01 | Host + Docker + orchestrator (base stack) | 4 GB | 2 | — | 20 GB | `lightweight` |
| F-02 | Tailscale remote access | +0.1 GB | — | — | — | `lightweight` |
| F-03 | Encrypted backups (restic or equivalent) | +0.2 GB | — | — | 2× data | `lightweight` |
| F-04 | PostgreSQL memory layer | +1 GB | 1 | — | 20 GB | `lightweight` |
| F-05 | Vector store — pgvector, colocated | +0.5 GB | — | — | 10 GB | `lightweight` |
| F-06 | Vector store — standalone (Qdrant/Weaviate) | +2 GB | 2 | — | 20 GB | `mid` |
| F-07 | Local embeddings (CPU) | +2 GB | 2 | — | 5 GB | `mid` |
| F-08 | Local coding model — 7B @ Q4 | +2 GB | 4 | 6 GB | 10 GB | `mid` + GPU |
| F-09 | Local coding model — 14B @ Q4 | +2 GB | 4 | 10 GB | 20 GB | `high` |
| F-10 | Local coding model — 32B @ Q4 | +4 GB | 8 | 20 GB | 40 GB | `high` |
| F-11 | Monitoring — Grafana + Prometheus | +1.5 GB | 2 | — | 50 GB | `mid` |
| F-12 | Scheduler — cron | negligible | — | — | — | `lightweight` |
| F-13 | Scheduler — Temporal | +2 GB | 2 | — | 20 GB | `mid` |
| F-14 | Concurrent agents (per agent) | +2 GB | 2 threads | — | 10 GB | see §4 |

RAM figures marked `+` are **additive working sets** over the base stack, not totals.
Disk figures are steady-state after install, excluding repository checkouts.

### 3.1 Reading the matrix

A row is enabled when **all** of its columns are satisfied *and* the machine meets the
row's minimum profile. Rows F-05/F-06 and F-12/F-13 are alternatives, not additions:
Stage 0 selects the highest-capability variant the machine supports and records the
choice in the platform manifest.

---

## 4. Concurrent Agent Capacity

### 4.1 Platform reserve

Before any agent runs, the platform reserves:

| Component | Reserve |
|---|---|
| Host OS + Docker daemon | 2.0 GB |
| Memory layer (F-04 + F-05) | 1.5 GB |
| Orchestrator | 0.5 GB |
| Monitoring (F-11, `mid` and above) | 1.5 GB |
| **Total — `lightweight`** | **4.0 GB** |
| **Total — `mid` / `high`** | **5.5 GB** |

The reserve is a **constant per profile**, not a function of enabled features. The
optional features in §3 are additive (F-06 + F-07 + F-13 together add ~6 GB) and the
formula does not subtract them. This is deliberate: above 32 GB cores bind before RAM in
every row of §4.3, so a feature-dependent reserve would change no capacity figure while
making the formula circular — enabled features depend on the profile, which depends on
capacity. **On a `mid` machine enabling all optional features, treat §4.2 as an upper
bound.** Revisit if a machine is ever both RAM-bound and feature-heavy.

### 4.2 Formula

```
agents_ram  = floor((RAM_total_GB − reserve_GB) / 2)
agents_cpu  = floor(threads / 2)
capacity    = max(1, min(agents_ram, agents_cpu))
```

2 GB and 2 threads per agent is a **working set under load**, not idle footprint — an
agent running a build or test suite spawns compilers, language servers, and test runners
that dominate its own process. Sizing to idle would oversubscribe the machine precisely
when several agents are busy, which is the case that matters.

### 4.3 Worked values

| RAM | Threads | `agents_ram` | `agents_cpu` | **Capacity** |
|---|---|---|---|---|
| 8 GB | 4 | 2 | 2 | **2** |
| 16 GB | 8 | 6 | 4 | **4** |
| 32 GB | 16 | 13 | 8 | **8** |
| 64 GB | 24 | 29 | 12 | **12** |
| 128 GB | 32 | 61 | 16 | **16** |

Two observations Stage 0 should surface from this table:

- **16 GB → 32 GB doubles capacity (4 → 8)** on a machine whose other dimensions
  already meet `mid` (≥ 8 cores / 16 threads, ≥ 512 GB NVMe). Where they do not, RAM is
  not the binding dimension and §6.2 requires saying so. Where it is, this is the single
  highest-leverage upgrade at the low end — it also clears the `mid` threshold that
  unlocks local embeddings.
- **Above 32 GB, cores bind before RAM.** At 64 GB the RAM would support 29 agents but
  24 threads allow 12. Recommending more RAM to a core-bound machine is the most likely
  wrong answer this document exists to prevent, so §6 requires the binding dimension to
  be named in every recommendation.

---

## 5. Health Score

003 §5.6 requires a single figure with its derivation shown. The formula is owned here,
alongside the matrix it scores against.

### 5.1 Dimensions and weights

| Dimension | Weight | Scored against |
|---|---|---|
| RAM | 30 | Headroom over the `mid` threshold |
| CPU | 20 | Thread count vs. agent capacity demand |
| Storage | 20 | Free NVMe capacity and random-IO throughput |
| GPU | 15 | VRAM against the F-08…F-10 tiers |
| Software currency | 10 | Ubuntu LTS status, driver and toolchain versions |
| Network | 5 | Link speed and remote reachability |

RAM carries the heaviest weight because it binds agent concurrency at the low end, which
is where most machines sit. GPU is weighted at 15 rather than higher because every
capability it unlocks is optional — a GPU-less machine is fully functional against cloud
models.

### 5.2 Per-dimension scoring

Each dimension scores 0–100:

```
0    below the platform floor for that dimension
50   meets `lightweight`
75   meets `mid`
100  meets `high`
```

Intermediate values interpolate linearly between adjacent thresholds. **Below the
`lightweight` threshold a dimension scores 0 outright — it does not interpolate toward
zero.** A dimension under the floor is disqualifying, and partial credit of 25 for 4 GB
of RAM would misrepresent a machine that cannot run the platform at all.

```
health = Σ (dimension_score × weight) / 100
```

### 5.3 Bands

**The §2.2 floor check is evaluated before the score and overrides it.** A machine below
the floor on any required dimension is `Insufficient` and the install is refused,
whatever the weighted score computes to. Without this precedence the two mechanisms
disagree: 4 GB of RAM with 32 threads and fast NVMe scores 55, which the table below
would otherwise read as runnable.

| Score | Band | Meaning |
|---|---|---|
| any | **Insufficient** | Below the §2.2 floor on any required dimension. Install refused, whatever the score. |
| 0–39 | **Insufficient** | Install refused. |
| 40–59 | **Constrained** | Runs at `lightweight`. Local inference disabled. Recommended upgrades listed. |
| 60–79 | **Capable** | Full platform at `mid`. Recommended upgrades expand capability. |
| 80–100 | **Headroom** | `high` profile with room to grow. Only optional upgrades remain. |

`required` upgrades (§6.1) exist only below the floor, so a `Constrained` machine that
cleared the floor lists `recommended` upgrades, never `required` ones.

### 5.4 Reporting rule

The score is never reported alone. Stage 0 must print the per-dimension scores, the
weights, and the arithmetic — a bare number invites trust the derivation may not
support, and the platform's stated purpose is to be diagnostic, not oracular.

---

## 6. Upgrade Recommendations

### 6.1 Tiers

| Tier | Criterion |
|---|---|
| `required` | Platform cannot function without it. Below the §2.2 floor. |
| `recommended` | Materially expands capability — crosses a profile threshold or at least doubles agent capacity. |
| `optional` | Marginal or niche gain. Does not cross a threshold. |

### 6.2 Required fields

Every recommendation carries all four:

1. **Tier** — from §6.1.
2. **Binding dimension** — which constraint this lifts, and what becomes the *next*
   binding constraint afterward. §4.3 shows why: RAM is not always the answer.
3. **Rationale** — the concrete capability unlocked, in capability language.
   *"32 GB of RAM doubles concurrent agent capacity from 4 to 8 and unlocks local
   embeddings."* / *"A discrete GPU with 12 GB VRAM enables local coding models up to
   14B."*
4. **Feasibility** — whether this machine can physically accept the upgrade, from the
   slot, socket, and max-supported facts in 003 §5.2. A recommendation to add RAM to a
   machine with no free slots and both populated at max capacity is worse than no
   recommendation.

### 6.3 Standard recommendations

Stage 0 emits from this set, filtered by detected state and feasibility:

| Upgrade | Tier when | Unlocks |
|---|---|---|
| RAM → 16 GB | `required` if < 8 GB | Clears the platform floor |
| RAM → 32 GB | `recommended` if 8–16 GB | `mid` profile; capacity 4 → 8; local embeddings (F-07); standalone vector store (F-06); Temporal (F-13) |
| RAM → 64 GB | `optional` if ≥ 32 GB and core-bound | Little, until cores increase — see §4.3 |
| CPU → ≥ 16 threads | `recommended` if core-bound below capacity 8 | Raises the `agents_cpu` ceiling |
| SATA SSD → NVMe | `recommended` if HDD, `optional` if SATA SSD | Build and test throughput; `mid` storage threshold |
| Add GPU ≥ 12 GB VRAM | `optional` | Local coding models F-08/F-09 |
| GPU → ≥ 20 GB VRAM | `optional` | 32B local models (F-10) |
| Disk → ≥ 1 TB | `recommended` if < 512 GB | Repo checkouts, model weights, metric retention |

---

## 7. Detected Specification

> **Pending.** Fills once the discovery script
> ([004](004-Environment-Discovery-Specification.md)) exists and runs on the target
> machine. Until then the profile is undetermined and no install decision is authorised
> by this document.

### 7.1 Discovery output

<!-- Paste the machine-readable discovery output below. -->

```text
TBD — run the discovery script on the target Linux machine and paste its output here.
```

### 7.2 Derived assessment

| Field | Value |
|---|---|
| Selected profile | TBD |
| Binding dimension | TBD |
| Agent capacity (§4.2) | TBD |
| Health score (§5) | TBD |
| Band | TBD |
| Enabled features | TBD |
| Disabled features + failed requirement | TBD |

### 7.3 Recommended upgrades

| Upgrade | Tier | Binding dimension | Rationale | Feasible |
|---|---|---|---|---|
| TBD | | | | |

---

## 8. Definition of Done

- [x] Profile thresholds defined (§2) — owed to 003 §5.3
- [x] Capability matrix populated (§3) — owed to 003 §5.4
- [x] Agent capacity formula defined (§4)
- [x] Health score formula and bands defined (§5) — owed to 003 §5.6
- [x] Upgrade tiers and required fields defined (§6) — owed to 003 §5.5
- [ ] Discovery script run on the target machine; §7 populated
- [ ] Matrix figures validated against observed usage on real hardware
- [x] Decision log populated (§9)
- [ ] Design review checklist passed (pending 009)

---

## 9. Decision Log

| # | Decision | Alternatives | Rationale | Trade-offs | Revisit when |
|---|---|---|---|---|---|
| D-101a | Memory compared at 95% of nominal threshold | Compare `MemTotal` literally | A 32 GB machine reports ~31 GiB and would fail its own label; the 5% band is far narrower than the 8→32 GB gap between thresholds | A machine 4% short of a threshold qualifies | Threshold spacing narrows |
| D-101 | Profile = lowest-scoring qualifying dimension | Highest, or weighted average | The binding constraint determines real capability; an optimistic profile enables components the machine cannot run | A single weak dimension caps an otherwise strong machine | Per-feature gating makes the profile abstraction redundant |
| D-102 | GPU never gates profile selection, `high` included | GPU as an input to the `high` threshold | Every GPU-unlocked capability is optional; a GPU-less machine is fully functional against cloud models | Two axes to reason about instead of one | Local inference becomes the primary path rather than a supplement |
| D-103 | 2 GB / 2 threads per agent, sized to load not idle | Size to idle footprint | Oversubscription hurts exactly when several agents are busy, which is the case that matters | Under-reports capacity for light workloads | Observed usage on real hardware contradicts it |
| D-104 | Health score weights RAM 30 / CPU 20 | Equal weights across dimensions | RAM binds agent concurrency at the low end, where most machines sit | Weights are judgment, not measurement | §4.3 core-binding proves more common than expected |
| D-105 | Health score never reported without its derivation | Report the number, detail on request | A bare score invites trust the derivation may not support; the platform is meant to be diagnostic | Longer report output | — |
| D-106 | Every recommendation must name its binding dimension | Recommend the upgrade alone | Prevents the most likely wrong answer — more RAM to a core-bound machine (§4.3) | More work per recommendation | — |
| D-107 | Governing half (§2–§6) written before the discovery script | Script first, document its thresholds | Hardcoded thresholds would become the de-facto matrix and this doc would describe the script rather than govern it | Figures are unvalidated until hardware is measured | §7 is populated and figures can be checked |
| D-108 | Health score formula owned by 002, not 004 | Own it in 004 alongside the script | It scores against this document's matrix and thresholds; splitting them invites drift | 004 must import from here | — |

---

## 10. Open Questions

1. **Target machine.** What is the actual Linux box? Every §7 figure and the whole
   upgrade set depend on it, and it is the last unknown blocking M0.
2. **Matrix validation.** The §3 and §4 figures are engineering estimates. What
   observation period on real hardware is needed before they are treated as settled?
3. **Repository disk budget.** F-14 allots 10 GB per agent for checkouts. This depends
   on how many repos come under management (003 §14 Q leaves the repo set open).
4. **Multi-machine.** §2 assumes one host. If a second machine is ever added, is the
   profile per-machine or per-cluster? Affects the manifest schema (006).
