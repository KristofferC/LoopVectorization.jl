

function load_constrained(op, u₁loop, u₂loop, innermost_loop_or_vloop, forprefetch = false)
    dependsonu₁ = isu₁unrolled(op)
    dependsonu₂ = isu₂unrolled(op)
    if forprefetch
        (dependsonu₁ & dependsonu₂) || return false
    end
    unrolleddeps = Symbol[]
    if forprefetch # innermost_loop_or_vloop is innermost_loop
        push!(unrolleddeps, innermost_loop_or_vloop)
    else# if this is for `sub_fmas` instead of prefetch, then `innermost_loop_or_vloop` is `vloop`, and we only care if it isn't vectorized
        # if it is vectorized, it can't be broadcasted on AVX512 anyway, so no point trying to enable that optimization
        dependsonu₁ &= u₁loop !== innermost_loop_or_vloop
        dependsonu₂ &= u₂loop !== innermost_loop_or_vloop
    end
    dependsonu₁ && push!(unrolleddeps, u₁loop)
    dependsonu₂ && push!(unrolleddeps, u₂loop)
    length(unrolleddeps) > 0 || return false
    any(parents(op)) do opp
        isload(opp) && all(in(loopdependencies(opp)), unrolleddeps)
    end
end
function check_if_remfirst(ls, ua)
    usorig = ls.unrollspecification[]
    @unpack u₁, u₁loopsym, u₂loopsym, u₂max = ua
    u₁loop = getloop(ls, u₁loopsym)
    u₂loop = getloop(ls, u₂loopsym)
    if isstaticloop(u₁loop) && (usorig.u₁ != u₁)
        return true
    end
    if isstaticloop(u₂loop) && (usorig.u₂ != u₂max)
        return true
    end
    false
end
function sub_fmas(ls::LoopSet, op::Operation, ua::UnrollArgs)
    @unpack u₁, u₁loopsym, u₂loopsym, vloopsym, u₂max = ua
    !(load_constrained(op, u₁loopsym, u₂loopsym, vloopsym) || check_if_remfirst(ls, ua))
end

struct FalseCollection end
Base.getindex(::FalseCollection, i...) = false
function parent_unroll_status(op::Operation, u₁loop::Symbol)
    map(opp -> isunrolled_sym(opp, u₁loop), parents(op)), fill(false, length(parents(op)))
end
function parent_unroll_status(op::Operation, u₁loop::Symbol, u₂loop::Symbol, vloop::Symbol, u₂max::Int)
    # u₂max ≥ 0 || return parent_unroll_status(op, u₁loop)
    u₂max == -1 && return parent_unroll_status(op, u₁loop)
    vparents = parents(op);
    # parent_names = Vector{Symbol}(undef, length(vparents))
    parents_u₁syms = Vector{Bool}(undef, length(vparents))
    parents_u₂syms = Vector{Bool}(undef, length(vparents))
    for i ∈ eachindex(vparents)
        parents_u₁syms[i], parents_u₂syms[i] = isunrolled_sym(vparents[i], u₁loop, u₂loop, vloop)#, u₂max)
    end
    # parent_names, parents_u₁syms, parents_u₂syms
    parents_u₁syms, parents_u₂syms
end

function _add_loopvalue!(ex::Expr, loopval::Symbol, vloop::Loop, u::Int)
    vloopsym = vloop.itersymbol
    if loopval === vloopsym
        if iszero(u)
            push!(ex.args, _MMind(Expr(:call, lv(:staticp1), loopval), step(vloop)))
        else
            mm = _MMind(Expr(:call, lv(:staticp1), loopval), step(vloop))
            if isone(u)
                push!(ex.args, Expr(:call, lv(:vadd_fast), VECTORWIDTHSYMBOL, mm))
            else
                push!(ex.args, Expr(:call, lv(:vadd_fast), Expr(:call, lv(:vmul_fast), VECTORWIDTHSYMBOL, u), mm))
            end
        end
    else
        push!(ex.args, Expr(:call, lv(:vadd_fast), loopval, staticexpr(u+1)))
    end
