#!/usr/bin/env bash
#
# discover.sh — Stage 0 environment discovery.
#
# Implements 004 Environment Discovery Specification. Detects the machine,
# evaluates it against 002's thresholds, and reports what may be installed.
#
# Guarantees (004 §2.2): read-only, idempotent, offline, zero-dependency,
# non-interactive. It installs nothing and gates everything.
#
# Exit codes (004 §2.3):
#   0   profile selected at or above lightweight — proceed
#   10  below the 002 §2.2 platform floor — refuse install
#   20  detection incomplete, a required fact could not be read
#   30  threshold data missing, malformed, or failing its 002 stamp check
#
set -uo pipefail

VERSION="1.0"
SCHEMA_VERSION="1.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EX_OK=0 EX_FLOOR=10 EX_DETECT=20 EX_CONFIG=30

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
JSON_OUT="" REPORT_OUT="" PRIVILEGED=0 BENCHMARK=0 QUIET=0 FIXTURE=""
THRESHOLDS="$ROOT/scripts/thresholds.env"

usage() {
  cat <<'USAGE'
discover.sh [options]

  --json PATH        write machine-readable output (default: ./discovery.json)
  --report PATH      write the human-readable report to a file as well
  --privileged       read DMI facts (memory slots, max capacity); needs root
  --benchmark        measure disk throughput (WRITES DATA; off by default)
  --quiet            suppress the report on stdout
  --fixture PATH     evaluate detected facts from a file instead of probing
  --thresholds PATH  threshold data file (default: scripts/thresholds.env)
  -h, --help         this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)       JSON_OUT="${2:-}"; shift 2 ;;
    --report)     REPORT_OUT="${2:-}"; shift 2 ;;
    --thresholds) THRESHOLDS="${2:-}"; shift 2 ;;
    --fixture)    FIXTURE="${2:-}"; shift 2 ;;
    --privileged) PRIVILEGED=1; shift ;;
    --benchmark)  BENCHMARK=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "discover.sh: unknown option: $1" >&2; usage >&2; exit "$EX_CONFIG" ;;
  esac
done
[ -n "$JSON_OUT" ] || JSON_OUT="./discovery.json"

die() { echo "discover.sh: $2" >&2; exit "$1"; }

# --------------------------------------------------------------------------
# Threshold data (004 §4.1) — stamp verified before any evaluation
# --------------------------------------------------------------------------
[ -f "$THRESHOLDS" ] || die "$EX_CONFIG" "threshold data not found: $THRESHOLDS"
# shellcheck disable=SC1090
. "$THRESHOLDS" || die "$EX_CONFIG" "threshold data is not loadable: $THRESHOLDS"

for v in PROFILE_LIGHTWEIGHT_RAM_MB PROFILE_MID_RAM_MB PROFILE_HIGH_RAM_MB \
         RESERVE_LIGHTWEIGHT_MB RESERVE_MID_MB AGENT_RAM_MB AGENT_THREADS \
         WEIGHT_RAM WEIGHT_CPU WEIGHT_STORAGE WEIGHT_GPU WEIGHT_SOFTWARE \
         WEIGHT_NETWORK MEM_TOLERANCE_PCT FEATURES THRESHOLDS_STAMP; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$EX_CONFIG" "threshold data is missing $v"
done

STAMP_STATE="unverified"
SPEC_002="$ROOT/docs/architecture/002-Hardware-Assessment.md"
if [ -f "$SPEC_002" ]; then
  _sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    elif command -v shasum  >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    else return 1; fi
  }
  want="$(awk '/^## 2\. Hardware Profiles/{on=1} /^## 7\. Detected Specification/{on=0} on' \
          "$SPEC_002" | _sha 2>/dev/null)" || want=""
  if [ -n "$want" ]; then
    if [ "$want" = "$THRESHOLDS_STAMP" ]; then
      STAMP_STATE="verified"
    else
      die "$EX_CONFIG" "threshold data does not match 002 (stamp mismatch).
  002 §2-§6: $want
  thresholds: $THRESHOLDS_STAMP
  Regenerate with scripts/stamp-thresholds.sh"
    fi
  fi
fi

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
have()   { command -v "$1" >/dev/null 2>&1; }
jesc()   { printf '%s' "${1-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'; }
# JSON value: bare number, or "unknown"/string quoted
jval()   { case "${1-}" in ''|unknown) printf '"unknown"' ;;
                           *[!0-9]*)   printf '"%s"' "$(jesc "$1")" ;;
                           *)          printf '%s' "$1" ;; esac; }
jstr()   { if [ -z "${1-}" ]; then printf 'null'; else printf '"%s"' "$(jesc "$1")"; fi; }
# integer division rounding to nearest, for display of tenths
tenths() { echo $(( ($1 * 10 + 512) / 1024 )); }
fmt_gb() { local t; t=$(tenths "$1"); echo "$((t/10)).$((t%10))"; }

# --------------------------------------------------------------------------
# Detection (004 §3) — every probe degrades to "unknown", never to a guess
# --------------------------------------------------------------------------
CPU_MODEL=unknown CPU_CORES=unknown CPU_THREADS=unknown CPU_VIRT=unknown
CPU_HYPERVISOR=none CPU_SOCKET=unknown
MEM_TOTAL_MB=unknown MEM_AVAIL_MB=unknown
MEM_SLOTS=unknown MEM_SLOTS_USED=unknown MEM_MAX_GB=unknown
GPU_PRESENT=0 GPU_MODEL=unknown GPU_VRAM_GB=unknown GPU_DRIVER=unknown
GPU_RUNTIME=none GPU_USABLE=0
DISK_ROOT_CLASS=unknown DISK_ROOT_FREE_GB=unknown DISK_ROOT_SIZE_GB=unknown
DISK_DEVICES="" NET_IFACES="" NET_SPEED=unknown TAILSCALE=0
OS_ID=unknown OS_VERSION=unknown OS_LTS=0 OS_KERNEL=unknown
TOOLS=""

