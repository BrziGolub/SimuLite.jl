module SimuLite

include("model/types.jl")
include("model/blocks/api.jl")
include("model/blocks/common.jl")
include("model/blocks/sources.jl")
include("model/blocks/math.jl")
include("model/diagram.jl")
include("sim/compiler.jl")
include("sim/runner.jl")

using .Types
using .BlocksAPI
using .Diagram
using .BlocksCommon
using .BlocksSources
using .BlocksMath
using .Compiler
using .Runner

export BlockDiagram, SimConfig, SimResult, add_block!, connect!, disconnect!, remove_block!
export DiagramError, DuplicateNameError, PortNotFoundError, PortAlreadyConnectedError
export input_ports, output_ports
export ConstantBlock, StepBlock, SineBlock, GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock
export simulate_ode
export simulate

end