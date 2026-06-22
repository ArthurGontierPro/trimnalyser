# ══ Parser ══════════════════════════════════════════════════════════════════════════════
    #
        # Pre-allocated singleton link vectors for rule types whose systemlink entries need no antecedents.
        # Singletons are safe to share ONLY if nothing pushes into them. _LINK_RUP is the exception:
        # ante_into_frontier! lazily replaces a RUP entry with a fresh vector on first cone visit,
        # so the singleton is only ever observed (never mutated) during parsing.
    const _LINK_RUP  = Int[-1]   # rup — sentinel; replaced lazily by ante_into_frontier! for cone steps
    const _LINK_RED  = Int[-4]   # inline red (no subproof)
    const _LINK_IARES = Int[-3]  # ia (single-antecedent pol) result
    const _LINK_END  = Int[-10]  # end-of-subproof marker
    const _LINK_PG7  = Int[-7]   # proofgoal #1
    const _LINK_SOLI = Int[-21]  # soli
    const _LINK_SOLX = Int[-20]  # solx

        # Contiguous byte view into the mmap'd file buffer — the token type returned by tokenize!.
        # Safe as long as the mmap array stays alive (it is kept alive by readopb/readproof's local ref).
    const ByteSpan = SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}

        # Byte-level token comparison against a compile-time String literal (avoids String allocation).
    @inline function tok_eq(v::AbstractVector{UInt8}, s::String)
        n = ncodeunits(s)
        length(v) == n || return false
        @inbounds for i in 1:n
            v[i] == codeunit(s, i) || return false
        end
        return true end

    @inline tok_in(v::AbstractVector{UInt8}, ss) = any(s -> tok_eq(v, s), ss)

        # Parse a signed decimal integer from raw bytes — no String allocation on the hot path.
    @inline function parse_int_bytes(v::AbstractVector{UInt8})
        i = 1
        @inbounds neg = v[1] == UInt8('-')
        neg && (i = 2)
        n = 0
        @inbounds while i <= length(v)
            n = n * 10 + (v[i] - UInt8('0'))
            i += 1
        end
        return neg ? -n : n end

        # Zero-allocation line tokenizer. Replaces both remove(ss,";") and split(ss,keepempty=false).
        # Skips ';' characters inline so no intermediate allocation is needed for semicolon stripping.
        # Uses task_local_storage so the buffer persists across all iterations on the same task
        # (safe with @threads :greedy — each task owns its buffer and never shares it).
        # Returns a reference to the task-local buffer — valid only until the next tokenize! call on this task.
    function tokenize!(ss::AbstractVector{UInt8})
        buf = get!(task_local_storage(), :tokbuf, ByteSpan[])
        empty!(buf)
        i = 1
        n = length(ss)
        while i <= n
            while i <= n
                @inbounds b = ss[i]
                b == UInt8(' ') || b == UInt8('\t') || b == UInt8(';') ? i += 1 : break
            end
            i > n && break
            j = i
            while j <= n
                @inbounds b = ss[j]
                b == UInt8(' ') || b == UInt8('\t') || b == UInt8(';') ? break : (j += 1)
            end
            push!(buf, @view ss[i:j-1])
            i = j
        end
        return buf end

        # Iterate over lines of content as byte views — zero copy per line.
        # Uses mmap'd Vector{UInt8} to avoid the file→heap memcpy that read(file,String) incurs.
    function _scan_lines(cb, content::AbstractVector{UInt8})
        i = 1
        n = length(content)
        while i <= n
            j = findnext(==(UInt8('\n')), content, i)
            last = j === nothing ? n : j - 1
            cb(@view content[i:last])
            i = j === nothing ? n + 1 : j + 1
        end end

    function readinstance(path,file)
        store,varmap,ctrmap,obj = readopb(path,file)
        nbopb = length(store)
        store,systemlink,redwitness,solirecord,assertrecord,output,conclusion = readproof(path,file,store,varmap,ctrmap,obj)
        prism = availableranges(redwitness)
        return store,systemlink,redwitness,solirecord,assertrecord,nbopb,varmap,ctrmap,output,conclusion,obj,prism end

    function readopb(path,file)
        store = FlatEqStore()
        varmap = Dict{Vector{UInt8},Int}()
        ctrmap = Dict{String, Int}()
        obj = ""
        # mmap the file: maps OS page cache directly into virtual address space — zero memcpy.
        # Avoids the file→heap copy that read(file,String) incurs. minfreemem already gates this.
        content_opb = Mmap.mmap(path*file*opb)
        c = 1
        _scan_lines(content_opb) do ss
            if isempty(ss) || ss[1]==UInt8('*') || ss[1]==UInt8('p') return end
            st = tokenize!(ss)
            if st[1][1]==UInt8('@')
                ctrmap[String(view(st[1], 2:length(st[1])))] = c
                st = st[2:end]
            end
            if ss[1] == UInt8('m')
                obj = readobj(st,varmap)
            else
                readeq_push!(store, st, varmap, 1:2:length(st))
                c+=1
            end
        end
        return store,varmap,ctrmap,obj end

        # readobj stores its result permanently (as obj), so it needs its own copy.
        # All other callers (readeq → normcoefeq → push_eq!) are done with lits before the next readlits call.
    readobj(st,varmap) = copy(readlits(st,varmap,2:2:length(st)))
    function readlits(st,varmap,range)
        # reuse a task-local buffer — safe because callers consume lits before the next readlits call.
        lits = get!(task_local_storage(), :litbuf, Lit[])
        n = length(range)
        resize!(lits, n)
        for i in range
            coef = parse_int_bytes(st[i])
            sign = st[i+1][1]!=UInt8('~')
            var = readvar(st[i+1],varmap)
            lits[(i - range.start)÷range.step+1] = Lit(coef,sign,var)
        end
        sort!(lits,by=x->x.var)
        return lits end

    function readvar(s,varmap)
        if s[1]==UInt8(';') error("; added as variable") end
        # Strip '~' prefix; both branches stay as AbstractVector{UInt8} — zero allocation.
        # Dict{Vector{UInt8},Int} lookup with ByteSpan key works via generic array hash/isequal.
        tmp = s[1]==UInt8('~') ? @view(s[2:end]) : s
        if haskey(varmap,tmp)
            return varmap[tmp]
        end
        varmap[copy(tmp)] = length(varmap)+1   # copy once per unique variable name
        return length(varmap) end

    readeq(st,varmap) = readeq(st,varmap,1:2:length(st))
    function readeq(st,varmap,r)
        lits = readlits(st,varmap,r.start:r.step:(r.stop-2))
        lits,b_corr = merge(lits)
        return Eq(lits, parse_int_bytes(st[r.start+2length(r)-1])-b_corr) end

        # Like readeq but pushes directly into the store without allocating an Eq.
        # Used in readopb and hot proof-step paths where the eq is never needed as an object.
        # Always pushes — an empty equation (no lits) IS the contradiction (e.g. >= 1 with no vars)
        # and must occupy a slot in the store so that store and systemlink stay in sync.
    function readeq_push!(store::FlatEqStore, st, varmap, r)
        lits = readlits(st, varmap, r.start:r.step:(r.stop-2))
        lits, b_corr = merge(lits)
        b = parse_int_bytes(st[r.start+2length(r)-1]) - b_corr
        if isempty(lits) && b != 1
            printstyled("  warning: unexpected empty eq with b=$b (expected contradiction b=1)\n"; color=:yellow)
        end
        push_eq_normalized!(store, lits, b)
        return true end

    function merge(lits)
        b_corr=0
        to_delete = get!(task_local_storage(), :delbuf, Int[])
        empty!(to_delete)
        i=j=1
        while i<length(lits)
            j = i
            while j<length(lits) && lits[i].var==lits[j+1].var
                j+=1
                lits[i],cc = add(lits[i],lits[j])
                b_corr+=cc
                push!(to_delete,j)
            end
            i = j+1
        end
        if !isempty(to_delete)
            deleteat!(lits,to_delete)
        end
        return lits,b_corr end

    function add(lit1,lit2)
        lit1,c1 = normlit(lit1)
        lit2,c2 = normlit(lit2)
        return Lit(lit1.coef+lit2.coef,true,lit1.var),c1+c2 end

    normlit(l) = !l.sign ? (Lit(-l.coef,true,l.var),l.coef) : (l,0)
    function normcoefeq(eq)
        c = 0
        for i in eachindex(eq.lits)
            l = eq.lits[i]
            if l.coef < 0
                eq.lits[i] = Lit(-l.coef, !l.sign, l.var)
                c += -l.coef
            end
        end
        eq.rhs = c + eq.rhs end

    function readproof(path,file,store,varmap,ctrmap,obj)
        systemlink = SystemLink()
        redwitness = Dict{Int, Red}()
        solirecord = Dict{Int, Vector{Lit}}()
        assertrecord = Dict{Int, String}()
        prism = Vector{UnitRange{Int64}}()
        output = conclusion = ""
        c = length(store)+1
        nbopb = length(store)
        # mmap the proof file: same rationale as readopb — zero memcpy from OS page cache.
        content_pbp = Mmap.mmap(path*file*pbp)
        _scan_lines(content_pbp) do ss
            if isempty(ss) return end
            i = findfirst(==(UInt8('%')), ss)
            if i !== nothing
                if i<3 return end
                if ss[1]==UInt8('a')
                    assertrecord[c] = String(@view ss[i+1:end])
                end
                ss = @view ss[1:i-1]
            end
            st = tokenize!(ss)
            if st[1][1]==UInt8('@')
                ctrmap[String(view(st[1], 2:length(st[1])))] = c
                st = st[2:end]
            end
            type = st[1]
            pushed = false
                if tok_eq(type,"rup") || tok_eq(type,"u") pushed = processrup_push!(store,st,varmap,systemlink)
            elseif tok_eq(type,"pol") || tok_eq(type,"p") pushed = processpol_push!(store,st,varmap,systemlink,c,ctrmap,nbopb)
            elseif tok_eq(type,"a")                        pushed = processassumption_push!(store,st,varmap,systemlink,assertrecord,c)
            elseif tok_eq(type,"ia")                       pushed = processia_push!(store,st,varmap,ctrmap,c,systemlink)
            elseif tok_eq(type,"red")                      c,_ = processred(store,systemlink,st,varmap,redwitness,c); pushed = true
            elseif tok_eq(type,"sol")                      error("trimmed SAT is the solution")
            elseif tok_eq(type,"soli")                     pushed = processsoli_push!(store,st,varmap,systemlink,c,prism,obj,solirecord)
            elseif tok_eq(type,"solx")                     pushed = processsolx_push!(store,st,varmap,systemlink,c,prism)
            elseif tok_eq(type,"output")                   output = String(st[2])
            elseif tok_eq(type,"conclusion")
                conclusion = String(st[2])
                if conclusion == "BOUNDS"
                    conclusion = String(ss)
                elseif !store_last_empty(store) && (conclusion == "SAT" || conclusion == "NONE")
                    error("SAT Not supported")
                end
            elseif !tok_in(type, ["%","*","wiplvl","w","setlvl","#","f","d","del","end","pseudo-Boolean"])
                printstyled("  [warn] unknown line head (skipped): $(String(ss))\n"; color=:yellow)
            end
            pushed && (c+=1)
        end
        return store,systemlink,redwitness,solirecord,assertrecord,output,conclusion end

        # Hot-path version: pushes directly into the store without allocating an Eq.
        # Always returns true: every systemlink push must have a matching store push to keep indices in sync.
        # Uses _LINK_RUP singleton — zero allocation per RUP step during parsing (~millions per large file).
        # ante_into_frontier! replaces the singleton with a fresh vector on first cone visit (lazy allocation).
    function processrup_push!(store,st,varmap,systemlink)
        sl_push_rule!(systemlink, -1)
        readeq_push!(store, st, varmap, 2:2:length(st))
        return true end

    function processpol_push!(store,st,varmap,systemlink,c,ctrmap,nbopb)
        linkbuf = get!(task_local_storage(), :linkbuf, Int[])
        empty!(linkbuf); push!(linkbuf, -2)
        # Flat POL: pushes directly to store (no Eq/Lit allocations)
        solvepol_flat!(store, st, linkbuf, c, varmap, ctrmap, nbopb)
        # Check for empty result
        if length(store) > 0 && store.row_ptr[end] == store.row_ptr[end-1] && store.rhs[end] == 0
            error("POL empty")
        end
        sl_push_data!(systemlink, linkbuf)
        return true end

    function processassumption_push!(store,st,varmap,systemlink,assertrecord,c)
        eq = readeq(st,varmap,2:2:length(st))
        if haskey(assertrecord,c)
            hints = split(assertrecord[c],keepempty=false)[2:end]
            link = [-30]
            for i in eachindex(hints)
                push!(link,parse(Int,hints[i]))
            end
            sl_push_data!(systemlink,link)
        else
            sl_push_rule!(systemlink,-30)
        end
        normcoefeq(eq); push_eq!(store,eq)
        return true end

    function processia_push!(store,st,varmap,ctrmap,c,systemlink)
        eq,l = readia(st,varmap,ctrmap,Eq([],0),c)
        sl_push_ia!(systemlink,-3,l)
        normcoefeq(eq); push_eq!(store,eq)
        return true end

    function readia(st,varmap,ctrmap,eq,c)
        tok_eq(st[end-1],":") || error("ia constraint has no ID (truncated proof line?)")
        eq = readeq(st,varmap,2:2:length(st)-3)
        l = st[end]
        l = l[1]==UInt8('@') ? ctrmap[String(view(l,2:length(l)))] : parse_int_bytes(l)
        l < 0 && (l = c+l)
        return eq,l end

    function processred(store,systemlink,st,varmap,redwitness,redid)
        i = findfirst(x->tok_eq(x,":"),st)
        eq = readeq(st[2:i],varmap)
        j = findlast(x->tok_eq(x,":"),st)
        if i==j                                        # no second ':' means no witness range — witness ends at "begin"
            j=length(st)
        end
        w = readwitness(st[i+1:j],varmap)
        sl_push_rule!(systemlink, -4)
        normcoefeq(eq)
        push_eq!(store,eq)
        redwitness[length(store)] = Red(w,0:0,[])
        return redid+1,Eq([],0) end

        # Witness is stored as flat pairs: t[2k-1]=source variable, t[2k]=target variable.
        # sign on source encodes polarity of the substitution; sign on target encodes direction.
    function readwitness(st,varmap)
        st = filter(x -> !tok_eq(x,"->") && !tok_eq(x,";"), st)
        t = Vector{Lit}(undef,length(st))
        for i in 1:2:length(st)
            j = i+1
            t[i] = Lit(0,st[i][1]!=UInt8('~'),readwitnessvar(st[i],varmap))  # source
            t[j] = Lit(0,st[j][1]!=UInt8('~'),readwitnessvar(st[j],varmap))  # target
        end
        return t end

    function readwitnessvar(s,varmap)
        if tok_eq(s,"0")
            return 0           # constant 0
        elseif tok_eq(s,"1")
            return -1          # constant 1 (negative sentinel, not a real var id)
        else
            return readvar(s,varmap)
        end end

    function processsoli_push!(store,st,varmap,systemlink,c,prism,obj,solirecord)
        sl_push_rule!(systemlink, -21)
        eq = findbound(store,st,c,varmap,prism,obj,solirecord)
        normcoefeq(eq); push_eq!(store,eq)
        return true end

    function findbound(store,st,c,varmap,prism,obj,solirecord)
        assi = findfullassi(store,st,c,varmap,prism)
        lits = Vector{Lit}(undef,length(assi))
        for i in eachindex(assi)
            if assi[i]==0
                error("assignment not propagated to full")
            else
                lits[i] = Lit(1,assi[i]==1,i) # we add the assignement
            end
        end
        solirecord[c] = lits
        b = 0
        for l in obj        #compute the bound
            if assi[l.var]==1 && l.sign || assi[l.var]==2 && !l.sign
                b+= l.coef
            end
        end
        negobj = [Lit(-l.coef,l.sign,l.var) for l in obj] # we negate the objective
        return Eq(negobj,-b+1) end # -b+1 because we want the bound to be strictly lower

    function findfullassi(store,st,init,varmap,prism)
        lits = Vector{Lit}(undef,length(st)-2)
        for i in 2:length(st)-1 # sol var var var ; — stop before ";"
            _ = readvar(st[i],varmap)
        end
        assi = zeros(Int8,length(varmap))
        for i in 2:length(st)-1
            sign = st[i][1]!=UInt8('~')
            var = readvar(st[i],varmap)
            lits[i-1] = Lit(1,!sign,var)
            assi[var] = sign ? 1 : 2
        end
        changes = true
        while changes
            changes = false
            for i in 1:init-1 # TODO can be replaced with efficient unit propagation
                if !inprism(i,prism)
                    eq = get_eq(store,i)
                    s = slack(eq,assi)
                    if s<0
                        printstyled("  [warn] sol propagated assignment to contradiction at ctr $i: $st\n"; color=:yellow)
                        printeq(eq)
                        lits = [Lit(l.coef,!l.sign,l.var) for l in lits]
                        return assi
                    else
                        for l in eq.lits
                            if l.coef > s && assi[l.var]==0
                                assi[l.var] = l.sign ? 1 : 2 # assi == 1 if l is true, 2 if l is false 0 if l is not assigned
                                changes = true
                            end end end end end end
        return assi end

    function processsolx_push!(store,st,varmap,systemlink,c,prism)
        sl_push_rule!(systemlink, -20)
        eq = solbreakingctr(store,st,c,varmap,prism)
        normcoefeq(eq); push_eq!(store,eq)
        return true end

    function solbreakingctr(store,st,init,varmap,prism)
        assi = findfullassi(store,st,init,varmap,prism)
        lits = Vector{Lit}(undef,length(assi))
        for i in eachindex(assi)
            if assi[i]==0
                error("assignment not propagated to full")
            else
                lits[i] = Lit(1,assi[i]!=1,i) # we add the negation of the assignement
            end
        end
        return Eq(lits,1) end
    function availableranges(redwitness)                   # build the prism, a range colections of all the red subproofs
        prism = [a.range for (_,a) in redwitness if a.range!=0:0]
        return prism end
