#!/bin/bash
# One arm of the M4.1 A/B on the five high-degree LV targets (g64 g76 g77 g84 g93).
#
#   bash scripts/ab_dense_targets.sh labels-for-analysis
#   bash scripts/ab_dense_targets.sh lazy-adjacency-relabelled
#
# Run ON THE COMPUTE NODE, inside tmux/screen (each arm is ~1-3 h).
#
# Isolation is by *directory rename*, never by the `proofs=` argument: a custom proofs
# dir is not forwarded to the trim subprocesses (orchestrator.jl:614), which makes every
# UNSAT instance report "no conclusion (truncated proof)" — exactly the metric under test.
# So each arm runs in the DEFAULT /scratch/arthur/proofs, which this script guarantees is
# empty at the start and archives under a per-arm name at the end. Nothing is deleted.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

BRANCH="${1:-}"
if [[ -z "$BRANCH" ]]; then
    echo "usage: bash scripts/ab_dense_targets.sh <glasgow-branch>" >&2
    exit 2
fi
LABEL="${BRANCH//\//-}"

GSS="$HOME/glasgow-subgraph-solver"
SCRATCH=/scratch/arthur
PROOFS="$SCRATCH/proofs"
INSTFILE="$REPO/instances_dense_targets.txt"
OUTDIR="$REPO/ab-$LABEL"
STAMP="$(date +%Y%m%d-%H%M%S)"

# ── preflight ────────────────────────────────────────────────────────────────
# Everything that can be checked before burning an hour of cluster time is checked here.
case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) ;;
    *) echo "refusing to run off the compute node (hostname=$(hostname))" >&2; exit 1 ;;
esac
[[ -d "$GSS/.git" ]]      || { echo "no Glasgow checkout at $GSS" >&2; exit 1; }
[[ -f "$INSTFILE" ]]      || { echo "missing $INSTFILE — copy it from the local repo" >&2; exit 1; }
[[ -d "$SCRATCH/newSIPbenchmarks" ]] || { echo "benchmarks missing: $SCRATCH/newSIPbenchmarks" >&2; exit 1; }
[[ -x "$SCRATCH/veripb" ]] || { echo "veripb missing at $SCRATCH/veripb — verif would silently no-op" >&2; exit 1; }
[[ -e "$OUTDIR" ]]        && { echo "$OUTDIR already exists — move it aside first" >&2; exit 1; }
# Checked here and not at step 5: `mv` into an existing directory would nest this arm's
# proofs inside the previous attempt's instead of failing.
[[ -e "$SCRATCH/proofs.ab-$LABEL" ]] && { echo "$SCRATCH/proofs.ab-$LABEL already exists — move it aside first" >&2; exit 1; }
# Untracked files are fine (they survive a checkout); only tracked modifications
# could be silently carried across branches and change what gets built.
if [[ -n "$(git -C "$GSS" status --porcelain --untracked-files=no)" ]]; then
    echo "Glasgow working tree has tracked modifications — commit or stash before switching branch" >&2
    git -C "$GSS" status --short --untracked-files=no >&2
    exit 1
fi
FREE_GB=$(df -BG --output=avail "$SCRATCH" | tail -1 | tr -dc '0-9')
(( FREE_GB > 400 )) || { echo "only ${FREE_GB}G free on $SCRATCH; one arm needs ~131G of raw proofs" >&2; exit 1; }

N_INST=$(grep -cve '^\s*#' -e '^\s*$' "$INSTFILE")

echo "=== arm: $BRANCH  ($N_INST instances, label=$LABEL, stamp=$STAMP) ==="

# ── 1. build the solver for this branch ──────────────────────────────────────
# GMP lives in ~/local since the 2026-07-08 reimage (no sudo, no system headers);
# the rpath is what lets the binary find libgmpxx at run time.
git -C "$GSS" checkout "$BRANCH"
GSS_SHA=$(git -C "$GSS" rev-parse --short HEAD)
GSS_SUBJ=$(git -C "$GSS" log -1 --pretty=%s)
if [[ ! -d "$GSS/build" ]]; then
    cmake -S "$GSS" -B "$GSS/build" \
        -DGMP_INCLUDE_DIR="$HOME/local/include" \
        -DGMP_LIBRARY="$HOME/local/lib/libgmp.so" \
        -DGMPXX_LIBRARY="$HOME/local/lib/libgmpxx.so" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,$HOME/local/lib"
fi
cmake --build "$GSS/build" -j 48
cp "$GSS/build/glasgow_subgraph_solver" "$SCRATCH/glasgow_subgraph_solver"
echo "solver: $BRANCH @ $GSS_SHA — $GSS_SUBJ"

