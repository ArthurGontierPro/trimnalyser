#!/bin/bash
# A/B for the Clit trim mode: does cone-first conflict analysis produce a smaller
# (or even a different) cone than Grim — and does its trimmed proof still verify?
#
#   bash scripts/ab_clit.sh            # from ~/trimnalyser on the compute node, in tmux
#
# UNLIKE ab_propagate_unify.sh THIS IS A SINGLE-ARM RUN. The `clit` flag makes
# trimnalyseandcie (pipeline.jl:69-77) trim the SAME parsed proof twice in the SAME
# subprocess — Grim first, then Clit — writing grim_* and gclt_* columns side by side
# into one .out. The comparison is therefore paired per instance, on identical input
# bytes, under identical machine load. No checkout, no second arm, no reset.
#
# Inputs are the already-solved proofs from the propagate!/ruptrail A/B, so nothing is
# re-solved. That also gives us a Grim verification baseline for free: ab-ruptrail/
# cluster_results.csv reports veripb on these exact trimmed proofs (0 failures).

set -euo pipefail

REPO="$HOME/trimnalyser"
SCRATCH=/scratch/arthur
PROOFS="$SCRATCH/proofs"
SRC_PROOFS="${SRC_PROOFS:-$SCRATCH/proofs.ab-propagate-unify}"   # 825 solved .opb/.pbp pairs
INSTFILE="${INSTFILE:-$HOME/instances_stratified.txt}"
SUFFIX="${SUFFIX:-}"
TT="${TT:-600}"       # trim timeout, seconds — 10 min
VT="${VT:-600}"       # verif timeout, seconds — set explicitly, never left to default (see below)
STAMP="$(date +%Y%m%d-%H%M%S)"

OUTDIR="$REPO/ab-clit$SUFFIX"
GRIM_REF="$SCRATCH/smol-grim-ref$SUFFIX"      # Grim's .smol.*, moved aside before the run
DONE_MARKER="=== AB-CLIT-COMPLETE ==="

# vt= defaults to tt= (config.jl:80), so it is always passed explicitly here — a silent
# default is the kind of thing that only shows up as a wedged run at 3am.
#
# 600s, and the run does not lose anything by it. `verify()` checks the trimmed proof and
# then RE-checks the full one; only the full check is ever slow (observed 553s / 1152s /
# 2017s), while every smol verif in the 828-run finished in ~0s. The smol result is the
# one that tests Clit and the only one the analysis reads (veri_smol_verified) — the full
# proofs were already verified by the run that produced them. So capping at 600s truncates
# redundant work, not evidence. The first run used vt=6000 and spent 33 minutes on a single
# full-proof re-verification for nothing.
#
# No `solve` (proofs are on disk), no `resolv` (core iterations only add cost and blur
# the paired comparison). `overwrite` is required: smol_complete (pipeline.jl:42) would
# otherwise skip every instance outright, since .smol.* already exist.
# ARM=both      one subprocess runs Grim then Clit. tt is ONE `timeout` around the whole
#               subprocess (orchestrator.jl:219), so the two passes SHARE the budget, and
#               since Grim goes first the squeeze lands entirely on Clit. Cheap, paired,
#               but it truncates Clit on the slow instances — the ones that matter most.
# ARM=clit-only the `no` flag skips the Grim pass (pipeline.jl:67), so Clit runs alone
#               with a full tt to itself. Pair against the grim_* columns of a previous
#               ARM=both run, which already had the full budget for the same reason.
ARM="${ARM:-both}"
case "$ARM" in
    both)      MODEFLAGS=(clit) ;;
    clit-only) MODEFLAGS=(no clit) ;;
    *) echo "ARM must be 'both' or 'clit-only'" >&2; exit 1 ;;
esac
RUNFLAGS=(--threads 75,1 "${MODEFLAGS[@]}" verif keepraw overwrite
          "instfile=$INSTFILE" "tt=$TT" "vt=$VT" rand)

HARVEST_FILES=(cluster_results.csv graph_features.csv quick_stats.txt
               proof_survey.html classify_supplementals.html classify_supplementals.txt
               cone_vs_full.html var_order_stats.csv var_order_family_summary.csv)

# ── preflight ────────────────────────────────────────────────────────────────
case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) ;;
    *) echo "refusing to run off the compute node (hostname=$(hostname))" >&2; exit 1 ;;
esac
[[ -f "$INSTFILE" ]]                 || { echo "missing $INSTFILE" >&2; exit 1; }
[[ -d "$SRC_PROOFS" ]]               || { echo "missing input proofs $SRC_PROOFS" >&2; exit 1; }
[[ -x "$SCRATCH/veripb" ]]           || { echo "veripb missing — verif would silently no-op" >&2; exit 1; }
[[ -e "$OUTDIR" ]]                   && { echo "$OUTDIR exists — move it aside" >&2; exit 1; }
[[ -e "$GRIM_REF" ]]                 && { echo "$GRIM_REF exists — move it aside" >&2; exit 1; }
grep -q '"clit"' "$REPO/src/config.jl" || { echo "this checkout has no clit flag" >&2; exit 1; }

