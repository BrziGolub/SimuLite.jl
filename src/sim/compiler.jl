module Compiler

using ModelingToolkit
using DifferentialEquations

using ..Types
using ..Diagram
using ..BlocksMath
using ..BlocksSources

export compile_ode, simulate_ode

# ------------------------------------------
# Block compilation methods
# ------------------------------------------

function compile_block(block, ctx)
    error("ODE compile not implemented for $(typeof(block))")
end

# ------------------------------------------
# Constant
# ------------------------------------------

function compile_block(block::ConstantBlock, ctx)

    name = Symbol("const_", objectid(block))

    val = block.value

    ctx[:outputs][block] = val
end

# ------------------------------------------
# Gain
# ------------------------------------------

function compile_block(block::GainBlock, ctx)

    input_expr =
        ctx[:signals][(block, :in)]

    expr = block.k * input_expr

    ctx[:outputs][block] = expr
end

# ------------------------------------------
# Sum
# ------------------------------------------

function compile_block(block::SumBlock, ctx)

    expr = zero(Num)

    for (i, sign_char) in enumerate(block.signs)
        port_name = Symbol("in$i")
        sign      = sign_char == '+' ? 1 : -1
        expr     += sign * ctx[:signals][(block, port_name)]
    end

    ctx[:outputs][block] = expr
end

# ------------------------------------------
# Integrator
# ------------------------------------------

function compile_block(block::IntegratorBlock, ctx)

    t = ctx[:t]
    D = Differential(t)

    xsym = Symbol(block.name)
    x = only(@variables $xsym(t))

    input_expr = ctx[:signals][(block, :in)]

    eq = D(x) ~ input_expr

    push!(ctx[:equations], eq)
    push!(ctx[:states], x)
    ctx[:u0][x] = block.state

    ctx[:outputs][block] = x
end

# ------------------------------------------
# Main compiler
# ------------------------------------------

function compile_ode(diagram::BlockDiagram)

    @independent_variables t

    ctx = Dict(
        :t         => t,
        :equations => Equation[],
        :states    => [],
        :u0        => Dict{Any, Any}(),
        :signals   => Dict(),
        :outputs   => Dict()
    )

    # Single topological pass: compile block, then wire its output downstream.
    # Each block reads signals that were wired by already-compiled upstream blocks.
    for block in get_execution_order(diagram)
        compile_block(block, ctx)

        for conn in diagram.connections
            if conn.src_block === block
                ctx[:signals][(conn.dst_block, conn.dst_port)] = ctx[:outputs][block]
            end
        end
    end

    sys = ODESystem(
        ctx[:equations],
        t,
        ctx[:states],
        [];
        name = :sys
    )

    return sys, ctx[:u0]
end

# ------------------------------------------
# Simulate
# ------------------------------------------

function simulate_ode(diagram::BlockDiagram; tspan=nothing)

    tspan = something(tspan, diagram.config.tspan)

    sys, u0 = compile_ode(diagram)
    sys = structural_simplify(sys)

    prob = ODEProblem(sys, u0, tspan)

    sol = solve(prob)

    return sol
end

end