#!/bin/bash
# M7.5 route 1 — produce the tab:configs-lad cells with ladveri's own bench harness.
#
# The five LAD columns come from ~/ladveri/proof/bench/bench.py, which is already
# resumable, names instances exactly as we do, and hard-excludes bio.
#
# NOTE (2026-08-21): the reason this is route 1 -- "LAD writes no OPB" -- no longer
# holds. LAD's -O FILE emits the model byte-identically to cake_pb_iso, so route 2
# (a runladsolver running LAD through our own trim/verif/resolv pipeline) is now
# possible and is what M5-proof-trim needs. This script stays as the cheap path to
# the no-logging columns. The config names
# below are OUR harness keys, defined inline so the CSV joins on (instance, config).
#
# Usage: bash scripts/lad_bench.sh [out.csv] [families]
# Then:  julia scripts/merge_lad_results.jl cluster_results.csv out.csv combined.csv
#
# Excluded on purpose:
#   bio            directed graphs — LAD reads them as undirected silently, cake rejects
#                  them. All four bio cells are marked † in the paper.
#   images, meshes LAD proofs have no deletions and grow with search length; the LV
#                  encoder output alone projects to 10.4 TB uncapped. Marked ‡ — do not
#                  schedule them until that is fixed.
set -euo pipefail

BENCH="${LADVERI_BENCH:-$HOME/ladveri/proof/bench/bench.py}"
[[ -f "$BENCH" ]] || { echo "bench.py not found at $BENCH (set LADVERI_BENCH)" >&2; exit 1; }

OUT="${1:-lad_results.csv}"
FAMILIES="${2:-LV,phase,sf,si}"

# The paper's grid, rows 10-14. `-c 0` is forced for the proof-logging pair: clique
# filtering emits no justification.
#
# DO NOT put a bare `-P` in these specs. `-P` is not a boolean — it is LAD's proof OUTPUT
# PATH (`ladveri/main.c:308`), and bench.py appends its own `-P <path>` at bench.py:271.
# With both present LAD's getopt takes the literal string "-P" as the proof filename and
# the real path falls through as an ignored positional, so `lad-alldiff-pl` and
# `lad-fc-pl` wrote NO PROOF AT ALL while still reporting a clean solve. `+proof` alone is
# bench.py's marker for "log a proof"; it supplies the flag. The same stray `-P` was
# removed from config.jl's two lad-*-pl entries on 2026-08-24.
#
# (The old comment here claimed `-P` "pins restarts to infinity". That is a side effect,
# not the meaning: main.c:461 sets nbMaxFail = INT_MAX when a proof path is given, because
# proof logging does not handle restart nogoods yet.)
CONFIGS=(
  'lad=lad -f 2 -c 4'
  'lad-clique=lad -f 0 -c 2'
  'lad-noclique=lad -f 0 -c 0'
  'lad-alldiff-pl=lad -f 0 -c 0 +proof'
  'lad-fc-pl=lad -f 1 -c 0 +proof'
)

args=()
for c in "${CONFIGS[@]}"; do args+=(--config "$c"); done

echo "bench: $BENCH"
echo "out:   $OUT   families: $FAMILIES"
python3 "$BENCH" "${args[@]}" --families "$FAMILIES" --out "$OUT" \
        --solver-timeout "${SOLVER_TIMEOUT:-60}" --verify-timeout "${VERIFY_TIMEOUT:-600}" \
        --jobs "${JOBS:-1}" "${@:3}"
