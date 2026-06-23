#!/usr/bin/env julia
# Quick terminal statistics from cluster_results.csv — stdlib only, no package deps.
# Usage: julia scripts/quick_stats.jl cluster_results.csv [output.txt]

using Statistics, Printf

struct TeeIO <: IO; a::IO; b::IO; end
Base.write(t::TeeIO, x::UInt8) = (write(t.a, x); write(t.b, x); 1)

sec(io, title) = println(io, "\n" * "="^70 * "\n " * title * "\n" * "="^70)
pct(n, tot)    = tot > 0 ? @sprintf("%.1f%%", 100n / tot) : "—"

function smry(data, unit="")
    isempty(data) && return "(no data)"
    @sprintf("mean %8.2f%s   median %8.2f%s   min %6.2f%s   max %6.2f%s",
        mean(data), unit, median(data), unit, minimum(data), unit, maximum(data), unit)
end

function countmap(v)
    d = Dict{eltype(v), Int}()
    for x in v; d[x] = get(d, x, 0) + 1; end
    d
end

# ── CSV parser (handles quoted fields containing commas) ──────────────────────

function csv_fields(line)
    fields = String[]; i = 1; n = length(line)
    while i <= n
        if i <= n && line[i] == '"'
            j = i + 1
            while j <= n && line[j] != '"'; j += 1; end
            push!(fields, line[i+1:j-1])
            i = j + 2
        else
            j = findnext(==(','), line, i)
            if j === nothing
                push!(fields, line[i:end]); break
            else
                push!(fields, line[i:j-1]); i = j + 1
            end
        end
    end
    fields
end

function read_csv(path)
    lines = readlines(path)
    isempty(lines) && error("empty CSV")
    header = [strip(h, '"') for h in split(lines[1], ',')]
    cols   = Dict(h => String[] for h in header)
    for line in @view lines[2:end]
        isempty(strip(line)) && continue
        fields = csv_fields(line)
        for (i, h) in enumerate(header)
            push!(cols[h], i <= length(fields) ? fields[i] : "")
        end
    end
    cols, max(0, length(lines) - 1)
end

numcol(cols, name) = Float64[x for x in
    (tryparse(Float64, v) for v in get(cols, name, String[])) if x !== nothing]

boolcol(cols, name) = [v == "true" for v in get(cols, name, String[])]

# ── Main ─────────────────────────────────────────────────────────────────────

