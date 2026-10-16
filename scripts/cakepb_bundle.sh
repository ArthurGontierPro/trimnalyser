#!/bin/bash
# Regenerate and package the CakePB slow-instance bundle: one representative per outlier
# type, as the VeriPB pair (.opb + raw .pbp). The recipients elaborate it themselves with
# `veripb -e`, which is why the elaborations are not here -- shipping them would have cost
# 1.4 GB packed and put LVg36g59's 31 GB elaboration out of reach entirely. The raw pair
# for all ten is 10 GB, which xz takes to ~286 MB.
#
#   bash scripts/cakepb_bundle.sh [small|all|<instance> ...]
#
#     small   the nine under 40 MB packed   (default, ~119 MB)
#     all     adds LVg73g77                 (~286 MB; its model alone is 5.8 GB raw)
#
# Runs on the laptop or on a node. SERIAL by design: one solve at a time, under a virtual
# memory cap, because the point is to not disturb the machine it runs on.
#
# It does NOT run veripb or cake_pb. Every one of these pairs was verified by VeriPB in the
# grid run; what this script checks instead is that the regenerated pair is BYTE-IDENTICAL
# IN SIZE to the one that was verified, which is the cheap end of the same guarantee and
# the thing that would break if the wrong binary were used.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TSV="runs-0903/cakepb-slow-instances/representatives.tsv"
OUTDIR="${OUT:-runs-0903/cakepb-slow-instances/proofs}"
ST="${ST:-600}"                       # solver budget, as the grid used
# Per-solve address-space cap. NON-ZERO IS MANDATORY OFF-CLUSTER and 0 must never be the
# default: an uncapped LVg73g77 solve exhausted a 15 GB laptop and took the whole machine
# down, along with every other session on it. It had completed once before that, which is
# the worst property a run can have -- it fits or it does not depending on what else is
# resident, so "it worked last time" is not evidence.
#
# A cap can truncate a model instead: at 12 GB, LVg73g77 exited 0, printed its full stats
# block, declared UNSAT and wrote a byte-identical proof beside a model missing 265,809 of
# its 1,988,502 constraints. That is why the cap is paired with the integrity check below.
# Capped, a row either yields a correct pair or is loudly refused -- never a crash, never a
# bad artefact. An instance that needs more than the cap is a CLUSTER row, not a reason to
# raise the cap on a machine that cannot afford it.
MEMCAP_GB="${MEMCAP_GB:-8}"
XZ_THREADS="${XZ_THREADS:-1}"         # serial, like the solves: this shares the machine
[[ -f $TSV ]] || { echo "missing $TSV" >&2; exit 1; }

# ── Binaries ──────────────────────────────────────────────────────────────────────────
# Each representative names the CONFIG it was measured under, and the config fixes the
# binary. Two are needed and they are not interchangeable:
#   gss rows -> Glasgow at 1ff87ba (lazy logging + the NDS proof-witness fix). An earlier
#              revision emits the NDS elimination lemmas as bare `rup` that no checker can
#              replay, so the pair would not be the one VeriPB accepted.
#   lad rows -> ladveri on the branch that has -O. LAD's proof ids refer to the model -O
#              writes, NOT to Glasgow's encoding of the same instance.
# gssbin() falls back SILENTLY to a single global path when a revision variable is unset,
# which is how eight grid columns once measured the same binary, so this resolves the
# revision explicitly and refuses to guess.
GSS_REV=1ff87ba
ON_CLUSTER=0
case "$(hostname)" in
    fataepyc*|*dcs.gla.ac.uk*)
        ON_CLUSTER=1
        # shellcheck source=/dev/null
        source scripts/cluster_env.sh || exit 1
        GSS="${GLASGOW_SUBGRAPH_SOLVER_1ff87ba:-}"; LAD="${LAD_SOLVER:-}"
        GRAPHS="${TRIMNALYSER_GRAPHS%/}" ;;
    *)
        GSS_REPO="${GSS_REPO:-/home/arthur_gla/veriPB/subgraphsolver/glasgow-subgraph-solver}"
        LAD_REPO="${LAD_REPO:-/home/arthur_gla/ladveri}"
        GSS="$GSS_REPO/build/glasgow_subgraph_solver"
        LAD="$LAD_REPO/main"
        GRAPHS="${TRIMNALYSER_GRAPHS:-/home/arthur_gla/veriPB/newSIPbenchmarks}"
        GRAPHS="${GRAPHS%/}"
        # The revision check is the whole point of the exercise, so it is fatal, and a
        # dirty tree fails it too: a clean 1ff87ba is the only state we can name in the
        # manifest we hand over.
        head=$(git -C "$GSS_REPO" rev-parse --short=7 HEAD 2>/dev/null)
        if [[ $head != "$GSS_REV" ]]; then
            echo "$GSS_REPO is at ${head:-<no repo>}, need $GSS_REV" >&2
            echo "  git -C $GSS_REPO checkout $GSS_REV && cmake --build build -j4" >&2
            exit 1
        fi
        if [[ -n $(git -C "$GSS_REPO" status --porcelain) ]]; then
            echo "$GSS_REPO has uncommitted changes; the binary would not be $GSS_REV" >&2
            exit 1
        fi
        # ladveri carries no version string, so check the capability instead of a hash:
        # -O is the commit that matters and the usage text names it.
        # Captured first, not piped: `main` with no arguments prints its usage and exits
        # NON-ZERO, and under `set -o pipefail` that status would sink the whole pipeline
        # however well grep did.
        lad_usage=$("$LAD" 2>&1 || true)
        if ! grep -q -- '-O FILE' <<< "$lad_usage"; then
            echo "$LAD does not offer -O; build the branch that has it" >&2; exit 1
        fi ;;