end
function add_loopvalue!(instrcall::Expr, loopval, ua::UnrollArgs, u₁::Int)
    @unpack u₁loopsym, u₂loopsym, vloopsym, vloop, suffix = ua
    if loopval === u₁loopsym #parentsunrolled[n]
        if isone(u₁)
            _add_loopvalue!(instrcall, loopval, vloop, 0)
        else
            t = Expr(:tuple)
            for u ∈ 0:u₁-1
                _add_loopvalue!(t, loopval, vloop, u)
            end
            push!(instrcall.args, Expr(:call, lv(:VecUnroll), t))
        end
    elseif suffix > 0 && loopval === u₂loopsym
        _add_loopvalue!(instrcall, loopval, vloop, suffix)
    elseif loopval === vloopsym
        push!(instrcall.args, _MMind(Expr(:call, lv(:staticp1), loopval), step(vloop)))
    else
        push!(instrcall.args, Expr(:call, lv(:staticp1), loopval))
    end
end

vecunrolllen(::Type{VecUnroll{N,W,T,V}}) where {N,W,T,V} = (N::Int + 1)
vecunrolllen(_) = -1
function ifelselastexpr(hasf::Bool, M::Int, vargtypes, K::Int, S::Int, maskearly::Bool)
    q = Expr(:block, Expr(:meta,:inline))
    vargs = map(k -> Symbol(:varg_,k), 1:K)
    lengths = Vector{Int}(undef, K);
    for k ∈ 1:K
        lengths[k] = l = vecunrolllen(vargtypes[k])
        if hasf
            gfvarg = Expr(:call, GlobalRef(Core, :getfield), :vargs, k, false)
            if l ≠ -1 # VecUnroll
                gfvarg = Expr(:call, GlobalRef(Core, :getfield), gfvarg, 1, false)
            end
            push!(q.args, Expr(:(=), vargs[k], gfvarg))
        elseif l ≠ -1
            varg = vargs[k]
            vargs[k] = dvarg = Symbol(:d, varg)
            push!(q.args, :($dvarg = data($varg)))
        end
    end
    N = last(lengths)
    start = (hasf | maskearly) ? 1 : M
    Sreduced = (S > 0) && (lengths[S] == -1)
    if Sreduced
        maxlen = maximum(lengths)
        if maxlen == -1
            Sreduced = false
            t = Expr(:tuple)
        else
            hasf || throw(ArgumentError("Argument reduction only supported for `ifelse(last/partial)(f::Function, args...)`"))
            M = maxlen
            t = q
        end
    else
        t = Expr(:tuple)
    end
    for m ∈ 1:start-1
        push!(t.args, :(getfield($(vargs[1]), $m, false)))
    end
    for m ∈ start:M
        call = if hasf
            (maskearly | (m == M)) ? Expr(:call, :ifelse, :f, :m) : Expr(:call, :f)
        else# m == M because !hasf
            Expr(:call, :ifelse, :m)
        end
        for k ∈ 1:K
            if lengths[k] == -1
                push!(call.args, vargs[k])
            else
                # @assert (k == K) || (lengths[k] == M)
                push!(call.args, :(getfield($(vargs[k]), $m, false)))
            end
        end
        if Sreduced
            push!(t.args, Expr(:(=), vargs[S], call))
        elseif N == -1
            push!(q.args, call)
            return q
        else
            push!(t.args, call)
        end
    end
    Sreduced && return q
    for m ∈ M+1:N
        push!(t.args, :(getfield($(vargs[K]), $m, false)))
    end
    # push!(q.args, :(VecUnroll($t)::VecUnroll{$N,$W,$T,$V}))
    # push!(q.args, Expr(:call, lv(:VecUnroll), t))
    push!(q.args, :(VecUnroll($t)))
    q
end
@generated function ifelselast(f::F, m::AbstractMask{W}, ::StaticInt{M}, ::StaticInt{S}, vargs::Vararg{Any,K}) where {F,W,K,M,S}
    1+1
    ifelselastexpr(true, M, vargs, K, S, false)
end
@generated function ifelselast(m::AbstractMask{W}, ::StaticInt{M}, ::StaticInt{S}, varg_1::V1, varg_2::V2) where {W,V1,V2,M,S}
    1+1
    ifelselastexpr(false, M, (V1,V2), 2, S, false)
