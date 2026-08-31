# ══ Entry point ══════════════════════════════════════════════════════════════════════════
# ══ Signal Handling ═══════════════════════════════════════════════════════════════════════════
    const _sysimage = joinpath(@__DIR__, "..", "trimnalyser.so")
    # Grace period between the trim timeout's SIGTERM and an uncatchable SIGKILL, in seconds.
    # handle_timeout below is NEVER reached: Julia masks SIGTERM in every thread and takes it on
    # a dedicated sigwait thread, so `signal(SIGTERM, ...)` installs a handler nothing delivers
    # to (the comment in run_trim_subprocess has said so for a while). Termination therefore
    # depends on Julia's own orderly shutdown, and that shutdown deadlocks: in the 2026-08-24
    # grid, gss-proof/LVg57g66 and gss-nostaged/LVg14g48 each burned their full 6000 s of CPU,
    # took the SIGTERM, and then slept for 43 h and 91 h holding 30 GB and 23 GB while the rest
    # of the node sat at load 0.00 — one wedged trim per column, each stalling a whole node.
    # `timeout -k` hands the second kill to the kernel, which cannot be caught or deadlocked.
    const trim_kill_grace = 60
    # Clean exit on timeout. Uses only async-signal-safe syscalls: write(2) + _exit(2).
    # Julia's exit() and println() acquire locks and are unsafe from a C signal handler.
    function handle_timeout(sig::Cint)
        msg = "Timeout: exiting (signal $sig)\n"
        ccall(:write, Cint, (Cint, Ptr{UInt8}, Csize_t), 2, msg, sizeof(msg))
        ccall(:_exit, Cvoid, (Cint,), Int32(124))
    end

    function packdots()
        visdir = _cfg[].proofs * "vis/"
        archive = _cfg[].proofs * "vis.tar.gz"
        dots = filter(f -> endswith(f, ".dot"), readdir(visdir; join=true))
        isempty(dots) && (println("No .dot files to pack."); return)
        run(`tar -czf $archive -C $visdir .`)
        println("Packed $(length(dots)) .dot files → $archive") end

    function renderdots()
        archive = _cfg[].proofs * "vis.tar.gz"
        visdir  = _cfg[].proofs * "vis/"
        isfile(archive) && run(`tar -xzf $archive -C $visdir`)
        dots = filter(f -> endswith(f, ".dot"), readdir(visdir; join=true))
        isempty(dots) && (println("No .dot files to render."); return)
        for dot in dots
            svg = dot[1:end-4] * ".svg"
            content = read(dot, String)
            m = match(r"layout=(\w+)", content)
            layout = m !== nothing ? m.captures[1] : "neato"
            try run(ignorestatus(`neato -Tsvg -K$layout -o$svg $dot`))
            catch; #printstyled("  neato not found — install graphviz\n"; color=:yellow);
                return
            end
        end
        println("Rendered $(length(dots)) SVGs in $visdir") end

    function getinstancesfromdir(proofs_dir)
        list = onlyname.(filter(x -> ext(x)==opb && isfile(noext(x)*pbp), readdir(proofs_dir, join=true)))
        if _cfg[].rand _shuffle!(list)
        elseif _cfg[].sort_by_size sort!(list, by = x -> inssize(x)) end
        println("%Found ", length(list), " instances in ", proofs_dir)
        return list end

    function paths_to_instance(patpath, tarpath)
        if contains(patpath, "/LV/")
            return "LV" * basename(patpath) * basename(tarpath)
        elseif contains(patpath, "/biochemicalReactions/")
            return "bio" * replace(basename(patpath), ".txt" => "") * replace(basename(tarpath), ".txt" => "")
        elseif contains(patpath, "/images-CVIU11/")
            return "cviu11_p" * replace(basename(patpath), "pattern" => "") * "_t" * replace(basename(tarpath), "target" => "")
        elseif contains(patpath, "/images-PR15/")
            return "pr15_p" * replace(basename(patpath), "pattern" => "")
        elseif contains(patpath, "/meshes-CVIU11/")
            return "mesh11_p" * replace(basename(patpath), "pattern" => "") * "_t" * replace(basename(tarpath), "target" => "")
        elseif contains(patpath, "/phase/")
            return "ph_" * replace(basename(patpath), "-pattern" => "")
        elseif contains(patpath, "/scalefree/")
            parts = splitpath(patpath)
            idx = findfirst(==("scalefree"), parts)
            return idx !== nothing && idx < length(parts) - 1 ? "sf_" * parts[idx + 1] : nothing
        elseif contains(patpath, "/si/")
            parts = splitpath(patpath)
            idx = findfirst(==("si"), parts)
            return idx !== nothing && idx + 2 <= length(parts) ? "si__" * parts[idx + 1] * "__" * parts[idx + 2] : nothing
        end
        return nothing end

    function instancesfromfile(path)
        list = String[]
        skipped = 0
        for line in eachline(path)
            line = strip(line)
            isempty(line) && continue
            line[1] == '#' && continue
            if contains(line, '\t')
                parts = split(line, '\t'; limit=2)
                ins = paths_to_instance(parts[1], parts[2])
                if ins === nothing
                    skipped += 1
                else
                    push!(list, ins)
                end
            else
                push!(list, line)
            end
        end
        # bio is directed. LAD reads directed graphs as undirected without warning (on
        # bio 001->002 Glasgow says SAT and LAD says UNSAT) and CakePB rejects them
        # outright, so a lad-* bio row is an answer to a DIFFERENT QUESTION and can never
        # be verified. Every bio cell of tab:configs-lad is marked †.
        #
        # These used to be filtered out entirely, as ladveri's own bench.py does. They now
        # run, so that "all 25590" means all 25590 and the table shows a measured cell
        # rather than a gap — but every one of them is announced here and stamped in its
        # own log by `lad_bio_marker` (see run_instance_*), because the one thing that must
        # not happen is a bio verdict being averaged into a LAD-vs-Glasgow comparison by
        # someone who did not read the footnote. Filter on `lad VALIDITY` or on the `bio`
        # prefix; do not rely on the marker being absent to mean "comparable".
        if solverconfig().kind == "lad"
            nbio = count(x -> startswith(x, "bio"), list)
            nbio == 0 ||
                printstyled("%Including $nbio bio instances for a lad-* config: DIRECTED graphs, ",
                            "read as undirected, unverifiable — marked † and stamped ",
                            "`lad VALIDITY DIRECTED_UNSOUND` per instance\n"; color=:yellow)
        end

        _cfg[].rand && _shuffle!(list)
        skipped > 0 && printstyled("  instfile: skipped $skipped unresolvable line(s)\n"; color=:yellow)
        println("%Read ", length(list), " instances from ", path)
        return list end

        # Enumerates all (pattern, target) instance names from the benchmark graph directories.
        # Filters pairs where both graphs have nodes in [minnodes, maxnodes] and pattern_size <= target_size.
    function allgraphinstances()
        list = String[]
        mkpath(_cfg[].proofs)

        # LV and biochemicalReactions: all (p,t) pairs from a single flat directory
        for (dir, pre, fext, fmt) in [
                (SIPgraphpath*"LV/",                    "g",  "",     (p,t) -> "LVg$(p)g$(t)"),
                (SIPgraphpath*"biochemicalReactions/",  "",   ".txt", (p,t) -> "bio$(p)$(t)") ]
            isdir(dir) || continue
            files = readdir(dir)
            ids = [f[length(pre)+1 : end-length(fext)] for f in files
                   if startswith(f, pre) && endswith(f, fext) && !isdir(dir*f)]
            sizes = Dict{String,Int}()
            for id in ids
                n = ladnodes(dir * pre * id * fext)
                n !== nothing && n >= _cfg[].minnodes && n <= _cfg[].maxnodes && (sizes[id] = n)
            end
            valid = collect(keys(sizes))
            _cfg[].rand ? _shuffle!(valid) : sort!(valid)
            for p in valid, t in valid
                p == t && continue
                sizes[p] > sizes[t] && continue
                push!(list, fmt(p, t))
            end
        end

        # images-CVIU11: patterns/ × targets/, all cross-pairs where pat_nodes <= tar_nodes
        let dir = SIPgraphpath * "images-CVIU11/"
            if isdir(dir * "patterns/") && isdir(dir * "targets/")
                pat_ids = sort!([parse(Int, f[8:end]) for f in readdir(dir*"patterns/") if startswith(f,"pattern")])
                tar_ids = sort!([parse(Int, f[7:end]) for f in readdir(dir*"targets/") if startswith(f,"target")])
                pat_sizes = Dict{Int,Int}(); tar_sizes = Dict{Int,Int}()
                for id in pat_ids
                    n = ladnodes(dir*"patterns/pattern$id")
                    n !== nothing && n >= _cfg[].minnodes && n <= _cfg[].maxnodes && (pat_sizes[id] = n)
                end
                for id in tar_ids
                    n = ladnodes(dir*"targets/target$id")
                    n !== nothing && n >= _cfg[].minnodes && n <= _cfg[].maxnodes && (tar_sizes[id] = n)
                end
                for (p, np) in pat_sizes, (t, nt) in tar_sizes
                    np <= nt && push!(list, "cviu11_p$(p)_t$(t)")
                end
            end
        end

        # images-PR15: each pattern vs a single shared target file
        let dir = SIPgraphpath * "images-PR15/"
            if isdir(dir) && isfile(dir*"target")
                nt = ladnodes(dir*"target")
                if nt !== nothing && nt >= _cfg[].minnodes && nt <= _cfg[].maxnodes
                    pat_ids = sort!([parse(Int, f[8:end]) for f in readdir(dir) if startswith(f,"pattern")])
                    for id in pat_ids
                        np = ladnodes(dir*"pattern$id")
                        np !== nothing && np >= _cfg[].minnodes && np <= nt && push!(list, "pr15_p$id")
                    end
                end
            end
        end

        # meshes-CVIU11: patterns/ × targets/, all cross-pairs where pat_nodes <= tar_nodes
        let dir = SIPgraphpath * "meshes-CVIU11/"
            if isdir(dir * "patterns/") && isdir(dir * "targets/")
                pat_ids = sort!([parse(Int, f[8:end]) for f in readdir(dir*"patterns/") if startswith(f,"pattern")])
                tar_ids = sort!([parse(Int, f[7:end]) for f in readdir(dir*"targets/") if startswith(f,"target")])
                pat_sizes = Dict{Int,Int}(); tar_sizes = Dict{Int,Int}()
                for id in pat_ids
                    n = ladnodes(dir*"patterns/pattern$id")
                    n !== nothing && n >= _cfg[].minnodes && n <= _cfg[].maxnodes && (pat_sizes[id] = n)
                end
                for id in tar_ids
                    n = ladnodes(dir*"targets/target$id")
                    n !== nothing && n >= _cfg[].minnodes && n <= _cfg[].maxnodes && (tar_sizes[id] = n)
                end
                for (p, np) in pat_sizes, (t, nt) in tar_sizes
                    np <= nt && push!(list, "mesh11_p$(p)_t$(t)")
                end
            end
        end

        # phase: sibling <base>-pattern / <base>-target file pairs
        let dir = SIPgraphpath * "phase/"
            if isdir(dir)
                bases = sort!([f[1:end-8] for f in readdir(dir) if endswith(f, "-pattern")])
                for base in bases
                    isfile(dir * base * "-target") || continue
                    np = ladnodes(dir * base * "-pattern")
                    nt = ladnodes(dir * base * "-target")
                    (np === nothing || nt === nothing) && continue
                    (np > _cfg[].maxnodes || nt > _cfg[].maxnodes || np < _cfg[].minnodes || nt < _cfg[].minnodes) && continue
                    np <= nt && push!(list, "ph_$base")
                end
            end
        end

        # scalefree: one pattern/target pair per subdirectory
        let dir = SIPgraphpath * "scalefree/"
            if isdir(dir)
                for subdir in sort!(filter(d -> isdir(dir*d), readdir(dir)))
                    pat = dir * subdir * "/pattern"; tar = dir * subdir * "/target"
                    isfile(pat) && isfile(tar) || continue
                    np = ladnodes(pat); nt = ladnodes(tar)
                    (np === nothing || nt === nothing) && continue
                    (np > _cfg[].maxnodes || nt > _cfg[].maxnodes || np < _cfg[].minnodes || nt < _cfg[].minnodes) && continue
                    np <= nt && push!(list, "sf_$subdir")
                end
            end
        end

        # bio is directed. LAD reads directed graphs as undirected without warning (on
        # bio 001->002 Glasgow says SAT and LAD says UNSAT) and CakePB rejects them
        # outright, so a lad-* bio row is an answer to a DIFFERENT QUESTION and can never
        # be verified. Every bio cell of tab:configs-lad is marked †.
        #
        # These used to be filtered out entirely, as ladveri's own bench.py does. They now
        # run, so that "all 25590" means all 25590 and the table shows a measured cell
        # rather than a gap — but every one of them is announced here and stamped in its
        # own log by `lad_bio_marker` (see run_instance_*), because the one thing that must
        # not happen is a bio verdict being averaged into a LAD-vs-Glasgow comparison by
        # someone who did not read the footnote. Filter on `lad VALIDITY` or on the `bio`
        # prefix; do not rely on the marker being absent to mean "comparable".
        if solverconfig().kind == "lad"
            nbio = count(x -> startswith(x, "bio"), list)
            nbio == 0 ||
                printstyled("%Including $nbio bio instances for a lad-* config: DIRECTED graphs, ",
                            "read as undirected, unverifiable — marked † and stamped ",
                            "`lad VALIDITY DIRECTED_UNSOUND` per instance\n"; color=:yellow)
        end

        _cfg[].rand && _shuffle!(list)
        println("%Generated ", length(list), " instances from benchmark graphs (minnodes=", _cfg[].minnodes, " maxnodes=", _cfg[].maxnodes, ")")
        return list end

    function run_trim_subprocess(ins, subargs, script)
        wait_for_memory("trim", ins)
        wait_for_disk("trim", ins)
        subout = _cfg[].proofs * ins * ".subout"
        suberr = _cfg[].proofs * ins * ".suberr"
        use_sysimage = isfile(_sysimage)
        _root = dirname(_sysimage)
        julia_flags = use_sysimage ? `--sysimage $_sysimage --project=$_root -t1,1` : `-t1,1`
        sub_env = ["JULIA_NUM_THREADS" => "1", "OPENBLAS_NUM_THREADS" => "1", "MKL_NUM_THREADS" => "1"]
        use_sysimage && push!(sub_env, "TRIMNALYSER_SYSIMAGE" => "1")
        proc = run(pipeline(addenv(`timeout -k $trim_kill_grace $(_cfg[].trimtimeout) julia $julia_flags $script $ins $subargs`, sub_env...),
                           stdout=subout, stderr=suberr),
                   wait=false)
        wait(proc)
        exitcode = proc.exitcode
        if isfile(subout)
            out = read(subout, String)
            !isempty(out) && (print(out); flush(stdout))
            rm(subout)
        end
        # On timeout, Julia's signal thread prints a SIGTERM backtrace via sigdie_handler to fd2
        # (bypasses our custom C handler — Julia masks SIGTERM and catches it via sigwait).
        # Discard suberr on timeout: it contains only that spurious backtrace.
        # On other exits, forward stderr so genuine crash info is visible.
        if exitcode == 124
            isfile(suberr) && rm(suberr)
        else
            if isfile(suberr)
                err = read(suberr, String)
                !isempty(err) && (print(Base.stderr, err); flush(Base.stderr))
                rm(suberr)
            end
        end
        smol_complete(ins) && return :ok
        if exitcode == 124
            msg = "Timeout after $(_cfg[].trimtimeout)s"
            printstyled("  $ins: $msg\n"; color=:red)
            open(_cfg[].proofs*ins*".err", "a") do f; println(f, msg) end
            logstage(ins, "trim TIMEOUT", _cfg[].trimtimeout)
            return :timeout
        elseif exitcode == 137
            # 137 now has two producers: the OOM monitor's `kill -9`, and `timeout -k` above
            # escalating because the SIGTERM went unanswered. Only the first is a memout, and it
            # always appends "OOM at <rss>G" to .err BEFORE it kills (see the monitor loop), so
            # that line is what separates them. Assuming memout is the expensive direction: it
            # writes .memoutNNN, which suppresses the instance on every later run that does not
            # raise maxmem=, so a trim that merely ran long would be silently dropped from the
            # table thereafter.
            if first(was_oom_killed(ins))
                msg = "OOM killed (exceeded $(_cfg[].maxinstmem_gb) GB)"
                printstyled("  $ins: $msg\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, msg) end
                logstage(ins, "trim MEMOUT", _cfg[].maxinstmem_gb)
                touch(memout_sentinel(ins))
                return :memout
            else
                msg = "Timeout after $(_cfg[].trimtimeout)s (SIGKILL after $(trim_kill_grace)s grace)"
                printstyled("  $ins: $msg\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, msg) end
                logstage(ins, "trim TIMEOUT", _cfg[].trimtimeout)
                return :timeout
            end
        else
            exitcode != 0 && (printstyled("  $ins: trim failed (exit $exitcode)\n"; color=:red);
                              logstage(ins, "trim ERR exit", exitcode))
            return :failed
        end end

    function run_resolv_loop(ins, use_subprocess::Bool, subargs=nothing, script=nothing)
        cur_pat = _cfg[].proofs * "vis/" * ins * ".core.pat.lad"
        cur_tar = _cfg[].proofs * "vis/" * ins * ".core.tar.lad"
        patfile, tarfile = parsegraphfiles(ins)
        prev_np = parse(Int, readline(patfile))
        prev_nt = parse(Int, readline(tarfile))
        outfile = logpath(ins)
        open(outfile, "a") do f; println(f, "resolv ITER 0 PAT $prev_np TAR $prev_nt") end
        iter = 0
        while true
            iter += 1
            if !isfile(cur_pat) || !isfile(cur_tar)
                open(outfile, "a") do f; println(f, "resolv STOP missing_lads") end
                printstyled("  resolv: core LADs missing at iter $iter\n"; color=:red); return
            end
            np = parse(Int, readline(cur_pat))
            nt = parse(Int, readline(cur_tar))
            if np == prev_np && nt == prev_nt
                open(outfile, "a") do f; println(f, "resolv STOP stabilized") end
                tryrm(cur_pat); tryrm(cur_tar)
                printstyled("  $ins resolv: fixpoint after $(iter-1) iteration(s) ($np pat, $nt tar nodes)\n"; color=:green); return
            end
            prev_np, prev_nt = np, nt
            open(outfile, "a") do f; println(f, "resolv ITER $iter PAT $np TAR $nt") end
            core_ins = ins * ".core$iter"
            tryrm(_cfg[].proofs*core_ins*".err")
            t = @elapsed (ok, timed_out) = runsolver(core_ins, cur_pat, cur_tar)
            if !ok
                stop = timed_out ? "solver_timeout" : "solver_failed"
                open(outfile, "a") do f; println(f, "resolv STOP $stop") end
                tryrm(cur_pat); tryrm(cur_tar)
                printstyled("  resolv: solver failed/timeout at iter $iter ($(round(t;digits=1))s)\n"; color=:red); return
            end
            if isempty(pbpconclusion(core_ins))
                open(outfile, "a") do f; println(f, "resolv STOP truncated") end
                tryrm(cur_pat); tryrm(cur_tar)
                printstyled("  $ins resolv iter $iter: truncated proof — aborting\n"; color=:red)
                open(_cfg[].proofs*core_ins*".err", "a") do f; println(f, "proof truncated: no conclusion") end
                return
            end
            printstyled("  $ins resolv iter $iter: $np pat / $nt tar → solved $(round(t;digits=1))s\n"; color=:cyan)
            # Each iteration repeats the whole certification chain of the top-level
            # instance: certify the reduced proof, trim it, certify the trimmed proof.
            _cfg[].verif && certify(core_ins, "full")
            if use_subprocess
                trim_status = run_trim_subprocess(core_ins, subargs, script)
                if trim_status !== :ok
                    stop = trim_status === :timeout ? "trim_timeout" :
                           trim_status === :memout  ? "trim_memout"  : "trim_failed"
                    open(outfile, "a") do f; println(f, "resolv STOP $stop") end
                    if trim_status === :timeout || trim_status === :memout
                        if !_cfg[].keepraw
                            tryrm(_cfg[].proofs * core_ins * pbp)
                            tryrm(_cfg[].proofs * core_ins * opb)
                        end
                    end
                    return
                end
            else
                printabline(core_ins)
                parse_time,trim_time,write_time,cone_stats,coremsg = trimnalyse(core_ins; mode=Grim())
                printabline2(core_ins, parse_time, trim_time, write_time, cone_stats)
                !isempty(coremsg) && println(coremsg)
            end
            if !_cfg[].keepraw
                tryrm(_cfg[].proofs * core_ins * pbp)
                tryrm(_cfg[].proofs * core_ins * opb)
            end
            smol_vt,smol_vs,smol_ct,smol_cs = _cfg[].verif ? certify(core_ins, "smol") :
                                                             (-1,:missing,-1,:missing)
            if !_cfg[].keepraw && smol_vs === :verified
                tryrm(_cfg[].proofs * core_ins * smol_pbp)
                tryrm(_cfg[].proofs * core_ins * smol_opb)
            end
            # recurse_ok logs its own "resolv STOP <reason>" line.
            recurse_ok(core_ins, smol_vs, smol_cs) ||
                (tryrm(cur_pat); tryrm(cur_tar); return)
            cur_pat = _cfg[].proofs * "vis/" * core_ins * ".core.pat.lad"
            cur_tar = _cfg[].proofs * "vis/" * core_ins * ".core.tar.lad"
        end end

        # Shared prologue for both instance drivers: OOM sentinel, log reset, solve,
        # conclusion gate and size guard. Returns :ok to continue, :skip to abandon the instance.
    function prepare_instance(ins)
        let (memout, lim) = memout_at_current_maxmem(ins)
            if !_cfg[].overwrite && memout
                printstyled("  $ins previously OOM killed (sentinel maxmem=$(lim)G) — skipping\n"; color=:yellow)
                runheader(ins); logstage(ins, "solve MEMOUT", lim)
                return :skip
            end
        end
        oom_killed, mem_info = was_oom_killed(ins)
        if !_cfg[].overwrite && oom_killed
            mem_str = isempty(mem_info) ? "" : " at $mem_info"
            printstyled("  $ins previously OOM killed$mem_str — skipping\n"; color=:yellow)
            runheader(ins); logstage(ins, "solve MEMOUT", isempty(mem_info) ? "?" : mem_info)
            return :skip
        end
        tryrm(_cfg[].proofs*ins*".err")
        runheader(ins)
        if _cfg[].solve
            patfile, tarfile = parsegraphfiles(ins)
            if patfile === nothing
                printstyled("  solve: cannot parse graph paths for $ins\n"; color=:red)
                logstage(ins, "solve ERR", "no_graph_paths"); return :skip
            end
            if !_cfg[].overwrite && isfile(_cfg[].proofs*ins*opb) && !isempty(pbpconclusion(ins))
                printstyled("  $ins proof exists — skipping solve\n"; color=:blue)
            else
                # ── Tier 1: no proof logging, short cap. Five of the fourteen configurations
                # write no proof at all and this solve IS their table cell; for the rest it
                # is the gate that keeps expensive logging runs off hopeless instances.
                if _cfg[].nopltimeout > 0
                    t0 = @elapsed runsolver(ins, patfile, tarfile; prove=false,
                                               timeout=_cfg[].nopltimeout)
                    v0 = solve_verdict(ins)
                    logstage(ins, "nopl VERDICT", uppercase(string(v0)))
                    logstage(ins, "nopl TIME", round(t0; digits=2))
                    if v0 === :sat
                        touch(_cfg[].proofs * ins * ".sat")
                        printstyled("  $ins SAT (no-logging solve) — skipping\n"; color=:yellow)
                        return :skip
                    elseif v0 === :unknown
                        touch(_cfg[].proofs * ins * ".timeout$(_cfg[].nopltimeout)")
                        printstyled("  $ins did not conclude in $(_cfg[].nopltimeout)s without logging — skipping\n"; color=:red)
                        return :skip
                    end
                    if !solverconfig().proves
                        # The cell is complete: this configuration never logs a proof.
                        touch(_cfg[].proofs * ins * ".done")
                        printstyled("  $ins $(uppercase(string(v0))) $(round(t0;digits=1))s (no-logging config)\n"; color=:cyan)
                        return :skip
                    end
                end
                # ── Tier 2: the logging solve.
                t = @elapsed (ok, timed_out) = runsolver(ins, patfile, tarfile)
                if !ok
                    if solve_verdict(ins) === :sat
                        touch(_cfg[].proofs * ins * ".sat")
                        tryrm(_cfg[].proofs * ins * pbp)
                        tryrm(_cfg[].proofs * ins * opb)
                        printstyled("  $ins SAT — skipping\n"; color=:yellow)
                        logstage(ins, "solve VERDICT", "SAT"); logstage(ins, "solve TIME", round(t; digits=2))
                    elseif timed_out
                        touch(_cfg[].proofs * ins * ".timeout$(_cfg[].solvertimeout)")
                        tryrm(_cfg[].proofs * ins * pbp)
                        tryrm(_cfg[].proofs * ins * opb)
                        printstyled("  $ins solver timed out ($(round(t;digits=1))s)\n"; color=:red)
                        logstage(ins, "solve VERDICT", "TIMEOUT"); logstage(ins, "solve TIMEOUT", _cfg[].solvertimeout)
                    else
                        printstyled("  $ins solve failed ($(round(t;digits=1))s)\n"; color=:red)
                        logstage(ins, "solve VERDICT", "FAILED"); logstage(ins, "solve TIME", round(t; digits=2))
                    end
                    return :skip
                end
                printstyled("  $ins solved $(round(t;digits=1))s\n"; color=:cyan)
                logstage(ins, "solve VERDICT", "UNSAT"); logstage(ins, "solve TIME", round(t; digits=2))
            end
        end
        let c = pbpconclusion(ins)
            if c == "SAT" || c == "NONE"
                touch(_cfg[].proofs * ins * ".sat")
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins $c — skipping\n"; color=:yellow)
                logstage(ins, "solve VERDICT", c); return :skip
            end
            if isempty(c)
                # Capture this BEFORE the cleanup below deletes the file.
                partial = filesize(_cfg[].proofs * ins * pbp) > 0
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins: no conclusion (truncated proof) — skipping\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, "proof truncated: no conclusion") end
                # A truncated proof is the solver dying mid-write, which in practice is always
                # an OOM: record it like any other memout so the next run with the same
                # maxmem= does not re-solve it from scratch. Only when a partial .pbp is
                # actually on disk — pbpconclusion() also returns "" for a MISSING file,
                # and sentinelling that would permanently skip an instance never solved.
                partial && touch(memout_sentinel(ins))
                logstage(ins, "solve ERR", "truncated_proof"); return :skip
            end
        end
        let sz = (isfile(_cfg[].proofs*ins*opb) ? filesize(_cfg[].proofs*ins*opb) : 0) +
                    (isfile(_cfg[].proofs*ins*pbp) ? filesize(_cfg[].proofs*ins*pbp) : 0)
            if sz > 50 * 1024^3
                printstyled("  $ins too large ($(round(sz/1024^3; digits=1)) GB) — skipping\n"; color=:yellow)
                logstage(ins, "solve ERR", "too_large_$(round(sz/1024^3; digits=1))G")
                # Delete it. This branch used to return with the proof still on disk,
                # which is the one skip path that LEAKS: every instance too big to trim
                # left its tens of GB behind for the rest of the run. Invisible on the
                # Glasgow grid, where the branch essentially never fires; fatal for LAD,
                # whose proofs have no deletions and grow with search length, so the
                # instances that trip 50 GB are common rather than exceptional.
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                return :skip
            end
        end
        return :ok end

        # Gate on the recursion into the reduced instance. A coreN chain built on a proof
        # that was never certified is not evidence of anything, so the loop is entered only
        # when the trimmed proof passed every checker that is switched on: VeriPB always,
        # and Cake too when `cake` is set.
    function recurse_ok(ins, smol_vs, smol_cs)
        _cfg[].resolv || return false
        _cfg[].verif  || return true
        if smol_vs !== :verified
            logstage(ins, "resolv STOP", "smol_$(smol_vs)"); return false
        end
        if _cfg[].cake && smol_cs !== :verified
            logstage(ins, "resolv STOP", "smolcake_$(smol_cs)"); return false
        end
        return true end

    function run_instance_batch(ins, subargs, script)
        prepare_instance(ins) === :ok || return
        # The full proof is certified BEFORE the trim, and its elaboration is deleted
        # before the trimmer starts. The order matters twice: it is what lets a run report
        # "the untrimmed proof could not be certified, the trimmed one could" as a fact
        # about one and the same solve, and it keeps the elaborated full proof — the
        # largest file the pipeline ever writes — off disk while the trimmer works.
        _cfg[].verif && certify(ins, "full")
        # The trim is a SIBLING of that certification, not its child: it runs whatever
        # VeriPB said. An instance the full checker times out on is exactly the case the
        # rescue result is about, so it must not be skipped here.
        trim_status = run_trim_subprocess(ins, subargs, script)
        if trim_status !== :ok
            if trim_status === :timeout || trim_status === :memout
                if !_cfg[].keepraw
                    tryrm(_cfg[].proofs * ins * pbp)
                    tryrm(_cfg[].proofs * ins * opb)
                end
            end
            return
        end
        if !_cfg[].keepraw
            tryrm(_cfg[].proofs * ins * pbp)
            tryrm(_cfg[].proofs * ins * opb)
        end
        smol_vt,smol_vs,smol_ct,smol_cs = _cfg[].verif ? certify(ins, "smol") :
                                                         (-1,:missing,-1,:missing)
        if !_cfg[].keepraw && smol_vs === :verified
            tryrm(_cfg[].proofs * ins * smol_pbp)
            tryrm(_cfg[].proofs * ins * smol_opb)
            touch(_cfg[].proofs * ins * ".done")
        end
        recurse_ok(ins, smol_vs, smol_cs) && run_resolv_loop(ins, true, subargs, script) end

    function run_instance_full(ins)
        if !_cfg[].overwrite && smol_complete(ins)
            printstyled("  $ins already done — skipping\n"; color=:blue); return
        end
        if isfile(_cfg[].proofs * ins * ".sat")
            tryrm(_cfg[].proofs * ins * pbp)
            tryrm(_cfg[].proofs * ins * opb)
            printstyled("  $ins SAT (cached) — skipping\n"; color=:yellow); return
        end
        if !_cfg[].overwrite && timed_out_at_current_st(ins)
            printstyled("  $ins timed out (cached st≤$(_cfg[].solvertimeout)s) — skipping\n"; color=:yellow); return
        end
        let (memout, lim) = memout_at_current_maxmem(ins)
            if !_cfg[].overwrite && memout
                printstyled("  $ins previously OOM killed (sentinel maxmem=$(lim)G) — skipping\n"; color=:yellow); return
            end
        end
        prepare_instance(ins) === :ok || return
        grim_verif_ok = false
        if !_cfg[].nonorm
            _cfg[].verif && certify(ins, "full")
            printabline(ins)
            parse_time,trim_time,write_time,cone_stats,coremsg = trimnalyse(ins; mode=Grim())
            printabline2(ins,parse_time,trim_time,write_time,cone_stats)
            !isempty(coremsg) && println(coremsg)
            # After printabline2, which reads the raw proof's sizes for the table row.
            if !_cfg[].keepraw && !_cfg[].clit
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
            end
            smol_vt,smol_vs,smol_ct,smol_cs = _cfg[].verif ? certify(ins, "smol") :
                                                             (-1,:missing,-1,:missing)
            grim_verif_ok = smol_vs === :verified
            recurse_ok(ins, smol_vs, smol_cs) && run_resolv_loop(ins, false)
        end
        if _cfg[].clit
            printabline(ins)
            parse_time,trim_time,write_time,cone_stats,_ = trimnalyse(ins; mode=Clit())
            printabline2(ins,parse_time,trim_time,write_time,cone_stats)
            _cfg[].verif && certify(ins, "smol")
        end
        if !_cfg[].keepraw && grim_verif_ok
            tryrm(_cfg[].proofs * ins * pbp)
            tryrm(_cfg[].proofs * ins * opb)
            tryrm(_cfg[].proofs * ins * smol_pbp)
            tryrm(_cfg[].proofs * ins * smol_opb)
            touch(_cfg[].proofs * ins * ".done")
        end end

        # Route 2 is implemented: runladsolver feeds LAD proofs into the same
        # trim/verif/resolv pipeline as Glasgow's, using LAD's own -O model as the OPB.
        # What is still missing is a Cake-clean writecoreladfile (ROADMAP M7.5), so resolv
        # on a lad-* configuration re-enters the solver with LAD-format files this harness
        # writes and Cake's stricter parser has never been shown to accept.
    function check_lad_route(args)
        solverconfig().kind == "lad" || return
        isfile(solverconfig().binary) ||
            error("config=$(_cfg[].config) needs the LAD binary at $(solverconfig().binary) " *
                  "(override with \$LAD_SOLVER)")
    end

    function _run_main(args)
        check_lad_route(args)
        if _cfg[].pack   packdots();   return
        elseif _cfg[].render renderdots(); return
        elseif _cfg[].atable plotresultstable(); return
        elseif _cfg[].clean
            for f in readdir(_cfg[].proofs; join=true)
                b = basename(f)
                if endswith(b, ".out") || endswith(b, ".err") ||
                   endswith(b, ".done") || endswith(b, ".sat") ||
                   match(r"\.timeout\d+$", b) !== nothing ||
                   match(r"\.memout\d+$", b) !== nothing
                    rm(f)
                end
            end
            visdir = _cfg[].proofs * "vis/"
            if isdir(visdir)
                rm.(filter(f -> any(endswith(f, e) for e in (".lad", ".dot")), readdir(visdir; join=true)))
            end
            return
        elseif _cfg[].inst !== nothing && _cfg[].subprocess
            trimnalyseandcie(_cfg[].inst); return
        elseif _cfg[].inst !== nothing
            run_instance_full(_cfg[].inst); return
        elseif (_cfg[].solve || _cfg[].resolv) && !_cfg[].allgraphs
            j = findfirst(x -> x ∉ argflags && !isdir(x) && is_instance_name(x), args)
            if j !== nothing
                run_instance_full(args[j]); return
            end
        end
        list = _cfg[].allgraphs ? allgraphinstances() :
               _cfg[].instfile !== nothing ? instancesfromfile(_cfg[].instfile) :
               getinstancesfromdir(_cfg[].proofs)
        n = length(list)
        println("%Running ", n, " instances on ", Threads.nthreads(), " thread(s)")
        println("%OOM limit: ", _cfg[].maxinstmem_gb, " GB per subprocess, minfreemem: ", _cfg[].minfreemem ÷ 1024^3, " GB")
        done    = Threads.Atomic{Int}(0)
        t_start = time()
        monitor_active = Threads.Atomic{Bool}(true)
        # Independent OOM monitor: scans all trimnalyser.jl subprocesses every 10s and kills OOM ones.
        # Runs on :interactive thread so worker saturation can't starve it.
        Threads.@spawn :interactive begin
            # ── Registered process types ──────────────────────────────────────────────
            # Three now, each (match, extract-instance). Add a type here rather than
            # bolting another branch onto the loop below.
            #
            # The solver is matched on its FULL PATH, not basename(). For a lad-* config
            # basename is the three-character string "lad", and `occursin("lad", cmdline)`
            # matches any command line containing it anywhere — /scratch/arthur/ladbench/…,
            # ~/ladveri/… — so the monitor could kill unrelated processes. A full path is
            # what we actually launched, and per-revision Glasgow binaries
            # (glasgow_subgraph_solver_39ca857) match it just as well.
            solver_bin  = solverconfig().binary
            # Glasgow: `--prove <proofs><instance>`      basename IS the instance
            # LAD:     `-P <proofs><instance>.pbp`       basename carries an extension
            # LAD was previously scanned for --prove, which it never emits (solver.jl:237),
            # so every LAD OOM got inst_name "?" — appending to a junk "<proofs>?.err" and,
            # because of the `inst_name == "?"` guard, never writing a .memoutNNN sentinel.
            # LAD memouts were re-solved from scratch on every subsequent run.
            solver_flag = solverconfig().kind == "lad" ? "-P" : "--prove"
            # Strip only KNOWN suffixes: an instance name is not guaranteed dot-free, so
            # splitext could truncate one. Longest first — ".smol.opb" before ".opb".
            _sufs = (smol_pbp, smol_opb, pbp, opb)
            function strip_suffix(b)
                for sfx in _sufs
                    endswith(b, sfx) && return b[1:end - length(sfx)]
                end
                return b
            end
            function inst_after(cmdargs, flag)
                i = findfirst(==(flag), cmdargs)
                (i === nothing || i >= length(cmdargs)) && return "?"
                b = strip_suffix(basename(cmdargs[i + 1]))
                isempty(b) ? "?" : String(b)
            end
            function inst_from_opb(cmdargs)      # veripb -e <elab> <opb> <pbp>
                i = findfirst(a -> endswith(a, opb), cmdargs)
                i === nothing && return "?"
                b = strip_suffix(basename(cmdargs[i]))
                isempty(b) ? "?" : String(b)
            end
            while monitor_active[]
                sleep(10)
                try
                    for entry in readdir("/proc")
                        pid_str = entry
                        all(isdigit, pid_str) || continue
                        pid = parse(Int, pid_str)
                        pid == getpid() && continue  # skip parent process
                        cmdline_path = "/proc/$pid_str/cmdline"
                        isfile(cmdline_path) || continue
                        cmdline = read(cmdline_path, String)
                        is_trimmer = occursin("trimnalyser.jl", cmdline)
                        is_solver  = !is_trimmer && occursin(solver_bin, cmdline)
                        # veripb is neither self-limiting nor otherwise bounded: it is a
                        # native binary that grows with the proof and nothing stopped it.
                        # cake is deliberately absent — CakeML preallocates a fixed heap
                        # (see cake_heap_mb in output.jl) and exits with "heap space
                        # exhausted" rather than growing, so it cannot OOM the node.
                        is_veripb  = !is_trimmer && !is_solver && occursin(veripbpath, cmdline)
                        (is_trimmer || is_solver || is_veripb) || continue
                        # Extract instance name from cmdline (args are \0-separated)
                        cmdargs = split(cmdline, '\0')
                        stage = is_trimmer ? "trim" : is_solver ? "solve" : "verif"
                        inst_name = if is_trimmer
                            idx = findfirst(is_instance_name, cmdargs)
                            idx !== nothing ? String(cmdargs[idx]) : "?"
                        elseif is_solver
                            inst_after(cmdargs, solver_flag)
                        else
                            inst_from_opb(cmdargs)
                        end
                        rss = process_rss_gb(pid)
                        rss == 0.0 && continue
                        if rss > _cfg[].maxinstmem_gb
                            try
                                run(`kill -9 $pid`)
                                msg = "OOM KILL $inst_name ($stage, pid=$pid): $(round(rss; digits=1)) GB > $(_cfg[].maxinstmem_gb) GB"
                                printstyled("  $msg\n"; color=:red)
                                # Record OOM kill in .err file. The "OOM at <n>G" prefix is
                                # load-bearing — was_oom_killed (pipeline.jl) greps it — so
                                # the stage goes after it, never before.
                                try
                                    open(_cfg[].proofs*inst_name*".err", "a") do f
                                        println(f, "OOM at $(round(rss; digits=1))G (limit $(_cfg[].maxinstmem_gb)G, stage $stage)")
                                    end
                                    inst_name == "?" || touch(memout_sentinel(inst_name))
                                catch
                                    # Ignore errors writing .err file (may not have permissions)
                                end
                            catch e
                                printstyled("  OOM KILL FAILED $inst_name (pid=$pid): $(round(rss; digits=1)) GB - $(sprint(showerror, e))\n"; color=:magenta)
                            end
                        elseif rss > _cfg[].maxinstmem_gb * 0.9
                            printstyled("  MEM WATCH $inst_name ($stage, pid=$pid): $(round(rss; digits=1)) GB / $(_cfg[].maxinstmem_gb) GB\n"; color=:yellow)
                        end
                    end
                catch e
                    # /proc scan can race with process exit — ignore errors
                end
            end
        end
        # Each trim subprocess is trim-only (GC-isolated Julia). Solve/verif/resolv run in orchestrator thread.
        # "subprocess" flag distinguishes trim-only subprocesses from interactive invocations.
        subargs = filter(a -> a in Set(["resolv","clit","render","profile","no-supplementals","keepraw","overwrite"]) ||
                              startswith(a, "config=") ||   # else the subprocess resolves a different proofs dir
                              startswith(a, "stnopl=") ||
                              startswith(a, "tt=") ||
                              startswith(a, "maxmem=") || startswith(a, "minmem="), args)
        push!(subargs, "subprocess")
        # The proofs directory is a bare positional, so the whitelist above cannot carry it.
        # Forward the RESOLVED value rather than re-filtering args: parse_config! picks it up
        # with the same `findfirst(isdir)` rule, and this way the child cannot land on a
        # different directory than the parent no matter how the arg was written (or omitted).
        # Without it the child falls back to `defaultproofs`, finds no .pbp, and reports
        # "no conclusion (truncated proof)" for every UNSAT instance of the run.
        push!(subargs, _cfg[].proofs)
        script = "bin/trimnalyser.jl"
        # Pre-scan for .timeoutNNN sentinels so we can skip without spawning subprocesses
        timeout_cache = Dict{String,Int}()
        memout_cache  = Dict{String,Int}()
        if isdir(_cfg[].proofs)
            for fname in readdir(_cfg[].proofs)
                m = match(r"^(.+)\.timeout(\d+)$", fname)
                if m !== nothing
                    inst = String(m.captures[1])
                    t    = parse(Int, m.captures[2])
                    timeout_cache[inst] = max(get(timeout_cache, inst, 0), t)
                end
                m = match(r"^(.+)\.memout(\d+)$", fname)
                if m !== nothing
                    inst = String(m.captures[1])
                    g    = parse(Int, m.captures[2])
                    memout_cache[inst] = max(get(memout_cache, inst, 0), g)
                end
            end
            isempty(timeout_cache) || println("%Skipping $(length(timeout_cache)) previously timed-out instance(s)")
            isempty(memout_cache)  || println("%Skipping $(length(memout_cache)) previously OOM-killed instance(s)")
        end
        wall = @elapsed Threads.@threads :greedy for ins in list
            try
                # Fast pre-checks — avoid spawning unnecessary subprocesses
                spawn = _cfg[].overwrite ||
                    (!isfile(_cfg[].proofs * ins * ".done") &&
                     !isfile(_cfg[].proofs * ins * ".sat")  &&
                     get(timeout_cache, ins, 0) < _cfg[].solvertimeout &&
                     get(memout_cache, ins, 0)  < _cfg[].maxinstmem_gb)
                if spawn
                    run_instance_batch(ins, subargs, script)
                end # if spawn
            catch e
                msg = sprint(showerror, e, catch_backtrace())
                printstyled("  ERROR $ins: $msg\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, msg) end
            end
            d = Threads.atomic_add!(done, 1) + 1
            if d % 100 == 0 || d == n
                elapsed = time() - t_start
                rate    = d / elapsed * 60
                eta     = rate > 0 ? (n - d) / rate : Inf
                printstyled("\n\n\n[", d, "/", n, "] ",
                        round(rate; digits=1), " inst/min  ETA ",
                        round(Int, eta), "min\n\n"; color=:magenta)
            end
        end
        monitor_active[] = false  # stop the OOM monitor
        n_empty = 0
        for f in readdir(_cfg[].proofs; join=true)
            endswith(f, ".err") && filesize(f) == 0 && (rm(f); n_empty += 1)
        end
        n_empty > 0 && println("%Removed $n_empty empty .err file(s)")
        println("%Wall time: ", round(wall; digits=1), "s")
    end

        # ── Stale-sysimage guard ──────────────────────────────────────────────────────
        # Every path in TrimAnalyser.jl and output.jl is `const X = get(ENV, "VAR", default)`,
        # evaluated at MODULE LOAD — which, under --sysimage, means when the sysimage was
        # BUILT, not when the run starts. Exporting GLASGOW_SUBGRAPH_SOLVER_39ca857 and then
        # launching against a sysimage built without it silently runs the baked value, and
        # nothing in the output says so: the nine-column grid would quietly measure one
        # binary nine times, which is the exact failure scripts/cluster_env.sh exists to
        # prevent. Verified with a sentinel: the env is ignored, the baked value wins.
        #
        # So: compare each baked constant against the environment as it is NOW, and refuse
        # to start on a mismatch. Cheap, and it converts an invisible wrong result into a
        # loud one-line failure with the fix in it.
    function check_sysimage_env()
        stale = String[]
        chk(var, baked) = (v = get(ENV, var, ""); !isempty(v) && v != baked &&
                           push!(stale, "  $var\n    env:   $v\n    baked: $baked"))
        chk("TRIMNALYSER_GRAPHS", SIPgraphpath)
        chk("TRIMNALYSER_LOGS",   logroot)
        chk("TRIMNALYSER_BASE",   abspath_base)
        chk("GLASGOW_SUBGRAPH_SOLVER", sipsolverpath)
        chk("LAD_SOLVER",         ladsolverpath)
        chk("VERIPB",             veripbpath)
        chk("CAKE_PB",            cakepbpath)
        chk("CAKE_PB_ISO",        cakeisopath)
        # Per-revision Glasgow pins: every GLASGOW_SUBGRAPH_SOLVER_<rev> that is exported
        # must be the binary some configuration actually resolved to.
        bins = Set(c.binary for c in values(SOLVER_CONFIGS))
        for (k, v) in ENV
            startswith(k, "GLASGOW_SUBGRAPH_SOLVER_") || continue
            v in bins || push!(stale, "  $k\n    env:   $v\n    baked: (no configuration resolves to it)")
        end
        isempty(stale) && return
        printstyled("\nSTALE SYSIMAGE — the environment and trimnalyser.so disagree:\n";
                    color=:red, bold=true)
        for m in stale; printstyled(m, "\n"; color=:red); end
        printstyled("""
These paths are baked into the sysimage at build time. Rebuild it with the same
environment, or run with `nosys`:

    source scripts/cluster_env.sh && julia --project=. build_sysimage.jl

""", color=:yellow)
        exit(2) end

    function main(args=ARGS)
        parse_config!(args)
        haskey(ENV, "TRIMNALYSER_SYSIMAGE") && check_sysimage_env()
        # SIGTERM handler only in subprocess mode: exits with 124 so the outer timeout command can detect it.
        # Interactive mode uses normal Julia signal handling.
        if _cfg[].subprocess
            ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Base.SIGTERM, @cfunction(handle_timeout, Cvoid, (Cint,)))
        end
        if _cfg[].subprocess
            # Subprocess mode: spawned by the orchestrator batch loop for trim-only work.
            # Output goes directly to the inherited stdout (parent's pipe → parent's tee → terminal + logfile).
            _run_main(args)
        elseif haskey(ENV, "TRIMNALYSER_EXTERNAL_TEE")
            # The ./trimnalyser wrapper already pipes stdout+stderr through `tee -a output.log`.
            # Keep fd 1 untouched: the internal pipe below is a deadlock source (a Julia-task
            # tee can be starved by the scheduler, the 64 KB pipe then fills and a blocking
            # write on fd 1 wedges the libuv event loop, leaving every wait(proc) hung).
            println("\n% run started ", Base.Libc.strftime("%Y-%m-%d %H:%M:%S", time()))
            flush(stdout)
            _run_main(args)
        else
            logfile = open(joinpath(abspath_base, "output.log"), "a")
            println(logfile, "\n% run started ", Base.Libc.strftime("%Y-%m-%d %H:%M:%S", time()))
            flush(logfile)
            orig_out = Base.stdout
            orig_err = Base.stderr
            rd, wr = redirect_stdout()  # redirects stdout fd to a pipe; returns (read_end, write_end)
            redirect_stderr(wr)         # stderr goes to the same pipe
            # drain pipe on a dedicated interactive thread so it never competes with compute threads for scheduling.
            # @async would deadlock: if all compute threads block on pipe writes the async task can never run.
            tee_task = Threads.@spawn :interactive while !eof(rd)
                data = readavailable(rd)
                write(orig_out, data)
                flush(orig_out)
                write(logfile, data)
                flush(logfile)
            end
            try
                _run_main(args)
            finally
                redirect_stdout(orig_out)
                redirect_stderr(orig_err)
                close(wr)       # signals EOF to the tee task
                wait(tee_task)  # drain remaining data before closing
                close(logfile)
            end
        end
    end
