# ══ Entry point ══════════════════════════════════════════════════════════════════════════
# ══ Signal Handling ═══════════════════════════════════════════════════════════════════════════
    const _sysimage = joinpath(@__DIR__, "..", "trimnalyser.so")
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

        _cfg[].rand && _shuffle!(list)
        println("%Generated ", length(list), " instances from benchmark graphs (minnodes=", _cfg[].minnodes, " maxnodes=", _cfg[].maxnodes, ")")
        return list end

    function run_trim_subprocess(ins, subargs, script)
        while available_memory() < _cfg[].minfreemem
            sleep(5)
        end
        subout = _cfg[].proofs * ins * ".subout"
        suberr = _cfg[].proofs * ins * ".suberr"
        use_sysimage = isfile(_sysimage)
        julia_flags = use_sysimage ? `--sysimage $_sysimage -t1,1` : `-t1,1`
        sub_env = ["JULIA_NUM_THREADS" => "1", "OPENBLAS_NUM_THREADS" => "1", "MKL_NUM_THREADS" => "1"]
        use_sysimage && push!(sub_env, "TRIMNALYSER_SYSIMAGE" => "1")
        proc = run(pipeline(addenv(`timeout $(_cfg[].trimtimeout) julia $julia_flags $script $ins $subargs`, sub_env...),
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
            return :timeout
        elseif exitcode == 137
            msg = "OOM killed (exceeded $(_cfg[].maxinstmem_gb) GB)"
            printstyled("  $ins: $msg\n"; color=:red)
            open(_cfg[].proofs*ins*".err", "a") do f; println(f, msg) end
            return :memout
        else
            exitcode != 0 && printstyled("  $ins: trim failed (exit $exitcode)\n"; color=:red)
            return :failed
        end end

    function run_resolv_loop(ins, use_subprocess::Bool, subargs=nothing, script=nothing)
        cur_pat = _cfg[].proofs * "vis/" * ins * ".core.pat.lad"
        cur_tar = _cfg[].proofs * "vis/" * ins * ".core.tar.lad"
        patfile, tarfile = parsegraphfiles(ins)
        prev_np = parse(Int, readline(patfile))
        prev_nt = parse(Int, readline(tarfile))
        outfile = _cfg[].proofs * ins * ".out"
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
            tryrm(_cfg[].proofs*core_ins*".out")
            tryrm(_cfg[].proofs*core_ins*".err")
            t = @elapsed (ok, timed_out) = runsipsolver(core_ins, cur_pat, cur_tar)
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
                smol_vt,smol_vs,full_vt,full_vs = _cfg[].verif ? verify(core_ins) : (-1,:missing,-1,:missing)
                writeout_verif(core_ins, smol_vt, full_vt)
                printverif(core_ins, smol_vt, smol_vs, full_vt, full_vs)
            else
                printabline(core_ins)
                parse_time,trim_time,write_time,cone_stats,coremsg = trimnalyse(core_ins; mode=Grim())
                smol_vt,smol_vs,full_vt,full_vs = _cfg[].verif ? verify(core_ins) : (-1,:missing,-1,:missing)
                printabline2(core_ins, parse_time, trim_time, write_time, cone_stats)
                !isempty(coremsg) && println(coremsg)
                writeout_verif(core_ins, smol_vt, full_vt)
                printverif(core_ins, smol_vt, smol_vs, full_vt, full_vs)
            end
            if !_cfg[].keepraw
                tryrm(_cfg[].proofs * core_ins * pbp)
                tryrm(_cfg[].proofs * core_ins * opb)
                if _cfg[].verif && smol_vs === :verified
                    tryrm(_cfg[].proofs * core_ins * smol_pbp)
                    tryrm(_cfg[].proofs * core_ins * smol_opb)
                end
            end
            cur_pat = _cfg[].proofs * "vis/" * core_ins * ".core.pat.lad"
            cur_tar = _cfg[].proofs * "vis/" * core_ins * ".core.tar.lad"
        end end

    function run_instance_batch(ins, subargs, script)
        oom_killed, mem_info = was_oom_killed(ins)
        if !_cfg[].overwrite && oom_killed
            mem_str = isempty(mem_info) ? "" : " at $mem_info"
            printstyled("  $ins previously OOM killed$mem_str — skipping\n"; color=:yellow); return
        end
        tryrm(_cfg[].proofs*ins*".out")
        tryrm(_cfg[].proofs*ins*".err")
        if _cfg[].solve
            patfile, tarfile = parsegraphfiles(ins)
            if patfile === nothing
                printstyled("  solve: cannot parse graph paths for $ins\n"; color=:red); return
            end
            if !_cfg[].overwrite && isfile(_cfg[].proofs*ins*opb) && !isempty(pbpconclusion(ins))
                printstyled("  $ins proof exists — skipping solve\n"; color=:blue)
            else
                t = @elapsed (ok, timed_out) = runsipsolver(ins, patfile, tarfile)
                if !ok
                    out_content = isfile(_cfg[].proofs*ins*".out") ? read(_cfg[].proofs*ins*".out", String) : ""
                    if occursin("SATISFIABLE", out_content) && !occursin("UNSATISFIABLE", out_content)
                        touch(_cfg[].proofs * ins * ".sat")
                        tryrm(_cfg[].proofs * ins * pbp)
                        tryrm(_cfg[].proofs * ins * opb)
                        printstyled("  $ins SAT — skipping\n"; color=:yellow)
                    elseif timed_out
                        touch(_cfg[].proofs * ins * ".timeout$(_cfg[].solvertimeout)")
                        tryrm(_cfg[].proofs * ins * pbp)
                        tryrm(_cfg[].proofs * ins * opb)
                        printstyled("  $ins solver timed out ($(round(t;digits=1))s)\n"; color=:red)
                    else
                        printstyled("  $ins solve failed ($(round(t;digits=1))s)\n"; color=:red)
                    end
                    return
                end
                printstyled("  $ins solved $(round(t;digits=1))s\n"; color=:cyan)
            end
        end
        let c = pbpconclusion(ins)
            if c == "SAT" || c == "NONE"
                touch(_cfg[].proofs * ins * ".sat")
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins $c — skipping\n"; color=:yellow); return
            end
            if isempty(c)
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins: no conclusion (truncated proof) — skipping\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, "proof truncated: no conclusion") end
                return
            end
        end
        let sz = (isfile(_cfg[].proofs*ins*opb) ? filesize(_cfg[].proofs*ins*opb) : 0) +
                    (isfile(_cfg[].proofs*ins*pbp) ? filesize(_cfg[].proofs*ins*pbp) : 0)
            if sz > 50 * 1024^3
                printstyled("  $ins too large ($(round(sz/1024^3; digits=1)) GB) — skipping\n"; color=:yellow)
                return
            end
        end
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
        smol_vt,smol_vs,full_vt,full_vs = _cfg[].verif ? verify(ins) : (-1,:missing,-1,:missing)
        writeout_verif(ins, smol_vt, full_vt)
        printverif(ins, smol_vt, smol_vs, full_vt, full_vs)
        if !_cfg[].keepraw
            tryrm(_cfg[].proofs * ins * pbp)
            tryrm(_cfg[].proofs * ins * opb)
        end
        grim_verif_ok = smol_vs === :verified
        if !_cfg[].keepraw && grim_verif_ok
            tryrm(_cfg[].proofs * ins * smol_pbp)
            tryrm(_cfg[].proofs * ins * smol_opb)
            touch(_cfg[].proofs * ins * ".done")
        end
        _cfg[].resolv && run_resolv_loop(ins, true, subargs, script) end

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
        oom_killed, mem_info = was_oom_killed(ins)
        if !_cfg[].overwrite && oom_killed
            mem_str = isempty(mem_info) ? "" : " at $mem_info"
            printstyled("  $ins previously OOM killed$mem_str — skipping\n"; color=:yellow); return
        end
        tryrm(_cfg[].proofs*ins*".out")
        tryrm(_cfg[].proofs*ins*".err")
        if _cfg[].solve
            patfile, tarfile = parsegraphfiles(ins)
            if patfile === nothing
                printstyled("  solve: cannot parse graph paths for $ins\n"; color=:red); return
            end
            if !_cfg[].overwrite && isfile(_cfg[].proofs*ins*opb) && !isempty(pbpconclusion(ins))
                printstyled("  $ins proof exists — skipping solve\n"; color=:blue)
            else
                t = @elapsed (ok, timed_out) = runsipsolver(ins, patfile, tarfile)
                if !ok
                    out_content = isfile(_cfg[].proofs*ins*".out") ? read(_cfg[].proofs*ins*".out", String) : ""
                    if occursin("SATISFIABLE", out_content) && !occursin("UNSATISFIABLE", out_content)
                        touch(_cfg[].proofs * ins * ".sat")
                        tryrm(_cfg[].proofs * ins * pbp)
                        tryrm(_cfg[].proofs * ins * opb)
                        printstyled("  $ins SAT — skipping\n"; color=:yellow)
                    elseif timed_out
                        touch(_cfg[].proofs * ins * ".timeout$(_cfg[].solvertimeout)")
                        tryrm(_cfg[].proofs * ins * pbp)
                        tryrm(_cfg[].proofs * ins * opb)
                        printstyled("  $ins solver timed out ($(round(t;digits=1))s)\n"; color=:red)
                    else
                        printstyled("  $ins solve failed ($(round(t;digits=1))s)\n"; color=:red)
                    end
                    return
                end
                printstyled("  $ins solved $(round(t;digits=1))s\n"; color=:cyan)
            end
        end
        let c = pbpconclusion(ins)
            if c == "SAT" || c == "NONE"
                touch(_cfg[].proofs * ins * ".sat")
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins $c — skipping\n"; color=:yellow); return
            end
            if isempty(c)
                tryrm(_cfg[].proofs * ins * pbp)
                tryrm(_cfg[].proofs * ins * opb)
                printstyled("  $ins: no conclusion (truncated proof) — skipping\n"; color=:red)
                open(_cfg[].proofs*ins*".err", "a") do f; println(f, "proof truncated: no conclusion") end
                return
            end
        end
        let sz = (isfile(_cfg[].proofs*ins*opb) ? filesize(_cfg[].proofs*ins*opb) : 0) +
                    (isfile(_cfg[].proofs*ins*pbp) ? filesize(_cfg[].proofs*ins*pbp) : 0)
            if sz > 50 * 1024^3
                printstyled("  $ins too large ($(round(sz/1024^3; digits=1)) GB) — skipping\n"; color=:yellow)
                return
            end
        end
        grim_verif_ok = false
        if !_cfg[].nonorm
            printabline(ins)
            parse_time,trim_time,write_time,cone_stats,coremsg = trimnalyse(ins; mode=Grim())
            smol_vt,smol_vs,full_vt,full_vs = _cfg[].verif ? verify(ins) : (-1,:missing,-1,:missing)
            printabline2(ins,parse_time,trim_time,write_time,cone_stats)
            !isempty(coremsg) && println(coremsg)
            writeout_verif(ins,smol_vt,full_vt)
            printverif(ins, smol_vt, smol_vs, full_vt, full_vs)
            grim_verif_ok = smol_vs === :verified
            _cfg[].resolv && run_resolv_loop(ins, false)
        end
        if _cfg[].clit
            printabline(ins)
            parse_time,trim_time,write_time,cone_stats,_ = trimnalyse(ins; mode=Clit())
            smol_vt,smol_vs,full_vt,full_vs = _cfg[].verif ? verify(ins) : (-1,:missing,-1,:missing)
            printabline2(ins,parse_time,trim_time,write_time,cone_stats)
            writeout_verif(ins,smol_vt,full_vt)
            printverif(ins, smol_vt, smol_vs, full_vt, full_vs)
        end
        if !_cfg[].keepraw && grim_verif_ok
            tryrm(_cfg[].proofs * ins * pbp)
            tryrm(_cfg[].proofs * ins * opb)
            tryrm(_cfg[].proofs * ins * smol_pbp)
            tryrm(_cfg[].proofs * ins * smol_opb)
            touch(_cfg[].proofs * ins * ".done")
        end end

    function _run_main(args)
        if _cfg[].pack   packdots();   return
        elseif _cfg[].render renderdots(); return
        elseif _cfg[].atable plotresultstable(); return
        elseif _cfg[].clean
            for f in readdir(_cfg[].proofs; join=true)
                b = basename(f)
                if endswith(b, ".out") || endswith(b, ".err") ||
                   endswith(b, ".done") || endswith(b, ".sat") ||
                   match(r"\.timeout\d+$", b) !== nothing
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
            solver_name = basename(sipsolverpath)
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
                        is_solver  = !is_trimmer && occursin(solver_name, cmdline)
                        (is_trimmer || is_solver) || continue
                        # Extract instance name from cmdline (args are \0-separated)
                        cmdargs = split(cmdline, '\0')
                        inst_name = if is_trimmer
                            idx = findfirst(is_instance_name, cmdargs)
                            idx !== nothing ? cmdargs[idx] : "?"
                        else
                            prove_idx = findfirst(==("--prove"), cmdargs)
                            prove_idx !== nothing && prove_idx < length(cmdargs) ?
                                basename(cmdargs[prove_idx + 1]) : "?"
                        end
                        rss = process_rss_gb(pid)
                        rss == 0.0 && continue
                        if rss > _cfg[].maxinstmem_gb
                            try
                                run(`kill -9 $pid`)
                                msg = "OOM KILL $inst_name (pid=$pid): $(round(rss; digits=1)) GB > $(_cfg[].maxinstmem_gb) GB"
                                printstyled("  $msg\n"; color=:red)
                                # Record OOM kill in .err file
                                try
                                    open(_cfg[].proofs*inst_name*".err", "a") do f
                                        println(f, "OOM at $(round(rss; digits=1))G (limit $(_cfg[].maxinstmem_gb)G)")
                                    end
                                catch
                                    # Ignore errors writing .err file (may not have permissions)
                                end
                            catch e
                                printstyled("  OOM KILL FAILED $inst_name (pid=$pid): $(round(rss; digits=1)) GB - $(sprint(showerror, e))\n"; color=:magenta)
                            end
                        elseif rss > _cfg[].maxinstmem_gb * 0.9
                            printstyled("  MEM WATCH $inst_name (pid=$pid): $(round(rss; digits=1)) GB / $(_cfg[].maxinstmem_gb) GB\n"; color=:yellow)
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
                              startswith(a, "tt=") ||
                              startswith(a, "maxmem=") || startswith(a, "minmem="), args)
        push!(subargs, "subprocess")
        script = "bin/trimnalyser.jl"
        # Pre-scan for .timeoutNNN sentinels so we can skip without spawning subprocesses
        timeout_cache = Dict{String,Int}()
        if isdir(_cfg[].proofs)
            for fname in readdir(_cfg[].proofs)
                m = match(r"^(.+)\.timeout(\d+)$", fname)
                if m !== nothing
                    inst = String(m.captures[1])
                    t    = parse(Int, m.captures[2])
                    timeout_cache[inst] = max(get(timeout_cache, inst, 0), t)
                end
            end
            isempty(timeout_cache) || println("%Skipping $(length(timeout_cache)) previously timed-out instance(s)")
        end
        wall = @elapsed Threads.@threads :greedy for ins in list
            try
                # Fast pre-checks — avoid spawning unnecessary subprocesses
                spawn = _cfg[].overwrite ||
                    (!isfile(_cfg[].proofs * ins * ".done") &&
                     !isfile(_cfg[].proofs * ins * ".sat")  &&
                     get(timeout_cache, ins, 0) < _cfg[].solvertimeout)
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

    function main(args=ARGS)
        parse_config!(args)
        # SIGTERM handler only in subprocess mode: exits with 124 so the outer timeout command can detect it.
        # Interactive mode uses normal Julia signal handling.
        if _cfg[].subprocess
            ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Base.SIGTERM, @cfunction(handle_timeout, Cvoid, (Cint,)))
        end
        if _cfg[].subprocess
            # Subprocess mode: spawned by the orchestrator batch loop for trim-only work.
            # Output goes directly to the inherited stdout (parent's pipe → parent's tee → terminal + logfile).
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
