#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# One column of the paper's configuration grid, end to end.
#
# The pipeline this drives (timeouts are the `tl` values, in seconds at scale 1):
#
#   tl 60    solve, no proof logging          <- a proves=false config STOPS here;
#    |                                           that solve IS its table cell
#    +- ok? tl 600  solve with proof logging  <- gate: never pay for logging on an
#         |                                       instance that is hopeless without it
#         +- ok? tl 6000  veripb --elaborate  (full)
#               |
#               +- ok? tl 6000  cakePB on the elaborated proof
#               +- delete elaborated proof     -+ siblings, NOT children of the cake
#               +- tl 6000  trimnalyser        -+ gate: the trim runs whatever VeriPB
#               +- delete original proof          said, because "the full proof could
#               |                                 not be certified and the trimmed one
#               |                                 could" is the result we are after
#               +- ok? tl 6000  veripb --elaborate (trimmed) -> cakePB -> delete
#                     +- if cake AND resolve both succeeded: recurse on coreN
#
# Both solvers go through it. For a lad-* configuration the OPB is LAD's own `-O` model
# (byte-identical to cake_pb_iso's encoder), so the same trim/verify/cake stages apply
# with no special-casing beyond which Cake binary can make which claim — see certify()
# in src/output.jl.
#
# Usage:
#   bash scripts/bench_config.sh <config> [scale] [instance]
#
#   <config>    a key of SOLVER_CONFIGS (src/config.jl); `list` prints them
#   [scale]     divides every timeout (default 1). Use 60 for a smoke test.
#   [instance]  run this one instance instead of the whole benchmark set
#
# Environment:
#   THREADS   julia --threads value            (default 92,1)
#   MAXMEM    per-instance memory cap, GB      (default 50)
#   MINNODES / MAXNODES   instance size filter (default: unset = all)
#   EXTRA     extra args passed to ./trimnalyser (e.g. "nosys overwrite")
#   DRYRUN=1  print the command and exit
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
cd "$(dirname "$0")/.."

# The agreed tree's timeouts, at scale 1.
BASE_STNOPL=60 BASE_ST=600 BASE_TT=6000

configs() { grep -oP '^\s*"\K[a-z0-9-]+(?="\s*=>\s*SolverConfig)' src/config.jl; }

if [[ $# -lt 1 || "${1:-}" == "list" ]]; then
    echo "usage: bash scripts/bench_config.sh <config> [scale] [instance]"
    echo "configs:"; configs | sed 's/^/  /'
    exit 1
fi

CONFIG="$1"; SCALE="${2:-1}"; INSTANCE="${3:-}"
configs | grep -qx "$CONFIG" || { echo "unknown config: $CONFIG" >&2
                                  echo "known:"; configs | sed 's/^/  /' >&2; exit 1; }
[[ "$SCALE" =~ ^[0-9]+$ ]] && [[ "$SCALE" -ge 1 ]] || { echo "scale must be a positive integer" >&2; exit 1; }

# Never round a timeout down to zero: st=0 and tt=0 mean "no limit", and stnopl=0 disables
# the tier-1 solve outright, so a large scale would silently change the pipeline shape.
div() { local v=$(( $1 / SCALE )); (( v < 1 )) && v=1; echo "$v"; }
STNOPL=$(div $BASE_STNOPL); ST=$(div $BASE_ST); TT=$(div $BASE_TT)
VT=$TT; CT=$TT

THREADS="${THREADS:-92,1}"
MAXMEM="${MAXMEM:-50}"

# ── Preflight ─────────────────────────────────────────────────────────────────────────
# Every one of these fails SOFTLY at run time — a missing veripb prints one yellow line
# and completes the whole run unverified — so they are checked up front instead.
KIND=$(sed -n "s/^\s*\"$CONFIG\"\s*=>\s*SolverConfig(\"\([a-z]*\)\".*/\1/p" src/config.jl)
case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*) CLUSTER=1 ;;
    *)                         CLUSTER=0 ;;
esac
# Pin the binaries, cluster only — cluster_env.sh points everything at node-local /scratch,
# which does not exist on the laptop. Sourced rather than duplicated so a column launched
# by hand gets exactly what run_grid.sh gives it, and sourced HERE because it must be in
# the environment before julia starts: SOLVER_CONFIGS is a const dict built at module load,
# so gssbin() reads $GLASGOW_SUBGRAPH_SOLVER_<rev> exactly once. Values already exported
# win, so an explicit override on the command line still takes effect.
if [[ $CLUSTER -eq 1 && -f scripts/cluster_env.sh ]]; then
    # shellcheck source=/dev/null
    source scripts/cluster_env.sh
