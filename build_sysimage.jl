#!/usr/bin/env julia
# Build or refresh trimnalyser.so. No-op when all source files are older than the image.
# Usage: julia +1.12.2 build_sysimage.jl
# Requires PackageCompiler in the global environment:
#   julia +1.12.2 -e 'using Pkg; Pkg.add("PackageCompiler")'

const ROOT  = @__DIR__
const SO    = joinpath(ROOT, "trimnalyser.so")
const STAMP = SO * ".juliaversion"
const ENVSTAMP = SO * ".env"

# The binary paths are `const X = get(ENV, "VAR", default)` evaluated at module load, so
# under --sysimage they are frozen at BUILD time. check_sysimage_env() (orchestrator.jl)
# refuses to start when they disagree with the environment and tells you to re-run this
# script — but a changed environment does not touch any source file, so the mtime check
# below would say "up to date" and the run would stay blocked with no way out. Record what
# was baked, and treat a change to it as staleness.
envkeys() = sort!(vcat(["TRIMNALYSER_GRAPHS", "TRIMNALYSER_LOGS", "TRIMNALYSER_BASE",
                        "GLASGOW_SUBGRAPH_SOLVER", "LAD_SOLVER", "VERIPB",
                        "CAKE_PB", "CAKE_PB_ISO"],
                       filter(k -> startswith(k, "GLASGOW_SUBGRAPH_SOLVER_"), collect(keys(ENV)))))
envstamp() = join(("$k=$(get(ENV, k, ""))" for k in envkeys()), "\n")

function stale()
    isfile(SO)    || return true
    isfile(STAMP) || return true
    read(STAMP, String) != string(VERSION) && return true
    isfile(ENVSTAMP) || return true
    read(ENVSTAMP, String) != envstamp() && return true
    t = mtime(SO)
    for f in readdir(joinpath(ROOT, "src"); join=true)
        endswith(f, ".jl") && mtime(f) > t && return true
    end
    for f in [joinpath(ROOT, "Project.toml"), joinpath(ROOT, "Manifest.toml")]
        isfile(f) && mtime(f) > t && return true
    end
    return false
end

if !stale()
    println("sysimage up to date → trimnalyser.so")
    exit(0)
end

println("Building sysimage → trimnalyser.so  (≈2 min, Julia $VERSION)")
t0 = time()

using Pkg
Pkg.activate(ROOT; io=devnull)

# The env-dependent constants are baked during PRECOMPILATION, and Julia's precompile
# cache key does not include the environment. So an image rebuilt with cluster_env.sh
# sourced happily reuses a .ji compiled without it, and every gssbin() pin silently
# collapses onto the single global binary again — the exact failure cluster_env.sh and
# check_sysimage_env() exist to prevent, except now it survives a "clean" rebuild.
# Observed 2026-08-27: all nine Glasgow columns resolved to
# /scratch/arthur/glasgow_subgraph_solver in a freshly built image.
let cache = joinpath(DEPOT_PATH[1], "compiled", "v$(VERSION.major).$(VERSION.minor)", "TrimAnalyser")
    isdir(cache) && (rm(cache; recursive=true); println("  purged stale precompile cache: $cache"))
end

try
    using PackageCompiler
catch
    println("┌ Sysimage build skipped: PackageCompiler not found in the global Julia env.")
    println("│   Subprocess startup will be ~5s slower per instance.")
    println("│   To enable sysimage builds, run once:")
    println("└   julia -e 'using Pkg; Pkg.add(\"PackageCompiler\")'")
    exit(0)
end

PackageCompiler.create_sysimage(
    [:TrimAnalyser];
    sysimage_path              = SO,
    project                    = ROOT,
    precompile_execution_file  = joinpath(ROOT, "precompile_workload.jl"),
)

write(STAMP, string(VERSION))
write(ENVSTAMP, envstamp())
println("Done in $(round(Int, time()-t0))s → trimnalyser.so  ($(round(filesize(SO)/1024^2; digits=0)) MB)")
