#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Build the two companion VeriPB trimmers we compare against.
#
#   feature_trimmer      -> $OUT/veripb_ft   the official trimmer (public branch)
#   feature/trimmer-base -> $OUT/veripb_tb   the not-yet-public rewrite
#
# Both are built from git worktrees of ~/veripb-dev so the main checkout — which
# `cluster_dist.sh` harvests target/release/veripb from — is never moved off main.
# Cargo target dirs go on node-local /scratch: cargo writes hundreds of thousands of
# small files and $HOME is shared NFS across all nine nodes.
#
# Usage:  bash scripts/companion_build.sh [ft|tb|all]
# ══════════════════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="${VERIPB_REPO:-$HOME/veripb-dev}"
OUT="${COMPANION_BIN:-/scratch/arthur}"
WORKROOT="${COMPANION_WORK:-$HOME/veripb-worktrees}"
CARGOROOT="${COMPANION_CARGO:-/scratch/arthur/cargo}"
WHICH="${1:-all}"

command -v cargo >/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || { echo "cargo not on PATH and not in ~/.cargo/bin" >&2; exit 1; }
[[ -d "$REPO/.git" ]] || { echo "no veripb-dev checkout at $REPO" >&2; exit 1; }
mkdir -p "$OUT" "$WORKROOT" "$CARGOROOT"

# The branch may have appeared upstream since the last fetch. Failure is not fatal:
# an already-fetched ref still builds, and feature/trimmer-base is expected to fail
# here until the repo is reachable.
# `timeout` is not optional here. The compute nodes are on a private network reachable
# only through the head node, so a fetch of an unreachable remote does not fail — it
# hangs on TCP connect, forever, with no output. That is exactly what it did on
# fataepyc-01. A failed fetch is fine: an already-fetched ref still builds.
echo "== fetching $REPO (60s limit) =="
timeout 60 git -C "$REPO" fetch --all --prune 2>&1 | sed 's/^/   /' || \
    echo "   fetch failed or timed out — building from already-fetched refs"

build_one() {                       # $1 = branch  $2 = output binary name
    local branch="$1" name="$2"
    local wt="$WORKROOT/$name" target="$CARGOROOT/$name"

    if ! git -C "$REPO" rev-parse --verify --quiet "origin/$branch^{commit}" >/dev/null; then
        echo "!! branch origin/$branch is not in $REPO — SKIPPING $name"
        echo "   (it has never been fetched; the repo needs gitlab credentials)"
        return 1
    fi
    local sha; sha=$(git -C "$REPO" rev-parse --short "origin/$branch")
    echo "== $name <- origin/$branch ($sha) =="

    if [[ -d "$wt" ]]; then
        timeout 60 git -C "$wt" fetch origin "$branch" 2>/dev/null || true
        git -C "$wt" checkout --quiet --force --detach "origin/$branch"
    else
        git -C "$REPO" worktree add --quiet --detach "$wt" "origin/$branch"
    fi

    # --locked would fail on a branch whose Cargo.lock predates the toolchain; we want
    # the branch's own dependency resolution, not ours, so plain build it is.
    ( cd "$wt" && CARGO_TARGET_DIR="$target" cargo build --release 2>&1 | tail -20 )

    local built="$target/release/veripb"
    [[ -x "$built" ]] || { echo "!! $name: no binary at $built" >&2; return 1; }
    install -m 0755 "$built" "$OUT/$name"
    echo "   -> $OUT/$name"
    # Record provenance beside the binary: which branch, which commit, built when and
    # where. Six months from now the table's caption has to name the revision.
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$branch" "$sha" "$(date -Iseconds)" "$(hostname -s)" \
        >> "$OUT/companion-binaries.tsv"
    "$OUT/$name" --version 2>&1 | head -2 | sed 's/^/   /' || true
}

rc=0
case "$WHICH" in
    ft)  build_one feature_trimmer      veripb_ft || rc=1 ;;
    tb)  build_one feature/trimmer-base veripb_tb || rc=1 ;;
    all) build_one feature_trimmer      veripb_ft || rc=1
         build_one feature/trimmer-base veripb_tb || true ;;   # expected to be missing
    *)   echo "usage: bash scripts/companion_build.sh [ft|tb|all]" >&2; exit 1 ;;
esac
echo "== done (rc=$rc) =="
exit $rc
