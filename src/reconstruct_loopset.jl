const NOpsType = Int#Union{Int,Vector{Int}}

function Loop(ls::LoopSet, ex::Expr, sym::Symbol, f, s, l)
    if (f !== nothing) && (s !== nothing) && (l !== nothing)
        return static_loop(sym, f, s, l)
    end
    ssym = String(sym)
    rangesym = gensym(ssym * "_loop");
    lensym = gensym(ssym * "_looplen")
    pushpreamble!(ls, Expr(:(=), rangesym, ex))
    pushpreamble!(ls, Expr(:(=), lensym, Expr(:call, lv(:maybestaticlength), rangesym)))
    F = if f === nothing
        start = gensym(ssym*"_loopstart")
        pushpreamble!(ls, Expr(:(=), start, Expr(:call, lv(:first), rangesym)))
        MaybeKnown(start, 1)
    else
        MaybeKnown(f)
    end
    S = if s === nothing
        step = gensym(ssym*"_loopstep")
        pushpreamble!(ls, Expr(:(=), step, Expr(:call, lv(:step), rangesym)))
        MaybeKnown(step, 1)
    else
        MaybeKnown(s)
    end
    L = if l === nothing
        stop = gensym(ssym*"_loopstop")
        pushpreamble!(ls, Expr(:(=), stop, Expr(:call, lv(:last), rangesym)))
        MaybeKnown(stop, 1024)
    else
        MaybeKnown(l)
    end
    loopiteratesatleastonce!(ls, Loop(sym, F, L, S, rangesym, lensym))
end
function Loop(ls::LoopSet, ex::Expr, sym::Symbol, ::Type{R}) where {R<:AbstractRange}
    f = ArrayInterface.known_first(R)
    s = ArrayInterface.known_step(R)
    l = ArrayInterface.known_last(R)
    
    Loop(ls, ex, sym, f, s, l)
end

function static_loop(sym::Symbol, L::Int, S::Int, U::Int)
    Loop(sym, MaybeKnown(L,0), MaybeKnown(U,0), MaybeKnown(S,0), Symbol(""), Symbol(""))
end
function Loop(::LoopSet, ::Expr, sym::Symbol, ::Type{OptionallyStaticUnitRange{Static{L}, Static{U}}}) where {L,U}
    static_loop(sym, L, 1, U)
end
function Loop(::LoopSet, ::Expr, sym::Symbol, ::Type{ArrayInterface.OptionallyStaticStepRange{StaticInt{L}, StaticInt{S}, StaticInt{U}}}) where {L,S,U}
    static_loop(sym, L, S, U)
end
function Loop(::LoopSet, ::Expr, sym::Symbol, ::Type{CloseOpen{Static{L}, Static{U}}}) where {L,U}
    static_loop(sym, L, 1, U - 1)
end


extract_loop(l) = Expr(:call, GlobalRef(Core,:getfield), Symbol("#loop#bounds#"), l, false)

function add_loops!(ls::LoopSet, LPSYM, LB)
    n = max(length(LPSYM), length(LB))
    for i = 1:n
        sym, l = LPSYM[i], LB[i]
        if l<:CartesianIndices
            add_loops!(ls, i, sym, l)
        else
            add_loop!(ls, Loop(ls, extract_loop(i), sym, l)::Loop)
            push!(ls.loopsymbol_offsets, ls.loopsymbol_offsets[end]+1)
        end
    end
end
function add_loops!(ls::LoopSet, i::Int, sym::Symbol, @nospecialize(l::Type{<:CartesianIndices}))
    N, T = l.parameters
    ssym = String(sym)
    for k = N:-1:1
        axisexpr = :(getfield(getfield(getfield(var"#loop#bounds#", $i, false), :indices), $k, false))
        add_loop!(ls, Loop(ls, axisexpr, Symbol(ssym*'#'*string(k)*'#'), T.parameters[k])::Loop)
    end
    push!(ls.loopsymbol_offsets, ls.loopsymbol_offsets[end]+N)
end

