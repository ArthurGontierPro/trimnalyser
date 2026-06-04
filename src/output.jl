# ══ Output & display ══════════════════════════════════════════════════════════════════════════
    function writeout_parse(ins, t1, nbopb, n_pbp, inp_lits, inp_vars, prefix)
        opb_sz = filesize(_cfg[].proofs*ins*opb)
        pbp_sz = filesize(_cfg[].proofs*ins*pbp)
        open(_cfg[].proofs*ins*".out", "a") do f
            println(f, "inp OPB SIZE ",   opb_sz)
            println(f, "inp PBP SIZE ",   pbp_sz)
            println(f, "inp SIZE ",       opb_sz + pbp_sz)
            println(f, "inp LIT ",        inp_lits)
            println(f, "inp VAR ",        inp_vars)
            println(f, prefix, " PARSE TIME ", t1)
            println(f, prefix, " OPB NBEQ ",  nbopb)
            println(f, prefix, " PBP NBEQ ",  n_pbp)
            println(f, prefix, " NBEQ ",      nbopb + n_pbp)
        end end

    function writeout_trim(ins, t2, cone, nbopb, prefix)
        cone_opb = sum(cone[1:nbopb])
        cone_pbp = sum(cone[nbopb+1:end])
        open(_cfg[].proofs*ins*".out", "a") do f
            println(f, prefix, " TRIM TIME ", t2)
            println(f, prefix, " OPB CONE ",  cone_opb)
            println(f, prefix, " PBP CONE ",  cone_pbp)
            println(f, prefix, " CONE ",      cone_opb + cone_pbp)
        end end

    function conelits_stats(sys, cone, conelits)
        lits_cone = 0; lits_smol = 0
        used_vars = falses(length(sys.var_ptr) - 1)
        for i in eachindex(cone)
            cone[i] || continue
            nl = length(eqrange(sys, i))
            lits_cone += nl
            lits_smol += haskey(conelits, i) ? length(conelits[i]) : nl
            haskey(conelits, i) && for v in conelits[i]; used_vars[v] = true; end
        end
        return (lits_cone=lits_cone, lits_smol=lits_smol, vars_used=sum(used_vars), vars_total=length(used_vars)) end

    function writeout_conelits(ins, sys, cone, conelits, prefix)
        s = conelits_stats(sys, cone, conelits)
        open(_cfg[].proofs*ins*".out", "a") do f
            println(f, prefix, " CONE LIT ", s.lits_cone)
            println(f, prefix, " SMOL LIT ", s.lits_smol)
            println(f, prefix, " CONE VAR ", s.vars_used)
        end end

    function count_step_types(systemlink::SystemLink, cone::Vector{Bool}, nbopb::Int)
        n_rup = n_pol = n_red = n_ia = n_other = 0
        @inbounds for i in nbopb+1:length(cone)
            cone[i] || continue
            k = systemlink.idx[i - nbopb]
            if k == -1 || k == 0
                n_rup += 1
            elseif k == -4
                n_red += 1
            elseif k > 0
                rt = systemlink.data[systemlink.ptr[k]]
                if rt == -2;     n_pol += 1
                elseif rt == -3; n_ia  += 1
                else             n_other += 1 end
            else
                n_other += 1
            end
        end
        (rup=n_rup, pol=n_pol, red=n_red, ia=n_ia, other=n_other) end

    function writeout_step_types(ins, counts, prefix)
        open(_cfg[].proofs*ins*".out", "a") do f
            println(f, prefix, " CONE RUP ",  counts.rup)
            println(f, prefix, " CONE POL ",  counts.pol)
            println(f, prefix, " CONE RED ",  counts.red)
            println(f, prefix, " CONE IA ",   counts.ia)
            counts.other > 0 && println(f, prefix, " CONE OTHER ", counts.other)
        end end

    function compute_cone_depth(cone::Vector{Bool}, systemlink::SystemLink, nbopb::Int)
        n = length(cone)
        depth = zeros(Int32, n)
        n_pbp = 0; d_sum = Int64(0); d_max = Int32(0)
        for i in nbopb+1:n
            cone[i] || continue
            n_pbp += 1
            link = systemlink[i - nbopb]
            d = zero(Int32)
            for j in eachindex(link)
                t = link[j]
                t > 0 || continue
                j < length(link) && link[j+1] in (-2, -3) && continue  # skip POL scalars
                cone[t] && (d = max(d, depth[t]))
            end
            depth[i] = d + Int32(1)
            d_sum += depth[i]
            depth[i] > d_max && (d_max = depth[i])
        end
        mean = n_pbp > 0 ? d_sum / n_pbp : 0.0
        (max_depth=Int(d_max), mean_depth=mean) end

    function writeout_cone_depth(ins, stats, prefix)
        open(_cfg[].proofs*ins*".out", "a") do f
            println(f, prefix, " CONE DEPTH MAX ",  stats.max_depth)
            println(f, prefix, " CONE DEPTH MEAN ", round(stats.mean_depth; digits=2))
        end end

    function writeout_write(ins, t1, t2, t3, prefix)
        open(_cfg[].proofs*ins*".out", "a") do f
            println(f, prefix, " WRITE TIME ", t3)
            println(f, prefix, " TIME ",       t1+t2+t3)
            println(f, prefix, " OPB SIZE ",   filesize(_cfg[].proofs*ins*smol_opb))
            println(f, prefix, " PBP SIZE ",   filesize(_cfg[].proofs*ins*smol_pbp))
            println(f, prefix, " SIZE ",       filesize(_cfg[].proofs*ins*smol_opb) + filesize(_cfg[].proofs*ins*smol_pbp))
        end end

    function writeout_verif(ins, smol_verif_time, full_verif_time)
        smol_verif_time < 0 && full_verif_time < 0 && return
        open(_cfg[].proofs*ins*".out", "a") do f
            smol_verif_time >= 0 && println(f, "veri smol TIME ", smol_verif_time)
            full_verif_time >= 0 && println(f, "veri TIME ",      full_verif_time)
        end end

    const veripbpath = get(ENV, "VERIPB",
        _cluster ? "/scratch/arthur/veripb" : "/home/arthur_gla/veriPB/trim/VeriPB/target/release/veripb")

    function verify(ins)
        smol_verif_time = full_verif_time = 0
        isfile(veripbpath) || (printstyled("  veripb not found at $veripbpath — skipping verif\n"; color=:yellow); return smol_verif_time,full_verif_time)
        ins2 = _cfg[].proofs*ins
        ins3 = ins2*".smolverif"
        ins4 = ins2*".verif"
        ins31 = ins3*".out"; ins32 = ins3*".err"
        ins41 = ins4*".out"; ins42 = ins4*".err"
        tryrm(ins31); tryrm(ins32)
        smol_verif_time = @elapsed try run(pipeline(ignorestatus(`timeout $(_cfg[].trimtimeout) $veripbpath $(ins2*smol_opb) $(ins2*smol_pbp)`),stdout=ins31,stderr=ins32)) catch e println("\nerr ",ins32) end
        isfile(ins32) && isempty(strip(read(ins32,String))) && tryrm(ins32)
        tryrm(ins41); tryrm(ins42)
        full_verif_time = @elapsed try run(pipeline(ignorestatus(`timeout $(_cfg[].trimtimeout) $veripbpath $ins2$opb $ins2$pbp`),stdout=ins41,stderr=ins42)) catch e println("\nerr ",ins42) end
        isfile(ins42) && isempty(strip(read(ins42,String))) && tryrm(ins42)
        return trunc(Int,smol_verif_time),trunc(Int,full_verif_time) end

    printgray(s)  = printstyled(s, color=:light_black)
    printyellow(s)= printstyled(s, color=:yellow)
    printred(s)   = printstyled(s, color=:red)
    printgreen(s) = printstyled(s, color=:green)
    printblue(s)  = printstyled(s, color=:blue)
    printcyan(s)  = printstyled(s, color=:cyan)
    function leftcarriage(c,s)
        carriage = string(c-length(s))
        return "\r\033["*carriage*"G"*s end

        # True when output can't use cursor positioning: either multiple threads in the same process
        # (would interleave), or a single-threaded subprocess handling one instance in a batch run.
    par() = Threads.nthreads() > 1 || _cfg[].inst !== nothing

    function printabline(f)
        par() && return  # parallel: skip placeholder, full line printed atomically in printabline2
        printgray("         &          &          &          &      (                   ) &      & ")
        printyellow(f)
        printgray(" \\\\\\hline")
        printcyan(leftcarriage(9, prettybytes(filesize(_cfg[].proofs*f*opb))))
        printcyan(leftcarriage(20,prettybytes(filesize(_cfg[].proofs*f*pbp)))) end

    function printabline2(f, parse_time, trim_time, write_time, smol_verif_time, full_verif_time, cone_stats=nothing)
        if par()
            pb(file) = isfile(file) ? prettybytes(filesize(file)) : "?"
            cone_s = cone_stats !== nothing ? " $(cone_stats.lits_smol)/$(cone_stats.lits_cone) $(cone_stats.vars_used)/$(cone_stats.vars_total)" : ""
            println(rpad(pb(_cfg[].proofs*f*opb),8),           " & ", rpad(pb(_cfg[].proofs*f*pbp),9),
                    " & ", rpad(pb(_cfg[].proofs*f*smol_opb),9)," & ", rpad(pb(_cfg[].proofs*f*smol_pbp),9),
                    " & ", rpad(parse_time+trim_time+write_time+max(0,smol_verif_time),5),
                    " (", rpad(parse_time,4), rpad(trim_time,4), rpad(write_time,4), rpad(smol_verif_time,5), ")",
                    " & ", rpad(full_verif_time,5), " & ", f, " \\\\\\hline%", cone_s)
            flush(stdout)
            return
        end
        printgreen(leftcarriage(31,prettybytes(filesize(_cfg[].proofs*f*smol_opb))))
        printgreen(leftcarriage(42,prettybytes(filesize(_cfg[].proofs*f*smol_pbp))))
        printgreen(leftcarriage(49,string(parse_time+trim_time+write_time+max(0,smol_verif_time))))
        printblue(leftcarriage(54,string(parse_time)))
        printgreen(leftcarriage(59,string(trim_time)))
        printblue(leftcarriage(64,string(write_time)))
        printcyan(leftcarriage(69,string(smol_verif_time)))
        printcyan(leftcarriage(78,string(full_verif_time)))
        println() end

    function printconestat(cone, cone_stats)
        par() && return  # cursor-based stat doesn't compose with parallel output
        printgray("\r\033[99G% "*string(sum(cone))*"/"*string(length(cone))*" "
                                *string(cone_stats.vars_used)*"/"*string(cone_stats.vars_total)*"\n") end

    function prettybytes(b)
        if b>=10^9
            return string(trunc(Int,b/(10^9))," GB")
        elseif b>=10^6
            return string(trunc(Int,b/(10^6))," MB")
        elseif b>=10^3
            return string(trunc(Int,b/(10^3))," KB")
        else
            return  string(trunc(Int,b)," B")
        end end

