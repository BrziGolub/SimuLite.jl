# SimuLite — Development Plan

## Project goal
A Julia-based block diagram simulator modelled after MATLAB Simulink, built for a university thesis.
Target: working GUI on top of a solid simulation engine.

---

## Current state (as of session 2026-06-20 — session 2)

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
| `ScopeBlock` | sinks | `ScopeBlock(; title, n_ports)` | Opens dedicated plot window on double-click; 1–3 input ports |

### Missing blocks (planned — from reference catalog)

#### Sources *(trivial, no new dependencies)*
| Block | Constructor | Output |
|---|---|---|
| `RampBlock` | `RampBlock(; slope, start_time, bias)` | `bias + (t >= start_time) ? slope*(t-start_time) : 0` |
| `ClockBlock` | `ClockBlock()` | `y = t` |

#### Math *(feedthrough unless noted)*
| Block | Constructor | Notes |
|---|---|---|
| `ProductBlock` | `ProductBlock(ops)` | `ops` is `Vector{Symbol}` of `:mul`/`:div` per port |
| `SaturationBlock` | `SaturationBlock(; lower, upper)` | `clamp(u, lower, upper)` |
| `AbsBlock` | `AbsBlock()` | `y = abs(u)` |
| `LookupTable1DBlock` | `LookupTable1DBlock(bp, vals)` | Linear interp, clamp extrapolation |
| `DerivativeBlock` | `DerivativeBlock(; N)` | Filtered derivative `H(s)=Ns/(s+N)`, 1 state var |

#### Control *(stateful, pure Julia — no ControlSystems.jl needed)*
| Block | Constructor | Notes |
|---|---|---|
| `PIDBlock` | `PIDBlock(; Kp, Ki, Kd, N, out_min, out_max)` | 2 state vars (xi, xd); direct state-space form |

> `TransferFnBlock` and `StateSpaceBlock` from the reference require `ControlSystems.jl` and are deferred to the post-thesis backlog to keep dependencies minimal.

#### Sinks *(0 outputs, no state)*
| Block | Constructor | Notes |
|---|---|---|
| `WorkspaceBlock` | `WorkspaceBlock(; var_name)` | Saves `(t, y)` to `SimResult.workspace[var_name]` |
| `TerminatorBlock` | `TerminatorBlock()` | No-op sink — silences unconnected output warnings |

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
      sinks.jl              — ScopeBlock
  sim/
    compiler.jl             — ODE compiler via ModelingToolkit
    runner.jl               — fixed-step simulation loop
  gui/
    canvas.jl               — full GUI: canvas, palette (4 tabs),
                              properties, toolbar, scope windows,
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
- **4-tab palette** — "Sources", "Math", "Sinks", and "File" tabs share the 140px sidebar; each tab exclusively shows its own blocks starting at palette grid row 5 (rows 1–4 are the tab buttons); `_pal_block!` computes row as `length(pal_items[]) + 5`.
- **Dynamic block height** — `_block_height(block)` scales height as `max(BLOCK_H, PORT_HIT × 1.4 × (n_ports + 1))` so port hit-circles never overlap on multi-port blocks (e.g. Scope ×3).
- **Scope windows** — `ScopeBlock` opens a dedicated `GLMakie.Screen` window on double-click; tracked per-block in `scope_screens` dict; `screen.window_open[]` guards against duplicate windows; old window is always replaced on re-run.
- **JSON save/load** — `save_diagram`/`_reconstruct_block` live at module level in `canvas.jl`; the file format stores block type name, constructor params, name, position, and connections by block-name references.

---

## GUI — COMPLETE (Phases 1–8)

### What `draw_diagram(diagram)` gives you
Opening the GUI with `draw_diagram(d)` shows a 3-row window sized to 92 × 88% of the primary monitor:

| Area | Location | Purpose |
|---|---|---|
| Toolbar | row 1 (auto height) | Run, tspan, dt, Clear — always visible at top |
| Canvas | row 2, left (Auto) | Drag blocks, draw wires — blue border, light blue background |
| Palette | row 2, middle (140px) | 4 tabs: Sources / Math / Sinks / File |
| Properties | row 2, right (200px) | Edit selected block parameters |
| Status bar | row 3 (auto height) | Current action / error messages |
| Scope windows | separate OS windows | One per ScopeBlock, opened on double-click |

### Interactions implemented
| Action | How |
|---|---|
| Add block | Click block button in palette tab → placed at canvas centre |
| Move block | Drag with left mouse; bezier wires follow live |
| Select block | Left click → blue border + properties panel opens |
| Edit params | Type in properties textbox, press Enter |
| Rename block | Edit "Name" field in properties → canvas label updates |
| Draw connection | Click output port (red) → click input port (blue) |
| Delete connection | Click wire → highlights orange → press Delete |
| Cancel wire | Escape |
| Delete block | Select → Delete key; removes block + all its connections |
| Run simulation | Click ▶ Run; last result stored, status bar prompts scope double-click |
| View scope signals | Double-click a ScopeBlock → dedicated plot window opens (no duplicates) |
| Change tspan/dt | Edit toolbar textboxes before running |
| Clear diagram | Click Clear button; closes all open scope windows |
| Zoom / pan canvas | Scroll to zoom; double-click empty area to reset view |
| Save diagram | File tab → set filename → Save |
| Load diagram | File tab → set filename → Load (clears canvas first) |

---

## Remaining work

### Polish items (if time allows before thesis demo)
- Block type label displayed inside the rectangle (e.g. "Gain" subtitle above block name)
- Per-type block colors (`BLOCK_COLOR` dict keyed on block type) — makes canvas look more Simulink-like
- Right-click to delete block or wire (currently Delete key only)
- Port name labels on hover
- Snap-to-grid for block positioning
- Undo/redo stack
- Rename validation (reject empty names, reject duplicate names before committing)

### GUI dependency decision (permanent)
The GUI stays on **GLMakie only** — no Gtk.jl or Cairo.jl.
GLMakie covers all needed features (canvas, events, zoom/pan, plots, text input).
The only trade-off is no native OS file dialog; the filename-in-textbox approach is adequate for thesis.
The Gtk+Cairo architecture in `simulite_reference.md §3` is reference material only — not a migration target.

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
  test_blocks.jl       — constructors and field defaults for all 8 blocks
                         (including ScopeBlock: n_ports, title, evaluate! no-op),
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
- `TransferFnBlock` and `StateSpaceBlock` via `ControlSystems.jl` (deferred to avoid dependency during thesis)
