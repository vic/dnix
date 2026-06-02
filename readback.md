# δ-lang: psi_native Readback — SETTLED

## Overview

`psi_native : Net<Canonical> → δ-lang Expr`

Two-step composition:

```
Net<Canonical>
  ↓ psi_S (existing, dnx-elab crate)
LambdaIR  { Var(VarId) | Abs(VarId, Box<LambdaIR>) | App(Box, Box) }  -- NO sharing nodes
  ↓ lambda_to_dnx
δ-lang Expr
```

Direct net traversal NOT needed. psi_S collapses RepIn trees → multi-occurrence vars
(LambdaIR has no sharing nodes; RepIn = implicit multi-use). lambda_to_dnx inserts
explicit `rep`/`era` to satisfy δ-lang linearity.

---

## Why Two-Step Works

**C4 invariant** (verified against main.tex / woot.md):
After full normalization, ALL RepIn.principal → Abs.aux1.
C4 "aux fan replication" enforces this: every RepIn accumulates at a variable port.

Consequence: in Net<Canonical>, sharing structure = multi-use bound variables only.
psi_S reads this correctly as `LambdaIR` with multi-use variables.
lambda_to_dnx then makes sharing explicit via `rep`.

**`rep` in psi_native output ALWAYS nested inside `abs`.** No top-level rep.

---

## Soundness

**Why psi_native is total on ALL Net<Canonical>** (main.tex §4 Theorem):

```
Δ_S^c := image(φ_S)             [defined as such in main.tex §3 Definition]
φ_S : Λ_S → Δ_S^c               [bijection, §3 Definition — ASSERTED, not proved]
Ω_S : Δ_S^p → Δ_S^c             [all proper nets normalize into Δ_S^c, §4 Theorem]
psi_S = φ_S^{-1} : Δ_S^c → Λ_S  [total on Δ_S^c, follows from bijection]

Native elaboration → Net<Proper> ∈ Δ_S^p
normalize(Net<Proper>) ∈ Δ_S^c   [by Ω_S]
∴ psi_native total on all Net<Canonical>  □
```

**Paper honesty**: `φ_S` being a bijection is ASSERTED as a definition in main.tex §3 (L804),
not proved. The totality of `Ω_S : Δ_S^p → Δ_S^c` is ASSERTED at L1087, not proved.
Both are believed correct; neither has a formal proof in the paper.

Note: Δ_S^p ⊃ Δ_S^c. Native killer-feature nets (top-level rep) live in Δ_S^p \ Δ_S^c.
Normalize collapses them into Δ_S^c. Native degrees of freedom exist only BEFORE normalization.

---

## Round-Trip Property

```
normalize(elaborate(psi_native(net))) = net
```

Proof:
1. C4 invariant → psi_native output has reps only inside abs
2. reps-inside-abs → elaborate acts identically to φ_K (RepIn at abs_level+1)
3. normalize(φ_K(psi_S(net))) = normalize(φ_K(φ_K^{-1}(net))) = normalize(net) = net
   (net already canonical; normalize = identity on Net<Canonical>)  □

**Paper honesty**: Step 3 relies on `φ_S^{-1} ∘ Ω_S` being idempotent, which is ASSERTED
in main.tex L1095 but not proved. The round-trip holds by construction of the implementation;
the paper provides the conceptual grounding without a formal proof.

---

## lambda_to_dnx Algorithm

Single-pass with per-variable name supply (no post-substitution):

