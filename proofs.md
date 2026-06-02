# DNX PROOF KERNEL — SINGLE SOURCE OF TRUTH

STATUS: FULLY SETTLED ✅ 2026-06-02 — Vic confirmed C1+C2. Coding can begin.
UPDATE 2026-06-03 (Vic): conv mechanism = structural intern (NOT BLAKE3 — §2b); +R11 ctor-field-universe soundness gate (Lean cross-check — §4 + Part III). Plan: trusted.md.
UPDATE 2026-06-04 (Vic + supervisor — UNIFIED IDENTITY): the system has ONE identity = **`ArtifactId`** = the canonical `serialize` bytes (canonical-hash.md), with two representations — LOCAL (`intern(serialize)`, conv TCB, structural-exact, no collision = the former "CanonId") + WIRE (`BLAKE3(serialize)`, distribution). `Const`/`Ind`/`Ctor`/`Elim` are content-addressed by `ArtifactId` (NOT separate interned `ConstId`/`IndId` name-ids); names = metadata→`ArtifactId`; `GlobalEnv` keyed by `ArtifactId` (§1, §2b, §6). The *code* refactor (drop `ConstId`/`IndId`/`CanonId` types) = SEPARATE impl track AFTER recursion — this is design only. ⚑ LOCAL = structural-exact-intern (RECOMMENDED) vs BLAKE3-only = open Vic-confirm (canonical-hash.md top).

This document merges the former `kernel-spec.md` (tight design SSOT) and `proofs.md`
(foundations, research Q&A, design decisions, soundness suite) into one authoritative file.

- **Part I** = the kernel spec (authoritative design). Read this to build.
- **Part II** = settled design decisions G1–G6 (the *why* behind Part I).
- **Part III** = soundness argument + test suite.
- **Part IV** = foundations, related-work deep dives, research Q&A (Q15–Q30), wishlist.

Authority: settle.md G1–G6 (now Part II) + Q15–Q30 (Part IV) + Vic axioms.
Net = arXiv 2505.20314. Theory target: MLTT + CIC inductives. Predicative.
No Classical/Quotient/typeclass v1.

SOUNDNESS RECONCILIATION (2026-06-02 merge):
- Part I and Part II agree; no contradictions in the design path.
- **G4 (raw Ind/Ctor/Elim, no levitation v1) SUPERSEDES Q24's levitation recommendation.**
  Q24 is retained in Part IV as research record only; Part I §4–5 follow G4.
- Q25–Q28 are RECOMMENDATIONS adopted by Parts I–II; still want Vic design-session sign-off.

═══════════════════════════════════════════════════════════════════════════════
# PART I — KERNEL SPEC (AUTHORITATIVE)
═══════════════════════════════════════════════════════════════════════════════

## 0. PIPELINE + φ_K ERASURE

```
surface (named)  --elab(untrusted)-->  Tm (core, de Bruijn, ANNOTATED)
Tm  --infer/check (TCB)-->  type ok      (conv invoked by T-Conv)
conv  --erase→φ_K→Ω_K→hash|readback-->  ≡ decision
δ,ι  OUTSIDE Ω_K  (Stuck-driven loop, typed layer)
```

φ_K erase rule: drop Lam.dom + all Pi (type positions). Net sees **pure λK only** (App/Abs/Era/Rep).
`Const`/`Ind`/`Ctor`/`Elim` → enter net as **Stuck free-slots** (NO new net agents). Ω_K unchanged.
de Bruijn binder → Abs node + wire; multi-use → Rep; non-use → Era.

INVARIANT (soundness, OPEN-1 resolved): `conv(t,u)` called ONLY when t,u already `check`ed at **same type**. Erased-net equality sound ⟺ same-type precondition holds. Enforced by T-Conv (B already a sort, t already : A, A≡B). Prevents D1 (`λx:A.x` vs `λx:B.x` net-collision).

---

## 1. Tm GRAMMAR (de Bruijn, annotated; complete)

```
Tm =
  | Var   (DbIdx)                  -- bound var; 0 = innermost binder
  | Sort  (Level)                  -- universe
  | Pi    (dom: Tm, cod: Tm)       -- Π; cod binds 1 var
  | Lam   (dom: Tm, body: Tm)      -- λ; body binds 1 var; dom erased at φ_K
  | App   (fn: Tm, arg: Tm)
  | Const (ArtifactId)             -- global def ref (δ-unfold target); content-addressed
  | Ind   (ArtifactId)             -- inductive type head; content-addressed
  | Ctor  (ArtifactId, ctor_ix: u32) -- constructor (position ctor_ix in the Ind's decl)
  | Elim  (ArtifactId)             -- recursor / eliminator (of the Ind)
```

- `DbIdx = u32`. **Heads are content-addressed by `ArtifactId`** (UNIFIED 2026-06-04, canonical-hash.md) — the `ArtifactId` of the definition's canonical net (Unison model), **NOT** separate interned `ConstId`/`IndId` name-ids and **NOT strings** (axiom 1). Human names = metadata mapping name→`ArtifactId` (elab layer). `Ctor`/`Elim` carry the parent inductive's `ArtifactId`.
- NO `Lit`: Nat is Inductive (A2 needs `Nat.rec`/ι). `PrimValue::Int` = nix-runtime only, NOT kernel (OPEN-12 resolved).
- NO `Let` in core: elaborator desugars `let x=v in b` → `App(Lam _ b) v` (β covers it). Keeps TCB minimal, no ζ-rule.
- NO metavars: elaborator-only.
- Annotation discipline (OPEN-11 resolved): core Tm KEEPS `Lam.dom`+`Pi` for `infer`; φ_K erases them. Single Tm type (no surface/core split at kernel boundary).
- Zero ambiguity: binders positional de Bruijn (no names in core); names live in elab layer only (G1).

---

## 2. TYPING RULES (TCB only)

```
T-Var    Γ ⊢ Var i : Γ[i]
T-Sort   Γ ⊢ Sort ℓ : Sort (ℓ+1)
T-Pi     Γ⊢A:Sort i,  Γ,A⊢B:Sort j           ⟹ Γ ⊢ Pi A B : Sort (max i j)
T-Lam    Γ⊢A:Sort _,  Γ,A⊢b:B                 ⟹ Γ ⊢ Lam A b : Pi A B
T-App    Γ⊢f:Pi A B,  Γ⊢a:A                    ⟹ Γ ⊢ App f a : B[0:=a]
T-Const  (c : T := _) ∈ env                    ⟹ Γ ⊢ Const c : T
T-Ind    (I : arity) ∈ env                     ⟹ Γ ⊢ Ind I : arity
T-Ctor   ctor k of I : Tk                       ⟹ Γ ⊢ Ctor I k : Tk
T-Elim   recursor of I : R  (§5)                ⟹ Γ ⊢ Elim I : R
T-Conv   Γ⊢t:A,  A≡B,  Γ⊢B:Sort _             ⟹ Γ ⊢ t : B
```

