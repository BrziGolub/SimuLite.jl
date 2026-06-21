# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-06-22 — session 3)

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

### Blocks available — 18 total
| Block | Module | Constructor | Notes |
|---|---|---|---|
| `ConstantBlock` | sources | `ConstantBlock(value)` | Scalar constant output |
| `StepBlock` | sources | `StepBlock(; step_time, before, after)` | Step at configurable time |
| `SineBlock` | sources | `SineBlock(; amplitude, frequency, phase, offset)` | Sinusoidal output |
| `RampBlock` | sources | `RampBlock(; slope, start_time, bias)` | Linear ramp starting at `start_time` |
| `ClockBlock` | sources | `ClockBlock()` | Outputs simulation time `t` |
| `GainBlock` | math | `GainBlock(k)` | Scalar multiply |
| `SumBlock` | math | `SumBlock("+-")` | Configurable signs per input port |
| `IntegratorBlock` | math | `IntegratorBlock(x0)` | Forward Euler, feeds MTK ODE compiler |
| `UnitDelayBlock` | math | `UnitDelayBlock(x0)` | Discrete z⁻¹ |
| `ProductBlock` | math | `ProductBlock(ops)` | `ops` is `Vector{Symbol}` of `:mul`/`:div` per port |
| `SaturationBlock` | math | `SaturationBlock(; lower, upper)` | `clamp(u, lower, upper)` |
| `AbsBlock` | math | `AbsBlock()` | `y = abs(u)` |
| `DerivativeBlock` | math | `DerivativeBlock(; N)` | Filtered derivative `H(s)=Ns/(s+N)`, 1 state var |
| `PIDBlock` | math | `PIDBlock(; Kp, Ki, Kd, N, out_min, out_max)` | 2 state vars (xi, fd); output clamped |
| `LookupTable1DBlock` | math | `LookupTable1DBlock(bp, vals)` | Linear interp, clamp extrapolation |
| `ScopeBlock` | sinks | `ScopeBlock(; title, n_ports)` | Opens dedicated plot window on double-click; 1–3 ports |
| `WorkspaceBlock` | sinks | `WorkspaceBlock()` | Pass-through tap; logged as `name.out` in `SimResult.data` |
| `TerminatorBlock` | sinks | `TerminatorBlock()` | No-op sink — caps unused output ports |

> `TransferFnBlock` and `StateSpaceBlock` require `ControlSystems.jl` — deferred to post-thesis backlog.

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
      sources.jl            — ConstantBlock, StepBlock, SineBlock,
                              RampBlock, ClockBlock
      math.jl               — GainBlock, SumBlock, IntegratorBlock,
                              UnitDelayBlock, ProductBlock,
                              SaturationBlock, AbsBlock,
                              DerivativeBlock, PIDBlock,
                              LookupTable1DBlock
      sinks.jl              — ScopeBlock, WorkspaceBlock, TerminatorBlock
  sim/
    compiler.jl             — ODE compiler via ModelingToolkit
    runner.jl               — fixed-step simulation loop
  gui/
    canvas.jl               — full GUI: canvas, palette (4 tabs),
                              floating properties windows,
                              toolbar, scope windows,
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
- **4-tab palette on the LEFT** — "Sources", "Math", "Sinks", and "File" tabs share the 140px left sidebar; canvas fills all remaining space to the right. `_pal_block!` computes row as `length(pal_items[]) + 5`; `trim!(palette_grid)` called on tab switch to drop ghost empty rows.
- **Dynamic block height** — `_block_height(block)` scales height as `max(BLOCK_H, PORT_HIT × 1.4 × (n_ports + 1))` so port hit-circles never overlap on multi-port blocks (e.g. Scope ×3).
- **Floating properties windows** — double-clicking any non-Scope block opens a dedicated `GLMakie.Screen` (300×380 px) with editable fields; tracked per-block in `prop_screens` dict; replaced on re-open. `_clear_all!` closes all prop windows.
- **Scope windows** — `ScopeBlock` opens a dedicated `GLMakie.Screen` window on double-click; tracked per-block in `scope_screens` dict; `screen.window_open[]` guards against duplicate windows; old window is always replaced on re-run.
- **JSON save/load** — `save_diagram`/`_reconstruct_block` live at module level in `canvas.jl`; the file format stores block type name, constructor params, name, position, and connections by block-name references.
- **`draw_diagram` default argument** — `draw_diagram(diagram::BlockDiagram = BlockDiagram())` so both `draw_diagram()` (empty canvas) and `draw_diagram(d)` (pre-populated) work with a single method.