```
lambda_to_dnx(ir: LambdaIR, supply: &mut HashMap<VarId, VecDeque<Name>>) → Expr:

  Var(x):
    supply[x].pop_front()    -- consume next name (linear guarantee: always present)
    // if x not in supply: free variable → emit x directly as name

  App(f, e):
    App(lambda_to_dnx(f, supply),   -- func first (matches psi_S DFS order)
        lambda_to_dnx(e, supply))

  Abs(x, body):
    n = count_free_uses(x, body)
    match n:
      0 →
        body' = lambda_to_dnx(body, supply)   -- x not in supply; never emitted
        abs x . era x in body'
      1 →
        supply[x] = deque![x]                  -- x maps to itself (linear, no rep)
        body' = lambda_to_dnx(body, supply)
        supply.remove(x)
        abs x . body'
      k (k≥2) →
        names = [fresh() for _ in 0..k]        -- x0 .. x_{k-1}, pre-allocated
        supply[x] = deque!(names.clone())
        body' = lambda_to_dnx(body, supply)   -- occurrences filled in DFS order
        supply.remove(x)
        abs x . chain_reps(x, names, body')
```

**DFS order invariant**: psi_S traverses func/body before arg (App: principal before
aux1; Abs: aux0 before aux1). lambda_to_dnx processes App(f,e) with f before e.
Order matches → occurrence numbering (x0 = leftmost use) is consistent. Round-trip safe.

### chain_reps

Names are pre-allocated and already substituted into body' via supply threading.
chain_reps only wraps the rep structure:

```
chain_reps(orig: Name, names: Vec<Name>, body': Expr) → Expr:
  // |names| ≥ 2 (n=1 handled above; n=0 uses era)
  [n0, n1]          → rep orig as (n0, n1) in body'
  [n0, n1, ..., nk]:
    x' = fresh()
    rep orig as (n0, x') in chain_reps(x', [n1..nk], body')
```

Left-spine. Each intermediate x' used exactly once (linear ✓).

Example n=3: `rep x as (x0, x') in rep x' as (x1, x2) in body'`
  where body' already has x0, x1, x2 at respective occurrence positions.

### Semantic Equivalence of chain_reps

chain_reps creates a NEW left-spine RepIn topology — NOT the original canonical net's
RepIn tree topology (which is unique by perfect confluence but intentionally discarded
when psi_S collapses RepIn → multi-occurrence vars).

Both topologies are semantically equivalent:

> main.tex §1: "every normalizing interaction order produces the same result in the
> same number of interactions" [for core interaction rules only, pre-canonicalization]

Different RepIn topologies for same λ-term → same Net<Canonical> after normalization.
Core interaction step count equal (§1 perfect confluence). Canonicalization overhead
(C2/C3/C4) varies by topology → total step count MAY differ. Both Lévy-optimal
(optimality = no redundant β-reductions; §4 guarantee).

---

## Killer Feature: Computation ≠ Normal Form

Native `rep` at non-canonical positions affects REDUCTION TRACE, not normal form.

```delta
-- Native (level-0 rep): R5 fires before R4
def g = rep id as (a,b) in a b;

-- Lambda-style (level-1 rep): R4 fires before R5
def f = abs x . rep x as (x0,x1) in x0 x1;
-- (f id) has same normal form as g
```

Both normalize to `abs x . x`. psi_native of either = `abs x . x` (no rep: x used once).

Top-level reps in source → normalized away → psi_native emits abs without rep.

Programmer uses native rep positions for **performance tuning** (sharing topology control),
not for expressing different values. Killer feature is invisible in readback output.

---

## Eraser in Readback

For `abs x . era x in body`:
- Abs.aux1 has eraser_bit set (no RepIn)
- psi_S emits Abs(x, body_ir) with x absent from body_ir
- lambda_to_dnx: count=0 → supply[x] not added → emits `abs x . era x in body'`

---

## Free Variables

Free slots in Net<Canonical> → original names via `var_names[slot.free_var_id()]` in psi_S.
lambda_to_dnx: Var(x) with x not in supply → emits x directly as δ-lang `name`.
Free vars are NOT subject to linear checker (same as def-name refs). ✓

---

## Variable Names in Output

- **Bound vars**: psi_S assigns `fresh_var()` names. Output is **α-equivalent** to
  original source term, NOT name-identical. `alpha_eq(psi_native(net), source)` guaranteed
  (main.tex round-trip test uses alpha_eq comparator).