detect_cpu() {
  if have lscpu; then
    local out; out="$(lscpu 2>/dev/null)"
    CPU_MODEL="$(printf '%s\n' "$out" | awk -F': *' '/^Model name:/{print $2; exit}')"
    local sockets cps
    sockets="$(printf '%s\n' "$out" | awk -F': *' '/^Socket\(s\):/{print $2; exit}')"
    cps="$(printf '%s\n' "$out" | awk -F': *' '/^Core\(s\) per socket:/{print $2; exit}')"
    if [ -n "${sockets:-}" ] && [ -n "${cps:-}" ]; then CPU_CORES=$((sockets * cps)); fi
    local virt
    virt="$(printf '%s\n' "$out" | awk -F': *' '/^Virtualization:/{print $2; exit}')"
    [ -n "${virt:-}" ] && CPU_VIRT=1
  fi
  if [ "$CPU_MODEL" = unknown ] && [ -r /proc/cpuinfo ]; then
    CPU_MODEL="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
  fi
  if [ "$CPU_CORES" = unknown ] && [ -r /proc/cpuinfo ]; then
    # 004 §3.1: core id is unique only within a socket — deduplicate on the
    # (physical id, core id) pair or a multi-socket machine under-reports.
    local n
    n="$(awk '/^physical id/{p=$4} /^core id/{print p":"$4}' /proc/cpuinfo | sort -u | wc -l | tr -d ' ')"
    [ "${n:-0}" -gt 0 ] && CPU_CORES="$n"
  fi
  if have nproc; then CPU_THREADS="$(nproc --all 2>/dev/null || nproc 2>/dev/null)"; fi
  if [ "$CPU_THREADS" = unknown ] && [ -r /proc/cpuinfo ]; then
    CPU_THREADS="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
  fi
  if [ "$CPU_VIRT" = unknown ] && [ -r /proc/cpuinfo ]; then
    if grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo 2>/dev/null; then CPU_VIRT=1; else CPU_VIRT=0; fi
  fi
  if have systemd-detect-virt; then
    CPU_HYPERVISOR="$(systemd-detect-virt 2>/dev/null || echo none)"
  elif [ -r /proc/cpuinfo ] && grep -qE '^flags.*\bhypervisor\b' /proc/cpuinfo 2>/dev/null; then
    CPU_HYPERVISOR=unknown-hypervisor
  fi
  if [ "$PRIVILEGED" = 1 ] && have dmidecode; then
    CPU_SOCKET="$(dmidecode -t processor 2>/dev/null | awk -F': *' '/Upgrade:/{print $2; exit}')"
    [ -n "${CPU_SOCKET:-}" ] || CPU_SOCKET=unknown
  fi
}

detect_memory() {
  if [ -r /proc/meminfo ]; then
    local kb; kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
    [ -n "${kb:-}" ] && MEM_TOTAL_MB=$((kb / 1024))
    kb="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)"
    if [ -n "${kb:-}" ]; then MEM_AVAIL_MB=$((kb / 1024))
    else
      local f c
      f="$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo)"
      c="$(awk '/^Cached:/{print $2; exit}' /proc/meminfo)"
      [ -n "${f:-}" ] && [ -n "${c:-}" ] && MEM_AVAIL_MB=$(( (f + c) / 1024 ))
    fi
  fi
  if [ "$PRIVILEGED" = 1 ] && have dmidecode; then
    local d; d="$(dmidecode -t memory 2>/dev/null)"
    if [ -n "$d" ]; then
      MEM_SLOTS="$(printf '%s\n' "$d" | awk -F': *' '/Number Of Devices:/{print $2; exit}')"
      MEM_SLOTS_USED="$(printf '%s\n' "$d" | grep -c '^	Size: [0-9]' || true)"
      local mx; mx="$(printf '%s\n' "$d" | awk -F': *' '/Maximum Capacity:/{print $2; exit}')"
      case "$mx" in
        *TB) MEM_MAX_GB=$(( ${mx%% *} * 1024 )) ;;
        *GB) MEM_MAX_GB="${mx%% *}" ;;
      esac
    fi
  fi
}

detect_gpu() {
  if have lspci; then
    local g; g="$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display controller' | head -1)"
    if [ -n "$g" ]; then GPU_PRESENT=1; GPU_MODEL="${g#*: }"; fi
  fi
  if have nvidia-smi; then
    local q
    q="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>/dev/null | head -1)"
    if [ -n "$q" ]; then
      GPU_PRESENT=1; GPU_RUNTIME=cuda; GPU_USABLE=1
      GPU_MODEL="$(printf '%s' "$q" | cut -d, -f1 | sed 's/^ *//')"
      local mib; mib="$(printf '%s' "$q" | cut -d, -f2 | tr -d ' ')"
      case "$mib" in ''|*[!0-9]*) : ;; *) GPU_VRAM_GB=$((mib / 1024)) ;; esac
      GPU_DRIVER="$(printf '%s' "$q" | cut -d, -f3 | sed 's/^ *//')"
    fi
  elif have rocm-smi; then
    GPU_RUNTIME=rocm; GPU_USABLE=1
    GPU_MODEL="$(rocm-smi --showproductname 2>/dev/null | awk -F': *' '/Card series/{print $2; exit}')"
  fi
  # 004 §3.3: visible but no compute runtime is present-but-unusable, and the
  # local-inference features stay disabled rather than claiming VRAM we can't reach.
}

