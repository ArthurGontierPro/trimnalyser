#!/usr/bin/env julia

if !haskey(ENV, "TRIMNALYSER_SYSIMAGE")
    import Pkg, Logging
    let prev = Logging.global_logger(Logging.NullLogger())
        Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
        Pkg.instantiate()
        Logging.global_logger(prev)
    end
end
using TrimAnalyser
TrimAnalyser.main(ARGS)