function ArrayReferenceMeta(
    ls::LoopSet, @nospecialize(ar::ArrayRefStruct), arraysymbolinds::Vector{Symbol},
    opsymbols::Vector{Symbol}, nopsv::Vector{NOpsType}, expandedv::Vector{Bool}
)
    # unpack the `ArrayRefStruct`
    # we don't want to specialize on it, as it is typed on symbols.
    index_types = (ar.index_types)::UInt64
    indices = (ar.indices)::UInt64
    offsets = (ar.offsets)::UInt64
    strides = (ar.strides)::UInt64
    arrayar = array(ar)::Symbol
    ptrar = ptr(ar)::Symbol
    # TODO, check if this matters at all. The compiler still knows it is an `::ArrayRefStruct`, just not `arrayar` or `ptrar`?
    ArrayReferenceMeta(
        ls, index_types, indices, offsets, strides,
        arrayar, ptrar, arraysymbolinds, opsymbols, nopsv, expandedv
    )
end
function ArrayReferenceMeta(
    ls::LoopSet, index_types::UInt64, indices::UInt64, offsets::UInt64, strides::UInt64,
    arrayar::Symbol, ptrar::Symbol, arraysymbolinds::Vector{Symbol},
    opsymbols::Vector{Symbol}, nopsv::Vector{NOpsType}, expandedv::Vector{Bool}
)
    ni = filled_8byte_chunks(index_types)
    index_vec = Symbol[]
    offset_vec = Int8[]
    stride_vec = Int8[]
    loopedindex = Bool[]
    while index_types != zero(UInt64)
        ind = indices % UInt8
        offsetᵢ = offsets % Int8
        strideᵢ = strides % Int8
        if index_types == LoopIndex
            if ind == zero(Int8) # CONSTANTZEROINDEX
                pushfirst!(index_vec, CONSTANTZEROINDEX)
                pushfirst!(offset_vec, offsetᵢ)
                pushfirst!(stride_vec, strideᵢ)
                pushfirst!(loopedindex, true)
            else
                for inda in ls.loopsymbol_offsets[ind]+1:ls.loopsymbol_offsets[ind+1]
                    pushfirst!(index_vec, ls.loopsymbols[inda])
                    pushfirst!(offset_vec, offsetᵢ)
                    pushfirst!(stride_vec, strideᵢ)
                    pushfirst!(loopedindex, true)
                end
            end
        else#if index_types == ComputedIndex
            @assert index_types == ComputedIndex
            opsym = opsymbols[ind]
            if expandedv[ind]
                nops = nopsv[ind]
                for j ∈ 0:nops-1
                    pushfirst!(index_vec, expandedopname(opsym, j))
                    pushfirst!(offset_vec, offsetᵢ)
                    pushfirst!(stride_vec, strideᵢ)
                    pushfirst!(loopedindex, false)
                end
            else
                pushfirst!(index_vec, opsym)
                pushfirst!(offset_vec, offsetᵢ)
                pushfirst!(stride_vec, strideᵢ)
                pushfirst!(loopedindex, false)
            end
        # else
            # @assert index_types == SymbolicIndex
            # pushfirst!(index_vec, arraysymbolinds[ind])
            # pushfirst!(offset_vec, offset)
            # pushfirst!(loopedindex, false)
        end
        index_types >>>= 8
        indices >>>= 8
        offsets >>>= 8
        strides >>>= 8
        ni -= 1
    end
    ArrayReferenceMeta(
        ArrayReference(arrayar, index_vec, offset_vec, stride_vec),
        loopedindex, ptrar
    )
end


extract_varg(i) = :(getfield(var"#vargs#", $i, false))
# _extract(::Type{Static{N}}) where {N} = N
extract_gsp!(sptrs::Expr, name::Symbol) = (push!(sptrs.args, name); nothing)
function rank_to_sortperm(R::NTuple{N,Int}) where {N}
    sp = ntuple(zero, Val{N}())
    r = ntuple(n -> sum(R[n] .≥ R), Val{N}())
    @inbounds for n = 1:N
        sp = Base.setindex(sp, n, r[n])
    end
    sp
