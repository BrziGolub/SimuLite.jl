# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-06-23 — session 4)

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
- **Icon-card block visual style** (wireframe Style C) — each block is split into two zones: top ~70% is a tinted icon zone with the type symbol (`⎍`, `Σ`, `PID`, `∿`, …), bottom 30% is a white name strip. Three category border colors: blue (`_BLUE_BORDER`) for Sources + most Math, amber (`_AMGR_BORDER`) for PID, green (`_GRNN_BORDER`) for Sinks. Selection uses bright dodgerblue `_SEL_COLOR`; deselect restores the block's natural `border_color` stored in `BlockVisual`.
- **Blue wires** — connections drawn in `_WIRE_COLOR = RGBf(0.19, 0.43, 0.69)` (linewidth 1.8); turn orange `_ORA_COLOR` on selection, restored on deselect.
- **Dot grid canvas** — 825 scatter dots at 0.5-unit spacing on warm-white background `RGBf(0.98, 0.98, 0.97)`; dots zoom with the canvas naturally.
- **2-row toolbar** — row 1: thin 24px menubar strip with "SimuLite" bold title + File/Edit/View/Diagram/Simulation/Help labels; row 2: green `▶ Run` button, visual `│` separators, `Start: [t0] → Stop: [t1]`, `dt: [dt]`, `Clear`.
- **Block Library panel** (2-column layout, 140px total):
  - Row 1: "Block Library" bold header
  - Row 2: `⌕` icon (col 1, 28px) + search `Textbox` (col 2, Auto)
  - Rows 3–6: Sources / Math / Sinks / File tab buttons (span 1:2)
  - Rows 7+: icon chip (col 1, category-colored symbol) + name button (col 2)
  - `next_content_row` Ref (starts at 7, reset on `clear_pal!`) tracks next row; no more `length(pal_items[]) + 5` offset
  - `search_obs` Observable + `on(tb_search.stored_string)` → live filter; `_build_pal!(items)` rebuilds from 4-tuple `(sym, color, label, factory)` list; File tab excluded from search
- **Dynamic block height** — `_block_height(block)` scales height as `max(BLOCK_H, PORT_HIT × 1.4 × (n_ports + 1))` so port hit-circles never overlap on multi-port blocks (e.g. Scope ×3).
- **Floating properties windows** — double-clicking any non-Scope block opens a dedicated `GLMakie.Screen` (300×380 px) with editable fields; tracked per-block in `prop_screens` dict; replaced on re-open. `_clear_all!` closes all prop windows.
- **Scope windows** — `ScopeBlock` opens a dedicated `GLMakie.Screen` window on double-click; tracked per-block in `scope_screens` dict; `screen.window_open[]` guards against duplicate windows; old window is always replaced on re-run.
- **JSON save/load** — `save_diagram`/`_reconstruct_block` live at module level in `canvas.jl`; the file format stores block type name, constructor params, name, position, and connections by block-name references.
- **`draw_diagram` default argument** — `draw_diagram(diagram::BlockDiagram = BlockDiagram())` so both `draw_diagram()` (empty canvas) and `draw_diagram(d)` (pre-populated) work with a single method.

---

## GUI — COMPLETE (Phases 1–10)

### What `draw_diagram()` gives you
Opening the GUI shows a 3-row window sized to 92 × 88% of the primary monitor:

| Area | Location | Purpose |
|---|---|---|
| Menubar strip | row 1, top 24px | SimuLite title + File/Edit/View/Diagram/Simulation/Help labels |
| Toolbar | row 1 (auto height) | Green ▶ Run, Start/Stop time fields, dt field, Clear |
| Block Library | row 2, left (140px) | Header + search box + 4 tabs; blocks shown as icon chip + name |
| Canvas | row 2, right (Auto) | Dot-grid warm-white background; blocks as icon cards; blue wires |
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

### Palette widget squashing *(likely fixed — needs confirmation)*
Previously: buttons/inputs sometimes rendered at near-zero height when switching tabs.
Session 4 changed the row tracking from `length(pal_items[]) + 5` (accumulated offset) to
`next_content_row[]` (explicit counter, reset to 7 on `clear_pal!`). This eliminates the ghost-row
accumulation that was the suspected root cause. `trim!(palette_grid)` is still called.
**Status**: needs user confirmation that squashing no longer occurs after tab switches.

---

## Remaining work

### Polish items (if time allows before thesis demo)
- ~~Block type label displayed inside the rectangle~~ — **done** (icon zone with type symbol)
- ~~Per-type block colors~~ — **done** (blue/amber/green by category; PID gets amber accent)
- Confirm palette squashing bug is resolved (see Known bugs above)
- Right-click context menu to delete block or wire
- Port name labels on hover
- Snap-to-grid for block positioning
- Undo/redo stack
- Rename validation (reject empty names, reject duplicate names before committing)

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
