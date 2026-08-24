#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Every column of the configuration grid, one after another.
#
# Sequential on purpose: each column already saturates the node (--threads 92,1) and the
# per-instance memory cap is sized for one run at a time. Two columns in parallel would
# make both of their timings unusable as table cells.
#
# Usage:
#   bash scripts/bench_all.sh [scale] [config ...]
#
#   [scale]     divides every timeout (default 1). 60 is the smoke-test scale: the whole
#               grid completes in minutes because nearly everything hits a limit, which
#               is what makes it a test of the SCRIPTS rather than of the solvers.
#   [config...] restrict to these columns (default: all fourteen, gss before lad)
#
# Environment: everything bench_config.sh reads, plus
#   RUNLOG    directory for the per-column console logs (default $TRIMNALYSER_BASE/benchlogs)
#   KEEPGOING=0  stop at the first column that exits non-zero (default: keep going)
#
# A column that fails does not abort the grid: its proofs and logs are already namespaced
# per configuration, so the remaining columns are unaffected and can be re-run singly with
#   bash scripts/bench_config.sh <config> [scale]
# ══════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/.."

SCALE="${1:-1}"; shift || true

ALL=(gss gss-noclique gss-proof gss-lazy
     gss-lazy-base gss-nostaged gss-nosupp gss-norestarts gss-cliques
     lad lad-clique lad-noclique lad-alldiff-pl lad-fc-pl)
CONFIGS=("$@"); [[ ${#CONFIGS[@]} -eq 0 ]] && CONFIGS=("${ALL[@]}")

case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) BASE="${TRIMNALYSER_BASE:-/users/grad/arthur}" ;;
    *)                         BASE="${TRIMNALYSER_BASE:-/home/arthur_gla/veriPB/subgraphsolver}" ;;
esac
RUNLOG="${RUNLOG:-${BASE%/}/benchlogs}"
mkdir -p "$RUNLOG"
STAMP=$(date +%Y%m%dT%H%M%S)

# Fail every column's preflight before running any of them: a missing veripb or cake_pb is
# a one-line yellow warning at run time, and a whole grid would otherwise complete with
# empty certification columns.
echo "=== preflight ==="
pre=0
for c in "${CONFIGS[@]}"; do
    DRYRUN=1 bash scripts/bench_config.sh "$c" "$SCALE" >/dev/null || { echo "  FAIL $c"; pre=1; }
done
[[ $pre -eq 0 ]] || { echo "preflight failed; nothing was run" >&2
                      DRYRUN=1 bash scripts/bench_config.sh "${CONFIGS[0]}" "$SCALE" >/dev/null; exit 1; }
echo "  ok (${#CONFIGS[@]} columns)"

declare -a RESULT
for c in "${CONFIGS[@]}"; do
    log="$RUNLOG/$STAMP.$c.log"
    echo "=== $c (scale=$SCALE) -> $log ==="
    t0=$SECONDS
    bash scripts/bench_config.sh "$c" "$SCALE" >"$log" 2>&1
    rc=$?
    dt=$((SECONDS - t0))
    RESULT+=("$(printf '%-16s rc=%-3s %5ds  %s' "$c" "$rc" "$dt" "$log")")
    echo "    rc=$rc  ${dt}s"
    if [[ $rc -ne 0 && "${KEEPGOING:-1}" == "0" ]]; then
        echo "stopping: KEEPGOING=0" >&2; break
    fi
done

echo
echo "=== summary (scale=$SCALE) ==="
printf '%s\n' "${RESULT[@]}"
echo
echo "harvest one column at a time, ON THE COMPUTE NODE:"
echo "  bash scripts/harvest.sh /scratch/arthur/proofs/gss/<config>"
