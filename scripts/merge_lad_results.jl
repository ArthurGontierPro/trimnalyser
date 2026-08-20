#!/usr/bin/env julia
# M7.5 route 1 — merge ladveri bench.py rows into our aggregated results.
#
# Usage: julia scripts/merge_lad_results.jl <cluster_results.csv> <lad_bench.csv>... [out.csv]
#
# Our CSV has one row per (instance, solver, config) since M7.4. bench.py's CSV keys on
# (instance, config) too — its instance names match ours exactly — so the merge is an
# append with a column remap, not a join: the two solvers fill different columns and no
# instance is ever described by both.
#
# bench.py column  ->  ours
#   verdict            solve_verdict      UNSAT/SAT/TIMEOUT as reported by the solver
#   solve_time         solve_time         seconds
#   pbp_bytes          inp_pbp_size       proof size (proof-logging configs only)
#   opb_bytes          inp_opb_size
#   dev_check          veri_full_status   VeriPB's verdict
#   cake_check         cake_full_status   the trusted checker's verdict
#   verify_time        veri_full_time
# Cone columns stay empty: no LAD proof has been through our trimmer (M5-proof-trim).
# Older bench CSVs name the config column `mode`; both are accepted.

function readcsv(path)
    lines = readlines(path)
    isempty(lines) && return (String[], Vector{Vector{String}}())
    split_row(l) = String.(split(l, ','))          # bench.py writes no quoted commas
    header = split_row(lines[1])
    rows = [split_row(l) for l in lines[2:end] if !isempty(strip(l))]
    (header, rows)
end

const REMAP = Dict(
    "verdict"     => "solve_verdict",
    "solve_time"  => "solve_time",
    "pbp_bytes"   => "inp_pbp_size",
    "opb_bytes"   => "inp_opb_size",
    "dev_check"   => "veri_full_status",
    "cake_check"  => "cake_full_status",
    "verify_time" => "veri_full_time",
    "family"      => "family",
    "instance"    => "instance",
    "solver"      => "solver",
)

function main()
    length(ARGS) < 2 && (println("Usage: julia merge_lad_results.jl <cluster_results.csv> <lad_bench.csv>... [out.csv]"); exit(1))
    ours_path = ARGS[1]
    # The last argument is always the output when more than one input is given; never
    # infer it from whether the file exists, or a re-run silently re-reads its own output.
    out_path  = length(ARGS) >= 3 ? ARGS[end] : "combined_results.csv"
    lad_paths = length(ARGS) >= 3 ? ARGS[2:end-1] : ARGS[2:end]

    header, rows = readcsv(ours_path)
    "instance" in header || error("$ours_path has no instance column")
    # Columns bench.py fills that our aggregator may not define yet.
    for c in ("solve_verdict", "solve_time", "cake_full_status", "veri_full_status", "veri_full_time")
        c in header || push!(header, c)
    end
    idx = Dict(c => i for (i, c) in enumerate(header))
    rows = [length(r) < length(header) ? [r; fill("", length(header) - length(r))] : r for r in rows]

    n_lad = 0
    for lp in lad_paths
        lh, lrows = readcsv(lp)
        cfgcol = "config" in lh ? "config" : "mode" in lh ? "mode" : nothing
        cfgcol === nothing && error("$lp has neither a config nor a mode column")
        lidx = Dict(c => i for (i, c) in enumerate(lh))
        for r in lrows
            cfg = r[lidx[cfgcol]]
            startswith(cfg, "lad") || continue        # bench.py CSVs also carry glasgow rows
            ins = r[lidx["instance"]]
            startswith(ins, "bio") && continue        # directed: invalid for LAD, never a cell
            out = fill("", length(header))
            out[idx["instance"]] = ins
            haskey(idx, "solver") && (out[idx["solver"]] = "lad")
            haskey(idx, "config") && (out[idx["config"]] = cfg)
            for (from, to) in REMAP
                (haskey(lidx, from) && haskey(idx, to)) || continue
                out[idx[to]] = r[lidx[from]]
            end
            push!(rows, out)
            n_lad += 1
        end
    end

    open(out_path, "w") do io
        println(io, join(header, ","))
        for r in rows; println(io, join(r, ",")); end
    end
    println("merged $n_lad LAD rows into $(length(rows) - n_lad) existing rows -> $out_path")
end

main()
