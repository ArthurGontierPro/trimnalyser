#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════════════
# Run the configuration grid across the nodes: one column per node, one node per column.
#
#     bash scripts/run_grid.sh launch [scale]   # start every column
#     bash scripts/run_grid.sh status           # who is still running
#     bash scripts/run_grid.sh tail <config>    # follow one column's log
#     bash scripts/run_grid.sh stop             # kill every column
#
#     CONFIGS="gss gss-noclique" NODES="fataepyc-01 fataepyc-02" bash scripts/run_grid.sh launch
#     INSTFILE=/cluster/arthur/instfiles/lad_pl.txt CONFIGS=... bash scripts/run_grid.sh launch
#
# `scale` divides every timeout (bench_config.sh). Use 60 for a smoke test that finishes
# in minutes; omit it for the real run. ALWAYS smoke-test first: a column that is going to
# die on a missing binary dies in the first minute either way, and at scale 1 you find out
# after a day.
#
# Each column runs inside tmux on its node, so it survives the ssh session ending. Logs go
# to /cluster/arthur/benchlogs (shared NFS) — never to /scratch, which is node-local and
# volatile, and never to the proof tree, which is deleted as the run proceeds.
# ══════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd "$(dirname "$0")/.."

REPO="${REMOTE_REPO:-\$HOME/trimnalyser}"
BENCHLOGS="${BENCHLOGS:-/cluster/arthur/benchlogs}"
NODES="${NODES:-fataepyc-01 fataepyc-02 fataepyc-03 fataepyc-04 fataepyc-05 fataepyc-06 fataepyc-07 fataepyc-08 fataepyc-09}"

# Default: the nine Glasgow columns, in the order they appear in the paper's tables.
# lad-* is deliberately NOT here — the trim stage is only just fixed and `bio` needs
# excluding for every lad key. Pass CONFIGS= explicitly to run those.
CONFIGS="${CONFIGS:-gss gss-noclique gss-proof gss-lazy gss-lazy-base gss-nostaged gss-nosupp gss-norestarts gss-cliques}"

read -ra CFGARR <<< "$CONFIGS"
read -ra NODEARR <<< "$NODES"
CMD="${1:-status}"; SCALE="${2:-1}"
sess() { echo "grid-$1"; }