# ── 2. guarantee an empty default proofs dir ─────────────────────────────────
# A leftover .done/.sat/.timeoutNNN/OOM sentinel would skip the instance outright
# (orchestrator.jl:340,431,435,635); a leftover .smol.* would be harvested as if this
# arm had produced it. Renaming sidesteps both without deleting anything.
mkdir -p "$PROOFS"
if [[ -n "$(ls -A "$PROOFS")" ]]; then
    KEEP="$SCRATCH/proofs.saved-$STAMP"
    echo "proofs dir not empty — archiving to $KEEP"
    mv "$PROOFS" "$KEEP"
    mkdir -p "$PROOFS"
fi

# ── 3. run ───────────────────────────────────────────────────────────────────
# maxmem stays at the default 50 GB: it is the quantity being compared against the
# 8-3 baseline, so raising it here would change the definition of failure.
STARTED="$(date -Iseconds)"
# Snapshot of what else is on the node: on a memory A/B, a competing job is the most
# plausible remaining confound, so record it rather than assume the node was idle.
LOAD_AT_START="$(uptime | sed 's/.*load average/load/'), $(free -g | awk '/^Mem:/{print $7" GB available"}')"
echo "=== run started $STARTED ($LOAD_AT_START) ==="
./trimnalyser --threads 75,1 solve resolv verif \
    "instfile=$INSTFILE" st=600 tt=6000 rand
FINISHED="$(date -Iseconds)"

# ── 4. harvest, then move the fixed-name outputs out of the way ──────────────
# harvest.sh hardcodes /scratch/arthur/proofs and writes cluster_results.csv etc. into
# the repo root, so it must run now and its outputs must be collected before the next arm.
# The repo root still holds the 8-3 harvest under those exact names: quarantine them first,
# so that a harvest step which fails midway cannot leave last run's file to be collected
# as if this arm had produced it.
HARVEST_FILES=(cluster_results.csv graph_features.csv quick_stats.txt
               proof_survey.html classify_supplementals.html classify_supplementals.txt
               cone_vs_full.html var_order_stats.csv var_order_family_summary.csv)
mkdir -p "$OUTDIR"
STALE="$REPO/stale-harvest-$STAMP"
for f in "${HARVEST_FILES[@]}"; do
    if [[ -f "$REPO/$f" ]]; then
        mkdir -p "$STALE"
        mv "$REPO/$f" "$STALE/"
    fi
done
[[ -d "$STALE" ]] && echo "quarantined pre-existing harvest outputs in $STALE"

bash scripts/harvest.sh 2>&1 | tee "$OUTDIR/harvest.log"

for f in "${HARVEST_FILES[@]}"; do
    if [[ -f "$REPO/$f" ]]; then
        mv "$REPO/$f" "$OUTDIR/"
    fi
done
cp "$INSTFILE" "$OUTDIR/instances.txt"

# ── 5. archive this arm's proofs, leaving an empty dir for the next one ──────
ARM_PROOFS="$SCRATCH/proofs.ab-$LABEL"
mv "$PROOFS" "$ARM_PROOFS"
mkdir -p "$PROOFS"

# ── 6. provenance ────────────────────────────────────────────────────────────
# output.log is cumulative across every run since June, so record the boundaries
# rather than trying to slice it here.
cat > "$OUTDIR/README.md" <<EOF
# A/B arm — Glasgow \`$BRANCH\`

Five high-degree LV targets (g64 g76 g77 g84 g93), $N_INST instances.

\`\`\`bash
./trimnalyser --threads 75,1 solve resolv verif instfile=instances_dense_targets.txt st=600 tt=6000 rand
\`\`\`

| | |
|---|---|
| Host | \`$(hostname)\` |
| Glasgow branch | \`$BRANCH\` |
| Glasgow commit | \`$GSS_SHA\` — $GSS_SUBJ |
| TrimAnalyser | \`$(git -C "$REPO" rev-parse --short HEAD)\` |
| Started | $STARTED |
| Finished | $FINISHED |
| Node state at start | $LOAD_AT_START |
| Memory cap | 50 GB/instance (default \`maxmem\`) |
| Solver timeout | \`st=600\` · trim timeout \`tt=6000\` |
| Raw proofs kept at | \`$ARM_PROOFS\` |

\`output.log\` is cumulative; this arm is the slice between the two timestamps above.
EOF

echo "=== arm done: $OUTDIR ==="
echo "raw proofs: $ARM_PROOFS   ($(du -sh "$ARM_PROOFS" | cut -f1))"
echo "next: bash scripts/ab_dense_targets.sh <other-branch>"
echo "then: python3 scripts/compare_runs.py ab-<A> ab-<B> -o ab-dense-targets.html"
