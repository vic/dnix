# δ-lang: Driver — End-to-End Pipeline — SETTLED

## Overview

`dnx` is a **language-agnostic** runtime. The driver pipeline is generic:
frontends plug in `PrimVal`, `PrimFun`, and `PrimTable`; the core is unchanged.

```
[Frontend]  Source text
               ↓ frontend parser (e.g. rnix, or δ-lang tokenizer)
            Ast<V, F>             ← dnx-ast; V: PrimVal, F: PrimFun
               ↓ elaborate()      ← dnx-elab
            Net<Proper, C>        ← dnx-core (C = L/A/I/K from Pass 1)
               ↓ force_whnf(port) ← dnx-sched (Sequential | Parallel | Gpu)   ← LAZY: demand spine → WHNF
            Net<Proper, C>        ← WHNF at demanded port; off-spine subnets unreduced
               ↓ readback surface ← dnx-read   (psi on the forced head; children forced on demand)
            ReadbackResult<V, F>  ← Lambda(Ast<V,F>) | Value(V) | Partial(Name)
               ↓ display          ← [Frontend] (language-specific; forces deeper on demand)
[Frontend]  Output (text, value, error)
```

**Hash/artifact branch only** (NOT eval): `normalize()` = `force_deep(root)` → `Net<Canonical, C>`
→ `psi_native()` (whole-term readback) / `canonical_hash()`. The lazy `force_whnf` path above is the
runtime; eager `normalize` is reserved for content-addressing (canonical-hash.md).

---

## Stage 1: Frontend Parse → Ast<V, F>

Responsibility: frontend crate (e.g. `dnx-lang`).

- Produce `Ast<V, F>` where `V: PrimVal`, `F: PrimFun`
- Frontend handles ALL language-specific desugaring (let, with, patterns, etc.)
- Result: structurally linear AST — no syntactic sugar remains
- Errors: frontend-specific (e.g. `NixError`, parse errors from rnix)
- Scope: frontend tracks bound names; free names → either PrimTable entries or `Ast::Name` (free var)

---

## Stage 2: Elaborate → Net<Proper, C>

`dnx_elab::elaborate<C, V, F>(ast, prim_table) → Result<Net<Proper, C>, DnxError>`

Three passes (elaborator.md):

| Pass | Input | Output |
|---|---|---|
| 0 | `Ast<V,F>` | resolved AST: no def-refs, `fix` desugared, prim names → PrimFun entries |
| 1 | resolved AST | `usage_levels: HashMap<Name,u32>`, NetClass bits (`has_era`, `has_rep`) |
| 2 | resolved AST + usage_levels | `Net<Proper, C>`: allocated slots + wired ports |

**NetClass `C`** is determined by Pass 1 bits and is a static typestate:
- `L` (ΔL): no era, no rep → minimal rules
- `A` (ΔA): era only → affine
- `I` (ΔI): rep only → relevant
- `K` (ΔK): era + rep → full

**Errors** from elaboration:
- `LinError::Unused(name)` — bound var used 0×
- `LinError::MultiUse(name, n)` — bound var used n> times
- `LinError::MutualRecursion(names)` — cycle without `fix`
- `LinError::TooManyFreeVars` — >16383 distinct free names
- `LOPathDepthExceeded` — nesting depth >512 (all 4 LOPath limbs full)

---

## Stage 3: Reduce (lazy `force_whnf` for eval · eager `normalize` for hash)


Scheduler selection is identical for both modes (runtime, not typestate):


**Two reduction modes — both LO-ordered (main.tex §4), both optimal (Lévy):**

- **`force_whnf(net, port)` — LAZY eval (reducer.md §Forcing). This is the runtime path.**
  Reduces ONLY the port's demand spine to WHNF (a value head). Off-spine subnets are left
  unreduced, so an infinite or erroring sub-value is never touched unless demanded — true
  call-by-need. Result is a WHNF `Net<Proper>` (not canonical). `force_deep` = recursively WHNF
  the observed children (output / `deepSeq` / `--strict`). Frontends (nix.md `eval`) drive
  evaluation by `force_whnf` on each demanded port — NEVER by eager `normalize()`.

- **`normalize() = Ω_S full-normalize = force_deep(root)` — HASH/ARTIFACT path only.**
  Total on normalizing `Net<Proper>`: produces the UNIQUE `Net<Canonical>` regardless of scheduler
  (scheduler-independent). Used ONLY when full NF is required: **canonical hashing / artifact export**
  (canonical-hash.md). NOT the eval path. A non-normalizing term diverges here even when its
  `force_whnf` would terminate at WHNF (e.g. `head [1, 1/0, fix id]` → `1` lazily, ⊥ under normalize).

**Laziness lives in `force_whnf`, NOT in `normalize()`** — `normalize()` is eager (forces everything).
LO = leftmost-outermost = normal order ⇒ `force_whnf` realizes call-by-need; no argument is reduced
unless the outermost demand reaches it.

