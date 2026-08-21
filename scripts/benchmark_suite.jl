#!/usr/bin/env julia
# Baseline benchmark: compare default vs --staged vs --no-supplementals.
# Reads instance pairs from a tab-separated file (absolute pat/tar paths).
#
# Usage:
#   julia --threads=N scripts/benchmark_suite.jl [instances_txt] [output_csv] [timeout_s]
#
# instances_txt: defaults to 6-29-fullrun/instances.txt
# output_csv:    defaults to benchmark_results/baseline_YYYY-MM-DD.csv
# timeout_s:     defaults to 60

const SOLVER = get(ENV, "GLASGOW_SUBGRAPH_SOLVER",
    contains(gethostname(), "dcs.gla.ac.uk") || startswith(gethostname(), "fataepyc") ?
    "/scratch/arthur/glasgow_subgraph_solver" :
    "/home/arthur_gla/veriPB/subgraphsolver/glasgow-subgraph-solver/build/glasgow_subgraph_solver")

function instance_family(pat_path)
    contains(pat_path, "/LV/")                  && return "LV"
    contains(pat_path, "/biochemicalReactions/") && return "bio"
    contains(pat_path, "/images-CVIU11/")        && return "images-CVIU11"
    contains(pat_path, "/meshes-CVIU11/")        && return "meshes-CVIU11"
    contains(pat_path, "/scalefree/")            && return "scalefree"
    contains(pat_path, "/phase/")                && return "phase"
    return "unknown"
end

# Short label for CSV column prefix + extra CLI flags
const CONFIGS = [
    ("default",  String[]),
    ("staged",   ["--staged"]),
    ("nosup",    ["--no-supplementals"]),
    ("lazy",     ["--lazy-supplementals"]),
]

function run_solver(solver, pat, tar, timeout_s, extra_flags)
    cmd = vcat(["timeout", string(timeout_s), solver, "--format", "lad"], extra_flags, [pat, tar])
    out = IOBuffer()
    exitcode = try
        p = run(pipeline(Cmd(cmd), stdout=out, stderr=devnull), wait=true)
        p.exitcode
    catch e
        e isa ProcessFailedException ? e.procs[1].exitcode : -1
    end
    output = String(take!(out))
    nodes     = let m = match(r"nodes = (\d+)", output);   m !== nothing ? parse(Int, m[1]) : -1 end
    runtime   = let m = match(r"runtime = (\d+)", output); m !== nothing ? parse(Int, m[1]) : -1 end
    status    = let m = match(r"status = (\w+)", output);  m !== nothing ? m[1] : "error" end
    timed_out = exitcode in (124, 137)
    (nodes=nodes, runtime_ms=runtime, status=status, timed_out=timed_out)
end

# PAR-2: mean runtime (s), with 2*timeout for unsolved/error instances.
function par2(results, timeout_s)
    isempty(results) && return NaN
    total = 0.0
    for (ms, solved) in results
        total += solved ? ms / 1000.0 : 2.0 * timeout_s
    end
    total / length(results)
end

# ── Arg parsing ──────────────────────────────────────────────────────────────

using Dates

script_dir    = dirname(abspath(PROGRAM_FILE))
repo_root     = dirname(script_dir)
default_instances = joinpath(repo_root, "6-29-fullrun", "instances.txt")
today         = Dates.format(Dates.today(), "yyyy-mm-dd")
default_csv   = joinpath(repo_root, "benchmark_results", "baseline_$today.csv")

instances_txt = length(ARGS) >= 1 ? ARGS[1] : default_instances
output_csv    = length(ARGS) >= 2 ? ARGS[2] : default_csv
timeout_s     = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 60

isfile(SOLVER)        || (println("Solver not found: $SOLVER"); exit(1))
isfile(instances_txt) || (println("Instances file not found: $instances_txt"); exit(1))
mkpath(dirname(output_csv))

# ── Load instances ────────────────────────────────────────────────────────────

struct Instance
    pat::String
    tar::String
    family::String
end

instances = Instance[]
for line in eachline(instances_txt)
    isempty(strip(line)) && continue
    parts = split(line, '\t')
    length(parts) < 2 && continue
    pat, tar = strip(parts[1]), strip(parts[2])
    (isfile(pat) && isfile(tar)) || continue
    push!(instances, Instance(pat, tar, instance_family(pat)))
end

n        = length(instances)
nthreads = Threads.nthreads()
println("Benchmark suite: $n instances, timeout=$(timeout_s)s, threads=$nthreads")
println("Configs: $(join([c[1] for c in CONFIGS], ", "))")
println("Solver: $SOLVER")
println("Output: $output_csv")

# ── CSV header ────────────────────────────────────────────────────────────────

cols = ["pat", "tar", "family"]
for (label, _) in CONFIGS
    push!(cols, "$(label)_ms", "$(label)_nodes", "$(label)_status", "$(label)_timeout")
end

# ── Run ───────────────────────────────────────────────────────────────────────

struct ResultRow
    line::String
    family::String
    # (runtime_ms, solved) per config, for PAR-2 aggregation
    config_results::Vector{Tuple{Int,Bool}}
end

rows = Vector{Union{ResultRow,Nothing}}(nothing, n)
done = Threads.Atomic{Int}(0)

Threads.@threads :greedy for i in 1:n
    inst = instances[i]
    config_results = Tuple{Int,Bool}[]
    fields = [inst.pat, inst.tar, inst.family]

    for (label, flags) in CONFIGS
        r = run_solver(SOLVER, inst.pat, inst.tar, timeout_s, flags)
        solved = r.status == "true" || r.status == "false"   # completed (sat or unsat)
        push!(fields, string(r.runtime_ms), string(r.nodes), r.status, string(r.timed_out))
        push!(config_results, (r.runtime_ms, solved && !r.timed_out))
    end

    rows[i] = ResultRow(join(fields, ","), inst.family, config_results)

    d = Threads.atomic_add!(done, 1) + 1
    d % 25 == 0 && println("  $d/$n done...")
end

# ── Write CSV ─────────────────────────────────────────────────────────────────

open(output_csv, "w") do io
    println(io, join(cols, ","))
    for r in rows
        r !== nothing && println(io, r.line)
    end
end

# ── PAR-2 summary ─────────────────────────────────────────────────────────────

families = unique(inst.family for inst in instances)
config_labels = [c[1] for c in CONFIGS]

# Collect (runtime_ms, solved) per family × config
accum = Dict((f, ci) => Tuple{Int,Bool}[] for f in families, ci in 1:length(CONFIGS))
for r in rows
    r === nothing && continue
    for (ci, cr) in enumerate(r.config_results)
        push!(accum[(r.family, ci)], cr)
    end
end

println("\nPAR-2 summary (seconds; 2×$timeout_s for unsolved):")
header = rpad("family", 18) * join(rpad(l, 12) for l in config_labels)
println(header)
println("-" ^ length(header))
for fam in sort(families)
    row = rpad(fam, 18)
    for ci in 1:length(CONFIGS)
        v = par2(accum[(fam, ci)], timeout_s)
        row *= rpad(isnan(v) ? "—" : string(round(v; digits=1)), 12)
    end
    println(row)
end

# All-families total
println("-" ^ length(header))
let total_row = rpad("ALL", 18)
    for ci in 1:length(CONFIGS)
        all_results = vcat([accum[(f, ci)] for f in families]...)
        v = par2(all_results, timeout_s)
        total_row *= rpad(isnan(v) ? "—" : string(round(v; digits=1)), 12)
    end
    println(total_row)
end

println("\nDone: $(done[]) instances written to $output_csv")