end
# sptrs::Expr, ls::LoopSet, ar::ArrayReferenceMeta, @nospecialize(_::Type{Core.LLVMPtr{T,0}}),
function add_mref!(
    sptrs::Expr, ls::LoopSet, ar::ArrayReferenceMeta, @nospecialize(_::Type{Ptr{T}}),
    C::Int, B::Int, sp::NTuple{N,Int}, name::Symbol
) where {T,N}
    Tsym::Symbol = get(VectorizationBase.JULIA_TYPES, T) do
        Symbol(T)
    end
    add_mref_ptr!(sptrs, ls, ar, Tsym, C, B, sp, name)
end
function loop_indexes_bit!(ls::LoopSet, ar::ArrayReferenceMeta)
    li = ar.loopedindex;
    ind = first(getindices(ar))
    ind === DISCONTIGUOUS && return
    first(li) || throw(LoopError("The contiguous index of a `BitArray` shouldn't be a complex function.", )ind)
    ls.loopindexesbit[getloopid(ls,ind)] = true
    nothing
end
function add_mref_ptr!(
    sptrs::Expr, ls::LoopSet, ar::ArrayReferenceMeta, Tsym::Symbol,
    C::Int, B::Int, sp::NTuple{N,Int}, name::Symbol
) where {N}
    @assert B ≤ 0 "Batched arrays not supported yet."
    # maybe no change needed? -- optimize common case
    column_major = ntuple(identity, N)
    li = ar.loopedindex;
    if sp === column_major || isone(length(li))
        # don't set `bit` to true if our vector width is ≥ 8
        ((Tsym === :Bit) && (ls.vector_width[] < 8)) && loop_indexes_bit!(ls, ar)
        return extract_gsp!(sptrs, name)
    end
    permute_mref!(ar, C, sp)
    # must now sort array's inds, and stack pointer's
    tmpsp = gensym(name)
    extract_gsp!(sptrs, tmpsp)
    strd_tup = Expr(:tuple)
    offsets_tup = Expr(:tuple)
    gf = GlobalRef(Core,:getfield)
    offsets = gensym(:offsets); strides = gensym(:strides)
    pushpreamble!(ls, Expr(:(=), offsets, Expr(:call, gf, tmpsp, QuoteNode(:offsets))))
    pushpreamble!(ls, Expr(:(=), strides, Expr(:call, gf, tmpsp, QuoteNode(:strd))))
    for (i, p) ∈ enumerate(sp)
        push!(strd_tup.args, Expr(:call, gf, strides, p, false))
        push!(offsets_tup.args, Expr(:call, gf, offsets, p, false))
    end
    #TODO: fix for `Tsym === Bit`.
    sptype = Expr(:curly, lv(:StridedPointer), Tsym, N, (C == -1 ? -1 : 1), B, column_major)
    sptr = Expr(:call, sptype, Expr(:call, :pointer, tmpsp), strd_tup, offsets_tup)
    pushpreamble!(ls, Expr(:(=), name, sptr))
    nothing
end
function permute_mref!(ar::ArrayReferenceMeta, C::Int, sp::NTuple{N,Int}) where {N}
    sp === ntuple(identity, Val(N)) && return nothing
    li = ar.loopedindex; lic = copy(li);
    inds = getindices(ar); indsc = copy(inds);
    offsets = ar.ref.offsets; offsetsc = copy(offsets);
    strides = ar.ref.strides; stridesc = copy(strides);
    for (i, p) ∈ enumerate(sp)
        li[i] = lic[p]
        inds[i] = indsc[p]
        offsets[i] = offsetsc[p]
        strides[i] = stridesc[p]
    end
    C == -1 && makediscontiguous!(getindices(ar))
    return nothing
end
function add_mref!(
    sptrs::Expr, ::LoopSet, ::ArrayReferenceMeta, @nospecialize(_::Type{VectorizationBase.FastRange{T,F,S,O}}),
    ::Int, ::Int, ::Any, name::Symbol
) where {T,F,S,O}
    extract_gsp!(sptrs, name)
end
function create_mrefs!(
    ls::LoopSet, arf::Vector{ArrayRefStruct}, as::Vector{Symbol}, os::Vector{Symbol},
    nopsv::Vector{NOpsType}, expanded::Vector{Bool}, ::Type{Tuple{}}
)
    length(arf) == 0 || throw(ArgumentError("Length of array ref vector should be 0 if there are no stridedpointers."))
    Vector{ArrayReferenceMeta}(undef, length(arf))