**No call stack** (both modes): entire reduction state lives in the frontier
(`BTreeMap<LOPath, ActivePair>`). Recursion via `fix`/Y-net = frontier entries cycling, NOT stack
frames. Stack depth = O(1); stack overflow is architecturally impossible.

---

## Stage 4: Readback → ReadbackResult<V, F>

Two entries — the eval path reads a WHNF surface; the artifact path reads a full normal form:



`psi_whnf` classifies by the forced head exactly as `psi_native` classifies by root slot; for `Value`
in eval mode the returned `V` may carry unforced child `Term`s (forced lazily by the frontend printer).
`psi_native`'s `Net<Canonical>` contract is unchanged (full-NF readback for artifact/whole-term).

**Note (reconcile with readback.md)**: `readback.md`'s `psi_native: Net<Canonical> → Expr`
returns the bare `Expr`; the driver is the layer that wraps that `Expr` into
`ReadbackResult::{Value, Lambda, Partial}` (Value/Lambda/Partial classification by root slot).

**`Value(V)`**: root slot is `AgentKind::PrimVal`.
Extract: `net.prim_vals[root.prim_id].clone()`. No traversal.

**`Lambda(Ast<V,F>)`**: root slot is `FanAbs` (or chains thereof).
Path: `psi_S → LambdaIR → lambda_to_dnx → Ast<V,F>` (readback.md).
C4 invariant guarantees all RepIn.principal → Abs.aux1 → psi_S total.

**`Partial(name)`**: root slot is `Free` (open term; free variable in result).
Frontend decides how to handle (error, display as-is, etc.).

---

## Divergence Policy

A term with no normal form loops forever in the frontier — but only `normalize()` must reach NF, so
`force_whnf` can terminate where `normalize` diverges (it stops at the first value head; off-spine loops
are never entered). A term with no WHNF (`fix id`, `let x = x`) loops under `force_whnf` too. Fuel guards
both modes. Detection:

**Option A: Fuel limit** (default for frontends)
`normalize_with_config(net, cfg) → Result<Net<Canonical>, StepLimitExceeded>` and
`force_whnf_with_config(net, port, cfg) → Result<ValueHead, StepLimitExceeded>` both honor the fuel.
Frontend exposes this as `--max-steps N` CLI flag.

**Option B: Unbounded** (library default)
`normalize()` (no config) = unbounded. Caller's responsibility.

**No GC loop risk**: only ΔI/ΔK nets can diverge (have `rep`). ΔL/ΔA always normalize.
Divergence = net_flags bit1 (`has_rep`) = true AND term is non-normalizing.

---

## Error Model

All errors are `DnxError` (unified enum across crates):


Frontend-specific errors (e.g. `NixError`, parse errors) are NOT in `DnxError`.
Frontends wrap: `DnxError → FrontendError::DnxError(e)`.

**Source spans**: elaborator does NOT track source spans. Frontends maintain
`name → Span` maps from their parse phase; they annotate `DnxError` with
span info at the frontend boundary.

---

## Frontend Contract

To implement a new language frontend:

1. Define `MyPrimVal: PrimVal` and `MyPrimFun: PrimFun`
2. Implement `MyPrimVal::alloc_in(net)` and `MyPrimFun::alloc_in(net)` (net emission)
3. Implement `MyPrimTable: PrimTable` (name → PrimFun registry)
4. Write parser: source → `Ast<MyPrimVal, MyPrimFun>` (desugar fully)
5. Call `dnx_elab::elaborate(ast, &my_prim_table)` → `Net<Proper, C>`
6. Drive eval lazily: `scheduler.force_whnf(net, root)` (then `psi_whnf` + force children on demand)
7. Display the WHNF surface in language-specific format (printer forces deeper as it prints)
8. (artifact/hash only) `scheduler.normalize(net)` → `Net<Canonical, C>` → `psi_native` / `canonical_hash`

No other integration points. `dnx-*` crates are otherwise opaque.

---

## dnx: Nix Frontend Binary

`dnx` implements the above contract for Pure Nix:

```
$ dnx eval '1 + 1'
2
$ dnx eval --file foo.nix
{ a = 1; b = "hello"; }
$ dnx eval --max-steps 1000000 '(let f = x: f x; in f 0)'
error: step limit exceeded after 1000000 reductions
```

**Pure Nix scope** (what `dnx` supports):
- All λ-calculus constructs (abs, app, let, rec, with, assert)
- Literals: int, float, bool, string (with interpolation), null, path, list, attrset
- Builtins: `builtins.add`, `builtins.mul`, `builtins.map`, `builtins.filter`, etc.
- `import` of **pure** `.nix` files (no store paths, no `<nixpkgs>`)

**Out of scope** for `dnx`:
- Derivations (`mkDerivation`, `builtins.derivation`)
- Nix store (`/nix/store/...` paths)
- `builtins.fetchurl`, `builtins.fetchTarball` (effectful)
- `builtins.currentSystem`, `builtins.currentTime` (impure)
