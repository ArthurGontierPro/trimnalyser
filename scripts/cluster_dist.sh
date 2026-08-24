#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Stage every binary the grid needs into ONE shared directory, /cluster/arthur/dist.
#
# Run this ONCE, on any node. /cluster and $HOME are shared NFS, so the result is visible
# everywhere; setup_node.sh then copies it onto each node's local /scratch.
#
#     bash scripts/cluster_dist.sh            # build what is missing
#     FORCE=1 bash scripts/cluster_dist.sh    # rebuild everything from scratch
#
# What it produces:
#   glasgow_subgraph_solver_<rev>   one per revision pinned by gssbin() in src/config.jl
#   glasgow_subgraph_solver         copy of the default config's revision (the fallback)
#   veripb  cake_pb  cake_pb_iso  lad
#   MANIFEST                        sha256 + provenance of each of the above
#
# The Glasgow build uses the post-2026-07-08-reimage recipe: no system GMP headers and no
# sudo, so GMP lives in ~/local unpacked from .debs, and the binary needs an rpath to find
# libgmpxx at run time. Boost is not required. See CLAUDE.md.
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD

DIST="${DIST:-/cluster/arthur/dist}"
GSS_REPO="${GSS_REPO:-$HOME/glasgow-subgraph-solver}"
WT="${WT:-$HOME/gss-worktrees}"
JOBS="${JOBS:-48}"

mkdir -p "$DIST" "$WT"
echo "dist   -> $DIST"
echo "repo   -> $GSS_REPO"