esac
fail=0
for b in "$GSS" "$LAD"; do [[ -x "$b" ]] || { echo "not executable: ${b:-<unset>}" >&2; fail=1; }; done
[[ -d "$GRAPHS" ]] || { echo "no graphs at $GRAPHS" >&2; fail=1; }
command -v xz >/dev/null || { echo "xz not installed" >&2; fail=1; }
(( fail )) && exit 1
GSS_SHA=$(sha256sum "$GSS" | cut -c1-16)
LAD_SHA=$(sha256sum "$LAD" | cut -c1-16)
LAD_REV=$(git -C "$(dirname "$LAD")" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

# ── Rows ──────────────────────────────────────────────────────────────────────────────
want=()
case "${1:-small}" in
    small) mapfile -t want < <(awk -F'\t' '!/^#/ && $11=="small" {print $2}' "$TSV") ;;
    all)   mapfile -t want < <(awk -F'\t' '!/^#/ && $11!="cluster-only" {print $2}' "$TSV") ;;
    *)     want=("$@") ;;
esac
# `cluster-only` rows need more memory than any laptop cap may allow, so they are excluded
# from `all` and refused by name off-cluster. This is a hard gate, not advice: the reason
# the row is marked is that running it here crashed the machine.
if [[ $ON_CLUSTER -eq 0 ]]; then
    keep=()
    for i in "${want[@]}"; do
        if awk -F'\t' -v n="$i" '!/^#/ && $2==n && $11=="cluster-only" {found=1} END {exit !found}' "$TSV"; then
            echo "  REFUSING $i: marked cluster-only (needs > ${MEMCAP_GB} GB; an uncapped run here" >&2
            echo "            exhausted the machine). Build it on a node with cakepb_bundle.sh." >&2
        else keep+=("$i"); fi
    done
    want=("${keep[@]}")
