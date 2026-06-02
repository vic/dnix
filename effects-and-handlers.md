# δ-lang: Effects and Handlers — SETTLED

## Status

All decisions D1-D10 settled. Architecture confirmed against Unison, Koka, Nix, nix-effects.
Multi-branch handler = concrete label-dispatch (native if + eq); see D10. canonical-hash.md now SETTLED
(consumes D6 ArtifactId). distribution.md remains a design sketch.

---

## Two-Tier Effect Architecture

dnx has TWO distinct effect mechanisms. They coexist and serve different use cases.

### Tier 1 — ForeignCall-style (driver-level)

`PrimFun` with `PrimImpl::Effectful(label)`. Handler lives OUTSIDE the net in
`HandlerEnv`. No continuation capture. No new net agents.

Used for: OS I/O, Nix store lookups, environment reads, time — effects where the
computation always resumes exactly once with a single value.

Analogy: Unison's `ForeignCall` instruction — direct dispatch, never touches
continuation stack.

### Tier 2 — Algebraic (net-level)

`Perform<l>` and `Handle<l>` agents in the net. Handler installed IN the net.
Continuation captured implicitly (the net graph IS the continuation). Fired by
the interaction rule `Perform<l> ↔ Handle<l>` during normalization.

Used for: non-determinism, generators, exceptions with restarts, any effect where
the handler may resume the continuation 0 or N times.

Analogy: Unison's `Reset`/`Capture` mechanism — but without explicit stack
manipulation because the interaction net graph naturally represents the continuation.

---

## Tier 1: ForeignCall Effects

### D1 — EffectLabel = string, PrimImpl enum

Effect labels are **open strings**, not a closed enum. Enables frontend-defined
effects without `Custom(u16)` registration hack.


Effect label in `PrimTable`:

### D2 — PrimFireResult + EffRequest

When a Tier-1 effectful prim fires:


**Two-step**: `fire_prim_fun` returns `EffectSaturated(label, args)`. The normalizer
(`prim_apply_rule`/`prim_app_rule`) captures `continuation + lo` from the active pair
and pushes the full `EffRequest` into `net.pending_effects`.

**Trampoline loop**:

### D3 — HandlerEnv


Stateful handlers: use `Mutex<State>` inside the closure. E.g. streaming accumulator:
`Mutex<Vec<PrimValue>>` collects emitted values across multiple `EffRequest` calls.

### D4 — Nix primitive effect mapping

All current `PrimTable::stdlib()` entries = `Pure`. Impure builtins map as:

| Nix builtin              | EffectLabel   |
|--------------------------|---------------|
| `builtins.storePath`     | `nix.store`   |
| `builtins.filterSource`  | `nix.store`   |
| `builtins.toFile`        | `nix.store`   |
| `builtins.readFile`      | `fs.file`     |
| `builtins.pathExists`    | `fs.file`     |
| `builtins.readDir`       | `fs.file`     |
| `builtins.fetchUrl`      | `io`          |
| `builtins.fetchGit`      | `io`          |
| `builtins.exec`          | `io`          |
| `builtins.currentTime`   | `time`        |
| `builtins.currentSystem` | `env`         |
| `builtins.nixPath`       | `env`         |
| `builtins.getEnv`        | `env`         |

`builtins.derivation` = PURE (output path deterministic from inputs).
`builtins.path` with `sha256` = PURE (content-addressed).

### D5 — EffectRow = sorted set, order-independent hash


EffectRow is ORDER-INDEPENDENT for hashing (like Unison `hashCycle`). Encoding:
`sorted(label_hashes)` → deterministic canonical bytes.

### D6 — ArtifactId


The identity (canonical `serialize` bytes) already encodes effect info implicitly (prim_ids in
PrimFun slots index into PrimTable which includes EffectLabel). The `effect_row` is DERIVED
METADATA for fast distribution validation — never mixed into the identity bytes
(canonical-hash.md:130-133). Two derived representations of the identity: WIRE = `BLAKE3(serialize)`
(distribution, above), LOCAL = `intern(serialize) -> u64` (conv/TCB, structural-exact; was `CanonId`).

Pure artifact: `ArtifactId { wire, effect_row: EffectRow::pure() }`.

### D7 — EffectRow inferred bottom-up from AST

