#!/usr/bin/env julia
import Pkg, Logging
# Suppress manifest-version warnings: they fire via Julia's logging system
# (not the io= channel) and are harmless — Pkg.instantiate() still works.
let prev = Logging.global_logger(Logging.NullLogger())
    Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
    Pkg.instantiate()
    Logging.global_logger(prev)
end
using TrimAnalyser
TrimAnalyser.main(ARGS)
