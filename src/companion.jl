# ══ Companion trimmers ════════════════════════════════════════════════════════════════════════
#
# The two VeriPB trimmers — `feature_trimmer` and `feature/trimmer-base` — run as a stage
# of this pipeline rather than from a shell harness beside it.
#
# WHY A STAGE, NOT A SCRIPT. The numbers our own trimmer contributes to the comparison
# come from the grid, which runs under this orchestrator: 92 threads, the admission gate
# in `wait_for_memory`, the OOM monitor's per-process ceiling, one `timeout` per stage,
# sentinels for resume, and `release_raw` deleting each proof as its instance finishes. A
# bash harness reproduces none of that faithfully. Measuring the companions there and ours
# here compares two schedulers at least as much as it compares two trimmers, and the
# scheduler differences are the larger effect: the first attempt at a harness put 48
# unbounded elaborations on one node and used 1.9 TB of 2.0 TB.
#
# It also removes the reason that harness had to work in batches. Two phases — solve
# everything, then compare everything — force every proof to exist at once, which is a
# disk problem that needs chunking to solve. Interleaved per instance, a proof lives only
# while its own instance is in flight, so peak disk is bounded by concurrency instead of
# by the size of the instance set. That is why the grid runs 25,590 instances in one pass.
#
# SHAPE follows `certify` deliberately, line for line: check the binary, check the inputs,
# go through `runcapture` (which is where the admission gate is), classify the exit code
# before reading stdout, `logstage` every field, and delete the artefacts on every path.

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
        printstyled("  $ins $(arm.tag) $(st === :verified ? "verified" : string(st)) $(round(vt; digits=1))s\n";
                    color = st === :verified ? :cyan : :yellow)
    end

        # Both arms, in order. Sequential per instance on purpose: they are two
        # measurements of the same proof, and running them concurrently would have each
        # one's timing depend on the other's memory pressure.
    function companion(ins)
        _cfg[].companion || return
        for arm in companion_arms
            companion_arm(ins, arm)
        end
    end
