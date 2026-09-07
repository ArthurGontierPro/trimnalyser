# ══ Companion trimmers ════════════════════════════════════════════════════════════════════════
#
# One column per companion trimmer, run exactly like every other column of the appendix
# grid: 92 threads, maxmem=32, the same timeouts, the same instance set, the same
# orchestrator. `companion=ft` and `companion=tb` each make one full run.
#
#   ./trimnalyser --threads 92,1 solve verif companion=ft config=gss-lazy-ft allgraphs ...
#
# WHAT IT DOES NOT MEASURE, on purpose: the untrimmed proof's elaboration, and our own
# trimmer. Both are already published from runs with these same parameters, so
# re-deriving them would cost days of solver time to reproduce numbers we have. The
# comparison joins this column's sizes and times against those.
#
# WHY A STAGE AND NOT A SHELL HARNESS. The published numbers come from runs under this
# orchestrator: the admission gate in `wait_for_memory`, the OOM monitor's per-process
# ceiling, one `timeout` per stage, sentinels for resume, and `release_raw` dropping each
# proof as its instance finishes. A trimmer measured under a different scheduler is not
# comparable to them -- and the difference is large: the harness this replaces put 48
# unbounded elaborations on one node and used 1.9 TB of 2.0 TB before the kernel
# intervened. Running here also removes that harness's need to work in batches, since
# peak disk follows concurrency rather than the size of the instance set.
#
# SHAPE follows `certify` deliberately, line for line: check the binary, check the inputs,
# go through `runcapture` (which is where the admission gate is), classify 124/137 before
# reading stdout, `logstage` every field, delete the artefacts on every path.

    const companion_ft = get(ENV, "VERIPB_FT",
        _cluster ? "/scratch/arthur/veripb_ft" : "")
    const companion_tb = get(ENV, "VERIPB_TB",
        _cluster ? "/scratch/arthur/veripb_tb" : "")

        # `trim` takes an output-formula positional on feature_trimmer; feature/trimmer-base
        # moved it to `check` only, so passing it there makes clap read the path as a stray
        # argument and the whole arm fails at startup with rc 2. Neither branch actually
        # writes a reformulated model on these proofs, but the argv still has to be right.
    const companion_arms = ((tag = "ft", bin = companion_ft, model = true),
                            (tag = "tb", bin = companion_tb, model = false))

        # One companion arm on one instance.
        #
        # Returns nothing; everything it measures goes to the log, which is what
        # aggregate_results.jl reads. Keys are "<tag> <FIELD> <value>" so they parse with
        # the same rule as every other stage.
    function companion_arm(ins, arm)
        isempty(arm.bin) && return
        ins2 = _cfg[].proofs * ins
        o, p = ins2 * opb, ins2 * pbp
        if !isfile(arm.bin)
            logstage(ins, "$(arm.tag) TRIM", "MISSING"); return
        end
        # The companions read the RAW proof, so this stage must run before release_raw.
        if !isfile(o) || !isfile(p)
            logstage(ins, "$(arm.tag) TRIM", "MISSING"); return
        end
        oo, op = ins2 * ".$(arm.tag)" * opb, ins2 * ".$(arm.tag)" * pbp
        tryrm(oo); tryrm(op)
        cmd = arm.model ? `$(arm.bin) trim $o $p $oo -e $op` :
                          `$(arm.bin) trim $o $p -e $op`
        (t, code, out, err) = runcapture(cmd, _cfg[].trimtimeout, op;
                                        stage = "companion $(arm.tag)", ins = ins)
        # 124 and 137 before anything else, for the same reason certify does it: a killed
        # process leaves partial output that reads like a refusal. A memout and a timeout
        # are different findings about a trimmer and must not be pooled with each other or
        # with a proof it genuinely rejects.
        status = code == 124 ? :timeout :
                 code == 137 ? :memout  :
                 (code == 0 && isfile(op) && filesize(op) > 0) ? :ok : :failed
        logstage(ins, "$(arm.tag) TRIM", uppercase(string(status)))
        logstage(ins, "$(arm.tag) TIME", round(t; digits=2))
        if status === :ok
            logstage(ins, "$(arm.tag) OPB SIZE", isfile(oo) ? filesize(oo) : 0)
            logstage(ins, "$(arm.tag) PBP SIZE", filesize(op))
            # Its own report of how much it removed.
            m = match(r"Number of trimmed steps:\s*(\d+)", out)
            m === nothing || logstage(ins, "$(arm.tag) STEPS", m.captures[1])
            companion_check(ins, arm, oo, op, o)
        else
            # When it refuses a proof VeriPB itself accepts, the reason is the finding.
            # The top-level line is always the same generic syntax error, so prefer the
            # detail under `Caused by:`.
            note = let mm = match(r"Caused by:\s*\n\s*(.+)", err)
                mm !== nothing ? mm.captures[1] :
                    (nn = match(r"(?m)^[Ee]rror.*$", err); nn === nothing ? "" : nn.match)
            end
            isempty(strip(note)) ||
                logstage(ins, "$(arm.tag) NOTE", replace(strip(note), r"[,;\n]" => ".")[1:min(end,200)])
            !isempty(strip(err)) && write(ins2 * ".$(arm.tag).err", err)
        end
        tryrm(oo); tryrm(op)
    end

        # Re-check the companion's output with the SAME binary every other arm is checked
        # with, so the verify times are comparable across arms and the verdict comes from
        # one checker rather than from each tool's own opinion of itself.
    function companion_check(ins, arm, oo, op, orig_opb)
        # A trimmer that emits no reformulated model leaves its proof against the ORIGINAL
        # formula; using an empty file here would reject every proof for the wrong reason.
        model = (isfile(oo) && filesize(oo) > 0) ? oo : orig_opb
        (vt, code, out, _) = runcapture(`$veripbpath $model $op`, _cfg[].veriftimeout, op;
                                        stage = "companion $(arm.tag) check", ins = ins)
        # VERIFIED on stdout, never a file's existence — see certify.
        st = code == 124 ? :timeout : code == 137 ? :memout :
             occursin("VERIFIED", out) ? :verified : :failed
        logstage(ins, "$(arm.tag) VERI", uppercase(string(st)))
        logstage(ins, "$(arm.tag) VERI TIME", round(vt; digits=2))
        # Resume marker, same as the normal path's. A verdict is a verdict: a proof this
        # trimmer produced and the checker rejected is a RESULT for the table, not work to
        # redo. Timeouts and memouts are deliberately left unmarked so a rerun at a larger
        # tt= or maxmem= picks them up, which is how every other stage behaves.
        st in (:verified, :failed) && touch(_cfg[].proofs * ins * ".done")
        printstyled("  $ins $(arm.tag) $(st === :verified ? "verified" : string(st)) $(round(vt; digits=1))s\n";
                    color = st === :verified ? :cyan : :yellow)
    end

        # Both arms, in order. Sequential per instance on purpose: they are two
        # measurements of the same proof, and running them concurrently would have each
        # one's timing depend on the other's memory pressure.
        # The one arm this run is a column for. Never both: two trimmers in one run would
        # share a log file and an instance's timings would depend on which ran first.
    function companion(ins)
        isempty(_cfg[].companion) && return
        # The untrimmed proof's size, under the same keys the normal path uses. It is the
        # denominator of every ratio in the table, and it is what a join against the
        # already-published columns is guarded on: two rows describe the same proof only
        # if these agree. Logged here because the normal trim path, which usually logs
        # them, does not run in a companion column. Cheap, and it makes the column
        # self-sufficient rather than only meaningful next to another one.
        let o = _cfg[].proofs * ins * opb, p = _cfg[].proofs * ins * pbp
            if isfile(o) && isfile(p)
                logstage(ins, "inp OPB SIZE", filesize(o))
                logstage(ins, "inp PBP SIZE", filesize(p))
                logstage(ins, "inp SIZE",     filesize(o) + filesize(p))
            end
        end
        for arm in companion_arms
            arm.tag == _cfg[].companion && return companion_arm(ins, arm)
        end
    end
