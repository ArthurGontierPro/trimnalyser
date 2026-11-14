# ══ Trimmer ═════════════════════════════════════════════════════════════════════════════

        # Forward pass: variable w is essential in constraint e if removing it makes e infeasible
        # (total coef - coef_w < rhs[e]). Essential vars must stay in conelits — weakening them out
        # would make the constraint unsatisfiable and break the proof. Only called for Clit mode.
    function compute_essentials!(essentials::Dict{Int,Set{Int}}, sys::PBSystem)
        for e in 1:length(sys.rhs)
            total = sum(sys.coefs[k] for k in eqrange(sys, e); init=zero(Int32))
            for k in eqrange(sys, e)
                if total - sys.coefs[k] < sys.rhs[e]
                    push!(get!(Set{Int}, essentials, e), Int(sys.vars[k]))
                end
            end
        end end

    @inline function ante_set!(a::Ante, i::Int)
        a.flags[i] && return                          # already registered: avoid list duplicate
        a.flags[i] = true; push!(a.list, i) end

    @inline ante_remove!(a::Ante, i::Int) = (a.flags[i] = false)  # O(1): leave stale entry in list
    @inline function ante_clear!(a::Ante)
        for i in a.list; a.flags[i] = false; end; empty!(a.list) end  # walk list to unset flags, then truncate

    @inline function pushtrail!(t::Trail, sys::PBSystem, v::Int32, eq::Int32, val::Int8)
        push!(t.var, v); push!(t.eq, eq)
        iv = Int(v)
        @inbounds t.pos[iv] = length(t.var)   # trail index of v (0 = unassigned)
        @inbounds t.assi[iv] = val
        update_slack_on_assign!(t, sys, iv, val) end

    function fixante(systemlink::SystemLink, ante::Ante, i)
        for j in eachindex(systemlink[i])
            t = systemlink[i][j]
            if t > 0 && !(j < length(systemlink[i]) && systemlink[i][j+1] in (-2,-3))  # skip multiplicands/divisors (not constraint refs)
                ante_set!(ante, t)
            end
        end end

        # After getcone, any constraint inside a red subproof that references an external antecedent
        # must have that antecedent visible from outside the block. This bubbles those references up
        # to the red declaration's systemlink so the writer emits them as del targets correctly.
    function fixredsystemlink(systemlink, cone, prism, nbopb)
        for range in prism
            red_link = sl_get_mut!(systemlink, range.start-nbopb)
            for i in range
                if cone[i]
                    inner = systemlink[i-nbopb]
                    for j in eachindex(inner)
                        k = inner[j]
                        if k > 0 && !(k in red_link) && k < range.start - nbopb
                            push!(red_link, k)   # bubble external ref up to red declaration
                        end
                    end
                end
            end
            sort!(red_link)
        end end

    function eqvars(sys::PBSystem, e::Int)
        Set{Int}(Int(sys.vars[k]) for k in eqrange(sys, e)) end

        # A constraint is trivial if, after assigning its non-cone literals to their worst case (all 0),
        # the remaining cone-lit coefs already satisfy the RHS — so the constraint adds nothing to the proof.
    function istrivial(sys::PBSystem, e::Int, conelits)
        cl = get(conelits, e, nothing)
        cl === nothing && return sys.rhs[e] <= 0       # no cone lits at all: trivial iff RHS ≤ 0
        a = zero(Int32)
        for k in eqrange(sys, e)
            !(sys.vars[k] in cl) && (a += sys.coefs[k])  # sum coefs of non-cone literals
        end
        return sys.rhs[e] - a <= 0 end                 # trivial if RHS minus non-cone coefs ≤ 0

    function fixconelits(sys::PBSystem, conelits, i::Int, ante::Ante, link)
        # if -3 in link[2:end] # deactivate lit trimming. when div is there
            # for j in ante.list; ante.flags[j] || continue
                # conelits[j] = eqvars(sys, j)
            # end
            # return
        # end
        ivars     = eqvars(sys, i)
        cl        = get(conelits, i, nothing)
        myconelit = cl !== nothing ? cl : ivars            # start from known cone lits, or all vars
        poslits = Set{Int}()   # vars appearing positive across antecedent eqs
        neglits = Set{Int}()   # vars appearing negative across antecedent eqs
        for j in ante.list
            ante.flags[j] || continue
            for k in eqrange(sys, j)
                sys.signs[k] ? push!(poslits, Int(sys.vars[k])) : push!(neglits, Int(sys.vars[k]))
            end
            cj = get(conelits, j, nothing)
            cj !== nothing && (myconelit = myconelit ∪ cj)  # inherit cone lits from antecedent
        end
        myconelit = myconelit ∪ (poslits ∩ neglits)   # vars with both signs are needed (resolution)
        conelits[i] = myconelit ∩ ivars               # restrict to vars actually in this constraint
        for j in ante.list
            ante.flags[j] || continue
            conelits[j] = myconelit ∩ eqvars(sys, j)  # propagate back to each antecedent
        end end

    function removetrivialantecedents(sys::PBSystem, ante::Ante, conelits, link, init::Int)
        for i in ante.list
            ante.flags[i] || continue
            istrivial(sys, i, conelits) || continue   # antecedent became trivial after lit trimming
            j = findfirst(x -> x == i, link)
            if j === nothing
                printstyled("  [warn] antecedent $i not found in link $link\n"; color=:yellow)
                continue
            end
            k0 = findfirst(x -> x == -1, @view link[j+1:end])  # find the '+' following this antecedent in the pol link
            if k0 === nothing
                printeqconelit(sys, init, conelits)
                println(link)
                for jj in ante.list
                    ante.flags[jj] || continue
                    printeqconelit(sys, jj, conelits)
                end
                printstyled("  [warn] antecedent $i's addition not found in link $link\n"; color=:yellow)
                deleteat!(link, j)
                ante_remove!(ante, i)
                continue
            end
            deleteat!(link, (j, k0 + j))  # remove antecedent id and its '+' from the pol link
            ante_remove!(ante, i)
        end end

    @inline function slack_reversed(sys::PBSystem, e::Int, assi::Vector{Int8})
        total = zero(Int32)
        c     = zero(Int32)
        @inbounds for k in eqrange(sys, e)
            coef   = sys.coefs[k]
            total += coef
            val    = assi[Int(sys.vars[k])]
            sign   = sys.signs[k]
            # ~lit is active when original lit is false or unassigned
            unaffected = (val == 0) | (sign & (val == Int8(2))) | (!sign & (val == Int8(1)))
            c += unaffected ? coef : zero(Int32)
        end
        return c - (total - sys.rhs[e] + 1) end  # slack of ~eq: used to RUP-check the negated constraint

        # Falsified-literal sort/filter: the only difference between Grim and Clit conflict analysis.
        # x = (eq_id, trail_pos, var, coef). eq_id==0 means level-0 (free to include).
    @inline function _arrange_falsified_lits!(lits, ::Grim, eq, slack_sum, b, rs, cone)
        sort!(lits; by = x -> x[1]) end

        # Clit: essential vars (removing them makes eq infeasible) must stay; cone/lvl0 vars are free.
        # If essential+free vars alone cover the slack, drop all other vars first (smaller cone).
        # Sort: essential first, then cone/lvl0, then proof depth ascending.
    @inline function _arrange_falsified_lits!(lits, ::Clit, eq, slack_sum, b, rs, cone)
        ess_set  = get(rs.essentials, eq, nothing)
        prio_sum = zero(Int32)
        for (eq_id, _, w, coef) in lits
            ((ess_set !== nothing && w in ess_set) || eq_id == 0 || cone[eq_id]) && (prio_sum += coef)
        end
        if prio_sum > slack_sum - b
            filter!(x -> x[1] == 0 || cone[x[1]] || (ess_set !== nothing && x[3] in ess_set), lits)
        end
        sort!(lits; by = x -> (ess_set !== nothing && x[3] in ess_set ? 0 : 1,
                               x[1] == 0 || cone[x[1]] ? 0 : 1, x[1])) end

    function conflicttrail(ceq::Int, sys::PBSystem, t::Trail,
                           ante::Ante, conelits, rs::RupState, mode::Union{Grim,Clit},
                           cone::BitVector; rev_init::Int=-1)
        to_explain    = rs.to_explain     # self-cleaning: empty after each normal exit
        is_to_explain = rs.is_to_explain  # self-cleaning: all-false after each normal exit
        ante_set!(ante, ceq)
        push!(t.var, Int32(0)); push!(t.eq, Int32(ceq))  # fake var 0 represents the conflict eq itself
        push!(to_explain, length(t.var)); is_to_explain[1] = true
        falsified_lits = rs.falsified_lits
        while !isempty(to_explain)
            vtp = pop!(to_explain)
            v   = Int(t.var[vtp])
            is_to_explain[v+1] = false
            v != 0 && (t.assi[v] = Int8(0))
            eq     = Int(t.eq[vtp])
            ante_set!(ante, eq)
            eq_rev = (eq == rev_init)
            b      = eq_rev ? (sum(sys.coefs[k] for k in eqrange(sys, eq); init=zero(Int32)) - sys.rhs[eq] + 1) :
                              sys.rhs[eq]
            empty!(falsified_lits)
            slack_sum = zero(Int32)
            @inbounds for k in eqrange(sys, eq)
                w = Int(sys.vars[k])
                w == v && continue
                coef = sys.coefs[k]
                slack_sum += coef
                wtp  = t.pos[w]
                wtp > vtp && continue
                wval = t.assi[w]; wsign = sys.signs[k]
                falsified_w = eq_rev ? ((wsign & (wval == Int8(1))) | (!wsign & (wval == Int8(2)))) :
                                       ((wsign & (wval == Int8(2))) | (!wsign & (wval == Int8(1))))
                falsified_w && push!(falsified_lits, (wtp > 0 ? @inbounds(Int(t.eq[wtp])) : 0, wtp, w, coef))
            end
            _arrange_falsified_lits!(falsified_lits, mode, eq, slack_sum, b, rs, cone)
            v != 0 && setconelits(conelits, v, eq)
            for (_, wtp, w, coef) in falsified_lits
                slack_sum < b && break
                if wtp > 0 && !is_to_explain[w+1]
                    push!(to_explain, wtp); is_to_explain[w+1] = true
                end
                setconelits(conelits, w, eq)
                slack_sum -= coef
            end
            if slack_sum >= b
                printstyled("  [error] conflicttrail: could not explain var $v in eq $eq\n"; color=:red)
                printeq(sys, eq); printeqconelit(sys, eq, conelits)
                throw(ErrorException("conflicttrail: could not explain $v with eq $eq"))
            end
        end end

        # Push eid into the right heap if not already queued.
    @inline function activate!(eid, rs::RupState, cone, on_frontier)
        rs.que[eid] && return              # already in a heap, skip
        rs.que[eid] = true
        if cone[eid]; push!(rs.pq_prio, eid)                         # priority: already in cone
        else                        push!(rs.pq_nonprio, eid)  # non-priority: new to cone
        end end

        # Compute slack, propagate, re-activate triggered equations. Return true on conflict.
    @inline function process_eq!(i, init, sys, t, ante, conelits, cone, on_frontier, rs::RupState, mode)
        rev = (i == init)                  # reversed constraint for RUP check of init
        s   = rev ? slack_reversed_cached(t, i) : slack_cached(t, i)
        if s < 0                           # falsified: conflict found
            conflicttrail(i, sys, t, ante, conelits, rs, mode, cone; rev_init=init)
            return true
        end
        @inbounds for k in eqrange(sys, i)
            v = Int(sys.vars[k])
            t.assi[v] != 0 && continue     # already assigned
            sys.coefs[k] > s || continue   # coef too small to force propagation
            sign = sys.signs[k]
            pushtrail!(t, sys, Int32(v), Int32(i),
                       rev ? (sign ? Int8(2) : Int8(1)) :
                             (sign ? Int8(1) : Int8(2)))            # assign variable
            for j in Int(t.iptr[v]):Int(t.iptr[v+1])-1
                eid = Int(t.ieqs[j])
                eid > t.ilimit && break
                (rs.ok[eid] && eid != i) || continue                # only usable eqs (see ruptrail)
                activate!(eid, rs, cone, on_frontier)               # re-queue equations containing v
            end
        end
        rs.que[i] = false                  # done: remove from queue
        return false end

        # Heap-based RUP check: two BinaryMinHeap{Int} — pq_prio (cone/on_frontier equations)
        # and pq_nonprio (others). Priority pass drains pq_prio fully before taking one step
        # from pq_nonprio.
    function ruptrail(sys::PBSystem, init::Int, t::Trail,
                      ante::Ante, on_frontier::BitVector,
                      cone::BitVector, conelits, prism, subrange, rs::RupState, mode=Grim();
                      limit::Int=init, T::Int=-1, core_only::Bool=false,
                      meta::Union{Nothing,ProofMeta}=nothing)
        # `rs.ok` is the set of constraints this check may use. For a refutation that is
        # "everything up to init outside a subproof". With database events (T >= 0) it is
        # also "not deleted by event T or earlier", and for the goals VeriPB checks against
        # the core only, "moved to core by event T or earlier". `init` (checked reversed) is
        # always usable, even when it is the constraint being deleted or a synthetic goal.
        init_slack_cache!(t, sys)
        fill!(rs.que, false)               # reset queue (may have stale trues from early return)
        empty!(rs.pq_prio); empty!(rs.pq_nonprio)
        ok = rs.ok; fill!(ok, false)
        for i in 1:limit                   # seed both heaps with all eligible equations
            (!inprism(i, prism) || (i in subrange)) || continue
            if T >= 0
                meta.deathseq[i] > T || continue
                (core_only && meta.coreseq[i] > T && !(i in subrange)) && continue
            end
            ok[i] = true
            activate!(i, rs, cone, on_frontier)
        end
        if !ok[init]
            ok[init] = true
            activate!(init, rs, cone, on_frontier)
        end
        # Which constraints an assignment touches. A refutation walks the system's inverse
        # index up to `limit`. With database events the usable set is a small part of the
        # proof (most lemmas are dead at any given time), so the check gets its own inverse
        # index over exactly the usable constraints; building it costs their literals once.
        t.iok = ok
        if T >= 0
            live_index!(t, sys, ok, limit, init)
        else
            t.iptr, t.ieqs, t.ilit = sys.var_ptr, sys.var_eqs, sys.var_lit_idx
            t.ilimit = limit
            t.iextra = init > limit ? init : 0
        end
        while true
            while !isempty(rs.pq_prio)     # drain priority equations first
                i = pop!(rs.pq_prio)
                rs.que[i] || continue      # stale pop guard (safety net)
                process_eq!(i, init, sys, t, ante, conelits, cone, on_frontier, rs, mode) && return true
            end
            isempty(rs.pq_nonprio) && break  # nothing left: no conflict found
            i = pop!(rs.pq_nonprio)          # take one non-priority equation
            rs.que[i] || continue            # stale pop guard (safety net)
            process_eq!(i, init, sys, t, ante, conelits, cone, on_frontier, rs, mode) && return true
        end
        return false end

    @inline function push_frontier!(frontier, on_frontier::BitVector, cone::BitVector, j::Int)
        cone[j] && return                             # already in cone (scheduled or processed)
        on_frontier[j] = true; cone[j] = true; push!(frontier, j) end

        # Expand the frontier with all active antecedents; optionally record them in systemlink.
    @inline function ante_into_frontier!(ante::Ante, frontier, on_frontier, cone)
        for j in ante.list; ante.flags[j] || continue; push_frontier!(frontier, on_frontier, cone, j); end end
        # Variant that records antecedents in systemlink[idx] for the writer.
        # sl_get_mut! lazily upgrades the singleton idx entry to a mutable extra vector on first visit,
        # so parsing pays zero allocation per RUP step and only cone steps (a tiny fraction) allocate.
    @inline function ante_into_frontier!(ante::Ante, frontier, on_frontier, cone, systemlink, idx)
        link = sl_get_mut!(systemlink, idx)
        for j in ante.list; ante.flags[j] || continue; push!(link, j); push_frontier!(frontier, on_frontier, cone, j); end end

    # A goal of `preserved_add` / `preserved_rm` is nearly always a reification constraint the
    # proof has just moved to the core (`red ... ; core id ... ; preserved_add ...`). VeriPB looks
    # the goal up in the database before it propagates anything; so do we. Returns the id of a
    # core constraint, alive at event `T` and created by `limit`, with the same terms and
    # degree as goal `g`, or 0. The candidates are the constraints containing the goal's
    # rarest variable.
    function goal_lookup(sys::PBSystem, g::Int, limit::Int, T::Int, meta::ProofMeta)
        gr = sys.row_ptr[g]:sys.row_ptr[g+1]-1
        isempty(gr) && return 0
        best = 0; bestlen = typemax(Int)
        for q in gr
            v = Int(sys.vars[q]); l = Int(sys.var_ptr[v+1] - sys.var_ptr[v])
            l < bestlen && (best = v; bestlen = l)
        end
        @inbounds for j in sys.var_ptr[best]:sys.var_ptr[best+1]-1
            c = Int(sys.var_eqs[j])
            (c <= limit && c != g) || continue
            (meta.deathseq[c] > T && meta.coreseq[c] <= T) || continue
            cr = sys.row_ptr[c]:sys.row_ptr[c+1]-1
            (length(cr) == length(gr) && sys.rhs[c] == sys.rhs[g]) || continue
            same = true
            for q in gr
                found = false
                for r in cr
                    if sys.vars[r] == sys.vars[q] && sys.signs[r] == sys.signs[q] && sys.coefs[r] == sys.coefs[q]
                        found = true; break
                    end
                end
                found || (same = false; break)
            end
            same && return c
        end
        return 0 end

    # Inverse index (variable -> constraints, literal positions) over the constraints of `ok`,
    # written into the trail's own buffers. Same layout as `sys.var_ptr / var_eqs / var_lit_idx`.
    function live_index!(t::Trail, sys::PBSystem, ok::BitVector, limit::Int, init::Int)
        nv = length(sys.var_ptr) - 1
        ptr = resize!(t.lptr, nv + 2); fill!(ptr, 0)
        @inbounds for e in 1:limit
            ok[e] || continue
            for k in sys.row_ptr[e]:sys.row_ptr[e+1]-1; ptr[Int(sys.vars[k]) + 2] += 1; end
        end
        if init > limit
            @inbounds for k in sys.row_ptr[init]:sys.row_ptr[init+1]-1; ptr[Int(sys.vars[k]) + 2] += 1; end
        end
        ptr[1] = 1; ptr[2] += 1
        @inbounds for v in 3:nv+2; ptr[v] += ptr[v-1]; end      # ptr[v+1] = start of v's list (shifted by one)
        n = ptr[nv+2] - 1
        eqs = resize!(t.leqs, n); lit = resize!(t.llit, n)
        @inbounds for e in 1:limit
            ok[e] || continue
            for k in sys.row_ptr[e]:sys.row_ptr[e+1]-1
                v = Int(sys.vars[k]); j = ptr[v+1]; ptr[v+1] = j + 1
                eqs[j] = e; lit[j] = k
            end
        end
        if init > limit
            @inbounds for k in sys.row_ptr[init]:sys.row_ptr[init+1]-1
                v = Int(sys.vars[k]); j = ptr[v+1]; ptr[v+1] = j + 1
                eqs[j] = init; lit[j] = k
            end
        end
        # after the fill, ptr[v+1] is the end of v's list = start of v+1's: shift back into ptr[v]
        t.iptr, t.ieqs, t.ilit = ptr, eqs, lit
        t.ilimit = typemax(Int); t.iextra = 0
        return end

    const _progress = Ref((0, 0))   # (constraint id, event index) the backward walk has reached

    function getcone!(cone, conelits, sys::PBSystem, systemlink, nbopb::Int,
                      prism::Vector{UnitRange{Int64}}, redwitness, conclusion::String, obj, mode;
                      meta::ProofMeta=ProofMeta())
        n    = length(sys.rhs)
        prism_bv = falses(n)
        for r in prism, i in r
            1 <= i <= n && (prism_bv[i] = true)       # bitvector version of prism for O(1) inprism checks
        end
        on_frontier = falses(n)                          # true = constraint is scheduled in frontier
        trail      = Trail(length(sys.var_ptr) - 1)    # var_ptr has length n_vars+1 (CSR convention)

        firstcontradiction = 0                         # root of the backward reachability
        # `ENUMERATION_COMPLETE 0 : id` is a refutation under another name: no solution was
        # logged and constraint `id` is a contradiction.
        conclusion == "ENUMERATION_COMPLETE 0" && (conclusion = "UNSAT")
        if conclusion == "UNSAT"
            firstcontradiction = getfirstcontradiction(sys, prism_bv)
        elseif occursin("BOUNDS", conclusion)
            firstcontradiction = getfirstboundeq(sys, obj, conclusion, cone)
        end
        sk = skeleton(meta)                            # equienumerability: the database events are the roots
        if firstcontradiction == 0 && !sk
            conclusion == "UNSAT" && printstyled("  [error] UNSAT contradiction not found\n"; color=:red)
            return
        end

        ante = Ante(n)
        rs   = RupState(n, length(sys.var_ptr) - 1)   # reusable scratch buffers for rup/conflict analysis
        mode isa Clit && compute_essentials!(rs.essentials, sys)  # forward pass: essential vars per constraint
        frontier = BinaryMaxHeap{Int}()                # max-heap: process highest-indexed eq first (backwards)

        # Local function: clear ante, reset trail, run rup. i and subrange are parameters (not captured)
        # to avoid Julia boxing mutable loop variables. Everything else is captured from getcone! scope.
        function do_rup!(i, subrange; limit=i, T=(sk ? evbefore(meta, i) : -1), core_only=false)
            ante_clear!(ante)
            reset!(trail)
            ruptrail(sys, i, trail, ante, on_frontier, cone, conelits, prism_bv, subrange, rs, mode;
                     limit=limit, T=T, core_only=core_only, meta=meta)
        end

        # Obligations of database event k (equienumerability proofs). Every event is kept in
        # the trimmed proof, so each one is a root:
        #   core id         the constraints it names must be derived
        #   del, core id    checked deletion: explicit subproof → its closing contradiction;
        #                   no witness → RUP from the remaining core; with a witness the
        #                   goals are trivial in the proofs seen so far and are not re-checked
        #   preserved_*     two goals, RUP from the core
        function process_event!(k)
            ev = meta.events[k]
            if ev.kind === :core
                for id in ev.ids; push_frontier!(frontier, on_frontier, cone, id); end
            elseif ev.kind === :del
                for id in ev.ids
                    meta.deathseq[id] == k || continue         # already gone (wiped level)
                    meta.coreseq[id] < k   || continue         # derived: unchecked
                    if ev.sub != 0:0
                        cone[ev.sub.start] = true
                        push_frontier!(frontier, on_frontier, cone, ev.sub.stop)
                    elseif isempty(ev.text)
                        if do_rup!(id, 0:0; limit=ev.at, T=k, core_only=true)
                            ante_remove!(ante, id)
                            ante_into_frontier!(ante, frontier, on_frontier, cone)
                        else
                            printstyled("  [error] checked deletion of $id is not rup from the core\n"; color=:red)
                        end
                    end
                end
            elseif ev.kind === :padd || ev.kind === :prm
                for g in ev.goals
                    c = goal_lookup(sys, g, ev.at, k, meta)   # VeriPB's own first try: the goal is in the core
                    if c != 0
                        meta.goalhits += 1
                        for q in sys.row_ptr[c]:sys.row_ptr[c+1]-1
                            setconelits(conelits, Int(sys.vars[q]), c)
                        end
                        push_frontier!(frontier, on_frontier, cone, c)
                    elseif do_rup!(g, 0:0; limit=ev.at, T=k, core_only=true)
                        meta.goalrups += 1
                        ante_remove!(ante, g)
                        ante_into_frontier!(ante, frontier, on_frontier, cone)
                    else
                        printstyled("  [error] goal of `$(ev.text)` is not rup from the core\n"; color=:red)
                    end
                end
            end end

        if firstcontradiction != 0
        cone[firstcontradiction] = true
        if systemlink[firstcontradiction - nbopb][1] == -2   # contradiction is a pol: antecedents explicit in link
            # Treat it exactly like any other pol step. Two things this branch used to skip:
            #  * fixante instead of a bare `j > 0` scan — a pol link stores multiplicands and
            #    divisors as positive numbers too, and those are not constraint ids.
            #  * fixconelits — it is what marks the antecedents' cancelling literals
            #    (poslits ∩ neglits) as needed. Without it another cone step is free to
            #    literal-trim one of them, and writeeqconelits drops the literal *and* lowers
            #    the degree by its coefficient. The cancellation that let this pol derive
            #    `>= 1` with an empty left-hand side then no longer happens, and VeriPB
            #    rejects `conclusion UNSAT : -1` with "not contradicting, as specified by the
            #    hint". LAD hits this because its final pol is a big weighted sum over the
            #    at-most-one constraints; Glasgow's contradiction is always a rup.
            ante_clear!(ante)
            fixante(systemlink, ante, firstcontradiction - nbopb)
            let lnk = sl_get_mut!(systemlink, firstcontradiction - nbopb)
                fixconelits(sys, conelits, firstcontradiction, ante, lnk)
                removetrivialantecedents(sys, ante, conelits, lnk, firstcontradiction)
            end
            ante_into_frontier!(ante, frontier, on_frontier, cone)
        else                                           # contradiction is rup/ia: RUP-check it to find antecedents
            # Same path for UNSAT and BOUNDS. For UNSAT the contradiction is the empty ">= 1"
            # constraint, so reversing it in process_eq! is a no-op (slack_rev = rhs-1 = 0, no
            # literals to propagate) and the scan proceeds exactly as a plain propagation would.
            if !do_rup!(firstcontradiction, 0:0)
                printstyled("  [error] initial rup for contradiction $firstcontradiction failed\n"; color=:red)
            end
            ante_remove!(ante, firstcontradiction)     # never its own antecedent (cf. the rup case below)
            ante_into_frontier!(ante, frontier, on_frontier, cone, systemlink, firstcontradiction - nbopb)
        end
        end
        evp     = sk ? length(meta.events) : 0         # next event to process, walking backwards
        red     = Red([], 0:0, [])                     # current red block being processed
        pfgl    = UnitRange{Int64}[]                   # deferred proof goals (ref not yet known to be in cone)
        newpfgl = true
        while newpfgl                                  # outer loop: retry deferred proof goals until stable
            newpfgl = false
            while true
                # an event sitting after the next constraint to visit is handled first
                while evp > 0 && (isempty(frontier) || meta.events[evp].at >= first(frontier))
                    process_event!(evp); evp -= 1
                end
                isempty(frontier) && break
                i = pop!(frontier)
                _progress[] = (i, evp)                 # how far back the walk is, for a profile cut short
                on_frontier[i] || continue             # stale pop guard
                on_frontier[i] = false                 # remove from queue (cone[i] already true since push)
                if i > nbopb
                    rule_type = systemlink[i - nbopb][1]   # rule type: -1=rup, -2=pol, -3=ia, -4=red, ...
                    if rule_type == -1                              # rup
                        sub = get(meta.subof, i, 0:0)       # a deletion subproof is checked against the core only
                        if do_rup!(i, sub; core_only = sk && sub != 0:0)
                            ante_remove!(ante, i)              # i itself is not its own antecedent
                            ante_into_frontier!(ante, frontier, on_frontier, cone, systemlink, i - nbopb)
                        else
                            printstyled("  [error] rup failed at $i\n"; color=:red)
                            return
                        end
                    elseif rule_type >= -3 || (rule_type == -30 && length(systemlink[i - nbopb]) > 1)  # pol / ia / assumption with hints
                        ante_clear!(ante)
                        fixante(systemlink, ante, i - nbopb)
                        let lnk = sl_get_mut!(systemlink, i - nbopb)
                            fixconelits(sys, conelits, i, ante, lnk)
                            removetrivialantecedents(sys, ante, conelits, lnk, i)
                        end
                        ante_into_frontier!(ante, frontier, on_frontier, cone)
                    elseif rule_type == -10                         # end of red subproof
                        red = redwitness[i]
                        red.range.start == 0 && continue            # parser sets range when "end" parsing is implemented
                        push_frontier!(frontier, on_frontier, cone, red.range.start)  # red declaration itself
                        for subr in red.proof_goal_ranges
                            if systemlink[subr.start - nbopb][1] == -8 && !cone[subr.start]
                                push!(pfgl, subr)              # defer: ref constraint not yet in cone
                            else
                                push_frontier!(frontier, on_frontier, cone, subr.start)
                                push_frontier!(frontier, on_frontier, cone, subr.stop)
                            end
                        end
                    elseif rule_type == -5                          # subproof rup
                        subran_idx = findfirst(x -> i in x, red.proof_goal_ranges)
                        if do_rup!(i, red.proof_goal_ranges[subran_idx])
                            ante_remove!(ante, i)
                            ante_into_frontier!(ante, frontier, on_frontier, cone, systemlink, i - nbopb)
                        else
                            printstyled("  [error] subproof rup failed\n"; color=:red)
                        end
                    elseif rule_type == -6 || rule_type == -8           # subproof pol / proofgoal ref
                        ante_clear!(ante)
                        fixante(systemlink, ante, i - nbopb)
                        ante_into_frontier!(ante, frontier, on_frontier, cone)
                    elseif rule_type == -7                          # proofgoal #1: no external antecedents
                    end
                end
            end
            for r in pfgl                              # revisit deferred proof goals now that more cone is known
                id = systemlink[r.start - nbopb][2]
                if cone[id] && !cone[r.start]          # ref is now in cone: safe to schedule this proof goal
                    push_frontier!(frontier, on_frontier, cone, r.start)
                    push_frontier!(frontier, on_frontier, cone, r.stop)
                    newpfgl = true
                end
            end
        end
        isempty(meta.subof) && fixredsystemlink(systemlink, cone, prism, nbopb) end # propagate subproof antecedents up to red declarations

    function getfirstcontradiction(sys::PBSystem, prism)
        assi = zeros(Int8, length(sys.var_ptr) - 1)
        for e in eachindex(sys.rhs)
            !inprism(e, prism) && slack(sys, e, assi) < 0 && return e
        end
        return 0 end

    function eqmatch(sys::PBSystem, e::Int, eq::Eq)
        sys.rhs[e] != eq.rhs && return false
        r = eqrange(sys, e)
        length(r) != length(eq.lits) && return false
        for (i, lit) in zip(r, eq.lits)
            (sys.vars[i] != lit.var || sys.coefs[i] != lit.coef || sys.signs[i] != lit.sign) && return false
        end
        return true end

    function getfirstboundeq(sys::PBSystem, obj, conclusion::String, cone::BitVector)
        st = split(conclusion, keepempty=false) # conclusion BOUNDS 10 20   ||  10 : id 20 : id
        ub = 0; lb = parse(Int, st[3])
        if length(st) > 3
            if st[4] != ":"
                ub = parse(Int, st[4])
            else
                i = findlast(x -> x == ":", st)
                if i != 4
                    ub = parse(Int, st[i-1])
                end
            end
        end
        lbctr = Eq(obj, lb)
        ubctr = negatecoefs(Eq(obj, ub)); normcoefeq(ubctr)
        lbid = ubid = 0
        for e in eachindex(sys.rhs)
            if lbid == 0 && eqmatch(sys, e, lbctr)
                lbid = e
            end
            if ubid == 0 && eqmatch(sys, e, ubctr)
                ubid = e
            end
            lbid > 0 && ubid > 0 && break
        end
        if ubid > 0 cone[ubid] = true end
        return lbid end

    function negatecoefs(eq::Eq)
        lits = [Lit(-l.coef, l.sign, l.var) for l in eq.lits]
        return Eq(lits,-eq.rhs) end
