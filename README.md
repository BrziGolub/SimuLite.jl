# SimuLite.jl

Lightweight block diagram simulator written in Julia, inspired by MATLAB Simulink.
Built as a university thesis project.

## Features

- **Interactive GUI** — drag-and-drop canvas, block palette, zoom/pan, undo/redo (buttons + Ctrl+Z / Ctrl+Y)
- **Block Library panel** — collapsible categories with toggle switches, search box, and mouse-wheel scrolling when the list overflows the window
- **Double-click to edit** — every block opens a floating properties window (Apply / Cancel); the Transfer Fn block's numerator/denominator coefficients are editable in place
- **20 built-in blocks** across sources, math, and sinks categories
- **Simulink-style Sum block** — circular block with per-port `+`/`−` sign glyphs; feedback-fed ports drop to the bottom of the circle
- **Feedback loops** — closed-loop diagrams work when the cycle contains a memory block (Integrator, UnitDelay, TransferFn, StateSpace); feedback wires route at right angles through a channel below the diagram and enter the bottom of the Sum block. Forward wires stay smooth curves.
- **Two simulation backends** — fixed-step discrete runner and symbolic ODE compiler via ModelingToolkit
- **Save / load** — diagrams serialized to JSON
- **Scope windows** — dedicated plot window per Scope block, opened after simulation

## Requirements

- Julia 1.9+
- Dependencies (installed automatically via `Pkg`):
  - [GLMakie](https://github.com/MakieOrg/Makie.jl) — GUI and plotting
  - [JSON3.jl](https://github.com/quinnj/JSON3.jl) — diagram save/load
- Optional (weak) dependencies — only needed for the symbolic ODE backend (`simulate_ode`):
  - [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl) — symbolic ODE compiler
  - [DifferentialEquations.jl](https://github.com/SciML/DifferentialEquations.jl) — ODE solver
  - Install them in your environment and `using ModelingToolkit, DifferentialEquations` activates the backend automatically

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
| Add block | Expand a palette category (toggle switch) or search → click the block chip |
| Scroll block library | Mouse wheel over the palette when the list overflows (⇕ hint row appears) |
| Move block | Left-click drag |
| Select block | Left-click → blue border; press **Delete** to remove |
| Edit parameters | Double-click any block → Properties window; **Apply** commits, **Cancel** discards |
| Edit Scope properties | **Ctrl + double-click** a Scope block |
| Draw wire | Click an output port (red circle) → click an input port (blue circle) |
| Cancel wire | **Escape** |
| Delete wire | Click the wire to select it (turns orange) → **Delete** |
| Undo / Redo | Toolbar **↶ Undo** / **↷ Redo** buttons, or **Ctrl+Z** / **Ctrl+Y** (Ctrl+Shift+Z also redoes) |
| Run simulation | Click **▶ Run** in the toolbar |
| View scope | Double-click a Scope block after running |
| Save diagram | Enter filename in toolbar textbox → click **Save** |
| Load diagram | Enter filename in toolbar textbox → click **Load** |
| Zoom / pan canvas | Scroll to zoom, or toolbar **− / +** buttons (the % label tracks every zoom); double-click empty canvas to reset view |
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

### Feedback / closed-loop example

```julia
using SimuLite

d = BlockDiagram()
ref   = add_block!(d, ConstantBlock(1.0;  name="ref"))
err   = add_block!(d, SumBlock("+-";      name="err"))
ctrl  = add_block!(d, PIDBlock(Kp=2.0, Ki=1.0, Kd=0.0; name="ctrl"))
plant = add_block!(d, IntegratorBlock(0.0; name="plant"))
scope = add_block!(d, ScopeBlock(;        name="scope"))

connect!(d, ref,   :out, err,   :in1)   # reference
connect!(d, plant, :out, err,   :in2)   # feedback
connect!(d, err,   :out, ctrl,  :in)
connect!(d, ctrl,  :out, plant, :in)
connect!(d, plant, :out, scope, :in1)

result = simulate(d; tspan=(0.0, 5.0), dt=0.01)
draw_diagram(d)   # open in GUI: feedback wire routes at a right angle into the bottom of `err`
```

The loop must contain at least one memory block (Integrator, UnitDelay, TransferFn/StateSpace with D=0, or an I-only PID with Kp=Kd=0). A cycle of only direct-feedthrough blocks throws `AlgebraicLoopError`, which names the blocks forming the loop and suggests where to insert a memory block.

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
| `SumBlock` | `SumBlock("+-")` | Signs string, one `+`/`-` per input; circular block, `in1…inN` top-to-bottom |
| `IntegratorBlock` | `IntegratorBlock(x0)` | Forward Euler, initial state `x0` |
| `UnitDelayBlock` | `UnitDelayBlock(x0)` | Discrete z⁻¹ |
| `ProductBlock` | `ProductBlock([:mul, :div])` | Per-port multiply or divide |
| `SaturationBlock` | `SaturationBlock(; lower, upper)` | `clamp(u, lower, upper)` |
| `AbsBlock` | `AbsBlock()` | `y = abs(u)` |
| `DerivativeBlock` | `DerivativeBlock(; N)` | Filtered derivative `H(s)=Ns/(s+N)` |
| `PIDBlock` | `PIDBlock(; Kp, Ki, Kd, N, out_min, out_max)` | Full PID with derivative filter and output clamp |
| `LookupTable1DBlock` | `LookupTable1DBlock(bp, vals)` | Linear interpolation, clamp extrapolation |
| `TransferFnBlock` | `TransferFnBlock(num, den)` | Continuous SISO transfer function; ZOH-discretized |
| `StateSpaceBlock` | `StateSpaceBlock(A, B, C, D)` | Continuous state-space model; ZOH-discretized |

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

# Symbolic ODE compiler via ModelingToolkit (more accurate for integrators).
# Requires the optional dependencies — install once with
#   import Pkg; Pkg.add(["ModelingToolkit", "DifferentialEquations"])
using ModelingToolkit, DifferentialEquations   # activates the ODE backend
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
      api.jl           — evaluate!, commit_state!, initialize!, input_ports, output_ports
      common.jl        — BlockBase
      sources.jl       — ConstantBlock, StepBlock, SineBlock, RampBlock, ClockBlock
      math.jl          — GainBlock, SumBlock, IntegratorBlock, UnitDelayBlock,
                         ProductBlock, SaturationBlock, AbsBlock,
                         DerivativeBlock, PIDBlock, LookupTable1DBlock,
                         TransferFnBlock, StateSpaceBlock
      sinks.jl         — ScopeBlock, WorkspaceBlock, TerminatorBlock
  sim/
    runner.jl          — fixed-step simulation loop
    compiler.jl        — stubs for the ODE backend (real impl in ext/)
  gui/
    canvas.jl          — full GUI (draw_diagram)
ext/
  SimuLiteCompilerExt.jl — ODE compiler via ModelingToolkit (package extension)
```

## License

MIT
