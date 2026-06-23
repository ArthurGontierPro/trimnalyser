#!/bin/bash
# Harvest: aggregate results and generate reports.
# Run ON THE CLUSTER from ~/trimnalyser/
# Usage: bash scripts/harvest.sh
# Then pull results locally with: bash scripts/harvest_pull.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PROOFS=/scratch/arthur/proofs

echo "=== 1/5 Aggregate results ==="
julia scripts/aggregate_results.jl "$PROOFS" cluster_results.csv

echo "=== 2/5 Graph features ==="
julia scripts/graph_features.jl "$PROOFS" graph_features.csv

echo "=== 3/5 Var order aggregation ==="
julia scripts/aggregate_var_order.jl "$PROOFS" var_order

echo "=== 4/5 Quick stats ==="
julia scripts/quick_stats.jl cluster_results.csv

echo "=== 5/5 HTML reports ==="
julia --project=scripts scripts/proof_survey.jl cluster_results.csv graph_features.csv proof_survey.html
julia --project=scripts scripts/classify_supplementals.jl cluster_results.csv graph_features.csv classify_supplementals

echo "=== Done — pull with: bash scripts/harvest_pull.sh ==="
