#!/bin/bash
# Harvest: aggregate results and generate reports.
# Run ON THE COMPUTE NODE that produced the proofs, from ~/trimnalyser/
# (/scratch is local to each machine — the head node has its own empty one,
#  so running this there would find nothing.)
# Usage: bash scripts/harvest.sh [proofs_dir] [logs_dir]
# Since M7.1/M7.4 the proofs dir is namespaced per configuration
# (/scratch/arthur/proofs/<solver>/<config>) and the .out logs live outside the proof
# tree in /cluster/arthur/logs. Harvest one configuration at a time:
#   bash scripts/harvest.sh /scratch/arthur/proofs/gss/gss-lazy
# Then pull results locally with: bash scripts/harvest_pull.sh
#
# The optional argument lets an archived run be re-harvested in place, without the
# rename dance that a hardcoded path would force:
#   bash scripts/harvest.sh /scratch/arthur/proofs.ab-labels-for-analysis
# Output filenames are unchanged, so move them aside between two harvests.

set -euo pipefail
cd "$(dirname "$0")/.."

PROOFS="${1:-/scratch/arthur/proofs/gss/gss-lazy}"
LOGS="${2:-/cluster/arthur/logs}"
[[ -d "$PROOFS" ]] || { echo "no such proofs dir: $PROOFS" >&2; exit 1; }
[[ -d "$LOGS" ]]   || { echo "no such logs dir: $LOGS" >&2; exit 1; }

# /scratch is node-local: on the head node the dir can exist but be empty, and every
# report below would then be generated, overwrite the real ones, and look merely "small".
NOPB=$(find "$PROOFS" -maxdepth 1 -name '*.opb' -printf . 2>/dev/null | wc -c)
if [[ "$NOPB" -eq 0 ]]; then
    echo "no .opb files under $PROOFS — wrong host, or the run never produced proofs" >&2
    echo "(are you on the compute node? /scratch is local to each machine)" >&2
    exit 1
fi

# The outputs below have FIXED names with no config in them, so a second harvest silently
# replaces the first. Stamp what produced them and refuse to clobber a different source.
STAMP=.harvest_source
if [[ -f "$STAMP" && -s cluster_results.csv ]]; then
    PREV=$(cat "$STAMP")
    if [[ "$PREV" != "$PROOFS" && "${HARVEST_FORCE:-0}" != "1" ]]; then
        echo "refusing to overwrite reports harvested from: $PREV" >&2
        echo "  now harvesting:                              $PROOFS" >&2
        echo "Move the previous outputs aside, or set HARVEST_FORCE=1 to replace them." >&2
        exit 1
    fi
fi
echo "$PROOFS" > "$STAMP"

echo "harvesting $PROOFS (logs: $LOGS)"

echo "=== 1/5 Aggregate results ==="
julia scripts/aggregate_results.jl "$PROOFS" cluster_results.csv "$LOGS"

echo "=== 2/5 Graph features ==="
TRIMNALYSER_LOGS="$LOGS" julia scripts/graph_features.jl "$PROOFS" graph_features.csv

echo "=== 3/5 Var order aggregation ==="
TRIMNALYSER_LOGS="$LOGS" julia scripts/aggregate_var_order.jl "$PROOFS" var_order

echo "=== 4/5 Quick stats ==="
julia scripts/quick_stats.jl cluster_results.csv

echo "=== 5/6 HTML reports ==="
julia --project=scripts scripts/proof_survey.jl cluster_results.csv graph_features.csv proof_survey.html
julia --project=scripts scripts/classify_supplementals.jl cluster_results.csv graph_features.csv classify_supplementals

echo "=== 6/6 Cone vs full ==="
julia --project=scripts scripts/cone_vs_full.jl cluster_results.csv cone_vs_full.html

echo "=== Done (6/6) — pull with: bash scripts/harvest_pull.sh ==="