SRC_GB=$(du -sBG "$SRC_PROOFS" | cut -f1 | tr -dc '0-9')
FREE_GB=$(df -BG --output=avail "$SCRATCH" | tail -1 | tr -dc '0-9')
(( FREE_GB > SRC_GB + 200 )) || { echo "only ${FREE_GB}G free, need ~$((SRC_GB+200))G" >&2; exit 1; }

N_INST=$(grep -cve '^\s*#' -e '^\s*$' "$INSTFILE")
HEAD_SHA="$(git -C "$REPO" rev-parse --short HEAD)"
echo "=== clit A/B — $N_INST instances, tt=$TT vt=$VT, stamp=$STAMP ==="
echo "    TrimAnalyser $HEAD_SHA — Grim and Clit trim the same proof in the same process"

trap 'echo "=== AB-CLIT-EXIT $? ==="' EXIT

# ── stage inputs ─────────────────────────────────────────────────────────────
mkdir -p "$PROOFS"
if [[ -n "$(ls -A "$PROOFS")" ]]; then
    KEEP="$SCRATCH/proofs.saved-$STAMP"
    echo "proofs dir not empty — archiving to $KEEP"
    mv "$PROOFS" "$KEEP"; mkdir -p "$PROOFS"
fi

echo "=== staging inputs from $SRC_PROOFS (${SRC_GB}G) ==="
cp -a "$SRC_PROOFS/." "$PROOFS/"
rm -rf "$PROOFS/vis"

# Move Grim's trimmed proofs out of the way. Two reasons, both mandatory:
#   1. run_trim_subprocess checks `smol_complete(ins) && return :ok` (orchestrator.jl:241)
#      BEFORE inspecting the exit code. A stale .smol.* left in place would make a
#      timed-out instance report :ok, and verify() would then verify last night's file.
#   2. Clit overwrites .smol.opb/.smol.pbp (writeconedel takes no mode/prefix,
#      pipeline.jl:136) — so this is our only copy of the Grim output to compare against.
mkdir -p "$GRIM_REF"
find "$PROOFS" -maxdepth 1 -type f \( -name '*.smol.opb' -o -name '*.smol.pbp' \) \
     -exec mv -t "$GRIM_REF" {} +
echo "moved $(find "$GRIM_REF" -type f | wc -l) Grim .smol.* files to $GRIM_REF"
# Stale per-instance logs would be re-parsed by aggregate_results.jl.
find "$PROOFS" -maxdepth 1 -type f \( -name '*.out' -o -name '*.err' -o -name '*.done' \) -delete
echo "staged: $(find "$PROOFS" -maxdepth 1 -name '*.pbp' ! -name '*.smol.*' | wc -l) raw .pbp"

# ── run ──────────────────────────────────────────────────────────────────────
( cd "$REPO" && julia --project=. build_sysimage.jl )

started="$(date -Iseconds)"
load="$(uptime | sed 's/.*load average/load/'), $(free -g | awk '/^Mem:/{print $7" GB avail"}')"
echo "=== run started $started ($load) ==="
( cd "$REPO" && ./trimnalyser "${RUNFLAGS[@]}" )
finished="$(date -Iseconds)"

# ── harvest ──────────────────────────────────────────────────────────────────
mkdir -p "$OUTDIR"
stale="$REPO/stale-harvest-$STAMP"
for f in "${HARVEST_FILES[@]}"; do
    [[ -f "$REPO/$f" ]] && { mkdir -p "$stale"; mv "$REPO/$f" "$stale/"; }
done
[[ -d "$stale" ]] && echo "quarantined pre-existing harvest outputs in $stale"

if ( cd "$REPO" && bash scripts/harvest.sh ) > "$OUTDIR/harvest.log" 2>&1; then
    echo "harvest ok"
else
    echo "WARNING: harvest.sh failed (rc=$?) — see $OUTDIR/harvest.log" >&2
    tail -5 "$OUTDIR/harvest.log" >&2
fi
[[ -f "$REPO/cluster_results.csv" ]] || { echo "FATAL: no cluster_results.csv" >&2; exit 1; }
for f in "${HARVEST_FILES[@]}"; do
    [[ -f "$REPO/$f" ]] && mv "$REPO/$f" "$OUTDIR/"
done
cp "$INSTFILE" "$OUTDIR/instances.txt"

