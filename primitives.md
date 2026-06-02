# δ-lang: Primitive Functions & Values — SETTLED

## Overview

Primitives (`PrimFun`, `PrimVal`) are Phase C extensions for runtime computation. NOT in main.tex. Never interact with core reduction rules R1-R7.

**Design principle**: strict separation. Paper agents (Fan, Rep, Eraser) ↔ core rules (R1-R7, C1-C4). Primitive agents ↔ `prim_apply` rules only. Dispatcher enforces isolation via `kind` field bitmasking.

---

## Agent Representation

### PrimVal

Opaque runtime value (number, string, boolean, attribute set, etc.). Stored in side table `Net.prim_vals[prim_id]`.

| Field | Type | Purpose |
|-------|------|---------|
| `prim_id` | u32 | Index into `prim_vals` vector |
| `tag` | u8 | `PrimVal` = `0xC` (`0b1100`); net.md tag layout |
| Zero ports | - | No principal, no auxiliary |

### PrimFun

Curried 1-ary function. Stores applied arguments, remaining arity, and `apply` closure.

| Field | Type | Purpose |
|-------|------|---------|
| `prim_id` | u32 | Index into `prim_fns` vector |
| `tag` | u8 | `PrimFun` = `0xD` (`0b1101`); net.md tag layout |
| `principal` | PortId | Input port (connects to App, Abs, or another PrimVal) |
| `aux0` | PortId | (Unused; for slot alignment) |

**PrimFunEntry struct** (canonical def in effects-and-handlers.md D2; mirrored here):


---

## Elaboration

### Pass 0 — Primitive Name Resolution

Load global **stdlib** (deterministic, canonical order):

```
PrimTable:
  add → prim_id=0
  mul → prim_id=1
  eq  → prim_id=2
  ... (sorted or definition order)
```

When resolving free names:
- Check **def environment** first (user-defined)
- Check **PrimTable** second (builtins)
- Error if not found

No linearity constraint: primitives are not bound variables.

### Pass 2 — Net Emission

When Pass 0 resolved name to a PrimTable entry:


`prim_fns[k]` populated from stdlib during net initialization.

---

## Interaction Rules (prim_apply)

### Active Pair: PrimFun ⊗ PrimVal

**When**: `PrimFun.principal` connects to `PrimVal.principal` (or App result)

**Action**:

```
let new_captured = captured.clone()
new_captured.push(prim_val_arg)

match apply(&new_captured):
  Ok(result_value) =>
    if arity_remaining > 1:
      // Emit new curried PrimFun
      new_prim_fn = PrimFun {
        name, 
        arity_remaining: arity_remaining - 1,
        captured: new_captured,
        apply
      }
      emit PrimFun.principal → new_prim_fn.principal
      retire PrimVal
    else:
      // Emit PrimVal result (arity_remaining == 1)
      new_prim_val = PrimVal(result_value)
      emit PrimFun.principal → new_prim_val.principal
      retire PrimVal
  Err(e) => runtime error
```

### prim-result (SETTLED) — a prim_apply result is one of five outcomes

Canonical enum defined in effects-and-handlers.md §D2 (single source of truth); mirrored here:


**NetFragment** lets a prim emit native net structure, not just a flat value. Two uses:
- **Church booleans**: comparison/logic/type-pred prims (`eq`,`lt`,`elem`,`hasAttr`,`isInt`,…) build the
  Church-bool subnet `true=λt.λe.t` / `false=λt.λe.e` (two FanAbs + wiring) and return its root port —
  this is what makes native `if c t e ≡ c t e` work (nixprim.nix §Booleans; reducer.md §Forcing).
- **Data decoders**: `fromJSON`/`fromTOML` build List/AttrSet PrimVals with lazy `Term` children.

A NetFragment connects via `net.connect()` like any rule output → `detect_pair` routes new active pairs.
Helpers: `emit_true(net)→PortId`, `emit_false(net)→PortId`, `emit_church_bool(net, b)→PortId`.

### Signature: apply function


**Example**: `add`


Alternatively, `apply` is called with full `captured + new_arg`:


---

## Interaction with App

PrimFun can interact with App (not just PrimVal). When App's principal connects to PrimFun:

```
App:
  principal ← PrimFun.principal
  aux0 → result port
  aux1 → argument port

Result: PrimFun consumes App, applies one currying step
        PrimFun.aux0 connects to argument
        emit new PrimFun or PrimVal to App.aux0
```

