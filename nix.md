# δ-lang: Pure Nix Runtime — SETTLED

## Status

Crate split: SETTLED. Stdlib coverage: SETTLED. Impure effect mapping: SETTLED.
Runtime pipeline: SETTLED. Missing builtins tracked below.

---

## Crate Architecture

```
dnx-lang/   (whole Nix frontend — single crate)
  parser/    rnix CST → LambdaAst<NixPrimVal, NixPrimFun>     (module)
  prim/      NixPrimVal, NixPrimFun, stdlib implementations   (module)
  effects/   impure builtin Tier1 HandlerEnv (Effectful labels) (module)
  runtime/   top-level eval API: &str → NixValue              (module)
```

### Dependency graph

```
dnx-core ←─ dnx-elab ←─ dnx-ast
   ↑            ↑
   └──── dnx-lang ────┘
```

`dnx-lang` is the whole Nix frontend (parser + prim + effects + runtime as
modules). It depends on `dnx-core` (runtime machinery), `dnx-elab` (elaboration),
and `dnx-ast` (AST). No other crate depends on `dnx-lang`.

---

## What Moves Where

### Currently misplaced code

| Location | Code | Moves to |
|---|---|---|
| `dnx-core` prim module | `PrimTable::stdlib()` + all prim_* impls | `dnx-lang` (prim module) |
| `dnx-lang` parser types | `NixPrimVal`, `NixPrimFun` | `dnx-lang` (prim module) |

### Stays in `dnx-core`

`PrimValue`, `PrimImpl`, `PrimFunEntry`, `PrimTable` (struct + register/lookup/make_fun_entry),
`fire_prim_fun`, `HandlerEnv`, `EffectHandler`, `HandlerResult`, `HandlerError`,
`EffectRow`, `EffRequest`, `PrimFireResult`.

These are language-agnostic runtime machinery. Zero Nix semantics.

### Stays in `dnx-elab`

`LambdaAst`, `phi_k`, `desugar_let`, `lam_app1/2/3`, `free_vars`, `subst`.
All Nix-agnostic (generic over PrimVal/PrimFun).

---

## `dnx-lang` — prim module

### NixPrimVal (moves from parser types)


### NixPrimFun (moves from parser types, EXTENDED)


> Note: surface builtin names (`add`, `map`, `select`, `head`, …) map to these
> CamelCase enum variants (`Add`, `Map`, `Select`, `Head`, …); the variant style is
> idiomatic Rust and is intentionally left as-is. (`if`/`assert`/`&&`/`||`/`!`/`->` are
> NOT variants — they desugar to the native Church-bool `if`; see §Booleans.)

### NixPrimTable


`NixPrimFun::to_prim_fun_entry()` looks up `nix_prim_table()` by name.

---

## `dnx-lang` — parser module (modifications)

The parser module keeps: `parse_nix`, `nix_to_lambda`, `NixError`, `str_ast`, `path_ast`,
desugar modules (inherit, pattern, rec_attrset, with).

The parser module drops: `NixPrimVal`, `NixPrimFun` (moved to the prim module).

The parser module uses the prim module for types (same crate).

`resolve_builtin` stays in the parser module — it gates impure builtins:

---

## `dnx-lang` — effects module

Tier 1 ForeignCall effects for impure Nix builtins. Implements `EffectHandler` per label.


### Impure builtin → effect label mapping

| Nix builtin | Effect label | Handler |
|---|---|---|
| `builtins.readFile` | `"fs.file"` | `ReadFileHandler` (reads from FS) |
| `builtins.readDir` | `"fs.file"` | `ReadDirHandler` |
| `builtins.pathExists` | `"fs.file"` | `PathExistsHandler` |
| `builtins.currentTime` | `"time"` | `CurrentTimeHandler` |
| `builtins.currentSystem` | `"env"` | `CurrentSystemHandler` |
| `builtins.getEnv` | `"env"` | `GetEnvHandler` |
| `builtins.fetchurl` | `"io"` | `FetchUrlHandler` |
| `builtins.fetchTarball` | `"io"` | `FetchTarballHandler` |
| `builtins.fetchGit` | `"io"` | `FetchGitHandler` |
| `builtins.storePath` | `"nix.store"` | `StorepathHandler` |
| `builtins.toFile` | `"nix.store"` | `ToFileHandler` |
| `builtins.filterSource` | `"nix.store"` | `FilterSourceHandler` |

