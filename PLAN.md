# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-06-19)

### Simulation engine — COMPLETE
- Fixed-step discrete runner (`simulate`) — feed-forward chains, integrators, unit delays
- ODE compiler path via ModelingToolkit (`simulate_ode`) — symbolic ODE system, adaptive solver
- Two-phase execution: `evaluate!` (output current state) → inline propagation → `commit_state!` (advance state)
- Topological sort (Kahn's algorithm) — blocks always executed in dependency order
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
- No save/load to file

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
  gui/                      — NEXT PHASE (empty)
```

---

## Key design decisions (permanent)
- **Two-phase execution** — `evaluate!` outputs current state, `commit_state!` advances it. Matches Simulink's Output/Update method split.
- **Topological sort at simulation start** — blocks always evaluated upstream-first.
- **`name::String` on all blocks** — used as `SimResult.data` key prefix and MTK symbolic variable name.
- **`SumBlock` takes a signs string** — `"+-"` enables subtraction for feedback error signals.
- **Two simulation backends** — runner (fixed-step, fast, used by GUI); compiler (MTK ODE, accurate, available as advanced mode).
- **Custom exception hierarchy** — `DiagramError` subtypes so the GUI can catch specific errors and show user-friendly messages.

---

## Next phase — GUI

### Library choice: GLMakie
Recommended over Gtk/Qt/web approaches because:
- Handles both the diagram canvas and results plots in one framework
- Native Julia, no external toolchain
- Has mouse/keyboard event system sufficient for drag-and-drop
- Observable-based reactivity fits the diagram-as-state model
- Already familiar to anyone in the Julia scientific computing ecosystem

Add to `Project.toml`: `GLMakie`

---

### GUI Phase 1 — Canvas rendering (no interaction)
**Goal:** display a diagram on screen. Nothing is clickable yet.

- Open a `GLMakie` Figure with two panels: left = canvas, right = results (empty for now)
- Render each block as a labeled rectangle at `block.position`
- Render each port as a small circle on the block edge (left side = inputs, right side = outputs)
- Render each connection as a bezier curve from src output port to dst input port
- Create `src/gui/canvas.jl` with a `draw_diagram(diagram)` function

**Done when:** `draw_diagram(d)` opens a window showing the current diagram correctly.

---

### GUI Phase 2 — Block selection and dragging
**Goal:** click a block to select it, drag it to reposition.

- Track selected block in a `Ref{Union{Nothing, AbstractBlock}}`
- On mouse press: hit-test against block bounding boxes, set selected block
- On mouse drag: update `block.position`, redraw canvas
- Highlight selected block with a different border color
- Escape / click empty space = deselect

**Done when:** blocks can be moved around the canvas by dragging.

---

### GUI Phase 3 — Connection drawing
**Goal:** click an output port, then click an input port to wire them.

- Track "wire in progress" state: source block + port stored in a Ref
- On click of an output port: enter wire-drawing mode, draw a rubber-band line to cursor
- On click of an input port: call `connect!(diagram, src, src_port, dst, dst_port)`, exit wire mode
- If `connect!` throws a `PortAlreadyConnectedError` or `PortNotFoundError`: show error label, cancel
- On Escape: cancel wire-drawing

**Done when:** connections can be drawn interactively and appear on the canvas.

---

### GUI Phase 4 — Block palette
**Goal:** add new blocks to the diagram from the GUI.

- Add a sidebar panel listing all available block types
- Click a block type → places it at a default position on the canvas with a generated name
- Double-click a block to rename it (inline text edit)
- Delete key on selected block → calls `remove_block!`, redraws

**Done when:** a full diagram can be built from scratch without writing Julia code.

---

### GUI Phase 5 — Properties panel
**Goal:** view and edit block parameters when a block is selected.

- When a block is selected, show its editable fields in a right panel:
  - `ConstantBlock` → value
  - `GainBlock` → k
  - `StepBlock` → step_time, before, after
  - `SineBlock` → amplitude, frequency, phase, offset
  - `IntegratorBlock` → initial state x0
  - All blocks → name, position (numeric fields)
- Changes apply immediately to the block struct

**Done when:** block parameters can be changed without touching Julia code.

---

### GUI Phase 6 — Simulation control and results
**Goal:** run the simulation and display output plots.

- Add toolbar: Run button, simulation config fields (tspan start/end, dt)
- Run button: calls `simulate(diagram)`, stores `SimResult`
- Results panel: one plot per output signal in `SimResult.data`, x-axis = `result.t`
- Error display: if `simulate` throws (e.g. cycle detected), show message in GUI
- Clear button: resets the diagram

**Done when:** the full workflow — build diagram → run → see plots — works entirely in the GUI.

---

### GUI Phase 7 — Save and load  *(post-demo, if time allows)*
- Serialize `BlockDiagram` to JSON (block types, params, positions, connections)
- File open/save dialogs via `GLMakie` or system dialog
- Load reconstructs the Julia objects and redraws the canvas

---

## Post-thesis backlog
- Algebraic loop resolution (iterative solver for direct-feedthrough cycles)
- Signal vectors / matrices (non-scalar ports)
- Subsystems (hierarchical diagrams with In/Out port blocks)
- Expose `simulate_ode` in GUI as "continuous solver" toggle
- Variable / mixed sample times (continuous + discrete in same diagram)
- Code generation (export diagram as standalone Julia ODE script)
