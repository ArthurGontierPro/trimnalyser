# Executed by PackageCompiler during sysimage build to trace native code.
using TrimAnalyser

let proofs = joinpath(@__DIR__, "test", "instances") * "/", inst = "LVg10g12"
    if isfile(proofs * inst * TrimAnalyser.opb) && isfile(proofs * inst * TrimAnalyser.pbp)
        mktempdir() do dir
            cp(proofs * inst * TrimAnalyser.opb, joinpath(dir, inst * TrimAnalyser.opb))
            cp(proofs * inst * TrimAnalyser.pbp, joinpath(dir, inst * TrimAnalyser.pbp))
            TrimAnalyser.parse_config!([dir * "/", inst])
            TrimAnalyser.trimnalyse(inst; mode=TrimAnalyser.Grim())
        end
    end
end
