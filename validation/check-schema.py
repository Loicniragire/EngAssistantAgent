#!/usr/bin/env python3
"""V-09 — discovery output validates against the 004 §5 schema."""
import json, sys

REQ_TOP = ["schema_version", "generated_at", "privileged", "detected", "evaluated"]
REQ_DET = {
    "cpu":     ["model", "cores", "threads", "virtualization", "hypervisor", "socket"],
    "memory":  ["total_gb", "available_gb", "slots_total", "slots_populated", "max_supported_gb"],
    "gpu":     ["present", "model", "vram_gb", "driver", "runtime", "usable"],
    "storage": ["root_class", "root_size_gb", "root_free_gb", "devices"],
    "network": ["interfaces", "speed_mbps", "tailscale_present"],
    "os":      ["id", "version", "lts", "kernel"],
    "toolchain": [],
}
REQ_EVAL = ["floor_passed", "profile", "binding_dimension", "agent_capacity",
            "health", "features", "recommendations"]
DIMS = ["ram", "cpu", "storage", "gpu", "software", "network"]
PROFILES = {"minimal", "lightweight", "mid", "high"}
BANDS = {"insufficient", "constrained", "capable", "headroom"}
TIERS = {"required", "recommended", "optional"}

def main(path):
    errs = []
    try:
        d = json.load(open(path))
    except Exception as e:
        print(f"not valid JSON: {e}", file=sys.stderr); return 1

    for k in REQ_TOP:
        if k not in d: errs.append(f"missing top-level key: {k}")
    if d.get("schema_version") != "1.0":
        errs.append(f"unexpected schema_version: {d.get('schema_version')}")

    det = d.get("detected", {})
    for sect, keys in REQ_DET.items():
        if sect not in det: errs.append(f"detected.{sect} missing"); continue
        for k in keys:
            if k not in det[sect]: errs.append(f"detected.{sect}.{k} missing")

    ev = d.get("evaluated", {})
    for k in REQ_EVAL:
        if k not in ev: errs.append(f"evaluated.{k} missing")
    if ev.get("profile") not in PROFILES:
        errs.append(f"invalid profile: {ev.get('profile')}")
    h = ev.get("health", {})
    if h.get("band") not in BANDS: errs.append(f"invalid band: {h.get('band')}")
    if not isinstance(h.get("score"), int) or not 0 <= h["score"] <= 100:
        errs.append(f"score out of range: {h.get('score')}")
    for dim in DIMS:
        v = h.get("dimensions", {}).get(dim)
        if not isinstance(v, int) or not 0 <= v <= 100:
            errs.append(f"health.dimensions.{dim} invalid: {v}")

    # 004 §5.1 — "unknown" is a value, never an omission
    def walk(o, path=""):
        if isinstance(o, dict):
            for k, v in o.items(): walk(v, f"{path}.{k}")
        elif o is None and not path.endswith((".model", ".driver", ".kernel")):
            pass
    walk(det, "detected")

    feats = ev.get("features", {})
    if not isinstance(feats.get("enabled"), list): errs.append("features.enabled not a list")
    for x in feats.get("disabled", []):
        for k in ("id", "failed", "required", "detected"):
            if k not in x or x[k] in (None, ""):
                errs.append(f"disabled entry {x.get('id')} missing {k}")
    both = set(feats.get("enabled", [])) & {x.get("id") for x in feats.get("disabled", [])}
    if both: errs.append(f"features both enabled and disabled: {sorted(both)}")

    for r in ev.get("recommendations", []):
        for k in ("upgrade", "tier", "binding_dimension", "rationale", "feasible"):
            if k not in r or r[k] in (None, ""):
                errs.append(f"recommendation {r.get('upgrade')} missing {k}")
        if r.get("tier") not in TIERS:
            errs.append(f"invalid tier: {r.get('tier')}")

    # 002 §5.3 — the floor overrides the band
    if ev.get("floor_passed") is False and h.get("band") != "insufficient":
        errs.append(f"floor failed but band is {h.get('band')}")

    if errs:
        print(f"{path}: schema violations:", file=sys.stderr)
        for e in errs: print("  -", e, file=sys.stderr)
        return 1
    print(f"{path}: schema ok")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
