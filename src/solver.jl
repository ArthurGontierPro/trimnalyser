# ══ Solver & UNSAT core ═════════════════════════════════════════════════════════════════
    #
        # Returns (node_count, path) for a LAD file, or nothing if unreadable.
    function ladnodes(path)
        isfile(path) || return nothing
        n = tryparse(Int, readline(path))
        n === nothing && return nothing
        return n end

        # Returns (pattern_file_path, target_file_path) for an instance name.
        # For ins.coreN, returns the LAD files written by the previous iteration.
        # For original instances, returns the benchmark graph files.
        # Instance name conventions:
        #   LVg<p>g<t>        — LV family
        #   bio<p><t>         — biochemicalReactions (3-char ids)
        #   cviu11_p<N>_t<M>  — images-CVIU11
        #   pr15_p<N>         — images-PR15 (single shared target)
        #   mesh11_p<N>_t<M>  — meshes-CVIU11
        #   ph_<base>         — phase (base = filename without -pattern/-target)
        #   sf_<dir>          — scalefree (dir = A.01 etc.)
        #   si__<group>__<inst> — si (double-underscore separates levels)
    function parsegraphfiles(ins)
        m = match(r"^(.+)\.core(\d+)$", ins)
        if m !== nothing
            base, n = m.captures[1], parse(Int, m.captures[2])
            prev_ins = n == 1 ? base : base * ".core$(n-1)"
            return _cfg[].proofs * "vis/" * prev_ins * ".core.pat.lad",
                   _cfg[].proofs * "vis/" * prev_ins * ".core.tar.lad"
        end
        if startswith(ins, "bio")
            pat = ins[4:end-3]
            tar = ins[end-2:end]
            base = SIPgraphpath * "biochemicalReactions/"
            return base * pat * ".txt", base * tar * ".txt"
        elseif startswith(ins, "LV")
            i   = findlast('g', ins)
            pat = ins[4:i-1]
            tar = ins[i+1:end]
            base = SIPgraphpath * "LV/"
            return base * "g" * pat, base * "g" * tar
        elseif startswith(ins, "cviu11_p")
            m2 = match(r"^cviu11_p(\d+)_t(\d+)$", ins)
            m2 === nothing && return nothing, nothing
            base = SIPgraphpath * "images-CVIU11/"
            return base * "patterns/pattern" * m2[1], base * "targets/target" * m2[2]
        elseif startswith(ins, "pr15_p")
            m2 = match(r"^pr15_p(\d+)$", ins)
            m2 === nothing && return nothing, nothing
            base = SIPgraphpath * "images-PR15/"
            return base * "pattern" * m2[1], base * "target"
        elseif startswith(ins, "mesh11_p")
            m2 = match(r"^mesh11_p(\d+)_t(\d+)$", ins)
            m2 === nothing && return nothing, nothing
            base = SIPgraphpath * "meshes-CVIU11/"
            return base * "patterns/pattern" * m2[1], base * "targets/target" * m2[2]
        elseif startswith(ins, "ph_")
            base_name = ins[4:end]
            base = SIPgraphpath * "phase/"
            return base * base_name * "-pattern", base * base_name * "-target"
        elseif startswith(ins, "sf_")
            dir = ins[4:end]
            base = SIPgraphpath * "scalefree/" * dir * "/"
            return base * "pattern", base * "target"
        elseif startswith(ins, "si__")
            parts = split(ins[5:end], "__"; limit=2)
            length(parts) != 2 && return nothing, nothing
            group, inst = parts[1], parts[2]
            base = SIPgraphpath * "si/" * group * "/" * inst * "/"
            return base * "pattern", base * "target"
        end
        return nothing, nothing end

        # Reads a LAD format graph: first line = n, then n lines of "degree nb1 nb2 ..." (0-indexed neighbors).
        # Returns 1-indexed adjacency list Vector{Vector{Int}}.
    function readlad(path)
        adj = Vector{Vector{Int}}()
        open(path, "r") do f
            n = parse(Int, readline(f))
            for _ in 1:n
                parts = filter(!isempty, split(readline(f)))
                push!(adj, [parse(Int, p) + 1 for p in parts[2:end]])
            end
        end
        return adj end

        # Parses "x{p}_{t}" (0-indexed) → (p+1, t+1). Returns nothing if name doesn't match.
    function parsevarname(name)
        length(name) < 3 && return nothing
        name[1] == 'x'   || return nothing
        u = findfirst('_', name)
        u === nothing     && return nothing
        p = tryparse(Int, name[2:u-1])
        t = tryparse(Int, name[u+1:end])
        (p === nothing || t === nothing) && return nothing
        return p + 1, t + 1 end

        # Extracts core pattern nodes P and target nodes T from OPB cone constraints,
        # restricted to variables kept by conelits (weakened-out variables are excluded).
    function corenodes(sys::PBSystem, cone::Vector{Bool}, varmap_inv::Vector{String},
                       conelits::Dict{Int,Set{Int}}, nbopb::Int)
        P = Set{Int}(); T = Set{Int}()
        for i in 1:nbopb
            cone[i] || continue
            clit = get(conelits, i, nothing)
            for k in eqrange(sys, i)
                v = Int(sys.vars[k])
                clit !== nothing && v ∉ clit && continue
                pt = parsevarname(varmap_inv[v])
                pt === nothing && continue
                push!(P, pt[1]); push!(T, pt[2])
            end
        end
        return sort!(collect(P)), sort!(collect(T)) end

        # Writes a DOT file for a graph. core_set nodes are green, others red.
        # LAD format stores each edge once (asymmetric) — symmetrise before writing.
        # For graphs with many nodes, node labels are hidden to reduce clutter.
    function writedot(path, adj, core_set)
        n = length(adj)
        large = n > 300
        edges = Set{Tuple{Int,Int}}()
        for i in 1:n, j in adj[i]
            push!(edges, (min(i,j), max(i,j)))
        end
        open(path, "w") do f
            println(f, "graph G {")
            println(f, "  layout=circo; overlap=false; node [shape=circle, width=0.2, fixedsize=true];")
            for i in 1:n
                color = i in core_set ? "#44bb44" : "#cc4444"
                label = large ? "" : string(i)
                println(f, "  $i [label=\"$label\", style=filled, fillcolor=\"$color\", fontsize=7];")
            end
            for (i, j) in edges
                ec = (i in core_set && j in core_set) ? "#44bb44" : "#aaaaaa"
                println(f, "  $i -- $j [color=\"$ec\"];")
            end
            println(f, "}")
        end end

        # Writes a LAD file for the induced subgraph on core (sorted 1-indexed node list).
    function writecoreladfile(path, adj, core)
        core_set = Set(core)
        old2new  = Dict(v => i - 1 for (i, v) in enumerate(core))  # 0-indexed for LAD format
        open(path, "w") do f
            println(f, length(core))
            for v in core
                neighbors = [old2new[u] for u in adj[v] if u in core_set]
                println(f, length(neighbors), " ", join(neighbors, " "))
            end
        end end

        # Runs the Glasgow SIP solver on pat_lad/tar_lad, writing proof to proofs/out_prefix.{opb,pbp}.
        # Solver stdout/stderr are appended to out_prefix.{out,err} (tryrm clears them beforehand for the original instance).
        # Returns true if both output files were produced.
    function runsipsolver(out_prefix, pat_lad, tar_lad)
        isfile(sipsolverpath) || (printstyled("  solver not found: $sipsolverpath\n"; color=:red); return (false, false))
        errfile = _cfg[].proofs*out_prefix*".err"
        options = ["--no-clique-detection"]
        _cfg[].nosup && push!(options, "--no-supplementals")
        local exitcode = 0
        open(_cfg[].proofs*out_prefix*".out", "a") do fout
            open(errfile, "a") do ferr
                p = run(pipeline(
                    ignorestatus(`timeout $(_cfg[].solvertimeout) $sipsolverpath
                        --prove $(_cfg[].proofs*out_prefix) $options --format lad $pat_lad $tar_lad`),
                    stdout=fout, stderr=ferr))
                exitcode = p.exitcode
            end
        end
        exitcode in (124, 137) && return (false, true)
        if isfile(errfile)
            err = read(errfile, String)
            if !isempty(strip(err))
                printstyled("  $out_prefix solver stderr: $err"; color=:red)
            else
                tryrm(errfile)
            end
        end
        return (isfile(_cfg[].proofs*out_prefix*opb) && isfile(_cfg[].proofs*out_prefix*pbp), false) end

        # Runs the solver on the core LAD files produced by writeunsatcore, then trims the result.
        # Iterates until fixpoint (core node counts stop shrinking) or solver fails.
        # Instances are named ins.core1, ins.core2, ... ; LADs chain naturally from each trim.
    function resolvecore(ins)
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
            printabline(core_ins)
            parse_time,trim_time,write_time,cone_stats,coremsg = trimnalyse(core_ins; mode=Grim())
            smol_verif_time,full_verif_time = _cfg[].verif ? verify(core_ins) : (-1,-1)
            printabline2(core_ins, parse_time, trim_time, write_time, smol_verif_time, full_verif_time, cone_stats)
            !isempty(coremsg) && println(coremsg)
            writeout_verif(core_ins, smol_verif_time, full_verif_time)
            if !_cfg[].keepraw
                tryrm(_cfg[].proofs * core_ins * pbp)
                tryrm(_cfg[].proofs * core_ins * opb)
                if _cfg[].verif && verif_ok(core_ins)
                    tryrm(_cfg[].proofs * core_ins * smol_pbp)
                    tryrm(_cfg[].proofs * core_ins * smol_opb)
                end
            end
            cur_pat = _cfg[].proofs * "vis/" * core_ins * ".core.pat.lad"
            cur_tar = _cfg[].proofs * "vis/" * core_ins * ".core.tar.lad"
        end end

    function writeunsatcore(ins, sys::PBSystem, cone::Vector{Bool},
                            conelits::Dict{Int,Set{Int}}, varmap_inv::Vector{String}, nbopb::Int)
        patfile, tarfile = parsegraphfiles(ins)
        (patfile === nothing || !isfile(patfile) || !isfile(tarfile)) && return ""
        P, T = corenodes(sys, cone, varmap_inv, conelits, nbopb)
        isempty(P) && return ""
        adj_p = readlad(patfile)
        adj_t = readlad(tarfile)
        dir = _cfg[].proofs * "vis/"
        mkpath(dir)
        P_set = Set(P); T_set = Set(T)
        writedot(dir * ins * ".pat.dot",  adj_p, P_set)
        writedot(dir * ins * ".tar.dot",  adj_t, T_set)
        writecoreladfile(dir * ins * ".core.pat.lad", adj_p, P)
        writecoreladfile(dir * ins * ".core.tar.lad", adj_t, T)
        if _cfg[].render
            for (base, layout) in [(ins*".pat", "circo"), (ins*".tar", "neato")]
                dot = dir * base * ".dot"
                svg = dir * base * ".svg"
                try run(ignorestatus(`neato -Tsvg -K$layout -o$svg $dot`))
                catch;
                    # printstyled("  neato not found — install graphviz to render $svg\n"; color=:yellow)
                end
            end
        end
        return "  $ins core: $(length(P))/$(length(adj_p)) pat nodes, $(length(T))/$(length(adj_t)) tar nodes" end
