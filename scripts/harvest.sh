#!/bin/bash
# Harvest: aggregate results and generate reports.
# Run ON THE COMPUTE NODE that produced the proofs, from ~/trimnalyser/
# (/scratch is local to each machine — the head node has its own empty one,
#  so running this there would find nothing.)
# Usage: bash scripts/harvest.sh [proofs_dir]
# Then pull results locally with: bash scripts/harvest_pull.sh
#
# The optional argument lets an archived run be re-harvested in place, without the
# rename dance that a hardcoded path would force:
#   bash scripts/harvest.sh /scratch/arthur/proofs.ab-labels-for-analysis
# Output filenames are unchanged, so move them aside between two harvests.

set -euo pipefail
cd "$(dirname "$0")/.."

PROOFS="${1:-/scratch/arthur/proofs}"
[[ -d "$PROOFS" ]] || { echo "no such proofs dir: $PROOFS" >&2; exit 1; }
echo "harvesting $PROOFS"

echo "=== 1/5 Aggregate results ==="
julia scripts/aggregate_results.jl "$PROOFS" cluster_results.csv

echo "=== 2/5 Graph features ==="
julia scripts/graph_features.jl "$PROOFS" graph_features.csv

echo "=== 3/5 Var order aggregation ==="
julia scripts/aggregate_var_order.jl "$PROOFS" var_order

echo "=== 4/5 Quick stats ==="
julia scripts/quick_stats.jl cluster_results.csv

echo "=== 5/6 HTML reports ==="
julia --project=scripts scripts/proof_survey.jl cluster_results.csv graph_features.csv proof_survey.html
julia --project=scripts scripts/classify_supplementals.jl cluster_results.csv graph_features.csv classify_supplementals

echo "=== 6/6 Cone vs full ==="
julia --project=scripts scripts/cone_vs_full.jl cluster_results.csv cone_vs_full.html

echo "=== Done (6/6) — pull with: bash scripts/harvest_pull.sh ==="
