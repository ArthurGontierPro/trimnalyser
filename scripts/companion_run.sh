#!/bin/bash
# One companion trimmer, one node, one full column.
#
#   bash scripts/companion_run.sh ft        # on one node
#   bash scripts/companion_run.sh tb        # on another
#
# Each is a normal appendix-grid column: the full instance set, 92 threads, maxmem=32,
# the same timeouts as every published column, under the same orchestrator. The pipeline
# per instance is exactly three stages:
#
#   solve ──► <this trimmer> trim ──► verif its output ──► release
#
# It does NOT elaborate the untrimmed proof and does NOT run our own trimmer. Both are
# already published from runs with these same parameters; re-deriving them would spend
# days of solver time reproducing numbers we already have. The comparison joins this
# column against those.
#
# The two runs MUST use different config keys. The key names the .out file in
# /cluster/arthur/logs, which is shared NFS across all nine nodes -- one key for both runs
# would interleave their per-run blocks in a single file and each would read the other's
# as its own. parse_config! refuses a mismatched pair rather than trusting the caller.
set -euo pipefail
cd "$(dirname "$0")/.."

ARM="${1:?usage: companion_run.sh ft|tb}"
case "$ARM" in ft|tb) ;; *) echo "arm must be ft or tb" >&2; exit 1 ;; esac
CONFIG="gss-lazy-$ARM"

THREADS="${THREADS:-92,1}"
ST="${ST:-600}"   STNOPL="${STNOPL:-60}"
TT="${TT:-6000}"  VT="${VT:-6000}"
MAXMEM="${MAXMEM:-32}"

# gssbin() falls back to the single global binary when its revision variable is unset, so
# eight of nine Glasgow columns once measured the same build. SOLVER_CONFIGS is a const
# built at module load, so this must be sourced before julia starts.
[[ -f scripts/cluster_env.sh ]] && source scripts/cluster_env.sh

BIN_VAR="VERIPB_$(echo "$ARM" | tr a-z A-Z)"
BIN="${!BIN_VAR:-/scratch/arthur/veripb_$ARM}"
VP="${VERIPB:-/scratch/arthur/veripb}"

# Both fail softly otherwise: a missing trimmer logs MISSING for all 25,590 instances and
# the run completes looking merely unlucky. Stamp them beside the numbers they produce.
for b in "$VP" "$BIN"; do
    [[ -x "$b" ]] || { echo "MISSING: $b — stage it first (scripts/cluster_dist.sh)" >&2; exit 1; }
    printf '  %-32s %s  %s\n' "$b" "$(sha256sum "$b" | cut -c1-16)" "$("$b" --version 2>&1 | head -1)"
done
echo "  arm=$ARM config=$CONFIG threads=$THREADS maxmem=${MAXMEM}G st=$ST tt=$TT vt=$VT"

exec ./trimnalyser --threads "$THREADS" solve verif "companion=$ARM" allgraphs \
     "config=$CONFIG" "stnopl=$STNOPL" "st=$ST" "tt=$TT" "vt=$VT" "maxmem=$MAXMEM" rand