# ── The pinned revisions, read from the single source of truth ────────────────────────
# Same grep as bench_config.sh's warning path, so the two cannot disagree about which
# revisions exist. Sorted+uniqued: five configs share 39ca857, three share 2180663.
mapfile -t REVS < <(grep -oP 'gssbin\("\K[0-9a-f]+' src/config.jl | sort -u)
[[ ${#REVS[@]} -gt 0 ]] || { echo "no gssbin() revisions found in src/config.jl" >&2; exit 1; }
echo "revs   -> ${REVS[*]}"

# The revision behind `default_config`, which becomes the un-suffixed fallback binary.
DEFCFG=$(grep -oP 'const default_config\s*=\s*"\K[a-z0-9-]+' src/config.jl)
DEFREV=$(grep -oP "^\s*\"$DEFCFG\"\s*=>\s*SolverConfig\(\"gss\",\s*gssbin\(\"\K[0-9a-f]+" src/config.jl)
echo "default-> $DEFCFG ($DEFREV)"
echo

# ── Preconditions the build silently mis-handles if absent ────────────────────────────
[[ -d "$GSS_REPO/.git" ]] || { echo "no glasgow clone at $GSS_REPO" >&2; exit 1; }
for f in "$HOME/local/include/gmp.h" "$HOME/local/lib/libgmp.so" "$HOME/local/lib/libgmpxx.so"; do
    [[ -e "$f" ]] || { echo "MISSING $f — GMP dev files live in ~/local since the reimage" >&2; exit 1; }
done
command -v cmake >/dev/null || { echo "no cmake" >&2; exit 1; }

# ── Build each revision in its own detached worktree ──────────────────────────────────
# A worktree rather than `git checkout` in place: the checkout would move the user's own
# working copy under them, and three sequential checkouts would force three full rebuilds.
# Separate worktrees keep three separate build/ caches, so a re-run is nearly free.
build_rev() {
    local rev=$1 out="$DIST/glasgow_subgraph_solver_$rev"
    if [[ -x "$out" && "${FORCE:-0}" != "1" ]]; then
        echo "  $rev: already built ($(stat -c%s "$out") bytes) — skipping"
        return 0
    fi
    local dir="$WT/$rev"
    if [[ ! -d "$dir" ]]; then
        echo "  $rev: adding worktree"
        git -C "$GSS_REPO" worktree add --detach --force "$dir" "$rev" >/dev/null
    else
        # Re-point an existing worktree, in case the rev moved or the dir is stale.
        git -C "$dir" checkout --detach --force "$rev" >/dev/null 2>&1
    fi
    [[ "${FORCE:-0}" == "1" ]] && rm -rf "$dir/build"
    echo "  $rev: cmake configure"
    cmake -S "$dir" -B "$dir/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DGMP_INCLUDE_DIR="$HOME/local/include" \
        -DGMP_LIBRARY="$HOME/local/lib/libgmp.so" \
        -DGMPXX_LIBRARY="$HOME/local/lib/libgmpxx.so" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,$HOME/local/lib" >"$dir/cmake.log" 2>&1 \
        || { echo "  $rev: CONFIGURE FAILED — see $dir/cmake.log" >&2; tail -20 "$dir/cmake.log" >&2; return 1; }
    echo "  $rev: building (-j$JOBS)"
    cmake --build "$dir/build" -j"$JOBS" >"$dir/build.log" 2>&1 \
        || { echo "  $rev: BUILD FAILED — see $dir/build.log" >&2; tail -30 "$dir/build.log" >&2; return 1; }
    local bin="$dir/build/glasgow_subgraph_solver"
    [[ -x "$bin" ]] || { echo "  $rev: built but no binary at $bin" >&2; return 1; }
    # Smoke-test before publishing: a binary that cannot resolve libgmpxx at run time
    # links fine and fails on every instance instead.
    "$bin" --help >/dev/null 2>&1 || { echo "  $rev: binary does not run (rpath?)" >&2
                                       ldd "$bin" | grep -i "not found" >&2 || true; return 1; }
    cp -f "$bin" "$out.tmp" && mv -f "$out.tmp" "$out"
    echo "  $rev: OK -> $out"
}

echo "── Glasgow revisions ────────────────────────────────────────────"
for rev in "${REVS[@]}"; do build_rev "$rev"; done

# The fallback binary. A copy, not a symlink: /scratch gets an rsync of this directory and
# a dangling symlink there would fail softly at run time.
cp -f "$DIST/glasgow_subgraph_solver_$DEFREV" "$DIST/glasgow_subgraph_solver"
echo "  fallback = $DEFREV"

# ── Auxiliary binaries ────────────────────────────────────────────────────────────────
# Each is looked up in a list of candidate locations, first hit wins. /scratch/arthur is
# in the list because cake_pb and cake_pb_iso were built there on fataepyc-07 and exist
# NOWHERE else — /scratch is node-local and volatile, so staging them here is the whole
# point of this step.
echo
echo "── auxiliary binaries ───────────────────────────────────────────"
stage() {
    local name=$1; shift
    if [[ -e "$DIST/$name" && "${FORCE:-0}" != "1" ]]; then
        echo "  $name: already staged — skipping"; return 0; fi
    local c
    for c in "$@"; do
        if [[ -e "$c" ]]; then
            cp -f "$c" "$DIST/$name.tmp" && mv -f "$DIST/$name.tmp" "$DIST/$name"
            chmod +x "$DIST/$name"
            echo "  $name: staged from $c"; return 0
        fi
    done
    echo "  $name: NOT FOUND — looked in: $*" >&2
    return 1
}
rc=0
stage veripb      "$HOME/veripb-dev/target/release/veripb" /scratch/arthur/veripb || rc=1
stage cake_pb     /scratch/arthur/cake_pb "$HOME/CakePB-dev/cake_pb" \
                  /scratch/arthur/cakepb-build/cake_pb || rc=1
stage cake_pb_iso /scratch/arthur/cake_pb_iso "$HOME/CakePB-dev/graph/cake_pb_iso" \
                  /scratch/arthur/cakepb-build/graph/cake_pb_iso || rc=1
stage lad         "$HOME/ladveri/main" /scratch/arthur/lad || rc=1

# ── Manifest ──────────────────────────────────────────────────────────────────────────
# Written last, and only over what actually exists. setup_node.sh copies it to each node,
# so `sha256sum -c` there answers "is this node running the same binaries as that one?"
{
    echo "# staged $(date -Is) on $(hostname -s) by $USER"
    echo "# glasgow repo: $GSS_REPO"
    for rev in "${REVS[@]}"; do
        printf '# %s = %s\n' "$rev" "$(git -C "$GSS_REPO" log -1 --format=%s "$rev" 2>/dev/null)"
    done
    echo "# default_config $DEFCFG -> $DEFREV"
    (cd "$DIST" && sha256sum glasgow_subgraph_solver* veripb cake_pb cake_pb_iso lad 2>/dev/null)
} > "$DIST/MANIFEST"

echo
echo "── manifest ─────────────────────────────────────────────────────"
cat "$DIST/MANIFEST"
[[ $rc -eq 0 ]] || echo -e "\nSOME AUXILIARY BINARIES ARE MISSING — see above" >&2
exit $rc