end
@generated function ifelsepartial(f::F, m::AbstractMask{W}, ::StaticInt{M}, ::StaticInt{S}, vargs::Vararg{Any,K}) where {F,W,K,M,S}
    1+1
    ifelselastexpr(true, M, vargs, K, S, true)
end
@generated function ifelsepartial(m::AbstractMask{W}, ::StaticInt{M}, ::StaticInt{S}, varg_1::V1, varg_2::V2) where {W,V1,V2,M,S}
    1+1
    ifelselastexpr(false, M, (V1,V2), 2, S, true)
end
@generated function subset_vec_unroll(vu::VecUnroll{N}, ::StaticInt{S}) where {N,S}
    (1 ≤ S ≤ N + 1) || throw(ArgumentError("`vu` isa `VecUnroll` of `$(N+1)` elements, but trying to subset $S of them."))
    t = Expr(:tuple)
    gf = GlobalRef(Core,:getfield)
    S == 1 && return Expr(:block, Expr(:meta,:inline), :($gf($gf(vu,1),1,false)))
    for s ∈ 1:S
        push!(t.args, Expr(:call, gf, :vud, s, false))
    end
    quote
        $(Expr(:meta,:inline))
        vud = $gf(vu, 1)
        VecUnroll($t)
    end
end
# `S` is the ind to replace with the return value of previous invocation ("S" for "self") if reducing
@generated function partialmap(f::F, default::D, ::StaticInt{M}, ::StaticInt{S}, vargs::Vararg{Any,K}) where {F,M,K,D,S}
    lengths = Vector{Int}(undef, K);
    q = Expr(:block, Expr(:meta,:inline))
    syms = Vector{Symbol}(undef, K)
    isnotpartial = true
    gf = GlobalRef(Core, :getfield)
    for k ∈ 1:K
        l = vecunrolllen(vargs[k])
        # if l
        kisnotpartial = ((l ≡ -1) & (k ≢ S)) | (l ≡ M)
        isnotpartial &= kisnotpartial
        lengths[k] = l
        @assert (l == -1) || (l ≥ M)
        syms[k] = symk = Symbol(:vargs_,k)
        extractq = :($gf(vargs, $k, false))
        if l != -1
            extractq = :(data($extractq))
        end
        push!(q.args, :($symk = $extractq))
    end
    Dlen = vecunrolllen(D)
    N = maximum(lengths)
    Sreduced = (S > 0) && (lengths[S] == -1) && N != -1
    if isnotpartial & (Sreduced | (Dlen == N))
        q =  Expr(:call, :f)
        for k ∈ 1:K
            push!(q.args, :($gf(vargs, $k, false)))
        end
        return Expr(:block, Expr(:meta, :inline), q)
    end
    if Sreduced
        M = N
        t = q
    else
        @assert (N ≤ Dlen)
        if Dlen == -1
            @assert (M == 1)
        else
            push!(q.args, :(dd = data(default)))
        end
        t = Expr(:tuple)
    end
    for m ∈ 1:M
        call = Expr(:call, :f)
        for k ∈ 1:K
            if lengths[k] == -1
                push!(call.args, syms[k])
            else
                push!(call.args, Expr(:call, gf, syms[k], m, false))
            end
        end
        # minimal change in behavior to fix case when !Sreduced by N -> Dlen; TODO: what should Dlen be here?
        if Sreduced ? (N == -1) : (Dlen == -1) 
            push!(q.args, call)
            return q
        end
        if Sreduced
            push!(t.args, Expr(:(=), syms[S], call))
        else
            push!(t.args, call)
        end
    end
    Sreduced && return q
    for m ∈ M+1:max(N,Dlen)
        push!(t.args, :($gf(dd, $m, false)))
    end
    push!(q.args, :(VecUnroll($t)))
    q
end

