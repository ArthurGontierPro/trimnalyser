# ══ Writer ══════════════════════════════════════════════════════════════════════════════
    function isid(link, k)
        return link[k] > 0 && (k == length(link) || (link[k+1] != -2 && link[k+1] != -3)) end

    function writelits(f::IO, lits, varmap)
        for l in lits
            print(f, l.coef, " ", l.sign ? "" : "~", varmap[l.var], " ")
        end end

    function writeeq(f::IO, sys::PBSystem, e::Int, varmap)
        for k in eqrange(sys, e)
            print(f, sys.coefs[k], " ", sys.signs[k] ? "" : "~", varmap[Int(sys.vars[k])], " ")
        end
        print(f, ">= ", sys.rhs[e], " ;\n") end

    function writeeqconelits(f::IO, sys::PBSystem, e::Int, varmap, conelit)
        b = zero(Int32)
        for k in eqrange(sys, e)
            v = Int(sys.vars[k])
            if v in conelit || -v in conelit
                print(f, sys.coefs[k], " ", sys.signs[k] ? "" : "~", varmap[v], " ")
            else
                b += sys.coefs[k]
            end
        end
        print(f, ">= ", max(0, Int(sys.rhs[e]) - Int(b)), " ;\n") end

    function writeu(f::IO, sys::PBSystem, e::Int, varmap)
        print(f, "rup "); writeeq(f, sys, e, varmap) end

    function writeuconelits(f::IO, sys::PBSystem, e::Int, varmap, conelit)
        print(f, "rup "); writeeqconelits(f, sys, e, varmap, conelit) end

    function writeia(f::IO, sys::PBSystem, e::Int, link, index, varmap)
        print(f, "ia ")
        for k in eqrange(sys, e)
            print(f, sys.coefs[k], " ", sys.signs[k] ? "" : "~", varmap[Int(sys.vars[k])], " ")
        end
        print(f, ">= ", sys.rhs[e], " : ", index[link], " ;\n") end

    function writeiaconelits(f::IO, sys::PBSystem, e::Int, link, index, varmap, conelit)
        b = zero(Int32)
        print(f, "ia ")
        for k in eqrange(sys, e)
            v = Int(sys.vars[k])
            if v in conelit || -v in conelit
                print(f, sys.coefs[k], " ", sys.signs[k] ? "" : "~", varmap[v], " ")
            else
                b += sys.coefs[k]
            end
        end
        print(f, ">= ", max(0, Int(sys.rhs[e]) - Int(b)), " : ", index[link], " ;\n") end

    function writewitness(f::IO, red_block, varmap)
        for l in red_block.witness
            if l.var > 0; print(f, !l.sign ? " ~" : " ", varmap[l.var])
            else          print(f, " ", -l.var) end
        end end

    function writered(f::IO, sys::PBSystem, e::Int, varmap, witness, beg; reversed=false)
        print(f, "red")
        for k in eqrange(sys, e)
            sign = reversed ? !sys.signs[k] : sys.signs[k]
            print(f, " ", sys.coefs[k], sign ? " " : " ~", varmap[Int(sys.vars[k])])
        end
        rhs = reversed ? (sum(Int(sys.coefs[k]) for k in eqrange(sys, e); init=0) - Int(sys.rhs[e]) + 1) :
                         Int(sys.rhs[e])
        print(f, " >= ", rhs, " ;")
        writewitness(f, witness, varmap)
        print(f, beg, "\n") end

    function writepol(f::IO, link, index, varmap)
        print(f, "pol")
        for i in 2:length(link)
            t = link[i]
            if t == -1;      print(f, " +")
            elseif t == -2;  print(f, " *")
            elseif t == -3;  print(f, " d")
            elseif t == -4;  print(f, " s")
            elseif t == -5;  print(f, " w")
            elseif t > 0
                if link[i+1] in [-2, -3]; print(f, " ", t)
                else                       print(f, " ", index[t]) end
            elseif t <= -100
                sign = mod((-t), 100) != 0
                print(f, sign ? " " : " ~", varmap[(-t) ÷ 100])
            end
        end
        print(f, " ;\n") end

    function writesolx(f::IO, sys::PBSystem, e::Int, varmap)
        print(f, "solx")
        for k in eqrange(sys, e)
            print(f, sys.signs[k] ? " ~" : " ", varmap[Int(sys.vars[k])])
        end
        print(f, " ;\n") end

    function writesoli(f::IO, sol, varmap)
        print(f, "soli")
        for l in sol
            print(f, l.sign ? " " : " ~", varmap[l.var])
        end
        print(f, " ;\n") end

    function writedel(f, systemlink, i, succ, index, nbopb, dels)
        isdel = false
        link = systemlink[i - nbopb]
        for k in eachindex(link)
            p = link[k]
            if isid(link, k) && !dels[p]
                m = maximum(succ[p])
                if m == i
                    if !isdel
                        write(f, "del id ")
                        isdel = true
                    end
                    dels[p] = true
                    if index[p] == 0
                        printstyled("  [error] del index is 0 for $p (link: $(systemlink[p - nbopb]))\n"; color=:red)
                    else
                        write(f, string(index[p], " "))
                    end
                end
            end
        end
        if isdel write(f, " ;\n") end end

    function invlink(systemlink, succ::Vector{Vector{Int}}, cone, nbopb)
        for i in eachindex(systemlink)
            link = systemlink[i]
            for k in eachindex(link)
                j = link[k]
                if isid(link, k) && cone[i + nbopb]
                    if isassigned(succ, j)
                        if !(i + nbopb in succ[j])
                            push!(succ[j], i + nbopb)
                        end
                    else
                        succ[j] = [i + nbopb]
                    end
                end
            end
        end end

    function justifydeg(f, sys::PBSystem, e::Int, hints, index, varmap)
        link = [-2, parse(Int, hints[1])]
        for j in 2:length(hints)-1
            push!(link, parse(Int, hints[j]))
            push!(link, -1)
        end
        push!(link, parse(Int, hints[end]))
        push!(link, -1, -4)
        writepol(f, link, index, varmap)
        print(f, "ia ")
        for k in eqrange(sys, e)
            print(f, sys.coefs[k], " ", sys.signs[k] ? "" : "~", varmap[Int(sys.vars[k])], " ")
        end
        print(f, ">= ", sys.rhs[e], " : -1 ;\n")
        write(f, "del id -2 ;\n")
        return 1 end

    function justify(f, sys::PBSystem, e::Int, asserthint, index, varmap)
        st = split(asserthint, keepempty=false)
        extrai = 0
        if st[1] == "deg"
            extrai = justifydeg(f, sys, e, st[2:end], index, varmap)
        end
        return extrai end

    function writeconedel(path, file, sys::PBSystem, cone, conelits, systemlink,
                          redwitness, solirecord, assertrecord, nbopb,
                          varmap, ctrmap, output, conclusion, obj, prism)
        index = zeros(Int, length(sys.rhs))
        lastindex = 0
        open(path*file*smol_opb, "w") do f
            if length(obj) > 0
                print(f, "min: ")
                writelits(f, obj, varmap)
                print(f, ";\n")
            end
            for i in 1:nbopb
                if cone[i]
                    lastindex += 1
                    index[i] = lastindex
                    cl = get(conelits, i, nothing)
                    if cl !== nothing; writeeqconelits(f, sys, i, varmap, cl)
                    else              writeeq(f, sys, i, varmap) end
                end
            end
        end
        # size by nbopb + all proof steps (including any empty equations) so that
        # constraint IDs in pol links — which count every systemlink entry — are always in range.
        succ = Vector{Vector{Int}}(undef, nbopb + length(systemlink))
        dels = falses(length(sys.rhs))
        dels[1:nbopb] .= true
        for p in prism
            dels[p] .= true
        end
        invlink(systemlink, succ, cone, nbopb)
        todel = Vector{Int}()
        open(path*file*smol_pbp, "w") do f
            print(f, "pseudo-Boolean proof version ", version, "\n")
            print(f, "f ", sum(cone[1:nbopb]), " ;\n")
            for i in nbopb+1:length(sys.rhs)
                if cone[i]
                    lastindex += 1
                    index[i] = lastindex
                    rule_type = systemlink[i - nbopb][1]
                    if rule_type == -1               # rup
                        cl = get(conelits, i, nothing)
                        if cl !== nothing; writeuconelits(f, sys, i, varmap, cl)
                        else              writeu(f, sys, i, varmap) end
                        if !isempty(eqrange(sys, i))
                            writedel(f, systemlink, i, succ, index, nbopb, dels)
                        end
                    elseif rule_type == -2           # pol
                        writepol(f, systemlink[i - nbopb], index, varmap)
                        writedel(f, systemlink, i, succ, index, nbopb, dels)
                    elseif rule_type == -3           # ia
                        cl = get(conelits, i, nothing)
                        if cl !== nothing; writeiaconelits(f, sys, i, systemlink[i - nbopb][2], index, varmap, cl)
                        else              writeia(f, sys, i, systemlink[i - nbopb][2], index, varmap) end
                        writedel(f, systemlink, i, succ, index, nbopb, dels)
                    elseif rule_type == -4           # red alone
                        writered(f, sys, i, varmap, redwitness[i], "")
                        dels[i] = true
                    elseif rule_type == -5           # rup in subproof
                        print(f, "    "); writeu(f, sys, i, varmap)
                        push!(todel, i)
                    elseif rule_type == -6           # pol in subproof
                        print(f, "    "); writepol(f, systemlink[i - nbopb], index, varmap)
                        push!(todel, i)
                    elseif rule_type == -9           # red with begin (reversed initial equation)
                        writered(f, sys, i, varmap, redwitness[i], " ; begin"; reversed=true)
                        todel = [i]; dels[i] = true
                    elseif rule_type == -7           # red proofgoal #1
                        write(f, "    proofgoal #1\n")
                    elseif rule_type == -8           # red proofgoal normal
                        print(f, "    proofgoal ", index[systemlink[i - nbopb][2]], "\n")
                        push!(todel, i)
                    elseif rule_type == -10          # red proofgoal end
                        lastindex -= 1                 # sub-block end doesn't consume an output index
                        write(f, "    end -1\n")
                        next = systemlink[i - nbopb][1]
                        if next != -7 && next != -8    # last proofgoal: close the outer red block too
                            lastindex += 1             # outer red "end" does consume an index
                            write(f, "end\n")
                            for ii in todel
                                writedel(f, systemlink, ii, succ, index, nbopb, dels)
                            end
                        end
                    elseif rule_type == -20          # solx
                        writesolx(f, sys, i, varmap); dels[i] = true
                    elseif rule_type == -21          # soli
                        writesoli(f, solirecord[i], varmap)
                    elseif rule_type == -30          # unchecked assumption
                        if haskey(assertrecord, i)
                            lastindex += justify(f, sys, i, assertrecord[i], index, varmap)
                        else
                            print(f, "a "); writeeq(f, sys, i, varmap)
                        end
                    else
                        printstyled("  [error] unknown rule_type=$rule_type\n"; color=:red)
                        lastindex -= 1
                    end
                end
            end
            print(f, "output ", output, " ;\n")
            if conclusion == "SAT"
                print(f, "conclusion ", conclusion, " ;\n")
            elseif conclusion == "UNSAT"
                print(f, "conclusion ", conclusion, " : -1 ;\n")
            else
                print(f, replace(conclusion, ";" => ""), " ;\n")
            end
            write(f, "end pseudo-Boolean proof ;")
        end end

    function printlitcolor(coef, sign, var, color)
        if coef != 1 printstyled(coef; color = :blue) end
        sign ? print(" ") : printstyled('~'; color = :red)
        printstyled(var; color = color) end

    function printeqconelit(sys::PBSystem, e::Int, conelits)
        conelit = get(conelits, e, Set{Int}())
        s = zero(Int32)
        for k in eqrange(sys, e)
            v = Int(sys.vars[k])
            print(" ")
            if v in conelit
                printlitcolor(sys.coefs[k], sys.signs[k], v, :yellow)
            else
                printlitcolor(sys.coefs[k], sys.signs[k], v, :magenta)
                s += sys.coefs[k]
            end
        end
        if s == 0
            println(" >= ", sys.rhs[e])
        else
            println(" >= ", sys.rhs[e], " - ", s, " >= ", sys.rhs[e] - s)
        end end

    function printeq(eq::Eq)
        for l in eq.lits
            print(" ")
            printlitcolor(l.coef, l.sign, l.var, :green)
        end
        println(" >= ", eq.rhs) end

    function printeq(sys::PBSystem, e::Int)
        for k in eqrange(sys, e)
            print(" ")
            printlitcolor(sys.coefs[k], sys.signs[k], Int(sys.vars[k]), :green)
        end
        println(" >= ", sys.rhs[e]) end
