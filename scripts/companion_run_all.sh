#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# The companion comparison at full scale, over the whole SIP suite.
#
# Why this exists rather than just pointing companion_proofs.sh at `allgraphs`: the
# two-phase shape (produce every stock proof, then compare) needs every raw proof on disk
# at once. At 25,590 instances that is the ~13 TB that exhausted /scratch before. So the
# suite is processed in CHUNKS, and each chunk's proofs are deleted the moment its rows
# are in the CSV. Peak disk is one chunk, not one suite.
#
#   bash scripts/companion_run_all.sh <shard> <nshards>
#
# The instance list is shuffled with a FIXED SEED and then dealt out round-robin to the
# shards, so (a) the shards are disjoint and reproducible from the seed alone, and (b)
# each one walks the suite in random order. That second property is the important one:
# a run that is stopped early — and this one will be, it is a weekend job on a suite that
# takes days — leaves an UNBIASED sample rather than "everything whose name starts with b".
#
# Resumable at chunk granularity: a chunk with a `.done` marker is skipped, so re-running
# the same command after an interruption continues where it stopped.
#
# Environment:
#   ALLFILE   instance list, one name per line (see scripts/dump_instances.jl)
#   OUTDIR    default /scratch/arthur/companion-full
#   CHUNK     instances per chunk           (default 96)
#   JOBS      concurrent instances in the compare phase (default 24)
#   THREADS   julia --threads for the solve phase      (default 92,1)
#   ST STNOPL TT VT MAXMEM   timeouts, seconds
#   CONFIG    solver configuration          (default gss-lazy)
#   SEED      shuffle seed                  (default 20260904)
#   ARMS      which trimmers                (default "base ta ft tb")
# ══════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SHARD="${1:?usage: companion_run_all.sh <shard> <nshards>   (shard is 1-based)}"
NSHARD="${2:?}"
[[ "$SHARD" =~ ^[0-9]+$ && "$NSHARD" =~ ^[0-9]+$ && $SHARD -ge 1 && $SHARD -le $NSHARD ]] \
    || { echo "shard must be 1..nshards" >&2; exit 1; }

case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) ;;
    *) echo "refusing to run off a compute node (hostname=$(hostname))" >&2; exit 1 ;;
esac

SCRATCH="${SCRATCH:-/scratch/arthur}"
OUTDIR="${OUTDIR:-$SCRATCH/companion-full}"
SRC="${COMPANION_SRC:-$HOME/trimnalyser-companion}"
ALLFILE="${ALLFILE:-$HOME/companion-sets/all-instances.txt}"
CHUNK="${CHUNK:-96}"       JOBS="${JOBS:-24}"     THREADS="${THREADS:-92,1}"
ST="${ST:-600}"            STNOPL="${STNOPL:-60}" TT="${TT:-1800}"
VT="${VT:-1800}"           MAXMEM="${MAXMEM:-32}" CONFIG="${CONFIG:-gss-lazy}"
SEED="${SEED:-20260904}"   ARMS="${ARMS:-base ta ft tb}"

[[ -f "$ALLFILE" ]] || { echo "missing instance list: $ALLFILE" >&2; exit 1; }
[[ -d "$SRC/.git" ]] || { echo "missing companion checkout: $SRC" >&2; exit 1; }
mkdir -p "$OUTDIR"/{chunks,csv,proofs,logs}

# shellcheck source=/dev/null
source "$SRC/scripts/cluster_env.sh"
export TRIMNALYSER_LOGS="$OUTDIR/logs/"
export TRIMNALYSER_BASE="$OUTDIR/"
for b in "$GLASGOW_SUBGRAPH_SOLVER_1ff87ba" "$VERIPB" "$TRIMNALYSER_GRAPHS"; do
    [[ -e "$b" ]] || { echo "MISSING $b" >&2; exit 1; }
done

# ── the shard's work list ────────────────────────────────────────────────────────────
SHUF="$OUTDIR/shard-$SHARD-of-$NSHARD.txt"
if [[ ! -s "$SHUF" ]]; then
    # `shuf --random-source` makes the permutation a pure function of the seed, so every
    # shard on every node deals from the same deck and the shards stay disjoint.
    grep -ve '^\s*#' -e '^\s*$' "$ALLFILE" \
      | shuf --random-source=<(yes "$SEED") \
      | awk -v s="$SHARD" -v n="$NSHARD" 'NR % n == (s % n)' > "$SHUF"
fi
N=$(wc -l < "$SHUF")
NCHUNK=$(( (N + CHUNK - 1) / CHUNK ))
echo "════════════════════════════════════════════════════════════════════════"
echo " companion full run — shard $SHARD/$NSHARD on $(hostname -s)"
echo "   instances   $N   in $NCHUNK chunk(s) of $CHUNK"
echo "   arms        $ARMS"
echo "   timeouts    st=$ST tt=$TT vt=$VT   jobs=$JOBS threads=$THREADS"
echo "   out         $OUTDIR"
echo "   checkout    $(git -C "$SRC" log --oneline -1)"
echo "════════════════════════════════════════════════════════════════════════"
[[ "${DRYRUN:-0}" == "1" ]] && exit 0

