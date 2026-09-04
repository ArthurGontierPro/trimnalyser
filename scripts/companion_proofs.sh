#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Phase 1 of the companion comparison: produce the STOCK PROOFS all three trimmers read.
#
# Solve with `keepraw` into a dedicated proof directory, so the raw <ins>.opb/<ins>.pbp
# survive the run instead of being released (orchestrator.jl `release_raw`).  No verif,
# no cake, no resolv: none of them is measured here, and the full-proof elaboration is
# the single largest file the pipeline ever writes.
#
# Isolation, deliberately, on three axes:
#
#   * its own PROOF DIR   ($SCRATCH/companion/proofs/) — never the grid's namespaced tree
#   * its own CHECKOUT    (~/trimnalyser-companion)    — $HOME is ONE shared NFS mount
#     across all nine nodes, and rebuilding trimnalyser.so under a live orchestrator
#     kills it with `signal 7 (2): Bus error`.  That is not hypothetical: it killed
#     lad-fc-pl on fataepyc-08 on 2026-09-01.  Six grid columns are running right now,
#     so this script must not touch ~/trimnalyser/trimnalyser.so at all.
#   * its own LOG DIR     ($SCRATCH/companion/logs/)   — the grid's /cluster/arthur/logs
#     is append-only and read by the aggregator; a comparison run has no business in it.
#
# Usage:  bash scripts/companion_proofs.sh <instfile> [config]
#
# Environment: THREADS (92,1)  ST (600)  STNOPL (60)  TT (6000)  MAXMEM (32)
#              COMPANION_ROOT ($SCRATCH/companion)  EXTRA (extra ./trimnalyser args)
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

INSTFILE="${1:?usage: companion_proofs.sh <instfile> [config]}"
CONFIG="${2:-gss-lazy}"

case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) ;;
    *) echo "refusing to run off a compute node (hostname=$(hostname))" >&2; exit 1 ;;
esac
[[ -f "$INSTFILE" ]] || { echo "missing instance list: $INSTFILE" >&2; exit 1; }
grep -qve '^\s*#' -e '^\s*$' "$INSTFILE" || { echo "instance list is empty" >&2; exit 1; }
grep -ve '^\s*#' -e '^\s*$' "$INSTFILE" | grep -q '/' && {
    echo "instance list holds paths, not names — run scripts/companion_sample.sh first" >&2; exit 1; }

SCRATCH="${SCRATCH:-/scratch/arthur}"
ROOT="${COMPANION_ROOT:-$SCRATCH/companion}"
PROOFS="$ROOT/proofs/"
SRC="${COMPANION_SRC:-$HOME/trimnalyser-companion}"
UPSTREAM="${TRIMNALYSER_UPSTREAM:-$HOME/trimnalyser}"

THREADS="${THREADS:-92,1}" ST="${ST:-600}" STNOPL="${STNOPL:-60}"
TT="${TT:-6000}" MAXMEM="${MAXMEM:-32}"

mkdir -p "$PROOFS" "$ROOT/logs"

# ── a checkout of our own ────────────────────────────────────────────────────────────
# `git clone --shared` would put the objects in $UPSTREAM/.git and make the two
# checkouts share a fate; a plain clone is 1 MB since the 2026-08-21 history purge.
if [[ ! -d "$SRC/.git" ]]; then
    echo "== cloning $UPSTREAM -> $SRC =="
    git clone --quiet "$UPSTREAM" "$SRC"
fi
git -C "$SRC" fetch --quiet origin || git -C "$SRC" fetch --quiet "$UPSTREAM" || true
WANT="${COMPANION_REF:-$(git -C "$UPSTREAM" rev-parse HEAD)}"
git -C "$SRC" checkout --quiet --force --detach "$WANT" 2>/dev/null || {
    echo "cannot check out $WANT in $SRC — is it pushed?" >&2; exit 1; }
echo "== companion checkout at $(git -C "$SRC" rev-parse --short HEAD) =="

# Pin the binaries BEFORE julia starts: SOLVER_CONFIGS is a const dict built at module
# load, so gssbin() reads $GLASGOW_SUBGRAPH_SOLVER_<rev> exactly once.
# shellcheck source=/dev/null
source "$SRC/scripts/cluster_env.sh"
# ...but not the log root: the grid's is append-only and aggregated, ours is disposable.
export TRIMNALYSER_LOGS="$ROOT/logs/"
export TRIMNALYSER_BASE="$ROOT/"

for b in "$GLASGOW_SUBGRAPH_SOLVER_1ff87ba" "$VERIPB" "$TRIMNALYSER_GRAPHS"; do
    [[ -e "$b" ]] || { echo "MISSING $b" >&2; exit 1; }
done
FREE_GB=$(df -BG --output=avail "$SCRATCH" | tail -1 | tr -dc '0-9')
N=$(grep -cve '^\s*#' -e '^\s*$' "$INSTFILE")
(( FREE_GB > 500 )) || { echo "only ${FREE_GB}G free on $SCRATCH; keepraw needs headroom" >&2; exit 1; }

echo "=== stock proofs: $N instances, config=$CONFIG, st=$ST tt=$TT ==="
echo "    proofs -> $PROOFS   (kept: keepraw)"
echo "    logs   -> $TRIMNALYSER_LOGS"
echo "    free   -> ${FREE_GB}G"

# `keepraw` is the whole point. `overwrite` is deliberately NOT here: a resumed run must
# reuse the proofs it already produced, and overwrite bypasses every sentinel.
ARGS=(--threads "$THREADS" solve keepraw "config=$CONFIG"
      "instfile=$INSTFILE" "stnopl=$STNOPL" "st=$ST" "tt=$TT" "maxmem=$MAXMEM"
      "$PROOFS")
# shellcheck disable=SC2206
[[ -n "${EXTRA:-}" ]] && ARGS+=(${EXTRA})

echo "+ ./trimnalyser ${ARGS[*]}"
[[ "${DRYRUN:-0}" == "1" ]] && exit 0
cd "$SRC" && exec ./trimnalyser "${ARGS[@]}"
