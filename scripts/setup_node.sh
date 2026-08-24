#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Make ONE node ready to run a column of the grid. Idempotent; safe to re-run any time.
#
#     bash scripts/setup_node.sh            # populate + verify
#     bash scripts/setup_node.sh --verify   # verify only, change nothing
#
# /scratch is node-local AND volatile (it was recreated 2026-07-06, destroying everything
# under /scratch/arthur). $HOME and /cluster are shared NFS. So the binaries and the
# benchmark graphs have to be re-copied onto every node, every time /scratch is wiped —
# that is what this does. Run it via setup_all_nodes.sh to do all nine at once.
#
# Nothing here is run-specific: it installs binaries and graphs, it does not start work.
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
cd "$(dirname "$0")/.."

DIST="${DIST:-/cluster/arthur/dist}"
SCRATCH="${SCRATCH:-/scratch/arthur}"
GRAPHS_SRC="${GRAPHS_SRC:-$HOME/newSIPbenchmarks}"
VERIFY_ONLY=0
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=1

H=$(hostname -s)
say() { printf '[%s] %s\n' "$H" "$*"; }
fail=0
bad() { printf '[%s] FAIL %s\n' "$H" "$*" >&2; fail=1; }

BINS=(glasgow_subgraph_solver veripb cake_pb cake_pb_iso lad)
mapfile -t REVBINS < <(cd "$DIST" 2>/dev/null && ls glasgow_subgraph_solver_* 2>/dev/null || true)

if [[ $VERIFY_ONLY -eq 0 ]]; then
    [[ -d "$DIST" ]] || { bad "no dist at $DIST — run scripts/cluster_dist.sh first"; exit 1; }
    say "populating $SCRATCH from $DIST"
    mkdir -p "$SCRATCH"

    # Binaries. --update alone is not enough: a rebuilt binary can be the same size and a
    # coarse NFS mtime, so checksum-compare and always preserve the exec bit.
    rsync -a --checksum --chmod=F755 \
          "$DIST"/glasgow_subgraph_solver* "$DIST"/veripb "$DIST"/cake_pb \
          "$DIST"/cake_pb_iso "$DIST"/lad "$DIST"/MANIFEST "$SCRATCH"/ 2>/dev/null \
        || bad "rsync of binaries from $DIST"

    # Benchmark graphs (~102 MB). Read on every instance, so they must be node-local:
    # nine nodes hammering one NFS export is the slowest possible way to run this.
    if [[ -d "$GRAPHS_SRC" ]]; then
        say "syncing benchmarks from $GRAPHS_SRC"
        rsync -a --delete "$GRAPHS_SRC"/ "$SCRATCH/newSIPbenchmarks"/ || bad "rsync of benchmarks"
    else
        bad "no benchmark source at $GRAPHS_SRC"
    fi

    mkdir -p "$SCRATCH/proofs"
    mkdir -p "${TRIMNALYSER_LOGS:-/cluster/arthur/logs}"
fi

# ── Verification ──────────────────────────────────────────────────────────────────────
# Everything below fails SOFTLY at run time if it is wrong — a missing veripb prints one
# yellow line and completes the whole run unverified — so it is all checked here instead.
say "verifying"

for b in "${BINS[@]}" "${REVBINS[@]}"; do
    [[ -x "$SCRATCH/$b" ]] || { bad "missing or not executable: $SCRATCH/$b"; continue; }
done

# Do the binaries actually RUN? The Glasgow builds carry an rpath into ~/local for
# libgmpxx; a node that cannot see it links fine and dies on every instance.
for b in "${REVBINS[@]}" glasgow_subgraph_solver; do
    [[ -x "$SCRATCH/$b" ]] || continue
    "$SCRATCH/$b" --help >/dev/null 2>&1 || { bad "$b does not run"; ldd "$SCRATCH/$b" 2>/dev/null | grep -i "not found" >&2 || true; }
done
[[ -x "$SCRATCH/veripb" ]] && { "$SCRATCH/veripb" --help >/dev/null 2>&1 || bad "veripb does not run"; }

# Byte-identical to what was staged? This is what makes a nine-node run comparable: if two
# nodes disagree here, two columns of the table were produced by different binaries.
if [[ -f "$SCRATCH/MANIFEST" ]]; then
    if (cd "$SCRATCH" && grep -E '^[0-9a-f]{64}' MANIFEST | sha256sum -c --quiet 2>/dev/null); then
        say "checksums match dist"
    else
        bad "checksum mismatch against MANIFEST — node is running different binaries"
    fi
else
    bad "no MANIFEST at $SCRATCH"
fi

# Graphs present and non-trivial.
n=$(find "$SCRATCH/newSIPbenchmarks" -type f 2>/dev/null | wc -l)
(( n > 100 )) || bad "benchmarks look wrong: $n files under $SCRATCH/newSIPbenchmarks"
say "benchmark files: $n"

# The whole point of the exercise: every pinned revision resolves to its OWN binary.
# gssbin() falls back silently, so an unset variable here is exactly the bug this
# automation exists to prevent.
# shellcheck source=/dev/null
source scripts/cluster_env.sh
mapfile -t REVS < <(grep -oP 'gssbin\("\K[0-9a-f]+' src/config.jl | sort -u)
for rev in "${REVS[@]}"; do
    var="GLASGOW_SUBGRAPH_SOLVER_$rev"
    if [[ -z "${!var:-}" ]]; then bad "$var unset (scripts/cluster_env.sh out of sync with src/config.jl)"
    elif [[ ! -x "${!var}" ]]; then bad "$var -> ${!var} is not executable"
    else say "$rev -> ${!var}"; fi
done

# Distinct revisions must be distinct FILES. If two of them hash the same, the grid would
# silently produce duplicate columns — the exact failure mode that is invisible in output.
if [[ ${#REVS[@]} -gt 1 ]]; then
    dup=$(for rev in "${REVS[@]}"; do
              [[ -x "$SCRATCH/glasgow_subgraph_solver_$rev" ]] &&
                  sha256sum "$SCRATCH/glasgow_subgraph_solver_$rev" | cut -d' ' -f1
          done | sort | uniq -d | wc -l)
    (( dup == 0 )) || bad "two pinned revisions are the same binary — check the build"
fi

df -h "$SCRATCH" | tail -1 | sed "s/^/[$H] scratch /"

if [[ $fail -eq 0 ]]; then say "READY"; else say "NOT READY"; fi
exit $fail
