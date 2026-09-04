#!/usr/bin/env julia
# Dump the instance names the orchestrator's own `allgraphs` enumeration produces, one per
# line, to stdout. Authoritative by construction: it calls `allgraphinstances()` rather
# than re-deriving the per-family pairing rules, which differ between all eight families
# and are exactly the thing a reimplementation would get subtly wrong.
#
#   julia --project=. scripts/dump_instances.jl config=gss-lazy [minnodes=N maxnodes=N] > all.txt
#
# `rand` is deliberately NOT passed: the output is sorted and reproducible, and any
# shuffling belongs to the consumer, with its own recorded seed.
using TrimAnalyser
TrimAnalyser.parse_config!(copy(ARGS))
list = TrimAnalyser.allgraphinstances()
for i in list
    println(i)
end
println(stderr, "dumped $(length(list)) instances")