function parent_op_name(
    ls::LoopSet, parents_op::Vector{Operation}, n::Int, modsuffix, suffix_, parents_u₁syms, parents_u₂syms, u₁, opisvectorized, tiledouterreduction
)
    opp = parents_op[n]
    parent = mangledvar(opp)
    u = 0
    if n == tiledouterreduction
        parent = Symbol(parent, modsuffix)
    else
        if parents_u₂syms[n]
            parent = Symbol(parent, suffix_)
        end
        u = if !parents_u₁syms[n]
            1
        elseif isouterreduction(ls, opp) ≠ -1
            getu₁full(ls, u₁)
        else
            getu₁forreduct(ls, opp, u₁)
        end
        parent = Symbol(parent, '_', u)
    end
    if opisvectorized && isload(opp) && (!isvectorized(opp))
        parent = Symbol(parent, "##broadcasted##")
    end
    parent, u
end
function getuouterreduct(ls::LoopSet, op::Operation, suffix)
    us = ls.unrollspecification[]
    if us.vloopnum === us.u₁loopnum # unroll u₂
        suffix
    else # unroll u₁
        us.u₁
    end
end

function getu₁full(ls::LoopSet, u₁::Int)
    Ureduct = ureduct(ls)
    ufull = if Ureduct == -1 # no reducing
        ls.unrollspecification[].u₁
    else
        Ureduct
    end
    # max is because we may be in the extended (non-reduct) region
    return max(u₁, ufull)
end
function getu₁forreduct(ls::LoopSet, op::Operation, u₁::Int)
    !isu₁unrolled(op) && return 1
    # if `op` is u₁unrolled, we must then find out if the initialization is `u₁unrolled`
    # if it is, then op's `u₁` will be the current `u₁`
    # if it is not, then the opp is initialized once per full u₁
    while true
        selfparentid = findfirst(Base.Fix2(===,name(op)) ∘ name, parents(op))
        selfparentid === nothing && return u₁
        op = parents(op)[selfparentid]
        isreduction(op) || break
    end
    if isu₁unrolled(op)
        return u₁
    elseif (ls.unrollspecification[].u₂ != -1) && length(ls.outer_reductions) > 0
        # then `ureduct` doesn't tell us what we need, so
        return ls.unrollspecification[].u₁
    else # we need to find u₁-full
        return getu₁full(ls, u₁)
    end    
end

