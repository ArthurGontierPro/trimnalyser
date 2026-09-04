#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Head-to-head: TrimAnalyser vs the two VeriPB trimmers, on one and the same stock proof.
#
# Feeds tab:configs-companion and the \ph{X}/\ph{Y}/\ph{XLV}/\ph{YLV} of sec:compress.
#
#   raw <ins>.opb + <ins>.pbp   (produced beforehand by companion_proofs.sh, `keepraw`)
#     |
#     +-- base : veripb <opb> <pbp> -e <ins>.full.elab.pbp        <- the DENOMINATOR
#     +-- ta   : trimnalyser (trim-only subprocess) -> .smol.*
#     |            then veripb .smol.opb .smol.pbp -e <ins>.ta.elab.pbp
#     +-- ft   : veripb_ft trim <opb> <pbp> <ins>.ft.opb -e <ins>.ft.pbp
#     |            then veripb <ins>.ft.opb <ins>.ft.pbp          <- re-check, same binary
#     +-- tb   : veripb_tb trim ...   (identical shape; skipped if the binary is absent)
#
# Why elaborate our side.  The VeriPB trimmers emit ONLY elaborated proofs, and
# TrimAnalyser's .smol.pbp still carries `rup`.  Comparing those two directly would
# credit us for work the elaborator has yet to do, so both sides are measured after
# elaboration.  The trimmed .opb is counted with it, as in tab:compression.
#
# Why one checker for all arms.  Verify time is a reported column; three different
# veripb builds would make it a measurement of the builds, not of the proofs.  Every
# `check` in this script is $VERIPB (main).  Only the `trim` subcommand differs per arm.
#
# Timing is external wall clock for every arm, uniformly — trimnalyser's own internal
# parse/trim/write split is not comparable with a rust binary's, and under the sysimage
# its startup is ~0.1 s.  Arms run BACK TO BACK inside one job, so a machine-load swing
# hits all of them or none.  That is the whole reason this is not four separate passes.
#
# Usage:
#   bash scripts/companion_compare.sh <instfile> <proofsdir> <out.csv>
#
# Environment:
#   JOBS=8          instances in flight (arms within an instance are always sequential)
#   TT=6000         per-trim timeout, seconds
#   VT=6000         per-elaborate / per-check timeout, seconds
#   ARMS="base ta ft tb"    which arms to run
#   KEEP=1          keep the produced proofs (default: delete, they are enormous)
#   CONFIG=gss-lazy passed to the trimnalyser subprocess (must match the proofs dir)
#   VERIPB / VERIPB_FT / VERIPB_TB / TRIMNALYSER_REPO / TRIMNALYSER_SO
# ══════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

INSTFILE="${1:?usage: companion_compare.sh <instfile> <proofsdir> <out.csv>}"
PROOFS="${2:?}"; OUTCSV="${3:?}"
PROOFS="${PROOFS%/}/"

JOBS="${JOBS:-8}"
TT="${TT:-6000}"
VT="${VT:-6000}"
ARMS="${ARMS:-base ta ft tb}"
KEEP="${KEEP:-0}"
CONFIG="${CONFIG:-gss-lazy}"
GRACE=30                       # `timeout` alone does not escalate; trims have wedged on
                               # SIGTERM before (see docs/runs, commit cf07c42).

VERIPB="${VERIPB:-/scratch/arthur/veripb}"
VERIPB_FT="${VERIPB_FT:-/scratch/arthur/veripb_ft}"
VERIPB_TB="${VERIPB_TB:-/scratch/arthur/veripb_tb}"
# The COMPANION checkout, not ~/trimnalyser. While the grid runs, ~/trimnalyser is
# pinned to the commit its live columns were launched at, so defaulting there would
# quietly measure a different revision of the trimmer than the one under test.
REPO="${TRIMNALYSER_REPO:-$HOME/trimnalyser-companion}"
SO="${TRIMNALYSER_SO:-$REPO/trimnalyser.so}"

WORK="$(dirname "$OUTCSV")/$(basename "$OUTCSV" .csv).parts"
LOGDIR="$(dirname "$OUTCSV")/$(basename "$OUTCSV" .csv).logs"
mkdir -p "$WORK" "$LOGDIR"