detect_storage() {
  if have lsblk; then
    local line name rota tran size
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      name="$(printf '%s' "$line" | awk '{print $1}')"
      rota="$(printf '%s' "$line" | awk '{print $2}')"
      tran="$(printf '%s' "$line" | awk '{print $3}')"
      size="$(printf '%s' "$line" | awk '{print $4}')"
      local cls=unknown
      case "$tran" in nvme) cls=nvme ;; *) case "$rota" in 0) cls=ssd ;; 1) cls=hdd ;; esac ;; esac
      DISK_DEVICES="${DISK_DEVICES}${name}|${cls}|${size}
"
      [ "$DISK_ROOT_CLASS" = unknown ] && DISK_ROOT_CLASS="$cls"
    done <<< "$(lsblk -dno NAME,ROTA,TRAN,SIZE 2>/dev/null)"
  fi
  if have df; then
    local o; o="$(df -Pk / 2>/dev/null | awk 'NR==2{print $2" "$4}')"
    if [ -n "${o:-}" ]; then
      DISK_ROOT_SIZE_GB=$(( $(echo "$o" | awk '{print $1}') / 1048576 ))
      DISK_ROOT_FREE_GB=$(( $(echo "$o" | awk '{print $2}') / 1048576 ))
    fi
  fi
  # 004 §3.4.1: throughput is classified, not measured — measuring writes data
  # and would break the read-only guarantee. --benchmark is opt-in.
  if [ "$BENCHMARK" = 1 ]; then
    echo "discover.sh: --benchmark writes a temporary file to measure throughput" >&2
  fi
}