fi
(( ${#want[@]} == 0 )) && { echo "nothing to do" >&2; exit 0; }
# Peak disk is one raw pair at a time, plus its archive: the pair is deleted as soon as it
# is packed, so the total never accumulates.
need=$(awk -F'\t' -v l=" ${want[*]} " '!/^#/ { if (index(l," "$2" ")) { s=($8+$9)/1073741824; if (s>m) m=s } }
                                      END { printf "%d", m*2+2 }' "$TSV")
avail=$(df -BG --output=avail "$(dirname "$OUTDIR")" | tail -1 | tr -dc '0-9')
(( avail < need )) && { echo "need ~${need} GB free, have ${avail} GB" >&2; exit 1; }

mkdir -p "$OUTDIR" || exit 1
rm -f "$OUTDIR/PENDING"
MAN="$OUTDIR/MANIFEST.txt"
{ echo "# CakePB slow-instance bundle -- VeriPB pairs (.opb + raw .pbp), xz -6"
  echo "# generated $(date -Is) on $(hostname)"
  echo "# glasgow $GSS_REV  sha256:$GSS_SHA  $GSS"
  echo "# ladveri $LAD_REV  sha256:$LAD_SHA  $LAD"
  echo "# sizes checked against the grid run that VeriPB verified; SIZE OK means the"
  echo "# regenerated pair is byte-for-byte the same length as the verified one."
} > "$MAN"

echo "glasgow $GSS_REV ($GSS_SHA)   ladveri $LAD_REV ($LAD_SHA)"
echo "output $OUTDIR   free ${avail} GB   serial, ${MEMCAP_GB} GB cap per solve"
echo
for ins in "${want[@]}"; do
    line=$(awk -F'\t' -v i="$ins" '!/^#/ && $2==i' "$TSV")
    [[ -n $line ]] || { echo "  $ins: not a representative, skipping" >&2; continue; }
    IFS=$'\t' read -r bucket _ config kind flags pat tar exp_o exp_p est tier <<< "$line"
    d="$OUTDIR/$bucket.$ins"; mkdir -p "$d"
    o="$d/$ins.opb"; p="$d/$ins.pbp"
    [[ -f $o.xz && -f $p.xz ]] && { echo "── $bucket  $ins  already packaged"; continue; }
    printf '── %-24s %-15s %-15s  expect %s + %s B, ~%s MB packed\n' \
           "$bucket" "$ins" "$config" "$exp_o" "$exp_p" "$est"

    t0=$SECONDS
    ( [[ ${MEMCAP_GB} -gt 0 ]] && ulimit -v $((MEMCAP_GB * 1024 * 1024))
      if [[ $kind == gss ]]; then
          # One --prove argument; Glasgow derives <prefix>.opb and <prefix>.pbp from it.
          # shellcheck disable=SC2086
          exec timeout "$ST" "$GSS" --prove "$d/$ins" $flags --format lad \
               "$GRAPHS/$pat" "$GRAPHS/$tar"
      else
          # LAD exits 0 on its own alarm, so -s carries the real limit; the outer timeout
          # is only a backstop for an alarm that cannot fire.
          # shellcheck disable=SC2086
          exec timeout $((ST + 30)) "$LAD" -p "$GRAPHS/$pat" -t "$GRAPHS/$tar" -s "$ST" \
               $flags -P "$p" -O "$o"
      fi ) > "$d/$ins.solverout" 2> "$d/$ins.solvererr"
    rc=$?; st=$((SECONDS - t0))
    if [[ ! -s $o || ! -s $p ]]; then
        echo "   SOLVE FAILED rc=$rc after ${st}s -- $d/$ins.solvererr" >&2
        printf 'FAILED\t%s\t%s\trc=%s\n' "$bucket" "$ins" "$rc" >> "$MAN"; continue
    fi
    # Self-consistency, which unlike the size comparison needs no reference run: the OPB's
    # own header says how many constraints it holds, and the proof's `f` line says how many
    # it expects. A truncated model satisfies neither, and nothing upstream complains --
    # that is exactly how the 12 GB cap above went unnoticed until the sizes disagreed.
    decl=$(head -1 "$o" | sed -n 's/.*#constraint=[[:space:]]*\([0-9]*\).*/\1/p')
    fline=$(head -3 "$p" | sed -n 's/^f[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
    actual=$(grep -cE '(>=|<=)' "$o")
    model_ok=yes
    if [[ -n $decl && $actual != "$decl" ]]; then
        echo "   MODEL SHORT: header declares $decl constraints, file holds $actual" >&2
        model_ok=no
    fi
    if [[ -n $fline && -n $decl && $fline != "$decl" ]]; then
        echo "   MODEL/PROOF DISAGREE: proof expects f $fline, model declares $decl" >&2
        model_ok=no
    fi
    got_o=$(stat -c%s "$o"); got_p=$(stat -c%s "$p")
    if [[ $model_ok == no ]]; then
        verdict="MODEL BROKEN (do not ship)"
    elif [[ $got_o == "$exp_o" && $got_p == "$exp_p" ]]; then
        verdict="SIZE OK"
    else
        verdict="SIZE MISMATCH (got $got_o + $got_p)"
        echo "   $verdict -- this pair is NOT the one VeriPB verified; wrong binary or flags?" >&2
    fi
    echo "   solved in ${st}s  $got_o + $got_p B  $actual/$decl constraints  $verdict"
    if [[ $verdict == "MODEL BROKEN"* ]]; then
        printf 'BROKEN\t%s\t%s\t%s\n' "$bucket" "$ins" "$verdict" >> "$MAN"
        rm -f "$o" "$p"; continue
    fi

    for f in "$o" "$p"; do xz -6 -T"$XZ_THREADS" -f "$f" || exit 1; done
    rm -f "$d/$ins.solvererr"
    { printf '%s\t%s\t%s\tsolve=%ss\t%s\n' "$bucket" "$ins" "$config" "$st" "$verdict"
      for f in "$o.xz" "$p.xz"; do
          printf '  %s  %10s  %s\n' "$(sha256sum "$f" | cut -c1-16)" \
                 "$(stat -c%s "$f")" "$(basename "$f")"; done
    } >> "$MAN"
    echo "   packed $(du -sh "$d" | cut -f1)"
done

echo
du -sh "$OUTDIR"
echo
echo "Ship $OUTDIR with README.md and instances.csv. Each directory is one outlier type:"
echo "  xz -d *.xz && veripb -e <ins>.elab.pbp <ins>.opb <ins>.pbp && cake_pb <ins>.opb <ins>.elab.pbp"
