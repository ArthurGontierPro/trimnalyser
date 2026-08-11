#!/bin/bash
# A/B for the propagate!-removal (commit d30f849): does routing the initial UNSAT
# contradiction through ruptrail instead of propagate! change any cone?
#
#   cp scripts/ab_propagate_unify.sh ~/ab_propagate_unify.sh   # MUST run from outside the repo
#   bash ~/ab_propagate_unify.sh
#
# Run ON THE COMPUTE NODE, inside tmux (arm A is the long one).
#
# Why outside the repo: this script git-checkouts two commits of the repo it lives in.
# The script is tracked in the NEW commit only, so a checkout of the base commit would
# delete it out from under bash.
#
# Unlike ab_dense_targets.sh, the two arms differ only in TrimAnalyser code — the solver
# binary and every input proof are identical. So arm A runs with `keepraw` and arm B
# reuses its raw .opb/.pbp (run_instance_batch:351 skips solve when a proof with a
# conclusion already exists). That halves the cluster time AND removes solver
# nondeterminism from the comparison: both arms trim literally the same bytes.

set -euo pipefail

REPO="$HOME/trimnalyser"
GSS_BIN=/scratch/arthur/glasgow_subgraph_solver
SCRATCH=/scratch/arthur
PROOFS="$SCRATCH/proofs"
INSTFILE="$HOME/instances_stratified.txt"   # outside $REPO: a tracked file would vanish on checkout
STAMP="$(date +%Y%m%d-%H%M%S)"

BASE_SHA=5e31074   # arm A: propagate!
NEW_SHA=d30f849    # arm B: unified ruptrail
ARM_A="$REPO/ab-propagate"
ARM_B="$REPO/ab-ruptrail"

RUNFLAGS=(--threads 75,1 solve resolv verif keepraw "instfile=$INSTFILE" st=600 tt=6000 rand)

HARVEST_FILES=(cluster_results.csv graph_features.csv quick_stats.txt
               proof_survey.html classify_supplementals.html classify_supplementals.txt
               cone_vs_full.html var_order_stats.csv var_order_family_summary.csv)

# ── preflight ────────────────────────────────────────────────────────────────
case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) ;;
    *) echo "refusing to run off the compute node (hostname=$(hostname))" >&2; exit 1 ;;
