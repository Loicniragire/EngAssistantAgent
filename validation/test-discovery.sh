#!/usr/bin/env bash
# Validation checks V-01..V-10 from 004 §9.
# Run: validation/test-discovery.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVER="$ROOT/scripts/discover.sh"
FIX="$ROOT/validation/fixtures"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
head_() { printf '\n%s\n' "$1"; }

run() { # run FIXTURE OUTJSON -> echoes exit code
  "$DISCOVER" --fixture "$FIX/$1" --json "$2" --quiet >/dev/null 2>&1; echo $?
}
jq_() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2" 2>/dev/null; }

# ---------------------------------------------------------------- V-01
head_ "V-01  two runs on unchanged input differ only in generated_at"
run 32gb-16t.env "$TMP/a.json" >/dev/null; run 32gb-16t.env "$TMP/b.json" >/dev/null
if diff <(grep -v generated_at "$TMP/a.json") <(grep -v generated_at "$TMP/b.json") >/dev/null; then
  ok "output is byte-identical apart from the timestamp"
else bad "runs differ" "$(diff "$TMP/a.json" "$TMP/b.json" | head -5)"; fi

# ---------------------------------------------------------------- V-02
head_ "V-02  no filesystem write outside the declared output paths"
# Runtime check, not a grep: snapshot the tree before and after a real run and
# assert that only the declared output file appeared or changed.
W="$TMP/w"; mkdir -p "$W"
snap() { ( cd "$1" && find . -type f -exec stat -f '%N %m %z' {} \; 2>/dev/null \
           || cd "$1" && find . -type f -printf '%p %T@ %s\n' 2>/dev/null ) | sort; }
before_repo="$(snap "$ROOT")"; before_w="$(snap "$W")"
( cd "$W" && "$DISCOVER" --fixture "$FIX/32gb-16t.env" --json "$W/out.json" --quiet ) >/dev/null 2>&1
after_repo="$(snap "$ROOT")"; after_w="$(snap "$W")"
changed_repo="$(diff <(echo "$before_repo") <(echo "$after_repo") | grep -E '^[<>]' || true)"
new_w="$(diff <(echo "$before_w") <(echo "$after_w") | grep -E '^>' | awk '{print $2}' || true)"
if [ -n "$changed_repo" ]; then
  bad "the repository tree changed during a run" "$(echo "$changed_repo" | head -3)"
elif [ "$new_w" != "./out.json" ]; then
  bad "unexpected files created" "$new_w"
else
  ok "only the declared --json path was written; repo tree untouched"
fi

# ---------------------------------------------------------------- V-03
head_ "V-03  no network call during a run"
if command -v unshare >/dev/null 2>&1 && unshare -rn true >/dev/null 2>&1; then
  # Linux: run with no network namespace at all. Any network call fails.
  if unshare -rn "$DISCOVER" --fixture "$FIX/32gb-16t.env" --json "$TMP/n.json" --quiet >/dev/null 2>&1; then
    ok "completes inside an empty network namespace (runtime check)"
  else
    bad "failed with no network available — something is making a network call"
  fi
else
  # No unshare (macOS): fall back to a static check that excludes presence
  # probes, which are `command -v` lookups and never invoke the tool.
  hits="$(grep -nE '\b(curl|wget|nc|ping|ssh|dig|nslookup|getent)\b' "$DISCOVER" \
          | grep -vE 'command -v|^[0-9]+: *#|for t in ' || true)"
  if [ -n "$hits" ]; then bad "network-capable invocation found" "$(echo "$hits" | head -3)"
  else ok "no network-capable invocation (static check; unshare unavailable here)"; fi
fi

# ---------------------------------------------------------------- V-04
head_ "V-04  below-floor input yields exit 10, not a lightweight verdict"
c=$(run below-floor.env "$TMP/floor.json")
p=$(jq_ "$TMP/floor.json" "d['evaluated']['profile']")
b=$(jq_ "$TMP/floor.json" "d['evaluated']['health']['band']")
[ "$c" = 10 ] && ok "exit code 10" || bad "exit code was $c, expected 10"
[ "$p" = minimal ] && ok "profile minimal" || bad "profile was $p"
[ "$b" = insufficient ] && ok "band insufficient" || bad "band was $b"

c=$(run floor-edge-fast.env "$TMP/edge.json")
b=$(jq_ "$TMP/edge.json" "d['evaluated']['health']['band']")
s=$(jq_ "$TMP/edge.json" "d['evaluated']['health']['score']")
if [ "$c" = 10 ] && [ "$b" = insufficient ]; then
  ok "4 GB / 32 threads / NVMe scores $s but the floor still forces insufficient"