```
Ast::Val(v)          → EffectRow::pure()
Ast::Fun(f)          → EffectRow::from(f.to_prim_fun_entry()?.impl_.effect_label())
Ast::App(f, x)       → union(infer(f), infer(x))
Ast::Abs(_, body)    → infer(body)
Ast::Name(_)         → EffectRow::pure()
Ast::Era(e1, e2)     → union(infer(e1), infer(e2))
Ast::Rep(e1,..,e2)   → union(infer(e1), infer(e2))
Ast::Fix(body)       → infer(body)
Ast::Perform(l, e)   → union({l}, infer(e))          ← Tier 2
Ast::Handle(comp, _) → infer(comp) \ {handled labels} ← Tier 2
```

Conservative union is SOUND for ForeignCall effects (never misses a required effect).
HOFs: `App(map, readFile)` → `union(Pure, {fs.file})` = `{fs.file}` propagates naturally.
Lazy effects: dead branches erased by E-rule at runtime → never generate EffRequests.
With Pass 0.5 type inference (see elaborator.md), D7 is subsumed by proper type
inference with effect row unification.

### D8 — validate_handlers (startup check)


Startup check (before normalization). Stronger than Unison's runtime discovery
(`unhandledAbilityRequest`). D8 is a STATIC check relative to the computed EffectRow.

### D9 — EffectLabel identity for distribution

Builtin labels (`"io"`, `"nix.store"`, etc.) = stable `Builtin` identifiers, hardcoded
in the protocol with fixed hash values.

