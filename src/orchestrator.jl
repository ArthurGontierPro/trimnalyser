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

        # Enumerates all (pattern, target) instance names from the benchmark graph directories.
        # Filters pairs where both graphs have <= maxnodes nodes and pattern_size <= target_size.
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
                n !== nothing && n <= _cfg[].maxnodes && (sizes[id] = n)
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
                    n !== nothing && n <= _cfg[].maxnodes && (pat_sizes[id] = n)
                end
                for id in tar_ids
                    n = ladnodes(dir*"targets/target$id")
                    n !== nothing && n <= _cfg[].maxnodes && (tar_sizes[id] = n)
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
                if nt !== nothing && nt <= _cfg[].maxnodes
                    pat_ids = sort!([parse(Int, f[8:end]) for f in readdir(dir) if startswith(f,"pattern")])
                    for id in pat_ids
                        np = ladnodes(dir*"pattern$id")
                        np !== nothing && np <= nt && push!(list, "pr15_p$id")
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
                    n !== nothing && n <= _cfg[].maxnodes && (pat_sizes[id] = n)
                end
                for id in tar_ids
                    n = ladnodes(dir*"targets/target$id")
                    n !== nothing && n <= _cfg[].maxnodes && (tar_sizes[id] = n)
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
                    (np > _cfg[].maxnodes || nt > _cfg[].maxnodes) && continue
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
                    (np > _cfg[].maxnodes || nt > _cfg[].maxnodes) && continue
                    np <= nt && push!(list, "sf_$subdir")
                end
            end
        end

        # si: si/<group>/<instance>/pattern + .../target (three-level nesting)
        # Instance names encode as si__<group>__<inst> (double-underscore separator;
        # group and instance names only contain single underscores so this is unambiguous)
        let dir = SIPgraphpath * "si/"
            if isdir(dir)
                for group in sort!(filter(d -> isdir(dir*d), readdir(dir)))
                    gpath = dir * group * "/"
                    for inst in sort!(filter(d -> isdir(gpath*d), readdir(gpath)))
                        ipath = gpath * inst * "/"
                        pat = ipath * "pattern"; tar = ipath * "target"
                        isfile(pat) && isfile(tar) || continue
                        np = ladnodes(pat); nt = ladnodes(tar)
                        (np === nothing || nt === nothing) && continue
                        (np > _cfg[].maxnodes || nt > _cfg[].maxnodes) && continue
                        np <= nt && push!(list, "si__$(group)__$(inst)")
                    end
                end
            end
        end

        _cfg[].rand && _shuffle!(list)
        println("%Generated ", length(list), " instances from benchmark graphs (maxnodes=", _cfg[].maxnodes, ")")
        return list end

    function _run_main(args)
        if _cfg[].pack   packdots();   return
        elseif _cfg[].render renderdots(); return
        elseif _cfg[].atable plotresultstable(); return
        elseif _cfg[].clean
            rm.(filter(f -> endswith(f, ".out") || endswith(f, ".err"), readdir(_cfg[].proofs; join=true)))
            visdir = _cfg[].proofs * "vis/"
            if isdir(visdir)
                rm.(filter(f -> any(endswith(f, e) for e in (".lad", ".dot")), readdir(visdir; join=true)))
            end
            return
        elseif _cfg[].inst !== nothing
            trimnalyseandcie(_cfg[].inst); return
        elseif (_cfg[].solve || _cfg[].resolv) && !_cfg[].allgraphs
            # proof files don't exist yet: find instance name by known prefix in args
            j = findfirst(x -> x ∉ argflags && !isdir(x) && is_instance_name(x), args)
            if j !== nothing
                trimnalyseandcie(args[j]); return
            end
        end
        list = _cfg[].allgraphs ? allgraphinstances() : getinstancesfromdir(_cfg[].proofs)
        n = length(list)
        println("%Running ", n, " instances on ", Threads.nthreads(), " thread(s)")
        println("%OOM limit: ", _cfg[].maxinstmem_gb, " GB per subprocess, minfreemem: ", _cfg[].minfreemem ÷ 1024^3, " GB")
        done    = Threads.Atomic{Int}(0)
        t_start = time()
        monitor_active = Threads.Atomic{Bool}(true)
        # Independent OOM monitor: scans all trimnalyser.jl subprocesses every 10s and kills OOM ones.
        # Runs on :interactive thread so worker saturation can't starve it.
        Threads.@spawn :interactive begin
            script_name = "trimnalyser.jl"
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
                        occursin(script_name, cmdline) || continue
                        # Extract instance name from cmdline (args are \0-separated)
                        cmdargs = split(cmdline, '\0')
                        instance = findfirst(is_instance_name, cmdargs)
                        inst_name = instance !== nothing ? cmdargs[instance] : "?"
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
        # Each instance runs in its own julia subprocess (single-threaded) so GC heaps are isolated:
        # no stop-the-world across instances. The outer @threads loop provides parallelism.
        # maxparse= and allgraphs are stripped: subprocess handles one instance, not a batch.
        # Directory paths are stripped and proofs_abs is passed explicitly (absolute, cluster-safe).
        subargs = filter(a -> a in Set(["solve","resolv","verif","render","profile","no-supplementals"]) ||
                              startswith(a, "st=") || startswith(a, "tt=") ||
                              startswith(a, "maxmem=") || startswith(a, "minmem="), args)
        script = "bin/trimnalyser.jl"
        wall = @elapsed Threads.@threads :greedy for ins in list
            try
                while available_memory() < _cfg[].minfreemem
                    sleep(5)
                end
                # -t1,1: 1 worker thread + 1 GC thread. Without ,1, Julia 1.10+ spawns
                # nCPUs/4 GC threads by default — 48 per subprocess on a 192-core machine,
                # which adds up to ~18k OS threads with 192 concurrent subprocesses.
                # addenv overrides JULIA_NUM_THREADS in case -t doesn't fully shadow it.
                subout = _cfg[].proofs * ins * ".subout"
                julia_flags = isfile(_sysimage) ? `--sysimage $_sysimage -t1,1` : `-t1,1`
                proc = run(pipeline(addenv(`timeout $(_cfg[].trimtimeout) julia $julia_flags $script $ins $subargs`,
                                          "JULIA_NUM_THREADS" => "1",
                                          "OPENBLAS_NUM_THREADS" => "1",
                                          "MKL_NUM_THREADS" => "1"),
                                   stdout=subout, stderr=subout),
                           wait=false)
                wait(proc)
                # timeout command exits with 124 (SIGTERM) or 137 (SIGKILL) on timeout
                # OOM killer also sends SIGKILL (exit 137), check subout for "OOM" to distinguish
                if proc.exitcode == 124 || proc.exitcode == 137
                    # Check if it was OOM or timeout
                    oom_killed = false
                    if isfile(subout)
                        out_preview = read(subout, String)
                        oom_killed = occursin("OOM", out_preview) || occursin("memory", lowercase(out_preview))
                    end
                    msg = oom_killed ? "OOM killed (exceeded $(_cfg[].maxinstmem_gb) GB)" : "Timeout after $(_cfg[].trimtimeout)s"
                    printstyled("  $ins: $msg\n"; color=:red)
                    open(_cfg[].proofs*ins*".err", "a") do f; println(f, msg) end
                end
                if isfile(subout)
                    out = read(subout, String)
                    !isempty(out) && (print(out); flush(stdout))
                    rm(subout)
                end
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
        println("%Wall time: ", round(wall; digits=1), "s")
    end

    function main(args=ARGS)
        parse_config!(args)
        # Only install SIGTERM handler when running as subprocess (inst is set)
        if _cfg[].inst !== nothing
            ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Base.SIGTERM, @cfunction(handle_timeout, Cvoid, (Cint,)))
        end
        if _cfg[].inst !== nothing
            # Subprocess mode: this process was spawned by the batch loop to handle one instance.
            # Output goes directly to the inherited stdout (parent's pipe → parent's tee → terminal + logfile).
            # No second tee needed — adding one would double-buffer and prevent output from flushing.
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