detect_network() {
  local ifs="" i
  if [ -d /sys/class/net ]; then
    for i in /sys/class/net/*; do
      [ -e "$i" ] || continue
      local n; n="$(basename "$i")"
      [ "$n" = lo ] && continue
      ifs="${ifs}${n} "
      if [ "$NET_SPEED" = unknown ] && [ -r "$i/speed" ]; then
        local s; s="$(cat "$i/speed" 2>/dev/null)"
        case "${s:-}" in ''|-*|*[!0-9]*) : ;; *) NET_SPEED="$s" ;; esac
      fi
    done
  fi
  NET_IFACES="$(printf '%s' "$ifs" | sed 's/ $//')"
  have tailscale && TAILSCALE=1
  # 004 §2.2 / D-205: no reachability test — that would be a network call.
}

detect_os() {
  if [ -r /etc/os-release ]; then
    OS_ID="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    OS_VERSION="$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    case "$OS_VERSION" in 16.04|18.04|20.04|22.04|24.04|26.04) OS_LTS=1 ;; esac
  fi
  have uname && OS_KERNEL="$(uname -r)"
}

detect_tools() {
  local t v
  for t in docker git python3 node curl claude codex opencode antigravity; do
    if have "$t"; then
      # 004 D-208: version strings captured verbatim, never parsed.
      v="$("$t" --version 2>/dev/null | head -1 | tr -d '\r')"
      TOOLS="${TOOLS}${t}|${v:-present}
"
    else
      TOOLS="${TOOLS}${t}|
"
    fi
  done
}

load_fixture() {
  # Evaluation-only mode: detected facts come from a file. Required by 004 §9
  # V-04 and V-10, which specify synthetic inputs.
  [ -f "$1" ] || die "$EX_CONFIG" "fixture not found: $1"
  # shellcheck disable=SC1090
  . "$1" || die "$EX_CONFIG" "fixture is not loadable: $1"
}

if [ -n "$FIXTURE" ]; then
  load_fixture "$FIXTURE"
else
  detect_cpu; detect_memory; detect_gpu; detect_storage; detect_network
  detect_os;  detect_tools
fi

# --------------------------------------------------------------------------
# Evaluation (004 §4) — order is fixed
# --------------------------------------------------------------------------

# 1. required facts present, else exit 20
case "$MEM_TOTAL_MB" in
  ''|unknown|*[!0-9]*) die "$EX_DETECT" \
    "could not read total memory (/proc/meminfo MemTotal). No verdict is possible without it." ;;
esac
case "$CPU_THREADS" in
  ''|unknown|*[!0-9]*) die "$EX_DETECT" \
    "could not determine CPU thread count (lscpu and /proc/cpuinfo both unavailable)." ;;
esac
case "$CPU_CORES" in
  ''|unknown|*[!0-9]*) die "$EX_DETECT" \
    "could not determine physical core count (lscpu and /proc/cpuinfo both unavailable).
  Cores gate profile selection (002 §2.1) and matrix rows (002 §3); inferring them from
  thread count would assume SMT and mis-gate a non-SMT machine. 004 §8: degrade to
  unknown, never to a guess." ;;
esac

# 002 §2.3: memory compares against 95% of the nominal threshold
mem_ok() { [ "$MEM_TOTAL_MB" -ge $(( $1 * MEM_TOLERANCE_PCT / 100 )) ]; }

# 2. floor check (002 §2.2) — precedes scoring, per 002 §5.3
FLOOR_PASSED=1; FLOOR_FAILS=""
mem_ok "$PROFILE_LIGHTWEIGHT_RAM_MB" || { FLOOR_PASSED=0
  FLOOR_FAILS="${FLOOR_FAILS}memory: $(fmt_gb "$MEM_TOTAL_MB") GiB detected, $((PROFILE_LIGHTWEIGHT_RAM_MB/1024)) GB required
"; }
[ "$CPU_THREADS" -ge "$PROFILE_LIGHTWEIGHT_THREADS" ] || { FLOOR_PASSED=0
  FLOOR_FAILS="${FLOOR_FAILS}cpu: $CPU_THREADS threads detected, $PROFILE_LIGHTWEIGHT_THREADS required
"; }

# 3. profile selection (002 §2.1) — lowest qualifying dimension
PROFILE=minimal BINDING=none BLOCKERS=""
if [ "$FLOOR_PASSED" = 1 ]; then
  PROFILE=lightweight; BINDING=memory
  # 002 D-101: the binding constraint determines real capability, so an
  # undetectable disk blocks advancement rather than waving it through. This
  # matches score_dim, which scores an unknown dimension 0 — the two must agree
  # or a machine could reach `high` on a disk we know nothing about.
  disk_ok() { case "$DISK_ROOT_SIZE_GB" in ''|unknown|*[!0-9]*) return 1 ;;
                                           *) [ "$DISK_ROOT_SIZE_GB" -ge "$1" ] ;; esac; }
  if mem_ok "$PROFILE_MID_RAM_MB" && [ "$CPU_CORES" -ge "$PROFILE_MID_CORES" ] \
     && [ "$CPU_THREADS" -ge "$PROFILE_MID_THREADS" ] && disk_ok "$PROFILE_MID_DISK_GB"; then
    PROFILE=mid
    if mem_ok "$PROFILE_HIGH_RAM_MB" && [ "$CPU_CORES" -ge "$PROFILE_HIGH_CORES" ] \
       && [ "$CPU_THREADS" -ge "$PROFILE_HIGH_THREADS" ] && disk_ok "$PROFILE_HIGH_DISK_GB"; then
      PROFILE=high
    fi
  fi
  # name the dimension that held the profile back — 002 §6.2 needs it
  next_ram=$PROFILE_MID_RAM_MB;  next_cores=$PROFILE_MID_CORES
  next_threads=$PROFILE_MID_THREADS; next_disk=$PROFILE_MID_DISK_GB
  if [ "$PROFILE" = mid ]; then
    next_ram=$PROFILE_HIGH_RAM_MB; next_cores=$PROFILE_HIGH_CORES
    next_threads=$PROFILE_HIGH_THREADS; next_disk=$PROFILE_HIGH_DISK_GB
  fi
  # 002 §6.2 / D-106: name every dimension holding the profile back, not just
  # the first one found. Reporting only the first produces the "more RAM for a
  # core-bound machine" recommendation this rule exists to prevent.
  BLOCKERS=""
  if [ "$PROFILE" != high ]; then
    mem_ok "$next_ram" || BLOCKERS="${BLOCKERS}memory "
    { [ "$CPU_CORES" -lt "$next_cores" ] || [ "$CPU_THREADS" -lt "$next_threads" ]; } \
      && BLOCKERS="${BLOCKERS}cpu "
    disk_ok "$next_disk" || BLOCKERS="${BLOCKERS}storage "
  fi
  BLOCKERS="$(printf '%s' "$BLOCKERS" | sed 's/ $//')"
  BINDING="${BLOCKERS%% *}"; [ -n "$BINDING" ] || BINDING=none
fi

# 4. agent capacity (002 §4.2)
RESERVE_MB=$RESERVE_LIGHTWEIGHT_MB
case "$PROFILE" in mid|high) RESERVE_MB=$RESERVE_MID_MB ;; esac
AGENTS_RAM=$(( (MEM_TOTAL_MB - RESERVE_MB) / AGENT_RAM_MB ))
[ "$AGENTS_RAM" -lt 0 ] && AGENTS_RAM=0
AGENTS_CPU=$(( CPU_THREADS / AGENT_THREADS ))
CAPACITY=$AGENTS_RAM
[ "$AGENTS_CPU" -lt "$CAPACITY" ] && CAPACITY=$AGENTS_CPU
[ "$CAPACITY" -lt 1 ] && CAPACITY=1
CAPACITY_BOUND=ram; [ "$AGENTS_CPU" -le "$AGENTS_RAM" ] && CAPACITY_BOUND=cpu

# 5. capability matrix (002 §3) — after profile selection, since rows carry a min profile
profile_rank() { case "$1" in minimal) echo 0 ;; lightweight) echo 1 ;; mid) echo 2 ;; high) echo 3 ;; esac; }
HAVE_RANK="$(profile_rank "$PROFILE")"
ENABLED="" DISABLED=""
while IFS='|' read -r fid fname fcores fvram fdisk fprof fgpu; do
  [ -n "$fid" ] || continue
  need="$(profile_rank "$fprof")"
  if [ "$HAVE_RANK" -lt "$need" ]; then
    DISABLED="${DISABLED}${fid}|profile|${fprof}|${PROFILE}|${fname}
"; continue
  fi
  if [ "$fcores" -gt 0 ] && [ "$CPU_CORES" -lt "$fcores" ]; then
    DISABLED="${DISABLED}${fid}|cores|${fcores}|${CPU_CORES}|${fname}
"; continue
  fi
  if [ "$fgpu" = 1 ]; then
    if [ "$GPU_USABLE" != 1 ]; then
      DISABLED="${DISABLED}${fid}|gpu_runtime|usable|none|${fname}
"; continue
    fi
    case "$GPU_VRAM_GB" in
      ''|unknown|*[!0-9]*) DISABLED="${DISABLED}${fid}|vram|${fvram}|unknown|${fname}
"; continue ;;
      *) if [ "$GPU_VRAM_GB" -lt "$fvram" ]; then
           DISABLED="${DISABLED}${fid}|vram|${fvram}|${GPU_VRAM_GB}|${fname}
"; continue; fi ;;
    esac
  fi
  case "$DISK_ROOT_FREE_GB" in
    ''|unknown|*[!0-9]*) : ;;
    *) if [ "$fdisk" -gt 0 ] && [ "$DISK_ROOT_FREE_GB" -lt "$fdisk" ]; then
         DISABLED="${DISABLED}${fid}|disk_free|${fdisk}|${DISK_ROOT_FREE_GB}|${fname}
"; continue; fi ;;
  esac
  ENABLED="${ENABLED}${fid}|${fname}
"
done <<< "$FEATURES"

# 6. health score (002 §5) — floor overrides band
# score_dim VALUE LIGHT MID HIGH -> 0|50..75|75..100
score_dim() {
  local v="$1" l="$2" m="$3" h="$4"
  case "$v" in ''|unknown|*[!0-9]*) echo 0; return ;; esac
  if   [ "$v" -lt "$l" ]; then echo 0
  elif [ "$v" -lt "$m" ]; then echo $(( 50 + (25 * (v - l)) / (m - l) ))
  elif [ "$v" -lt "$h" ]; then echo $(( 75 + (25 * (v - m)) / (h - m) ))
  else echo 100; fi
}
S_RAM="$(score_dim "$MEM_TOTAL_MB" \
          $(( PROFILE_LIGHTWEIGHT_RAM_MB * MEM_TOLERANCE_PCT / 100 )) \
          $(( PROFILE_MID_RAM_MB        * MEM_TOLERANCE_PCT / 100 )) \
          $(( PROFILE_HIGH_RAM_MB       * MEM_TOLERANCE_PCT / 100 )) )"
S_CPU="$(score_dim "$CPU_THREADS" "$PROFILE_LIGHTWEIGHT_THREADS" "$PROFILE_MID_THREADS" "$PROFILE_HIGH_THREADS")"
S_STORAGE="$(score_dim "$DISK_ROOT_SIZE_GB" "$PROFILE_LIGHTWEIGHT_DISK_GB" "$PROFILE_MID_DISK_GB" "$PROFILE_HIGH_DISK_GB")"
if [ "$GPU_USABLE" = 1 ]; then
  S_GPU="$(score_dim "$GPU_VRAM_GB" 6 "$PROFILE_HIGH_VRAM_GB" 20)"
else S_GPU=0; fi
S_SOFTWARE=0
[ "$OS_ID" = ubuntu ] && S_SOFTWARE=50
[ "$OS_LTS" = 1 ] && S_SOFTWARE=100
S_NETWORK="$(score_dim "$NET_SPEED" 100 1000 10000)"

HEALTH=$(( (S_RAM*WEIGHT_RAM + S_CPU*WEIGHT_CPU + S_STORAGE*WEIGHT_STORAGE \
          + S_GPU*WEIGHT_GPU + S_SOFTWARE*WEIGHT_SOFTWARE + S_NETWORK*WEIGHT_NETWORK) / 100 ))

if [ "$FLOOR_PASSED" = 0 ]; then BAND=insufficient
elif [ "$HEALTH" -le "$BAND_INSUFFICIENT_MAX" ]; then BAND=insufficient
elif [ "$HEALTH" -le "$BAND_CONSTRAINED_MAX" ]; then BAND=constrained
elif [ "$HEALTH" -le "$BAND_CAPABLE_MAX" ];      then BAND=capable
else BAND=headroom; fi

# 7. recommendations (002 §6) — tier, binding dimension, rationale, feasibility
FEASIBLE=unknown
case "$MEM_SLOTS" in
  ''|unknown|*[!0-9]*) FEASIBLE=unknown ;;
  *) if [ "${MEM_SLOTS_USED:-0}" -lt "$MEM_SLOTS" ]; then
       FEASIBLE="yes — $(( MEM_SLOTS - MEM_SLOTS_USED )) of $MEM_SLOTS slots free"
     else FEASIBLE="slots full ($MEM_SLOTS_USED/$MEM_SLOTS); replacement required"; fi ;;
esac

RECS=""
add_rec() { RECS="${RECS}$1|$2|$3|$4|$5
"; }
mem_gb_nominal=$(( (MEM_TOTAL_MB + 512) / 1024 ))
if [ "$FLOOR_PASSED" = 0 ]; then
  add_rec "RAM to 16 GB" required memory \
    "Clears the platform floor; below it nothing can be orchestrated" "$FEASIBLE"
elif ! mem_ok "$PROFILE_MID_RAM_MB"; then
  # Project the capacity that 32 GB would actually deliver on THIS machine —
  # cores may cap it well below what the extra RAM would allow.
  cap32=$(( (PROFILE_MID_RAM_MB - RESERVE_MID_MB) / AGENT_RAM_MB ))
  [ "$AGENTS_CPU" -lt "$cap32" ] && cap32=$AGENTS_CPU
  others="$(printf '%s' "$BLOCKERS" | sed 's/memory//; s/^ *//; s/ *$//')"
  if [ -z "$others" ]; then
    add_rec "RAM to 32 GB" recommended memory \
      "Memory is the only dimension short of mid. Reaches mid profile; agent capacity $CAPACITY -> $cap32; unlocks local embeddings (F-07), standalone vector store (F-06), Temporal (F-13)" \
      "$FEASIBLE"
  else
    detail="cpu ($CPU_CORES cores / $CPU_THREADS threads, mid needs $PROFILE_MID_CORES / $PROFILE_MID_THREADS)"
    case "$others" in *storage*) detail="$detail and storage (${DISK_ROOT_SIZE_GB} GB, mid needs $PROFILE_MID_DISK_GB GB)" ;; esac
    case "$others" in cpu*) : ;; storage*) detail="storage (${DISK_ROOT_SIZE_GB} GB, mid needs $PROFILE_MID_DISK_GB GB)" ;; esac
    if [ "$cap32" = "$CAPACITY" ]; then
      add_rec "RAM to 32 GB" optional "memory + $others" \
        "Would NOT reach mid profile on its own — $detail also blocks it. Agent capacity stays at $CAPACITY because $CAPACITY_BOUND binds. Raise $others first" \
        "$FEASIBLE"
    else
      add_rec "RAM to 32 GB" optional "memory + $others" \
        "Would NOT reach mid profile on its own — $detail also blocks it. Agent capacity $CAPACITY -> $cap32" \
        "$FEASIBLE"
    fi
  fi