TCB side-conditions (soundness gates):
- universe consistency: T-Sort `ℓ+1`, T-Pi `max i j` (no `Type:Type` → R1/R2).
- δ-acyclicity: Const env is DAG (R7).
- strict positivity on Ind admission (§4, R3).
- recursor well-formedness: arity-table matches decl (R6), recursor only via §5 (R5 underapply stays Stuck).
- T-Conv `≡` = ONLY rule invoking Ω_K.

### 2b. conv `≡` mechanism (OPEN-13/14 resolved)

```
conv(Γ, t, u):
  closed(t)∧closed(u)?  closed := free_slots empty ∧ normalize→no Stuck
    YES: normalize both → intern(serialize) → ArtifactId LOCAL-eq   (fast path, A7; structural, NOT hash)
    NO : force_whnf both → match ValueHead:
           Abs,Abs   → recurse bodies under fresh neutral level
           Stuck,Stuck → δ/ι drive (§7) → structural spine compare
           Prim,Prim → eq
         then readback (psi_native, de Bruijn levels) + α-compare
η (typed shell, NOT Ω_K — net erased, can't see Π; OPEN-10 resolved):
  η-Π : one side Abs, other not, type = Pi  → η-expand → retry   (A4; domain-match guards R8)
  η-Unit : type ≡ Unit → both ≡
  NO η-Bool/Nat (multi-ctor). η-Σ deferred (G5, gate-off-Prop later).
```

α-eq mechanism = readback(levels)+structural (reuse `psi_native`); net-graph-iso = future opt.
Closed identity = **`ArtifactId` LOCAL equality** = `intern(serialize)` (canonical-hash.md): intern table bytes = ground-truth, hash only buckets → structural-exact, NO collision in TCB. This LOCAL representation is the mechanism formerly named `CanonId`. The WIRE representation `BLAKE3(serialize)` is distribution-only, **never** the conv decision — same `ArtifactId`, different view. (UNIFIED 2026-06-04; ⚑ structural-exact-vs-BLAKE3-only = open Vic-confirm, canonical-hash.md top; tests: trusted.md §Conv-mechanism + T6.)
Routing predicate (D3): open term NEVER takes the `ArtifactId` LOCAL fast path (uses lazy force_whnf + congruence).

---

## 3. UNIVERSE STRATEGY

```
Level = Nat                       -- Type₀, Type₁, … ; v1 MONOMORPHIC (no level vars/poly)
Sort ℓ : Sort (ℓ+1)               -- countable, unbounded; NO Type:Type
Π-rule : Pi (Sort i) (Sort j) : Sort (max i j)        -- PREDICATIVE
cumulativity : NON-cumulative. Sort i ⊄ Sort j. explicit `Lift` only-when-needed (NOT v1).
Prop : NONE v1 (predicative-only, Q30). no proof-irrelevance v1.
```

- Ω_K never sees universes (erased). ALL level checks in infer/check.
- R1 (`Type₀:Type₀`) → T-Sort. R2 (Π too low) → T-Pi max. A5 (large-elim into Type) → motive sort free.
- R10 (Prop large-elim) **DROPPED v1** (no Prop sort). re-add with impredicative-Prop + singleton-elim later.

---

## 4. INDUCTIVE DECLARATION REPR

```
Inductive {
  id      : ArtifactId,    -- content-addressed (UNIFIED 2026-06-04); was IndId
  params  : Telescope,     -- uniform params (shared all ctors + indices)
  indices : Telescope,     -- index telescope ([] for non-indexed; Nat for Vec)
  sort    : Level,         -- arity: Π params. Π indices. Sort sort
  ctors   : Vec<CtorDecl>,
}
CtorDecl {
  ctor_ix     : u32,
  args        : Telescope, -- ctor field types (may ref params + strictly-pos Ind occ)
  ret_indices : Vec<Tm>,   -- index values ctor returns (indexed families)
}
Telescope = Vec<Tm>        -- ordered binder types, de Bruijn left→right
```

Elim arity-table (type-erased survivor, baked at admission; OPEN-8 resolved):
```
{ ind: ArtifactId, nparams, nindices,
  ctors: [ { ctor_ix, nfields, nrec } ] }      -- nrec = #recursive args = #IH ; ind content-addressed (was interned IndId)
```

- positivity: **Lean4-style strict positivity** (G4, OPEN-6 resolved). per ctor arg: `Ind` occurs strictly-positive only (never left of →, never under non-spos). occurrence-check per arg telescope.
- **ctor-field universe (R11 — added 2026-06-03, Lean cross-check)**: each ctor field's sort level ≤ decl `sort` (STRICT; dnx predicative → no Prop/`is_zero` escape). Prevents large field in small inductive → predicativity break → proves False. NOT caught by T-Pi well-formedness (ctor *type* fine; *containment* isn't).
- mutual inductives: **NO v1** (deferred). single Ind per decl.
- nested inductives: **NO v1** (deferred, subset of mutual).
- indexed inductives: **YES** (Vec A n) via indices + ret_indices.

---

## 5. RECURSOR GENERATION (TCB; Lean4 mk_rec_rules pattern)

site = **TCB** (recursor trusted; elaborator cannot forge — OPEN-7 resolved).

Recursor type for `I` (params P, indices X, ctors C):
```
Elim I :
  Π (P)
  Π (motive : Π (X) (x: I P X). Sort ℓ_m)        -- ℓ_m free (large-elim, A5)
  Π (minor_k : MINOR_k)   for each ctor k
  Π (X)                                           -- target indices
  Π (x : I P X)                                   -- scrutinee
  → motive X x

MINOR_k  (ctor k, args A_k, recursive fields rec_j ∈ A_k):
  Π (A_k)                                         -- ctor fields
  Π (ih_j : motive (idx rec_j) rec_j)  per rec_j  -- one IH per recursive field
  → motive (ret_indices_k) (Ctor I k P A_k)
```

ι-rule (fires in Stuck-driver, OUTSIDE Ω_K):
```
Elim I P motive minors X (Ctor I k P a)
   ⟶  minor_k a (ih…)
   where ih_j = Elim I P motive minors (idx rec_j) rec_j     -- recursive call per rec field
```

- motive abstracts indices X + scrutinee x.
- indices threaded: motive @ `ret_indices_k` at result; motive @ `idx rec_j` in each IH (A6).
- ih: one per recursive field = recursor applied to that field.
- guards: underapplied recursor stays Stuck (R5); wrong minor count rejected by arity-table (R6); ι on neutral head never fires (R4).

---

## 6. δ/ι DRIVER + RE-ENCODE (OPEN-9 resolved)

```
loop on net at port:
  force_whnf(net, port) → ValueHead:
    Stuck(p):
      const?(p)         → δ: lookup body in &GlobalEnv → φ_K body → SPLICE subnet at p → retry
      elim-of-ctor?(p)  → ι: build RHS Tm (minor_k a ih…) → φ_K RHS → SPLICE subnet at p → retry
    Abs | Prim          → WHNF done
```

