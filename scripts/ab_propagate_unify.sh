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
# Overridable so the harness itself can be smoke-tested on a handful of instances
# before the real multi-hour run. ST/TT matter as much as INSTFILE: at the production
# tt=6000 a single cviu11 trim can run 100 minutes, so a smoke that inherits it has no
# bounded runtime at all.
#   INSTFILE=~/smoke.txt SUFFIX=-smoke ST=60 TT=300 bash ~/ab_propagate_unify.sh
INSTFILE="${INSTFILE:-$HOME/instances_stratified.txt}"  # outside $REPO: a tracked file would vanish on checkout
SUFFIX="${SUFFIX:-}"
ST="${ST:-600}"      # solver timeout, seconds
TT="${TT:-6000}"     # trim timeout, seconds (vt= defaults to tt=)
STAMP="$(date +%Y%m%d-%H%M%S)"

BASE_SHA=5e31074   # arm A: propagate!
NEW_SHA=d30f849    # arm B: unified ruptrail
ANALYSIS_REF="${ANALYSIS_REF:-main}"   # harvest/report scripts, identical in both arms
ARM_A="$REPO/ab-propagate$SUFFIX"
ARM_B="$REPO/ab-ruptrail$SUFFIX"
SMOL_STASH="$SCRATCH/smol-armA$SUFFIX"

RUNFLAGS=(--threads 75,1 solve resolv verif keepraw "instfile=$INSTFILE" "st=$ST" "tt=$TT" rand)

