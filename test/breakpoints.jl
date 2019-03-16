radius2(x, y) = x^2 + y^2
function loop_radius2(n)
    s = 0
    for i = 1:n
        s += radius2(1, i)
    end
    s
end

tmppath = ""
if isdefined(Main, :Revise)
    global tmppath
    tmppath, io = mktemp()
    print(io, """
    function jikwfunc(x, y=0; z="hello")
        a = x + y
        b = z^a
        return length(b)
    end
    """)
    close(io)
    includet(tmppath)
end

using JuliaInterpreter, Test

function stacklength(frame)
    n = 1
    frame = frame.callee
    while frame !== nothing
        n += 1
        frame = frame.callee
    end
    return n
end

@testset "Breakpoints" begin
    breakpoint(radius2)
    frame = JuliaInterpreter.enter_call(loop_radius2, 2)
    bp = JuliaInterpreter.finish_and_return!(frame)
    @test isa(bp, JuliaInterpreter.BreakpointRef)
    @test stacklength(frame) == 2
    @test leaf(frame).framecode.scope == @which radius2(0, 0)
    bp = JuliaInterpreter.finish_stack!(frame)
    @test isa(bp, JuliaInterpreter.BreakpointRef)
    @test stacklength(frame) == 2
    @test JuliaInterpreter.finish_stack!(frame) == loop_radius2(2)

    # Conditional breakpoints
    function runsimple()
        frame = JuliaInterpreter.enter_call(loop_radius2, 2)
        bp = JuliaInterpreter.finish_and_return!(frame)
        @test isa(bp, JuliaInterpreter.BreakpointRef)
        @test stacklength(frame) == 2
        @test leaf(frame).framecode.scope == @which radius2(0, 0)
        @test JuliaInterpreter.finish_stack!(frame) == loop_radius2(2)
    end
    remove()
    breakpoint(radius2, :(y > x))
    runsimple()
    remove()
    @breakpoint radius2(0,0) y>x
    runsimple()
    # Demonstrate the problem that we have with scope
    local_identity(x) = identity(x)
    remove()
    @breakpoint radius2(0,0) y>local_identity(x)
    @test_broken @interpret loop_radius2(2)

    # Conditional breakpoints on local variables
    remove()
    halfthresh = loop_radius2(5)
    @breakpoint loop_radius2(10) 5 s>$halfthresh
    frame, bp = @interpret loop_radius2(10)
    @test isa(bp, JuliaInterpreter.BreakpointRef)
    lframe = leaf(frame)
    s_extractor = eval(JuliaInterpreter.prepare_slotfunction(lframe.framecode, :s))
    @test s_extractor(lframe) == loop_radius2(6)
    JuliaInterpreter.finish_stack!(frame)
    @test s_extractor(lframe) == loop_radius2(7)
    disable(bp)
    @test JuliaInterpreter.finish_stack!(frame) == loop_radius2(10)

    # Next line with breakpoints
    function outer(x)
        inner(x)
    end
    function inner(x)
        return 2
    end
    breakpoint(inner)
    frame = JuliaInterpreter.enter_call(outer, 0)
    bp = JuliaInterpreter.next_line!(frame)
    @test isa(bp, JuliaInterpreter.BreakpointRef)
    @test JuliaInterpreter.finish_stack!(frame) == 2

    # Breakpoints by file/line
    if isdefined(Main, :Revise)
        remove()
        method = which(JuliaInterpreter.locals, Tuple{Frame})
        breakpoint(String(method.file), method.line+1)
        frame = JuliaInterpreter.enter_call(loop_radius2, 2)
        ret = @interpret JuliaInterpreter.locals(frame)
        @test isa(ret, JuliaInterpreter.BreakpointRef)
        # Test kwarg method
        remove()
        bp = breakpoint(tmppath, 3)
        frame, bp2 = @interpret jikwfunc(2)
        @test bp2 == bp
        var = JuliaInterpreter.locals(leaf(frame))
        @test !any(v->v.name == :b, var)
        @test filter(v->v.name == :a, var)[1].value == 2
    else
        try
            breakpoint(pathof(JuliaInterpreter.CodeTracking), 5)
        catch err
            @test isa(err, ErrorException)
            @test occursin("Revise", err.msg)
        end
    end

    # Direct return
    @breakpoint gcd(1,1) a==5
    @test @interpret(gcd(10,20)) == 10
    # FIXME: even though they pass, these tests break Test!
    # frame, bp = @interpret gcd(5, 20)
    # @test stacklength(frame) == 1
    # @test isa(bp, JuliaInterpreter.BreakpointRef)
    remove()

    # break on error
    try
        JuliaInterpreter.break_on_error[] = true

        inner(x) = error("oops")
        outer() = inner(1)
        frame = JuliaInterpreter.enter_call(outer)
        bp = JuliaInterpreter.finish_and_return!(frame)
        @test bp.err == ErrorException("oops")
        @test stacklength(frame) >= 2
        @test frame.framecode.scope.name == :outer
        cframe = frame.callee
        @test cframe.framecode.scope.name == :inner

        # Don't break on caught exceptions
        function f_exc_outer()
            try
                f_exc_inner()
            catch err
                return err
            end
        end
        function f_exc_inner()
            error()
        end
        frame = JuliaInterpreter.enter_call(f_exc_outer);
        v = JuliaInterpreter.finish_and_return!(frame)
        @test v isa ErrorException
        @test stacklength(frame) == 1
    finally
        JuliaInterpreter.break_on_error[] = false
    end

    # Breakpoint display
    io = IOBuffer()
    frame = JuliaInterpreter.enter_call(loop_radius2, 2)
    bp = JuliaInterpreter.BreakpointRef(frame.framecode, 1)
    show(io, bp)
    @test String(take!(io)) == "breakpoint(loop_radius2(n) in $(@__MODULE__) at $(@__FILE__):3, line 3)"
    bp = JuliaInterpreter.BreakpointRef(frame.framecode, 0)  # fictive breakpoint
    show(io, bp)
    @test String(take!(io)) == "breakpoint(loop_radius2(n) in $(@__MODULE__) at $(@__FILE__):3, %0)"
    bp = JuliaInterpreter.BreakpointRef(frame.framecode, 1, ArgumentError("whoops"))
    show(io, bp)
    @test String(take!(io)) == "breakpoint(loop_radius2(n) in $(@__MODULE__) at $(@__FILE__):3, line 3, ArgumentError(\"whoops\"))"

    # In source breakpointing
    f_outer_bp(x) = g_inner_bp(x)
    function g_inner_bp(x)
        sin(x)
        @bp
        @bp
        @bp
        x = 3
        return 2
    end
    fr, bp = @interpret f_outer_bp(3)
    @test leaf(fr).framecode.scope.name == :g_inner_bp
    @test bp.stmtidx == 3
end

if tmppath != ""
    rm(tmppath)
end