Custom effects:
- MVP: registration-based per-session (string = identity)
- Future: `Structural` = same string hash cross-codebase; `Unique` = GUID-distinguished
  (same as Unison's `structural`/`unique` ability modifier)

---

## Tier 2: Algebraic Effects — Free Monad Church Encoding

### D10 — Free monad elaboration of Perform/Handle

Tier 2 algebraic effects elaborate to **pure λ-terms** (Var/Abs/App/Rep/Era) via
Church-encoded free monad. No new net agent types. No new interaction rules.
All paper guarantees (confluence, optimality, Church-Rosser) apply directly.

**Grounding**: free monad IS the denotational model of algebraic effects
(Plotkin/Pretnar free algebra). The `handle` fold is its universal property.
φ_K translates these λ-terms to canonical Δ-nets; R1-R7 reduce them.

#### perform

```
-- Source: perform "l" arg
-- Elaborates to: λpure. λh.  h "l" arg (λresult. pure result)
--   h (the handler) receives: LABEL (Str), the effect arg, and the continuation k=λresult.pure result.
--   Passing the label lets one handler dispatch over many effect labels (see Multi-branch).

elaborate(Ast::Perform("l", arg)) =
  Abs(pure,
    Abs(h,
      App(App(App(Var(h), Str("l")), elaborate(arg)),
          Abs(result, App(Var(pure), result)))))
```

Variable usage (linearity):
- `"l"`, `arg`, `pure`, `h`, `result` each used exactly once → **λL-term**
- φ_L applies: fans only, no replicators, no erasers
- One-shot effects: zero Rep overhead

#### handle

```
-- Source: handle comp with { "l" x k → body }
-- Elaborates to:
--   comp (λr. r) (λlbl. λx. λk. era lbl in body)
--   pure = identity; the handler takes the LABEL too (ignored for one branch; dispatched for many).

elaborate(Ast::Handle(comp, [("l", x, k, body)])) =
  App(App(elaborate(comp),
          Abs(r, Var(r))),                                   -- pure return: identity
      Abs(lbl, Abs(x, Abs(k, Era(Var(lbl), elaborate(body))))))  -- λlbl.λx.λk. era lbl in body
```

Semantics: computation `comp` receives two arguments:
- The pure-return path (identity: `λr.r`)
- The effect handler (`λlbl.λx.λk. era lbl in body`)

When `perform "l" arg` fires inside `comp`:
```
  (λpure.λh. h "l" arg (λr.pure r))
    (λr.r)                          -- pure = identity
    (λlbl.λx.λk. era lbl in body)   -- handler
=  (λlbl.λx.λk. era lbl in body) "l" arg (λr.(λr.r) r)
=  body[x:=arg, k:=λr.r]            -- lbl="l" erased; k = identity continuation
```
β-reduction only. No new rules.

#### Multi-branch handlers

A handler with N branches is ONE dispatcher that selects by label (native `if` + `eq` on the Str label):

```
handle comp with { "l1" x k → b1 ; … ; "ln" x k → bn }  ≡
  comp (λr. r)                                  -- pure = identity
       (λlbl. λx. λk.                           -- dispatcher
          if lbl == "l1" then b1
          else if …
          else if lbl == "ln" then bn
          else perform lbl x k)                 -- unmatched → FORWARD (re-perform) to the outer handler
```
- `lbl == "li"` = `nix_eq` on Str → Church-bool; native `if` selects (nix.md §Booleans). One branch survives.
- `lbl`,`x`,`k` appear in several branches → elaborator inserts `rep`; the untaken branches `era` their
  copies (native `if` erases the unchosen branch). Linearity preserved.
- **Forwarding**: an unmatched label re-performs → caught by an enclosing `handle` (handler composition).
  An effect that reaches the top unhandled = `UnhandledEffect` (D8 `validate_handlers` catches it statically).
- Multi-shot (k used ≥2× in a branch) → `rep k` → NetClass ≥ I. Abort (`era k`) → NetClass ≥ A.

Or: Church-encode effect coproduct — handler argument selects by position.

#### Multi-shot continuations

Handler body uses `k` multiple times → **λK-term** → Rep needed:

```
-- handle comp with { "choose" alts k →
--   rep alts as (a0, a1) in rep k as (k0, k1) in (k0 a0) (k1 a1) }
```

Pass 1 detects `k` used twice → `rep_used = true` → NetClass ≥ I.
Existing R5/R6/R7 handle Rep correctly. Paper optimality preserved.

#### Abort

Handler uses `Era k` — continuation discarded:

```
-- handle comp with { "fail" _ k → era k in 0 }
```

`era_used = true` → NetClass ≥ A. C1 cleans disconnected subnet.

---

## Confluence and Optimality

**Confluence**: Tier 2 effects are pure λ-terms → φ_K maps them to canonical nets.
R1-R7 are confluent (main.tex §2). No new rules needed. Church-Rosser holds.

**Optimality**: One-shot effects = λL-terms → only R4 fires → step_count = β_count.
Multi-shot effects = λK-terms → R4-R7 fire → no redundant β-reductions (LO order).

---

## Open Items

### O1 — Lazy over-approximation in EffectRow inference

dnx is lazy. `let x = readFile "f" in 42` never forces `readFile` — erased by E-rule
before generating EffRequest. But conservative D7 inference still declares `{fs.file}`
in EffectRow. Safe (never misses), may over-declare for distribution.

Future: reachability analysis for more precise EffectRow. MVP: over-approximation ok.

### O2 — Handlers as content-addressed net computations

Currently handlers = Rust closures. Future:
- Handlers can be pure net computations
- Distribution artifact: `{ computation: Hash, handlers: Map<EffectLabel, Hash> }`
- Remote fetches missing handler hashes (like Unison's entity sync)

### O3 — Type system for effect rows (Pass 0.5)

Effect rows as part of computation types. System F + effect rows (Koka-style):
- Function type: `T →{ε} T`; open rows `{l | ε}`; bidirectional inference
- Subsumes D7's ad-hoc union. NOT full MLTT for MVP.
- Deferred: not needed for net correctness with free monad encoding.
- See elaborator.md §Open.

### O4 — Custom effect registration protocol

Cross-frontend effect label namespacing. MVP: string = identity, no collision protocol.
Future: `Structural` vs `Unique` (GUID-distinct, like Unison abilities).

---

## Architectural Classification (vs Unison)

| | Unison | dnx Tier 1 | dnx Tier 2 |
|---|---|---|---|
| Mechanism | ForeignCall or Reset/Capture | ForeignCall dispatch | Free monad Church encoding |
| Continuation | Stack frames captured | Not captured | λ-term (λresult.…) |
| Handler location | HEnv (runtime) | HandlerEnv (driver) | Elaborated into λ-terms |
| Multi-resume | Captured closure | Not supported | Rep on k variable |
| Abort | Discard instruction | HandlerResult::Abort | Era on k variable |
| Net agents | — | PrimFun/PrimVal | Fan/Rep/Eraser only |

---

## Relationship to Other Docs

- `ast.md` — `Ast::Perform` / `Ast::Handle` variants elaborate to λ-terms (not agents)
- `elaborator.md` — Pass 2 free monad encoding rules
- `syntax.md` — `perform label expr` / `handle expr with { ... }` surface syntax
- `driver.md` — Tier 1 trampoline loop + HandlerEnv setup
- `canonical-hash.md` — D6: ArtifactId{wire, effect_row} (UNIFIED 2026-06-04; wire=BLAKE3(serialize))
- `distribution.md` — D6: effect_row = capability contract for remote execution
