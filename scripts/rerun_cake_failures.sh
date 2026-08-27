#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Re-run the (config, instance) pairs whose TRIMMED proof CakeML rejected, against a
# rebuilt cake_pb.
#
# Why a re-run and not a re-check: the pipeline deletes each proof at last use, so the
# 3815 rejected .pbp files no longer exist anywhere. Establishing whether cakepb-dev
# c41ce52 ("fix a bug in weakening") clears them means regenerating solve -> trim ->
# veripb -> cake from scratch for every pair.
#
# The bug (see docs/failing-pairs/README.md, category B): `w v` on a literal that is not
# in the constraint is a legal no-op — coefficient 0, degree unchanged — and CakeML
# skipped the step instead, diverging from VeriPB and surfacing at the first `ia`. It can
# only fire on a TRIMMED proof: the trimmer drops literals while `writepol` copies
# Glasgow's `w` tokens through verbatim. That is exactly what the grid measured — 3815
# cake_smol rejections, and zero cake_full rejections in 217835 pair-records.
#
# Usage:
#   CAKE_PB=/path/to/fixed/cake_pb bash scripts/rerun_cake_failures.sh [pairs.tsv]
#
#   pairs.tsv   <config>\t<instance>, one pair per line
#               (default: docs/failing-pairs/B_cake-smol-failed.tsv)
#
# Environment:
#   CAKE_PB     REQUIRED. No default: the whole point is to not run the grid's binary.
#   WORKDIR     where the per-config instance lists go (default /cluster/arthur/rerun)
#   SCALE       divides every timeout, as in bench_config.sh (default 1)
#   THREADS     julia --threads value (default 92,1)
#   DRYRUN=1    print what would run and exit
#
# Runs one column at a time, in the foreground. Wrap the whole thing in tmux/nohup —
# each column is hours, and every ssh is a fresh shell.
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
cd "$(dirname "$0")/.."

PAIRS="${1:-docs/failing-pairs/B_cake-smol-failed.tsv}"
WORKDIR="${WORKDIR:-/cluster/arthur/rerun}"
SCALE="${SCALE:-1}"
THREADS="${THREADS:-92,1}"

[[ -s "$PAIRS" ]] || { echo "no such pair list: $PAIRS" >&2; exit 1; }

# ── The one thing this script exists to get right ─────────────────────────────────────
# cluster_env.sh pins CAKE_PB to /scratch/arthur/cake_pb. It uses `:=` so an exported
# value wins, but it only started doing that today — on an un-updated checkout the export
# is unconditional and this run would silently re-measure the OLD binary and "reproduce"
# all 3815 failures. So: demand the variable, and prove at the end of preflight that the
# value survives sourcing.
[[ -n "${CAKE_PB:-}" ]] || { echo "CAKE_PB is unset. Point it at the rebuilt cake_pb." >&2; exit 1; }
[[ -x "$CAKE_PB" ]]     || { echo "CAKE_PB is not executable: $CAKE_PB" >&2; exit 1; }
export CAKE_PB
WANT_CAKE="$CAKE_PB"
if [[ -f scripts/cluster_env.sh ]] && [[ "$(hostname)" == fataepyc* ]]; then
    ( source scripts/cluster_env.sh; [[ "$CAKE_PB" == "$WANT_CAKE" ]] ) || {
        echo "cluster_env.sh overrode CAKE_PB (\"$WANT_CAKE\" did not survive sourcing)." >&2
        echo "This checkout predates the := fix. Pull, or overwrite /scratch/arthur/cake_pb." >&2
        exit 1; }
fi

mkdir -p "$WORKDIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUNDIR="$WORKDIR/$STAMP"
mkdir -p "$RUNDIR"

# ── Split the pair list into one instance list per column ─────────────────────────────
awk -F'\t' -v d="$RUNDIR" 'NF>=2 && $1!="" && $2!="" { print $2 > (d "/" $1 ".txt") }' "$PAIRS"
mapfile -t COLUMNS < <(cd "$RUNDIR" && ls *.txt 2>/dev/null | sed 's/\.txt$//' | sort)
[[ ${#COLUMNS[@]} -gt 0 ]] || { echo "pair list produced no columns" >&2; exit 1; }

{
  echo "rerun    $STAMP"
  echo "host     $(hostname)"
  echo "pairs    $PAIRS ($(wc -l < "$PAIRS") lines)"
  echo "cake_pb  $CAKE_PB"
  echo "sha256   $(sha256sum "$CAKE_PB" | cut -d' ' -f1)"
  echo "repo     $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "scale    $SCALE   threads $THREADS"
  echo "columns:"
  for c in "${COLUMNS[@]}"; do printf '  %-16s %6d instances\n' "$c" "$(wc -l < "$RUNDIR/$c.txt")"; done
} | tee "$RUNDIR/PROVENANCE.txt"

[[ "${DRYRUN:-0}" == "1" ]] && exit 0

# ── Run the columns ───────────────────────────────────────────────────────────────────
# `overwrite` is not optional: every one of these instances carries a .done/.sat sentinel
# from the grid run, and without it the whole list is skipped in silence.
for c in "${COLUMNS[@]}"; do
    echo "══ $c  ($(wc -l < "$RUNDIR/$c.txt") instances)  $(date -u +%H:%M:%SZ) ══"
    INSTFILE="$RUNDIR/$c.txt" THREADS="$THREADS" EXTRA="overwrite" \
        bash scripts/bench_config.sh "$c" "$SCALE" \
        2>&1 | tee -a "$RUNDIR/$c.log" || echo "column $c exited $?"
done
echo "══ done  $(date -u +%Y-%m-%dT%H:%M:%SZ) ══  logs in $RUNDIR"