Parser translates `builtins.readFile path` →
`Fun(NixPrimFun::Builtin("readFile"))` with `PrimImpl::Effectful("fs.file")`.

At PrimFun saturation: reducer emits `EffRequest { label: "fs.file", args, continuation, lo }`.
`normalize_with_handlers` trampoline dispatches to `ReadFileHandler`. ✓

---

## `dnx-lang` — runtime module

Top-level API. No Nix semantics here — only pipeline wiring.


---

## Pure Stdlib Coverage

### Currently implemented (in dnx-core prim.rs, moving to dnx-lang prim module)

`add sub mul div neg eq ne lt le gt ge select select_or has_attr insert update list_cons list_concat
 str_concat path_concat to_str pred succ`

**NOT prims** (Church-bool native if-desugar — see §Booleans): `if assert and or not impl`

### Missing — must add to dnx-lang prim module for ASAP target

| Priority | Builtin | Notes |
|---|---|---|
| P0 | `length` | List/AttrSet length — used everywhere |
| P0 | `head` | First list element |
| P0 | `tail` | Rest of list |
| P0 | `elem` | `builtins.elem x list` |
| P0 | `map` | `map f list` — higher-order, needs PrimFun partial apply |
| P0 | `filter` | `filter pred list` |
| P0 | `foldl'` | `foldl' f init list` |
| P0 | `attr_names` | `builtins.attrNames` |
| P0 | `attr_values` | `builtins.attrValues` |
| P0 | `type_of` | `builtins.typeOf` |
| P1 | `elem_at` | `builtins.elemAt list n` |
| P1 | `gen_list` | `builtins.genList f n` |
| P1 | `map_attrs` | `builtins.mapAttrs f attrset` |
| P1 | `filter_attrs` | `builtins.filterAttrs` |
| P1 | `list_to_attrs` | `builtins.listToAttrs [{name,value}]` |
| P1 | `to_int` | `builtins.toInt "42"` |
| P1 | `to_float` | coercion |
| P1 | `try_eval` | `builtins.tryEval expr` → `{success, value}` |
| P1 | `throw` | `throw "msg"` → DnxError::Throw |
| P1 | `abort` | `abort "msg"` → DnxError::Abort |
| P1 | `substring` | `builtins.substring start len s` |
| P1 | `string_length` | `builtins.stringLength s` |
| P2 | `to_json` | `builtins.toJSON v` |
| P2 | `from_json` | `builtins.fromJSON s` |
| P2 | `is_int` etc | type-predicate family |
| P2 | `concat_map` | `builtins.concatMap f list` |
| P2 | `sort` | `builtins.sort cmp list` |
| P2 | `unique_by` | `builtins.uniqueBy f list` |
| P2 | `group_by` | `builtins.groupBy f list` |
| P2 | `intersect_attrs` | `builtins.intersectAttrs` |
| P2 | `remove_attrs` | `builtins.removeAttrs` |

**map/filter/genList/foldl' design (LAZY SPINE + lazy elements, net construction — no eager Rust iteration)**:
- `map f xs`: lazy-spine — `map f (Cons x xs) = Cons(App(f,x), map f xs)`, `map f Nil = Nil`. Head elem is an
  UNFORCED `App` subnet, tail unforced. `f` may be FanAbs OR PrimFun — simply applied in the net. NO lambda-as-arg limitation.
- `filter pred xs`: lazy-spine — `filter p (Cons x xs)` forces `p x` to a Church-bool: kept → `Cons(x, filter p xs)`,
  dropped → `filter p xs`. `head (filter …)` forces preds only until the FIRST kept element (not all). Infinite-list safe.
