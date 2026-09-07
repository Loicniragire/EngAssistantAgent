#!/usr/bin/env python3
"""V-05 — every value in scripts/thresholds.env matches its 002 table.

004 D-201 makes 002 the sole owner of thresholds. The stamp (D-201a) proves the
data file corresponds to *a* version of 002; this proves the values were
transcribed correctly. Both are needed: a regenerated stamp over a mistyped
value would otherwise pass.
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
spec = (root / "docs/architecture/002-Hardware-Assessment.md").read_text()
env  = (root / "scripts/thresholds.env").read_text()

def envval(k):
    m = re.search(rf'^{k}=("?)([^"\n]*)\1', env, re.M)
    return m.group(2) if m else None

errs = []
def check(key, want, where):
    got = envval(key)
    if got is None:            errs.append(f"{key}: missing from thresholds.env")
    elif str(got) != str(want): errs.append(f"{key}: env={got} but 002 {where} says {want}")

# --- §2.1 profile table ---------------------------------------------------
rows = {}
for line in spec.splitlines():
    m = re.match(r'\|\s*`(lightweight|mid|high)`\s*\|(.+)\|', line)
    if m:
        rows[m.group(1)] = [c.strip() for c in m.group(2).split('|')]
def gb(cell):
    m = re.search(r'(\d+)\s*(GB|TB)', cell)
    if not m: return None
    return int(m.group(1)) * (1024 if m.group(2) == 'TB' else 1)
def cores(cell):
    m = re.search(r'(\d+)\s*cores', cell);  return int(m.group(1)) if m else None
def threads(cell):
    m = re.search(r'(\d+)\s*threads', cell); return int(m.group(1)) if m else None

for prof, key in (("lightweight","LIGHTWEIGHT"), ("mid","MID"), ("high","HIGH")):
    r = rows.get(prof)
    if not r: errs.append(f"§2.1 row for {prof} not found"); continue
    check(f"PROFILE_{key}_RAM_MB",  gb(r[0]) * 1024, "§2.1")
    check(f"PROFILE_{key}_CORES",   cores(r[1]),     "§2.1")
    check(f"PROFILE_{key}_THREADS", threads(r[1]),   "§2.1")
    check(f"PROFILE_{key}_DISK_GB", gb(r[3]),        "§2.1")

# --- §2.3 memory tolerance ------------------------------------------------
m = re.search(r'≥\s*0\.(\d+)\s*×\s*T', spec)
if m: check("MEM_TOLERANCE_PCT", int(m.group(1)), "§2.3")
else: errs.append("§2.3 tolerance rule not found")

# --- §4.1 reserve ---------------------------------------------------------
for label, key in (("`lightweight`", "RESERVE_LIGHTWEIGHT_MB"), ("`mid` / `high`", "RESERVE_MID_MB")):
    m = re.search(rf'\|\s*\*\*Total — {re.escape(label)}\*\*\s*\|\s*\*\*([\d.]+) GB\*\*', spec)
    if m: check(key, int(float(m.group(1)) * 1024), "§4.1")
    else: errs.append(f"§4.1 reserve row for {label} not found")

# --- §4.2 per-agent -------------------------------------------------------
if re.search(r'2 GB and 2 threads per agent', spec):
    check("AGENT_RAM_MB", 2048, "§4.2"); check("AGENT_THREADS", 2, "§4.2")
else: errs.append("§4.2 per-agent sizing sentence not found")

# --- §5.1 weights ---------------------------------------------------------
for dim, key in (("RAM","WEIGHT_RAM"), ("CPU","WEIGHT_CPU"), ("Storage","WEIGHT_STORAGE"),
                 ("GPU","WEIGHT_GPU"), ("Software currency","WEIGHT_SOFTWARE"), ("Network","WEIGHT_NETWORK")):
    m = re.search(rf'^\|\s*{re.escape(dim)}\s*\|\s*(\d+)\s*\|', spec, re.M)
    if m: check(key, int(m.group(1)), "§5.1")
    else: errs.append(f"§5.1 weight row for {dim} not found")
tot = sum(int(envval(k)) for k in ("WEIGHT_RAM","WEIGHT_CPU","WEIGHT_STORAGE",
                                   "WEIGHT_GPU","WEIGHT_SOFTWARE","WEIGHT_NETWORK"))
if tot != 100: errs.append(f"weights sum to {tot}, not 100")

# --- §3 capability matrix -------------------------------------------------
# Not just the ids: every gating column must match, or a mistyped VRAM figure
# would pass V-05 and silently mis-gate a feature (004 D-201).
m = re.search(r'FEATURES="(.*?)"\n', env, re.S)
env_rows = {}
if m:
    for line in m.group(1).strip().splitlines():
        f = line.split("|")
        if len(f) == 7:
            env_rows[f[0]] = {"cores": f[2], "vram": f[3], "disk": f[4],
                              "profile": f[5], "gpu": f[6]}
else:
    errs.append("FEATURES block not found in thresholds.env")

def num(cell):
    """A matrix cell as an integer: '20 GB' -> 20, '+2 GB' -> 2, '—' -> 0."""
    c = cell.strip()
    if c in ("—", "-", "", "negligible"): return 0
    # Only a bare number or an N GB / N TB quantity is a threshold. Anything
    # else ("2× data") is a prose requirement the matrix does not gate on.
    mm = re.fullmatch(r'\+?(\d+(?:\.\d+)?)\s*(GB|TB)?', c)
    if not mm: return None
    v = float(mm.group(1))
    return int(v * 1024) if mm.group(2) == "TB" else int(v)

spec_rows = {}
for line in spec.splitlines():
    mm = re.match(r'\|\s*(F-\d\d)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|', line)
    if mm:
        fid, _name, _ram, cores, vram, disk, prof = [g.strip() for g in mm.groups()]
        spec_rows[fid] = {"cores": cores, "vram": vram, "disk": disk, "profile": prof}

if sorted(env_rows) != sorted(spec_rows):
    errs.append(f"§3 feature ids differ: 002={sorted(spec_rows)} env={sorted(env_rows)}")

for fid in sorted(set(env_rows) & set(spec_rows)):
    e, sp = env_rows[fid], spec_rows[fid]
    for col in ("cores", "vram", "disk"):
        want = num(sp[col])
        if want is None:
            # non-numeric requirement ("2× data"); the env must encode 0 (ungated)
            if e[col] != "0":
                errs.append(f"§3 {fid} {col}: 002 says '{sp[col]}' (not a number) so env must be 0, got {e[col]}")
            continue
        if int(e[col]) != want:
            errs.append(f"§3 {fid} {col}: env={e[col]} but 002 says '{sp[col]}' ({want})")
    prof_cell = sp["profile"]
    pm = re.search(r'`(lightweight|mid|high)`', prof_cell)
    if pm:
        if e["profile"] != pm.group(1):
            errs.append(f"§3 {fid} profile: env={e['profile']} but 002 says {pm.group(1)}")
    elif "§4" not in prof_cell:
        errs.append(f"§3 {fid} profile: 002 cell '{prof_cell}' names no profile")
    want_gpu = "1" if "GPU" in prof_cell or num(sp["vram"]) else "0"
    if e["gpu"] != want_gpu:
        errs.append(f"§3 {fid} needs_gpu: env={e['gpu']} but 002 row implies {want_gpu}")

# --- §5.3 bands -----------------------------------------------------------
for rng, key in ((r'0–39', "BAND_INSUFFICIENT_MAX"), (r'40–59', "BAND_CONSTRAINED_MAX"), (r'60–79', "BAND_CAPABLE_MAX")):
    if re.search(rf'\|\s*{rng}\s*\|', spec):
        check(key, rng.split('–')[1], "§5.3")
    else: errs.append(f"§5.3 band row {rng} not found")

if errs:
    print("threshold drift from 002:", file=sys.stderr)
    for e in errs: print("  -", e, file=sys.stderr)
    sys.exit(1)
print("all thresholds match 002")
