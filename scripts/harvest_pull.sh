#!/bin/bash
# Pull harvest results from cluster to local ~/trimnalyser/
# Run LOCALLY after running harvest.sh on the cluster.
# Usage: bash scripts/harvest_pull.sh

set -euo pipefail
cd "$(dirname "$0")/.."

# Le head node suffit : /users/grad est partage en NFS entre le head et tous
# les noeuds, donc les fichiers produits par harvest.sh y sont visibles. Un
# seul saut, et ca ne depend pas de l'etat d'un noeud de calcul en particulier.
# (Les noeuds fataepyc-NN sont sur un reseau prive et ne sont joignables qu'en
# ProxyJump via le head — voir ~/.ssh/config.)
CLUSTER=fataepyc-head
REMOTE=/users/grad/arthur/trimnalyser

for f in cluster_results.csv graph_features.csv var_order_stats.csv var_order_family_summary.csv oracle_replay_results.csv proof_survey.html classify_supplementals.html classify_supplementals.txt cone_vs_full.html oracle_scatter.html; do
    echo "pulling $f ..."
    scp "${CLUSTER}:${REMOTE}/$f" . && echo "  ok" || echo "  FAILED (file may not exist)"
done

echo "pulling output.log as cluster_output.log ..."
scp "${CLUSTER}:/users/grad/arthur/output.log" cluster_output.log && echo "  ok" || echo "  FAILED (file may not exist)"

echo "=== Done ==="