# ── Pairing ───────────────────────────────────────────────────────────────────────────
# Strictly one column per node. More columns than nodes would put two 92-thread,
# 50 GB-per-instance runs on the same box, and they would contend for exactly the
# resources the timings are supposed to measure.
if [[ ${#CFGARR[@]} -gt ${#NODEARR[@]} ]]; then
    echo "${#CFGARR[@]} configs but only ${#NODEARR[@]} nodes." >&2
    echo "Run them in waves rather than doubling up — timings would be contended." >&2
    exit 1
fi

case "$CMD" in
launch)
    echo "scale=$SCALE   $((${#CFGARR[@]})) columns over ${#NODEARR[@]} nodes"
    echo
    # Refuse to launch onto a node that is not READY. bench_config.sh only WARNS about an
    # unset revision variable, and a warning scrolls past; a column that silently measures
    # the wrong binary is worse than one that never started.
    echo "── preflight ────────────────────────────────────────────────────"
    bad=0
    for i in "${!CFGARR[@]}"; do
        n="${NODEARR[$i]}"; c="${CFGARR[$i]}"
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" \
              "bash -lc 'cd $REPO && bash scripts/setup_node.sh --verify'" 2>&1)
        if [[ $? -ne 0 ]]; then
            printf '  %-14s %-16s NOT READY\n' "$n" "$c"
            echo "$out" | grep FAIL | head -3 | sed 's/^/      /'
            bad=1
        else
            # Already running something under this name?
            if ssh "$n" "tmux has-session -t $(sess "$c") 2>/dev/null"; then
                printf '  %-14s %-16s ALREADY RUNNING\n' "$n" "$c"; bad=1
            else
                printf '  %-14s %-16s ok\n' "$n" "$c"
            fi
        fi
    done
    [[ $bad -eq 0 ]] || { echo -e "\npreflight failed — nothing launched." >&2
                          echo "fix with: bash scripts/setup_all_nodes.sh" >&2; exit 1; }


    # ── Sysimage ─────────────────────────────────────────────────────────────────
    # Every path in TrimAnalyser.jl is `const X = get(ENV, "VAR", default)`, evaluated at
    # module load — which under --sysimage means when the image was BUILT. So the sysimage
    # must be rebuilt with cluster_env.sh sourced, or all nine columns resolve the baked
    # fallback and the grid measures one binary nine times.
    #
    # Three reasons this is done here, once, up front, rather than left to ./trimnalyser:
    #   1. build_sysimage.jl's staleness check is mtime-only. The env is invisible to it,
    #      so an image built with the wrong environment reports "up to date" forever.
    #      Hence the rm: the rebuild has to be unconditional.
    #   2. $HOME is shared NFS. Nine columns starting at once would race on one .so.
    #   3. check_sysimage_env() (orchestrator.jl) exits 2 on a mismatch, so a stale image
    #      does not corrupt the run — it kills all nine columns a minute after launch.
    #      Better to find out before anything is launched.
    if [[ "${SKIP_SYSIMAGE:-0}" != "1" ]]; then
        bn="${NODEARR[0]}"
        echo "── sysimage (on $bn; \$HOME is shared, so once is enough) ────────"
        ssh "$bn" "bash -lc 'cd $REPO && source scripts/cluster_env.sh \
            && rm -f trimnalyser.so trimnalyser.so.juliaversion \
            && julia +1.12.2 --startup-file=no build_sysimage.jl'" 2>&1 | sed 's/^/  /'
        # Verify with the run-time guard itself, not a proxy: same function, same
        # comparison, before a single column is launched.
        if ! ssh "$bn" "bash -lc 'cd $REPO && source scripts/cluster_env.sh \
                && julia +1.12.2 --startup-file=no --sysimage trimnalyser.so --project=. \
                   -e \"using TrimAnalyser; TrimAnalyser.check_sysimage_env(); println(\\\"SYSIMAGE OK\\\")\"'" \
             2>&1 | sed 's/^/  /' | grep -q 'SYSIMAGE OK'; then
            echo -e "\nsysimage does not agree with cluster_env.sh — nothing launched." >&2
            exit 1
        fi
        echo "  sysimage ok"
    fi
    echo
    echo "── launching ────────────────────────────────────────────────────"
    mkdir -p "$BENCHLOGS" 2>/dev/null || true
    for i in "${!CFGARR[@]}"; do
        n="${NODEARR[$i]}"; c="${CFGARR[$i]}"; s=$(sess "$c")
        log="$BENCHLOGS/$c.$n.\$(date +%Y%m%d-%H%M%S).log"
        # cluster_env.sh must be sourced BEFORE julia starts: SOLVER_CONFIGS is a const
        # dict built at module load, so gssbin() reads the environment exactly once.
        # EXTRA reaches bench_config.sh through the environment, and ssh does not carry
        # it, so it is written into the command. Needed for `overwrite`: a smoke run leaves
        # .done/.sat sentinels behind, and without it the real run skips exactly the
        # instances the smoke test already touched, leaving its short-timeout numbers
        # standing as the last log block.
        # INSTFILE travels the same way and for the same reason. It is per-invocation, not
        # per-column, so a grid whose columns need different instance sets (lad-*: the two
        # proof-logging columns are capped to the 4,247-pair set, the three no-logging ones
        # run the whole family) has to be launched as one call per set.
        # The command is staged as a script on the node instead of being embedded in the
        # ssh -> bash -lc -> tmux quoting. Three levels of nesting cannot survive a value
        # containing a space: EXTRA="overwrite mindisk=3000" produced a tmux session that
        # died on creation, and run_grid.sh still printed "-> tmux:<name>" because the ssh
        # itself had succeeded. A whole launch looked fine and had not started.
        launcher="$BENCHLOGS/.launch-$c.sh"
        ssh "$n" "cat > $launcher" <<LAUNCH
#!/bin/bash
cd $REPO || exit 1
source scripts/cluster_env.sh
export EXTRA=${EXTRA:-}
export INSTFILE=${INSTFILE:-}
exec bash scripts/bench_config.sh $c $SCALE
LAUNCH
        if ssh "$n" "bash -lc 'mkdir -p $BENCHLOGS; tmux new-session -d -s $s \"bash $launcher 2>&1 | tee $log\"'"; then
            sleep 2
            if ssh "$n" "bash -lc 'tmux has-session -t $s 2>/dev/null'"; then
                printf '  %-14s %-16s -> tmux:%s\n' "$n" "$c" "$s"
            else
                printf '  %-14s %-16s LAUNCH DIED IMMEDIATELY (see $log)\n' "$n" "$c" >&2
            fi
        else
            printf '  %-14s %-16s LAUNCH FAILED\n' "$n" "$c" >&2
        fi
    done
    echo
    echo "watch:  bash scripts/run_grid.sh status"
    ;;

status)
    printf '  %-14s %-16s %-10s %s\n' NODE CONFIG STATE LOG
    for i in "${!CFGARR[@]}"; do
        n="${NODEARR[$i]}"; c="${CFGARR[$i]}"; s=$(sess "$c")
        if ! timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=8 "$n" true 2>/dev/null; then
            printf '  %-14s %-16s %-10s\n' "$n" "$c" "UNREACH"; continue; fi
        if ssh "$n" "tmux has-session -t $s 2>/dev/null"; then st=RUNNING; else st=done; fi
        # Last progress line from the newest log for this column.
        last=$(ssh "$n" "bash -lc 'ls -t $BENCHLOGS/$c.$n.*.log 2>/dev/null | head -1 | xargs -r tail -1'" 2>/dev/null | tr -d '\r' | cut -c1-60)
        printf '  %-14s %-16s %-10s %s\n' "$n" "$c" "$st" "$last"
    done
    ;;

tail)
    c="${2:-}"; [[ -n "$c" ]] || { echo "usage: run_grid.sh tail <config>" >&2; exit 1; }
    for i in "${!CFGARR[@]}"; do
        [[ "${CFGARR[$i]}" == "$c" ]] || continue
        n="${NODEARR[$i]}"
        exec ssh -t "$n" "bash -lc 'tail -f \$(ls -t $BENCHLOGS/$c.$n.*.log | head -1)'"
    done
    echo "config $c is not in CONFIGS" >&2; exit 1
    ;;

stop)
    # Kills the tmux session, which SIGHUPs the orchestrator. In-flight solver and trimmer
    # subprocesses are the orchestrator's children and go with it; anything that outlives
    # it shows up in the next `status` as a node with load but no session.
    for i in "${!CFGARR[@]}"; do
        n="${NODEARR[$i]}"; c="${CFGARR[$i]}"; s=$(sess "$c")
        ssh "$n" "tmux kill-session -t $s 2>/dev/null" && echo "  $n $c stopped" || echo "  $n $c not running"
    done
    ;;

*)  sed -n '3,20p' "$0"; exit 1 ;;
esac
