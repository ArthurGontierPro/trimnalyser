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

            # Trail-based unit propagation.
    function propagate!(sys::PBSystem, t::Trail, prism, ante::Ante, conelits, rs::RupState, cone::BitVector)
        init_slack_cache!(t, sys)
        i = 1; n = length(sys.rhs)
        que = trues(n)                                # all constraints initially pending
        while i <= n
            if !inprism(i, prism) && que[i]
                s = slack_cached(t, i)
                if s < 0                               # falsified: record conflict and stop
                    conflicttrail(i, sys, t, ante, conelits, rs, Grim(), cone)
                    return
                end
                que[i] = false
                rewind = i + 1                         # will jump back to earliest newly-triggered eq
                @inbounds for k in eqrange(sys, i)
                    v = Int(sys.vars[k])
                    t.assi[v] != 0 && continue         # already assigned
                    sys.coefs[k] > s || continue       # coef too small to force propagation
                    pushtrail!(t, sys, Int32(v), Int32(i), sys.signs[k] ? Int8(1) : Int8(2))
                    for j in varrange(sys, v)
                        eid = Int(sys.var_eqs[j])
                        que[eid] = true
                        rewind = min(rewind, eid)      # re-scan from earliest affected constraint
                    end
                end
                i = rewind
            else
                i += 1
            end
        end
        printstyled("  [error] propagate! found no conflict\n"; color=:red) end

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
            for j in varrange(sys, v)
                eid = Int(sys.var_eqs[j])
                (eid <= init && eid != i) || continue               # only earlier/unrelated eqs
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
                      cone::BitVector, conelits, prism, subrange, rs::RupState, mode=Grim())
        init_slack_cache!(t, sys)
        fill!(rs.que, false)               # reset queue (may have stale trues from early return)
        empty!(rs.pq_prio); empty!(rs.pq_nonprio)
        for i in 1:init                    # seed both heaps with all eligible equations
            (!inprism(i, prism) || (i in subrange)) || continue
            activate!(i, rs, cone, on_frontier)
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

    function getcone!(cone, conelits, sys::PBSystem, systemlink, nbopb::Int,
                      prism::Vector{UnitRange{Int64}}, redwitness, conclusion::String, obj, mode)
        n    = length(sys.rhs)
        prism_bv = falses(n)
        for r in prism, i in r
            1 <= i <= n && (prism_bv[i] = true)       # bitvector version of prism for O(1) inprism checks
        end
        on_frontier = falses(n)                          # true = constraint is scheduled in frontier
        trail      = Trail(length(sys.var_ptr) - 1)    # var_ptr has length n_vars+1 (CSR convention)

        firstcontradiction = 0                         # root of the backward reachability
        if conclusion == "UNSAT"
            firstcontradiction = getfirstcontradiction(sys, prism_bv)
        elseif occursin("BOUNDS", conclusion)
            firstcontradiction = getfirstboundeq(sys, obj, conclusion, cone)
        end
        if firstcontradiction == 0
            conclusion == "UNSAT" && printstyled("  [error] UNSAT contradiction not found\n"; color=:red)
            return
        end

        ante = Ante(n)
        rs   = RupState(n, length(sys.var_ptr) - 1)   # reusable scratch buffers for rup/conflict analysis
        mode isa Clit && compute_essentials!(rs.essentials, sys)  # forward pass: essential vars per constraint
        frontier = BinaryMaxHeap{Int}()                # max-heap: process highest-indexed eq first (backwards)

        # Local function: clear ante, reset trail, run rup. i and subrange are parameters (not captured)
        # to avoid Julia boxing mutable loop variables. Everything else is captured from getcone! scope.
        function do_rup!(i, subrange)
            ante_clear!(ante)
            reset!(trail)
            ruptrail(sys, i, trail, ante, on_frontier, cone, conelits, prism_bv, subrange, rs, mode)
        end

        cone[firstcontradiction] = true
        if systemlink[firstcontradiction - nbopb][1] == -2   # contradiction is a pol: antecedents explicit in link
            for j in systemlink[firstcontradiction - nbopb]
                j > 0 && push_frontier!(frontier, on_frontier, cone, j)
            end
        else                                           # contradiction is rup/ia: run propagation to find antecedents
            if conclusion == "UNSAT" || conclusion == "NONE"
                propagate!(sys, trail, prism_bv, ante, conelits, rs, cone)
            elseif occursin("BOUNDS", conclusion)
                if !do_rup!(firstcontradiction, 0:0) printstyled("  [error] initial rup for bound contradiction failed\n"; color=:red) end
            end
            ante_into_frontier!(ante, frontier, on_frontier, cone, systemlink, firstcontradiction - nbopb)
        end
        red     = Red([], 0:0, [])                     # current red block being processed
        pfgl    = UnitRange{Int64}[]                   # deferred proof goals (ref not yet known to be in cone)
        newpfgl = true
        while newpfgl                                  # outer loop: retry deferred proof goals until stable
            newpfgl = false
            while !isempty(frontier)
                i = pop!(frontier)
                on_frontier[i] || continue             # stale pop guard
                on_frontier[i] = false                 # remove from queue (cone[i] already true since push)
                if i > nbopb
                    rule_type = systemlink[i - nbopb][1]   # rule type: -1=rup, -2=pol, -3=ia, -4=red, ...
                    if rule_type == -1                              # rup
                        if do_rup!(i, 0:0)
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
        fixredsystemlink(systemlink, cone, prism, nbopb) end # propagate subproof antecedents up to red declarations

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
