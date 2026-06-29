#!/usr/bin/env julia
# Oracle replay experiment: re-solve instances with cone- or full-proof-derived branching order.
# Three comparisons per instance:
#   baseline  — Glasgow default heuristic (no order file)
#   cone      — --pattern-order-file <instance>.var_order      (cone-derived order)
#   full      — --pattern-order-file <instance>.full.var_order (full-proof-derived order)
#
# Ratios (<1 = order file is better than reference):
#   cone_vs_base : cone / baseline
#   full_vs_base : full / baseline
#   cone_vs_full : cone / full  (does cone trimming improve the oracle?)
#
# Skips .coreN iterations (resolv cores use reduced LAD files that may not exist).
# If only one of .var_order / .full.var_order exists, that run still proceeds; the
# missing run's columns are left as -1 and its ratios as -1.
#
# Usage:
#   julia --threads=N scripts/oracle_replay.jl <proofs_dir> [output_csv] [solver_timeout]
#
# proofs_dir:     directory containing .var_order / .full.var_order files
# output_csv:     defaults to oracle_replay_results.csv
# solver_timeout: seconds, defaults to 60

const GRAPHS = get(ENV, "TRIMNALYSER_GRAPHS",
    contains(gethostname(), "dcs.gla.ac.uk") || startswith(gethostname(), "fataepyc") ?
    "/scratch/arthur/newSIPbenchmarks/" : "/home/arthur_gla/veriPB/newSIPbenchmarks/")

const SOLVER = get(ENV, "GLASGOW_SUBGRAPH_SOLVER",
    contains(gethostname(), "dcs.gla.ac.uk") || startswith(gethostname(), "fataepyc") ?
    "/scratch/arthur/glasgow_subgraph_solver" : "/home/arthur_gla/veriPB/subgraphsolver/glasgow-subgraph-solver/build/glasgow_subgraph_solver")

function instance_family(ins)
    startswith(ins, "LV")     && return "LV"
    startswith(ins, "bio")    && return "bio"
    startswith(ins, "cviu11") && return "images-CVIU11"
    startswith(ins, "pr15")   && return "images-PR15"
    startswith(ins, "mesh11") && return "meshes-CVIU11"
    startswith(ins, "ph_")    && return "phase"
    startswith(ins, "sf_")    && return "scalefree"
    startswith(ins, "si__")   && return "si"
    return "unknown"
end

