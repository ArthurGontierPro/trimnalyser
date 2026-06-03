using Test, TrimAnalyser

const INSTANCES = joinpath(@__DIR__, "instances")

function run_trim(inst; flags=["overwrite"])
    mktempdir() do dir
        cp(joinpath(INSTANCES, inst*".opb"), joinpath(dir, inst*".opb"))
        cp(joinpath(INSTANCES, inst*".pbp"), joinpath(dir, inst*".pbp"))
        TrimAnalyser.main([dir*"/", inst, flags...])
        verif_out = joinpath(dir, inst*".smolverif.out")
        verif = isfile(verif_out) ? occursin("s VERIFIED", read(verif_out, String)) : nothing
        (opb   = isfile(joinpath(dir, inst*".smol.opb")),
         pbp   = isfile(joinpath(dir, inst*".smol.pbp")),
         verif = verif)
    end
end

@testset "LVg400g500 — small proof, trim only" begin
    r = run_trim("LVg400g500")
    @test r.opb
    @test r.pbp
end

@testset "LVg10g12 — full resolv loop + verif" begin
    r = run_trim("LVg10g12"; flags=["overwrite", "resolv", "verif"])
    @test r.opb
    @test r.pbp
    r.verif !== nothing && @test r.verif   # skipped silently if VeriPB not installed
end