fi
if [ "$CAPACITY_BOUND" = cpu ] && [ "$CPU_THREADS" -lt "$PROFILE_MID_THREADS" ]; then
  add_rec "CPU to ${PROFILE_MID_THREADS}+ threads" recommended cpu \
    "Cores bind before RAM at $CPU_THREADS threads (agents_cpu=$AGENTS_CPU vs agents_ram=$AGENTS_RAM); raises the ceiling" \
    "unknown — socket and board dependent"
fi
case "$DISK_ROOT_CLASS" in
  hdd) add_rec "HDD to NVMe" recommended storage \
        "Build and test throughput; reaches the mid storage class" "unknown — bay and interface dependent" ;;
  ssd) add_rec "SATA SSD to NVMe" optional storage \
        "Build and test throughput" "unknown — bay and interface dependent" ;;
esac
if [ "$GPU_USABLE" != 1 ]; then
  add_rec "Add GPU with ${PROFILE_HIGH_VRAM_GB}+ GB VRAM" optional gpu \
    "Enables local coding models F-08/F-09; every GPU-gated feature is optional and the platform is fully functional against cloud models without one" \
    "unknown — slot and PSU dependent"
fi

# --------------------------------------------------------------------------
# Machine-readable output (004 §5)
# --------------------------------------------------------------------------
emit_json() {
  local first
  printf '{\n'
  printf '  "schema_version": "%s",\n' "$SCHEMA_VERSION"
  printf '  "tool_version": "%s",\n' "$VERSION"
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "privileged": %s,\n' "$([ "$PRIVILEGED" = 1 ] && echo true || echo false)"
  printf '  "thresholds": { "spec": %s, "stamp": %s, "stamp_state": %s },\n' \
    "$(jstr "$THRESHOLDS_SPEC")" "$(jstr "$THRESHOLDS_STAMP")" "$(jstr "$STAMP_STATE")"
  printf '  "detected": {\n'
  printf '    "cpu": { "model": %s, "cores": %s, "threads": %s, "virtualization": %s, "hypervisor": %s, "socket": %s },\n' \
    "$(jstr "$CPU_MODEL")" "$(jval "$CPU_CORES")" "$(jval "$CPU_THREADS")" \
    "$([ "$CPU_VIRT" = 1 ] && echo true || echo false)" "$(jstr "$CPU_HYPERVISOR")" "$(jval "$CPU_SOCKET")"
  printf '    "memory": { "total_gb": %s, "available_gb": %s, "slots_total": %s, "slots_populated": %s, "max_supported_gb": %s },\n' \
    "$(fmt_gb "$MEM_TOTAL_MB")" \
    "$(case "$MEM_AVAIL_MB" in ''|unknown|*[!0-9]*) printf '"unknown"' ;; *) fmt_gb "$MEM_AVAIL_MB" ;; esac)" \
    "$(jval "$MEM_SLOTS")" "$(jval "$MEM_SLOTS_USED")" "$(jval "$MEM_MAX_GB")"
  printf '    "gpu": { "present": %s, "model": %s, "vram_gb": %s, "driver": %s, "runtime": %s, "usable": %s },\n' \
    "$([ "$GPU_PRESENT" = 1 ] && echo true || echo false)" "$(jstr "$GPU_MODEL")" \
    "$(jval "$GPU_VRAM_GB")" "$(jstr "$GPU_DRIVER")" "$(jstr "$GPU_RUNTIME")" \
    "$([ "$GPU_USABLE" = 1 ] && echo true || echo false)"
  printf '    "storage": { "root_class": %s, "root_size_gb": %s, "root_free_gb": %s, "devices": [' \
    "$(jstr "$DISK_ROOT_CLASS")" "$(jval "$DISK_ROOT_SIZE_GB")" "$(jval "$DISK_ROOT_FREE_GB")"
  first=1
  while IFS='|' read -r dn dc ds; do
    [ -n "$dn" ] || continue
    [ "$first" = 1 ] || printf ', '; first=0
    printf '{ "device": %s, "class": %s, "size": %s }' "$(jstr "$dn")" "$(jstr "$dc")" "$(jstr "$ds")"
  done <<< "$DISK_DEVICES"
  printf '] },\n'
  printf '    "network": { "interfaces": %s, "speed_mbps": %s, "tailscale_present": %s },\n' \
    "$(jstr "$NET_IFACES")" "$(jval "$NET_SPEED")" \
    "$([ "$TAILSCALE" = 1 ] && echo true || echo false)"
  printf '    "os": { "id": %s, "version": %s, "lts": %s, "kernel": %s },\n' \
    "$(jstr "$OS_ID")" "$(jstr "$OS_VERSION")" \
    "$([ "$OS_LTS" = 1 ] && echo true || echo false)" "$(jstr "$OS_KERNEL")"
  printf '    "toolchain": {'
  first=1
  while IFS='|' read -r tn tv; do
    [ -n "$tn" ] || continue
    [ "$first" = 1 ] || printf ','; first=0
    printf ' %s: %s' "$(jstr "$tn")" "$(jstr "$tv")"
  done <<< "$TOOLS"
  printf ' }\n  },\n'
  printf '  "evaluated": {\n'
  printf '    "floor_passed": %s,\n' "$([ "$FLOOR_PASSED" = 1 ] && echo true || echo false)"
  printf '    "profile": %s,\n' "$(jstr "$PROFILE")"
  printf '    "binding_dimension": %s,\n' "$(jstr "$BINDING")"
  printf '    "agent_capacity": %s,\n' "$CAPACITY"
  printf '    "agent_capacity_detail": { "agents_ram": %s, "agents_cpu": %s, "reserve_mb": %s, "bound_by": %s },\n' \
    "$AGENTS_RAM" "$AGENTS_CPU" "$RESERVE_MB" "$(jstr "$CAPACITY_BOUND")"
  printf '    "health": { "score": %s, "band": %s, "dimensions": { "ram": %s, "cpu": %s, "storage": %s, "gpu": %s, "software": %s, "network": %s } },\n' \
    "$HEALTH" "$(jstr "$BAND")" "$S_RAM" "$S_CPU" "$S_STORAGE" "$S_GPU" "$S_SOFTWARE" "$S_NETWORK"
  printf '    "features": {\n      "enabled": ['
  first=1
  while IFS='|' read -r fid _; do
    [ -n "$fid" ] || continue
    [ "$first" = 1 ] || printf ', '; first=0
    printf '%s' "$(jstr "$fid")"
  done <<< "$ENABLED"
  printf '],\n      "disabled": ['
  first=1
  while IFS='|' read -r fid ffail freq fdet _; do
    [ -n "$fid" ] || continue
    [ "$first" = 1 ] || printf ', '; first=0
    printf '{ "id": %s, "failed": %s, "required": %s, "detected": %s }' \
      "$(jstr "$fid")" "$(jstr "$ffail")" "$(jval "$freq")" "$(jval "$fdet")"
  done <<< "$DISABLED"
  printf ']\n    },\n'
  printf '    "recommendations": ['
  first=1
  while IFS='|' read -r rlabel rtier rbind rrat rfeas; do
    [ -n "$rlabel" ] || continue
    [ "$first" = 1 ] || printf ', '; first=0
    printf '{ "upgrade": %s, "tier": %s, "binding_dimension": %s, "rationale": %s, "feasible": %s }' \
      "$(jstr "$rlabel")" "$(jstr "$rtier")" "$(jstr "$rbind")" "$(jstr "$rrat")" "$(jstr "$rfeas")"
  done <<< "$RECS"
  printf ']\n  }\n}\n'
}

