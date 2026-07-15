module Compiler
# ODE-compiler stubs. Real implementations live in ext/SimuLiteCompilerExt.jl,
# attached automatically when the user loads both ModelingToolkit and
# DifferentialEquations (Julia >= 1.9 package extension). This keeps
# `using SimuLite` free of the ~10-20 s MTK/DiffEq load cost.

export compile_ode, simulate_ode

const _EXT_HINT = """
    the ODE compiler backend is provided by a package extension loaded only \
    when ModelingToolkit and DifferentialEquations are present. Run

        using ModelingToolkit, DifferentialEquations

    and try again. (If not installed: \
    `import Pkg; Pkg.add(["ModelingToolkit", "DifferentialEquations"])`.)"""

compile_ode(args...; kwargs...)  = error("compile_ode: ", _EXT_HINT)
simulate_ode(args...; kwargs...) = error("simulate_ode: ", _EXT_HINT)

end
