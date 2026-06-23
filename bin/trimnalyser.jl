#!/usr/bin/env julia

# === DIAGNOSTIC MODE — remove after debugging ===
println("DIAG: JULIA_PKG_PRECOMPILE_AUTO = ", get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", "NOT SET"))
println("DIAG: TRIMNALYSER_SYSIMAGE      = ", get(ENV, "TRIMNALYSER_SYSIMAGE", "NOT SET"))
println("DIAG: sysimage file              = ", unsafe_string(Base.JLOptions().image_file))

println("\nDIAG: testing Pkg.activate alone...")
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
println("DIAG: Pkg.activate done")

println("DIAG: testing 'using TrimAnalyser'...")
using TrimAnalyser
println("DIAG: all done, exiting")
# === END DIAGNOSTIC ===
