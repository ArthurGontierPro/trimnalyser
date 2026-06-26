#!/bin/bash
# Pull harvest results from cluster to local ~/trimnalyser/
# Run LOCALLY after running harvest.sh on the cluster.
# Usage: bash scripts/harvest_pull.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=arthur@fataepyc-07.dcs.gla.ac.uk
REMOTE=/users/grad/arthur/trimnalyser

for f in cluster_results.csv graph_features.csv var_order_stats.csv var_order_family_summary.csv oracle_replay_results.csv proof_survey.html classify_supplementals.html classify_supplementals.txt cone_vs_full.html; do
    echo "pulling $f ..."
    scp "${CLUSTER}:${REMOTE}/$f" . && echo "  ok" || echo "  FAILED (file may not exist)"
done

echo "pulling output.log as cluster_output.log ..."
scp "${CLUSTER}:/users/grad/arthur/output.log" cluster_output.log && echo "  ok" || echo "  FAILED (file may not exist)"

echo "=== Done ==="