end
function create_mrefs!(
    ls::LoopSet, arf::Vector{ArrayRefStruct}, as::Vector{Symbol}, os::Vector{Symbol},
    nopsv::Vector{NOpsType}, expanded::Vector{Bool}, @nospecialize(_::Type{VectorizationBase.GroupedStridedPointers{P,C,B,R,I,X,O}})
) where {P,C,B,R,I,X,O}
    mrefs = Vector{ArrayReferenceMeta}(undef, length(arf))
    sptrs = Expr(:tuple)
    # pushpreamble!(ls, Expr(:(=), sptrs, :(VectorizationBase.stridedpointers(getfield(vargs, 1, false)))))
    pushpreamble!(ls, Expr(:(=), sptrs, :(VectorizationBase.stridedpointers(getfield(var"#vargs#", 1, false)))))
    j = 0
    rank_to_sps = Vector{Tuple{Int,NTuple{<:Any,Int}}}(undef, length(arf))
    for i ∈ eachindex(arf)
        ar = ArrayReferenceMeta(ls, arf[i], as, os, nopsv, expanded)
        duplicate = false
        vptrar = vptr(ar)
        for k ∈ 1:i-1
            if vptr(mrefs[k]) === vptrar
                duplicate = true
                # if isassigned(rank_to_sps, k)
                Cₖ, sp = rank_to_sps[k]
                permute_mref!(ar, Cₖ, sp)
                # end
                break
            end
        end
        if !duplicate
            j += 1
            sp = rank_to_sortperm(R[j])
            rank_to_sps[i] = (C[j],sp)
            add_mref!(sptrs, ls, ar, P.parameters[j], C[j], B[j], sp, vptr(ar))
        end
        mrefs[i] = ar
    end
    mrefs
end

function num_parameters(AM)
    num_param::Int = AM[1]
    # num_param += length(AM[2].parameters)
    num_param + length(AM[3])
end
function gen_array_syminds(AM)
    Symbol[Symbol("##arraysymbolind##"*i*'#') for i ∈ 1:(AM[1])::Int]
end
function process_metadata!(ls::LoopSet, AM)
    opoffsets = ls.operation_offsets
    expandbyoffset!(ls.outer_reductions, AM[2], opoffsets)
    for (i,si) ∈ enumerate(AM[3])
        sii = si::Int
        s = gensym(:symlicm)
        push!(ls.preamble_symsym, (opoffsets[sii] + 1, s))
        pushpreamble!(ls, Expr(:(=), s, extract_varg(1 + i)))
    end
    expandbyoffset!(ls.preamble_symint, AM[4], opoffsets)
    expandbyoffset!(ls.preamble_symfloat, AM[5], opoffsets)
    expandbyoffset!(ls.preamble_zeros, AM[6], opoffsets)
    expandbyoffset!(ls.preamble_funcofeltypes, AM[7], opoffsets)
    nothing
end
function expandbyoffset!(indexpand::Vector{T}, inds, offsets::Vector{Int}, expand::Bool = true) where {T <: Union{Int,Tuple{Int,<:Any}}}
    for _ind ∈ inds
        ind = T === Int ? _ind : first(_ind)
        base = offsets[ind] + 1
        for inda ∈ base:(expand ? offsets[ind+1] : base)
            T === Int ? push!(indexpand, inda) : push!(indexpand, (inda,last(_ind)))
        end
    end
    indexpand
end
expandbyoffset(inds::Vector{Int}, offsets::Vector{Int}, expand::Bool) = expandbyoffset!(Int[], inds, offsets, expand)
function loopindex(ls::LoopSet, u::Unsigned, shift::Unsigned)
    mask = (one(shift) << shift) - one(shift) # mask to zero out all but shift-bits
    idxs = Int[]
    while u != zero(u)
        pushfirst!(idxs, ( u % UInt8 ) & mask)
        u >>= shift
    end
    reverse!(idxs)