- `genList g n`: `List([App(g,0), …, App(g,n-1)])` — lazy elements.
- `foldl' f z xs`: STRICT left fold (the tick) — forces the accumulator to WHNF each step (Nix `foldl'`).

NO `force_apply` dispatch and NO Rust eager iteration: the function arg is applied by building `App`
nodes; the reducer forces each element Term only when demanded.

---

## Error Types


---

## Lazy Evaluation

Nix is lazy (call-by-need). dnx IS a lazy evaluator — **demand-driven**, never eager:
- **force_whnf(port)** (reducer.md §Forcing): reduce ONLY the port's LO demand spine to WHNF.
  The runtime drives eval with this, NOT `Ω_S` full-normalize. Off-spine subnets stay unreduced.
- **LO order** = normal order = call-by-need; **optimality** = nothing unnecessary reduced;
  **perfect confluence** = the forced value is order-independent. (paper §2/§4.)
- **Sharing** (call-by-NEED): `let x = e; …x…x…` → `rep` shares `e`; x forces once.
- **Erasure**: dead branches (untaken `if`, unused binding) → eraser; never on a spine; never forced.
- List/AttrSet elements are lazy `Term`s; forced individually by head/getAttr/elemAt.

Lists = LAZY SPINE + lazy elements (cons-cell = head Term + tail Term, both unforced). `++`/concat/map/filter
are lazy-spine; `head` forces 1 cons, `length` forces the whole spine. **dnx-Nix is MORE lazy than stock Nix:
infinite lists are PRODUCTIVE — no stack overflow.**
Sanity (MUST hold): `head [ 1 (1/0) ]` → `1` (elem1 never demanded → no error);
`length [ (1/0) ]` → `1` (no element forced); `(x: 1) (throw "e")` → `1` (arg erased);
`let xs = [1] ++ xs; in head xs` → `1` (LAZY SPINE — only first cons forced; infinite list productive, NO overflow);
`let x = 1/0; in 2` → `2` (unused binding never forced).
NOTE `head [ (1/0) ]` DOES error — `head`'s result *is* the `1/0` thunk, observing the eval output
force_whnf's it (matches `nix-instantiate --eval`). Spine, element, binding, branch laziness ALL via dnx call-by-need.

`builtins.tryEval e` = `force_whnf(e)` under a catch (PURE, no effect): success → `{success=true; value=e}`;
`Throw`/`AssertFailed` → `{success=false; value=false}`. Does NOT catch `Abort`/`TypeError`.

## Booleans (Church-encoded, native `if`)

Nix `bool` is NOT a `PrimVal`. Booleans are Church-encoded native nets (VIC Q1):
```
true  = λt. λe. t        (FanAbs; inner λe discards e → e-port → eraser)
false = λt. λe. e        (FanAbs; outer λt discards t → t-port → eraser)
if c t e  ≡  (c t e)     = App(App(c, t), e) — pure native application; NO prim, NO new rule
```
- **Branch laziness = optimality**: in `(true t e)`, `true=λt.λe.t` ignores `e` → `e` lands on an eraser,
  never on a forced spine → never reduced. Symmetric for `false`. Exactly one branch is forced.
- **Desugar** (nixparse): `a&&b ≡ if a b false`, `a||b ≡ if a true b`, `!a ≡ if a false true`,
  `a->b ≡ if a b true`. Short-circuit for free. `assert c; body ≡ if c body (throw "assertion failed")`.
- **Producers**: comparison/logic/type-pred prims EMIT a Church-bool net (primitives.md §prim-result;
  `emit_church_bool`), not a `PrimVal`.
- **Recognizer** `is_church_bool(net, p) -> Option<bool>`: force_whnf ⇒ FanAbs(λt); body force ⇒ FanAbs(λe);
  body force ⇒ var `t` (Some true) | var `e` (Some false). Used by typeOf/isBool/toString/toJSON + output.
- **KNOWN divergence (accepted, Q1)**: untyped `true ≡ K`, `false ≡ K I`. A user λ α-equal to these is
  indistinguishable from a bool; `typeOf`/`isBool` answer by the structural recognizer. Pure-eval Nix
  programs do not depend on this distinction. Documented so implementers trust the boundary.

