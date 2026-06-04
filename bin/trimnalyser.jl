#!/usr/bin/env julia
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
Pkg.instantiate()
using TrimAnalyser
TrimAnalyser.main(ARGS)