# ══ Statistics ══════════════════════════════════════════════════════════════════════════
    # Column index constants for the results table
        const T_FILE       =  1
        const T_GRIM_TIME  =  2
        const T_GRIM_OSIZ  =  3
        const T_GRIM_PSIZ  =  4
        const T_GRIM_SIZE  =  5
        const T_VERI_STIME =  6
        const T_VERI_TIME  =  7
        const T_VERI_OSIZ  =  8
        const T_VERI_PSIZ  =  9
        const T_VERI_SIZE  = 10
        const T_BRIM_TIME  = 11
        const T_BRIM_OSIZ  = 12
        const T_BRIM_PSIZ  = 13
        const T_BRIM_SIZE  = 14
        const T_GRIM_PTIME = 15  # parse time
        const T_GRIM_TTIME = 16  # trim (getcone) time
        const T_GRIM_WTIME = 17  # write time
        const T_GRIM_OCONE = 18  # OPB constraints in cone
        const T_GRIM_PCONE = 19  # proof steps in cone
        const T_GRIM_CONE  = 20  # total constraints in cone
        const T_GRIM_ONBEQ = 21  # total OPB constraints (input)
        const T_GRIM_PNBEQ = 22  # total proof steps (input)
        const T_INP_OSIZ   = 23  # input OPB file size
        const T_INP_PSIZ   = 24  # input PBP file size
        const T_INP_SIZE   = 25  # input total file size
        const T_GRIM_NBEQ  = 26  # total equations (OPB + PBP)
        const T_GBFS_TTIME = 27  # BFS trim (getcone) time
        const T_GBFS_OCONE = 28  # BFS OPB constraints in cone
        const T_GBFS_PCONE = 29  # BFS proof steps in cone
        const T_GBFS_CONE  = 30  # BFS total constraints in cone
        const T_GRIM_CLIT  = 31  # total literals in grim cone constraints
        const T_GRIM_SLIT  = 32  # total literals kept after conelits weakening (grim)
        const T_GBFS_CLIT  = 33  # total literals in gbfs cone constraints
        const T_GBFS_SLIT  = 34  # total literals kept after conelits weakening (gbfs)
        const T_INP_LIT    = 35  # total literals in all input constraints
        const T_INP_VAR    = 36  # total variables in input
        const T_GRIM_CVAR  = 37  # distinct variables in union of grim conelits
        const T_GBFS_CVAR  = 38  # distinct variables in union of gbfs conelits
        const T_GCLT_TTIME = 39  # clit trim (getcone) time
        const T_GCLT_OCONE = 40  # clit OPB constraints in cone
        const T_GCLT_PCONE = 41  # clit proof steps in cone
        const T_GCLT_CONE  = 42  # clit total constraints in cone
        const T_GCLT_CLIT  = 43  # total literals in clit cone constraints
        const T_GCLT_SLIT  = 44  # total literals kept after conelits weakening (clit)
        const T_GCLT_CVAR  = 45  # distinct variables in union of clit conelits
        const T_NCOLS      = 45

        # Counts how many resolv iterations ran for ins by checking coreN .out files.
    function countresolveiters(ins)
        n = 0
        while isfile(_cfg[].proofs * ins * ".core$(n+1)" * ".out"); n += 1 end
        return n end

        # Parses solver-written fields from the top of ins.out (appended by runsipsolver).
    function parsesolverstats(ins)
        outfile = _cfg[].proofs * ins * ".out"
        isfile(outfile) || return nothing
        content = read(outfile, String)
        gi(r) = (m = match(r, content)) !== nothing ? parse(Int, m.captures[1]) : nothing
        gs(r) = (m = match(r, content)) !== nothing ? m.captures[1] : nothing
        (pat_vertices = gi(r"pattern_vertices\s*=\s*(\d+)"),
         tar_vertices = gi(r"target_vertices\s*=\s*(\d+)"),
         runtime_ms   = gi(r"runtime\s*=\s*(\d+)"),
         status       = gs(r"status\s*=\s*(\w+)")) end

    function plotresultstable()
        list = filter(x -> ext(x)==".out" && !endswith(x,".smolverif.out") && !endswith(x,".verif.out"), readdir(_cfg[].proofs))
        list = onlyname.(list)
        table = Vector{Vector{Any}}()
        for file in list
            res = Any[file; fill(nothing, T_NCOLS - 1)]
            for line in eachline(_cfg[].proofs*file*".out")
                    if occursin("grim PARSE TIME ", line)    res[T_GRIM_PTIME]= tryparse(Int, split(line)[end])
                elseif occursin("grim TRIM TIME ", line)     res[T_GRIM_TTIME]= tryparse(Int, split(line)[end])
                elseif occursin("grim WRITE TIME ", line)    res[T_GRIM_WTIME]= tryparse(Int, split(line)[end])
                elseif occursin("grim TIME ", line)          res[T_GRIM_TIME] = tryparse(Int, split(line)[end])
                elseif occursin("grim OPB SIZE ", line)      res[T_GRIM_OSIZ] = tryparse(Int, split(line)[end])
                elseif occursin("grim PBP SIZE ", line)      res[T_GRIM_PSIZ] = tryparse(Int, split(line)[end])
                elseif occursin("grim SIZE ", line)          res[T_GRIM_SIZE] = tryparse(Int, split(line)[end])
                elseif occursin("grim OPB CONE ", line)      res[T_GRIM_OCONE]= tryparse(Int, split(line)[end])
                elseif occursin("grim PBP CONE ", line)      res[T_GRIM_PCONE]= tryparse(Int, split(line)[end])
                elseif occursin("grim CONE LIT ", line)      res[T_GRIM_CLIT] = tryparse(Int, split(line)[end])
                elseif occursin("grim SMOL LIT ", line)      res[T_GRIM_SLIT] = tryparse(Int, split(line)[end])
                elseif occursin("grim CONE VAR ", line)      res[T_GRIM_CVAR] = tryparse(Int, split(line)[end])
                elseif occursin("grim CONE ", line)          res[T_GRIM_CONE] = tryparse(Int, split(line)[end])
                elseif occursin("grim OPB NBEQ ", line)      res[T_GRIM_ONBEQ]= tryparse(Int, split(line)[end])
                elseif occursin("grim PBP NBEQ ", line)      res[T_GRIM_PNBEQ]= tryparse(Int, split(line)[end])
                elseif occursin("inp OPB SIZE ", line)       res[T_INP_OSIZ]  = tryparse(Int, split(line)[end])
                elseif occursin("inp PBP SIZE ", line)       res[T_INP_PSIZ]  = tryparse(Int, split(line)[end])
                elseif occursin("inp SIZE ", line)           res[T_INP_SIZE]  = tryparse(Int, split(line)[end])
                elseif occursin("inp LIT ", line)            res[T_INP_LIT]   = tryparse(Int, split(line)[end])
                elseif occursin("inp VAR ", line)            res[T_INP_VAR]   = tryparse(Int, split(line)[end])
                elseif occursin("grim NBEQ ", line)          res[T_GRIM_NBEQ] = tryparse(Int, split(line)[end])
                elseif occursin("gclt TRIM TIME ", line)     res[T_GCLT_TTIME]= tryparse(Int, split(line)[end])
                elseif occursin("gclt OPB CONE ", line)      res[T_GCLT_OCONE]= tryparse(Int, split(line)[end])
                elseif occursin("gclt PBP CONE ", line)      res[T_GCLT_PCONE]= tryparse(Int, split(line)[end])
                elseif occursin("gclt CONE LIT ", line)      res[T_GCLT_CLIT] = tryparse(Int, split(line)[end])
                elseif occursin("gclt SMOL LIT ", line)      res[T_GCLT_SLIT] = tryparse(Int, split(line)[end])
                elseif occursin("gclt CONE VAR ", line)      res[T_GCLT_CVAR] = tryparse(Int, split(line)[end])
                elseif occursin("gclt CONE ", line)          res[T_GCLT_CONE] = tryparse(Int, split(line)[end])
                elseif occursin("gbfs TRIM TIME ", line)     res[T_GBFS_TTIME]= tryparse(Int, split(line)[end])
                elseif occursin("gbfs OPB CONE ", line)      res[T_GBFS_OCONE]= tryparse(Int, split(line)[end])
                elseif occursin("gbfs PBP CONE ", line)      res[T_GBFS_PCONE]= tryparse(Int, split(line)[end])
                elseif occursin("gbfs CONE LIT ", line)      res[T_GBFS_CLIT] = tryparse(Int, split(line)[end])
                elseif occursin("gbfs SMOL LIT ", line)      res[T_GBFS_SLIT] = tryparse(Int, split(line)[end])
                elseif occursin("gbfs CONE VAR ", line)      res[T_GBFS_CVAR] = tryparse(Int, split(line)[end])
                elseif occursin("gbfs CONE ", line)          res[T_GBFS_CONE] = tryparse(Int, split(line)[end])
                elseif occursin("veri smol TIME ", line)     res[T_VERI_STIME]= tryparse(Int, split(line)[end])
                elseif occursin("veri TIME ", line)          res[T_VERI_TIME] = tryparse(Int, split(line)[end])
                elseif occursin("veri OPB SIZE ", line)      res[T_VERI_OSIZ] = tryparse(Int, split(line)[end])
                elseif occursin("veri PBP SIZE ", line)      res[T_VERI_PSIZ] = tryparse(Int, split(line)[end])
                elseif occursin("veri SIZE ", line)          res[T_VERI_SIZE] = tryparse(Int, split(line)[end])
                elseif occursin("brim TIME ", line)          res[T_BRIM_TIME] = tryparse(Int, split(line)[end])
                elseif occursin("brim OPB SIZE ", line)      res[T_BRIM_OSIZ] = tryparse(Int, split(line)[end])
                elseif occursin("brim PBP SIZE ", line)      res[T_BRIM_PSIZ] = tryparse(Int, split(line)[end])
                elseif occursin("brim SIZE ", line)          res[T_BRIM_SIZE] = tryparse(Int, split(line)[end])
                end
            end
            push!(table,res)
        end
        # printpoints2Dlog(table, T_GRIM_CONE, T_GRIM_NBEQ, "grim CONE", "grim NBEQ")
        printratios(table)
        # resolv iteration counts — inferred from coreN .out file existence
        iters = [countresolveiters(t[1]) for t in table if !occursin(".core", t[1])]
        if any(i -> i > 0, iters)
            println("── Resolv iterations ──")
            println("  max   : ", maximum(iters))
            println("  mean  : ", round(sum(iters) / length(iters); digits=2))
            maxiters = maximum(iters)
            for k in 0:maxiters
                c = count(==(k), iters)
                c > 0 && println("  iter=", k, " : ", c, " instance(s)")
            end
            maxins = [t[1] for t in table if !occursin(".core", t[1]) && countresolveiters(t[1]) == maxiters]
            println("  max instances: ", join(maxins, ", "))
            println()
        end
        walltxt = _cfg[].proofs * "wall.txt"
        if isfile(walltxt)
            wall = parse(Float64, readline(walltxt))
            println("── Wall time ──")
            println("  ", round(wall; digits=1), "s")
            println()
        end end

        # 1-shifted geometric mean of a column: exp(mean(log(v + 1))) - 1.
    function col_sgm(table, col)
        valid = [t[col] for t in table if t[col] !== nothing && t[col] > 0]
        isempty(valid) && return nothing
        exp(sum(log(v + 1) for v in valid) / length(valid)) - 1 end

        # Ratio of the 1-shifted geomeans of two columns, restricted to rows where both are present.
        # This gives "ratio of averages" rather than "average of ratios".
    function ros(table, col_num, col_den)
        valid = [t for t in table if t[col_num] !== nothing && t[col_den] !== nothing && t[col_num] > 0 && t[col_den] > 0]
        isempty(valid) && return nothing
        sgm_num = exp(sum(log(t[col_num] + 1) for t in valid) / length(valid)) - 1
        sgm_den = exp(sum(log(t[col_den] + 1) for t in valid) / length(valid)) - 1
        sgm_den == 0 && return nothing
        sgm_num / sgm_den end

    function printratios(table)
        # "X times smaller, Y% of original" — for reductions where bigger ratio = better
        fmt_r(x) = x === nothing ? "N/A" :
            "$(rpad(string(round(x; digits=1))*"x smaller,", 14)) $(round(100/x; digits=1))% of original"
        # plain percentage — for the trim-time fraction (already a ratio ≤ 1)
        fmt_p(x) = x === nothing ? "N/A" : "$(round(100*x; digits=1))% of total time"
        n = count(t -> t[T_GRIM_SIZE] !== nothing, table)
        println("\n── Proof reduction (ratio of 1-shifted geomeans, n=", n, ") ──")
        println("  size        : ", fmt_r(ros(table, T_INP_SIZE,  T_GRIM_SIZE)))
        println("  constraints : ", fmt_r(ros(table, T_GRIM_NBEQ, T_GRIM_CONE)))
        println("  literals    : ", fmt_r(ros(table, T_GRIM_CLIT, T_GRIM_SLIT)))
        println("  variables   : ", fmt_r(ros(table, T_INP_VAR,   T_GRIM_CVAR)))
        # println("  trim time   : ", fmt_p(ros(table, T_GRIM_TTIME, T_GRIM_TIME)))
        any(t -> t[T_GCLT_SLIT] !== nothing, table) && begin
            # println("  clit lits   : ", fmt_r(ros(table, T_GRIM_SLIT, T_GCLT_SLIT)), "  vs grim")
            # println("  clit vars   : ", fmt_r(ros(table, T_GRIM_CVAR, T_GCLT_CVAR)), "  vs grim")
        end
        any(t -> t[T_VERI_TIME] !== nothing, table) && begin
            println("  verif speed : ", fmt_r(ros(table, T_VERI_TIME, T_VERI_STIME)))
        end
        println() end

    function maxvalue(table,a)
        m = 0
        for t in table
            if t[a]!==nothing
                if t[a]>m m=t[a] end
            end
        end
        return m end

    function printpoints2D(table,a,b,xlbl="",ylbl="")
        prefixtikz(maxvalue(table,a),maxvalue(table,b),xlbl,ylbl)
        for t in table
            if t[a]!==nothing &&t[b]!==nothing
                print(t[a],'/',t[b],',')
            end
        end
        println()
        postfixtikz() end

    function printpoints2Dlog(table,a,b,xlbl="",ylbl="")
        xlbl*=" (log)"; ylbl*=" (log)"
        prefixtikz(logsmooth(maxvalue(table,a)),logsmooth(maxvalue(table,b)),xlbl,ylbl)
        for t in table
            if t[a]!==nothing &&t[b]!==nothing
                print(logsmooth(t[a]),'/',logsmooth(t[b]),',')
            end
        end
        println()
        postfixtikz() end

    function logsmooth(a) round(max(log10(a),0),sigdigits = 3) end
    function prefixtikz(mx=10,my=10,xlbl="",ylbl="")
        m = max(mx,my)
        steps = Int(m÷10 + 1)
        m = Int((m÷10)*10 + 10) # to make a 10 integer scale
        mx = my = m
        xsteps = steps
        ysteps = steps
        scale = 1#/max(xsteps,ysteps)
        xx = 1/xsteps
        yy = 1/ysteps    # mx = Int(ceil(mx))
        println("\\begin{tikzpicture}[scale=$scale, x=$xx cm, y=$yy cm] \n\\def\\xmin{0} \\def\\xmax{$mx} \\def\\ymin{0} \\def\\ymax{$my} \n\\draw[style=help lines, ystep=$ysteps, xstep=$xsteps] (\\xmin,\\ymin) grid (\\xmax,\\ymax); \n\\draw[->] (\\xmin,\\ymin) -- (\\xmax,\\ymin) node[above left] {$xlbl}; \n\\draw[->] (\\xmin,\\ymin) -- (\\xmin,\\ymax) node[below right] {$ylbl}; \n\\foreach \\x in {0,$xsteps,...,\\xmax} \\node at (\\x, \\ymin) [below] {\\x}; \n\\foreach \\y in {0,$ysteps,...,\\xmax} \\node at (\\xmin,\\y) [left] {\\y}; \n\\foreach \\x/\\y in{") end

    function postfixtikz()
        println("}\\draw (\\x,\\y) node[noeudver] {};\n\\end{tikzpicture}") end
