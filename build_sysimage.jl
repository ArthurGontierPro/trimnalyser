#!/usr/bin/env julia
# Build or refresh trimnalyser.so. No-op when all source files are older than the image.
# Usage: julia build_sysimage.jl
# Requires PackageCompiler in the global environment:
#   julia -e 'using Pkg; Pkg.add("PackageCompiler")'

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
using PackageCompiler   # errors clearly if not installed

PackageCompiler.create_sysimage(
    [:TrimAnalyser];
    sysimage_path = SO,
    project       = ROOT,
)

write(STAMP, string(VERSION))
println("Done in $(round(Int, time()-t0))s → trimnalyser.so  ($(round(filesize(SO)/1024^2; digits=0)) MB)")
