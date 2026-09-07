#!/usr/bin/env bash
# Compute the 002 governing-section content stamp.
#
# 004 D-201a: the threshold data file carries a stamp derived from 002's
# governing sections (§2-§6). discover.sh verifies it at load, so a data file
# that no longer corresponds to 002 is a Stage 0 refusal (exit 30) rather than
# a silent evaluation.
#
# Usage: stamp-thresholds.sh [--check]   (default: print the current stamp)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/docs/architecture/002-Hardware-Assessment.md"
DATA="$ROOT/scripts/thresholds.env"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else echo "no sha256 tool available" >&2; exit 1
  fi
}

# Governing half only: §2 through §6. §7 holds machine-specific detected data
# and must not invalidate the stamp when it is filled in.
compute() {
  awk '/^## 2\. Hardware Profiles/{on=1} /^## 7\. Detected Specification/{on=0} on' "$SPEC" | sha256
}

case "${1:-}" in
  --check)
    want="$(compute)"
    have="$(grep '^THRESHOLDS_STAMP=' "$DATA" | cut -d= -f2 | tr -d '"')"
    if [ "$want" = "$have" ]; then
      echo "stamp ok: $want"
    else
      echo "STAMP MISMATCH" >&2
      echo "  002 governing sections: $want" >&2
      echo "  thresholds.env:         $have" >&2
      exit 1
    fi
    ;;
  *) compute ;;
esac