This allows mixed lambda + primitive applications: `(f x)` where `f` is primitive.

---

## Dispatcher & Isolation

**Slot.kind field** (bitfield):

```
kind:u8 lower-nibble (bits[3..0]):
  0b0000 → Free    (bits[3..2]=00)
  0b0100 → FanApp  (bits[3..2]=01, bit[0]=0)
  0b0101 → FanAbs  (bits[3..2]=01, bit[0]=1)
  0b1000 → RepIn   (bits[3..2]=10, bit[0]=0)
  0b1001 → RepOut  (bits[3..2]=10, bit[0]=1)
  0b1100 → PrimVal (bits[3..2]=11, bit[0]=0)
  0b1101 → PrimFun (bits[3..2]=11, bit[0]=1)
```

**Dispatcher pseudo-code**:


**Guarantee**: prim_apply only fires on `(PrimFun ⊗ PrimVal)` or `(PrimFun ⊗ App)` pairs. No paper rules fire on primitive agents. No primitive rules fire on paper agents. **Separation is automatic and enforced by kind-based dispatcher.**

---

## Readback (psi_native)

Reconstruct δ-lang from `Net<Canonical>` containing both paper and primitive agents.

**Architecture**: psi_native = **extended psi_S** + lambda_to_dnx.

Two-step (per readback.md):

```
Net<Canonical>
  ↓ psi_S_extended (psi_S + primitive handling)
LambdaIR + Free("primitive_names")
  ↓ lambda_to_dnx (unchanged)
δ-lang Expr
```