- SPLICE body/RHS **subnet** at Stuck port — NOT re-encode whole term (avoids exponential blowup).
- δ uses Rep-shared body (Q26 hybrid): glued rigid head outside, when forced unfold INTO net w/ Rep sharing.
- Stuck(PortId) → const/ind identity: resolve via free_slots reverse / `ArtifactId` on slot (OPEN-2 mechanism).
- `&GlobalEnv` threaded param, immutable (G6).
- GlobalEnv schema (OPEN-16 resolved; UNIFIED 2026-06-04 — keyed by `ArtifactId`, canonical-hash.md): `{ consts: Map<ArtifactId,(ty,body)>, inds: Map<ArtifactId,Inductive>, recursors: Map<ArtifactId,arity-table> }`; admission checks δ-acyclicity + positivity + recursor wf. (Was `ConstId`/`IndId`-keyed; names = metadata→`ArtifactId`.)

---

## 7. OPEN ITEMS

Design decisions: **ALL SETTLED** (OPEN-1,2,5,6,7,8,9,10,11,12,13,14,16 resolved above). UPDATE 2026-06-03 (Vic): conv = structural intern not BLAKE3 (§2b); **+R11** ctor-field-universe gate (Lean cross-check → §4 + Part III). UPDATE 2026-06-04 (Vic+supervisor): ONE identity = `ArtifactId` (LOCAL intern-eq = old "CanonId" + WIRE BLAKE3); heads/`GlobalEnv` content-addressed by `ArtifactId` (§1/§2b/§6). See trusted.md + canonical-hash.md.

Remaining (do NOT block coding start, do NOT affect soundness) → `unsettled.md`:
- **OPEN-15** test infra: D2 differential reference normalizer (independent normalizer for fuzz).
- **OPEN-17** theory: Ω_K Lévy-optimality under replicator-label coloring unproven. Blocks PERF headline, NOT soundness (Q25: soundness uses correctness, not optimality).

OPEN-17 discharge path: (a) cite GAL92/AG98/Lévy for inherited interaction-net-rule optimality (untyped λ); (b) write a separate lemma for the replicator-merge + level-delta-pairing rules unique to Δ-nets — paper already gives a prose sketch (main.tex §optimality); (c) machine-check that sketch. Honest framing until discharged: "perfect-confluence + soundness-correct"; claim Lévy-optimal only with the lemma in hand. NOTE: "optimal" = no unnecessary β-reductions (Lévy), NOT fewest total interactions (C-rules add overhead not counted in β).

Vic confirmed 2026-06-02 (minimalism → sound kernel):
- C1: NON-cumulative + explicit Lift ✅
- C2: Prop = NONE v1 ✅ (R10 dropped, proof-irrelevance deferred)

═══════════════════════════════════════════════════════════════════════════════
# PART II — DESIGN DECISIONS (SETTLED 2026-06-02)
═══════════════════════════════════════════════════════════════════════════════

### G1 TERM REPR ✅
de Bruijn indices in kernel layer. Named vars in elab layer only.
Bridge at φ_K: named λAST → de Bruijn before encoding.
Rationale: α-equiv = index equality, no capture-avoidance. nix-effects + Lean4 both use de Bruijn in kernel.

### G2 TYPE ERASURE ✅
Full erase type annotations before φ_K. Keep Elim arity-table (compile-time metadata).
- Erase: λ-binder type annotations, Pi-domain/codomain in term positions
- KEEP: recursor rule-table `{ctor_name, nfields, nindices, minor_count}` — baked into Elim node at elaboration time, NOT runtime type info
- Rationale: ι fires on constructor name (structural). Δ-Net is untyped by design — types cannot be in net. Lean4 + nix-effects both confirm structural ctor matching.
- Soundness risk: erasing arity table → wrong arg slicing → proves False

### G3 δ-REDUCTION ✅
Lazy-δ outside Ω_K. Unfold only when `Stuck(port)` and port is a defined const.
Shared Stuck-driver with ι (see G4).

