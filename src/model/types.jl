module Types

export Port, AbstractBlock, Connection, SimConfig, BlockDiagram, SimResult,
       DiagramError, DuplicateNameError, PortNotFoundError, PortAlreadyConnectedError

abstract type DiagramError <: Exception end

struct DuplicateNameError <: DiagramError
    name :: String
end
Base.showerror(io::IO, e::DuplicateNameError) =
    print(io, "DuplicateNameError: a block named \"$(e.name)\" already exists in this diagram")

struct PortNotFoundError <: DiagramError
    block_name :: String
    port       :: Symbol
    direction  :: Symbol   # :input or :output
end
Base.showerror(io::IO, e::PortNotFoundError) =
    print(io, "PortNotFoundError: block \"$(e.block_name)\" has no $(e.direction) port :$(e.port)")

struct PortAlreadyConnectedError <: DiagramError
    block_name :: String
    port       :: Symbol
end
Base.showerror(io::IO, e::PortAlreadyConnectedError) =
    print(io, "PortAlreadyConnectedError: input port :$(e.port) of \"$(e.block_name)\" is already driven by a connection")

mutable struct Port
    name::Symbol
    value::Float64
end

abstract type AbstractBlock end

mutable struct Connection
    src_block::AbstractBlock
    src_port::Symbol
    dst_block::AbstractBlock
    dst_port::Symbol
end

mutable struct SimConfig
    tspan :: Tuple{Float64, Float64}
    dt    :: Float64
end

SimConfig() = SimConfig((0.0, 10.0), 0.01)

mutable struct BlockDiagram
    blocks      :: Vector{AbstractBlock}
    connections :: Vector{Connection}
    config      :: SimConfig
end

BlockDiagram() = BlockDiagram(AbstractBlock[], Connection[], SimConfig())

struct SimResult
    t    :: Vector{Float64}
    data :: Dict{String, Vector{Float64}}
end

end