psi_S already handles Free slots → Free("name") in LambdaIR. psi_S extended to also handle **PrimFun agents** (which aren't paper agents).

### psi_S Extension for Primitives

Add to psi_S match statement:


**Output**: `Free("mul")` for primitive names, `App(...)` for applications. LambdaIR doesn't need to know these are primitives.

### lambda_to_dnx Unchanged

lambda_to_dnx processes the LambdaIR output. `Free("mul")` is treated as a user-defined or primitive name:


No change needed. Free("mul") and Free("user_func") are indistinguishable at this point. readback.md applies.

### DFS Order Invariant

**Critical**: psi_S_extended's `captured[]` traversal must match **elaborator's left-to-right order**.

During **elaboration**: when `(mul x y)` is parsed:
- App node created
- func `mul` elaborated (emits PrimFun, arity=2, captured=[])
- arg `x` elaborated (emits value)
- prim_apply fires: new PrimFun(arity=1, captured=[port_x])
- arg `y` elaborated
- prim_apply fires: new PrimFun(arity=0) or PrimVal

So `captured` is populated **left-to-right** (x, then y).

During **readback**: walking `captured[]` in order emits args left-to-right, preserving `((mul x) y)` structure. ✓

**Key point**: psi_S_extended respects same DFS order as original psi_S (principal before aux1 for App). Primitive captured[] follows same order.

---

## Round-Trip Correctness

**Invariant**:

```
normalize(elaborate(psi_native(net))) = net  (structural equivalence)
```

**Structural equivalence**: same agent types, same connections, same primitive metadata (prim_id, arity_remaining). PortIds may differ (fresh allocation during elaborate), but connectivity is preserved.

Proof sketch:

1. **psi_S extension preserves information**: prim_id stored in slot.data. captured[] stored in PrimFun struct. Readback extracts name + captured[] expressions. Elaboration re-emits same prim_id and application structure.

2. **prim_id deterministic**: stdlib populated in canonical order (sorted or definition). `add` always gets prim_id=0, `mul` always prim_id=1, etc. Readback extracts `add` from prim_fns[0]; elaborate re-looks-up `add` in stdlib, gets same prim_id=0.

3. **captured[] structure preserved**: readback walks captured[] in DFS order (matches elaborator's left-to-right application order). Elaborate re-applies arguments in same order, reconstructing same application structure. Ports are fresh, but structure (which args feed to which PrimFun) is identical.

4. **Paper agents unaffected**: RepIn collapse + lambda reconstruction already proven sound (readback.md §4 Theorem; see readback.md Soundness). Primitives don't interact with R1-R7, so soundness transfers: `normalize(elaborate(psi_native(paper_part))) = paper_part`.

5. **Combined**: Paper + primitive parts both round-trip. Full net (paper + prim) round-trips structurally. Normalize is idempotent: `normalize(net_canonical) = net_canonical`. ✓

6. **C1 compatibility**: PrimFun/PrimVal are reachable agents. C1 mark-and-sweep treats them like any other agent. Disconnected primitives GC'd normally.

---

## Elaboration Interface

**PrimTable** (global stdlib):


**Construction** (deterministic):


**Lookup in Pass 0**:


---

## Examples

### Arithmetic

```delta
def add_two = add 2;
def result = add_two 3;
```

**Elaboration**:
- `add` resolves to `prim_id=0` (from stdlib)
- Emits `PrimFun(prim_id=0, arity_remaining=2, captured=[])` at `add`
- `2` emits `PrimVal(number 2)`
- Application: `add 2` → calls `prim_apply`
  - `apply(&[2])` → returns `PrimValue::Closure` (partial)
  - Emits `PrimFun(prim_id=0, arity_remaining=1, captured=[port_2])`
- `3` emits `PrimVal(number 3)`
- Application: `(add 2) 3` → calls `prim_apply`
  - `apply(&[2, 3])` → returns `PrimValue::Number(5)`
  - Emits `PrimVal(number 5)` to result

**Readback** (if normalized to `PrimVal(5)`):
- Emits `Lit("5")` or similar

### Comparison

```delta
def eq_x = eq x;
def check = eq_x 5;
```

**Elaboration**:
- `eq` resolves to `prim_id=2`
- `x` is a bound variable (from abs context or def param)
- `eq x` emits `PrimFun(prim_id=2, captured=[port_x])`
- `(eq x) 5` applies, result is boolean PrimVal

---

## Constraints & Properties

1. **Primitives are linear**: No RepIn can connect to a PrimFun. Each application creates a new PrimFun or terminal PrimVal. No replication of primitive functions themselves.

2. **Never touch R1-R7**: prim_apply is strictly separated. Kind-based dispatcher enforces this. Confluence and optimality of core rules are unaffected.

3. **Deterministic prim_id**: Round-trip soundness depends on canonical stdlib ordering. If `add` is always registered first, `prim_id=0` is stable.

4. **Lazy evaluation**: prim_apply only fires when PrimFun.principal connects to argument. No speculative evaluation. Arguments (PortIds) are only traversed if needed.

5. **Evaluated exactly once**: When prim_apply fires, captured[] are evaluated in order, then apply() is called. Result is deterministic; no backtracking or retry.

6. **Opaque computation**: `apply` function is opaque to the interaction net. Its implementation is external (Rust code). The net only sees inputs (captured + new arg) and output (PrimValue).

7. **No eta-expansion**: A PrimFun is kept as a reference. It's never desugared to lambda. This distinguishes compiled primitives from user-defined functions.

---

## Scope & Limitations

**In scope**:
- Deterministic primitive dispatch via kind-based dispatcher
- Curried 1-ary functions with partial application via arity_remaining
- Opaque computations (arithmetic, comparison, string ops, etc)
- Pure Nix evaluation (no side effects in apply)
- Deterministic round-trip with canonical stdlib

**Out of scope** (not formalized):
- Termination guarantees for recursive primitives (Nix's responsibility, handled by `apply` implementation)
- Stack depth limits (implementation-specific, not modeled in net)
- Exception handling for primitive errors (apply returns Result; error propagation TBD)
- Custom closures as primitive state (captured[] allows closures, but no formal spec)

---

## Settled — Do Not Revisit

- Primitives are Phase C extensions, orthogonal to main.tex
- prim_apply firing order: dispatcher prioritizes paper rules, prim-rules fire only on prim-touching pairs
- PrimFun arity_remaining dispatch: if `arity_remaining > 1` → new PrimFun; else → PrimVal
- Captured args stored as PortIds in PrimFun.captured: deterministic DFS order from elaboration
- psi_S_extended handles primitives; lambda_to_dnx unchanged
- prim_id deterministic: stable round-trip with canonical stdlib order
- PrimFun principal only: no auxiliary ports (unlike Fan/Rep)
- C1 mark-and-sweep applies: primitives are reachable agents, subject to GC if disconnected
- Lazy evaluation: prim_apply fires only when principal connects
- No eta-expansion: primitives kept as references, never desugared to lambda
- Primitives are linear: no RepIn sharing
- Never touch R1-R7: kind-based dispatcher enforces isolation
