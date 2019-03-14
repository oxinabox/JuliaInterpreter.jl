# This file generates builtins.jl.
using InteractiveUtils

function scopedname(f)
    io = IOBuffer()
    show(io, f)
    fstr = String(take!(io))
    occursin('.', fstr) && return fstr
    tn = typeof(f).name
    Base.isexported(tn.module, Symbol(fstr)) && return fstr
    fsym = Symbol(fstr)
    isdefined(tn.module, fsym) && return string(tn.module) * '.' * fstr
    return "Base." * fstr
end

function nargs(f, table, id)
    # Look up the expected number of arguments in Core.Compiler.tfunc data
    if id !== nothing
        minarg, maxarg, tfunc = table[id]
    else
        minarg = 0
        maxarg = typemax(Int)
    end
    # The tfunc tables are wrong for fptoui and fptosi (fixed in https://github.com/JuliaLang/julia/pull/30787)
    if f == "Base.fptoui" || f == "Base.fptosi"
        minarg = 2
    end
    return minarg, maxarg
end

function generate_fcall_nargs(fname, minarg, maxarg)
    # Generate a separate call for each number of arguments
    maxarg < typemax(Int) || error("call this only for constrained number of arguments")
    wrapper = minarg == maxarg ? "" : "if nargs == "
    for nargs = minarg:maxarg
        if minarg < maxarg
            wrapper *= "$nargs\n            "
        end
        argcall = ""
        for i = 1:nargs
            argcall *= "@lookup(frame, args[$(i+1)])"
            if i < nargs
                argcall *= ", "
            end
        end
        wrapper *= "return Some{Any}($fname($argcall))"
        if nargs < maxarg
            wrapper *= "\n        elseif nargs == "
        end
    end
    if minarg < maxarg
        wrapper *= "\n        end"
    end
    return wrapper
end

function generate_fcall(f, table, id)
    minarg, maxarg = nargs(f, table, id)
    fname = scopedname(f)
    if maxarg < typemax(Int)
        return generate_fcall_nargs(fname, minarg, maxarg)
    end
    # A built-in with arbitrary or unknown number of arguments.
    # This will (unfortunately) use dynamic dispatch.
    return "return Some{Any}($fname(getargs(args, frame)...))"
end

# `io` is for the generated source file
# `intrinsicsfile` is the path to Julia's `src/intrinsics.h` file
function generate_builtins(file::String)
    open(file, "w") do io
        generate_builtins(io::IO)
    end
end
function generate_builtins(io::IO)
    pat = r"(ADD_I|ALIAS)\((\w*),"
    print(io,
"""
# This file is generated by `generate_builtins.jl`. Do not edit by hand.

function getargs(args, frame)
    nargs = length(args)-1  # skip f
    callargs = resize!(frame.framedata.callargs, nargs)
    for i = 1:nargs
        callargs[i] = @lookup(frame, args[i+1])
    end
    return callargs
end

\"\"\"
    ret = maybe_evaluate_builtin(frame, call_expr, expand::Bool)

If `call_expr` is to a builtin function, evaluate it, returning the result inside a `Some` wrapper.
Otherwise, return `call_expr`.

If `expand` is true, `Core._apply` calls will be resolved as a call to the applied function.
\"\"\"
function maybe_evaluate_builtin(frame, call_expr, expand::Bool)
    # By having each call appearing statically in the "switch" block below,
    # each gets call-site optimized.
    args = call_expr.args
    nargs = length(args) - 1
    fex = args[1]
    if isa(fex, QuoteNode)
        f = fex.value
    else
        f = @lookup(frame, fex)
    end
    # Builtins and intrinsics have empty method tables. We can circumvent
    # a long "switch" check by looking for this.
    mt = typeof(f).name.mt
    if isa(mt, Core.MethodTable)
        isempty(mt) || return call_expr
    end
    # Builtins
""")
    firstcall = true
    for ft in subtypes(Core.Builtin)
        ft === Core.IntrinsicFunction && continue
        ft === getfield(Core, Symbol("#kw##invoke")) && continue  # handle this one later
        head = firstcall ? "if" : "elseif"
        firstcall = false
        f = ft.instance
        fname = scopedname(f)
        # Tuple is common, especially for returned values from calls. It's worth avoiding
        # dynamic dispatch through a call to `ntuple`.
        if f === tuple
            print(io,
"""
    $head f === tuple
        return Some{Any}(ntuple(i->@lookup(frame, args[i+1]), length(args)-1))
""")
            continue
        elseif f === Core._apply
            # Resolve varargs calls
            print(io,
"""
    $head f === Core._apply
        argswrapped = getargs(args, frame)
        if !expand
            return Some{Any}(Core._apply(getargs(args, frame)...))
        end
        argsflat = Base.append_any((argswrapped[1],), argswrapped[2:end]...)
        new_expr = Expr(:call, map(x->isa(x, Symbol) || isa(x, Expr) || isa(x, QuoteNode) ? QuoteNode(x) : x, argsflat)...)
        return new_expr
""")
            continue
        end

        id = findfirst(isequal(f), Core.Compiler.T_FFUNC_KEY)
        fcall = generate_fcall(f, Core.Compiler.T_FFUNC_VAL, id)
        print(io,
"""
    $head f === $fname
        $fcall
""")
        firstcall = false
    end
    print(io,
"""
    # Intrinsics
""")
    print(io,
"""
    elseif f === Base.cglobal
        if nargs == 1
            return Some{Any}(Core.eval(moduleof(frame), call_expr))
        elseif nargs == 2
            call_expr = copy(call_expr)
            call_expr.args[3] = @lookup(frame, args[3])
            return Some{Any}(Core.eval(moduleof(frame), call_expr))
        end
""")
    # Extract any intrinsics that support varargs
    fva = []
    minmin, maxmax = typemax(Int), 0
    for fsym in names(Core.Intrinsics)
        fsym == :Intrinsics && continue
        isdefined(Base, fsym) || continue
        f = getfield(Base, fsym)
        id = reinterpret(Int32, f) + 1
        minarg, maxarg = nargs(f, Core.Compiler.T_IFUNC, id)
        if maxarg == typemax(Int)
            push!(fva, f)
        else
            minmin = min(minmin, minarg)
            maxmax = max(maxmax, maxarg)
        end
    end
    for f in fva
        id = reinterpret(Int32, f) + 1
        fname = scopedname(f)
        fcall = generate_fcall(f, Core.Compiler.T_IFUNC, id)
        print(io,
"""
    elseif f === $fname
        $fcall
    end
""")
    end
    # Now handle calls with bounded numbers of args
    fcall = generate_fcall_nargs("f", minmin, maxmax)
    print(io,
"""
    if isa(f, Core.IntrinsicFunction)
        $fcall
""")
    print(io,
"""
    end
    if isa(f, getfield(Core, Symbol("#kw##invoke")))
        return Some{Any}(getfield(Core, Symbol("#kw##invoke"))(getargs(args, frame)...))
    end
    return call_expr
end
""")
end

generate_builtins(joinpath(@__DIR__, "builtins-julia$(Int(VERSION.major)).$(Int(VERSION.minor)).jl"))