fi
if [[ $CLUSTER -eq 1 ]]; then
    SOLVER_GSS="${GLASGOW_SUBGRAPH_SOLVER:-/scratch/arthur/glasgow_subgraph_solver}"
    SOLVER_LAD="${LAD_SOLVER:-/scratch/arthur/lad}"
    VERIPB="${VERIPB:-/scratch/arthur/veripb}"
    CAKE_PB="${CAKE_PB:-/scratch/arthur/cake_pb}"
    CAKE_PB_ISO="${CAKE_PB_ISO:-/scratch/arthur/cake_pb_iso}"
    GRAPHS="${TRIMNALYSER_GRAPHS:-/scratch/arthur/newSIPbenchmarks}"
    LOGS="${TRIMNALYSER_LOGS:-/cluster/arthur/logs}"
else
    SOLVER_GSS="${GLASGOW_SUBGRAPH_SOLVER:-/home/arthur_gla/veriPB/subgraphsolver/glasgow-subgraph-solver/build/glasgow_subgraph_solver}"
    SOLVER_LAD="${LAD_SOLVER:-/home/arthur_gla/ladveri/main}"
    VERIPB="${VERIPB:-/home/arthur_gla/veriPB/trim/VeriPB/target/release/veripb}"
    CAKE_PB="${CAKE_PB:-/home/arthur_gla/CakePB-dev/cake_pb}"
    CAKE_PB_ISO="${CAKE_PB_ISO:-/home/arthur_gla/CakePB-dev/graph/cake_pb_iso}"
    GRAPHS="${TRIMNALYSER_GRAPHS:-/home/arthur_gla/veriPB/newSIPbenchmarks}"
    LOGS="${TRIMNALYSER_LOGS:-/home/arthur_gla/veriPB/subgraphsolver/logs}"
fi

fail=0
need() { [[ -e "$2" ]] || { echo "MISSING $1: $2" >&2; fail=1; }; }
if [[ "$KIND" == "lad" ]]; then need "lad solver" "$SOLVER_LAD"
                           else need "glasgow solver" "$SOLVER_GSS"; fi
need "veripb"    "$VERIPB"
need "cake_pb"   "$CAKE_PB"
need "benchmarks" "$GRAPHS"
mkdir -p "$LOGS"
# cake_pb_iso is only reachable for lad-* (it rebuilds the model from the graphs, and only
# LAD's own OPB matches its numbering — see certify() in src/output.jl).
if [[ "$KIND" == "lad" ]]; then need "cake_pb_iso" "$CAKE_PB_ISO"; fi
[[ $fail -eq 0 ]] || { echo "preflight failed — see CLAUDE.md for how to rebuild these" >&2; exit 1; }

# Nine of the fourteen columns pin a Glasgow revision (SOLVER_CONFIGS calls gssbin(<rev>),
# which reads $GLASGOW_SUBGRAPH_SOLVER_<rev>). With that variable unset every one of them
# silently falls back to the single global binary, and the table's revision columns then
# all measure whatever happens to be built. Loud, because it cannot be seen in the output.
if [[ "$KIND" == "gss" ]]; then
    REV=$(grep -oP "^\s*\"$CONFIG\"\s*=>\s*SolverConfig\(\"gss\",\s*gssbin\(\"\K[0-9a-f]+" src/config.jl || true)
    if [[ -n "$REV" ]]; then
        VAR="GLASGOW_SUBGRAPH_SOLVER_$REV"
        if [[ -z "${!VAR:-}" ]]; then
            echo "WARNING: $CONFIG pins glasgow revision $REV but \$$VAR is unset;" >&2
            echo "         it will run whatever is at $SOLVER_GSS" >&2
        else
            need "glasgow $REV" "${!VAR}"
            [[ $fail -eq 0 ]] || exit 1
        fi
    fi
fi

# ── Assemble ──────────────────────────────────────────────────────────────────────────
ARGS=(solve resolv verif cake "config=$CONFIG"
      "stnopl=$STNOPL" "st=$ST" "tt=$TT" "vt=$VT" "ct=$CT" "maxmem=$MAXMEM")
if [[ -n "$INSTANCE" ]]; then
    ARGS=("$INSTANCE" "${ARGS[@]}")
else
    ARGS=(--threads "$THREADS" "${ARGS[@]}" allgraphs rand)
    [[ -n "${MINNODES:-}" ]] && ARGS+=("minnodes=$MINNODES")
    [[ -n "${MAXNODES:-}" ]] && ARGS+=("maxnodes=$MAXNODES")
fi
# shellcheck disable=SC2206
[[ -n "${EXTRA:-}" ]] && ARGS+=(${EXTRA})

echo "config=$CONFIG kind=$KIND scale=$SCALE  stnopl=$STNOPL st=$ST tt=$TT vt=$VT ct=$CT"
echo "logs -> $LOGS/<instance>.$KIND.$CONFIG.out"
echo "+ ./trimnalyser ${ARGS[*]}"
[[ "${DRYRUN:-0}" == "1" ]] && exit 0

export VERIPB CAKE_PB CAKE_PB_ISO
exec ./trimnalyser "${ARGS[@]}"
