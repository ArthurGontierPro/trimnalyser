# ══ Entry point ══════════════════════════════════════════════════════════════════════════
# ══ Signal Handling ═══════════════════════════════════════════════════════════════════════════
    const _sysimage = joinpath(@__DIR__, "..", "trimnalyser.so")
    # Clean exit on timeout to prevent signal handler corruption of @inbounds code
    function handle_timeout(sig::Cint)
        println(stderr, "Timeout signal received (signal $sig), exiting cleanly...")
        exit(124)  # Standard timeout exit code
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
        if _cfg[].rand shuffle!(list)
        elseif _cfg[].sort_by_size sort!(list, by = x -> inssize(x)) end
        println("%Found ", length(list), " instances in ", proofs_dir)
        return list end

        # Enumerates all (pattern, target) instance names from the benchmark graph directories.
        # Filters pairs where both graphs have <= maxnodes nodes and pattern_size <= target_size.
    function allgraphinstances()
        list = String[]
        mkpath(_cfg[].proofs)
        for (dir, pre, fext, fmt) in [
                (SIPgraphpath*"LV/",                    "g",  "",     (p,t) -> "LVg$(p)g$(t)"),
                (SIPgraphpath*"biochemicalReactions/",  "",   ".txt", (p,t) -> "bio$(p)$(t)") ]
            isdir(dir) || continue
            files = readdir(dir)
            # strip prefix and extension to get the numeric identifier
            ids = [f[length(pre)+1 : end-length(fext)] for f in files
                   if startswith(f, pre) && endswith(f, fext) && !isdir(dir*f)]
            # read node counts, filter by maxnodes
            sizes = Dict{String,Int}()
            for id in ids
                n = ladnodes(dir * pre * id * fext)
                n !== nothing && n <= _cfg[].maxnodes && (sizes[id] = n)
            end
            valid = collect(keys(sizes))
            _cfg[].rand ? shuffle!(valid) : sort!(valid)
            for p in valid, t in valid
                p == t && continue
                sizes[p] > sizes[t] && continue  # only embed smaller into larger
                push!(list, fmt(p, t))
            end
        end
        _cfg[].rand && shuffle!(list)
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
            # proof files don't exist yet: find instance name by bio/LV prefix in args
            j = findfirst(x -> x ∉ argflags && !isdir(x) &&
                               (startswith(x,"LV") || startswith(x,"bio")), args)
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
                        instance = findfirst(a -> startswith(a, "LV") || startswith(a, "bio"), cmdargs)
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
            println(logfile, "\n% run started ", Dates.now())
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