esac
SELF="$(cd "$(dirname "$0")" && pwd -P)"; REPO_P="$(cd "$REPO" && pwd -P)"
[[ "$SELF" == "$REPO_P"/* || "$SELF" == "$REPO_P" ]] && {
    echo "this script is inside $REPO_P — copy it to \$HOME and run it from there" >&2; exit 1; }
[[ -f "$INSTFILE" ]]                 || { echo "missing $INSTFILE" >&2; exit 1; }
[[ -d "$SCRATCH/newSIPbenchmarks" ]] || { echo "benchmarks missing" >&2; exit 1; }
[[ -x "$GSS_BIN" ]]                  || { echo "solver missing at $GSS_BIN" >&2; exit 1; }
[[ -x "$SCRATCH/veripb" ]]           || { echo "veripb missing — verif would silently no-op" >&2; exit 1; }
[[ -e "$ARM_A" || -e "$ARM_B" ]]     && { echo "$ARM_A / $ARM_B exist — move them aside" >&2; exit 1; }
if [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]; then
    echo "repo has tracked modifications — commit or stash (both arms checkout a commit)" >&2
    git -C "$REPO" status --short --untracked-files=no >&2; exit 1
fi
for sha in "$BASE_SHA" "$NEW_SHA"; do
    git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" >/dev/null \
        || { echo "commit $sha not in $REPO — git fetch first" >&2; exit 1; }
done
FREE_GB=$(df -BG --output=avail "$SCRATCH" | tail -1 | tr -dc '0-9')
(( FREE_GB > 600 )) || { echo "only ${FREE_GB}G free on $SCRATCH; keepraw needs headroom" >&2; exit 1; }

# Both arms detach HEAD; put the repo back where it was however we exit.
ORIG_REF="$(git -C "$REPO" symbolic-ref --quiet --short HEAD || git -C "$REPO" rev-parse HEAD)"
trap 'echo "restoring $REPO to $ORIG_REF"; git -C "$REPO" checkout --quiet "$ORIG_REF"' EXIT

mkdir -p "$PROOFS"
if [[ -n "$(ls -A "$PROOFS")" ]]; then
    KEEP="$SCRATCH/proofs.saved-$STAMP"
    echo "proofs dir not empty — archiving to $KEEP"
    mv "$PROOFS" "$KEEP"; mkdir -p "$PROOFS"
fi

N_INST=$(grep -cve '^\s*#' -e '^\s*$' "$INSTFILE")
echo "=== propagate! A/B — $N_INST instances, stamp=$STAMP ==="
echo "    arm A $BASE_SHA (propagate!)  ->  arm B $NEW_SHA (ruptrail)"

# ── helpers ──────────────────────────────────────────────────────────────────
run_arm() {                                     # $1=sha  $2=label  $3=outdir
    local sha="$1" label="$2" outdir="$3"
    echo "=== arm $label: checkout $sha ==="
    git -C "$REPO" checkout --quiet "$sha"
    ( cd "$REPO" && julia --project=. build_sysimage.jl )   # src changed between arms

    local started; started="$(date -Iseconds)"
    local load; load="$(uptime | sed 's/.*load average/load/'), $(free -g | awk '/^Mem:/{print $7" GB avail"}')"
    echo "=== arm $label run started $started ($load) ==="
    ( cd "$REPO" && ./trimnalyser "${RUNFLAGS[@]}" )
    local finished; finished="$(date -Iseconds)"

    # harvest.sh writes fixed names into the repo root; quarantine any pre-existing ones
    # so a half-failed harvest cannot leave the other arm's file to be collected here.
    mkdir -p "$outdir"
    local stale="$REPO/stale-harvest-$STAMP-$label"
    for f in "${HARVEST_FILES[@]}"; do
        [[ -f "$REPO/$f" ]] && { mkdir -p "$stale"; mv "$REPO/$f" "$stale/"; }
    done
    [[ -d "$stale" ]] && echo "quarantined pre-existing harvest outputs in $stale"

    ( cd "$REPO" && bash scripts/harvest.sh ) 2>&1 | tee "$outdir/harvest.log"
    for f in "${HARVEST_FILES[@]}"; do
        [[ -f "$REPO/$f" ]] && mv "$REPO/$f" "$outdir/"
    done
    cp "$INSTFILE" "$outdir/instances.txt"

    cat > "$outdir/README.md" <<EOF
# A/B arm $label — TrimAnalyser \`$sha\`

$N_INST instances, stratified sample (\`select_instances.jl\`, from the 6-29 full run).

\`\`\`bash
./trimnalyser ${RUNFLAGS[*]}
\`\`\`

| | |
|---|---|
| Host | \`$(hostname)\` |
| TrimAnalyser | \`$sha\` — $(git -C "$REPO" log -1 --pretty=%s) |
| Glasgow binary | \`$GSS_BIN\` (identical in both arms) |
| Started | $started |
| Finished | $finished |
| Node at start | $load |
| Solve | $( [[ "$label" == A ]] && echo "run fresh" || echo "REUSED from arm A (identical input proofs)" ) |

\`output.log\` is cumulative; this arm is the slice between the two timestamps.
EOF
    echo "=== arm $label done: $outdir ==="
}

# Strip every arm-A output but keep the inputs, so arm B re-trims the same bytes.
# Keep: <ins>.opb/.pbp (non-core), .sat, .timeoutNNN   — .sat/.timeout keep the skip
# set identical across arms.  Drop: .done (else the instance is skipped outright),
# .smol.* (else trimnalyseandcie:42 smol_complete() skips the trim), .out/.err,
# and every .coreN.* + vis/ so resolv restarts from iteration 0.
reset_between_arms() {
    echo "=== resetting $PROOFS for arm B ==="
    local before; before=$(find "$PROOFS" -type f | wc -l)
    rm -rf "$PROOFS/vis"
    find "$PROOFS" -type f \
         ! \( \( -name '*.opb' -o -name '*.pbp' \) ! -name '*.core*' ! -name '*.smol.*' \) \
         ! -name '*.sat' ! -name '*.timeout*' \
         -delete
    echo "kept $(find "$PROOFS" -type f | wc -l) of $before files"
    echo "  raw proofs: $(find "$PROOFS" -name '*.pbp' | wc -l) .pbp / $(find "$PROOFS" -name '*.opb' | wc -l) .opb"
    echo "  skip sentinels kept: $(find "$PROOFS" -name '*.sat' | wc -l) .sat, $(find "$PROOFS" -name '*.timeout*' | wc -l) .timeout"
}

# ── run ──────────────────────────────────────────────────────────────────────
run_arm "$BASE_SHA" A "$ARM_A"
reset_between_arms
run_arm "$NEW_SHA"  B "$ARM_B"

mv "$PROOFS" "$SCRATCH/proofs.ab-propagate-unify"
mkdir -p "$PROOFS"

echo
echo "=== both arms done ==="
echo "  $ARM_A   (propagate!)"
echo "  $ARM_B   (ruptrail)"
echo "  raw proofs: $SCRATCH/proofs.ab-propagate-unify"
echo
echo "next:"
echo "  cd $REPO && git checkout $NEW_SHA"
echo "  python3 scripts/compare_runs.py ab-propagate ab-ruptrail -o ab-propagate-unify.html --csv"