# ── byte-compare: did Clit change the trimmed proof at all? ──────────────────
# On LVg10g12 locally, Clit reproduced Grim's output byte for byte. If that holds at
# scale, the mode is a no-op and the choice is not worth its place in the heuristic chain.
#
# GATING IS MANDATORY. tt bounds the WHOLE subprocess — parse+Grim+write+parse+Clit+write
# — so on a slow instance the Grim pass can eat the budget and `timeout` kills the process
# before Clit finishes. .smol.* is then still Grim's own output from earlier in that same
# subprocess, smol_complete() reports :ok, and a naive compare scores the instance
# "identical" while Clit never ran. Worse, that bias is concentrated exactly on the big
# instances where Clit has the most room to differ. The smoke caught this on LVg10g16
# (Grim trim 210s of a 300s budget, gclt_total_cone empty).
#
# The `gclt TRIM TIME` line is written by writeout_trim only after the Clit pass
# completes, so it is the ground truth for "Clit actually ran on this instance".
report="$OUTDIR/smol-bytecompare.txt"
same=0; differ=0; missing=0; extra=0; truncated=0
: > "$report"
while IFS= read -r f; do
    base="$(basename "$f")"
    ins="${base%.smol.opb}"; ins="${ins%.smol.pbp}"
    if ! grep -q '^gclt TRIM TIME' "$PROOFS/$ins.out" 2>/dev/null; then
        truncated=$((truncated+1)); echo "NO_CLIT_PASS $base" >> "$report"; continue
    fi
    if [[ ! -f "$PROOFS/$base" ]]; then
        missing=$((missing+1)); echo "MISSING_IN_CLIT $base" >> "$report"
    elif cmp -s "$f" "$PROOFS/$base"; then
        same=$((same+1))
    else
        differ=$((differ+1))
        echo "DIFFER $base  grim=$(stat -c%s "$f") clit=$(stat -c%s "$PROOFS/$base") bytes" >> "$report"
    fi
done < <(find "$GRIM_REF" -maxdepth 1 -type f | sort)
while IFS= read -r f; do
    base="$(basename "$f")"
    [[ -f "$GRIM_REF/$base" ]] || { extra=$((extra+1)); echo "ONLY_IN_CLIT $base" >> "$report"; }
done < <(find "$PROOFS" -maxdepth 1 -type f \( -name '*.smol.opb' -o -name '*.smol.pbp' \) | sort)

{   echo "# trimmed proofs: Grim (ab-propagate-unify) vs Clit (this run)"
    echo "# counts are FILES (.smol.opb + .smol.pbp), not instances"
    echo "identical:        $same"
    echo "differ:           $differ"
    echo "missing in clit:  $missing"
    echo "only in clit:     $extra"
    echo "no clit pass:     $truncated   (tt=$TT budget spent by the Grim pass; excluded, not counted identical)"
} | tee "$OUTDIR/smol-bytecompare.summary"
cat "$OUTDIR/smol-bytecompare.summary" "$report" > "$report.tmp" && mv "$report.tmp" "$report"

cat > "$OUTDIR/README.md" <<EOF
# clit A/B — Grim vs Clit conflict analysis

Single run, $N_INST instances. \`clit\` trims each parsed proof twice in one subprocess
(Grim then Clit), so \`grim_*\` and \`gclt_*\` columns in \`cluster_results.csv\` are
paired per instance on identical input bytes.

\`\`\`bash
./trimnalyser ${RUNFLAGS[*]}
\`\`\`

| | |
|---|---|
| Host | \`$(hostname)\` |
| TrimAnalyser | \`$HEAD_SHA\` — $(git -C "$REPO" log -1 --pretty=%s) |
| Input proofs | \`$SRC_PROOFS\` (not re-solved) |
| Trim timeout | ${TT}s (bounds parse+Grim+write+parse+Clit+write combined) |
| Verif timeout | ${VT}s (pinned to the baseline run, not to tt) |
| Grim verif baseline | \`ab-ruptrail/cluster_results.csv\` — same proofs, 0 failures |
| Started | $started |
| Finished | $finished |
| Node at start | $load |

**Reading the verif column.** In batch mode \`verify()\` runs once, after the subprocess
(\`orchestrator.jl:404\`), on whatever \`.smol.*\` is on disk — and Clit wrote last. So
\`veri_smol_verified\` here describes **Clit's** proof. Grim's baseline is the
ab-ruptrail CSV.

Byte comparison of the trimmed proofs: see \`smol-bytecompare.summary\`.
EOF

mv "$PROOFS" "$SCRATCH/proofs.ab-clit$SUFFIX"
mkdir -p "$PROOFS"

echo
echo "=== done ==="
echo "  results:     $OUTDIR"
echo "  grim .smol:  $GRIM_REF"
echo "  clit proofs: $SCRATCH/proofs.ab-clit$SUFFIX"
echo
echo "next:"
echo "  python3 scripts/clit_vs_grim.py $OUTDIR/cluster_results.csv --baseline ab-ruptrail/cluster_results.csv"
echo "$DONE_MARKER"
