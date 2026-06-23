#!/usr/bin/env julia
# Build or refresh trimnalyser.so. No-op when all source files are older than the image.
# Usage: julia +1.12.2 build_sysimage.jl
# Requires PackageCompiler in the global environment:
#   julia +1.12.2 -e 'using Pkg; Pkg.add("PackageCompiler")'

const ROOT  = @__DIR__
const SO    = joinpath(ROOT, "trimnalyser.so")
const STAMP = SO * ".juliaversion"

function stale()
    isfile(SO)    || return true
    isfile(STAMP) || return true
    read(STAMP, String) != string(VERSION) && return true
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
println("Done in $(round(Int, time()-t0))s → trimnalyser.so  ($(round(filesize(SO)/1024^2; digits=0)) MB)")
println("BUILD_SCRIPT_EXIT")