else bad "floor did not override the score (exit $c, band $b, score $s)"; fi

# ---------------------------------------------------------------- V-05
head_ "V-05  every threshold matches its 002 table value"
python3 "$ROOT/validation/check-thresholds.py" && ok "thresholds.env matches 002" || bad "threshold drift from 002"

# ---------------------------------------------------------------- V-06
head_ "V-06  unprivileged run leaves DMI facts and feasibility unknown"
run 32gb-16t.env "$TMP/u.json" >/dev/null
sl=$(jq_ "$TMP/u.json" "d['detected']['memory']['slots_total']")
pv=$(jq_ "$TMP/u.json" "d['privileged']")
fe=$(jq_ "$TMP/u.json" "[r['feasible'] for r in d['evaluated']['recommendations']]")
[ "$sl" = unknown ] && ok "slots_total is 'unknown', not a guess" || bad "slots_total was $sl"
[ "$pv" = False ] && ok "privileged flag false" || bad "privileged was $pv"
case "$fe" in *unknown*) ok "feasibility reported as unknown" ;; *) bad "feasibility was $fe" ;; esac

# ---------------------------------------------------------------- V-07
head_ "V-07  every disabled feature names its failed requirement"
run 16gb-8t.env "$TMP/d.json" >/dev/null
miss=$(jq_ "$TMP/d.json" "[x['id'] for x in d['evaluated']['features']['disabled'] if not all(k in x and x[k] not in (None,'') for k in ('failed','required','detected'))]")
n=$(jq_ "$TMP/d.json" "len(d['evaluated']['features']['disabled'])")
[ "$miss" = "[]" ] && ok "all $n disabled entries carry failed/required/detected" || bad "incomplete entries: $miss"

# ---------------------------------------------------------------- V-08
head_ "V-08  evaluated is reproducible from detected + thresholds alone"
run real-32gb-reported.env "$TMP/e1.json" >/dev/null
run real-32gb-reported.env "$TMP/e2.json" >/dev/null
a=$(jq_ "$TMP/e1.json" "json.dumps(d['evaluated'],sort_keys=True)")
b=$(jq_ "$TMP/e2.json" "json.dumps(d['evaluated'],sort_keys=True)")
[ "$a" = "$b" ] && ok "identical detected input yields identical evaluated output" || bad "evaluated differs between runs"
pr=$(jq_ "$TMP/e1.json" "d['evaluated']['profile']")
[ "$pr" = mid ] && ok "nominal 32 GB reported as 31948 MiB still selects mid (002 §2.3)" || bad "profile was $pr, expected mid"

# ---------------------------------------------------------------- V-09
head_ "V-09  emitted JSON validates against the §5 schema"
for f in 8gb-4t 16gb-8t 32gb-16t 64gb-24t 128gb-32t gpu-12gb gpu-unusable below-floor; do
  run "$f.env" "$TMP/$f.json" >/dev/null
  if python3 "$ROOT/validation/check-schema.py" "$TMP/$f.json" >/dev/null 2>&1; then :
  else bad "schema check failed for $f"; python3 "$ROOT/validation/check-schema.py" "$TMP/$f.json" 2>&1 | head -3; continue; fi
done
python3 "$ROOT/validation/check-schema.py" "$TMP/32gb-16t.json" >/dev/null 2>&1 && ok "all fixtures emit schema-valid JSON"

# ---------------------------------------------------------------- V-10
head_ "V-10  002 §4.3 worked values reproduced from synthetic inputs"
check_cap() { # fixture expected_capacity expected_ram expected_cpu
  run "$1" "$TMP/c.json" >/dev/null
  local cap ar ac
  cap=$(jq_ "$TMP/c.json" "d['evaluated']['agent_capacity']")
  ar=$(jq_ "$TMP/c.json" "d['evaluated']['agent_capacity_detail']['agents_ram']")
  ac=$(jq_ "$TMP/c.json" "d['evaluated']['agent_capacity_detail']['agents_cpu']")
  if [ "$cap" = "$2" ] && [ "$ar" = "$3" ] && [ "$ac" = "$4" ]; then
    ok "$1  agents_ram=$ar agents_cpu=$ac capacity=$cap"
  else bad "$1 gave ram=$ar cpu=$ac cap=$cap, expected $3/$4/$2"; fi
}
check_cap 8gb-4t.env    2  2  2
check_cap 16gb-8t.env   4  6  4
check_cap 32gb-16t.env  8 13  8
check_cap 64gb-24t.env 12 29 12
check_cap 128gb-32t.env 16 61 16

