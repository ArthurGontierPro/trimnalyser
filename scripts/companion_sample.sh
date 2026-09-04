#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Build the two instance lists the companion comparison runs on.
#
#   set C  (companion)   the companion's OWN SIP evaluation set, exactly as shipped in
#                        benches/solver_instances/gss/ on origin/feature_trimmer:
#                        5 LV pairs + 8 bio.  This is the set behind the 6.85 they
#                        publish, so it is the set \ph{XLV}/\ph{YLV} must be measured on.
#                        Our own Glasgow produces the proofs — "the two tools on our
#                        machine" (sec:compress) — not their shipped .pbp, which came
#                        from a different solver revision.
#
#   set S  (stratified)  our four families, subsampled from the stratified list the
#                        propagate!/ruptrail A/B already used.  scalefree is dropped:
#                        3 instances is not a family and the paper reports four.
#
# Usage:  bash scripts/companion_sample.sh <outdir> [per_family]
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

OUTDIR="${1:?usage: companion_sample.sh <outdir> [per_family]}"
PER="${2:-40}"
STRAT="${STRATFILE:-$HOME/instances_stratified.txt}"
SEED="${SEED:-20260904}"
mkdir -p "$OUTDIR"

# ── set C ────────────────────────────────────────────────────────────────────────────
# Hardcoded rather than read from the branch: the files are git-lfs pointers, so
# `git ls-tree` sees the names but a checkout without lfs credentials gets no content.
# The names are all we need — we regenerate the proofs ourselves.
cat > "$OUTDIR/set-companion.txt" <<'EOF'
# The companion trimmer's own gss evaluation set
# (origin/feature_trimmer:benches/solver_instances/gss/), names only.
LVg19g36
LVg2g3
LVg34g51
LVg5g24
LVg7g25
bio027084
bio044053
bio079196
bio080075
bio096149
bio151166
bio156095
EOF
# bio has 8 pairs in their tree but one name repeats a target; count what we wrote.
echo "set C: $(grep -cve '^#' -e '^$' "$OUTDIR/set-companion.txt") instances -> $OUTDIR/set-companion.txt"

# ── set S ────────────────────────────────────────────────────────────────────────────
[[ -f "$STRAT" ]] || { echo "missing stratified list: $STRAT" >&2; exit 1; }
# The stratified file is <patternpath>TAB<targetpath>; both trimnalyser (instfile=) and
# companion_compare.sh want the INSTANCE NAME, so convert here — once, visibly — with the
# same rule as paths_to_instance (orchestrator.jl:55).  Keeping the conversion in one
# place is the point: a name built by a different rule silently addresses a proof that
# does not exist, and the harness would report `noproof` for the whole set.
to_name() {
    awk -F'\t' '
      function base(p){ n=split(p,a,"/"); return a[n] }
      {
        pat=$1; tar=$2; pb=base(pat); tb=base(tar)
        if (pat ~ /\/LV\//)                    print "LV" pb tb
        else if (pat ~ /\/biochemicalReactions\//) { sub(/\.txt$/,"",pb); sub(/\.txt$/,"",tb); print "bio" pb tb }
        else if (pat ~ /\/images-CVIU11\//)    { sub(/^pattern/,"",pb); sub(/^target/,"",tb); print "cviu11_p" pb "_t" tb }
        else if (pat ~ /\/meshes-CVIU11\//)    { sub(/^pattern/,"",pb); sub(/^target/,"",tb); print "mesh11_p" pb "_t" tb }
      }'
}
# Deterministic subsample: seeded shuffle, PER per family, families in a fixed order so
# the file is reproducible from the seed alone.
{
  echo "# stratified subsample of $STRAT, as instance names"
  echo "# seed=$SEED per_family=$PER  (scalefree excluded: 3 instances, not a family)"
} > "$OUTDIR/set-stratified.txt"
for fam in LV biochemicalReactions images-CVIU11 meshes-CVIU11; do
    n=$(grep -F "/$fam/" "$STRAT" | shuf --random-source=<(yes "$SEED") -n "$PER" | sort \
        | to_name | tee -a "$OUTDIR/set-stratified.txt" | wc -l)
    printf "  %-22s %s\n" "$fam" "$n"
done
echo "set S: $(grep -cve '^#' -e '^$' "$OUTDIR/set-stratified.txt") instances -> $OUTDIR/set-stratified.txt"