function main()
    length(ARGS) < 1 && (println("Usage: julia quick_stats.jl <csv> [output.txt]"); exit(1))
    csv_file = ARGS[1]; out_file = length(ARGS) >= 2 ? ARGS[2] : "stats_summary.txt"
    isfile(csv_file) || (println("Error: $csv_file not found"); exit(1))

    println("Loading $csv_file...")
    cols, n = read_csv(csv_file)

    has_proof = boolcol(cols, "has_proof")
    # Glasgow writes status = true (SAT) / false (UNSAT); derive from status column
    status_col = get(cols, "status", String[])
    is_sat    = !isempty(status_col) ? [v == "true"  for v in status_col] : boolcol(cols, "is_sat")
    is_unsat  = !isempty(status_col) ? [v == "false" for v in status_col] : boolcol(cols, "is_unsat")
    has_error = boolcol(cols, "has_error")
    truncated = boolcol(cols, "proof_truncated")
    resolv_it = numcol(cols, "resolv_iterations")

    # proof-only row mask
    proof_idx = findall(has_proof)
    pcol(name) = numcol(Dict(name => get(cols, name, String[])[proof_idx]), name)

    open(out_file, "w") do f
        io = TeeIO(stdout, f)

        println(io, "Cluster Results Analysis — $csv_file")
        println(io, "="^70)

        # ── Overview ──────────────────────────────────────────────────────────
        sec(io, "OVERVIEW")
        println(io, @sprintf("Total instances:      %10d", n))
        for (v, label) in [(is_sat,"SAT"), (is_unsat,"UNSAT"), (has_proof,"With proof"),
                           (truncated,"Truncated"), (has_error,"Errors")]
            c = sum(v)
            println(io, @sprintf("%-22s %10d  (%s)", label * ":", c, pct(c, n)))
        end
        if !isempty(resolv_it)
            rc = sum(resolv_it .> 0)
            ri = sum(.!isempty.(get(cols, "resolv_stop_reason", String[])))  # invoked (incl. 0-iter)
            println(io, @sprintf("%-22s %10d  (%s)", "Resolv invoked:", ri, pct(ri, n)))
            println(io, @sprintf("%-22s %10d  (%s of invoked)", "Resolv ≥1 iter:", rc, pct(rc, ri)))
        end

        np = length(proof_idx)
        np == 0 && (println(io, "\nNo instances with proofs."); return)

        # ── Skip / error breakdown ────────────────────────────────────────────
        skip_vals = get(cols, "skip_reason", String[])[proof_idx]
        skip_vals = filter(!isempty, skip_vals)
        if !isempty(skip_vals)
            sec(io, "SKIP REASONS")
            for (reason, count) in sort(collect(countmap(skip_vals)); by=x -> -x[2])
                println(io, @sprintf("  %-35s %7d  (%s)", reason, count, pct(count, n)))
            end
        end

        # ── Timing ────────────────────────────────────────────────────────────
        sec(io, "TIMING  (n=$np instances with proofs)")
        for (label, col) in [("Parse Time","grim_parse_time"), ("Trim Time","grim_trim_time"),
                              ("Write Time","grim_write_time"), ("Total Time","grim_total_time")]
            data = pcol(col); isempty(data) && continue
            println(io, "\n  $label:")
            println(io, "    " * smry(data, "s"))
            println(io, @sprintf("    95th %%ile %8.2fs   std %8.2fs", quantile(data, 0.95), std(data)))
        end

        # ── Size / reduction ──────────────────────────────────────────────────
        sec(io, "SIZE & REDUCTION  (n=$np)")
        inp_sz = pcol("inp_total_size"); out_sz = pcol("grim_total_size")
        if !isempty(inp_sz) && !isempty(out_sz)
            println(io, @sprintf("  Total input %8.2f GB   Total output %8.2f GB   Reduction %.1f%%",
                sum(inp_sz)/1024^3, sum(out_sz)/1024^3, (1 - sum(out_sz)/sum(inp_sz))*100))
        end
        inp_eq = pcol("inp_total_nbeq"); out_eq = pcol("grim_total_cone")
        if !isempty(inp_eq) && !isempty(out_eq)
            r = [(a-b)/a for (a,b) in zip(inp_eq, out_eq) if a > 0]
            isempty(r) || println(io, @sprintf(
                "  Constraint reduction  mean %.1f%%   median %.1f%%   min %.1f%%   max %.1f%%",
                mean(r)*100, median(r)*100, minimum(r)*100, maximum(r)*100))
        end
        lit_in = pcol("grim_cone_literals"); lit_out = pcol("grim_smol_literals")
        if !isempty(lit_in) && !isempty(lit_out)
            r = [(a-b)/a for (a,b) in zip(lit_in, lit_out) if a > 0]
            isempty(r) || println(io, @sprintf(
                "  Literal reduction     mean %.1f%%   median %.1f%%   min %.1f%%   max %.1f%%",
                mean(r)*100, median(r)*100, minimum(r)*100, maximum(r)*100))
        end

        # ── Cone step types ───────────────────────────────────────────────────
        rup_data = pcol("grim_cone_rup")
        if !isempty(rup_data)
            sec(io, "CONE STEP TYPES  (n=$(length(rup_data)))")
            for (col, label) in [("grim_opb_cone","OPB"), ("grim_cone_rup","RUP"),
                                  ("grim_cone_pol","POL"), ("grim_cone_ia","IA"),
                                  ("grim_cone_red","RED")]
                data = pcol(col); isempty(data) && continue
                println(io, @sprintf("  %-6s  mean %9.1f   median %7.0f   max %7.0f",
                    label, mean(data), median(data), maximum(data)))
            end
            total_v = pcol("grim_total_cone")
            println(io, "\n  Fractions of total cone (OPB + derived):")
            for (col, label) in [("grim_opb_cone","OPB"), ("grim_cone_rup","RUP"),
                                  ("grim_cone_pol","POL"), ("grim_cone_ia","IA"),
                                  ("grim_cone_red","RED")]
                num_v = pcol(col); (isempty(num_v) || isempty(total_v)) && continue
                fracs = [n/t for (n,t) in zip(num_v, total_v) if t > 0]
                isempty(fracs) && continue
                println(io, @sprintf("  %-6s  mean %6.1f%%   median %6.1f%%",
                    label, mean(fracs)*100, median(fracs)*100))
            end
        end

        # ── Cone depth ────────────────────────────────────────────────────────
        dmax = pcol("grim_cone_depth_max")
        if !isempty(dmax)
            sec(io, "CONE DAG DEPTH  (n=$(length(dmax)))")
            println(io, "  Max depth   " * smry(dmax))
            dmean = pcol("grim_cone_depth_mean")
            isempty(dmean) || println(io, "  Mean depth  " * smry(dmean))
            for (label, col, note) in [
                    ("P50        ", "grim_cone_depth_p50", ""),
                    ("P90        ", "grim_cone_depth_p90", ""),
                    ("Entropy    ", "grim_cone_depth_entropy", "  (0=chain, high=spread)"),
                    ("Bottom frac", "grim_cone_bottom_frac",  "  (fraction of steps at depth ≤ 2)"),
                    ("Width CV   ", "grim_cone_width_cv",     "  (0=uniform, high=spiky)")]
                data = pcol(col); isempty(data) && continue
                println(io, @sprintf("  %s  mean %8.3f   median %8.3f%s",
                    label, mean(data), median(data), note))
            end
            println(io)
            for (label, col, note) in [
                    ("POL depth mean", "grim_cone_pol_depth_mean", "centroid in depth space"),
                    ("POL ante mean ", "grim_cone_pol_ante_mean",  "avg antecedents per POL step"),
                    ("POL OPB frac  ", "grim_cone_pol_opb_frac",   "fraction of POL antes from axioms")]
                data = pcol(col); isempty(data) && continue
                println(io, @sprintf("  %s  mean %6.2f   (%s)", label, mean(data), note))
            end
        end

        # ── Resolv ────────────────────────────────────────────────────────────
        reasons = filter(!isempty, get(cols, "resolv_stop_reason", String[]))
        if !isempty(reasons)
            sec(io, "RESOLV LOOP  (n=$(length(reasons)) invoked)")
            for (reason, count) in sort(collect(countmap(reasons)); by=x -> -x[2])
                println(io, @sprintf("  %-30s %6d  (%s of invoked)", reason, count, pct(count, length(reasons))))
            end
            for (label, col) in [("Pattern","resolv_pat_shrinkage"), ("Target","resolv_tar_shrinkage")]
                ps = filter(x -> x > 0, numcol(cols, col))
                isempty(ps) && continue
                println(io, @sprintf("\n  %s shrinkage (n=%d where > 0):  mean %.1f%%   median %.1f%%   max %.1f%%",
                    label, length(ps), mean(ps)*100, median(ps)*100, maximum(ps)*100))
            end
        end

        # ── UNSAT core ────────────────────────────────────────────────────────
        cpn = pcol("core_pattern_nodes")
        if !isempty(cpn)
            sec(io, "UNSAT CORE  (n=$(length(cpn)))")
            println(io, "  Pattern core nodes  " * smry(cpn))
            ctn = pcol("core_target_nodes")
            isempty(ctn) || println(io, "  Target  core nodes  " * smry(ctn))
        end

        # ── Outliers ──────────────────────────────────────────────────────────
        sec(io, "OUTLIERS (>1.5 IQR above Q3)")
        for (label, col) in [("Total Time","grim_total_time"), ("Trim Time","grim_trim_time")]
            data = pcol(col); isempty(data) && continue
            q1, q3 = quantile(data, 0.25), quantile(data, 0.75)
            cutoff = q3 + 1.5*(q3 - q1)
            out_idx = [proof_idx[i] for (i,v) in enumerate(data) if v > cutoff]
            isempty(out_idx) && continue
            println(io, "\n  $label outliers ($(length(out_idx))):")
            order = sortperm([parse(Float64, get(cols, col, String[])[i]) for i in out_idx]; rev=true)
            for i in out_idx[order[1:min(5,end)]]
                t    = parse(Float64, cols[col][i])
                inp  = something(tryparse(Int, cols["inp_total_nbeq"][i]),  0)
                cone = something(tryparse(Int, cols["grim_total_cone"][i]), 0)
                println(io, @sprintf("    %-35s %8.1fs  inp=%8d  cone=%7d",
                    cols["instance"][i], t, inp, cone))
            end
        end

        # ── Top 10 slowest ────────────────────────────────────────────────────
        times = pcol("grim_total_time")
        if !isempty(times)
            sec(io, "TOP 10 SLOWEST")
            order = sortperm(times; rev=true)
            for i in order[1:min(10,end)]
                gi = proof_idx[i]
                inp  = something(tryparse(Int, cols["inp_total_nbeq"][gi]),  0)
                cone = something(tryparse(Int, cols["grim_total_cone"][gi]), 0)
                println(io, @sprintf("  %-35s %8.1fs  inp=%8d  cone=%7d",
                    cols["instance"][gi], times[i], inp, cone))
            end
        end

        println(io, "\n" * "="^70)
        println(io, "Summary saved to: $out_file")
    end
    println("\nDone.")
end

main()