function lower_compute!(
    q::Expr, op::Operation, ls::LoopSet, ua::UnrollArgs, mask::Bool
)
    @unpack u₁, u₁loopsym, u₂loopsym, vloopsym, u₂max, suffix = ua
    var = name(op)
    instr = instruction(op)
    parents_op = parents(op)
    nparents = length(parents_op)
    # __u₂max = ls.unrollspecification[].u₂
    # TODO: perhaps allos for swithcing unrolled axis again
    # mvar, u₁unrolledsym, u₂unrolledsym = variable_name_and_unrolled(op, u₁loopsym, u₂loopsym, vloopsym, u₂max, suffix)
    mvar, u₁unrolledsym, u₂unrolledsym = variable_name_and_unrolled(op, u₁loopsym, u₂loopsym, vloopsym, suffix)
    opunrolled = u₁unrolledsym || isu₁unrolled(op)
    # parent_names, parents_u₁syms, parents_u₂syms = parent_unroll_status(op, u₁loop, u₂loop, suffix)
    parents_u₁syms, parents_u₂syms = parent_unroll_status(op, u₁loopsym, u₂loopsym, vloopsym, u₂max)
    # tiledouterreduction = if num_loops(ls) == 1# (suffix == -1)# || (vloopsym === u₂loopsym)
    tiledouterreduction = if (suffix == -1)# || (vloopsym === u₂loopsym)
        suffix_ = Symbol("")
        -1
    else
        suffix_ = Symbol(suffix, :_)
        isouterreduction(ls, op)
    end
    if !opunrolled && any(parents_u₁syms) # TODO: Clean up this mess, refactor the naming code, putting it in one place and have everywhere else use it for easy equivalence.
        parents_op = copy(parents_op) # don't mutate the original!
        for i ∈ eachindex(parents_u₁syms)
            parents_u₁syms[i] || continue
            parents_u₁syms[i] = false
            parentop = parents_op[i]
            i == tiledouterreduction && isconstant(parentop) && continue
            newparentop = Operation(
                parentop.identifier, gensym(parentop.variable), parentop.elementbytes, parentop.instruction, parentop.node_type,
                parentop.dependencies, parentop.reduced_deps, parentop.parents, parentop.ref, parentop.reduced_children
            )
            parentname = mangledvar(parentop)
            newparentname = mangledvar(newparentop)
            parents_op[i] = newparentop
            if parents_u₂syms[i]
                parentname = Symbol(parentname, suffix_)
                newparentname = Symbol(newparentname, suffix_)
            end
            if isconstant(newparentop)
                push!(q.args, Expr(:(=), Symbol(newparentname, '_', 1), Symbol(parentname, '_', 1)))
            else
                newpname = Symbol(newparentname, '_', u₁)
                push!(q.args, Expr(:(=), newpname, Symbol(parentname, '_', u₁)))
                reduce_expr!(q, newparentname, instruction(newparentop), u₁, -1, true, false)
                push!(q.args, Expr(:(=), Symbol(newparentname, '_', 1), Symbol(newparentname, "##onevec##")))
            end
        end
    end
    # if suffix === nothing# &&
    # end
    # cache unroll and tiling check of parents
    # not broadcasted, because we use frequent checks of individual bools
    # making BitArrays inefficient.
    # parentsyms = [opp.variable for opp ∈ parents(op)]
    Uiter = opunrolled ? u₁ - 1 : 0
    isreduct = isreduction(op)
    # if isreduct
    #     @show u₁unrolledsym, u₂unrolledsym, isu₁unrolled(op), isu₂unrolled(op) op
    # end
    if Base.libllvm_version < v"11.0.0" && (suffix ≠ -1) && isreduct# && (iszero(suffix) || (ls.unrollspecification[].u₂ - 1 == suffix))
    # if (length(reduceddependencies(op)) > 0) | (length(reducedchildren(op)) > 0)# && (iszero(suffix) || (ls.unrollspecification[].u₂ - 1 == suffix))
        # instrfid = findfirst(isequal(instr.instr), (:vfmadd, :vfnmadd, :vfmsub, :vfnmsub))
        instrfid = findfirst(Base.Fix2(===,instr.instr), (:vfmadd_fast, :vfnmadd_fast, :vfmsub_fast, :vfnmsub_fast))
        # instrfid = findfirst(isequal(instr.instr), (:vfnmadd_fast, :vfmsub_fast, :vfnmsub_fast))
        # want to instcombine when parent load's deps are superset
        # also make sure opp is unrolled
        if !(instrfid === nothing) && (opunrolled && u₁ > 1) && sub_fmas(ls, op, ua)
            specific_fmas = Base.libllvm_version >= v"11.0.0" ? (:vfmadd, :vfnmadd, :vfmsub, :vfnmsub) : (:vfmadd231, :vfnmadd231, :vfmsub231, :vfnmsub231)
            # specific_fmas = Base.libllvm_version >= v"11.0.0" ? (:vfnmadd, :vfmsub, :vfnmsub) : (:vfnmadd231, :vfmsub231, :vfnmsub231)
            # specific_fmas = (:vfmadd231, :vfnmadd231, :vfmsub231, :vfnmsub231)
            instr = Instruction(specific_fmas[instrfid])
        end
    end
    reduceddeps = reduceddependencies(op)
    vecinreduceddeps = isreduct && vloopsym ∈ reduceddeps
    maskreduct = mask & vecinreduceddeps #any(opp -> opp.variable === var, parents_op)
    # if vecinreduceddeps && vectorized ∉ loopdependencies(op) # screen parent opps for those needing a reduction to scalar
    #     # parents_op = reduce_vectorized_parents!(q, op, parents_op, U, u₁loopsym, u₂loopsym, vectorized, suffix)
    #     isreducingidentity!(q, op, parents_op, U, u₁loopsym, u₂loopsym, vectorized, suffix) && return
    # end    
    # if a parent is not unrolled, the compiler should handle broadcasting CSE.
    # because unrolled/tiled parents result in an unrolled/tiled dependendency,
    # we handle both the tiled and untiled case here.
    # bajillion branches that go the same way on each iteration
    # but smaller function is probably worthwhile. Compiler could theoreically split anyway
    # but I suspect that the branches are so cheap compared to the cost of everything else going on
    # that smaller size is more advantageous.
    opisvectorized = isvectorized(op)
    modsuffix = 0
    # for u ∈ 0:Uiter
    isouterreduct = false
    instrcall = callexpr(instr)
    dopartialmap = false
    varsym = if tiledouterreduction > 0 # then suffix ≠ -1
        # modsuffix = ((u + suffix*(Uiter + 1)) & 7)
        isouterreduct = true
        # if u₁unrolledsym
        #     modsuffix = ls.unrollspecification[].u₁#getu₁full(ls, u₁)#u₁
        #     Symbol(mangledvar(op), '_', modsuffix)
        # else
        modsuffix = 0#suffix % tiled_outerreduct_unroll(ls)
        Symbol(mangledvar(op), modsuffix)
        # end
        # dopartialmap = u₁ > 1

        # Symbol(mvar, modsuffix)
        # elseif u₁unrolledsym
        #     Symbol(mvar, u)
    elseif u₁unrolledsym
        if isreduct #(isanouterreduction(ls, op))
            # isouterreduct = true
            isouterreduct = isanouterreduction(ls, op)
            u₁reduct = isouterreduct ? getu₁full(ls, u₁) : getu₁forreduct(ls, op, u₁)
            # @show isouterreduct, u₁reduct, op
            dopartialmap = u₁reduct ≠ u₁
            Symbol(mvar, '_', u₁reduct)
        else
            Symbol(mvar, '_', u₁)
        end
    else
        Symbol(mvar, '_', 1)
    end
    selfopname = varsym
    selfdep = 0
    for n ∈ 1:nparents
        opp = parents_op[n]
        if isloopvalue(opp)
            loopval = first(loopdependencies(opp))
            add_loopvalue!(instrcall, loopval, ua, u₁)
        elseif name(opp) === name(op)
            selfdep = n
            if ((isvectorized(first(parents_op)) && !isvectorized(op)) && !dependent_outer_reducts(ls, op)) ||
                (parents_u₁syms[n] != u₁unrolledsym) || (parents_u₂syms[n] != u₂unrolledsym)
                
                selfopname, uₚ = parent_op_name(ls, parents_op, n, modsuffix, suffix_, parents_u₁syms, parents_u₂syms, u₁, opisvectorized, tiledouterreduction)
                # if (uₚ ≠ 0) & (uₚ ≠ u₁)
                #     dopartialmap = true
                # end
                push!(instrcall.args, selfopname)
            else
                push!(instrcall.args, varsym)
            end
        elseif ((!isu₂unrolled(op)) & isu₂unrolled(opp)) && (isouterreduction(ls, opp) != -1)
            # this checks if the parent is u₂ unrolled but this operation is not, in which case we need to reduce it.
            push!(instrcall.args, reduce_expr_u₂(mangledvar(opp), instruction(opp), ureduct(ls)))
        else
            parent, uₚ = parent_op_name(ls, parents_op, n, modsuffix, suffix_, parents_u₁syms, parents_u₂syms, u₁, opisvectorized, tiledouterreduction)
            # if name(op) === Symbol("##op#9536")
            #     @show parent
            # end
            if (selfdep == 0) && search_tree(parents(opp), name(op))
                selfdep = n
                push!(instrcall.args, parent)
            elseif (uₚ ≠ 0) & (uₚ > u₁)
                push!(instrcall.args, :(subset_vec_unroll($parent, StaticInt{$u₁}())))
            else
                push!(instrcall.args, parent)
            end

            # @show uₚ, u₁, op
        end
    end
    selfdepreduce = ifelse(((!u₁unrolledsym) & isu₁unrolled(op)) & (u₁ > 1), selfdep, 0)
    # if selfdep ≠ 0
    #     @show mvar
    #     # @show isu₁unrolled(op), u₁unrolledsym, u₁, u₂max
    #     # @show selfdep, selfdepreduce#, op
    # end
    # push!(q.args, (isreduct, u₁, (!u₁unrolledsym), isu₁unrolled(op), dopartialmap, varsym))
    if maskreduct
        ifelsefunc = if ls.unrollspecification[].u₁ == 1
            :ifelse # don't need to be fancy
        elseif (u₁loopsym !== vloopsym)
            :ifelsepartial # ifelse all the early ones
        else# mask last u₁
            :ifelselast # ifelse only the last one
        end
        if last(instrcall.args) == varsym
            pushfirst!(instrcall.args, lv(ifelsefunc))
            # showexpr = true
            insert!(instrcall.args, 3, MASKSYMBOL)
            if !(ifelsefunc === :ifelse)
                insert!(instrcall.args, 4, staticexpr(u₁))
                insert!(instrcall.args, 5, staticexpr(selfdepreduce))
            end
        elseif all(in(loopdependencies(op)), reduceddeps) || any(opp -> mangledvar(opp) === mangledvar(op), parents_op)
            # Here, we are evaluating the function, and then `ifelse`-ing it with `hasf == false`.
            # That means we still need to adjust the `instrcall` in case we're reducing/accumulating across the unroll
            if ifelsefunc ≡ :ifelse # ifelse means it's unrolled by 1, no need
                # push!(q.args, Expr(:(=), varsym, Expr(:call, lv(ifelsefunc), MASKSYMBOL, instrcall, selfopname)))
                push!(q.args, Expr(:(=), varsym, Expr(:call, lv(ifelsefunc), MASKSYMBOL, instrcall, selfopname)))
            elseif ((u₁ ≡ 1) | (selfdepreduce ≡ 0))
                # if the current unroll is 1, no need to accumulate. Same if there is no selfdepreduce, but there has to be if we're here?
                # push!(q.args, Expr(:(=), varsym, Expr(:call, lv(ifelsefunc), MASKSYMBOL, staticexpr(u₁), staticexpr(selfdepreduce), instrcall, selfopname)))
                push!(q.args, Expr(:(=), varsym, Expr(:call, lv(ifelsefunc), MASKSYMBOL, staticexpr(u₁), staticexpr(selfdepreduce), instrcall, selfopname)))
            else
                make_partial_map!(instrcall, selfopname, u₁, selfdepreduce)
                # partialmap accumulates
                push!(q.args, Expr(:(=), varsym, Expr(:call, lv(:ifelse), MASKSYMBOL, instrcall, selfopname)))
            end
            return
        elseif selfdep != 0
            # @show op, isouterreduct, maskreduct, instr
            make_partial_map!(instrcall, selfopname, u₁, selfdepreduce)
        end
    elseif selfdep != 0 && (dopartialmap ||
        (isouterreduct && (opunrolled) && (u₁ < ls.unrollspecification[].u₁)) ||
        (isreduct & (u₁ > 1) & (!u₁unrolledsym) & isu₁unrolled(op))) # TODO: DRY `selfdepreduce` definition
        # first possibility (`isouterreduct && opunrolled && (u₁ < ls.unrollspecification[].u₁)`):
        # checks if we're in the "reduct" part of an outer reduction
        #
        # second possibility (`(isreduct & (u₁ > 1) & (!u₁unrolledsym) & isu₁unrolled(op))`):
        # if the operation is repeated across u₁ (indicated by `isu₁unrolled(op)`) but
        # the variables are not correspondingly replicated across u₁ (indicated by `!u₁unrolledsym`)
        # then we need to accumulate it.
        make_partial_map!(instrcall, selfopname, u₁, selfdepreduce)
    # elseif 
    end
    if instr.instr === :identity && isone(length(parents_op))
        if instrcall.args[2] !== varsym
            push!(q.args, Expr(:(=), varsym, instrcall.args[2]))
        end
    elseif identifier(op) ∉ ls.outer_reductions && should_broadcast_op(op)
        push!(q.args, Expr(:(=), varsym, Expr(:call, lv(:vbroadcast), VECTORWIDTHSYMBOL, instrcall)))
    else
        push!(q.args, Expr(:(=), varsym, instrcall))
    end
    # end
end
function make_partial_map!(instrcall, selfopname, u₁, selfdep)
    pushfirst!(instrcall.args, lv(:partialmap))
    insert!(instrcall.args, 3, selfopname)
    insert!(instrcall.args, 4, staticexpr(u₁))
    insert!(instrcall.args, 5, staticexpr(selfdep))
    nothing
end