---

## Recursion (lazy, productive)

`rec { … }` and recursive `let` → SCC analysis (nixparse): each recursive strongly-connected group
desugars to `fix`; a mutual-recursion SCC → a single `fix` over a tuple/record of the group.
`fix` → Y-net (syntax.md/elaborator.md): `fix e ≡ (abs f. rep (abs x. rep x as(x0,x1) in f (x0 x1)) as(m,m') in m m') e`.

- **Productive via laziness**: recursion unfolds only as far as `force_whnf` demands.
  `let ones = [1] ++ ones; in elemAt ones 3` forces 4 cons cells, no more.
- **Self-reference shared, forced-once**: the Y-net `rep` shares each recursive value (call-by-need).
- Non-terminating recursion diverges ONLY if its result is actually demanded (matches Nix).
- `builtins.fix = f: let x = f x; in x` → same `fix`/Y-net. ✓

---

## Implementation Order (ASAP sprint)

```
Phase 1 — module split (no new features, just reorganize):
  1. Create dnx-lang prim module
  2. Move NixPrimVal, NixPrimFun from parser types → prim module
  3. Move prim_* impls + stdlib() from dnx-core prim → prim module as nix_prim_table()
  4. Wire parser module to use prim module

Phase 2 — P0 builtins (length/head/tail/map/filter/foldl'/attr_names/attr_values/type_of):
  5. Implement in dnx-lang prim module
  6. Add to nix_prim_table()
  7. Expand NixPrimFun with new variants
  8. Tests for each

Phase 3 — runtime module:
  9. Create dnx-lang runtime module with NixRuntime + NixEvalResult
  10. Wire pipeline: parse → elaborate → normalize → readback
  11. Integration tests: eval "1 + 1" == 2, etc.

Phase 4 — impure effects (dnx-lang effects module):
  12. Create dnx-lang effects module with NixHandlerEnv
  13. readFile, pathExists, currentTime, currentSystem, getEnv
  14. Wire in parser module: impure builtins → PrimImpl::Effectful
  15. Integration tests with mock handlers

Phase 5 — P1 builtins and polish.
```

---

## Settled — Do Not Revisit