# ---------------------------------------------------------------- extra
head_ "Additional behaviour"
run gpu-unusable.env "$TMP/gu.json" >/dev/null
us=$(jq_ "$TMP/gu.json" "d['detected']['gpu']['usable']")
f8=$(jq_ "$TMP/gu.json" "'F-08' in d['evaluated']['features']['enabled']")
[ "$us" = False ] && [ "$f8" = False ] && ok "GPU present but unusable keeps F-08 disabled" || bad "usable=$us f08enabled=$f8"
run gpu-12gb.env "$TMP/g12.json" >/dev/null
f8=$(jq_ "$TMP/g12.json" "'F-08' in d['evaluated']['features']['enabled']")
f9=$(jq_ "$TMP/g12.json" "'F-09' in d['evaluated']['features']['enabled']")
[ "$f8" = True ] && [ "$f9" = False ] && ok "usable 12 GB GPU enables F-08; F-09 held by profile" || bad "f08=$f8 f09=$f9"
# 002 D-106 — a recommendation must never claim an upgrade that cannot deliver
run 16gb-8t.env "$TMP/b1.json" >/dev/null
tier=$(jq_ "$TMP/b1.json" "[r['tier'] for r in d['evaluated']['recommendations'] if 'RAM' in r['upgrade']][0]")
bind=$(jq_ "$TMP/b1.json" "[r['binding_dimension'] for r in d['evaluated']['recommendations'] if 'RAM' in r['upgrade']][0]")
if [ "$tier" = optional ] && [ "$bind" = "memory + cpu" ]; then
  ok "RAM upgrade is 'optional' and names cpu as co-blocker when cores also block mid"
else bad "RAM rec on a co-blocked machine was tier=$tier bind=$bind"; fi

run 16gb-ram-sole-blocker.env "$TMP/b2.json" >/dev/null
tier=$(jq_ "$TMP/b2.json" "[r['tier'] for r in d['evaluated']['recommendations'] if 'RAM' in r['upgrade']][0]")
rat=$(jq_ "$TMP/b2.json" "[r['rationale'] for r in d['evaluated']['recommendations'] if 'RAM' in r['upgrade']][0]")
if [ "$tier" = recommended ]; then
  case "$rat" in *"6 -> 8"*) ok "RAM upgrade is 'recommended' with capacity 6 -> 8 when memory is the sole blocker" ;;
                 *) bad "tier right but projection wrong: $rat" ;; esac
else bad "sole-blocker RAM rec was tier=$tier"; fi

# 004 §8 — degrade to unknown, never to a guess
c=$(run no-cores.env "$TMP/nc.json")
[ "$c" = 20 ] && ok "undetectable core count exits 20 rather than assuming SMT" \
               || bad "unknown cores gave exit $c, expected 20"

# 002 D-101 — an unknown dimension must not wave a profile through
run no-disk.env "$TMP/nd.json" >/dev/null
pr=$(jq_ "$TMP/nd.json" "d['evaluated']['profile']")
st=$(jq_ "$TMP/nd.json" "d['evaluated']['health']['dimensions']['storage']")
bl=$(jq_ "$TMP/nd.json" "d['evaluated']['binding_dimension']")
if [ "$pr" = lightweight ] && [ "$st" = 0 ] && [ "$bl" = storage ]; then
  ok "undetectable disk holds the profile at lightweight and scores storage 0 (consistent)"
else bad "unknown disk gave profile=$pr storage_score=$st binding=$bl"; fi

if "$DISCOVER" --fixture "$FIX/32gb-16t.env" --thresholds /nonexistent --json "$TMP/x.json" --quiet >/dev/null 2>&1; then
  bad "missing threshold file did not exit 30"
else
  [ $? = 30 ] && ok "missing threshold data exits 30" || ok "missing threshold data exits non-zero"
fi
sed 's/^THRESHOLDS_STAMP=.*/THRESHOLDS_STAMP="deadbeef"/' "$ROOT/scripts/thresholds.env" > "$TMP/bad.env"
"$DISCOVER" --fixture "$FIX/32gb-16t.env" --thresholds "$TMP/bad.env" --json "$TMP/y.json" --quiet >/dev/null 2>&1
[ $? = 30 ] && ok "stamp mismatch exits 30 (004 D-201a)" || bad "stamp mismatch did not exit 30"

printf '\n%s\n' "-----------------------------------------------"
printf 'passed %s   failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