# ── binary stamp for the whole shard ─────────────────────────────────────────────────
# compare-all.csv accumulates chunks over days. If a trimmer is rebuilt between chunks the
# column silently becomes two populations, and nothing in the CSV says so. Stamp once, and
# refuse to continue against a different stamp: better a loud stop than a mixed column.
STAMP="$OUTDIR/BINARIES.txt"
{
    for b in "$VERIPB" "${VERIPB_FT:-/scratch/arthur/veripb_ft}" "${VERIPB_TB:-/scratch/arthur/veripb_tb}"; do
        if [[ -x "$b" ]]; then printf '%s %s\n' "$(sha256sum "$b" | cut -c1-16)" "$(basename "$b")"
        else printf 'absent %s\n' "$(basename "$b")"; fi
    done
    printf '%s trimnalyser\n' "$(git -C "$SRC" rev-parse --short HEAD)"
} > "$STAMP.new"
if [[ -f "$STAMP" ]] && ! diff -q "$STAMP" "$STAMP.new" >/dev/null; then
    echo "REFUSING TO CONTINUE: the binaries changed since this output directory was started." >&2
    diff "$STAMP" "$STAMP.new" >&2
    echo "Move $OUTDIR aside (its rows were produced by the older binaries) or point OUTDIR elsewhere." >&2
    exit 1
fi
mv "$STAMP.new" "$STAMP"
echo "   binaries    $(tr '\n' ' ' < "$STAMP")"

cd "$SRC"
for ((c = 1; c <= NCHUNK; c++)); do
    tag=$(printf 'c%04d' "$c")
    marker="$OUTDIR/chunks/$tag.done"
    [[ -f "$marker" ]] && { echo "[$tag] already done — skipping"; continue; }
    inst="$OUTDIR/chunks/$tag.txt"
    sed -n "$(( (c-1)*CHUNK + 1 )),$(( c*CHUNK ))p" "$SHUF" > "$inst"
    [[ -s "$inst" ]] || { touch "$marker"; continue; }
    pdir="$OUTDIR/proofs/$tag/"
    mkdir -p "$pdir"

    echo
    echo "════ [$tag] $(wc -l < "$inst") instances — $(date -Iseconds) ════"
    df -h "$SCRATCH" | tail -1 | sed 's/^/  disk: /'

    # ── solve, keeping the raw proof for the trimmers to read ────────────────────────
    echo "── [$tag] solve"
    ./trimnalyser --threads "$THREADS" solve keepraw "config=$CONFIG" \
        "instfile=$inst" "stnopl=$STNOPL" "st=$ST" "tt=$TT" "maxmem=$MAXMEM" "$pdir" \
        || echo "  [$tag] solve phase returned $? — continuing with whatever it produced"

    # ── compare every trimmer on those proofs ────────────────────────────────────────
    echo "── [$tag] compare"
    TRIMNALYSER_REPO="$SRC" JOBS="$JOBS" TT="$TT" VT="$VT" ARMS="$ARMS" KEEP=0 \
      bash scripts/companion_compare.sh "$inst" "$pdir" "$OUTDIR/csv/$tag.csv" \
        || echo "  [$tag] compare returned $? — keeping whatever rows landed"

    # ── bank the rows, then reclaim the disk ─────────────────────────────────────────
    if [[ -s "$OUTDIR/csv/$tag.csv" ]]; then
        if [[ ! -s "$OUTDIR/compare-all.csv" ]]; then
            cp "$OUTDIR/csv/$tag.csv" "$OUTDIR/compare-all.csv"
        else
            tail -n +2 "$OUTDIR/csv/$tag.csv" >> "$OUTDIR/compare-all.csv"
        fi
        echo "  [$tag] banked $(( $(wc -l < "$OUTDIR/csv/$tag.csv") - 1 )) rows;" \
             "total $(( $(wc -l < "$OUTDIR/compare-all.csv") - 1 ))"
    else
        echo "  [$tag] produced no rows"
    fi
    # The per-chunk proof tree is the whole reason this is chunked. Its own directory, so
    # this is one rm -rf and cannot reach a neighbouring chunk's files.
    rm -rf "$pdir" "$OUTDIR/csv/$tag.parts"
    touch "$marker"
    echo "  [$tag] done $(date -Iseconds)"
done
echo
echo "════ SHARD $SHARD/$NSHARD COMPLETE $(date -Iseconds) ════"
echo "rows: $(( $(wc -l < "$OUTDIR/compare-all.csv" 2>/dev/null || echo 1) - 1 ))"
