# 004 — Environment Discovery Specification

| Field | Value |
|---|---|
| Spec ID | 004 |
| Status | Draft |
| Milestone | M1 — Core Architecture |
| Depends on | [001 Vision and Principles](001-Vision-and-Principles.md), [002 Hardware Assessment](002-Hardware-Assessment.md), [003 Core Architecture](003-Core-Architecture-Specification.md) §5 |
| Consumed by | 006 Platform Manifest, bootstrap (reference implementation pillar) |

---

## 1. Purpose and Scope

### 1.1 Division of ownership

[003 §5](003-Core-Architecture-Specification.md#5-environment-discovery-stage-0)
establishes that discovery is the first stage of every installation run.
[002](002-Hardware-Assessment.md) owns what the detected facts *permit*. This document
owns **how the facts are detected and reported**.

| Question | Owned by |
|---|---|
| Is discovery a gate or a report? | 003 §5.1 |
| What does 32 GB of RAM permit? | 002 §3, §4 |
| How is installed RAM detected on Ubuntu? | **004 (this document)** |
| What does the tool emit, and in what shape? | **004** |
| What happens when a fact cannot be detected? | **004** |

The rule that keeps these from drifting: **004 contains no thresholds.** Every number the
tool compares against is read from 002. A threshold hardcoded here would silently become
the real matrix — the failure 002 D-107 exists to prevent.

### 1.2 Out of scope

Installation actions, component provisioning, and the manifest schema itself. Discovery
decides *what may be installed*; it installs nothing.

---

## 2. Execution Contract

### 2.1 Invocation

```
discover.sh [--json PATH] [--report PATH] [--privileged] [--benchmark] [--quiet]
```

Invoked as Stage 0 of every bootstrap, upgrade, and component install. No installation
step may run without a discovery result from the current run.

### 2.2 Guarantees

| Guarantee | Meaning |
|---|---|
| **Read-only** | Makes no change to the system. Installs nothing, starts no service, writes only its own output files. |
| **Idempotent** | Repeated runs on unchanged hardware produce identical output but for the timestamp. |
| **Offline** | Makes no network request. Detection is local-only, so results are deterministic and no inventory leaves the machine. |
| **Zero-dependency** | Runs on a bare Ubuntu install using only the base system. Installs no package to complete its own job. |
| **Non-interactive** | Never prompts. Every decision comes from flags or detected state. |

Zero-dependency is the binding constraint on implementation: discovery runs *before*
anything is installed, so it cannot assume Python packages, Docker, or any tool the
platform itself provides.

### 2.3 Exit codes

| Code | Meaning | Bootstrap behaviour |
|---|---|---|
| `0` | Profile selected at or above `lightweight` | Proceed with enabled feature set |
| `10` | Below the 002 §2.2 platform floor | **Refuse install.** Print shortfall and required upgrades. |
| `20` | Detection incomplete — a required fact could not be read | Refuse install. Print which fact and why. |
| `30` | Threshold data missing, malformed, or failing its 002 stamp check (§4.1) | Refuse install. Configuration error, not a hardware verdict. |

`10` and `20` are distinct because they need different responses: `10` is a hardware
verdict the user can act on, `20` is a tooling problem that says nothing about the
machine.

### 2.4 Privilege model

Discovery runs **unprivileged by default**. Only DMI-derived facts — memory slot count,
populated slots, maximum supported capacity, CPU socket type — require root.

Without root the tool completes normally, marks those fields `unknown`, and sets every
upgrade recommendation's feasibility to `unknown` rather than guessing. Since
[002 §6.2](002-Hardware-Assessment.md#62-required-fields) requires feasibility on every
recommendation, the report states plainly that re-running with `--privileged` is what
turns "add RAM" into "add RAM — 2 of 4 slots free, 128 GB max."

Escalating silently would violate P4; guessing feasibility would violate G4.

---

## 3. Detection Methods

Each fact names a primary method and a fallback. Sources are base-system only.

### 3.1 CPU

| Fact | Primary | Fallback |
|---|---|---|
| Model | `lscpu` → `Model name` | `/proc/cpuinfo` → `model name` |
| Physical cores | `lscpu` → `Socket(s)` × `Core(s) per socket` | `/proc/cpuinfo` unique (`physical id`, `core id`) pairs |
| Threads | `nproc --all` | `/proc/cpuinfo` processor count |
| Base clock | `lscpu` → `CPU MHz` / `CPU max MHz` | `/proc/cpuinfo` → `cpu MHz` |
| Virtualization support | `lscpu` → `Virtualization` | `/proc/cpuinfo` flags: `vmx` (Intel) or `svm` (AMD) |
| Running under hypervisor | `systemd-detect-virt` | `/proc/cpuinfo` flag `hypervisor` |
| Socket type | `dmidecode -t processor` *(root)* | `unknown` |

`core id` is unique only within a socket, so the fallback must deduplicate on the
(`physical id`, `core id`) pair. Counting `core id` alone under-reports a multi-socket
machine by a factor of the socket count.

Hypervisor detection matters for reporting, not gating: a VM's core count is real but its
memory may be balloonable, so §5.4 flags it.

### 3.2 Memory

| Fact | Primary | Fallback |
|---|---|---|
| Total | `/proc/meminfo` → `MemTotal` | — (required; failure ⇒ exit `20`) |
| Available | `/proc/meminfo` → `MemAvailable` | `MemFree` + `Cached` |
| Slots total / populated | `dmidecode -t memory` → `Number Of Devices`, per-device `Size` | `unknown` |
| Maximum supported | `dmidecode -t memory` → `Maximum Capacity` | `unknown` |

`MemTotal` reports usable RAM after firmware and integrated-graphics reservations, so it
reads slightly below the nominal installed figure. Thresholds in 002 §2 are written
against `MemTotal`, not against the number on the DIMM label.

### 3.3 GPU

| Fact | Primary | Fallback |
|---|---|---|
| Present | `lspci -nn` matching VGA / 3D / Display class | — |
| Model | `nvidia-smi --query-gpu=name` / `rocm-smi --showproductname` | `lspci` device string |
| VRAM | `nvidia-smi --query-gpu=memory.total` / `rocm-smi --showmeminfo vram` | `unknown` |
| Driver version | `nvidia-smi --query-gpu=driver_version` | `modinfo nvidia` |
| Compute runtime | presence of `nvidia-smi` / `rocm-smi` | absent |

A GPU visible to `lspci` but with no working compute runtime is reported as
**present but unusable**, and the local-inference features (002 F-08…F-10) stay disabled.
Reporting VRAM the platform cannot reach would produce a capability claim the machine
cannot honour.

### 3.4 Storage

| Fact | Primary | Fallback |
|---|---|---|
| Devices | `lsblk -dno NAME,ROTA,TRAN,SIZE,MODEL` | `/sys/block/*/queue/rotational` |
| Class | `TRAN=nvme` ⇒ NVMe; `ROTA=0` ⇒ SSD; `ROTA=1` ⇒ HDD | `unknown` |
| Free space on platform root | `df -B1 /` | `statvfs` via `stat -f` |
| Throughput | `--benchmark` only (see §3.4.1) | class-derived estimate |

#### 3.4.1 Why class, not benchmark, by default

003 §5.2 lists disk throughput among the detection surface. Measuring it honestly means
writing test files, which breaks the read-only guarantee (§2.2) and takes minutes.

Discovery therefore **classifies** by bus and rotational flag and derives an expected
throughput band. NVMe versus SATA-SSD versus HDD is the distinction 002's thresholds
actually turn on, and class detection resolves it without writing a byte. A real
measurement is available under `--benchmark`, which is opt-in, documented as
write-generating, and never run during bootstrap.

### 3.5 Network

| Fact | Primary | Fallback |
|---|---|---|
| Interfaces | `ip -o link show` | `/sys/class/net/` |
| Link speed | `/sys/class/net/<if>/speed` | `ethtool <if>` → `Speed`, else `unknown` |
| Tailscale present | `command -v tailscale` | absent |

Consistent with §2.2, discovery does **not** test reachability — that requires a network
call. Remote reachability is validated later, by the validation pillar, after Tailscale is
configured.

### 3.6 OS and toolchain

| Fact | Primary |
|---|---|
| Distribution / version | `/etc/os-release` → `ID`, `VERSION_ID`, `VERSION_CODENAME` |
| LTS status | `VERSION_ID` matched against the LTS series list |
| Kernel | `uname -r` |
| Toolchain present | `command -v` for `docker`, `git`, `python3`, `node`, `curl` |
| Agent runtimes present | `command -v` for `claude`, `codex`, `opencode`, and the Antigravity CLI |
| Versions | each tool's own `--version`, captured verbatim |

Version strings are captured as text and not parsed into a comparison. Four vendors'
formats change independently and a brittle parser would fail closed against a working
tool; 006 handles version comparison where it is genuinely needed.

---

## 4. Evaluation

Detection produces facts. Evaluation applies 002 and produces a verdict. The order is
fixed, and each step's output feeds the next.

```
1. detect                    §3
2. floor check               002 §2.2      ── fail ⇒ exit 10
3. select profile            002 §2.1      lowest qualifying dimension
4. compute agent capacity    002 §4.2
5. evaluate matrix           002 §3        row by row
6. score health              002 §5        floor overrides band
7. build recommendations     002 §6
8. emit                      §5, §6
```

Two ordering rules carry weight:

- **The floor check precedes scoring**, per 002 §5.3. A machine below the floor is
  `Insufficient` whatever it scores.
- **Profile selection precedes matrix evaluation**, because matrix rows carry a minimum
  profile. Evaluating rows first would enable features the profile forbids.

### 4.1 Threshold source

Every value in steps 2–7 comes from 002. The implementation loads them from a data file
generated from 002's tables rather than embedding literals, so that changing a threshold
is a change to 002 alone.

Divergence is caught at two points, deliberately:

| Point | Catches | Mechanism |
|---|---|---|
| **Load time**, every run | The data file does not correspond to the current 002 | The file carries a stamp — 002's content hash and spec revision — that discovery verifies before evaluating. Mismatch ⇒ exit `30`. |
| **CI**, on change | A stamp regenerated without the values actually matching | V-05 compares each entry against 002's tables |

The load-time stamp is what makes drift a Stage 0 refusal rather than something only CI
notices. Without it, a well-formed but stale file would evaluate silently — the exact
failure D-201 exists to prevent.

---

## 5. Machine-Readable Output

Written to `--json` (default `discovery.json`). Consumed by the platform manifest (006)
and by bootstrap.

```json
{
  "schema_version": "1.0",
  "generated_at": "2026-09-07T12:00:00Z",
  "privileged": false,
  "detected": {
    "cpu":     { "model": "…", "cores": 8, "threads": 16,
                 "virtualization": true, "hypervisor": "none",
                 "socket": "unknown" },
    "memory":  { "total_gb": 31.2, "available_gb": 28.9,
                 "slots_total": "unknown", "slots_populated": "unknown",
                 "max_supported_gb": "unknown" },
    "gpu":     { "present": true, "model": "…", "vram_gb": 12,
                 "driver": "…", "runtime": "cuda", "usable": true },
    "storage": [ { "device": "nvme0n1", "class": "nvme",
                   "size_gb": 1000, "free_gb": 812 } ],
    "network": { "interfaces": [ { "name": "eno1", "speed_mbps": 1000 } ],
                 "tailscale_present": false },
    "os":      { "id": "ubuntu", "version": "24.04", "lts": true,
                 "kernel": "…" },
    "toolchain": { "docker": "…", "git": "…", "claude": null }
  },
  "evaluated": {
    "floor_passed": true,
    "profile": "mid",
    "binding_dimension": "cpu",
    "agent_capacity": 8,
    "health": { "score": 71, "band": "capable",
                "dimensions": { "ram": 75, "cpu": 75, "storage": 100,
                                "gpu": 75, "software": 100, "network": 50 } },
    "features": {
      "enabled":  ["F-01", "F-02", "…"],
      "disabled": [ { "id": "F-10", "failed": "vram_gb",
                      "required": 20, "detected": 12 } ]
    },
    "recommendations": [
      { "upgrade": "cpu_threads_16", "tier": "recommended",
        "binding_dimension": "cpu", "next_binding": "ram",
        "rationale": "Raises the agents_cpu ceiling from 8 to …",
        "feasible": "unknown" }
    ]
  }
}
```

### 5.1 Schema rules

- **`unknown` is a value, never an omission.** A field absent because detection failed and
  a field absent because the schema changed must not look alike to 006.
- **Every disabled feature names the requirement it failed**, with required and detected
  values. "Disabled" without a reason is not a valid entry.
- **`schema_version` is mandatory** and bumps on any breaking shape change.
- **Raw detected facts and derived verdicts stay separate.** `detected` is reproducible
  from the machine; `evaluated` is reproducible from `detected` plus 002. Mixing them
  makes it impossible to re-evaluate an old capture against revised thresholds.

---

## 6. Human-Readable Report

Written to `--report`, printed to stdout unless `--quiet`. This is what gets pasted into
[002 §7.1](002-Hardware-Assessment.md#71-discovery-output).

Sections, in the order 003 §5.6 requires:

1. **Detected specification** — the §3 facts.
2. **Selected profile** — and the specific dimension that determined it.
3. **Enabled / disabled features** — each disabled entry paired with its failed
   requirement.
4. **Upgrade recommendations** — tier, binding dimension, rationale, feasibility.
5. **Health score** — with per-dimension scores and the arithmetic, per 002 §5.4.
6. **Next steps** — the concrete actions the report implies.

### 6.1 Capability language

Findings are stated as capability, not as inventory. This is G4 made concrete, and it is
the difference between a report and a spec sheet:

| Not this | This |
|---|---|
| `RAM: 16 GB` | `16 GB — supports 4 concurrent agents` |
| `F-07: disabled` | `Local embeddings disabled — needs 32 GB, detected 16 GB` |
| `Add RAM` | `32 GB doubles capacity 4 → 8 and unlocks local embeddings — 2 of 4 slots free` |

### 6.2 Reporting rules

- The health score never appears without its derivation (002 §5.4).
- Every recommendation names its binding dimension and what binds next (002 §6.2), so the
  report cannot recommend RAM to a core-bound machine without saying so.
- A recommendation whose feasibility is `unknown` says why — and that `--privileged`
  resolves it.

---

## 7. Manifest Interaction

Per [003 §6.1](003-Core-Architecture-Specification.md#61-purpose), discovery and bootstrap
both read and write the manifest.

| Direction | Fields |
|---|---|
| Discovery **writes** | `hardware_profile` (profile, detected facts, timestamp), feature eligibility |
| Discovery **reads** | Previous `hardware_profile` — to detect hardware change since last run |
| Discovery never touches | `agents`, `runtimes`, `tools`, `notifications`, `autonomy`, `repositories` |

### 7.1 Change detection

A change is **material** when it crosses a 002 threshold — that is, when it changes the
selected profile, the agent capacity, or any row of the enabled-feature set. Facts that
move without crossing a threshold (a firmware bump, free space changing) update the stored
values without raising a flag.

On a material change discovery flags it rather than silently overwriting. A profile that
drops — RAM removed, a GPU pulled — may leave installed components unsupported, and that is
a decision for bootstrap, not a side effect of a read-only probe.

### 7.2 Staleness

A discovery result older than the current run is never reused. This follows directly from
003 §5.1: discovery is Stage 0 of *every* run, not a cached artifact. The stored profile
exists for change detection (§7.1), not as a substitute for running.

---

## 8. Failure Modes

| Condition | Behaviour |
|---|---|
| `/proc/meminfo` unreadable | Exit `20`. RAM is required; no verdict is possible without it. |
| `lscpu` absent | Fall back to `/proc/cpuinfo`. Exit `20` only if both fail. |
| `dmidecode` absent or unprivileged | Slot facts `unknown`; feasibility `unknown`; run continues. |
| GPU present, no compute runtime | `usable: false`; local-inference features disabled; stated in the report. |
| Running in a VM or container | Report normally, flagged. Memory may be balloonable and the figure not durable. |
| Threshold data missing, malformed, or stamp mismatch | Exit `30`. Distinct from `20`: a configuration error, not a hardware verdict. |
| Below platform floor | Exit `10` with shortfall and required upgrades. |

The governing rule: **degrade to `unknown`, never to a guess.** An invented feasibility or
an assumed VRAM figure produces a capability claim the machine cannot honour, which is
worse than admitting the gap.

---

## 9. Validation

Owned by the validation pillar (003 §10.1); listed here as this document's acceptance
criteria.

| # | Check |
|---|---|
| V-01 | Two consecutive runs on unchanged hardware differ only in `generated_at` |
| V-02 | No filesystem write outside the declared output paths (verified under trace) |
| V-03 | No network syscall during a run |
| V-04 | Synthetic below-floor input yields exit `10`, not a `lightweight` verdict |
| V-05 | Every threshold in the data file matches the corresponding 002 table value |
| V-06 | Unprivileged run completes with slot facts `unknown` and feasibility `unknown` |
| V-07 | Every `disabled` entry carries `failed`, `required`, and `detected` |
| V-08 | `evaluated` is reproducible from `detected` + 002 thresholds alone |
| V-09 | Emitted JSON validates against the §5 schema |
| V-10 | 002 §4.3 worked values are reproduced from synthetic inputs |

V-05 and V-08 are the anti-drift checks: together they make it impossible for the tool to
hold a threshold 002 does not, or to reach a verdict that cannot be re-derived.

---

## 10. Definition of Done

- [x] Ownership boundary with 002 stated (§1.1)
- [x] Execution contract, exit codes, privilege model defined (§2)
- [x] Detection method with fallback for every 003 §5.2 fact (§3)
- [x] Evaluation order fixed and justified (§4)
- [x] Machine-readable schema defined (§5)
- [x] Human-readable report contract defined (§6)
- [x] Manifest read/write boundary defined (§7)
- [x] Failure modes enumerated (§8)
- [x] Validation checks defined (§9)
- [ ] Implementation written and V-01…V-10 passing
- [ ] Run on the target machine; 002 §7 populated
- [ ] Design review checklist passed (pending 009)

---

## 11. Decision Log

| # | Decision | Alternatives | Rationale | Trade-offs | Revisit when |
|---|---|---|---|---|---|
| D-201 | 004 holds no thresholds; all values load from 002 | Embed thresholds in the script | A hardcoded threshold silently becomes the real matrix (002 D-107) | Needs a generation-and-check step between 002 and the data file | — |
| D-201a | Threshold data file carries a 002 content stamp, verified at load | Trust the file; catch divergence in CI only | A stale but well-formed file would evaluate silently, which is the drift D-201 prevents | Regenerating 002 requires regenerating the stamp | A single source removes the file entirely |
| D-202 | Zero-dependency, base-system-only implementation | Python with a package for detection | Discovery runs before anything is installed; it cannot depend on what it gates | Harder to write and test than a Python implementation | The floor guarantees an interpreter and libraries |
| D-203 | Classify storage by bus and rotational flag; benchmark opt-in | Always measure throughput | Measuring writes data, breaking the read-only guarantee, and class is the distinction 002 turns on | Class-derived throughput is an estimate | A threshold needs a real IOPS figure |
| D-204 | Unprivileged by default; DMI facts degrade to `unknown` | Require root; or silently escalate | Silent escalation violates P4; guessing feasibility violates G4 | Feasibility needs a second, privileged run | A rootless source for DMI data exists |
| D-205 | No network calls at any point | Test reachability during discovery | Keeps results deterministic and keeps a hardware inventory on the machine | Reachability is validated later, separately | — |
| D-206 | `unknown` is an explicit value, never an omission | Omit undetectable fields | 006 must distinguish "detection failed" from "schema changed" | Slightly larger output | — |
| D-207 | Separate `detected` from `evaluated` in output | One flat result object | Lets an old capture be re-evaluated against revised thresholds | Some duplication between sections | — |
| D-208 | Capture tool versions as opaque strings | Parse into comparable versions | Four vendors' formats change independently; a brittle parser fails closed against a working tool | No version comparison at discovery time | 006 needs comparison and a stable format exists |
| D-209 | Exit `10` (below floor) distinct from `20` (detection failed) | One non-zero failure code | They need different responses: a hardware verdict versus a tooling problem | One more code for callers to handle | — |
| D-210 | Discovery never reuses a prior result | Cache with a TTL | 003 §5.1 makes discovery Stage 0 of every run; a cache would reintroduce the report model it replaced | Repeated cost on every install step | Discovery cost becomes material (003 D-002) |

---

## 12. Open Questions

1. **Threshold data file format and generation.** Generated from 002's tables by what —
   a script, or hand-maintained with V-05 as the guard?
2. **Antigravity CLI binary name.** §3.6 probes `command -v`; the actual executable name
   is unconfirmed.
3. **Agent runtime detection beyond presence.** Is authentication state in scope for
   discovery, or for the validation pillar?
4. **Storage scope.** §3.4 and the §5 schema report every block device, and the free-space
   fact is measured on the platform root. Should *evaluation* follow the root device, or
   aggregate across mounted volumes? Detection already covers both; only the evaluation
   rule is open.
5. **VM handling.** A hypervisor is flagged (§3.1) but not gated. Should ballooning memory
   cap the profile, given that `MemTotal` may not be durable?
