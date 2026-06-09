#!/usr/bin/env julia
# Terminal statistics from cluster_results.csv.
# Usage: julia --project=scripts scripts/quick_stats.jl cluster_results.csv [output.txt]

using CSV, DataFrames, Statistics, Printf

struct TeeIO <: IO; a::IO; b::IO; end
Base.write(t::TeeIO, x::UInt8) = (write(t.a, x); write(t.b, x); 1)

sec(io, title) = println(io, "\n" * "="^70 * "\n " * title * "\n" * "="^70)
pct(n, tot) = tot > 0 ? @sprintf("%.1f%%", 100n / tot) : "—"

function nonnull(df, col)
    col ∉ names(df) && return Float64[]
    Float64[x for x in skipmissing(df[!, col])]
end

function smry(data, unit="")
    isempty(data) && return "(no data)"
    @sprintf("mean %8.2f%s   median %8.2f%s   min %6.2f%s   max %6.2f%s",
        mean(data), unit, median(data), unit, minimum(data), unit, maximum(data), unit)
end

function main()
    length(ARGS) < 1 && (println("Usage: julia quick_stats.jl <csv> [output.txt]"); exit(1))
    csv_file = ARGS[1]
    out_file = length(ARGS) >= 2 ? ARGS[2] : "stats_summary.txt"
    isfile(csv_file) || (println("Error: $csv_file not found"); exit(1))

    println("Loading $csv_file...")
    df = CSV.read(csv_file, DataFrame; missingstring=["", "NA"])

    for col in (:is_sat, :is_unsat, :has_proof, :proof_truncated, :has_error)
        col ∈ propertynames(df) || continue
        df[!, col] = map(x -> !ismissing(x) && (x == "true" || x == true), df[!, col])
    end

    open(out_file, "w") do f
        io = TeeIO(stdout, f)
        n = nrow(df)

        println(io, "Cluster Results Analysis — $csv_file")
        println(io, "="^70)

        # ── Overview ──────────────────────────────────────────────────────────
        sec(io, "OVERVIEW")
        println(io, @sprintf("Total instances:      %10d", n))
        for (col, label) in [(:is_sat,"SAT"), (:is_unsat,"UNSAT"), (:has_proof,"With proof"),
                              (:proof_truncated,"Truncated"), (:has_error,"Errors")]
            col ∉ propertynames(df) && continue
            c = sum(df[!, col])
            println(io, @sprintf("%-22s %10d  (%s)", label * ":", c, pct(c, n)))
        end
        if :resolv_iterations ∈ propertynames(df)
            rc = sum(coalesce.(df.resolv_iterations, 0) .> 0)
            println(io, @sprintf("%-22s %10d  (%s)", "Resolv ran:", rc, pct(rc, n)))
        end

        proof_df = df[df.has_proof .== true, :]
        np = nrow(proof_df)
        np == 0 && (println(io, "\nNo instances with proofs."); return)

        # ── Skip / error breakdown ────────────────────────────────────────────
        if :skip_reason ∈ propertynames(df)
            skip_df = df[.!ismissing.(df.skip_reason), :]
            if nrow(skip_df) > 0
                sec(io, "SKIP REASONS")
                for (reason, count) in sort(collect(countmap(skip_df.skip_reason)); by=x -> -x[2])
                    println(io, @sprintf("  %-35s %7d  (%s)", reason, count, pct(count, n)))
                end
            end
        end

        # ── Timing ────────────────────────────────────────────────────────────
        sec(io, "TIMING  (n=$np instances with proofs)")
        for (label, col) in [("Parse Time", "grim_parse_time"), ("Trim Time", "grim_trim_time"),
                              ("Write Time", "grim_write_time"), ("Total Time", "grim_total_time")]
            data = nonnull(proof_df, col)
            isempty(data) && continue
            println(io, "\n  $label:")
            println(io, "    " * smry(data, "s"))
            println(io, @sprintf("    95th %%ile %8.2fs   std %8.2fs", quantile(data, 0.95), std(data)))
        end

        # ── Size / reduction ──────────────────────────────────────────────────
        sec(io, "SIZE & REDUCTION  (n=$np)")
        inp_sz = nonnull(proof_df, "inp_total_size")
        out_sz = nonnull(proof_df, "grim_total_size")
        if !isempty(inp_sz) && !isempty(out_sz)
            inp_gb = sum(inp_sz) / 1024^3
            out_gb = sum(out_sz) / 1024^3
            println(io, @sprintf("  Total input %8.2f GB   Total output %8.2f GB   Reduction %.1f%%",
                inp_gb, out_gb, (1 - out_gb / inp_gb) * 100))
        end
        inp_eq = nonnull(proof_df, "inp_total_nbeq")
        out_eq = nonnull(proof_df, "grim_total_cone")
        if !isempty(inp_eq) && !isempty(out_eq)
            ratios = [(a - b) / a for (a, b) in zip(inp_eq, out_eq) if a > 0]
            isempty(ratios) || println(io, @sprintf(
                "  Constraint reduction  mean %.1f%%   median %.1f%%   min %.1f%%   max %.1f%%",
                mean(ratios)*100, median(ratios)*100, minimum(ratios)*100, maximum(ratios)*100))
        end
        lit_in  = nonnull(proof_df, "grim_cone_literals")
        lit_out = nonnull(proof_df, "grim_smol_literals")
        if !isempty(lit_in) && !isempty(lit_out)
            ratios = [(a - b) / a for (a, b) in zip(lit_in, lit_out) if a > 0]
            isempty(ratios) || println(io, @sprintf(
                "  Literal reduction     mean %.1f%%   median %.1f%%   min %.1f%%   max %.1f%%",
                mean(ratios)*100, median(ratios)*100, minimum(ratios)*100, maximum(ratios)*100))
        end

        # ── Cone step types ───────────────────────────────────────────────────
        rup_data = nonnull(proof_df, "grim_cone_rup")
        if !isempty(rup_data)
            sec(io, "CONE STEP TYPES  (n=$(length(rup_data)))")
            for col in ["grim_cone_rup", "grim_cone_pol", "grim_cone_red", "grim_cone_ia"]
                data = nonnull(proof_df, col)
                isempty(data) && continue
                label = uppercase(replace(col, "grim_cone_" => ""))
                println(io, @sprintf("  %-6s  mean %9.1f   median %7.0f   max %7.0f",
                    label, mean(data), median(data), maximum(data)))
            end
            println(io)
            for col in ["grim_rup_frac", "grim_pol_frac", "grim_ia_frac", "grim_red_frac"]
                data = nonnull(proof_df, col)
                isempty(data) && continue
                label = uppercase(replace(col, "grim_" => ""))
                println(io, @sprintf("  %-12s  mean %6.1f%%   median %6.1f%%",
                    label, mean(data)*100, median(data)*100))
            end
        end

        # ── Cone depth ────────────────────────────────────────────────────────
        dmax = nonnull(proof_df, "grim_cone_depth_max")
        if !isempty(dmax)
            sec(io, "CONE DAG DEPTH  (n=$(length(dmax)))")
            println(io, "  Max depth   " * smry(dmax))
            dmean = nonnull(proof_df, "grim_cone_depth_mean")
            isempty(dmean) || println(io, "  Mean depth  " * smry(dmean))

            for (label, col, note) in [
                    ("P50        ", "grim_cone_depth_p50", ""),
                    ("P90        ", "grim_cone_depth_p90", ""),
                    ("Entropy    ", "grim_cone_depth_entropy", "  (0=chain, high=spread)"),
                    ("Bottom frac", "grim_cone_bottom_frac",  "  (fraction of steps at depth ≤ 2)"),
                    ("Width CV   ", "grim_cone_width_cv",     "  (0=uniform, high=spiky)")]
                data = nonnull(proof_df, col)
                isempty(data) && continue
                println(io, @sprintf("  %s  mean %8.3f   median %8.3f%s",
                    label, mean(data), median(data), note))
            end
            println(io)
            pol_dm = nonnull(proof_df, "grim_pol_depth_mean")
            pol_am = nonnull(proof_df, "grim_pol_ante_mean")
            pol_of = nonnull(proof_df, "grim_pol_opb_frac")
            isempty(pol_dm) || println(io, @sprintf("  POL depth mean   mean %6.2f   (centroid in depth space)", mean(pol_dm)))
            isempty(pol_am) || println(io, @sprintf("  POL ante mean    mean %6.2f   (avg antecedents per POL step)", mean(pol_am)))
            isempty(pol_of) || println(io, @sprintf("  POL OPB frac     mean %6.2f   (fraction of POL antes from axioms)", mean(pol_of)))
        end

        # ── Resolv ────────────────────────────────────────────────────────────
        if :resolv_stop_reason ∈ propertynames(df)
            reasons = collect(skipmissing(df.resolv_stop_reason))
            if !isempty(reasons)
                sec(io, "RESOLV LOOP")
                for (reason, count) in sort(collect(countmap(reasons)); by=x -> -x[2])
                    println(io, @sprintf("  %-30s %6d  (%s)", reason, count, pct(count, n)))
                end
                ps = filter(x -> x > 0, nonnull(df, "resolv_pat_shrinkage"))
                ts = filter(x -> x > 0, nonnull(df, "resolv_tar_shrinkage"))
                isempty(ps) || println(io, @sprintf(
                    "\n  Pattern shrinkage (n=%d where > 0):  mean %.1f%%   median %.1f%%   max %.1f%%",
                    length(ps), mean(ps)*100, median(ps)*100, maximum(ps)*100))
                isempty(ts) || println(io, @sprintf(
                    "  Target  shrinkage (n=%d where > 0):  mean %.1f%%   median %.1f%%   max %.1f%%",
                    length(ts), mean(ts)*100, median(ts)*100, maximum(ts)*100))
            end
        end

        # ── UNSAT core ────────────────────────────────────────────────────────
        cpn = nonnull(proof_df, "core_pattern_nodes")
        ctn = nonnull(proof_df, "core_target_nodes")
        if !isempty(cpn)
            sec(io, "UNSAT CORE  (n=$(length(cpn)))")
            println(io, "  Pattern core nodes  " * smry(cpn))
            isempty(ctn) || println(io, "  Target  core nodes  " * smry(ctn))
        end

        # ── Outliers ──────────────────────────────────────────────────────────
        sec(io, "OUTLIERS (>1.5 IQR above Q3)")
        for (label, col) in [("Total Time", "grim_total_time"), ("Trim Time", "grim_trim_time")]
            data = nonnull(proof_df, col)
            isempty(data) && continue
            q1, q3 = quantile(data, 0.25), quantile(data, 0.75)
            cutoff = q3 + 1.5 * (q3 - q1)
            out_idx = findall(i -> !ismissing(proof_df[i, col]) && Float64(proof_df[i, col]) > cutoff,
                              1:nrow(proof_df))
            isempty(out_idx) && continue
            println(io, "\n  $label outliers ($(length(out_idx))):")
            sub = sort(proof_df[out_idx, :], col; rev=true)
            for row in eachrow(sub[1:min(5, end), :])
                inp  = ismissing(row[:inp_total_nbeq])  ? 0 : Int(row[:inp_total_nbeq])
                cone = ismissing(row[:grim_total_cone]) ? 0 : Int(row[:grim_total_cone])
                println(io, @sprintf("    %-35s %8.1fs  inp=%8d  cone=%7d",
                    row[:instance], Float64(row[Symbol(col)]), inp, cone))
            end
        end

        # ── Top 10 slowest ────────────────────────────────────────────────────
        if "grim_total_time" ∈ names(proof_df)
            sec(io, "TOP 10 SLOWEST")
            for row in eachrow(sort(proof_df, :grim_total_time; rev=true)[1:min(10, end), :])
                inp  = ismissing(row[:inp_total_nbeq])  ? 0 : Int(row[:inp_total_nbeq])
                cone = ismissing(row[:grim_total_cone]) ? 0 : Int(row[:grim_total_cone])
                println(io, @sprintf("  %-35s %8.1fs  inp=%8d  cone=%7d",
                    row[:instance], Float64(row[:grim_total_time]), inp, cone))
            end
        end

        println(io, "\n" * "="^70)
        println(io, "Summary saved to: $out_file")
    end
    println("\nDone.")
end

# StatsBase.countmap equivalent using just Base
function countmap(v)
    d = Dict{eltype(v), Int}()
    for x in v; d[x] = get(d, x, 0) + 1; end
    d
end

main()
