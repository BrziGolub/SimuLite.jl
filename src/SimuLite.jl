module SimuLite

include("model/types.jl")
include("model/blocks/api.jl")
include("model/blocks/common.jl")
include("model/blocks/sources.jl")
include("model/blocks/math.jl")
include("model/blocks/sinks.jl")
include("model/diagram.jl")
include("sim/compiler.jl")
include("sim/runner.jl")
include("gui/canvas.jl")

using .Types
using .BlocksAPI
using .Diagram
using .BlocksCommon
using .BlocksSources
using .BlocksMath
using .BlocksSinks
using .Compiler
using .Runner
using .Canvas

export BlockDiagram, SimConfig, SimResult, add_block!, connect!, disconnect!, remove_block!
export DiagramError, DuplicateNameError, PortNotFoundError, PortAlreadyConnectedError
export input_ports, output_ports
export ConstantBlock, StepBlock, SineBlock, RampBlock, ClockBlock
export GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock,
       ProductBlock, SaturationBlock, AbsBlock,
       DerivativeBlock, PIDBlock, LookupTable1DBlock,
       TransferFnBlock, StateSpaceBlock
export ScopeBlock, WorkspaceBlock, TerminatorBlock
export simulate_ode
export simulate
export draw_diagram

end