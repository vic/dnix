# δ-lang: Native Delta-Nets Language — SETTLED SYNTAX

## Grammar

```ebnf
prog  ::= def*
def   ::= 'def' name '=' expr ';'

expr  ::= name                                             -- wire (linear: use once)
        | 'abs' name '.' expr                              -- abstraction → Abs
        | expr expr                                        -- application → App (left-assoc)
        | 'rep' expr 'as' '(' name ',' name ')' 'in' expr -- explicit replication → RepIn
        | 'era' expr 'in' expr                             -- explicit erasure → Eraser
        | 'fix' expr                                       -- fixpoint combinator
        | 'perform' label expr                             -- algebraic effect → free-monad λ-term (no agent)
        | 'handle' expr 'with' '{' handler* '}'            -- handler → free-monad fold λ-term (no agent)
        | '(' expr ')'                                     -- grouping

handler ::= label name name '->' expr                      -- label arg_name k_name -> body

label ::= STRING_LITERAL                                   -- e.g. "io" "nix.store" "choose"
name  ::= IDENT
```

## Core Primitives

| Syntax | Net Agent | Ports |
|--------|-----------|-------|
| `abs x . e` | Abs | principal=parent(↑), aux0=child(↓) body, aux1=parent(↑) var |
| `f x` | App | principal=child(↓) func, aux0=parent(↑) result, aux1=child(↓) arg |
| `rep e as (a,b) in body` | RepIn | principal=child(↓), aux0=parent(↑) a-wire, aux1=parent(↑) b-wire |
| `era e in body` | Eraser | virtual bit on PortId; no slot; principal only |
| `fix e` | Y-net | desugared to Y-combinator AST before elaboration |
| `perform "l" e` | (none) | free-monad λ-term; NO agent (effects-and-handlers.md D10) |
| `handle e with {…}` | (none) | free-monad fold λ-term; NO agent |

## Effect Syntax

```delta
-- Perform: effect "l" with argument e. Elaborates to free-monad λ-term; handler applied by β-reduction (R4).
perform "io" path

-- Handle: install handler for effect "l" in scope of e.
-- x = effect argument, k = continuation (λresult. rest-of-computation)
-- handler body may: App(k, value) — resume once
--                   Rep k as (k0,k1) in ... — resume multiple times
--                   Era k in result — abort (discard continuation)
handle (perform "choose" alternatives) with {
    "choose" alts k ->
        rep alts as (a0, a1) in
        rep k as (k0, k1) in
        (k0 a0) (k1 a1)
}
```

**Tier 1 vs Tier 2**: Nix frontend's `readFile` path, `storePath` etc. use
`Fun(NixPrimFun::ReadFile)` which has `PrimImpl::Effectful("fs.file")` — these are
Tier 1 (ForeignCall, handled by driver HandlerEnv). `perform`/`handle` syntax =
Tier 2 (algebraic effects with continuation capture).

## Type System: Linear

Each **bound** wire name (abs/rep-introduced) used **exactly once**. Explicit structural rules:

- `rep` for replication. Never implicit.
- `era` for erasure. Never implicit.
- Error: name used 0× (forgot `era e in ...`) OR 2× (forgot `rep e as (...) in ...`).
- **Def names are NOT linear** — global templates, each ref = fresh AST copy.

## Linearity Scope

```
abs x . body   → x is linear in body
rep e as (a,b) in body → a, b are each linear in body
era e in body  → no binders; body continues after erasure
```

Def references resolved by AST copy (Pass 0) — never reach the linear checker.

## Parallelism

ZERO syntax. Fully emergent from LO-path independence (main.tex §1, §4).
Any two active pairs with disjoint LO path prefixes reduce simultaneously.
§1: "interaction rules are local; applied simultaneously without synchronization"
§4: LO order guarantees optimality; prefix-independent pairs = disjoint write sets.
Programmer does NOT annotate parallelism.

## Level System (Elaborator — Never Programmer-Visible)

elaborate(expr) returns (PortId, result_level):

```
abs x . body:
  env[x] = (abs.aux1, current_level + 1)   -- x wire at level+1
  body elaborated at current_level (same)
  result_level = current_level

e1 e2:
  e1 at current_level (function)
  e2 at current_level + 1 (argument, behind app.aux1)
  result_level = current_level

rep e as (a, b) in body:
  elaborate(e) → (e_port, rep_level)       -- rep_level = result_level of e
  RepIn.level = rep_level
  env[a] = (rep.aux0, usage_levels[a])
  env[b] = (rep.aux1, usage_levels[b])
  d_i = (usage_levels[name_i] as i32) - (rep_level as i32)   -- i16, CAN BE NEGATIVE
  result_level = result_level of body

era e in body:
  elaborate(e) to get erased port (eraser is virtual, no level)
  result_level = result_level of body

name x:
  result_level = env[x].stored_level   -- abs_level+1 if abs-bound
```

**Delta rules (main.tex §3):**
- rep_level = result_level(e). For abs-bound name: rep_level = abs_level+1 (= φ_K formula, §3: d_i = l_i−(l+1)).
- Deltas i16, **CAN BE NEGATIVE**: `abs x . rep x as (a,b) in a b` → rep_level=1, d0=0-1=-1.
  (§3 φ_K guarantees d≥0 for canonical nets; native proper nets may have d<0 — still valid in Δ_S^p)
- For native-position reps (killer feature): rep_level = current_level ≤ usage_levels → d ≥ 0.

## What Changes vs Lambda + φ_K

| Lambda frontend | δ-lang native |
|---|---|
| φ_K bijection pass | NONE |
| Implicit weakening (unused var) | Explicit `era e in body` |
| Implicit contraction (multi-use var) | Explicit `rep e as (a,b) in body` |
| RepIn always at abs_level+1 | RepIn at result_level(e) — any position |
| Canonical nets only at source | Full proper-net space expressible |
| C1 mark-sweep | Still needed (era produces same disconnection as ΔK) |