- Crate layout: single `dnx-lang` crate; parser/prim/effects/runtime as modules, strict separation
- NixPrimVal/NixPrimFun/nix_prim_table → dnx-lang prim module (NOT in dnx-core)
- PrimTable infrastructure stays in dnx-core (language-agnostic)
- Impure builtins → Tier 1 Effectful + HandlerEnv (NOT Tier 2 free monad)
- dnx-lang runtime module = pipeline wiring only, zero Nix semantics
- LAZY eval = DEMAND-DRIVEN `force_whnf` (NOT eager Ω_S/normalize); thunk = unreduced subnet; `force_deep` ONLY for output/hash/deepSeq
- value repr (D4 lazy): `Cons(Term,Term)|Nil` LAZY-SPINE lists (infinite lists PRODUCTIVE, NO overflow — better than stock Nix), `AttrSet(Vec<(name,Term)>)` strict keyset + lazy values; Path IN SCOPE (D3)
- bool = Church-encoded native net (NO `PrimVal::Bool`); `if`/`&&`/`||`/`!`/`assert` = native if-desugar (no prim); comparison/type-pred prims emit Church-bool nets
- **lists = SCOTT-encoded lambdas** (D5, Vic 2026-06-02): `nil=c:n:n`, `cons h t=c:n:c h t` — pure lambdas like Church-bool, NO net agent, NO R-rule, NO NetEmit. `Cons(Term,Term)` = Scott CONSTRUCTOR semantics (not a net agent). head/tail/isNil/map/filter/foldl'/genList/concatMap/length/elem/elemAt/concat = **Nix PRELUDE** (`prelude.rs`) supplied to pass0 def-map, inlined where used. recursion via `fix`. laziness via call-by-need. typeOf/isList over lists need a net list-recognizer (PrimValue::Lambda opaque) — followup.
- map/filter = prelude (Scott), NOT eager Rust iteration, NOT net-emit prim
- rec/letrec = SCC → `fix`/Y-net; productive via demand (forces only what's observed). ⚠️ fix/Y-net REDUCTION currently DIVERGES (rep levels App-arg-depth vs paper φ_K abstraction-depth → no C2-merge). BLOCKED — Vic decision: fix φ_K levels (A) vs REF-nodes (B).
- attrsets (D5b): eager `PrimValue::AttrSet(Vec<(name,PrimValue)>)` — select/insert/hasAttr/update/mkSingleton/selectOr prims. scalar values work; function/list values opaque (Lambda sentinel) + eager (no lazy values yet). dynamic-string-keyed map = justified PrimVal (not pure-dnx-expressible). attrNames/attrValues need Scott-list bridge (followup).
- Error propagation: NixEvalError wraps all sub-errors; no panics
- PrimTable::stdlib() in dnx-core: REMOVE after migration; nix_prim_table() replaces it

---

## Nix ecosystem integration design

### Eval↔store seam convergence

The boundary between pure evaluation and effectful store/build operations converges independently with established prior art: an evaluator that stays store-agnostic by routing every filesystem/store/build operation through a single trait/effect-boundary, with two implementations — a pure/dummy mode (returns unsupported for all impure ops) and a store-backed mode (full implementation). dnx's settled `HandlerEnv` purity boundary (Tier-1 ForeignCall effects) IS this pattern, expressed as effect-requests through a trampoline rather than a trait object. The designs arrive at the same abstraction independently; this confirms the boundary is correct.

**Mapping**: pure eval with empty `HandlerEnv` = pure/dummy mode. `HandlerEnv` populated with store/build/fs handlers = store-backed mode. Six key effect labels (`fs.file`, `nix.store`, `nix.build`, `io`, `nix.fetch`, `nix.env`) cover the full impure surface.

**Implication**: parallel builds live in the build-handler (batched `nix.build` effect requests), NOT in the eval seam itself. The eval seam is single-resume by design; parallelism at build level is a handler-internal concern.

### What must NOT be re-derived

The Nix protocol surface (store-path hashing, NAR archive format, `.drv` ATerm serialization, daemon wire protocol) is already solved. dnx's store hash (BLAKE3 of canonical net) differs from the Nix SHA256 store hash — these are two separate identities serving different purposes:
- dnx `ArtifactId` / `net_hash`: semantic identity (same meaning = same hash, cross-language).
- Nix store path: recipe identity (same derivation = same path, build-system compatible).

Bridge at protocol level: a dnx-built artifact can be registered into a Nix store by producing the correct SHA256-based store path as metadata. The two hashes coexist; neither replaces the other.

### String-context (open design question)

Nix strings carry a `StringContext` (set of references to store paths, derivation outputs, or derivation files). This context is used to populate `inputDrvs` and `inputSrcs` in `derivationStrict`. The interaction-net kernel has no string-context field. Candidate designs:
- Context as a parallel effect row (derived metadata, not in net hash, analogous to `EffectRow`).
- Context materialized only at `derivationStrict` boundary (pure string operations ignore context; context only matters at the drv-construction boundary).
- Context as a `PrimValue` variant (`Str` carries a context set alongside the raw bytes).

This is an open design question gating full `derivationStrict` support.

### Two walls blocking full Nix evaluation

1. **Recursion**: genuine fix/Y-net does not yet normalize for self-duplicating recursion (countdown, length of a list, map/filter/foldl). Blocks `mkDerivation`, all HOF-based builtins, `import <nixpkgs>`. Root cause is in the rep-level assignment for the fix feedback arc.
2. **Parse walls**: `rec {}`, `with`, `inherit`, string interpolation (`"${}"`) are syntactically unsupported. Hit before recursion on any real nixpkgs expression.

Non-recursive pure Nix (literals, arithmetic, comparisons, `if/then/else`, non-recursive `let`, lambdas, eager attrsets, lists, `import ./path`) works today.
