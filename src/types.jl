# ══ Data structures ═════════════════════════════════════════════════════════════════════
    struct Lit
        coef::Int
        sign::Bool
        var::Int end

    mutable struct Eq
        lits::Vector{Lit}   # literals (coef, sign, var triples), sorted by var
        rhs::Int end        # right-hand side constant (sum of satisfied lits >= rhs)

        # Growable flat CSR store for equations parsed from .opb and .pbp files.
        # Replaces Vector{Eq} as the persistent representation, eliminating millions of
        # Eq/Vector{Lit}/Lit heap allocations. processred still uses temporary Eq values.
    mutable struct FlatEqStore
        vars    :: Vector{Int32}   # flat literal variable indices
        coefs   :: Vector{Int32}   # flat literal coefficients
        signs   :: BitVector       # flat literal signs
        rhs     :: Vector{Int64}   # one rhs per equation
        row_ptr :: Vector{Int64} end  # CSR row pointers, length = n_eqs+1; row_ptr[i]:row_ptr[i+1]-1 is eq i

    FlatEqStore() = FlatEqStore(Int32[], Int32[], BitVector(), Int64[], Int64[1])
    function push_eq!(s::FlatEqStore, eq::Eq)
        for l in eq.lits
            push!(s.vars,  Int32(l.var))
            push!(s.coefs, Int32(l.coef))
            push!(s.signs, l.sign)
        end
        push!(s.rhs,     Int64(eq.rhs))
        push!(s.row_ptr, s.row_ptr[end] + length(eq.lits)) end

        # Normalises lits in-place (make all coefs positive) and pushes directly into the store.
        # Replaces the normcoefeq(eq) + push_eq!(store, eq) pair without allocating an Eq object.
    function push_eq_normalized!(s::FlatEqStore, lits::Vector{Lit}, b::Int)
        b2 = 0
        for l in lits
            if l.coef < 0; b2 += -l.coef; end
        end
        b += b2
        for l in lits
            if l.coef < 0
                push!(s.vars, Int32(l.var)); push!(s.coefs, Int32(-l.coef)); push!(s.signs, !l.sign)
            else
                push!(s.vars, Int32(l.var)); push!(s.coefs, Int32(l.coef)); push!(s.signs, l.sign)
            end
        end
        push!(s.rhs,     Int64(b))
        push!(s.row_ptr, s.row_ptr[end] + length(lits)) end

    function get_eq(s::FlatEqStore, i::Int)
        r = Int(s.row_ptr[i]):Int(s.row_ptr[i+1])-1
        Eq([Lit(Int(s.coefs[k]), s.signs[k], Int(s.vars[k])) for k in r], Int(s.rhs[i])) end

    Base.length(s::FlatEqStore)      = length(s.rhs)
    last_eq(s::FlatEqStore)          = get_eq(s, length(s))
        # replicates isequal(system[end], Eq([],1)): last eq has zero lits and rhs==1
    store_last_empty(s::FlatEqStore) = length(s) > 0 &&
                                       s.row_ptr[end] == s.row_ptr[end-1] &&
                                       s.rhs[end] == 1

        # Helper for FlatEqStore: get range of literals for equation e
    eqrange(s::FlatEqStore, e::Integer) = Int(s.row_ptr[e]):Int(s.row_ptr[e+1])-1

        # Scratch buffers for flat POL operations — eliminates all Eq/Lit allocations.
        # For 40k-literal POL steps, this saves millions of allocations by operating
        # directly on flat Int32/BitVector arrays instead of creating temporary Eq objects.
    mutable struct PolScratch
        # Primary working buffer (used for intermediate results)
        vars  ::Vector{Int32}
        coefs ::Vector{Int32}
        signs ::BitVector
        rhs   ::Int64

        # Stack for POL expression evaluation
        # Entries: >0 = equation ID in store, <0 = index into scratch_pool
        stack ::Vector{Int32}
        stack_depth ::Int

        # Pool of scratch equations for complex POL expressions
        # Each entry: (vars, coefs, signs, rhs)
        scratch_pool ::Vector{Tuple{Vector{Int32}, Vector{Int32}, BitVector, Int64}}
        next_scratch ::Int
    end

    PolScratch() = PolScratch(Int32[], Int32[], BitVector(), 0, Int32[], 0, [], 1)
    get_pol_scratch() = get!(task_local_storage(), :pol_scratch, PolScratch())

        # Helper: get equation arrays from either store (id > 0) or scratch (id < 0)
    @inline function _pol_get_arrays(ps::PolScratch, store::FlatEqStore, id::Integer)
        if id > 0
            r = eqrange(store, id)
            return store.vars, store.coefs, store.signs, store.rhs[id], r
        else
            idx = -id
            scratch = ps.scratch_pool[idx]
            r = 1:length(scratch[1])
            return scratch[1], scratch[2], scratch[3], scratch[4], r
        end
    end

        # Allocate scratch buffer from pool and copy ps.{vars,coefs,signs,rhs} into it
    function _pol_alloc_scratch!(ps::PolScratch)
        idx = ps.next_scratch
        ps.next_scratch += 1
        if idx > length(ps.scratch_pool)
            push!(ps.scratch_pool, (copy(ps.vars), copy(ps.coefs), copy(ps.signs), ps.rhs))
        else
            s = ps.scratch_pool[idx]
            resize!(s[1], length(ps.vars)); copyto!(s[1], ps.vars)
            resize!(s[2], length(ps.coefs)); copyto!(s[2], ps.coefs)
            resize!(s[3], length(ps.signs)); copyto!(s[3], ps.signs)
            ps.scratch_pool[idx] = (s[1], s[2], s[3], ps.rhs)
        end
        return idx
    end

        # Materialize store equation into ps.{vars,coefs,signs,rhs}
    function _pol_materialize!(ps::PolScratch, store::FlatEqStore, id::Integer)
        r = eqrange(store, id)
        resize!(ps.vars, length(r))
        resize!(ps.coefs, length(r))
        resize!(ps.signs, length(r))
        for (i, k) in enumerate(r)
            ps.vars[i] = store.vars[k]
            ps.coefs[i] = store.coefs[k]
            ps.signs[i] = store.signs[k]
        end
        ps.rhs = store.rhs[id]
    end

    mutable struct Red
        witness::Vector{Lit}                # flat pairs: witness[2k-1]=source var, witness[2k]=target var (var=0 → const-0, var=-1 → const-1)
        range::UnitRange{Int64}             # system id range of the entire red block (reversed negation → conclusion)
        proof_goal_ranges::Vector{UnitRange{Int64}} end  # id ranges of individual proof goals inside the block

    struct PBSystem
        # Forward: equation → terms
        vars    ::Vector{Int32}
        coefs   ::Vector{Int32}
        signs   ::BitVector
        rhs     ::Vector{Int64}
        row_ptr ::Vector{Int64}
        # Inverse: variable → equations containing it
        var_ptr     ::Vector{Int64}  # length = n_vars + 1
        var_eqs     ::Vector{Int32}  # flat list of equation ids
        var_lit_idx ::Vector{Int64}  # flat literal index k of var v in equation var_eqs[j]
        # Precomputed initial slack (all vars unassigned): used by init_slack_cache!
        initial_slack_fwd ::Vector{Int32}  # sum(coefs[e]) - rhs[e]
        initial_slack_rev ::Vector{Int32}  # rhs[e] - 1
    end

    mutable struct Trail
        var  ::Vector{Int32}    # variables in propagation order
        eq   ::Vector{Int32}    # reason equation for each entry
        pos  ::Vector{Int}      # pos[v] = index in var/eq (0 = unassigned)
        assi ::Vector{Int8}     # current assignment (1=true, 2=false, 0=unset)
        slack_cache ::Vector{Int32}      # incremental slack per constraint
        slack_rev_cache ::Vector{Int32}  # incremental slack for reversed constraints
    end

    Trail(n_vars::Int) = Trail(Int32[], Int32[], zeros(Int, n_vars), zeros(Int8, n_vars), Int32[], Int32[])
    @inline function reset!(t::Trail)
        empty!(t.var); empty!(t.eq)
        fill!(t.pos, 0); fill!(t.assi, 0)
        empty!(t.slack_cache); empty!(t.slack_rev_cache) end

        # init_slack_cache!: reset trail caches to the all-vars-unassigned state.
        # With assi all-zero: fwd = sum(coefs[e]) - rhs[e], rev = rhs[e] - 1 — both precomputed
        # in PBSystem. This replaces the former O(n·k) loop with two O(n) memcopies.
    function init_slack_cache!(t::Trail, sys::PBSystem)
        n = length(sys.rhs)
        copyto!(resize!(t.slack_cache,     n), sys.initial_slack_fwd)
        copyto!(resize!(t.slack_rev_cache, n), sys.initial_slack_rev)
    end

        # Update slack caches incrementally when assigning variable v to val.
        # For each constraint containing v:
        #   - Forward: if literal becomes falsified, subtract its coef
        #   - Reversed: if literal becomes satisfied, subtract its coef
    @inline function update_slack_on_assign!(t::Trail, sys::PBSystem, v::Int, val::Int8)
        @inbounds for j in varrange(sys, v)
            eid  = Int(sys.var_eqs[j])
            k    = Int(sys.var_lit_idx[j])
            sign = sys.signs[k]
            coef = sys.coefs[k]
            becomes_falsified = (sign & (val == Int8(2))) | (!sign & (val == Int8(1)))
            becomes_satisfied = (sign & (val == Int8(1))) | (!sign & (val == Int8(2)))
            t.slack_cache[eid]     -= becomes_falsified ? coef : zero(Int32)
            t.slack_rev_cache[eid] -= becomes_satisfied ? coef : zero(Int32)
        end
    end

        # Cached slack accessors — read from incremental cache instead of recomputing.
    @inline slack_cached(t::Trail, e::Int) = @inbounds t.slack_cache[e]
    @inline slack_reversed_cached(t::Trail, e::Int) = @inbounds t.slack_rev_cache[e]

    struct Ante
        flags::Vector{Bool}   # O(1) membership
        list ::Vector{Int} end# O(k) iteration; may contain stale (false) entries

    Ante(n::Int) = Ante(zeros(Bool, n), Int[])
    struct RupState                                    # scratch buffers for one getcone! call; RED subproof calls allocate their own
        que           ::BitVector                      # ruptrail equation queue
        pq_prio       ::BinaryMinHeap{Int}             # priority equations (cone/on_frontier)
        pq_nonprio    ::BinaryMinHeap{Int}             # non-priority equations
        to_explain    ::BinaryMaxHeap{Int}             # conflicttrail: trail positions still needing explanation
        is_to_explain ::BitVector                      # membership guard for to_explain (self-cleaning)
        falsified_lits::Vector{Tuple{Int,Int,Int,Int32}} # conflicttrail: reused per-iteration buffer
        essentials    ::Dict{Int,Set{Int}} end           # forward-pass: essential vars per constraint (Clit only)

        # Trimming mode — passed through getcone! → ruptrail → process_eq! → conflicttrail.
        # To add a new mode: define a new struct + a conflicttrail method. Nothing else changes.
    struct Grim end        # standard: proof-index sort in conflict analysis
    struct Clit end        # cone-first sort + essentials-aware filter in conflict analysis
    RupState(n_eqs::Int, n_vars::Int) = RupState(
        falses(n_eqs),
        BinaryMinHeap{Int}(),
        BinaryMinHeap{Int}(),
        BinaryMaxHeap{Int}(),
        falses(n_vars + 1),
        Tuple{Int,Int,Int,Int32}[],
        Dict{Int,Set{Int}}())

    function PBSystem(store::FlatEqStore, n_vars::Int)
        # Forward arrays are reused directly from the store — zero copy.
        # Only the inverse index (var_ptr, var_eqs) needs to be computed fresh.
        vars    = store.vars
        coefs   = store.coefs
        signs   = store.signs
        rhs     = store.rhs
        row_ptr = store.row_ptr
        n_lits  = length(vars)

        var_count = zeros(Int32, n_vars)
        for v in vars; var_count[v] += 1; end
        var_ptr = Vector{Int64}(undef, n_vars + 1)
        var_ptr[1] = 1
        for v in 1:n_vars
            var_ptr[v+1] = var_ptr[v] + var_count[v]
        end
        var_eqs     = Vector{Int32}(undef, n_lits)
        var_lit_idx = Vector{Int64}(undef, n_lits)
        fill!(var_count, 0)
        n_eqs = length(rhs)
        initial_slack_fwd = Vector{Int32}(undef, n_eqs)
        initial_slack_rev = Vector{Int32}(undef, n_eqs)
        for e in 1:n_eqs
            total = zero(Int32)
            for k in Int(row_ptr[e]):Int(row_ptr[e+1])-1
                v = vars[k]
                j = var_ptr[v] + var_count[v]
                var_eqs[j]     = e
                var_lit_idx[j] = k
                var_count[v] += 1
                total += coefs[k]
            end
            initial_slack_fwd[e] = total - Int32(rhs[e])
            initial_slack_rev[e] = Int32(rhs[e]) - Int32(1)
        end
        return PBSystem(vars, coefs, signs, rhs, row_ptr, var_ptr, var_eqs, var_lit_idx,
                        initial_slack_fwd, initial_slack_rev) end

    eqrange(sys::PBSystem, e) = Int(sys.row_ptr[e]):Int(sys.row_ptr[e+1])-1
    varrange(sys::PBSystem, v) = Int(sys.var_ptr[v]):Int(sys.var_ptr[v+1])-1
    function slack(eq::Eq, assi::Vector{Int8})
        c = 0
        for l in eq.lits
            val = assi[l.var]
            (val == 0 || (l.sign && val == 1) || (!l.sign && val == 2)) && (c += l.coef)
        end
        return c - eq.rhs end

    @inline function slack(sys::PBSystem, e::Int, assi::Vector{Int8})
        c = zero(Int32)
        @inbounds for i in eqrange(sys, e)
            val  = assi[Int(sys.vars[i])]
            sign = sys.signs[i]
            unaffected = (val == 0) | (sign & (val == 1)) | (!sign & (val == 2))
            c += unaffected ? sys.coefs[i] : zero(Int32)
        end
        return c - sys.rhs[e] end

    inprism(n, prism::BitVector)             = n <= length(prism) && prism[n]
    inprism(n, prism::Vector{UnitRange{Int64}}) = any(n in r for r in prism)
    @inline function setconelits(conelits, v, id)
        push!(get!(Set{Int}, conelits, id), v) end

        # CSR storage for proof step link data — zero allocation per step during parsing.
        # idx[i] encodes entry type:  k>0 → flat data at ptr[k]:ptr[k+1]-1
        #                              k<0 → singleton rule type (shared const, never mutated)
        #                              k=0 → mutable entry in extra (RUP cone + RED with refs)
    mutable struct SystemLink
        data::Vector{Int}             # flat concatenated link payloads for non-singleton steps
        ptr::Vector{Int}              # ptr[k]:ptr[k+1]-1 = k-th flat entry range in data
        idx::Vector{Int}              # one per proof step — see encoding above
        extra::Dict{Int,Vector{Int}} end # mutable per-step vectors (RUP cone-visited, RED refs)

    SystemLink() = SystemLink(Int[], Int[1], Int[], Dict{Int,Vector{Int}}())
    Base.length(sl::SystemLink) = length(sl.idx)
    Base.eachindex(sl::SystemLink) = 1:length(sl.idx)
    Base.isassigned(sl::SystemLink, i::Int) = 1 <= i <= length(sl.idx)
    @inline function _sl_singleton(t::Int)
        t == -1  ? _LINK_RUP  :
        t == -4  ? _LINK_RED  :
        t == -3  ? _LINK_IARES :
        t == -10 ? _LINK_END  :
        t == -7  ? _LINK_PG7  :
        t == -21 ? _LINK_SOLI :
        t == -20 ? _LINK_SOLX : error("unknown singleton type $t") end

        # Read: zero allocation — returns a view into flat data or a shared singleton const.
    function Base.getindex(sl::SystemLink, i::Int)
        k = @inbounds sl.idx[i]
        k > 0 ? (@inbounds @view sl.data[sl.ptr[k]:sl.ptr[k+1]-1]) :
        k < 0 ? _sl_singleton(k) :
                 sl.extra[i] end

        # Push a proof rule with no antecedents (RUP, RED, SOLI, SOLX, …).
        # Stores only the rule type — no heap allocation.
    sl_push_rule!(sl::SystemLink, type::Int) = push!(sl.idx, type)

        # Push a proof step with multiple antecedents (POL, assumption-with-hints).
        # Appends the link data in-place — no copy of the source vector.
    function sl_push_data!(sl::SystemLink, link::AbstractVector{Int})
        k = length(sl.ptr)
        append!(sl.data, link)
        push!(sl.ptr, length(sl.data) + 1)
        push!(sl.idx, k) end

        # Push an inequality addition (IA) rule: stores [-3, constraint_id] without a temp Vector.
    function sl_push_ia!(sl::SystemLink, a::Int, b::Int)
        k = length(sl.ptr)
        push!(sl.data, a, b)
        push!(sl.ptr, length(sl.data) + 1)
        push!(sl.idx, k) end

        # Return (creating if needed) the mutable Vector for step i (RUP cone / RED refs).
    function sl_get_mut!(sl::SystemLink, i::Int)
        k = sl.idx[i]
        k == 0 && return sl.extra[i]
        vec = k < 0 ? Int[k] : collect(@inbounds @view sl.data[sl.ptr[k]:sl.ptr[k+1]-1])
        sl.extra[i] = vec
        sl.idx[i] = 0
        return vec end