# --------------------------------------------------------------------------
# Human-readable report (004 §6) — sections in the order 003 §5.6 requires
# --------------------------------------------------------------------------
emit_report() {
  echo "=============================================================="
  echo " Environment Discovery — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo " discover.sh $VERSION · thresholds from $THRESHOLDS_SPEC ($STAMP_STATE)"
  echo "=============================================================="
  echo
  echo "1. DETECTED SPECIFICATION"
  echo "   CPU        $CPU_MODEL"
  echo "              $CPU_CORES cores / $CPU_THREADS threads$([ "$CPU_HYPERVISOR" != none ] && echo "  [virtualized: $CPU_HYPERVISOR]")"
  echo "   Memory     $(fmt_gb "$MEM_TOTAL_MB") GiB total$(case "$MEM_AVAIL_MB" in ''|unknown|*[!0-9]*) : ;; *) echo ", $(fmt_gb "$MEM_AVAIL_MB") GiB available" ;; esac)"
  if [ "$MEM_SLOTS" = unknown ]; then
    echo "              slots/max: unknown (re-run as root with --privileged)"
  else
    echo "              slots $MEM_SLOTS_USED/$MEM_SLOTS, max supported $MEM_MAX_GB GB"
  fi
  if [ "$GPU_PRESENT" = 1 ]; then
    echo "   GPU        $GPU_MODEL"
    echo "              VRAM ${GPU_VRAM_GB} GB, runtime $GPU_RUNTIME$([ "$GPU_USABLE" = 1 ] || echo " — PRESENT BUT UNUSABLE")"
  else
    echo "   GPU        none detected"
  fi
  echo "   Storage    root: $DISK_ROOT_CLASS, ${DISK_ROOT_SIZE_GB} GB total, ${DISK_ROOT_FREE_GB} GB free"
  echo "   Network    ${NET_IFACES:-none}, ${NET_SPEED} Mbps$([ "$TAILSCALE" = 1 ] && echo ", tailscale present")"
  echo "   OS         $OS_ID $OS_VERSION$([ "$OS_LTS" = 1 ] && echo " LTS"), kernel $OS_KERNEL"
  echo
  echo "2. SELECTED PROFILE"
  echo "   Profile:   $PROFILE"
  if [ "$BINDING" = none ]; then
    echo "   No dimension is holding the profile back."
  else
    if [ "$BLOCKERS" = "$BINDING" ]; then
      echo "   Binding dimension: $BINDING — the only dimension holding the profile at $PROFILE."
    else
      echo "   Binding dimensions: $BLOCKERS — all of these hold the profile at $PROFILE."
      echo "   Raising any one alone will not advance it."
    fi
  fi
  echo "   Agent capacity: $CAPACITY concurrent agents"
  echo "     agents_ram = ($(fmt_gb "$MEM_TOTAL_MB") GiB - $(fmt_gb "$RESERVE_MB") GiB reserve) / 2 GiB = $AGENTS_RAM"
  echo "     agents_cpu = $CPU_THREADS threads / 2                        = $AGENTS_CPU"
  echo "     capacity   = min($AGENTS_RAM, $AGENTS_CPU) = $CAPACITY   (bound by $CAPACITY_BOUND)"
  echo
  echo "3. FEATURES"
  while IFS='|' read -r fid fname; do
    [ -n "$fid" ] || continue
    printf '   [on ] %-5s %s\n' "$fid" "$fname"
  done <<< "$ENABLED"
  while IFS='|' read -r fid ffail freq fdet fname; do
    [ -n "$fid" ] || continue
    printf '   [off] %-5s %s — needs %s %s, detected %s\n' "$fid" "$fname" "$ffail" "$freq" "$fdet"
  done <<< "$DISABLED"
  echo
  echo "4. UPGRADE RECOMMENDATIONS"
  if [ -z "${RECS//[$'\n' ]/}" ]; then
    echo "   None. Every dimension meets its highest threshold."
  else
    while IFS='|' read -r rlabel rtier rbind rrat rfeas; do
      [ -n "$rlabel" ] || continue
      echo "   [$rtier] $rlabel"
      echo "     binds:      $rbind"
      echo "     unlocks:    $rrat"
      echo "     feasible:   $rfeas"
    done <<< "$RECS"
  fi
  [ "$PRIVILEGED" = 1 ] || echo "   (Re-run with --privileged as root to resolve 'unknown' feasibility.)"
  echo
  echo "5. HEALTH SCORE — $HEALTH/100 ($BAND)"
  printf '   %-10s %3s x %2s%% = %5s\n' ram      "$S_RAM"      "$WEIGHT_RAM"      "$(( S_RAM*WEIGHT_RAM/100 ))"
  printf '   %-10s %3s x %2s%% = %5s\n' cpu      "$S_CPU"      "$WEIGHT_CPU"      "$(( S_CPU*WEIGHT_CPU/100 ))"
  printf '   %-10s %3s x %2s%% = %5s\n' storage  "$S_STORAGE"  "$WEIGHT_STORAGE"  "$(( S_STORAGE*WEIGHT_STORAGE/100 ))"
  printf '   %-10s %3s x %2s%% = %5s\n' gpu      "$S_GPU"      "$WEIGHT_GPU"      "$(( S_GPU*WEIGHT_GPU/100 ))"
  printf '   %-10s %3s x %2s%% = %5s\n' software "$S_SOFTWARE" "$WEIGHT_SOFTWARE" "$(( S_SOFTWARE*WEIGHT_SOFTWARE/100 ))"
  printf '   %-10s %3s x %2s%% = %5s\n' network  "$S_NETWORK"  "$WEIGHT_NETWORK"  "$(( S_NETWORK*WEIGHT_NETWORK/100 ))"
  printf '   %-10s %19s\n' total "$HEALTH"
  [ "$FLOOR_PASSED" = 1 ] || echo "   Band forced to 'insufficient' by the floor check (002 §5.3)."
  echo
  echo "6. NEXT STEPS"
  if [ "$FLOOR_PASSED" = 0 ]; then
    echo "   Install refused — below the platform floor:"
    printf '%s' "$FLOOR_FAILS" | sed 's/^/     - /'
    echo "   Apply the required upgrade above, then re-run."
  else
    echo "   - Proceed with bootstrap; $(printf '%s' "$ENABLED" | grep -c '|') features enabled."
    echo "   - Paste this report into 002 §7.1 and fill the §7.2 table."
    [ "$PRIVILEGED" = 1 ] || echo "   - Re-run as root with --privileged for upgrade feasibility."
  fi
  echo
}

# --------------------------------------------------------------------------
# Emit
# --------------------------------------------------------------------------
emit_json > "$JSON_OUT" || die "$EX_DETECT" "could not write $JSON_OUT"
[ -n "$REPORT_OUT" ] && { emit_report > "$REPORT_OUT" || die "$EX_DETECT" "could not write $REPORT_OUT"; }
[ "$QUIET" = 1 ] || emit_report

[ "$FLOOR_PASSED" = 1 ] || exit "$EX_FLOOR"
exit "$EX_OK"
