# δ-lang: dnx::Ast — SETTLED

## Overview

`dnx::Ast<V, F>` is the Rust type produced by frontends and consumed by the elaborator.
Single shared IR between all frontends (δ-lang textual parser, Nix frontend, etc.)
and the elaborator pipeline.

`dnx::Ast` is **generic** over language-specific primitive types:
- `V: PrimVal` — language-specific literal values (e.g. `NixPrimVal` in `dnx-lang`)
- `F: PrimFun` — language-specific primitive functions (e.g. `NixPrimFun` in `dnx-lang`)

`PrimVal` and `PrimFun` are traits defined in `dnx-ast`. Each frontend implements them.
**No Nix-specific types exist in `dnx-ast`.** Nix primitives live only in `dnx-lang`.

`syntax.md` describes the *textual surface grammar*. `dnx::Ast` is the *Rust enum* — superset:
adds `Lit(V)` and `Fun(F)` for frontend-specific values and primitive functions.

---

## Traits


Marker traits. No required methods. Frontends impl them on their concrete types.

---

## dnx::Ast


`Fun(F)` is applied via `App` — e.g. `prim_select e key` =
`App(App(Fun(NixPrimFun::Select), e), key)`.

`Perform(l, arg)` and `Handle(comp, branches)` allocate **NO net agent** — both elaborate to
pure free-monad λ-terms (Abs/App/Rep/Era). See effects-and-handlers.md D10 + elaborator.md.

**Two-tier distinction**:
- `Fun(F)` with `PrimImpl::Effectful(label)` = Tier 1 (ForeignCall, driver handles)
- `Perform(label, e)` = Tier 2 (algebraic; free-monad λ-terms, reduced by core R1-R7 — no new rule)

---

## Name / Arc<str>


Cheap clone. Shared across Rep/Era binders, env maps, PrimTable keys.

---

## Invariants (enforced by frontends, checked by Pass 1)

| Invariant | Checked by |
|-----------|-----------|
| Each `Abs`/`Rep`-bound name used exactly once in body | Elaborator Pass 1 |
| `Rep` aux names `a ≠ b` | Frontend (name freshness) |
| `Fix` desugared before Pass 1 | Elaborator Pass 0 |
| No `Fun` in textual δ-lang parser output | δ-lang parser (never emits Fun) |

---

## Elaborator interface


Pass 2 dispatch on `Ast` variant:

| Variant | Net emission |
|---------|-------------|
| `Name(x)` | look up env → wire, or alloc Free slot |
| `Abs(x, body)` | `alloc_abs` → connect body + var wire |
| `App(f, a)` | `alloc_app` → connect f + a |
| `Rep(e, a, b, body)` | `alloc_rep_in` → connect e, bind a/b in env |
| `Era(e, body)` | eraser_bit on e's port |
| `Fix(e)` | desugared in Pass 0 (never reaches Pass 2) |
| `Val(v)` | `v.alloc_in(net)` — PrimVal trait method |
| `Fun(f)` | `f.alloc_in(net)` — PrimFun trait method |
| `Perform(l, e)` | elaborate to free monad λ-terms: `λpure.λh. h e (λr.pure r)` (Abs/App only) |
| `Handle(comp, branches)` | elaborate to fold λ-terms: `comp (λr.r) (λx.λk.body)` (Abs/App only) |

---

## Crate location

Shared by all crates.
`dnx-lang` depends on `dnx-ast` (for `Ast<V,F>` + traits).
`dnx-elaborator` depends on `dnx-ast` (consumes `Ast<V,F>`).

---

## LambdaAst (phi crate) — Frontend Surface

`LambdaAst` is the typed surface AST from frontends. It desugars to `Ast` via `phi_k`.


- `Ann(e, T)` → `phi_k(e)` (type erased after Pass 0.5)
- `Perform(l, e)` → `Ast::Perform(l, phi_k(e)?)`
- `Handle(comp, branches)` → `Ast::Handle(phi_k(comp)?, branches.map(phi_k))`

---

## Settled — Do Not Revisit

- Type name: `dnx::Ast<V, F>` (not `Expr`, not `LambdaIR`)
- `PrimValue` does NOT exist in `dnx-ast` — it was removed; each frontend defines its own `PrimVal` impl
- `Fun(F)` = language-specific primitive function; applied via `App`; never emitted by δ-lang textual parser
- `Val(V)` = language-specific literal value; emitted by frontends only
- `Name` = `Arc<str>` for cheap clone
- `Fix` desugared in Pass 0 — never reaches Pass 2 dispatch
- Nix primitives (`NixPrimFun::Select` etc.) live ONLY in `dnx-lang` — never in `dnx-ast`
- `PrimVal`/`PrimFun` = marker traits, no required methods
- `Perform(label, arg)` = Tier 2 algebraic effect; elaborates to free monad λ-terms (no net agent)
- `Handle(comp, branches)` = Tier 2 handler; elaborates to fold λ-terms (no net agent)
- Tier 1 ForeignCall effects = `Fun(F)` with `PrimImpl::Effectful(label)` — NO Perform/Handle needed
- `LambdaAst` = typed surface (includes Ann/Perform/Handle); phi_k translates to Ast
- Two-tier coexist: Tier1 (PrimFun+HandlerEnv, ForeignCall) + Tier2 (free monad, pure Abs/App/Rep/Era)
