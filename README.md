# SimuLite.jl

Lightweight block diagram simulator written in Julia, inspired by MATLAB Simulink.
Built as a university thesis project.

## Features

- **Interactive GUI** — drag-and-drop canvas, tabbed block palette, bezier wires, zoom/pan
- **Double-click to edit** — every block opens a floating properties window on double-click
- **18 built-in blocks** across sources, math, and sinks categories
- **Two simulation backends** — fixed-step discrete runner and symbolic ODE compiler via ModelingToolkit
- **Save / load** — diagrams serialized to JSON
- **Scope windows** — dedicated plot window per Scope block, opened after simulation

## Requirements

- Julia 1.9+
- Dependencies (installed automatically via `Pkg`):
  - [GLMakie](https://github.com/MakieOrg/Makie.jl) — GUI and plotting
  - [DifferentialEquations.jl](https://github.com/SciML/DifferentialEquations.jl) — ODE solver backend
  - [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl) — symbolic ODE compiler
  - [JSON3.jl](https://github.com/quinnj/JSON3.jl) — diagram save/load

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/BrziGolub/SimuLite.jl")
```

Or clone and use locally:

```julia
using Pkg
Pkg.develop(path="path/to/SimuLite")
```

## Running

```julia
using SimuLite

# Open an empty canvas — build the diagram in the GUI
draw_diagram()
```

That's it. A full-screen window opens with the block palette on the left and the canvas on the right.

## GUI Interactions

| Action | How |
|---|---|
| Add block | Click a block button in the palette (Sources / Math / Sinks tabs) |
| Move block | Left-click drag |
| Select block | Left-click → blue border; press **Delete** to remove |
| Edit parameters | Double-click any block → floating Properties window |
| Draw wire | Click an output port (red circle) → click an input port (blue circle) |
| Cancel wire | **Escape** |
| Delete wire | Click the wire to select it (turns orange) → **Delete** |
| Run simulation | Click **▶ Run** in the toolbar |
| View scope | Double-click a Scope block after running |
| Save diagram | File tab → enter filename → **Save** |
| Load diagram | File tab → enter filename → **Load** |
| Zoom / pan canvas | Scroll to zoom; double-click empty canvas to reset view |
| Clear all | Click **Clear** — closes all open windows and resets the canvas |

## Mixing CLI and GUI

You can also build a diagram programmatically and open it in the GUI pre-populated:

```julia
using SimuLite

d = BlockDiagram()

step  = add_block!(d, StepBlock(; step_time=1.0, after=1.0))
gain  = add_block!(d, GainBlock(2.0))
scope = add_block!(d, ScopeBlock())

connect!(d, step, :out, gain,  :in)
connect!(d, gain, :out, scope, :in1)

d.config.tspan = (0.0, 5.0)
d.config.dt    = 0.01

draw_diagram(d)   # opens GUI with the diagram already loaded
```

Or run a simulation entirely from the REPL without opening a window:

```julia
result = simulate(d)
# result.t        — time vector
# result.data     — Dict of signal vectors, keyed by "blockname.portname"
```

## Block Catalog

### Sources

| Block | Constructor | Output |
|---|---|---|
| `ConstantBlock` | `ConstantBlock(value)` | Constant scalar |
| `StepBlock` | `StepBlock(; step_time, before, after)` | Step at `step_time` |
| `SineBlock` | `SineBlock(; amplitude, frequency, phase, offset)` | Sinusoidal |
| `RampBlock` | `RampBlock(; slope, start_time, bias)` | Linear ramp |
| `ClockBlock` | `ClockBlock()` | Current simulation time `t` |

### Math

| Block | Constructor | Notes |
|---|---|---|
| `GainBlock` | `GainBlock(k)` | `y = k·u` |
| `SumBlock` | `SumBlock("+-")` | Signs string, one `+`/`-` per input |
| `IntegratorBlock` | `IntegratorBlock(x0)` | Forward Euler, initial state `x0` |
| `UnitDelayBlock` | `UnitDelayBlock(x0)` | Discrete z⁻¹ |
| `ProductBlock` | `ProductBlock([:mul, :div])` | Per-port multiply or divide |
| `SaturationBlock` | `SaturationBlock(; lower, upper)` | `clamp(u, lower, upper)` |
| `AbsBlock` | `AbsBlock()` | `y = abs(u)` |
| `DerivativeBlock` | `DerivativeBlock(; N)` | Filtered derivative `H(s)=Ns/(s+N)` |
| `PIDBlock` | `PIDBlock(; Kp, Ki, Kd, N, out_min, out_max)` | Full PID with derivative filter and output clamp |
| `LookupTable1DBlock` | `LookupTable1DBlock(bp, vals)` | Linear interpolation, clamp extrapolation |

### Sinks

| Block | Constructor | Notes |
|---|---|---|
| `ScopeBlock` | `ScopeBlock(; title, n_ports)` | 1–3 inputs; plot window on double-click |
| `WorkspaceBlock` | `WorkspaceBlock()` | Pass-through tap; logged as `name.out` in `SimResult.data` |
| `TerminatorBlock` | `TerminatorBlock()` | No-op sink; caps unused output ports |

## Simulation API

```julia
# Fixed-step runner (used by GUI)
result = simulate(diagram)
result = simulate(diagram; tspan=(0.0, 10.0), dt=0.01)

# Symbolic ODE compiler via ModelingToolkit (more accurate for integrators)
result = simulate_ode(diagram)

# Accessing results
result.t                        # Vector{Float64} — time steps
result.data["gain1.out"]        # Vector{Float64} — signal from gain1's output port
```

## Project Structure

```
src/
  SimuLite.jl          — top-level module and exports
  model/
    types.jl           — core types: Port, AbstractBlock, Connection, SimConfig, BlockDiagram, SimResult
    diagram.jl         — add_block!, connect!, disconnect!, remove_block!
    blocks/
      api.jl           — evaluate!, commit_state!, input_ports, output_ports
      common.jl        — BlockBase
      sources.jl       — ConstantBlock, StepBlock, SineBlock, RampBlock, ClockBlock
      math.jl          — GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock,
                         ProductBlock, SaturationBlock, AbsBlock,
                         DerivativeBlock, PIDBlock, LookupTable1DBlock
      sinks.jl         — ScopeBlock, WorkspaceBlock, TerminatorBlock
  sim/
    runner.jl          — fixed-step simulation loop
    compiler.jl        — ODE compiler via ModelingToolkit
  gui/
    canvas.jl          — full GUI (draw_diagram)
```

## License

MIT