---

## GUI — COMPLETE (Phases 1–9)

### What `draw_diagram()` gives you
Opening the GUI shows a 3-row window sized to 92 × 88% of the primary monitor:

| Area | Location | Purpose |
|---|---|---|
| Toolbar | row 1 (auto height) | Run, tspan, dt, Clear — always visible at top |
| Palette | row 2, left (140px) | 4 tabs: Sources / Math / Sinks / File |
| Canvas | row 2, right (Auto) | Drag blocks, draw wires — blue border, light blue background |
| Status bar | row 3 (auto height) | Current action / error messages |
| Properties windows | separate OS windows | One per block, opened on double-click |
| Scope windows | separate OS windows | One per ScopeBlock, opened on double-click after run |

### Interactions implemented
| Action | How |
|---|---|
| Add block | Click block button in palette tab → placed at canvas centre |
| Move block | Drag with left mouse; bezier wires follow live |
| Select block | Left click → blue border |
| Edit params | Double-click block → floating Properties window opens |
| Rename block | Edit "Name" field in Properties window → canvas label updates live |
| Draw connection | Click output port (red) → click input port (blue) |
| Delete connection | Click wire → highlights orange → press Delete |
| Cancel wire | Escape |
| Delete block | Select → Delete key; removes block + all its connections |
| Run simulation | Click ▶ Run; last result stored, status bar prompts scope double-click |
| View scope signals | Double-click a ScopeBlock → dedicated plot window opens (no duplicates) |
| Change tspan/dt | Edit toolbar textboxes before running |
| Clear diagram | Click Clear button; closes all scope + properties windows |
| Zoom / pan canvas | Scroll to zoom; double-click empty area to reset view |
| Save diagram | File tab → set filename → Save |
| Load diagram | File tab → set filename → Load (clears canvas first) |

---

## Known bugs / open issues

### Palette widget squashing *(not yet fixed)*
Buttons and input fields in the palette sometimes render at near-zero height.
Attempted fix (`trim!(palette_grid)` after `clear_pal!()`) has not confirmed resolution.
**Root cause hypothesis**: GLMakie retains row height metadata for deleted cells even after `trim!`;
the layout engine distributes height across all historically-created rows rather than only currently-populated ones.
**Next steps to investigate**:
- Use explicit `rowsize!(palette_grid, r, Auto())` after trim
- Or rebuild `palette_grid` from scratch on each tab switch instead of deleting/re-adding widgets

---

## Remaining work

### Polish items (if time allows before thesis demo)
- Block type label displayed inside the rectangle (e.g. "Gain" subtitle above block name)
- Per-type block colors (`BLOCK_COLOR` dict keyed on block type) — makes canvas look more Simulink-like
- Right-click context menu to delete block or wire
- Port name labels on hover
- Snap-to-grid for block positioning
- Undo/redo stack
- Rename validation (reject empty names, reject duplicate names before committing)
- Fix palette widget squashing bug (see Known bugs above)

### GUI dependency decision (permanent)
The GUI stays on **GLMakie only** — no Gtk.jl or Cairo.jl.
GLMakie covers all needed features (canvas, events, zoom/pan, plots, text input).
The only trade-off is no native OS file dialog; the filename-in-textbox approach is adequate for thesis.

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
  test_blocks.jl       — constructors and field defaults for all 18 blocks,
                         evaluate! / commit_state! round-trips,
                         input_ports / output_ports counts
  test_runner.jl       — simulate() on: constant feed-forward,
                         gain chain, step response, integrator (ramp),
                         unit delay (one-step shift), PID step response
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
- `README.md` — DONE (install instructions, usage examples, full block catalog)

---

## Post-thesis backlog
- Algebraic loop resolution (iterative solver for direct-feedthrough cycles)
- Signal vectors / matrices (non-scalar ports)
- Subsystems (hierarchical diagrams with In/Out port blocks)
- Expose `simulate_ode` in GUI as "continuous solver" toggle
- Variable / mixed sample times (continuous + discrete in same diagram)
- Code generation (export diagram as standalone Julia ODE script)
- `TransferFnBlock` and `StateSpaceBlock` via `ControlSystems.jl` (deferred to avoid dependency during thesis)
