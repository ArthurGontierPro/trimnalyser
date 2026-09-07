#!/bin/bash
# Companion trimmer comparison — one orchestrator run, four arms, no harness.
#
#   bash scripts/companion_run.sh [config]
#
# WHAT THIS REPLACES. companion_run_all.sh + companion_compare.sh drove the two VeriPB
# trimmers from bash: xargs for concurrency, chunks for disk, and their own memory policy.
# That was wrong twice over.
#
#   Fairness. Our trimmer's numbers come from a run under the orchestrator. Measuring the
#   companions under a different scheduler compares schedulers as much as trimmers, and
#   the scheduler difference is the bigger effect -- the harness put 48 unbounded
#   elaborations on one node and used 1.9 TB of 2.0 TB before the kernel killed it.
#
#   Disk. The harness needed chunking because it solved everything, then compared
#   everything, so every proof had to exist at once. The orchestrator interleaves per
#   instance and release_raw drops each proof as its instance finishes, so peak disk
#   follows concurrency, not the size of the instance set. No chunks, no barriers.
#
# ALL FOUR ARMS COME FROM THIS ONE RUN, on one machine, at one moment:
#
#   base   veri full        VeriPB elaborating the untrimmed proof
#   ta     grim + veri smol our trimmer, then the same checker on its output
#   ft     ft   + ft VERI   feature_trimmer, then the same checker
#   tb     tb   + tb VERI   feature/trimmer-base, then the same checker
#
# So the reuse join against archived grid rows is no longer needed for this table. That
# join was always the weaker option: it paired arms measured weeks apart under different
# binaries, and needed a per-row guard on input sizes to be trustworthy at all.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-gss-lazy}"
THREADS="${THREADS:-92,1}"
ST="${ST:-600}"       STNOPL="${STNOPL:-60}"
TT="${TT:-6000}"      VT="${VT:-6000}"
MAXMEM="${MAXMEM:-32}"

# cluster_env.sh exports the per-revision Glasgow paths. Without it gssbin() falls back to
# the single global binary and every column silently measures the same build.
[[ -f scripts/cluster_env.sh ]] && source scripts/cluster_env.sh

FT="${VERIPB_FT:-/scratch/arthur/veripb_ft}"
TB="${VERIPB_TB:-/scratch/arthur/veripb_tb}"
VP="${VERIPB:-/scratch/arthur/veripb}"

# Preflight. Every one of these fails softly at run time -- a missing companion binary
# logs MISSING for every instance and the run completes looking merely unlucky.
fail=0
for b in "$VP" "$FT" "$TB"; do
    if [[ -x "$b" ]]; then
        printf '  %-34s %s  %s\n' "$b" "$(sha256sum "$b" | cut -c1-16)" \
               "$("$b" --version 2>&1 | head -1)"
    else
        echo "  MISSING: $b" >&2; fail=1
    fi
done
[[ "$fail" -eq 0 ]] || { echo "stage the binaries on this node first (scripts/cluster_dist.sh)" >&2; exit 1; }

# `companion` adds the stage; `verif` gives base and ta their verdicts from the same
# checker the companions are checked with. No `cake` (not part of this comparison) and no
# `resolv` (it re-solves cores, which measures the solver, not the trimmers).
exec ./trimnalyser --threads "$THREADS" solve verif companion allgraphs \
     "config=$CONFIG" "stnopl=$STNOPL" "st=$ST" "tt=$TT" "vt=$VT" "maxmem=$MAXMEM" rand
