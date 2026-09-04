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
# allgraphinstances() prints its own "%Generated N instances ..." banner to stdout, which
# would land in the list as a 25,591st "instance". Swallow it — stdout here is the list.
list = redirect_stdout(devnull) do
    TrimAnalyser.allgraphinstances()
end
for i in list
    println(i)
end
println(stderr, "dumped $(length(list)) instances")
