#!/usr/bin/env julia
import Pkg
Pkg.activate(joinpath(@__DIR__, ".."); io=devnull)
using TrimAnalyser
TrimAnalyser.main(ARGS)
