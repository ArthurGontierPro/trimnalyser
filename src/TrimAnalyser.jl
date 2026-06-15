#= This is a PB trimmer made to analyse proofs. If problem, ask arthur.pro.gontier@gmail.com
julia --project bin/trimnalyser.jl [options] [instance name or directory of instances]
julia --project --threads 196,1 bin/trimnalyser.jl solve resolv allgraphs maxnodes=50
julia --project --threads 192,1 bin/trimnalyser.jl solve resolv verif allgraphs maxnodes=3000 st=180 tt=6000 rand maxparse=192
=#
module TrimAnalyser

using DataStructures, Mmap

# ── Static constants (cluster detection, paths) ──────────────────────────────
const instance_prefixes = ("LV", "bio", "cviu11", "pr15", "mesh11", "ph_", "sf_")
const is_instance_name(x) = any(startswith(x, p) for p in instance_prefixes)

const opb = ".opb"
const pbp = ".pbp"
const smol = ".smol"
const smol_opb = smol * opb   # ".smol.opb" — trimmed constraint file
const smol_pbp = smol * pbp   # ".smol.pbp" — trimmed proof file
const version = "3.0"
const _cluster = contains(gethostname(), "dcs.gla.ac.uk") || startswith(gethostname(), "fataepyc")
const abspath_base  = get(ENV, "TRIMNALYSER_BASE",
    _cluster ? "/users/grad/arthur/" : "/home/arthur_gla/veriPB/subgraphsolver/")
const SIPgraphpath  = get(ENV, "TRIMNALYSER_GRAPHS",
    _cluster ? "/scratch/arthur/newSIPbenchmarks/" : "/home/arthur_gla/veriPB/newSIPbenchmarks/")
const sipsolverpath = get(ENV, "GLASGOW_SUBGRAPH_SOLVER",
    _cluster ? "/scratch/arthur/glasgow_subgraph_solver" : "/home/arthur_gla/veriPB/subgraphsolver/glasgow-subgraph-solver/build/glasgow_subgraph_solver")

# ── Optional profiler ─────────────────────────────────────────────────────────
const _HAS_PROFILER = try; @eval using StatProfilerHTML; true; catch; false; end

# ── Config struct + runtime init ──────────────────────────────────────────────
include("config.jl")

# ── Core sections (in dependency order) ──────────────────────────────────────
include("utilities.jl")
include("types.jl")
include("parser.jl")
include("pol.jl")
include("trimmer.jl")
include("writer.jl")
include("solver.jl")
include("output.jl")
include("pipeline.jl")
include("orchestrator.jl")

export main

# ── Precompile workload ───────────────────────────────────────────────────────
using PrecompileTools
@compile_workload begin
    let _proofs = joinpath(@__DIR__, "..", "test", "instances") * "/", _inst = "LVg10g12"
        if isfile(_proofs * _inst * opb) && isfile(_proofs * _inst * pbp)
            mktempdir() do dir
                cp(_proofs * _inst * opb, joinpath(dir, _inst * opb))
                cp(_proofs * _inst * pbp, joinpath(dir, _inst * pbp))
                parse_config!([dir * "/", _inst])
                trimnalyse(_inst; mode=Grim())
            end
        end
    end
end

end # module TrimAnalyser