# ── preflight ────────────────────────────────────────────────────────────────────────
have() { [[ -x "$1" ]]; }
fail=0
have "$VERIPB" || { echo "MISSING veripb (the shared checker): $VERIPB" >&2; fail=1; }
[[ -d "$PROOFS" ]] || { echo "MISSING proofs dir: $PROOFS" >&2; fail=1; }
[[ -f "$INSTFILE" ]] || { echo "MISSING instance list: $INSTFILE" >&2; fail=1; }
RUN_ARMS=""
for a in $ARMS; do
    case "$a" in
        base|ta) RUN_ARMS="$RUN_ARMS $a" ;;
        ft) have "$VERIPB_FT" && RUN_ARMS="$RUN_ARMS ft" \
                || echo "note: arm ft skipped, no binary at $VERIPB_FT" >&2 ;;
        tb) have "$VERIPB_TB" && RUN_ARMS="$RUN_ARMS tb" \
                || echo "note: arm tb skipped, no binary at $VERIPB_TB (branch not public yet)" >&2 ;;
        *) echo "unknown arm: $a" >&2; fail=1 ;;
    esac
done
if [[ " $RUN_ARMS " == *" ta "* ]]; then
    [[ -f "$REPO/bin/trimnalyser.jl" ]] || { echo "MISSING $REPO/bin/trimnalyser.jl" >&2; fail=1; }
    # Without the sysimage every trim pays ~5 s of Julia startup, which on the bio family
    # (median trim 0.03 s) would be the entire measurement.
    [[ -f "$SO" ]] || echo "WARNING: no sysimage at $SO — trimnalyser arm pays full JIT startup" >&2
fi
(( fail == 0 )) || exit 1

HDR=$(cat <<'EOF'
instance,family,rc_note,opb_bytes,pbp_bytes,pbp_lines,base_status,base_s,base_bytes,base_lines,ta_status,ta_s,ta_opb_bytes,ta_pbp_bytes,ta_elab_status,ta_elab_s,ta_elab_bytes,ta_elab_lines,ta_check_status,ta_check_s,ft_status,ft_s,ft_opb_bytes,ft_pbp_bytes,ft_pbp_lines,ft_check_status,ft_check_s,ft_steps,ft_note,tb_status,tb_s,tb_opb_bytes,tb_pbp_bytes,tb_pbp_lines,tb_check_status,tb_check_s,tb_steps,tb_note
EOF
)

# ── the per-instance body, exported for xargs ────────────────────────────────────────
export PROOFS TT VT KEEP CONFIG GRACE VERIPB VERIPB_FT VERIPB_TB REPO SO WORK LOGDIR RUN_ARMS

