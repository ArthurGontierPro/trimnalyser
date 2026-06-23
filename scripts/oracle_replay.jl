#!/usr/bin/env julia
# Oracle replay experiment: re-solve instances with cone-derived branching order.
# Compares baseline (default Glasgow heuristic) vs oracle (--pattern-order-file).
# No proof logging — measures raw search performance.
#
# Discovers all .var_order files in proofs_dir, derives instance names and LAD
# paths, runs baseline + oracle on each. Skips .coreN iterations (resolv cores
# use reduced LAD files that may not exist).
#
# Usage:
#   julia --threads=N scripts/oracle_replay.jl <proofs_dir> [output_csv] [solver_timeout]
#
# proofs_dir:     directory containing .var_order files
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
    nodes = let m = match(r"nodes = (\d+)", output); m !== nothing ? parse(Int, m[1]) : -1 end
    runtime = let m = match(r"runtime = (\d+)", output); m !== nothing ? parse(Int, m[1]) : -1 end
    status = let m = match(r"status = (\w+)", output); m !== nothing ? m[1] : "error" end
    timed_out = exitcode in (124, 137)
    (nodes=nodes, runtime=runtime, status=status, timed_out=timed_out)
end

const CSV_COLUMNS = [
    "instance", "family",
    "baseline_nodes", "baseline_ms", "baseline_status",
    "oracle_nodes", "oracle_ms", "oracle_status",
    "node_ratio", "time_ratio"
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
    vo::String
end

vo_files = filter(f -> endswith(f, ".var_order") && !contains(f, ".core"), readdir(proofs_dir))
entries, n_unresolved = let entries = InstanceEntry[], nr = 0
    for f in vo_files
        ins = f[1:end-length(".var_order")]
        pat, tar = parsegraphfiles(ins, GRAPHS)
        if pat === nothing || !isfile(pat) || !isfile(tar)
            nr += 1
            continue
        end
        push!(entries, InstanceEntry(ins, pat, tar, joinpath(proofs_dir, f)))
    end
    sort!(entries, by=e -> e.name)
    entries, nr
end

n = length(entries)
nthreads = Threads.nthreads()
println("Oracle replay: $n instances from $(length(vo_files)) .var_order files, timeout=$(solver_timeout)s, threads=$nthreads")
n_unresolved > 0 && println("  $n_unresolved instances skipped (LAD files not found)")
println("Solver: $SOLVER")
println("Graphs: $GRAPHS")

struct ResultRow
    line::String
end

results = Vector{Union{ResultRow, Nothing}}(nothing, n)
done    = Threads.Atomic{Int}(0)

Threads.@threads for i in 1:n
    entry = entries[i]
    family = instance_family(entry.name)

    baseline = run_solver(SOLVER, entry.pat, entry.tar, solver_timeout)
    oracle   = run_solver(SOLVER, entry.pat, entry.tar, solver_timeout; order_file=entry.vo)

    node_ratio = (baseline.nodes > 0 && oracle.nodes > 0) ?
        round(oracle.nodes / baseline.nodes; digits=4) : -1.0
    time_ratio = (baseline.runtime > 0 && oracle.runtime > 0) ?
        round(oracle.runtime / baseline.runtime; digits=4) : -1.0

    results[i] = ResultRow(join([
        entry.name, family,
        baseline.nodes, baseline.runtime, baseline.status,
        oracle.nodes, oracle.runtime, oracle.status,
        node_ratio, time_ratio
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