- **Free vars**: original def/prim names from var_names mapping preserved.
- **chain_dups intermediates**: gensym'd (x', x'', or sequential fresh names).

---

## Net<Proper> vs Net<Canonical> — Structural Differences

Net<Proper> (during reduction) CAN have structures that Net<Canonical> CANNOT [main.tex §4]:

| Structure | Net<Proper> | Net<Canonical> | Eliminated by |
|-----------|-------------|----------------|---------------|
| Non-canonical rep placement | ✓ allowed | ✗ forbidden | normalize() + φ_K^{-1} bijection |
| RepOut agents | ✓ exist (from R5) | ✗ none | C4 Phase2 exhaustion |
| Replicator trees (Rep→Rep connections) | ✓ exist | ✗ none | C2 unpaired merge |
| Fan-out replicators (RepOut at non-Abs positions) | ✓ exist | ✗ none | C4 aux fan replication |
| Disconnected erasable subnets | ✓ may exist (ΔK) | ✗ none | C1 mark-sweep |
| Active pairs in frontier | ✓ exist | ✗ empty | Phase1 + Phase2 exhaustion |

**Canonical = fully reduced + no rep-trees + no fan-out-reps + no disconnected subnets.**
These are the "additional degrees of freedom" in Δ_S^p \ Δ_S^c (main.tex §4).

## Net<Canonical> Structural Invariants (enforced before readback)

| Invariant | Source |
|-----------|--------|
| ALL RepIn.principal → Abs.aux1 | C4 invariant (main.tex §4) |
| NO RepOut agents present | C4 exhaustion: all RepOut resolved by Phase2 end |
| No Rep→Rep connections (no replicator trees) | C2 elimination during Phase1 |
| No disconnected subnets (ΔK only) | C1 mark-sweep |
| No active pairs in frontier1 or frontier2 | Phase1+Phase2 loop termination |

**RepOut in Net<Canonical> = invariant violation → debug_assert.** psi_S never encounters RepOut;
if one is present, the net was not fully canonicalized (Phase2 incomplete or C4 bug).

---

## Error Cases

None. psi_native is **total** on Net<Canonical>:
- §4 Theorem chain: Ω_S maps all Net<Proper> → Net<Canonical> = image(φ_S); psi_S = φ_S^{-1} total
- lambda_to_dnx terminates (LambdaIR finite tree; count bounded by net size)

---

## Settled — Do Not Revisit

- psi_native = two-step; no direct RepIn net traversal
- C4 invariant: RepIn.principal → Abs.aux1 in Net<Canonical> always
- NO RepOut in Net<Canonical>: Phase2 exhausts all C4 candidates; RepOut presence = debug_assert violation
- rep in output always inside abs (never top-level)
- LambdaIR has no sharing nodes; psi_S collapses RepIn trees → multi-occurrence vars
- lambda_to_dnx = single-pass with supply; no post-substitution pass
- chain_reps: names pre-allocated before body traversal; supply threading does substitution
- chain_reps for n>2: left-spine with fresh intermediates; each x' used once (linear ✓)
- chain_reps = semantic equiv via perfect confluence; step count may differ (topology differs)
- RepIn tree topology: unique by confluence, intentionally discarded in two-step (by design)
- round-trip: normalize(elaborate(psi_native(net))) = net [C4 + elaborate=φ_K + Projection Theorem]
- killer feature = computation path only; invisible in readback output
- psi_native total (no error cases) [§4 Theorem + finite termination]
- occurrence ordering = leftmost DFS matching psi_S traversal (func/body before arg)
- DFS order must match between psi_S and lambda_to_dnx for consistent occurrence numbering
- Δ_S^c := image(φ_S); Δ_S^p ⊃ Δ_S^c; native Δ_S^p\Δ_S^c nets collapse into Δ_S^c on normalize
- Free vars: Free slots → original names; not in linear scope
- Bound vars: fresh names in output; α-equiv guaranteed, name-exact NOT guaranteed