### G4 ι-REDUCTION ✅
Raw Ind/Ctor/Elim (Lean4 style). No levitation / description universe in v1.
**(Supersedes Q24's levitation recommendation.)**
- ι CANNOT fire inside Ω_K — net has only fan/eraser/replicator agents
- External Stuck-driven loop handles both δ and ι:
  ```
  loop:
    force_whnf(net) → Stuck(port)?
      is_const(port) → δ-unfold → re-encode → retry
      is_elim_of_ctor(port) → ι-fire (apply minor premise) → re-encode → retry
    Abs/Prim → WHNF done
  ```
- Strict positivity check on Ind declarations = #1 soundness gate
- Rationale: description universe = bigger blast radius, generic elim bugs affect all inductives. Raw Ind = well-trodden, Lean4 kernel pattern.

### G5 CONV η-RULES ✅
v1: η-Π (mandatory) + η-Unit (trivial).
η-Σ/struct: add alongside record support, gate off Prop.
Bool/Nat: no η (multi-ctor types have no η).
η is completeness not soundness — monotone-safe to grow. η-Σ on Prop = unsound risk.

### G6 GLOBAL ENV ✅
`&GlobalEnv` threaded as param throughout kernel. Immutable ref. No global statics.
Steal nix-effects Layer 0 pattern (eval+quote+conv take Env as param).

═══════════════════════════════════════════════════════════════════════════════
# PART III — SOUNDNESS ARGUMENT + TEST SUITE
═══════════════════════════════════════════════════════════════════════════════

Soundness gate = these tests pass before any claim of correctness.
Fourcolor (fourcolor-lean) = completeness target, deferred — needs Mathlib-level features not in v1.

## TCB SPLIT (Q25)

MUST be in TCB (soundness depends on each):
- `φ_K` (Tm→net) — bug ⇒ wrong net ⇒ wrong nf ⇒ accept false. TRUSTED.
- `Ω_K` (net normalizer) — β/ι engine. Wrong reduction ⇒ wrong conv. Must be CONFLUENT + correct rule table. TRUSTED.
- `φ_K⁻¹` (readback) — wrong readback ⇒ wrong α-compare. TRUSTED.
- `conv` (α-compare + η + universe-level compare) — equality decision. TRUSTED.
- PLUS `infer`/`check` + positivity + universe/level consistency + termination/guard. These make the SYSTEM consistent — optimal β is worthless if a non-positive inductive or `Type:Type` is accepted.

CAN be OUTSIDE TCB (re-checked by TCB): elaborator, unifier/metavars, surface syntax, HOAS, notation, tactics, implicit-arg inference, definition DB (bodies re-checked on add). nix-effects Layer-2 pattern.

MITIGATION for large TCB surface: keep Ω_K rule table small+fixed (closed alphabet), machine-verify confluence once. Optimality (min-steps) is NOT in the soundness argument — only correctness is.

## MUST-ACCEPT (completeness)

| # | test | exercises |
|---|---|---|
| A1 | `id : Π(A:Type₀)(x:A), A` applied + `refl` typechecks | φ_K erasure + readback roundtrip |
| A2 | `Nat.rec` on `succ(succ zero)` → literal `2` | ι fires on ctor, Elim arity-table correct |
| A3 | `add 2 3 = 5` via δ-unfold | δ-unfold + Ω_K confluence |
| A4 | η-Π: `f` conv `λx. f x` for `f : Π(x:A), B x` | η-Π conv path |
| A5 | Large-elim: `Nat.rec` motive into `Type` | predicativity, universe of motive |
| A6 | `Vec A n` recursor, motive depends on index | index substitution in ι |
| A7 | `ArtifactId` LOCAL-eq closed ≡ structural open — both routes agree on same term | conv routing correctness |
| A8 | α-rename roundtrip: `λx.λy.x` survives φ_K → Ω_K → φ_K⁻¹ intact | de Bruijn scoping in readback |

## MUST-REJECT (soundness traps, priority order)

| # | test | hole plugged |
|---|---|---|
| R1 | `Type₀ : Type₀` | Girard/Hurkens — universe inconsistency. **HIGHEST PRIORITY** |
| R2 | `Π(A:Typeᵤ).A : Typeᵤ` (Π placed too low) | Hurkens via Π universe-max miscompute |
| R3 | `Inductive Bad := mk : (Bad → Bad) → Bad` | non-strict-positive → proves False. **HIGHEST PRIORITY** |
| R4 | ι-fire on neutral/stuck head (no ctor exposed) | false ι firing = unsoundness |
| R5 | Underapplied recursor fires | must stay Stuck |
| R6 | Recursor with wrong minor-premise count | Elim arity-table mismatch |
| R7 | δ-cycle: `A := A` or forward-ref loop | definition acyclicity |
| R8 | η-Π with mismatched domains: `λx:A.f x` ≠ `f` when `f:B→C`, `A≠B` | η scoping |
| R9 | `λx.λy.x` ≠ `λx.λy.y` after roundtrip | de Bruijn capture in readback |
| R10 | `Nat.rec` (Prop motive) eliminating into `Type` (non-singleton) | large-elim Prop→Type restriction (DROPPED v1, no Prop) |
| R11 | `Inductive Big : Type₀ := mk : Type₀ → Big` (ctor field's universe > decl's) | **predicativity break** — large field in small inductive proves False. Gate: each field sort level ≤ decl `sort`. MISSING from spec, added 2026-06-03. **HIGH PRIORITY** |

## ΔNET-SPECIFIC risks (no analogue in tree-walking kernels)

| # | test | risk |
|---|---|---|
| D1 | `(λx:A.x)` vs `(λx:B.x)` erase to IDENTICAL net → SAME `ArtifactId` (LOCAL-eq cannot distinguish — types erased). Soundness from §0 same-type precondition (conv never called at `A≠B`), NOT from id-distinctness | erasure collision; GUARDED by §0 INVARIANT + kernel item 1b |
| D2 | random closed λ-terms: Ω_K NF == trusted reference NF (differential fuzz) | bracket mismanagement in optimal sharing (OPEN-15) |
| D3 | open term with free vars must NOT take `ArtifactId` LOCAL fast path | premature full-normalize on non-closed term (use lazy WHNF+congruence) |
| D4 | `λx.λy.x` sharing preserved after net reduction | readback scope after binder reordering via sharing |

### A1 trust strategy

Optimal-β-as-conv is NOVEL — no prior published meta-theory combines optimal-reduction + definitional-equality + dependent types. Cannot borrow soundness from external type-theory consistency proofs. The entire TCB soundness rests on A1 (full Church–Rosser with C-rules + φ_S⁻¹ readback idempotency, asserted in paper not proved).

Trust is built empirically, not theoretically, via:
- **T1 differential fuzz** (see trusted.md §T1): independent reference normalizer vs Ω_K on ≥10k random closed λ-terms. Any disagreement = implementation bug (core R1-R7 confluence proven → disagreement is never a theory gap). T1 is NON-NEGOTIABLE and the only available A1 evidence.
- **T6 CanonId injectivity**: `intern(serialize(n1)) == intern(serialize(n2)) ⟹ n1 ≡_β n2`. Tests representation-invariance (alloc-order, generation, topology erased from canonical form).
- **Stretch**: machine-checked confluence of full R1-R7+C1-C4 would promote A1 from asserted to proven — this is the only path to "verified" without qualification. High effort; do after T1 green.

## HISTORICAL BUGS these catch
- Lean4 `Acc.rec` large-elim Prop→Type → R10
- Coq 2014 universe-poly Type:Type via template-poly → R1/R2
- Coq 2013/2017 fixpoint guard holes → R3
- Lean/Coq VM-vs-kernel NF divergence → D2

═══════════════════════════════════════════════════════════════════════════════
# PART IV — FOUNDATIONS, RELATED WORK, RESEARCH Q&A
═══════════════════════════════════════════════════════════════════════════════

## FOUNDATION: WHAT PAPER GIVES (arXiv 2505.20314)

Paper = pure untyped λ-calculus + interaction nets. ZERO type theory content.

| Have | Notes |
|---|---|
| `φ_S : Λ_S → Δ_S^c` | bijection λ-terms ↔ canonical Δ-nets |
| `Ω_S` | optimal β-normalizer, MINIMUM steps guaranteed |
| λL/λA/λI/λK | 4 calculi (linear/affine/relevant/full structural rules) |
| idempotency | `φ_S⁻¹ ∘ Ω_S` idempotent = normalizer provably correct |
| S ∈ {L,A,I,K} | λK = weakening+contraction = full λ-calculus |

## CURRY-HOWARD BRIDGE (β only)

Under Curry-Howard, CoC proof terms ARE λ-terms (with type annotations).
β-reduction on proof terms = same β as λK. `Ω_K` computes it optimally.

```
proof term t : P  (CoC)
  → erase type annotations → untyped λK-term t*
  → φ_K(t*)  → Δ-net
  → Ω_K      → canonical normal form  (OPTIMAL: min β-steps)
  → φ_K⁻¹   → β-normal form
```

**Definitional equality (β-conv) via Δ-nets:**
```
t₁ ≡_β t₂  iff  φ_K⁻¹(Ω_K(φ_K(t₁*))) =_α φ_K⁻¹(Ω_K(φ_K(t₂*)))
```

Killer feature: optimal = fastest possible conv check.
Type-checker calls normalizer on EVERY type annotation — perf matters enormously.

## NbE MAPPING: nix-effects → ΔNETS

| NbE (nix-effects) | Δ-nets analog |
|---|---|
| `eval : Env × Tm → Val` | `φ_S` translation to net |
| reduction in `vApp` (β fires) | `Ω_S` interaction steps |
| `quote : Val → Tm` | `φ_S⁻¹` read-back |
| `conv : Val × Val → Bool` | α-compare after normalize |

NbE = call-by-value, eager. Δ-nets = optimal (minimum steps). Δ-nets strictly better.

## LEAN4 KERNEL ARCHITECTURE (leanprover/lean4)

Two-layer: **trusted kernel** (C++) + **MetaM** (Lean, NOT trusted).

### Trusted Kernel TCB
| File | Role |
|---|---|
| `type_checker.cpp` | WHNF, def-eq, type inference |
| `environment.cpp` | declaration storage, `add()` entry point |
| `inductive.cpp` | ι-reduction for recursors |
| `quot.cpp` | quotient type reduction |

Trust level: `LEAN_BELIEVER_TRUST_LEVEL = 1024`. Above = no type checking.

### WHNF Normalization
- `whnf_core(e, cheap_rec, cheap_proj)` — β, ζ (let), ι (recursor→ctor), quotient, proj
- `whnf(e)` — calls `whnf_core` + δ (definition unfolding) + native/Nat builtins

### Definitional Equality (`is_def_eq_core`)
1. Quick structural check
2. `whnf_core` cheap pass
3. Proof irrelevance
4. **Lazy delta reduction** — unfold lower-priority constant first. Same priority + same head → compare args before unfolding.
5. Congruence, η-expansion, η-struct, string literals, unit-like types

### MetaM (NOT trusted, elaborator only)
- Adds transparency modes: `all/default/instances/reducible/none`
- Adds metavariable support

### KEY DNX TAKEAWAY
Lean4 lazy delta = unfold only what necessary. Δ-nets optimal β = same spirit.
dnx kernel = same two-layer: **TCB** (φ_S + Ω_S + conv) + **elaborator** (untrusted).

### `whnf` loop
```cpp
expr t = e;
while (true) {
    expr t1 = whnf_core(t);           // β + ζ + ι + proj (no δ)
    if (auto v = reduce_native(t1))   // Lean.reduceBool/Nat via compiled IR
    if (auto v = reduce_nat(t1))      // built-in Nat arith
    if (auto next_t = unfold_definition(t1)) t = *next_t;  // δ: unfold one const
    else return t1;                   // stuck = WHNF
}
```
Two caches: `m_whnf_core` (no-δ), `m_whnf` (full with δ).

### `lazy_delta_reduction_step`
1. Both have delta-def: compare `ReducibilityHints`. Unfold LOWER priority first.
2. Same priority + same head + regular hint → try `is_def_eq_args` BEFORE unfolding. Cache failures in `m_failure`.
3. One side = projection app → `try_unfold_proj_app` instead of full δ.

### `is_def_eq_core` flow
1. `quick_is_def_eq` — pointer eq, memoized equiv_manager, binding/sort/lit
2. `whnf_core` cheap pass (cheap_rec=true, cheap_proj=true)
3. Proof irrelevance (Prop-typed neutrals)
4. `lazy_delta_reduction_step` loop
5. `is_def_eq_app` — congruence (same fn + args)
6. `try_eta_expansion_core` — Π-η
7. `try_eta_struct_core` — struct-η (single-ctor non-recursive)
8. Unit-like types, string literal expansion

### ι-REDUCTION (`reduce_recursor` → `inductive_reduce_rec`)
```
reduce_recursor(e):
  → quot_reduce_rec (quotient types)
  → inductive_reduce_rec(env, e, whnf_fn, infer_fn, is_def_eq_fn)
     → get_rec_rule_for(rec_val, major_premise)
       → match major_premise head const against recursor rules
       → if ctor found: instantiate rule RHS with params + args
```
ι fires when: `recursor applied to constructor`. Major premise forced to WHNF first.
`cheap_rec=true` → use `whnf_core` (no δ) on major. `cheap_rec=false` → full `whnf` (with δ).

### ι-REDUCTION DATA MODEL (from codegraph)
```cpp
struct recursor_rule {
    name   get_cnstr();   // constructor name this rule fires for
    uint   get_nfields(); // #fields (excl. params)
    expr   get_rhs();     // RHS template = comp_rhs (lambda over params+Cs+minors+fields)
};
```
`mk_rec_rules` builds RHS at `add_inductive` time:
```
comp_rhs = λ params. λ Cs. λ minors. λ b_u. (minor_i b_u v)
```
where `v` = recursive call applications (IH arguments).
ι fires: match major premise ctor name → get_rhs() → instantiate w/ actual args.

For dnx: ι = lookup `recursor_rule` in global env → substitute → translate to net → reduce.
No new agent type needed: ι fires OUTSIDE Ω_K (unfold in λ-term repr, then retranslate).

### KEY FOR DNX
- `reduce_native` = compiled Lean code for `vm_compute`-equiv. **fourcolor uses this**. Ω_K competes directly.
- `m_whnf` cache = memoized normalization. Dnx must cache `φ_K⁻¹(Ω_K(φ_K(t)))` per-term.
- `m_failure` cache = negative memoization (known-unequal). Critical for perf.
- `equiv_manager` = positive memoization. Dnx: `ArtifactId` LOCAL = `intern(serialize)` = this (free for closed terms; was `CanonId`, see §2b:110, canonical-hash.md). NOT BLAKE3 (that is the WIRE/distribution view only).
- `reduce_nat` = 14 built-in Nat ops. Dnx: `PrimValue::Int` covers this.

### KERNEL FILES REFERENCE
| File | Role |
|---|---|
| `type_checker.cpp` (1244L) | WHNF, def-eq, lazy-delta, η, infer |
| `type_checker.h` (174L) | caches: m_whnf, m_whnf_core, m_failure, equiv_manager |
| `inductive.cpp` | ι-reduction (recursor → constructor) |
| `environment.cpp` | `add()` entry point, trust level |
| `declaration.cpp` | ReducibilityHints (regular/abbrev/opaque) |
| `equiv_manager.cpp` | positive def-eq memoization |

Source: lean4 kernel.

## nix-effects MLTT KERNEL (kleisli-io/nix-effects)

Closest existing proof kernel to dnx target. Pure Nix.

### Trust Layers
| Layer | Trust | Role |
|---|---|---|
| 0 TCB | highest | `eval`, `quote`, `conv` — pure, no effects |
| 1 semi | medium | `check`, `infer`, `checkTypeLevel` |
| 2 untrusted | none | `hoas`, `elaborate` |

Layer 2 bugs CANNOT break soundness — Layer 0 re-verifies all output.

### Term Repr
- `Tm`: de Bruijn **indices** (0=innermost). Nix attrsets w/ `tag`.
- `Val`: de Bruijn **levels** (0=outermost). Stable under ctx extension.
- Closures: defunctionalized `{env, body}` — no Nix lambdas in TCB (Nix `==` on lambdas = always false).

### Pi-types / Sort
```
eval(ρ, Pi(n,A,B)) = VPi(n, eval(ρ,A), (ρ,B))
vApp(VLam(n,A,cl), v) = instantiate(cl, v)   -- β fires immediately
```
- Level-indexed, **non-cumulative** (cumulativity only in `check` Sub rule)
- Level = join-semilattice: `zero`, `suc`, `max` — normalised in `conv`
- `U(i) : U(i)` REJECTED (level i+1 > i). Cross-level: `Lift l m eq A : U(m)` primitive

### Definitional Equality (`conv`)
- Purely structural on normalized values (NbE). No type info used.
- η-rules: **Π-η** (`f ≡ λx. f x`), **Σ-η**, **⊤-η**
- Binding forms: instantiate both closures w/ fresh `VNe(d,[])`, recurse at d+1
- Neutrals equal iff same de Bruijn level + convertible spines

### Reduction: call-by-value NbE
- Fuel-threaded: default 10M steps. Throws `"normalization budget exceeded"`.
- Trampolining via `builtins.genericClosure` for deep Nat/List chains.
- Stuck = `VNe(level, spine)` neutral (open term, can't reduce).

### Inductive Types (description universe — NOT adopted by dnx, see G4)
- `Desc^k I` + `μ I D i` = single inductive primitive (Dybjer/levitation)
- `descCon` = Ctor, `descInd` = Elim, `descElim` = recursor for Desc itself
- iota-reduction: YES in `vDescIndF` (trampolined). W-types via `datatypeP`.
- Prelude: Nat, List, Sum, Fin, Vec, Eq, Bool, Void — all via description universe

### NOT Implemented vs Full CIC
Cumulativity (explicit `Lift`), impredicative Prop, mutual inductives, inductive-recursive,
general termination (structural only), `funext` (postulate), `levelToNat` (absent).

## AGDA KERNEL (agda/agda)

### Architecture
```
compareAs/compareTerm (Conversion.hs)
  → checkSyntacticEquality  ← O(1) pointer eq fast path
  → compareAtom → reduceB (WHNF both) → case split: MetaV/Blocked/neutral/constructor
```

### WHNF: TWO PATHS
- **Fast path**: `Reduce/Fast.hs` — Krivine-style call-by-need AM in `ST s`. Thunks updated in-place. Local sharing only. `memoQName` caches `QName→CompactDef` per `fastReduce` call.
- **Slow path**: `Reduce.hs` — structural WHNF via `unfoldDefinitionE` loop.

### NEUTRALS = BLOCKED TERMS
```haskell
Blocked Blocker a | NotBlocked (NotBlocked' t) a
-- NotBlocked: StuckOn elim | Underapplied | MissingClauses | ReallyNotBlocked
-- Blocker: UnblockOnMeta MetaId | UnblockOnDef QName | UnblockOnAll/Any
```

### MEMOIZATION: NONE ACROSS REDUCTIONS
- No `m_whnf` cache like Lean4. Each `reduce` starts fresh. Only STRef thunks within ONE reduction.
- **DNX ADVANTAGE**: `m_whnf` cache + BLAKE3 hash = orders of magnitude better.

### TCB: NO SMALL KERNEL

### KEY DNX ADVANTAGES vs AGDA
| | Agda | Dnx |
|---|---|---|
| Sharing | STRef thunks (local) | Replicators (global, optimal) |
| Memoization | None across calls | BLAKE3 hash + whnf cache |
| Parallelism | None | LOPath antichain + rayon |
| Optimal β | No (call-by-need) | Yes (Lévy-optimal) |
| TCB size | Huge (10+ files) | Tiny (φ+Ω+φ⁻¹+conv) |

## COQ KERNEL (coq/coq)
- `cClosure.ml`: lazy sharing via OCaml closures (local, no cross-call cache)
- `conversion.ml`: normalize to WHNF → structural compare → lazy delta loop
- TCB: `cClosure.ml` + `conversion.ml` + `term.ml` + `inductive.ml`
- Delta bottleneck: repeated unfolding of same const, no negative memoization
- Complexity: O(n) best case, exponential worst (deep delta chains)
- **Dnx fix**: negative memo (`m_failure` equiv) + optimal β eliminates repeated work

## SOMA (SrGaabriel/soma) — MOST RELEVANT RELATED PROJECT

Dependently typed FP lang → native via LLVM. Interaction nets as compilation model. QTT. GC-free via DUP/ERA.
```
Source → CST → AST → Core → Circuit IR (interaction net) → Alloy IR (SSA) → LLVM → Native
```
- Full dependent types + **QTT** (0=erased, 1=linear, ω=unrestricted)
- Pi (explicit/implicit/instance), Sigma (sugar over inductive). Impredicative Prop (Coq-like).
- **NbE separate from Circuit IR** — type checker never touches interaction net.
- `convert`: force both → structural match. η: Π-η, record-η. Proof irrelevance short-circuit.
- Full GADTs, indexed families, strict positivity. Structural recursion via size-change matrices (SCC).

### KEY DNX DIFF
Soma: interaction nets = runtime memory-management layer (below type checker).
dnx goal: interaction nets = THE normalizer INSIDE the type checker (Layer 0 TCB). More ambitious.

## LINEAR LOGIC LINEAGE
```
Girard 1987 LL (proof nets, !A) → Lafont 1990 Interaction Nets [Laf90]
  → GAL92 GoI + LL Without Boxes → AG98 Optimal Impl FP → Lambdascope 2004 [OL04]
  → Δ-nets 2025 (arXiv 2505.20314)
```
`!A` exponential = sharing/replication = replicators in Δ-nets.
Paper buried comment: `D ~= !D -o D` (vs GAL92's `D ~= !(D -o D)`).
MLL proof nets ≅ λL fragment. weakening=λA, contraction=λI, both=λK. Direct path: LL proofs → proof nets → Δ-nets.

## PAPER BIBLIOGRAPHY (arXiv 2505.20314)
| Key | Work |
|---|---|
| Lev78/80 | Lévy — Optimal Reductions in Lambda-Calculus |
| Lam89 | Lamping — Algorithm for Optimal Lambda Calculus Reduction |
| Laf90 | Lafont — Interaction Nets |
| GAL92a | Gonthier/Abadi/Lévy — Geometry of Optimal Lambda-Reduction |
| GAL92b | Gonthier/Abadi/Lévy — Linear Logic Without Boxes |
| Jac93 | Jacobs — Semantics of λI and other substructure λ-calculi |
| Laf97 | Lafont — Interaction Combinators |
| AG98 | Asperti/Guerrini — Optimal Implementation of FP Languages |
| LM99 | Lawall/Mairson — Optimality and inefficiency |
| OL04 | van Oostrom/van de Looij — Lambdascope |

ZERO refs to: Lean/Coq/Agda, CoC/CIC.

## RELATED REPOS
| Repo | Relevance |
|---|---|
| SrGaabriel/soma | QTT + dependent types + interaction nets. MOST SIMILAR GOALS. |
| kleisli-io/nix-effects | MLTT kernel, TCB layer pattern, NbE, inductives. STEAL ARCHITECTURE. |
| leanprover/lean4 | Production proof kernel. C++ TCB. Lazy delta. |
| rocq-community/fourcolor | First test case. 119 files, 44k LOC. |
| danaugrs/deltanets | Paper author's JS ref impl of Δ-nets |
| VineLang/Vine | Interaction net lang |

## FOURCOLOR TEST CASE

Four color theorem Coq/Rocq proof. rocq-community/fourcolor. **119 `.v` files, ~44k LOC.**
99 Fixpoints. 116/119 use ssreflect. 148 `reflect`-lemma uses. Tiny explicit Eval: 3 `compute`, 2 `vm_compute` — most computation IMPLICIT in conv-checking. Largest: present7/8/9.v (the 633 reducible-config enumeration).

WHAT IT STRESSES MOST:
1. BOOLEAN REFLECTION (ssreflect `reflect`/`is_true`): kernel must REDUCE decidable boolean computation. ι+δ heavy — exactly Ω_K's job.
2. ι-REDUCTION on tree/graph recursors (gtree, kempetree — 99 Fixpoints over inductive graph/tree types).
3. δ-UNFOLDING of many ssreflect library defs (Q29 #1 bottleneck) — tests Q26 hybrid lazy-delta hard.
4. LARGE CASE ENUMERATION (present7-9.v) — massive structural terms; tests φ_K/φ_K⁻¹ + α-compare scaling.

NOT stressed: universe poly (mostly Type₀), HITs, coinduction. Tests COMPUTE/conv path almost exclusively — ideal first benchmark. `vm_compute`/`native_compute` exist BECAUSE lazy conv too slow — Ω_K optimal β is the direct competitor. Beating vm_compute on these 5 sites = headline result. Need ssreflect prelude support to import.

## RESEARCH Q&A (KNOWN ANSWERS — DW + literature)

### Q15+19+21: Optimal reduction + typed calculi
- Lévy optimality = stated for UNTYPED λ-calculus only.
- β preserves types in simply-typed + System F + CoC (subject reduction).
- Parallel β (Church-Rosser) holds for typed calculi — no type errors in intermediate steps.
- CLOSED terms in pure CoC: β-normal form equality = definitional equality (β-completeness). SN + confluence → unique nf → conv ≡ nf comparison. ✅
- η NOT captured by β-normalization → need η-expansion pass in conv.

### Q16: Bracket problem (Lamping)
Lamping needs bracket/croissant nodes to track which copies belong together inside shared context. Δ-nets claim: replicator LABELS solve this — labeled reps annihilate only matching labels. No bracket nodes. Type-agnostic. ✅

### Q17: GoI for dependent types — what breaks?
GoI = token-passing; works for MLL/MELL + System F (∀ erased, routing type-independent). BREAKS for dependent types: a TYPE can mention a VALUE (`Vec n`) → wire routing would depend on a value computed elsewhere; GoI wiring is static, dep-types need value-dependent topology. Also GoI = observational equiv, conv needs intensional.
DNX INSIGHT: VALIDATES erase-then-normalize split. Δ-nets sound for ERASED λK-term. Type-level computation (Π/Sort/ι on indices) MUST be in a separate typed layer, NOT inside Ω_K. Net = β-engine on erased terms only.

### Q18: Δ-nets ⊆ Lafont Interaction Combinators?
Lafont IC = γ/δ/ε, 2 schemas (annihilation+commutation), universal. Δ-nets node set: App, Abs (γ-like), Era (=ε), Rep (LABELED w/ integer level + status). Rules: App-Abs annihilation, Era erasure, Fan-Rep commutation, Rep-Rep commutation (level-delta arithmetic), Rep-Rep MERGING.
VERDICT: NOT a literal subset — adds integer-level labels w/ arithmetic + status flag + merge rule (no IC analog). This labeled-level scheme = the bracket-free oracle (Q16). But SIMULABLE by IC (universal). Practically: Δ-nets = IC + integer-labeled duplicators + merge.

### Q20: Eliminator shared via replicator + ι on one copy — safe?
LOCALLY SAFE by confluence: ι = annihilation Elim-Ctor; Rep already duplicated Elim → each copy independent subnet. Firing ι on copy 1 can't touch copy 2. Interaction nets strongly confluent ⇒ order irrelevant.
DEP-TYPE CAVEAT: if copies receive DIFFERENT constructors, each ι picks a different branch — CORRECT for dependent elimination. Wrong-copy-fusion prevented by replicator labels.
SOUNDNESS HINGES ON: ι being type-ERASED. Erase motive before netting (Q23 quantity-0) OR keep ι OUT of Ω_K in typed layer. Recommended: ι on ERASED recursor = pure pattern-select, safe under duplication.

### Q22: Glued Evaluation (AndrasKovacs/smalltt)
Maintain TWO values per term: **rigid** (opaque head+spine, def NOT unfolded) + **lazy** (fully unfolded thunk, forced on demand, memoized). Conv tries rigid heads first: same head → recurse args, NO UNFOLDING. Different heads → force both thunks → retry. Common case = O(1).
DNX ADAPTATION: Δ-nets = fast-path unfolded value. Rigid spine = glued head. Rigid-fail → net → Ω_K. Thunk = memoized Δ-net nf.

**3-state structure**: conv attempt has three states — Rigid (try spine-compare without unfolding, speculative), Flex (bounded unfold if rigid-spine-match fails), Full (always unfold). Rigid→Flex→Full, one-way. Same-head on rigid side → recurse spine without reading def body → O(1) in number of defs. Head-mismatch on rigid side → force into-net (the unfolded value, memoized). This structure organizes the existing open/closed routing: closed→`ArtifactId` LOCAL fast path; open→lazy `force_whnf` + congruence.

### Q23: QTT erasure before reduction
Quantity-0 = type-only, zero runtime. Erasure commutes with β (McBride/Atkey): `erase(β(t)) = β(erase(t))`. SAFE to erase Q-0 before kernel reduction. dnx: erase annotations → translate erased λK → Ω_K → readback → check.

### Q24: Description universe / levitation (Chapman 2009) — **SUPERSEDED by G4**
Levitation: ONE generic `μ : Desc I → I → Set` + ONE generic eliminator; ι = single rule. Fixed finite net-agent alphabet `{App,Abs,Era,Rep, con, elim, σ,π,rec,ret,plus, μ}` — bounded TCB, no per-datatype rules.
RAW alternative: per-datatype agents = unbounded rule set (bad for net engine).
ORIGINAL RECOMMENDATION: adopt levitation. **DECISION (G4): NOT adopted v1.** Raw Ind/Ctor/Elim chosen because ι fires OUTSIDE Ω_K (no per-datatype net agents needed — the unbounded-rule objection doesn't apply), and description-universe generic-elim bugs have larger blast radius. Levitation revisitable later. Retained here as research record.

**Incremental levitation path (for future reference)**:
- Slice-0: closed code-enum `Desc₀` + type-valued decoder `El₀` (large-elim + one ι) — uses ZERO new kernel machinery; generic algebra type + fold derivable today.
- Slice-1: generic VALUE-level fold over native described data via ONE `Elim` — axiom-free, no new Tm variant. Code↔data coherence as a PROVABLE theorem (not postulated iso).
- Slice-2: faithful self-describing universe `Desc ≅ μ DescD` — requires W-types OR induction-recursion + universe polymorphism (level variables). TCB-expanding; not v1.
Slice-0 and Slice-1 are reachable with current kernel; Slice-2 is gated on features deferred from v1.

### Q25: TCB split — see Part III (φ_K + Ω_K + φ_K⁻¹ + conv + infer/check/positivity/universe). ✅ adopted.

### Q26: δ-reduction into-net vs outside Ω_K — HYBRID (adopted, see Part I §6)
(A) UNFOLD-INTO-NET: body netted ONCE, Rep-duplicated to all sites, β-reduced optimally across all uses — the Lévy-optimal win Coq/Agda/Lean LACK. Con: over-unfold.
(B) UNFOLD-OUTSIDE (glued, Q22): lazy delta, skip if heads match (Lean4/smalltt win). Con: re-nets per unfold.
RESOLUTION: HYBRID. δ-decision (whether) = outside, lazy, glued. δ-mechanism (how) = into-net, Rep-shared. Skip cost like Lean; when paid, pay optimally. `Const` agent = opaque rigid head; unfold = annihilate with body-net via level-0 Rep. Def bodies netted+cached (memoized nf).

### Q27: de Bruijn indices vs levels — boundary concern only
Inside the net: binding is STRUCTURAL (Abs port → use-site wires via Rep/Era). NO names, NO indices, intrinsically α-invariant. Index/level dance dissolves inside Ω_K. Boundaries: φ_K input = indices (elaborator-produced); φ_K⁻¹ readback = levels (assign each Abs depth-from-root); conv α-compare on nets directly = graph iso (needs neither — skips φ_K⁻¹ in hot path). Prefer comparing NETS for α-eq.

### Q28: fourcolor as stress test — see FOURCOLOR section above.

### Q29: Conv bottlenecks in existing kernels
- Coq: lazy OCaml closures but re-evaluates on cache miss. δ-unfolding = #1 bottleneck (`Opaque` hides defs).
- Lean4: lazy delta w/ priority hints. Metavar-heavy elaboration = repeated conv.
- Agda: NbE, no sharing across checks — re-evaluates from scratch.
Optimal reduction addresses β-step count. Does NOT directly address δ-unfolding overhead or metavar resolution.

### Q30: Is impredicative Prop necessary? — NO (informs C2 / R10-drop)
Impredicative Prop = `∀(X:Prop),X→X : Prop`. Coq+Lean4 have it; Agda fully predicative.
- STRICTLY REQUIRED by almost nothing — Agda formalizes vast math predicatively. Predicative + universe poly covers essentially all ordinary math (incl. fourcolor combinatorics).
- BUYS: impredicative encodings (avoidable, use native inductives); proof irrelevance + clean erasure (Lean leans on this); single bottom universe for props.
- DANGER: impredicative Prop + EM + large elim = INCONSISTENT (needs singleton-elim restriction → kernel complexity + soundness side-condition).
VERDICT for dnx: NOT necessary for soundness or fourcolor-class target. Predicative + universe poly = sufficient + SIMPLER. Ship predicative first. Add impredicative Prop later ONLY if proof-irrelevance erasure worth the complexity; pairs naturally with QTT quantity-0 erasure (most of Prop's erasure benefit WITHOUT impredicativity).

### Q18-supplement: IC agents (optimal reduction)
6 agents: VAR, ERA, LAM, APP, SUP (`&L{a,b}`), DUP (`!&L{x,y}=t;body`). LABELS `L` control annihilate-vs-commute — SAME mechanism as Δ-net replicator levels. Confirms Rep-labeling is the standard optimal-reduction device, not paper-specific.

### Q31: Proof-carrying values

A proved value = closed term `(v, pf) : Σ(x:A). P(x)` — a dependent pair where `pf : P[x:=v]` is kernel-checked. The type-checker verifies `pf` proves `P` of that specific `v`.

`Sigma` is NOT primitive (not in `Tm` grammar, by G4 design). Derivable as a user inductive: single constructor `mkSigma (a:A)(p:P a)`. `fst`/`snd` = its `Elim`; extraction via ι-reduction. Kernel-checks the proof at `check` time; emits nothing if proof fails.

Universe: `Sigma : Sort(max(i,j))` where `A : Sort i`, `P : Sort j` (R11 gate: ctor field sort ≤ decl sort).

Pattern: `extract_value = Elim Sigma … (mkSigma a p → a)`. `extract_proof = Elim Sigma … (mkSigma a p → p)`.

Non-indexed Σ works today. Indexed variant (proof component is an indexed family) requires the indexed-family ι path (A6 gap).

### Q-impl: IC-based type theory (CoC-ish variant)
Reduces directly via interaction net (def-eq = normalize both + compare, NOT separate NbE). CoC-ish w/ self-types (λ-encoded inductives, Cedille-lineage, NOT native CIC). NO ι primitive — eliminators are just β. The "everything via β on erased terms" extreme; pays with no native recursors / no proof-irrelevance. dnx w/ raw-Ind ι is a middle path: native ι, OUTSIDE Ω_K.

## FROM SETTLED DOCS

### C-RULES: C1=mark-sweep, C2=rep-merge, C3=rep-decay, C4=aux-fan-rep
- `force_whnf` does NOT run C4 — stays `Net<Proper>`. Only `normalize` → `Net<Canonical>`.
- Proof kernel: `force_whnf` for WHNF steps during type checking. `normalize` for full conv.

### CONV FOR CLOSED TERMS = `ArtifactId` LOCAL-eq (intern, NOT hash) — UNIFIED 2026-06-04
- `Net<Canonical>` = deterministic root-DFS `serialize` → `intern` → `ArtifactId` LOCAL rep (u64). Two β-equal closed terms → same LOCAL id = conv. **Structural-exact**: intern bytes = ground-truth, hash only buckets → no collision in TCB. (This LOCAL rep is the mechanism formerly named `CanonId`.)
- The WIRE rep `BLAKE3(serialize)` of the SAME `ArtifactId` is **distribution-only** (collision = dedup miss, NOT unsoundness) — never the conv decision. One id, two views.
- Open terms (free vars) → `ValueHead::Stuck` → lazy force_whnf + structural congruence (don't full-normalize).

### LOPATH ANTICHAIN = PARALLEL TYPE CHECKING
- Prefix-independent pairs fire simultaneously, zero sync. Independent Pi sub-terms = independent LOPath regions. Check `A≡A'` and `B≡B'` simultaneously via `parallel.rs`.

### REPLICATOR ARITY ≤ 2
- k-ary sharing = binary rep tree, depth ⌈log₂ k⌉. Pi-body using var k times = binary rep tree.

### ARTIFACTID = THE CONTENT IDENTITY (proofs, defs, all) — UNIFIED 2026-06-04
- `ArtifactId` = the `serialize` bytes; WIRE rep = `BLAKE3(serialize)`, LOCAL rep = `intern(serialize)`; `effect_row` = derived metadata, NOT in identity. Pure proof = empty row → id = the bytes alone. Dedup identical proofs for free (by WIRE rep).
- Kernel defs `Const`/`Ind`/`Ctor`/`Elim` content-addressed by `ArtifactId` (§1); `GlobalEnv` keyed by `ArtifactId` (§6); names = metadata→`ArtifactId`.

### PASS1 USAGE LEVELS → TYPE ERASURE HOOK
- Pass1 sets ΔL/ΔA/ΔI/ΔK per-variable usage. Proof kernel: Q-0 vars → erasers, non-Q-0 → full ΔK.

## PENDING (NotebookLM — daily limit hit, retry later)

Parts 1+2 of note.md = ONLY notebook can answer (dnx design docs):
- Q1-8: parallelism gates
- Q9-14: proof kernel design in dnx settled docs

Q25-28 answered as RECOMMENDATIONS (adopted in Parts I–II) — still want Vic design-session sign-off.

═══════════════════════════════════════════════════════════════════════════════
**SETTLED ✅ 2026-06-02. This file is the SSOT, merged from kernel-spec.md + proofs.md. Coding can begin.**