# Completion is detected by reading the log, not by pgrep: `pgrep -f <script>` also matches
# the launching shell and any polling shell whose own command line contains the pattern, so
# it never reaches zero. AB-HARNESS-EXIT is emitted from the EXIT trap and so appears on
# success AND failure; AB-HARNESS-COMPLETE only on success.
DONE_MARKER="=== AB-HARNESS-COMPLETE ==="

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
[[ -e "$SMOL_STASH" ]]               && { echo "$SMOL_STASH exists — move it aside" >&2; exit 1; }
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
on_exit() {
    local rc=$?
    echo "restoring $REPO to $ORIG_REF"
    git -C "$REPO" checkout --quiet --force "$ORIG_REF" || true
    echo "=== AB-HARNESS-EXIT $rc ==="
}
trap on_exit EXIT

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
    echo "=== arm $label: checkout $sha (analysis scripts pinned to $ANALYSIS_REF) ==="
    git -C "$REPO" checkout --quiet --force "$sha"
    # A bare checkout reverts scripts/ as well as src/, so each arm would be harvested by
    # its own commit's analysis code — a confound, and the reason arm A crashed on the
    # unfixed classify_supplementals.jl. Overlay one pinned version so the arms differ in
    # src/ only. (The analysis scripts are in fact identical between the two arms; this
    # just makes that guaranteed rather than incidental, and carries the crash fix.)
    git -C "$REPO" checkout --quiet "$ANALYSIS_REF" -- scripts/
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

    # Report generation must never cost us a finished arm: classify_supplementals.jl and the
    # HTML survey are downstream of the only output this A/B actually needs
    # (cluster_results.csv, written by step 1). So harvest failure is logged, not fatal —
    # but a missing cluster_results.csv still is.
    if ( cd "$REPO" && bash scripts/harvest.sh ) > "$outdir/harvest.log" 2>&1; then
        echo "harvest ok"
    else
        echo "WARNING: harvest.sh failed for arm $label (rc=$?) — see $outdir/harvest.log" >&2
        tail -5 "$outdir/harvest.log" >&2
    fi
    [[ -f "$REPO/cluster_results.csv" ]] || {
        echo "FATAL: arm $label produced no cluster_results.csv" >&2; exit 1; }
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
| Analysis scripts | pinned to \`$ANALYSIS_REF\` in both arms |
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
# set identical across arms.  Drop: .out/.err and every .coreN.* + vis/ so resolv
# restarts from iteration 0.  (.done is never written under keepraw — orchestrator:415.)
# Arm A's .smol.* MUST go, or smol_complete() (pipeline:42) skips the trim outright —
# but they are moved aside, not deleted: byte-comparing them against arm B's is the
# actual result this A/B is after, and it is far stronger than any CSV metric.
reset_between_arms() {
    echo "=== resetting $PROOFS for arm B ==="
    local before; before=$(find "$PROOFS" -type f | wc -l)
    rm -rf "$PROOFS/vis"
    mkdir -p "$SMOL_STASH"
    find "$PROOFS" -maxdepth 1 -type f \( -name '*.smol.opb' -o -name '*.smol.pbp' \) \
         ! -name '*.core*' -exec mv -t "$SMOL_STASH" {} +
    echo "stashed $(find "$SMOL_STASH" -type f | wc -l) arm-A .smol.* files in $SMOL_STASH"
    find "$PROOFS" -type f \
         ! \( \( -name '*.opb' -o -name '*.pbp' \) ! -name '*.core*' ! -name '*.smol.*' \) \
         ! -name '*.sat' ! -name '*.timeout*' \
         -delete
    echo "kept $(find "$PROOFS" -type f | wc -l) of $before files"
    echo "  raw proofs: $(find "$PROOFS" -name '*.pbp' | wc -l) .pbp / $(find "$PROOFS" -name '*.opb' | wc -l) .opb"
    echo "  skip sentinels kept: $(find "$PROOFS" -name '*.sat' | wc -l) .sat, $(find "$PROOFS" -name '*.timeout*' | wc -l) .timeout"
}

# The headline result: for every instance both arms trimmed, are the trimmed proofs
# identical byte for byte? Anything in DIFFER is a real behavioural change to explain.
compare_smol() {
    local report="$ARM_B/smol-bytecompare.txt"
    local same=0 differ=0 missing_b=0 extra_b=0
    : > "$report"
    local f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        if [[ ! -f "$PROOFS/$base" ]]; then
            missing_b=$((missing_b+1)); echo "MISSING_IN_B $base" >> "$report"
        elif cmp -s "$f" "$PROOFS/$base"; then
            same=$((same+1))
        else
            differ=$((differ+1))
            echo "DIFFER $base  A=$(stat -c%s "$f") B=$(stat -c%s "$PROOFS/$base") bytes" >> "$report"
        fi
    done < <(find "$SMOL_STASH" -maxdepth 1 -type f | sort)
    while IFS= read -r f; do
        base="$(basename "$f")"
        [[ -f "$SMOL_STASH/$base" ]] || { extra_b=$((extra_b+1)); echo "ONLY_IN_B $base" >> "$report"; }
    done < <(find "$PROOFS" -maxdepth 1 -type f \( -name '*.smol.opb' -o -name '*.smol.pbp' \) ! -name '*.core*' | sort)

    {   echo "# byte comparison of trimmed proofs, arm A ($BASE_SHA) vs arm B ($NEW_SHA)"
        echo "identical:      $same"
        echo "differ:         $differ"
        echo "missing in B:   $missing_b"
        echo "only in B:      $extra_b"
    } | tee "$ARM_B/smol-bytecompare.summary"
    cat "$ARM_B/smol-bytecompare.summary" "$report" > "$report.tmp" && mv "$report.tmp" "$report"
    if (( differ == 0 && missing_b == 0 && extra_b == 0 )); then
        echo "RESULT: every trimmed proof is byte-identical across the two arms."
    else
        echo "RESULT: $differ differ / $missing_b missing / $extra_b extra — see $report"
    fi
}

# ── run ──────────────────────────────────────────────────────────────────────
run_arm "$BASE_SHA" A "$ARM_A"
reset_between_arms
run_arm "$NEW_SHA"  B "$ARM_B"
compare_smol

mv "$PROOFS" "$SCRATCH/proofs.ab-propagate-unify$SUFFIX"
mkdir -p "$PROOFS"

echo
echo "=== both arms done ==="
echo "  $ARM_A   (propagate!)"
echo "  $ARM_B   (ruptrail)"
echo "  raw proofs: $SCRATCH/proofs.ab-propagate-unify$SUFFIX"
echo
echo "next:"
echo "  cd $REPO && git checkout $NEW_SHA"
echo "  python3 scripts/compare_runs.py ab-propagate$SUFFIX ab-ruptrail$SUFFIX -o ab-propagate-unify$SUFFIX.html --csv"
echo "$DONE_MARKER"
