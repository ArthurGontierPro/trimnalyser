#!/usr/bin/env julia
import Pkg, Logging
let prev = Logging.global_logger(Logging.NullLogger())
    Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
    haskey(ENV, "TRIMNALYSER_SYSIMAGE") || Pkg.instantiate()
    Logging.global_logger(prev)
end
using TrimAnalyser
TrimAnalyser.main(ARGS)