## C-Rules vs R-Rules: LOPath and δ-lang Linearity

**R-rules** (R1-R7) fire on active pairs (principal⊗principal). Each produces new agents with
LOPath **extended** from the redex LOPath P via static suffix tables (P ++ 0b00, P ++ 0b01, etc.).
These are true reductions — they advance LO depth.

**C-rules** (C1-C4) are **topological rewires** — not active-pair rewrites (main.tex §4).
They restructure wiring at the *same* LO position. Key consequence:
- New active pairs created by C2/C3 **inherit** triggering pair's LOPath P — no extension.
- `connect(a, b, lo)` must always be called (never bypassed via `connect_peers` or `rewire`)
  so `detect_pair()` correctly routes to frontier1/frontier2.

**Which C-rules activate depends on δ-lang source constructs** (δ-lang is linear = explicit):

| Source uses | ΔS system | C-rules needed at runtime |
|---|---|---|
| neither `rep` nor `era` | ΔL | **none** — only R4 fires |
| `era` only | ΔA | C1 only |
| `rep` only | ΔI | C2 + C4 (no C1, no C3) |
| both `rep` and `era` | ΔK | C1 + C2 + C3 + C4 |

The linearity of δ-lang (explicit structural rules) is what makes this table computable at
compile-time — `era_used` flag from elaborator Pass 1 is exactly this check. ΔL programs
skip ALL C-rules; the runtime hot path is pure R4-only for linear programs.

## C1 Status

**C1 still runs** for programs using `era` (main.tex §4: "final canonicalization erasure step").
Explicit `era x` places eraser_bit on Abs.aux1 — identical net structure to φK implicit erasure.
When R4 fires on `(abs x . era x in body)(arg)`, eraser migrates to arg's result port.
If arg has no live wires back to root, it disconnects. C1 finds it.

Eraser on AUX port = INERT (not active pair). Erasure propagates lazily via R4/R5.

Only pure ΔI programs (zero `era`) can skip C1 (§4: "C1 skippable for ΔI programs").

## The Killer Feature

φ_K forces RepIn always at abs_level+1. δ-lang allows rep at ANY structural position:

```delta
-- Equivalent to phi_K canonical form (rep at level 1):
def f = abs x . rep x as (a,b) in a b;

-- NATIVE: share at level 0 (impossible in phi_K canonical form)
def g = rep id as (id0, id1) in id0 id1;
```

Different sharing position → different net structure → different reduction trace.

## Recursion

`fix e` desugars to Y-net AST before elaboration:

```
fix e  ≡  (abs f .
             rep (abs x . rep x as (x0,x1) in f (x0 x1)) as (m,m') in
             m m') e
```

`f` used once inside inner abs (linear ✓). Runtime replication of `f` via R5.

```delta
def fact = fix (abs self . abs n .
  rep n as (n0, n1) in
  mul n0 (self (pred n1)));
```

## Output: psi_native Readback

Two-step composition (see `readback.md` for full algorithm):

```
psi_native = psi_S → LambdaIR → lambda_to_dnx → δ-lang
```

**C4 invariant**: in Net<Canonical>, ALL RepIn.principal → Abs.aux1.
Therefore `rep` in psi_native output ALWAYS appears inside `abs`. No top-level rep.

| Agent | Emits |
|---|---|
| Abs (var used once) | `abs x . [body]` |
| Abs (var used 0×) | `abs x . era x in [body]` |
| Abs (var used 2×) | `abs x . rep x as (a,b) in [body]` |
| App | `[func] [arg]` |
| PrimVal | raw value (42, "str", etc.) |
| Free node | primitive/free variable name |

**Killer feature is computation, not normal form**: `rep id as (a,b) in a b` and
`(abs x . rep x as (x0,x1) in x0 x1) id` produce the SAME canonical normal form
(`abs x . x`) via different reduction traces (R5-before-R4 vs R4-before-R5).

## Examples

```delta
def id = abs x . x;

def K = abs x . abs y . era y in x;

def S = abs f . abs g . abs x .
  rep x as (x0, x1) in
  (f x0) (g x1);

def omega = abs x .
  rep x as (x0, x1) in x0 x1;

-- Diverges with CONSTANT MEMORY (not linear blowup)
def Omega = omega omega;

def zero = abs f . abs x . era f in x;
def one  = abs f . abs x . f x;
def two  = abs f . abs x .
  rep f as (f0, f1) in f0 (f1 x);

def fact = fix (abs self . abs n .
  rep n as (n0, n1) in
  mul n0 (self (pred n1)));
```

## Settled — Do Not Revisit

- Lambda surface: DROPPED
- `**` parallel operator: DROPPED (emergent)
- Absolute vs relative levels: relative at runtime, absolute in elaborator
- Wire-linear with explicit rep/era (not point-free)
- Level annotations in source: NONE (fully inferred)
- C1: still needed when `era` used; skippable for pure ΔI (era_used=false flag from elaborator)
- Eraser on aux = inert; lazy propagation via R4/R5
- Deltas i16, can be negative (abs-bound rep)
- Def names = templates (not linear); each ref = fresh AST copy
- Mutual recursion via fix only; def cycles → elaborator error
- Separate IR: none — elaborator → Net<Proper> directly
- psi_native = two-step (psi_S → LambdaIR → lambda_to_dnx); see readback.md
- Killer feature = computation path optimization (same normal form, different trace)
- LOPath: 4-limb {hot,warm,cold,frozen:u128,len:u8}; max depth 512; zero-alloc; API transparent (lopath.md)
