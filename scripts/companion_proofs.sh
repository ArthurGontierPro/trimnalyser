set -euo pipefail

MODE=run
[[ "${1:-}" == "--sync" || "${COMPANION_SYNC:-0}" == "1" ]] && MODE=sync

SCRATCH="${SCRATCH:-/scratch/arthur}"
ROOT="${COMPANION_ROOT:-$SCRATCH/companion}"
PROOFS="$ROOT/proofs/"
SRC="${COMPANION_SRC:-$HOME/trimnalyser-companion}"
UPSTREAM="${TRIMNALYSER_UPSTREAM:-$HOME/trimnalyser}"

THREADS="${THREADS:-92,1}" ST="${ST:-600}" STNOPL="${STNOPL:-60}"
TT="${TT:-6000}" MAXMEM="${MAXMEM:-32}"

# ── a checkout of our own ────────────────────────────────────────────────────────────
# This script does NOT move $SRC. It used to, and that was a footgun of exactly the kind
# the rest of this file exists to avoid: a second job (the cargo build, running out of the
# same tree) had its scripts swapped mid-flight, and the sysimage build died with them.
# One tree, one owner. Run `companion_proofs.sh --sync` when nothing else is using it.
if [[ "$MODE" == "sync" ]]; then
    if [[ ! -d "$SRC/.git" ]]; then
        echo "== cloning $UPSTREAM -> $SRC =="
        git clone --quiet "$UPSTREAM" "$SRC"
    fi
    # Point at the REAL origin, not at $UPSTREAM. Cloning from a local path makes that
    # path the new origin, and a fetch from it transfers refs/heads only — so a commit
    # that exists in $UPSTREAM merely as a remote-tracking ref would never arrive. That
    # is the normal state here: while the grid is running, $UPSTREAM's worktree is
    # deliberately pinned to the commit the live columns were launched at, and everything
    # newer is only in refs/remotes.
    ORIGIN_URL="$(git -C "$UPSTREAM" remote get-url origin 2>/dev/null || true)"
    [[ -n "$ORIGIN_URL" ]] && git -C "$SRC" remote set-url origin "$ORIGIN_URL"
    # Bounded: compute nodes reach the outside world only through the head, and an
    # unreachable remote hangs on connect rather than failing.
    timeout 120 git -C "$SRC" fetch --quiet --all --prune || echo "   fetch failed or timed out"
    WANT="${COMPANION_REF:-origin/$(git -C "$UPSTREAM" rev-parse --abbrev-ref HEAD)}"
    git -C "$SRC" checkout --quiet --force --detach "$WANT" 2>/dev/null || {
        echo "cannot check out $WANT in $SRC — is it pushed?" >&2; exit 1; }
    echo "== synced $SRC to $(git -C "$SRC" log --oneline -1) =="
    exit 0
fi

INSTFILE="${1:?usage: companion_proofs.sh <instfile> [config]   |   companion_proofs.sh --sync}"
CONFIG="${2:-gss-lazy}"

case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) ;;
    *) echo "refusing to run off a compute node (hostname=$(hostname))" >&2; exit 1 ;;
esac
[[ -f "$INSTFILE" ]] || { echo "missing instance list: $INSTFILE" >&2; exit 1; }
grep -qve '^\s*#' -e '^\s*$' "$INSTFILE" || { echo "instance list is empty" >&2; exit 1; }
grep -ve '^\s*#' -e '^\s*$' "$INSTFILE" | grep -q '/' && {
    echo "instance list holds paths, not names — run scripts/companion_sample.sh first" >&2; exit 1; }
[[ -d "$SRC/.git" ]] || { echo "no checkout at $SRC — run: bash $0 --sync" >&2; exit 1; }
mkdir -p "$PROOFS" "$ROOT/logs"
echo "== companion checkout at $(git -C "$SRC" log --oneline -1) =="

# Pin the binaries BEFORE julia starts: SOLVER_CONFIGS is a const dict built at module
# load, so gssbin() reads $GLASGOW_SUBGRAPH_SOLVER_<rev> exactly once.
# shellcheck source=/dev/null
source "$SRC/scripts/cluster_env.sh"
# ...but not the log root: the grid's is append-only and aggregated, ours is disposable.
export TRIMNALYSER_LOGS="$ROOT/logs/"
export TRIMNALYSER_BASE="$ROOT/"

for b in "$GLASGOW_SUBGRAPH_SOLVER_1ff87ba" "$VERIPB" "$TRIMNALYSER_GRAPHS"; do
    [[ -e "$b" ]] || { echo "MISSING $b" >&2; exit 1; }
done
FREE_GB=$(df -BG --output=avail "$SCRATCH" | tail -1 | tr -dc '0-9')
N=$(grep -cve '^\s*#' -e '^\s*$' "$INSTFILE")
(( FREE_GB > 500 )) || { echo "only ${FREE_GB}G free on $SCRATCH; keepraw needs headroom" >&2; exit 1; }

echo "=== stock proofs: $N instances, config=$CONFIG, st=$ST tt=$TT ==="
echo "    proofs -> $PROOFS   (kept: keepraw)"
echo "    logs   -> $TRIMNALYSER_LOGS"
echo "    free   -> ${FREE_GB}G"

# `keepraw` is the whole point. `overwrite` is deliberately NOT here: a resumed run must
# reuse the proofs it already produced, and overwrite bypasses every sentinel.
ARGS=(--threads "$THREADS" solve keepraw "config=$CONFIG"
      "instfile=$INSTFILE" "stnopl=$STNOPL" "st=$ST" "tt=$TT" "maxmem=$MAXMEM"
      "$PROOFS")
# shellcheck disable=SC2206
[[ -n "${EXTRA:-}" ]] && ARGS+=(${EXTRA})

echo "+ ./trimnalyser ${ARGS[*]}"
[[ "${DRYRUN:-0}" == "1" ]] && exit 0
cd "$SRC" && exec ./trimnalyser "${ARGS[@]}"