end
function loopindexoffset(ls::LoopSet, u::Unsigned, li::Bool, expand::Bool = false)
    if li
        shift = 0x04
        offsets = ls.loopsymbol_offsets
    else
        shift = 0x08
        offsets = ls.operation_offsets
    end
    idxs = loopindex(ls, u, shift)
    expandbyoffset(idxs, offsets, expand)
end
function parents_symvec(ls::LoopSet, u::Unsigned, expand, offset)
    idxs = loopindexoffset(ls, u, true, expand)   # TODO DRY  (undesirable that this gets hard-coded in multiple places)
    return Symbol[getloopsym(ls, i + offset) for i ∈ idxs]
end
loopdependencies(ls::LoopSet, os::OperationStruct, expand = false, offset = 0) = parents_symvec(ls, os.loopdeps, expand, offset)
reduceddependencies(ls::LoopSet, os::OperationStruct, expand = false, offset = 0) = parents_symvec(ls, os.reduceddeps, expand, offset)
childdependencies(ls::LoopSet, os::OperationStruct, expand = false, offset = 0) = parents_symvec(ls, os.childdeps, expand, offset)

# parents(ls::LoopSet, u::UInt64) = loopindexoffset(ls, u, false)
parents(ls::LoopSet, u::UInt64) = loopindex(ls, u, 0x08)
parents(ls::LoopSet, os::OperationStruct) = parents(ls, os.parents)

expandedopname(opsymbol::Symbol, offset::Integer) = Symbol(String(opsymbol)*'#'*string(offset+1)*'#')
function calcnops(ls::LoopSet, os::OperationStruct)
    optyp = optype(os)
    if (optyp != loopvalue) && (optyp != compute)
        return 1
    end
    offsets = ls.loopsymbol_offsets
    idxs = loopindex(ls, os.loopdeps, 0x04)  # TODO DRY
    iszero(length(idxs)) && return 1
    return maximum(i->offsets[i+1]-offsets[i], idxs)
end
function isexpanded(ls::LoopSet, ops::Vector{OperationStruct}, nopsv::Vector{NOpsType}, i::Int)
    nops = nopsv[i]
    # nops isa Vector{Int} only if accesses_memory(os), which means isexpanded must be false
    (nops === 1 || isa(nops, Vector{Int})) && return false
    os = ops[i]
    optyp = optype(os)
    if optyp == compute
        any(j -> isexpanded(ls, ops, nopsv, j), parents(ls, os))
    elseif optyp == loopvalue
        true
    else
        false
    end
end
function add_op!(
    ls::LoopSet, instr::Instruction, ops::Vector{OperationStruct}, nopsv::Vector{NOpsType}, expandedv::Vector{Bool}, i::Int,
    mrefs::Vector{ArrayReferenceMeta}, opsymbol, elementbytes::Int
)
    os = ops[i]
    # opsymbol = (isconstant(os) && instr != LOOPCONSTANT) ? instr.instr : opsymbol
    # If it's a CartesianIndex add or subtract, we may have to add multiple operations
    expanded = expandedv[i]# isexpanded(ls, ops, nopsv, i)
    opoffsets = ls.operation_offsets
    # offsets = ls.loopsymbol_offsets
    optyp = optype(os)
    if !expanded
        op = Operation(
            length(operations(ls)), opsymbol, elementbytes, instr,
            optyp, loopdependencies(ls, os, true), reduceddependencies(ls, os, true),
            Operation[], (isload(os) | isstore(os)) ? mrefs[os.array] : NOTAREFERENCE,
            childdependencies(ls, os, true)
        )
        push!(ls.operations, op)
        push!(opoffsets, opoffsets[end] + 1)
        return
    end
    nops = (nopsv[i])::Int # if it were a vector, it would have to have been expanded
    # if expanded, optyp must be either loopvalue, or compute (with loopvalues in its ancestry, not cutoff by loads)
    for offset = 0:nops-1
        sym = nops === 1 ? opsymbol : expandedopname(opsymbol, offset)
        op = Operation(
            length(operations(ls)), sym, elementbytes, instr,
            optyp, loopdependencies(ls, os, false, offset), reduceddependencies(ls, os, false, offset),
            Operation[], (isload(os) | isstore(os)) ? mrefs[os.array] : NOTAREFERENCE,
            childdependencies(ls, os, false, offset)
        )
        push!(ls.operations, op)
    end
    push!(opoffsets, opoffsets[end] + nops)
    nothing
