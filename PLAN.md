# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-06-20)

### Simulation engine — COMPLETE
- Fixed-step discrete runner (`simulate`) — feed-forward chains, integrators, unit delays
- ODE compiler path via ModelingToolkit (`simulate_ode`) — symbolic ODE system, adaptive solver
- Two-phase execution: `evaluate!` (output current state) → inline propagation → `commit_state!` (advance state)
- Topological sort (Kahn's algorithm) — blocks always evaluated in dependency order
- `simulate` returns `SimResult(t, data)` — time vector + named signal vectors

### Model layer — COMPLETE
- `BlockDiagram` with `SimConfig` (tspan, dt) and `Vector{Connection}`
- `add_block!` validates unique names → throws `DuplicateNameError`
- `connect!` validates port existence and no double-driven inputs → throws `PortNotFoundError`, `PortAlreadyConnectedError`
- `disconnect!` and `remove_block!` (removes block + all its connections)
- `input_ports(block)` / `output_ports(block)` — stable GUI API for port introspection
- All blocks have `name::String` and `position::Tuple{Float64,Float64}`

### Blocks available
| Block | Module | Constructor | Notes |
|---|---|---|---|
| `ConstantBlock` | sources | `ConstantBlock(value)` | Scalar constant output |
| `StepBlock` | sources | `StepBlock(; step_time, before, after)` | Step at configurable time |
| `SineBlock` | sources | `SineBlock(; amplitude, frequency, phase, offset)` | Sinusoidal output |
| `GainBlock` | math | `GainBlock(k)` | Scalar multiply |
| `SumBlock` | math | `SumBlock("+-")` | Configurable signs per input port |
| `IntegratorBlock` | math | `IntegratorBlock(x0; name)` | Forward Euler, feeds MTK ODE compiler |
| `UnitDelayBlock` | math | `UnitDelayBlock(x0)` | Discrete z⁻¹ |

### Known limitations (deferred)
- No algebraic loop solving — cycles in the diagram error out
- All signals are scalar `Float64` only
- No subsystems / hierarchical diagrams

---

## File map
```
src/
  SimuLite.jl               — top-level module and exports
  model/
    types.jl                — Port, AbstractBlock, Connection,
                              SimConfig, BlockDiagram, SimResult,
                              DiagramError subtypes
    diagram.jl              — add_block!, connect!, disconnect!,
                              remove_block!, get_execution_order
    blocks/
      api.jl                — evaluate!, commit_state!,
                              input_ports, output_ports
      common.jl             — BlockBase, _next_id() counter
      sources.jl            — ConstantBlock, StepBlock, SineBlock
      math.jl               — GainBlock, SumBlock, IntegratorBlock,
                              UnitDelayBlock
  sim/
    compiler.jl             — ODE compiler via ModelingToolkit
    runner.jl               — fixed-step simulation loop
  gui/
    canvas.jl               — full GUI: canvas, palette (tabbed),
                              properties, toolbar, results,
                              save/load (draw_diagram)
test/
  runtests.jl               — (planned) main test entry point
```

---

## Key design decisions (permanent)
- **Two-phase execution** — `evaluate!` outputs current state, `commit_state!` advances it. Matches Simulink's Output/Update method split.
- **Topological sort at simulation start** — blocks always evaluated upstream-first.
- **`name::String` on all blocks** — used as `SimResult.data` key prefix and MTK symbolic variable name.
- **`SumBlock` takes a signs string** — `"+-"` enables subtraction for feedback error signals.
- **Two simulation backends** — runner (fixed-step, fast, used by GUI); compiler (MTK ODE, accurate, available as advanced mode).
- **Custom exception hierarchy** — `DiagramError` subtypes so the GUI can catch specific errors and show user-friendly messages.
- **Observable-based GUI** — block centers, port positions, and connection curves are all `@lift`-derived Observables; dragging a block updates everything reactively without explicit redraws.
- **Tabbed palette** — "Blocks" and "File" tabs share the same 140px sidebar column; tab switching clears and rebuilds the content area dynamically (same delete/recreate pattern as the Properties panel).
- **JSON save/load** — `save_diagram`/`_reconstruct_block` live at module level in `canvas.jl`; the file format stores block type name, constructor params, name, position, and connections by block-name references.

---

## GUI — COMPLETE (Phases 1–7)

### What `draw_diagram(diagram)` gives you
Opening the GUI with `draw_diagram(d)` shows a 4-row window sized to 92 × 88% of the primary monitor:

| Area | Location | Purpose |
|---|---|---|
| Canvas | top-left (Auto) | Drag blocks, draw wires — blue border, light blue background |
| Palette | top-middle (140px) | Tabbed: Blocks tab (Sources / Math) or File tab (save/load) |
| Properties | top-right (200px) | Edit selected block parameters |
| Toolbar | row 2 (auto height) | Run, tspan, dt, Clear |
| Results | row 3 (28%) | Signal plots after Run |
| Status bar | row 4 (auto height) | Current action / error messages |

### Interactions implemented
| Action | How |
|---|---|
| Add block | Click block button in "Blocks" tab → placed at canvas centre |
| Move block | Drag with left mouse; bezier wires follow live |
| Select block | Left click → blue border + properties panel opens |
| Edit params | Type in properties textbox, press Enter |
| Rename block | Edit "Name" field in properties → canvas label updates |
| Draw connection | Click output port (red) → click input port (blue) |
| Delete connection | Click wire → highlights orange → press Delete |
| Cancel wire | Escape |
| Delete block | Select → Delete key; removes block + all its connections |
| Run simulation | Click ▶ Run; signal plots appear in Results panel |
| Change tspan/dt | Edit toolbar textboxes before running |
| Clear diagram | Click Clear button |
| Zoom / pan canvas | Scroll to zoom; double-click to reset view |
| Save diagram | File tab → set filename → Save |
| Load diagram | File tab → set filename → Load (clears canvas first) |

---

## Remaining work

### Polish items (if time allows before thesis demo)
- Block type label displayed inside the rectangle (e.g. "Gain" subtitle above block name)
- Port name labels on hover
- Snap-to-grid for block positioning
- Undo/redo stack
- Rename validation (reject empty names, reject duplicate names before committing)

---

## Testing infrastructure *(required for Julia General Registry)*

Julia's General Registry requires a package to have a passing `test/runtests.jl` and proper `[compat]` bounds. Planned test structure:

```
test/
  runtests.jl          — @testset "SimuLite" includes all sub-suites
  test_types.jl        — Port, Connection, SimConfig, BlockDiagram,
                         SimResult, DiagramError subtypes
  test_diagram.jl      — add_block!, connect!, disconnect!,
                         remove_block!, get_execution_order,
                         error path coverage (DuplicateNameError,
                         PortNotFoundError, PortAlreadyConnectedError)
  test_blocks.jl       — constructors and field defaults for all 7 blocks,
                         evaluate! / commit_state! round-trips,
                         input_ports / output_ports counts
  test_runner.jl       — simulate() on: constant feed-forward,
                         gain chain, step response, integrator (ramp),
                         unit delay (one-step shift)
  test_compiler.jl     — simulate_ode() on integrator block (ramp),
                         compare result with runner to within tolerance
  test_io.jl           — save_diagram / load round-trip:
                         same block count, params, and connections
                         after save → new diagram → load
```

### Additional registry checklist
- `[compat]` entries for all direct deps (GLMakie, JSON3, DifferentialEquations, ModelingToolkit)
- Public API docstrings on `draw_diagram`, `simulate`, `simulate_ode`, all block constructors, `add_block!`, `connect!`, `disconnect!`, `remove_block!`
- Semantic versioning: bump to `0.2.0` once tests pass
- `LICENSE` file (MIT recommended for Julia ecosystem packages)
- `README.md` with install instructions and a minimal usage example

---

## Post-thesis backlog
- Algebraic loop resolution (iterative solver for direct-feedthrough cycles)
- Signal vectors / matrices (non-scalar ports)
- Subsystems (hierarchical diagrams with In/Out port blocks)
- Expose `simulate_ode` in GUI as "continuous solver" toggle
- Variable / mixed sample times (continuous + discrete in same diagram)
- Code generation (export diagram as standalone Julia ODE script)
