#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Bring every node to READY, in parallel. Runs from anywhere with ssh to the cluster.
#
#     bash scripts/setup_all_nodes.sh              # dist (if needed) + populate all nodes
#     bash scripts/setup_all_nodes.sh --verify     # verify only, change nothing
#     NODES="fataepyc-01 fataepyc-02" bash scripts/setup_all_nodes.sh
#     SKIP_DIST=1 bash scripts/setup_all_nodes.sh  # dist is already staged
#
# Two stages, in this order and not the other:
#   1. cluster_dist.sh on ONE node   — builds the pinned Glasgow revisions into shared
#                                      /cluster/arthur/dist. Shared NFS, so build once.
#   2. setup_node.sh on EVERY node   — copies dist onto that node's local /scratch.
#
# The split exists because $HOME and /cluster are shared but /scratch is not: building
# nine times would be nine times the work for one identical result, while copying is the
# part that genuinely has to happen per node.
# ══════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/.."

NODES="${NODES:-fataepyc-01 fataepyc-02 fataepyc-03 fataepyc-04 fataepyc-05 fataepyc-06 fataepyc-07 fataepyc-08 fataepyc-09}"
REPO="${REMOTE_REPO:-\$HOME/trimnalyser}"     # unexpanded: resolved on the remote side
BUILD_NODE="${BUILD_NODE:-}"
VERIFY_ONLY=0
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=1

LOGDIR="${LOGDIR:-/tmp/setup_all_nodes.$$}"
mkdir -p "$LOGDIR"

read -ra NODEARR <<< "$NODES"
echo "nodes: ${NODEARR[*]}"
echo "logs:  $LOGDIR"
echo

# ── Reachability ──────────────────────────────────────────────────────────────────────
# Checked up front: a node that is down should be reported as down, not as a build
# failure forty seconds into a compile.
echo "── reachability ─────────────────────────────────────────────────"
UP=()
for n in "${NODEARR[@]}"; do
    if timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" true 2>/dev/null; then
        UP+=("$n"); echo "  $n up"
    else
        echo "  $n UNREACHABLE" >&2
    fi
done
[[ ${#UP[@]} -gt 0 ]] || { echo "no nodes reachable" >&2; exit 1; }
echo

# ── Stage 1: build the shared dist, once ──────────────────────────────────────────────
if [[ $VERIFY_ONLY -eq 0 && "${SKIP_DIST:-0}" != "1" ]]; then
    BN="${BUILD_NODE:-${UP[0]}}"
    echo "── dist (on $BN) ────────────────────────────────────────────────"
    # SSH does not source .bashrc, so cmake/git/julia are not on PATH without `bash -lc`.
    ssh "$BN" "bash -lc 'cd $REPO && FORCE=${FORCE:-0} bash scripts/cluster_dist.sh'" 2>&1 \
        | tee "$LOGDIR/dist.log" | sed "s/^/  /"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "DIST FAILED — not touching any node's /scratch. See $LOGDIR/dist.log" >&2
        exit 1
    fi
    echo
fi

# ── Stage 2: populate every node, in parallel ─────────────────────────────────────────
ARG=""; [[ $VERIFY_ONLY -eq 1 ]] && ARG="--verify"
echo "── nodes ────────────────────────────────────────────────────────"
for n in "${UP[@]}"; do
    ( ssh "$n" "bash -lc 'cd $REPO && bash scripts/setup_node.sh $ARG'" >"$LOGDIR/$n.log" 2>&1
      echo $? > "$LOGDIR/$n.rc" ) &
done
wait

# ── Report ────────────────────────────────────────────────────────────────────────────
ready=0; broken=()
for n in "${UP[@]}"; do
    rc=$(cat "$LOGDIR/$n.rc" 2>/dev/null || echo 1)
    if [[ "$rc" == "0" ]]; then
        printf '  %-14s READY\n' "$n"; ((ready++))
    else
        printf '  %-14s NOT READY\n' "$n"; broken+=("$n")
        grep -E "FAIL|MISSING|error" "$LOGDIR/$n.log" | head -5 | sed 's/^/      /'
    fi
done
echo
echo "$ready/${#UP[@]} nodes ready   (logs in $LOGDIR)"
if [[ ${#broken[@]} -gt 0 ]]; then
    echo "not ready: ${broken[*]}   — full log: $LOGDIR/<node>.log" >&2
    exit 1
fi