end
function add_parents_to_op!(ls::LoopSet, op::Operation, up::Unsigned, k::Int, Δ::Int)
    vparents = parents(op)
    ops = operations(ls)
    offsets = ls.operation_offsets
    if isone(Δ) # not expanded
        @assert isone(k)
        for i ∈ parents(ls, up)
            # FIXME; children also filled in cacheunrolled
            for j ∈ offsets[i]+1:offsets[i+1] # if parents are expanded, add them all
                opp = ops[j]
                pushfirst!(vparents, opp)
                push!(children(opp), op)
            end
        end
    else#if isexpanded
        # Do we want to require that all Δidxs are equal?
        # Because `CartesianIndex((2,3)) - 1` results in a methoderorr, I think this is reasonable for now
        # FIXME; children also filled in cacheunrolled
        for i ∈ parents(ls, up)
            opp = ops[offsets[i]+k]
            pushfirst!(vparents, opp)
            push!(children(opp), op)
        end
    end
end
function add_parents_to_ops!(ls::LoopSet, ops::Vector{OperationStruct}, constoffset)
    offsets = ls.operation_offsets
    for i in 1:length(offsets)-1
        pos = offsets[i]
        Δ = offsets[i+1]-pos
        for k ∈ 1:Δ
            op = ls.operations[pos+k]
            if isconstant(op)
                instr = instruction(op)
                if instr != LOOPCONSTANT && instr.mod !== :numericconstant
                    constoffset += 1
                    pushpreamble!(ls, Expr(:(=), instr.instr, extract_varg(constoffset)))
                end
            elseif !isloopvalue(op)
                add_parents_to_op!(ls, op, ops[i].parents, k, Δ)
            end
        end
    end
    constoffset
end
function add_ops!(
    ls::LoopSet, instr::Vector{Instruction}, ops::Vector{OperationStruct}, mrefs::Vector{ArrayReferenceMeta},
    opsymbols::Vector{Symbol}, constoffset::Int, nopsv::Vector{NOpsType}, expandedv::Vector{Bool}, elementbytes::Int
)
    # @show ls.loopsymbols ls.loopsymbol_offsets
    for i ∈ eachindex(ops)
        os = ops[i]
        opsymbol = opsymbols[os.symid]
        add_op!(ls, instr[i], ops, nopsv, expandedv, i, mrefs, opsymbol, elementbytes)
    end
    add_parents_to_ops!(ls, ops, constoffset)
    # for op ∈ operations(ls)
    #     if isstore(op) && isreduction(op) && iszero(length(loopdependencies(op)))
    #         addreduct_to_outer_reductions!(ls, op)
    #     end
    # end
    # for op in operations(ls)
        # @show op
    # end
end

# elbytes(::VectorizationBase.AbstractPointer{T}) where {T} = sizeof(T)::Int
# typeeltype(::Type{P}) where {T,P<:VectorizationBase.AbstractStridedPointer{T}} = T
typeeltype(::Type{Ptr{T}}) where {T} = T
# typeeltype(::Type{Core.LLVMPtr{T,0}}) where {T} = T
typeeltype(::Type{VectorizationBase.FastRange{T,F,S,O}}) where {T,F,S,O} = T
typeeltype(::Type{T}) where {T<:Real} = T
# typeeltype(::Any) = Int8

function add_array_symbols!(ls::LoopSet, arraysymbolinds::Vector{Symbol}, offset::Int)
    for (i,as) ∈ enumerate(arraysymbolinds)
        pushpreamble!(ls, Expr(:(=), as, extract_varg(i + offset)))
    end
end
function extract_external_functions!(ls::LoopSet, offset::Int, vargs)
    for op ∈ operations(ls)
        if iscompute(op)
            instr = instruction(op)
            if instr.mod != :LoopVectorization
                offset += 1
                instr_new = get(FUNCTIONSYMBOLS, vargs[offset], instr)
                if instr_new === instr
                    extractf = Expr(:call, GlobalRef(Core,:getfield), Symbol("#vargs#"), offset, false)
                    pushpreamble!(ls, Expr(:(=), instr.instr, extractf))
                else
                    op.instruction = instr_new
                end
            end
        end
    end
    offset