runone() {
    ins="$1"
    part="$WORK/$ins.csv"
    [[ -s "$part" ]] && return 0          # resumable: an existing row is never redone
    log="$LOGDIR/$ins.log"
    : > "$log"

    opb="$PROOFS$ins.opb"; pbp="$PROOFS$ins.pbp"
    case "$ins" in
        LV*)      fam=LV ;;
        bio*)     fam=bio ;;
        cviu11_*) fam=images ;;
        mesh11_*) fam=meshes ;;
        *)        fam=other ;;
    esac
    if [[ ! -s "$opb" || ! -s "$pbp" ]]; then
        printf '%s,%s,%s,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,\n' "$ins" "$fam" "noproof" > "$part"
        return 0
    fi

    # elapsed of a command, to the millisecond, with the command's own log appended.
    # Returns the command's exit status in $RC and the elapsed seconds in $EL.
    timed() {
        local t0 t1
        t0=${EPOCHREALTIME/,/.}
        "$@" >>"$log" 2>&1; RC=$?
        t1=${EPOCHREALTIME/,/.}
        EL=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    }
    # NOTE on every `grep -q VERIFIED` below: VeriPB's verdict comes from that word on
    # stdout and NEVER from a file existing. `veripb -e` writes the elaboration's header
    # before it checks anything, so a rejected proof still leaves a ~40-byte file
    # (see certify(), src/output.jl). Each check greps only the lines its own stage
    # appended, hence the `tail -n +$n0`.
    lines() { [[ -s "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }
    bytes() { [[ -e "$1" ]] && stat -c %s "$1" || echo 0; }
    # A timeout kill shows as 124 (or 137 after the -k escalation).
    stat_of() { case "$1" in 0) echo ok ;; 124|137) echo timeout ;; *) echo "rc$1" ;; esac; }

    opb_b=$(bytes "$opb"); pbp_b=$(bytes "$pbp"); pbp_l=$(lines "$pbp")

    base_status=; base_s=; base_b=; base_l=
    ta_status=; ta_s=; ta_opb_b=; ta_pbp_b=
    ta_el_status=; ta_el_s=; ta_el_b=; ta_el_l=; ta_ck_status=; ta_ck_s=
    ft_status=; ft_s=; ft_opb_b=; ft_pbp_b=; ft_pbp_l=; ft_ck_status=; ft_ck_s=; ft_steps=; ft_note=
    tb_status=; tb_s=; tb_opb_b=; tb_pbp_b=; tb_pbp_l=; tb_ck_status=; tb_ck_s=; tb_steps=; tb_note=

    # ── baseline: elaborate the untrimmed proof ──────────────────────────────────────
    if [[ " $RUN_ARMS " == *" base "* ]]; then
        out="$PROOFS$ins.full.elab.pbp"
        echo "### base: $VERIPB $opb $pbp -e $out" >> "$log"
        n0=$(wc -l < "$log")
        timed timeout -k "$GRACE" "$VT" "$VERIPB" "$opb" "$pbp" -e "$out"
        base_s=$EL; base_status=$(stat_of $RC)
        [[ $RC -eq 0 ]] && { tail -n +"$n0" "$log" | grep -q 'VERIFIED' || base_status=notverified; }
        base_b=$(bytes "$out"); base_l=$(lines "$out")
        [[ "$KEEP" == "1" ]] || rm -f "$out"
    fi

    # ── arm ta: TrimAnalyser, trim only ──────────────────────────────────────────────
    if [[ " $RUN_ARMS " == *" ta "* ]]; then
        rm -f "$PROOFS$ins.smol.opb" "$PROOFS$ins.smol.pbp"
        jflags=()
        [[ -f "$SO" ]] && { jflags=(--sysimage "$SO" --project="$REPO"); export TRIMNALYSER_SYSIMAGE=1; }
        echo "### ta: julia bin/trimnalyser.jl $ins subprocess tt=$TT config=$CONFIG $PROOFS" >> "$log"
        timed timeout -k "$GRACE" "$TT" julia +1.12.2 "${jflags[@]}" --startup-file=no \
              "$REPO/bin/trimnalyser.jl" "$ins" subprocess "tt=$TT" "config=$CONFIG" "$PROOFS"
        ta_s=$EL; ta_status=$(stat_of $RC)
        ta_opb_b=$(bytes "$PROOFS$ins.smol.opb"); ta_pbp_b=$(bytes "$PROOFS$ins.smol.pbp")
        [[ $RC -eq 0 && $ta_pbp_b -gt 0 ]] || ta_status="${ta_status/ok/nosmol}"

        if [[ $ta_pbp_b -gt 0 ]]; then
            out="$PROOFS$ins.ta.elab.pbp"
            echo "### ta-elab: $VERIPB $ins.smol.opb $ins.smol.pbp -e $out" >> "$log"
            n0=$(wc -l < "$log")
            timed timeout -k "$GRACE" "$VT" "$VERIPB" "$PROOFS$ins.smol.opb" "$PROOFS$ins.smol.pbp" -e "$out"
            ta_el_s=$EL; ta_el_status=$(stat_of $RC)
            [[ $RC -eq 0 ]] && { tail -n +"$n0" "$log" | grep -q 'VERIFIED' || ta_el_status=notverified; }
            ta_el_b=$(bytes "$out"); ta_el_l=$(lines "$out")
            # Re-check the elaborated form with the same binary every other arm is
            # checked with, so ta_check_s and ft_check_s measure the same thing.
            if [[ "$ta_el_status" == "ok" ]]; then
                echo "### ta-check: $VERIPB $ins.smol.opb $ins.ta.elab.pbp" >> "$log"
                n0=$(wc -l < "$log")
                timed timeout -k "$GRACE" "$VT" "$VERIPB" "$PROOFS$ins.smol.opb" "$out"
                ta_ck_s=$EL; ta_ck_status=$(stat_of $RC)
                [[ $RC -eq 0 ]] && { tail -n +"$n0" "$log" | grep -q 'VERIFIED' || ta_ck_status=notverified; }
            fi
            [[ "$KEEP" == "1" ]] || rm -f "$out"
        fi
        [[ "$KEEP" == "1" ]] || rm -f "$PROOFS$ins.smol.opb" "$PROOFS$ins.smol.pbp"
    fi

    # ── arms ft / tb: the VeriPB trimmers ────────────────────────────────────────────
    run_vp_arm() {   # $1 = tag  $2 = binary
        local tag="$1" bin="$2"
        local oopb="$PROOFS$ins.$tag.opb" opbp="$PROOFS$ins.$tag.pbp"
        rm -f "$oopb" "$opbp"
        echo "### $tag: $bin trim $opb $pbp $oopb -e $opbp" >> "$log"
        local n1; n1=$(wc -l < "$log")
        # No --solution-state: these are UNSAT proofs and log no solutions (`grep -c '^sol'`
        # is 0), so the default `none` is the accurate promise. The binary warns anyway.
        timed timeout -k "$GRACE" "$TT" "$bin" trim "$opb" "$pbp" "$oopb" -e "$opbp"
        local s=$EL st; st=$(stat_of $RC)
        local ob pb pl ck cs steps note
        ob=$(bytes "$oopb"); pb=$(bytes "$opbp"); pl=$(lines "$opbp")
        [[ $RC -eq 0 && $pb -gt 0 ]] || st="${st/ok/notrim}"
        # Its own report of how much it removed, and — when it refuses a proof VeriPB
        # itself accepts — the reason, so the failures can be classified and sent
        # upstream instead of showing up as a bare count.
        steps=$(tail -n +"$n1" "$log" | sed -n 's/^Number of trimmed steps: *\([0-9]*\).*/\1/p' | head -1)
        note=$(tail -n +"$n1" "$log" | grep -m1 -E '^(Error|Caused by|    [A-Z])' | tr ',;' '..' | cut -c1-160)
        [[ $RC -eq 0 ]] && note=""
        ck=; cs=
        if [[ "$st" == "ok" ]]; then
            # The trimmer may or may not emit a reformulated model; when it does not,
            # the trimmed proof is still against the ORIGINAL opb.
            local model="$oopb"; [[ -s "$oopb" ]] || model="$opb"
            echo "### $tag-check: $VERIPB $model $opbp" >> "$log"
            local n0; n0=$(wc -l < "$log")
            timed timeout -k "$GRACE" "$VT" "$VERIPB" "$model" "$opbp"
            cs=$EL; ck=$(stat_of $RC)
            [[ $RC -eq 0 ]] && { tail -n +"$n0" "$log" | grep -q 'VERIFIED' || ck=notverified; }
        fi
        [[ "$KEEP" == "1" ]] || rm -f "$oopb" "$opbp"
        ARM_OUT="$st,$s,$ob,$pb,$pl,$ck,$cs,$steps,$note"
    }
    if [[ " $RUN_ARMS " == *" ft "* ]]; then
        run_vp_arm ft "$VERIPB_FT"; IFS=, read -r ft_status ft_s ft_opb_b ft_pbp_b ft_pbp_l ft_ck_status ft_ck_s ft_steps ft_note <<<"$ARM_OUT"
    fi
    if [[ " $RUN_ARMS " == *" tb "* ]]; then
        run_vp_arm tb "$VERIPB_TB"; IFS=, read -r tb_status tb_s tb_opb_b tb_pbp_b tb_pbp_l tb_ck_status tb_ck_s tb_steps tb_note <<<"$ARM_OUT"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$ins" "$fam" "" "$opb_b" "$pbp_b" "$pbp_l" \
        "$base_status" "$base_s" "$base_b" "$base_l" \
        "$ta_status" "$ta_s" "$ta_opb_b" "$ta_pbp_b" \
        "$ta_el_status" "$ta_el_s" "$ta_el_b" "$ta_el_l" "$ta_ck_status" "$ta_ck_s" \
        "$ft_status" "$ft_s" "$ft_opb_b" "$ft_pbp_b" "$ft_pbp_l" "$ft_ck_status" "$ft_ck_s" "$ft_steps" "$ft_note" \
        "$tb_status" "$tb_s" "$tb_opb_b" "$tb_pbp_b" "$tb_pbp_l" "$tb_ck_status" "$tb_ck_s" "$tb_steps" "$tb_note" \
        > "$part"
    echo "  done $ins  base=$base_status/${base_s}s ta=$ta_status/${ta_s}s ft=$ft_status/${ft_s}s tb=$tb_status/${tb_s}s"
}
export -f runone

# Instance NAMES only — companion_sample.sh already converted the stratified file's
# path pairs (a name built here by a second rule would address proofs that do not exist).
LIST=$(grep -ve '^\s*#' -e '^\s*$' "$INSTFILE" | awk '{print $1}')
if echo "$LIST" | grep -q '/'; then
    echo "instance list contains paths, not names — run scripts/companion_sample.sh first" >&2
    exit 1
fi
N=$(echo "$LIST" | wc -l)
echo "=== companion comparison: $N instances, arms:$RUN_ARMS, JOBS=$JOBS, tt=$TT vt=$VT ==="
echo "    proofs   $PROOFS"
echo "    binaries $VERIPB | $VERIPB_FT | $VERIPB_TB"
echo "$LIST" | xargs -P "$JOBS" -I{} bash -c 'runone "$@"' _ {}

{ echo "$HDR"; echo "$LIST" | while read -r i; do [[ -s "$WORK/$i.csv" ]] && cat "$WORK/$i.csv"; done; } > "$OUTCSV"
echo "=== wrote $OUTCSV ($(( $(wc -l < "$OUTCSV") - 1 )) rows) ==="