function parsegraphfiles(ins, graphs)
    g = graphs
    if startswith(ins, "bio")
        pat = ins[4:end-3]; tar = ins[end-2:end]
        base = g * "biochemicalReactions/"
        return base * pat * ".txt", base * tar * ".txt"
    elseif startswith(ins, "LV")
        i = findlast('g', ins)
        base = g * "LV/"
        return base * "g" * ins[4:i-1], base * "g" * ins[i+1:end]
    elseif startswith(ins, "cviu11_p")
        m = match(r"^cviu11_p(\d+)_t(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = g * "images-CVIU11/"
        return base * "patterns/pattern" * m[1], base * "targets/target" * m[2]
    elseif startswith(ins, "pr15_p")
        m = match(r"^pr15_p(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = g * "images-PR15/"
        return base * "pattern" * m[1], base * "target"
    elseif startswith(ins, "mesh11_p")
        m = match(r"^mesh11_p(\d+)_t(\d+)$", ins)
        m === nothing && return nothing, nothing
        base = g * "meshes-CVIU11/"
        return base * "patterns/pattern" * m[1], base * "targets/target" * m[2]
    elseif startswith(ins, "ph_")
        base = g * "phase/"
        return base * ins[4:end] * "-pattern", base * ins[4:end] * "-target"
    elseif startswith(ins, "sf_")
        base = g * "scalefree/" * ins[4:end] * "/"
        return base * "pattern", base * "target"
    elseif startswith(ins, "si__")
        parts = split(ins[5:end], "__"; limit=2)
        length(parts) != 2 && return nothing, nothing
        base = g * "si/" * parts[1] * "/" * parts[2] * "/"
        return base * "pattern", base * "target"
    end
    return nothing, nothing
end

function run_solver(solver, pat, tar, timeout; order_file=nothing)
    cmd_parts = ["timeout", string(timeout), solver,
                 "--no-clique-detection", "--staged", "--format", "lad", pat, tar]
    if order_file !== nothing
        push!(cmd_parts, "--pattern-order-file", order_file)
    end
    out = IOBuffer()
    err = IOBuffer()
    exitcode = try
        p = run(pipeline(Cmd(cmd_parts), stdout=out, stderr=err), wait=true)
        p.exitcode
    catch e
        e isa ProcessFailedException ? e.procs[1].exitcode : -1
    end
    output = String(take!(out))
    nodes   = let m = match(r"nodes = (\d+)", output);   m !== nothing ? parse(Int, m[1]) : -1 end
    runtime = let m = match(r"runtime = (\d+)", output); m !== nothing ? parse(Int, m[1]) : -1 end
    status  = let m = match(r"status = (\w+)", output);  m !== nothing ? m[1] : "error" end
    timed_out = exitcode in (124, 137)
    (nodes=nodes, runtime=runtime, status=status, timed_out=timed_out)
end

# Sentinel result used when an order file is absent.
const MISSING_RUN = (nodes=-1, runtime=-1, status="missing", timed_out=false)

ratio(a, b) = (a > 0 && b > 0) ? round(a / b; digits=4) : -1.0

const CSV_COLUMNS = [
    "instance", "family",
    "baseline_nodes", "baseline_ms", "baseline_status",
    "cone_nodes",     "cone_ms",     "cone_status",
    "full_nodes",     "full_ms",     "full_status",
    "cone_vs_base_nodes", "cone_vs_base_ms",
    "full_vs_base_nodes", "full_vs_base_ms",
    "cone_vs_full_nodes", "cone_vs_full_ms",
]

# ── Main ──────────────────────────────────────────────────────────────────────

if length(ARGS) < 1
    println("Usage: julia --threads=N scripts/oracle_replay.jl <proofs_dir> [output_csv] [solver_timeout]")
    exit(1)
end

proofs_dir     = ARGS[1]
output_csv     = length(ARGS) >= 2 ? ARGS[2] : "oracle_replay_results.csv"
solver_timeout = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 60

isfile(SOLVER) || (println("Solver not found: $SOLVER"); exit(1))
isdir(proofs_dir) || (println("Proofs dir not found: $proofs_dir"); exit(1))

struct InstanceEntry
    name::String
    pat::String
    tar::String
    cone_vo::Union{String,Nothing}   # path to .var_order, or nothing
    full_vo::Union{String,Nothing}   # path to .full.var_order, or nothing
end

# Discover instances from .var_order files (exclude .full.var_order and .coreN).
cone_suffix = ".var_order"
cone_files  = filter(readdir(proofs_dir)) do f
    endswith(f, cone_suffix) && !contains(f, ".full.") && !contains(f, ".core")
end

entries, n_unresolved = let entries = InstanceEntry[], nr = 0
    for f in cone_files
        ins = f[1:end-length(cone_suffix)]
        pat, tar = parsegraphfiles(ins, GRAPHS)
        if pat === nothing || !isfile(pat) || !isfile(tar)
            nr += 1
            continue
        end
        cone_path = joinpath(proofs_dir, ins * ".var_order")
        full_path = joinpath(proofs_dir, ins * ".full.var_order")
        push!(entries, InstanceEntry(
            ins, pat, tar,
            isfile(cone_path) ? cone_path : nothing,
            isfile(full_path) ? full_path : nothing,
        ))
    end
    sort!(entries, by=e -> e.name)
    entries, nr
end

n        = length(entries)
nthreads = Threads.nthreads()
n_cone   = count(e -> e.cone_vo !== nothing, entries)
n_full   = count(e -> e.full_vo !== nothing, entries)
println("Oracle replay: $n instances from $(length(cone_files)) .var_order files, timeout=$(solver_timeout)s, threads=$nthreads")
println("  cone orders: $n_cone / $n  |  full orders: $n_full / $n")
n_unresolved > 0 && println("  $n_unresolved instances skipped (LAD files not found)")
println("Solver: $SOLVER")
println("Graphs: $GRAPHS")

struct ResultRow
    line::String
end

results = Vector{Union{ResultRow, Nothing}}(nothing, n)
done    = Threads.Atomic{Int}(0)

Threads.@threads :greedy for i in 1:n
    entry = entries[i]
    family = instance_family(entry.name)

    baseline = run_solver(SOLVER, entry.pat, entry.tar, solver_timeout)
    cone     = entry.cone_vo !== nothing ?
               run_solver(SOLVER, entry.pat, entry.tar, solver_timeout; order_file=entry.cone_vo) :
               MISSING_RUN
    full     = entry.full_vo !== nothing ?
               run_solver(SOLVER, entry.pat, entry.tar, solver_timeout; order_file=entry.full_vo) :
               MISSING_RUN

    results[i] = ResultRow(join([
        entry.name, family,
        baseline.nodes, baseline.runtime, baseline.status,
        cone.nodes,     cone.runtime,     cone.status,
        full.nodes,     full.runtime,     full.status,
        ratio(cone.nodes,     baseline.nodes),   ratio(cone.runtime,     baseline.runtime),
        ratio(full.nodes,     baseline.nodes),   ratio(full.runtime,     baseline.runtime),
        ratio(cone.nodes,     full.nodes),        ratio(cone.runtime,     full.runtime),
    ], ","))

    d = Threads.atomic_add!(done, 1) + 1
    d % 50 == 0 && println("  $d/$n done...")
end

open(output_csv, "w") do io
    println(io, join(CSV_COLUMNS, ","))
    for r in results
        r !== nothing && println(io, r.line)
    end
end
println("Done: $(done[]) instances processed")
println("Results in $output_csv")