end
function sizeofeltypes(v)::Int
    num_arrays = length(v)::Int
    if num_arrays == 0
        return 8
    end
    T = typeeltype(v[1])
    sz = if (VectorizationBase.simd_integer_register_size() != VectorizationBase.register_size()) && T <: Integer # hack
        (VectorizationBase.register_size() ÷ VectorizationBase.simd_integer_register_size()) * sizeof(T)
    else
        sz = sizeof(T)
    end
    for i ∈ 2:num_arrays
        Ttemp = typeeltype(v[i])
        szᵢ = if (VectorizationBase.simd_integer_register_size() != VectorizationBase.register_size()) && T <: Integer # hack
            (VectorizationBase.register_size() ÷ VectorizationBase.simd_integer_register_size()) * sizeof(T)
        else
            sizeof(Ttemp)
        end
        # if !VectorizationBase.SIMD_NATIVE_INTEGERS && Ttemp <: Integer # hack
        #     return VectorizationBase.register_size()
        # end
        # T = promote_type(T, Ttemp)
        sz = max(szᵢ, sz)
    end
    sz
    # sizeof(T)
end

function avx_loopset!(
    ls::LoopSet, instr::Vector{Instruction}, ops::Vector{OperationStruct}, arf::Vector{ArrayRefStruct},
    AM::Vector{Any}, LPSYM::Vector{Any}, LB::Core.SimpleVector, vargs::Core.SimpleVector
)
    # TODO: check outer reduction types instead
    elementbytes = if length(vargs[1].parameters) > 0
        sizeofeltypes(vargs[1].parameters[1].parameters)
    else
        8
    end
    pushpreamble!(ls, :((var"#loop#bounds#", var"#vargs#") = var"#lv#tuple#args#"))
    add_loops!(ls, LPSYM, LB)
    resize!(ls.loop_order, ls.loopsymbol_offsets[end])
    arraysymbolinds = gen_array_syminds(AM)
    opsymbols = [gensym("op") for _ ∈ eachindex(ops)]
    nopsv = NOpsType[calcnops(ls, op) for op in ops]
    expandedv = [isexpanded(ls, ops, nopsv, i) for i ∈ eachindex(ops)]

    resize!(ls.loopindexesbit, length(ls.loops)); ls.loopindexesbit .= false;
    mrefs = create_mrefs!(ls, arf, arraysymbolinds, opsymbols, nopsv, expandedv, vargs[1])
    for mref ∈ mrefs
        push!(ls.includedactualarrays, vptr(mref))
    end    
    # num_params = num_arrays + num_parameters(AM)
    num_params = 1 + num_parameters(AM)
    add_ops!(ls, instr, ops, mrefs, opsymbols, num_params, nopsv, expandedv, elementbytes)
    process_metadata!(ls, AM)
    add_array_symbols!(ls, arraysymbolinds, 1 + length(ls.preamble_symsym))
    num_params = extract_external_functions!(ls, num_params, vargs)
    ls
end
function avx_body(ls::LoopSet, UNROLL::Tuple{Bool,Int8,Int8,Int,Int,Int,Int,Int,Int,Int,UInt})
    inline, u₁, u₂, W, rs, rc, cls, l1, l2, l3, nt = UNROLL
    q = iszero(u₁) ? lower_and_split_loops(ls, inline % Int) : lower(ls, u₁ % Int, u₂ % Int, inline % Int)
    iszero(length(ls.outer_reductions)) ? push!(q.args, nothing) : push!(q.args, loopset_return_value(ls, Val(true)))
    q
end

function _avx_loopset_debug(::Val{UNROLL}, ::Val{OPS}, ::Val{ARF}, ::Val{AM}, ::Val{LPSYM}, _vargs::Tuple{LB,V}) where {UNROLL, OPS, ARF, AM, LPSYM, LB, V}
    @show OPS ARF AM LPSYM _vargs
    _avx_loopset(OPS, ARF, AM, LPSYM, _vargs[1].parameters, V.parameters, UNROLL)
