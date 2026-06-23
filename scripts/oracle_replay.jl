#!/usr/bin/env julia
# Oracle replay experiment: re-solve instances with cone-derived branching order.
# Compares baseline (default Glasgow heuristic) vs oracle (--pattern-order-file).
# No proof logging — measures raw search performance.
#
# Usage:
#   julia scripts/oracle_replay.jl <proofs_dir> <instance_list> [output_csv] [solver_timeout]
#
# proofs_dir:     directory containing .var_order files
# instance_list:  text file — either one instance name per line (e.g. "LVg10g12")
#                 or tab-separated LAD path pairs (e.g. "/path/to/pat\t/path/to/tar")
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
    return nothing
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

if length(ARGS) < 2
    println("Usage: julia scripts/oracle_replay.jl <proofs_dir> <instance_list> [output_csv] [solver_timeout]")
    exit(1)
end

proofs_dir   = ARGS[1]
instfile     = ARGS[2]
output_csv   = length(ARGS) >= 3 ? ARGS[3] : "oracle_replay_results.csv"
solver_timeout = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 60

isfile(SOLVER) || (println("Solver not found: $SOLVER"); exit(1))
isfile(instfile) || (println("Instance list not found: $instfile"); exit(1))

struct InstanceEntry
    name::String
    pat::String
    tar::String
end

function load_instances(path, graphs)
    entries = InstanceEntry[]
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
                push!(entries, InstanceEntry(ins, parts[1], parts[2]))
            end
        else
            pat, tar = parsegraphfiles(line, graphs)
            if pat === nothing
                skipped += 1
            else
                push!(entries, InstanceEntry(line, pat, tar))
            end
        end
    end
    skipped > 0 && println("  skipped $skipped unresolvable lines")
    entries
end

entries = load_instances(instfile, GRAPHS)
println("Oracle replay: $(length(entries)) instances, timeout=$(solver_timeout)s")
println("Solver: $SOLVER")
println("Graphs: $GRAPHS")

let n_skipped = 0, n_done = 0
    open(output_csv, "w") do io
        println(io, join(CSV_COLUMNS, ","))

        for (i, entry) in enumerate(entries)
            vo_file = joinpath(proofs_dir, entry.name * ".var_order")
            if !isfile(vo_file)
                n_skipped += 1
                continue
            end

            if !isfile(entry.pat) || !isfile(entry.tar)
                n_skipped += 1
                continue
            end

            family = instance_family(entry.name)

            baseline = run_solver(SOLVER, entry.pat, entry.tar, solver_timeout)
            oracle   = run_solver(SOLVER, entry.pat, entry.tar, solver_timeout; order_file=vo_file)

            node_ratio = (baseline.nodes > 0 && oracle.nodes > 0) ?
                round(oracle.nodes / baseline.nodes; digits=4) : -1.0
            time_ratio = (baseline.runtime > 0 && oracle.runtime > 0) ?
                round(oracle.runtime / baseline.runtime; digits=4) : -1.0

            println(io, join([
                entry.name, family,
                baseline.nodes, baseline.runtime, baseline.status,
                oracle.nodes, oracle.runtime, oracle.status,
                node_ratio, time_ratio
            ], ","))

            n_done += 1
            if n_done % 50 == 0
                println("  $n_done/$(length(entries)) done ($(n_skipped) skipped)...")
                flush(io)
            end
        end
    end
    println("Done: $n_done instances processed, $n_skipped skipped")
    println("Results in $output_csv")
end