end
function tovector(@nospecialize(t))
    v = Vector{Any}(undef, length(t))
    for i ∈ eachindex(v)
        tᵢ = t[i]
        if tᵢ isa Tuple # reduce specialization?
            v[i] = tovector(tᵢ)
        else
            v[i] = tᵢ
        end
    end
    v
end
function _avx_loopset(
    @nospecialize(OPSsv), @nospecialize(ARFsv), @nospecialize(AMsv), @nospecialize(LPSYMsv), LBsv::Core.SimpleVector, vargs::Core.SimpleVector,
    UNROLL::Tuple{Bool,Int8,Int8,Int,Int,Int,Int,Int,Int,Int,UInt}
)
    nops = length(OPSsv) ÷ 3
    instr = Instruction[Instruction(OPSsv[3i+1], OPSsv[3i+2]) for i ∈ 0:nops-1]
    ops = OperationStruct[ OPSsv[3i] for i ∈ 1:nops ]
    ls = LoopSet(:LoopVectorization)
    inline, u₁, u₂, W, rs, rc, cls, l1, l2, l3, nt = UNROLL
    set_hw!(ls, rs, rc, cls, l1, l2, l3); ls.vector_width[] = W
    avx_loopset!(
        ls, instr, ops,
        ArrayRefStruct[ARFsv...],
        tovector(AMsv), tovector(LPSYMsv), LBsv, vargs
    )::LoopSet
    ls
end

"""
    _avx_!(unroll, ops, arf, am, lpsym, lb, vargs...)

Execute an `@avx` block. The block's code is represented via the arguments:
- `unroll` is `Val((u₁,u₂))` and specifies the loop unrolling factor(s).
  These values may be supplied manually via the `unroll` keyword
  of [`@avx`](@ref).
- `ops` is `Tuple{mod1, sym1, op1, mod2, sym2, op2...}` encoding the operations of the loop.
  `mod` and `sym` encode the module and symbol of the called function; `op` is an [`OperationStruct`](@ref)
  encoding the details of the operation.
- `arf` is `Tuple{arf1, arf2...}`, where each `arfi` is an [`ArrayRefStruct`](@ref) encoding
  an array reference.
- `am` contains miscellaneous data about the LoopSet (see `process_metadata!`)
- `lpsym` is `Tuple{:i,:j,...}`, a Tuple of the "loop symbols", i.e. the item variable `i` in `for i ∈ iter`
- `lb` is `Tuple{RngTypei,RngTypej,...}`, a Tuple encoding syntactically-knowable information about
  the iterators corresponding to `lpsym`. For example, in `for i ∈ 1:n`, the `1:n` would be encoded with
  `StaticLowerUnitRange(1)` because the lower bound of the iterator can be determined to be 1.
- `vargs...` holds the encoded pointers of all the arrays (see `VectorizationBase`'s various pointer types).
"""
@generated function _avx_!(
    ::Val{UNROLL}, ::Val{OPS}, ::Val{ARF}, ::Val{AM}, ::Val{LPSYM}, var"#lv#tuple#args#"::Tuple{LB,V}
) where {UNROLL, OPS, ARF, AM, LPSYM, LB, V}
    1 + 1 # Irrelevant line you can comment out/in to force recompilation...
    ls = _avx_loopset(OPS, ARF, AM, LPSYM, LB.parameters, V.parameters, UNROLL)
    # return @show avx_body(ls, UNROLL)
    if last(UNROLL) > 1
        inline, u₁, u₂, W, rs, rc, cls, l1, l2, l3, nt = UNROLL
        # wrap in `OPS, ARF, AM, LPSYM` in `Expr` to homogenize types
        avx_threads_expr(
            ls, (inline, u₁, u₂, W, rs, rc, cls, l1, l2, l3, one(UInt)), nt,
            :(Val{$OPS}()), :(Val{$ARF}()), :(Val{$AM}()), :(Val{$LPSYM}())
        )
    else
        # @show avx_body(ls, UNROLL)
        # Main.BODY[] = avx_body(ls, UNROLL)
        avx_body(ls, UNROLL)
    end
    # @show UNROLL, OPS, ARF, AM, LPSYM, LB
end
