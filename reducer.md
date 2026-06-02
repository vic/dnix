# δ-lang: Reducer Design — SETTLED

## Fundamental Distinction

**Interaction rules R1-R7**: principal⊗principal rewrites. Embarrassingly parallel.
Disjoint LO prefixes → disjoint write sets → fire simultaneously, zero synchronization.

**Canonicalization rules C1-C4**: NOT interaction rules. Network-state maintenance.
C1: global traversal (single-threaded, once at end).
C2/C3: lazy pre-checks on unpaired reps, applied immediately before R3/R5/R6/R7/C4.
C4: Phase2 exclusive; fires on (rep.principal ↔ app.aux0) — NOT a principal⊗principal pair.

**Correctness source**: main.tex §2 (interaction rules R1-R7; perfect confluence of core), §3 (φ_K translation; δ-formula d_i=l_i−(l+1)), §4 (two-phase reduction; LO optimality; C2/C3/C4; Church-Rosser).
Optimality = LO order + lazy C2/C3 (§4).
Confluence = Church-Rosser via C4 accumulation + C1 final sweep (§4).

---

## Two Frontiers


**Invariant**: `frontier1` holds ONLY principal⊗principal pairs.
`frontier2` holds ONLY rep.principal↔app.aux0 connections (C4 trigger).

---

## Normalize Entry Point

**NetClass gating**: `net.net_flags bits[1..0]` (set by elaborator Pass 1) determines which C-rule families
are structurally possible. Checked once at normalize entry; inner loops skip entire families.

| `net.class` | dispatch_phase1 | Phase 2 (C4) | C1 |
|---|---|---|---|
| L (0b00) | R4 only | skipped (frontier2 empty by construction) | skipped |
| A (0b01) | R4 + R2 | skipped (no reps → frontier2 empty) | `pending_c1` |
| I (0b10) | R4-R7 + C2 pre-check | C2 pre-check + C4 | skipped (no erasers) |
| K (0b11) | R4-R7 + C3+C2 pre-check | C3+C2 pre-check + C4 | `pending_c1` |

```
// Generic over C: C-rule dispatch gated by C type + net_flags fast-path.
// ΔL: no C-rules (proven by type). ΔI: only C2+C4. ΔA: only C1. ΔK: all.
pub fn normalize<C: NetClassMarker>(net: Net<Proper, C>) -> Net<Canonical, C> {
    let has_rep = net.net_flags & 0b10 != 0;  // mirrors C; kept for branch-free dispatch
    let has_era = net.net_flags & 0b01 != 0;

    // Phase 1: R1-R7 + lazy C2/C3 (C3 only when has_era AND has_rep; C2 only when has_rep)
    while let Some(pair) = net.frontier1.pop_lo_min() {
        if stale(pair, net) { continue; }
        dispatch_phase1(net, pair);
    }

    // Phase 2: C4 only — frontier2 non-empty only when has_rep
    if has_rep {
        while let Some(c4) = net.frontier2.pop_lo_min() {
            if stale(c4, net) { continue; }
            if has_era { c3_rep_decay(net, c4.rep_principal, c4.lo); }  // C3 only if erasers exist
            c2_rep_merge(net, c4.rep_principal, c4.lo);
            c4_aux_fan_replication(net, c4);
        }
    }

    // Final: C1 — only A/K nets; pending_c1 is exact runtime guard (never true for L/I)
    if net.net_flags & 0x04 != 0 {  // net_pending_c1: eraser placed on aux at runtime
        c1_mark_sweep(net);
    }

    let w = certify_canonical(net)?;   // private witness, produced only when Ω-conditions hold
    net.into_canonical(w)              // pub(crate): typestate transition
}
```

**Phase switch**: frontier1 exhaustion triggers Phase2. Phase A (sequential): no epoch sync needed.
Phase C (parallel): Phase1→Phase2 switch is automatic (coordinator observes empty frontier1).
BUT Phase2→C1: requires `request_quiescent_epoch()` before `c1_mark_sweep()` — blocks until all workers
at `leave_epoch()`. C1 is a non-local BFS mutation; no concurrent Phase2 workers can be active. (woot.md)
Parallel: `pop_lo_min()` extracts prefix-independent batch; workers fire rules independently;
push new pairs back to frontiers; coordinator merges.

**Phase2 termination**: each C4 firing either eliminates an App fan (sub-case A) or moves a RepIn
one position closer to its paired Abs fan (sub-case B: rep lifts above app, reducing the
rep-to-Abs distance by 1). Decreasing measure = Σ(distance from each RepIn to paired Abs).
This is bounded by net size after Phase1. Phase2 terminates in O(n) C4 firings ≤ net size.
Main.tex §4: "all fan-in replicators accumulate at the variable port of abstraction fans." ✓

---

## Demand-Driven WHNF Forcing (Lazy Evaluation) — SETTLED

**The runtime is LAZY. It never eagerly runs `Ω_S` full-normalize on the whole program.**
Evaluation is driven by *demand*: a port is forced to WHNF only when its value is observed.
This is what makes dnx a call-by-need (lazy) evaluator — see nixprim.nix §Laziness, nix.md.

### value-heads (WHNF stop condition)
A port `p` is in **WHNF** when the agent at its head (follow wires/principal toward the value)
is a *value-head*:
- `PrimVal` (Int/Float/Str/Path/Null) — opaque literal.
- `FanAbs` (lambda) — a function; Church-encoded bools are FanAbs too (true=λt.λe.t, false=λt.λe.e).
- a Nix data constructor held in a `PrimVal`: `List` / `AttrSet` (whose elements are lazy `Term`s).

`is_value_head(agent)` = `is_prim(tag) || (is_fan(tag) && fan_is_abs(tag))`. O(1) on the slot tag.

### demand spine
The **demand spine** of `p` = the chain of agents from `p` following principal-port connections
toward the value being produced. An active pair (redex) is *demanded by p* iff it lies on p's spine
(its result feeds p). Off-spine subnets (list tails, unused args, untaken `if` branches) are NOT on
any forced spine → never reduced → lazy.

### force_whnf
`lo_min_redex_on_spine(p)` = the frontier1 entry with smallest LOPath among those on p's spine.
Because the frontier is `BTreeMap<LOPath,_>` (LO order), and the spine of the program root is the
whole frontier, `force_whnf(root)` simply drains frontier1 in LO order until the root head is a value.
Forcing an *inner* port (e.g. a list element's `Term`) restricts to that subtree's LO sub-order.

**Source of truth = the WIRE TOPOLOGY, not the frontier map.** The on-spine head redex is found
by following principal-port wires from `p` (`head_agent`), tracking the demand path (aux0→left,
aux1→right). The frontier map is a fast index keyed by LOPath; if a reduction rule forms a
principal-principal pair whose LOPath key collides (a sibling at the same path overwrites it in the
BTreeMap), that pair is missing from the index but is still the structural demand head and MUST fire
(its path is reconstructed from the descent). This keeps the SEQUENTIAL lazy walker reachable-complete:
it surfaces the demanded value (so a scalar result short-circuits before any non-spine drain) while
off-spine subnets — discarded `if` branches, unused args, the unused-self knot of a discarded
recursion — are never on the walked spine, never fire, stay lazy (§soundness perfect-confluence). The
antichain invariant constrains only the PARALLEL batch extractor (`pop_lo_min`), not this walker.

**OPEN DEFECT (CP0 genuine-recursion, 2026-06-04i — Vic-core-driver-reserved).** An active pair
requires BOTH endpoints to be PRINCIPAL ports (main.tex §2 interaction defn). `take_spine_redex`
(whnf.rs) breaks the descent as soon as the *peer* `q` is a principal, WITHOUT checking that the
current endpoint `cur` is also principal. When the walk is ENTERED at an aux port — the prim
arg-force enters at `App.aux1` (the arg consumer wire, mod.rs step_with_prims) — iteration 1 has
`cur = App.aux1` (aux) peering `q = producer.principal`, so it mis-breaks on that single
consumer→producer wire and never descends INTO the producer to reach its principal-interaction.
For genuine recursion (literal-Y), `n`'s producing wire holds an EQUAL-LEVEL `REP_OUT(0x0b) ⊗
REP_IN(0x0a)` pair (R6-annihilate) that this early-break skips → `n` is delivered with a REP_OUT
head (not a value). PROVEN firsthand (ELAB_REP/RR/ARGFORCE/STUCK traces, diag-bug2 §resolution):
self-app rep levels are paper-EXACT (main.tex:820 off-by-one is MANDATED — NOT the bug); the defect
is the walker dropping an on-spine equal-level R6 pair. Candidate fix: when entered at an aux whose
peer is a principal, descend into the producer (continue the walk) instead of breaking; only break
when BOTH `cur` and `q` are principal. Scope = Vic (touches the 5×-escalated demand walker).

### force_deep (NF / deepSeq / hashing)

### soundness (paper)
- **LO = normal order** (§4): forcing the LO spine reaches WHNF iff a WHNF exists (head normalization).
- **Perfect confluence** (§2): the WHNF is unique regardless of which *off-spine* redexes are or aren't
  reduced → lazy and eager agree on the value, differing only on whether divergent/erroring off-spine
  parts are touched. Lazy touches none → matches Nix call-by-need exactly.
- **Optimality** (§4): no redex is fired that the WHNF does not need.
- **Sharing = call-by-NEED**: a forced thunk's WHNF is left in place (slot mutated); `rep`-shared thunks
  force once (a single RepIn feeds all uses). Not call-by-name (no re-forcing).

### relationship to Ω_S
`Ω_S` full-normalize ≡ `force_deep(root)`. The reducer KEEPS `Ω_S`/`normalize()` (used by canonical
hashing + artifact export, which need NF). But the **Nix runtime drives evaluation with `force_whnf`
on demand, never `Ω_S`.** `into_canonical` is reached only when the caller actually wants full NF.

### prims under demand
A saturated `PrimFun` fires only when its result is demanded (its principal is on a forced spine).
Each prim forces its arguments to the depth it needs, then computes:
- arithmetic (`add`,`sub`,…): force operands to WHNF (PrimVal), compute.
- structural (`eq`, `<` on data): `force_deep` the operands.
- `seq` = `force_whnf(arg0)`; `deepSeq` = `force_deep(arg0)`.
- `if`/`&&`/`||` are NOT prims — Church-bool native application; branch laziness is automatic
  (the untaken branch is the eraser-connected aux of the bool's abstraction → never on a spine).
- A prim result may be a `PrimVal`, a `PrimFun` (partial), or a **net fragment** (e.g. comparison
  prims emit a Church-bool subnet; `fromJSON` emits a List/AttrSet PrimVal). See primitives.md.

---

## Two-phase discipline invariants

**Phase switch is ONE-WAY**: Phase-1 (R1–R7 + lazy C2/C3) exhausts before Phase-2 (C4 + epoch sync) begins. Once C4 fires, R5 must NOT re-enter. Demand path that oscillates (drain-phase2→continue→R5 re-fires) violates this; adds unnecessary R5 steps and risks pairing-invariant violations.

**C3 decay requires UNPAIRED rep**: Wire-through decay (rep with one aux erased, delta==0) is scoped to UNPAIRED reps only (paper §4). Applying C3 to a paired rep breaks the pairing invariant. C3 gate must check `rep_is_unpaired()` before wire-through.

**Polarity guard on ALL principal pairs**: Every principal⊗principal dispatch must verify opposite polarity (child port ↔ parent port). The demand path has this guard; the batch normalize path must have it too. Same-polarity principal wires are illegal at the interaction level.

**Off-spine blind drain**: `normalize_demand` must not fire active pairs in subnets already flagged for erasure (C1 reachable = not yet erased but eraser-reachable). Reducing a discarded subnet wastes interactions and may corrupt the eraser graph.

**Rep self-loop guard in R5**: When a fan meets a rep (R5 fan⊗rep), if the rep's aux0 loops back to its own principal (a self-loop rep), normal R5 wiring creates a cycle. Self-loop reps require a separate case: produce an erased copy rather than a wired copy.

---

## Phase1 Dispatcher


---

## R1: Era ⊗ Era

**Trigger**: both ports have eraser_bit set.
**Action**: nothing — virtual erasers, no slots. Neither agent has a Slot.
**New pairs**: none.

```
r1_era_era: retire nothing (virtual). emit nothing.
```

---

## R2: Era ⊗ Fan

**Trigger**: eraser_bit port ↔ Fan.principal.
**Action**:
1. Set eraser_bit on both fan.aux0 and fan.aux1 (virtual erasers on external peers)
2. Retire fan Slot
3. External peers of aux0/aux1: emit new ActivePairs if those peers are principal ports


**LO suffix**: `extend_left()` for aux0 peer, `extend_right()` for aux1 peer.

---

## R3: Era ⊗ Rep

**Pre**: `c3_rep_decay(net, rep)` — may simplify rep first.
**Action**:
1. Place erasers on all rep aux port peers
2. Retire rep Slot
3. Emit active pairs for each erased aux peer (if principal)


---

## R4: Fan ⊗ Fan (β-reduction)

**Trigger**: Abs.principal ↔ App.principal.
**Action**: cross-wire aux ports. Both fans retired. No new allocs.

```
abs.aux0 (body)  ↔  app.aux0 (result)   → wire these two peers together
abs.aux1 (var)   ↔  app.aux1 (arg)       → wire these two peers together
```


**Orientation note**: main.tex TikZ shows R4 as visual cross-wire (fan1.left↔fan2.right).
This is same-index (aux0↔aux0) because the two fans face opposite directions (abs points UP, app points DOWN), making their "left" port labels visually swap. In our port labeling: Abs.left=aux1(var), Abs.right=aux0(body); App.left=aux0(result), App.right=aux1(arg). Cross-wire fan1.left↔fan2.right = App.aux0(result)↔Abs.aux0(body) = same index ✓.

**Optimality note**: β-reduction = R4 only. LO order ensures no redundant R4s.
If rep_a (unpaired) would need to commute past a fan before the fan reaches LO position,
C2 merges rep_a first — the fan never has to replicate it unnecessarily.

---

## R5: Fan ⊗ Rep (commutation)

**Pre**: `c3_rep_decay`, `c2_rep_merge` on rep first.
**Trigger**: Fan.principal ↔ Rep.principal.
**Allocates**: 2 new Fans (same kind as original: Abs→Abs, App→App) + 2 new Reps.
**PairedStatus of new reps**: **Unknown** (both).

**RepIn/RepOut assignment** (depends on fan.aux0 port direction):
- `new_rep_a`: principal→peer(fan.aux0); kind = RepIn if fan.aux0 is child port, else RepOut
- `new_rep_b`: principal→peer(fan.aux1); kind = RepIn if fan.aux1 is child port, else RepOut
  - Abs: aux0=child(body)→new_rep_a=RepIn; aux1=parent(var)→new_rep_b=RepOut
  - App: aux0=parent(result)→new_rep_a=RepOut; aux1=child(arg)→new_rep_b=RepIn

```
Original:
  fan.aux0 → ext_a (external)   [fan.aux0 direction determines new_rep_a kind]
  fan.aux1 → ext_b (external)   [fan.aux1 direction determines new_rep_b kind]
  rep.aux0 → ext_c (external)
  rep.aux1 → ext_d (external)

New agents:
  new_fan0:  kind=fan.kind   principal→ext_c   aux0→new_rep_a.aux0   aux1→new_rep_b.aux0
  new_fan1:  kind=fan.kind   principal→ext_d   aux0→new_rep_a.aux1   aux1→new_rep_b.aux1
  new_rep_a: kind=RepIn|Out (per fan.aux0 direction)
             level=rep.level  delta0=rep.delta0  delta1=rep.delta1
             principal→ext_a   aux0→new_fan0.aux0   aux1→new_fan1.aux0
  new_rep_b: kind=RepIn|Out (per fan.aux1 direction)
             level=rep.level  delta0=rep.delta0  delta1=rep.delta1
             principal→ext_b   aux0→new_fan0.aux1   aux1→new_fan1.aux1
```

**Naming alias** (used in rest of doc): new_rep_in = new_rep_a when fan is Abs (most common case).

**LOPath suffix table** (per new agent from redex LO `P`):
```
new_fan0:    P ++ 0b00
new_fan1:    P ++ 0b01
new_rep_in:  P ++ 0b10
new_rep_out: P ++ 0b11
```

**New active pairs emitted**:
- Boundary: (new_rep_in.principal, ext_a_peer) if ext_a_peer is principal
- Boundary: (new_rep_out.principal, ext_b_peer) if ext_b_peer is principal
- Inner: new_fan0 ↔ new_rep_in (at aux0), new_fan0 ↔ new_rep_out (at aux1), etc.
  — inner wires between new_fan and new_rep are NOT active pairs (aux ports, not principal⊗principal)
- Check ext_c/ext_d peers vs new_fan0/new_fan1 principals: emit if principal⊗principal

**C4 check**: after R5, if new_rep_in.principal connects to an app_fan.aux0
→ emit C4Candidate to `frontier2` (NOT frontier1).

---

## R6: Rep ⊗ Rep Annihilation (same level AND same deltas)

**Pre**: `c3_rep_decay`, `c2_rep_merge` on both.
**Action**: cross-wire SAME-INDEX aux ports. Both retired. No new allocs.

**Equality check** (main.tex §2 L787 + native net correctness):
Paper: for φ_K nets, same level → same deltas guaranteed by construction.
Native δ-lang nets (killer feature): can produce same-level reps with different deltas
after R7 (e.g. A(lvl=2,d=(-1,0)) and B(lvl=2,d=(0,0)) from different sharing scopes).
Level-only check would incorrectly annihilate them.

**Triple equality required**: fire R6 only when `l_a == l_b AND d0_a == d0_b AND d1_a == d1_b`.
Cost: 2 extra i16 comparisons per R6 check. Correctness > micro-optimisation.

```
rep_a.aux0 peer  ↔  rep_b.aux0 peer   (wire directly)
rep_a.aux1 peer  ↔  rep_b.aux1 peer
```


---

## R7: Rep ⊗ Rep Commutation (different levels, l_lo < l_hi)

**Pre**: `c3_rep_decay`, `c2_rep_merge` on both.
**Allocates**: 4 new Reps (2 copies of `hi`, 2 copies of `lo`).
**PairedStatus**: each copy inherits parent's PairedStatus.

```
Orient: lower.level < higher.level

New agents:
  hi_copy_0: level = hi.level + lo.delta0  (checked_add → DeltaOverflow)
             delta0=hi.delta0  delta1=hi.delta1
             kind=hi.kind  paired=hi.paired
             principal → peer(lo.aux0)     [external]
             aux0 → lo_copy_0.aux0
             aux1 → lo_copy_1.aux0

  hi_copy_1: level = hi.level + lo.delta1  (checked_add → DeltaOverflow)
             delta0=hi.delta0  delta1=hi.delta1
             kind=hi.kind  paired=hi.paired
             principal → peer(lo.aux1)     [external]
             aux0 → lo_copy_0.aux1
             aux1 → lo_copy_1.aux1

  lo_copy_0: level = lo.level
             delta0=lo.delta0  delta1=lo.delta1
             kind=lo.kind  paired=lo.paired
             principal → peer(hi.aux0)     [external]
             aux0 → hi_copy_0.aux0
             aux1 → hi_copy_0.aux1

  lo_copy_1: level = lo.level
             delta0=lo.delta0  delta1=lo.delta1
             kind=lo.kind  paired=lo.paired
             principal → peer(hi.aux1)     [external]
             aux0 → hi_copy_1.aux0
             aux1 → hi_copy_1.aux1
```

**LOPath suffix table**:
```
hi_copy_0: P ++ 0b00
hi_copy_1: P ++ 0b01
lo_copy_0: P ++ 0b10
lo_copy_1: P ++ 0b11
```

**New active pairs**: boundary pairs at external connections + C4 checks on all new rep principals.

**Delta overflow**: `hi.level as i32 + lo.delta_i as i32` checked; Err(DeltaOverflow) if outside `u32` range.

**Non-negativity of hi_copy levels** (native δ-lang nets with negative deltas):
Proof: R7 requires lo.level < hi.level → hi.level - lo.level ≥ 1.
lo.delta_i = usage_level_i - lo.level (from elaboration, usage_level_i ≥ 0).
hi_copy.level = hi.level + lo.delta_i = (hi.level - lo.level) + usage_level_i ≥ 1 + 0 = 1 ≥ 0. ✓
DeltaOverflow handles the u32 range check (hi.level as i32 + lo.delta_i as i32 negative = outside u32 = error,
but proof above shows this can't happen for valid δ-lang programs).

---

## C2: Unpaired Rep Merge (Lazy)

**When applied**: immediately before R3, R5, R6, R7, C4 on any Unpaired rep.

**Condition** (fixed n=2):
```
rep_a: PairedStatus=Unpaired, has aux_i → rep_b.principal
       other aux_j: has eraser_bit (C3 must have already run)
Constraint: 0 ≤ rep_b.level - rep_a.level ≤ rep_a.delta_i
```

**Action**:
1. Wire rep_b.principal to peer(rep_a.principal)
2. Adjust rep_b's deltas: new_rep_b.delta_k += (rep_b.level - rep_a.level) for each k
   Actually: rep_b.level becomes rep_a.level; deltas adjusted to preserve absolute target levels:
   `new_delta_k = rep_b.delta_k + (rep_b.level - rep_a.level)`
3. rep_b.level = rep_a.level
4. Retire rep_a


> **2026-06-04 NOTE — C2 vs paper L1068, and why it does NOT fix Y-net recursion.**
> Paper L1068 has NO `other-erased` requirement (A unpaired + A.aux_i→B.principal +
> `0≤l_B−l_A≤d` suffices, and B is then DETERMINED unpaired → set B.status=Unpaired so
> the merge cascades). The `other-erased` narrowing above + the missing B-unpaired
> determination diverge from the paper. HOWEVER, generalizing C2 to the paper rule was
> tried 2026-06-04 and (a) FIRES 0× on the diverging fix-nets and (b) REGRESSES
> `gpu_church_lo_optimality` (church4 r4_count 4≠6) — so it was REVERTED; the narrow
> rule above is what ships. Instrumented proof the merge is inapplicable: in the
> diverging fix-nets the UNPAIRED replicator is ALWAYS a tree CHILD (its principal
> connects UP to an UNKNOWN parent's aux); it is NEVER a tree parent, and its own aux
> ports connect only to FANs and REP_OUTs — never to a consecutive REP_IN principal.
> So C2's precondition (A=unpaired PARENT, A.aux→B.principal) has ZERO opportunities
> (0 unpaired-parent over 2489 rep-tree edges in countdown-3; status is lost at the
> FIRST R5 unpaired⊗fan→unknown before any rep-rep tree forms). The divergence is an
> UNPAIRED fan-in climbing via R7 against REP_OUTs at level N (itself at N+1), never
> reaching equal level for R6 annihilation. Root is the fix Y-net's collapse/sharing
> when the body operates on its bound var (smaller repro: `(fix(self:n:if n==0 then 9
> else 8)) 3` diverges with self UNUSED, but `(fix(self:n:n)) 3`→3 and the same body
> without fix→8), NOT a missing C2 merge, NOT levels.
> 2026-06-04 + memory recursion-applied-fix-diverge. Whether to relax C2 to the paper
> rule (and fix the gpu-optimality interaction separately) is a Vic core-driver call.

---

## C3: Unpaired Rep Decay (Lazy)

**When applied**: immediately before R3, R5, R6, R7, C4 on any Unpaired rep.
Also called by C1 during mark+sweep on all encountered unpaired reps.

**Cases** (fixed n=2):

```
Case A: both aux erased
  → place eraser on peer(rep.principal); retire rep

Case B: aux_i erased, aux_j NOT erased
  sub-case B1: delta_j == 0 (single remaining aux has zero delta)
    → wire peer(rep.principal) directly to peer(aux_j); retire rep
  sub-case B2: delta_j != 0
    → leave eraser_bit on aux_i; rep survives with erased aux_i
    (do nothing — already minimal)

Case C: neither aux erased → no-op
```


---

## C4: Aux Fan Replication (Phase 2 Only)

**Trigger**: `rep.principal ↔ app_fan.aux0` (non-principal connection → NOT in frontier1).
**Detected**: when any rule wires a rep.principal to an app_fan.aux0 → emit to `frontier2`.

**Two sub-cases**:

### Sub-case A: app.aux0 has eraser_bit

```
rep.principal → erased app.aux0
→ erase peer(app.principal) + peer(app.aux1)
→ retire app fan
→ rep.principal now connects to erased principal peer
```

**Phase2 invariant**: peer(app.principal) = ext_up is ALWAYS an AUX port of a containing agent
(or a free output slot) — never a bare principal port. Reason: if ext_up were a principal forming
a principal⊗principal active pair, Phase1 would have already reduced it (Phase1 exhausts frontier1
before Phase2 begins). Therefore erasing ext_up = inert eraser on AUX port; NO new frontier1
entries created by sub-case A. Same logic applies to ext_arg = peer(app.aux1).

### Sub-case B: Full aux fan replication (main.tex Fig.ipsi)

```
Before:
  rep(level=l, d0, d1).principal ↔ app_fan.aux0
  rep.aux0 → ext_c
  rep.aux1 → ext_d
  app_fan.principal → ext_up  (result going up)
  app_fan.aux1 → ext_arg     (arg going down)

After: (produces paper Fig.ipsi result)
  new_rep_0: level=l, d0=d0, d1=d1
             principal → ext_up
             aux0 → new_app_fan_0.principal
             aux1 → new_app_fan_1.principal

  new_app_fan_0: principal → new_rep_0.aux0
                 aux0 → ext_c (goes to rep's old aux0 external)
                 aux1 → ext_arg (replicates arg connection)

  new_app_fan_1: principal → new_rep_0.aux1
                 aux0 → ext_d (goes to rep's old aux1 external)
                 aux1 → [new aux fan replication of ext_arg... see below]
```

Actually C4 in full generality is: the rep "lifts" above the app fan, consuming the app fan
and replicating it once per rep aux port. With fixed n=2:

```
Result:
  new_rep (at app.principal position):
    level=l, d0, d1
    principal → ext_up
    aux0 → new_app0.principal
    aux1 → new_app1.principal

  new_app0: (App copy)
    principal → new_rep.aux0
    aux0 → ext_c           ← rep old aux0 external
    aux1 → ext_arg_copy_0  ← ext_arg replicated (new RepOut needed for ext_arg)

  new_app1: (App copy)
    principal → new_rep.aux1
    aux0 → ext_d           ← rep old aux1 external
    aux1 → ext_arg_copy_1
```

Replicating ext_arg requires a new RepOut(level=l, d0=0, d1=0) at ext_arg's position
if ext_arg is shared. (The sharing of arg across replicated apps = standard commutation.)

**LOPath suffix table** (C4Candidate has `lo = P`):

Derivation: C4 = rotate(app: aux0→principal) + R5-commute(rotated_app, rep) + unrotate(result fans).
R5 suffix table applied to rotated config — rotated_app.aux0=ext_up, rotated_app.aux1=ext_arg,
rep.aux0=ext_c, rep.aux1=ext_d — gives new_fan0/new_fan1/new_rep_a/new_rep_b at P.0b00–0b11.
After unrotate (new_fan0→new_app0, new_fan1→new_app1, new_rep_a→new_rep, new_rep_b→new_repout):

```
Agent        lo              Boundary connection
new_app0     P ++ 0b00       new_app0.aux0 ↔ ext_c   (rep's old aux0 external)
new_app1     P ++ 0b01       new_app1.aux0 ↔ ext_d   (rep's old aux1 external)
new_rep      P ++ 0b10       new_rep.principal ↔ ext_up   (app's principal external)
new_repout   P ++ 0b11       new_repout.principal ↔ ext_arg   (app's aux1 external)
```

Inner wires (rep.aux0↔app0.principal, rep.aux1↔app1.principal, app0.aux1↔repout.aux0,
app1.aux1↔repout.aux1) — never active pairs; passed nearest ancestor's suffix lo in connect().

**C4 boundary connect() calls**:

**All wiring goes through `net.connect()`** → `detect_pair()` handles all frontier routing automatically.
No explicit C4 or frontier1 emission in rule bodies — `connect()` is the single detection point.
C4 sub-case B = O(1): rotate app ports (3 field writes) + 1 commute (alloc 2 new agents + 4 wires) + reverse rotate (4 field writes). No traversal.

**C4 sub-case B pair guarantee**: rotate+commute+unrotate produces ONLY new C4-type pairs
(rep.principal ↔ app_fan.aux0) — no R5/R6/R7 principal⊗principal pairs are created in Phase2.
The rotation transforms the app aux0 into position for commute; the reverse rotation restores fan
orientation such that new rep.principals land on new app.aux0 positions, not on principal ports.
Phase2 drains frontier2 exclusively — this guarantee ensures frontier1 remains empty throughout Phase2.


---

## C1: Erasure Canonicalization (Sequential, Final)

**When**: after Phase2 complete. Only if `net.net_flags & 0x04 != 0` (pending_c1 bit).
`pending_c1` is set by `set_eraser_on_port()` whenever an eraser is placed on an AUX port (inert eraser
= possible disconnection). More precise than compile-time `era_used`: only triggers C1 when
disconnection actually occurred at runtime, not merely because `era` appeared in source.

**Optional eager application** (main.tex §4 L977): C1 CAN be applied at any point during reduction
to reclaim disconnected subnets early (trade computation for memory). Specifically, should be applied
after every R4 that erases an Abs fan. Detection: `abs_is_erasing(slot.tag)` — O(1), no PortId load.
Default: apply once at end. Eager mode: call `c1_mark_sweep(net)` after each erasing R4.

**Algorithm**: BFS from all `free_slots` (def roots). Mark reachable via `c1_mark` bit[5] in tag.
Retire unreachable. `c1_mark` cleared by `retire_slot()` so reused slots start clean.
**On each encountered Unpaired rep**: run C3 first.
**Complexity**: O(live agents) — uses `Arena.live_list` (live slot index list maintained on alloc/retire).
C1 never scans the full arena capacity.


Note: `c1_mark` in tag bit[5] replaces the `FixedBitSet` alloc from the old approach.
`retire_slot()` also clears bit[5] on tombstone so reused slots start unmarked.

`Arena.live_list`: `Vec<u32>` maintained by `alloc_slot()` (push) and `retire_slot()` (swap-remove).
Sweep = O(live) not O(arena_capacity). Critical for sparse nets.

---

## PairedStatus Transitions

| Event | Transition |
|-------|-----------|
| `alloc_rep_in` (elaborator) | → **Unpaired** |
| R5 (Fan⊗Rep): new reps created | → **Unknown** (both new reps) |
| R7 (Rep⊗Rep diff levels): copies | → inherit parent's status |
| R6 (Rep⊗Rep same level): annihilate | n/a (both retired) |
| C2/C3 pre-check | only fires on **Unpaired** |
| C4 pre-check | only fires on **Unpaired** (via C3 check first) |

**Unpaired** = this rep was produced directly by elaboration or by copying an Unpaired rep.
It has never interacted with a Fan. It can NEVER be the fan-in of a proper active R5/R6/R7 pair
before being merged (by C2) or decayed (by C3). This is the optimality invariant.

**Unknown** = produced by R5. May or may not be paired. Cannot C2/C3 eagerly.
Determined unpaired only if local constraint (C2) satisfied.

---

## Optimality Guarantee

**Claim**: LO order + lazy C2/C3 = no duplicate β-reductions.

**Proof sketch** (main.tex §4):
1. An unpaired rep (fanin) in LO spine must be merged (C2) before any fan commutation (R5) past it.
2. If C2 is possible, C2 fires BEFORE R5 (lazy pre-check). Rep vanishes. R5 never fires on it.
3. Any R5 that fires uses a paired rep (Unknown). No duplication of that R5's β-reductions.
4. By induction: every R4 fired is necessary (no copy created by avoidable R5 triggers it).
∴ no redundant β-reductions. LO optimality preserved. □

---

## Confluence Guarantee

**Claim**: ΔK-Nets are Church-Rosser confluent.

**Proof sketch** (main.tex §4 Theorem):
1. Phase1 (R1-R7): core is perfectly confluent (§2); independent redexes commute.
2. Phase2 (C4): aux fan replication is deterministic given the C4 candidates.
   All normal ΔK-nets have ALL RepIn.principal→Abs.aux1 (C4 invariant).
   C4 drives the net to this canonical form.
3. C1: mark-sweep is deterministic given the reachable set. Result unique.
4. Combined: Ω_K(φ_K(t)) is the same for any reduction order → Church-Rosser (§4). □

**Paper honesty**: Church-Rosser is ASSERTED in one sentence (main.tex L1087:
"Since all normal Δ-nets are canonical, the Δ-Nets systems are all Church-Rosser confluent.")
No formal proof is given. The "proof sketch" above is implementation-level reasoning,
not a paper proof. Believed correct; remains an open verification task.

---

## Parallelism Model

```
Phase1 parallel:
  coordinator:
    batch = frontier1.drain_independent_batch()  // prefix-independent pairs
    dispatch batch to worker pool (rayon)
  workers (per pair in batch):
    c3/c2 lazy pre-checks (local to rep slots — thread-local if shard-assigned)
    fire rule → alloc new slots from ArenaSegment (per-worker, no atomic alloc)
    emit new ActivePairs / C4Candidates via local queue
  coordinator: merge worker queues → frontier1/frontier2

Phase2 sequential (coordinator only):
  C4 is NOT parallelized — single-threaded on coordinator (cpu.md SETTLED).
  Reason: non-local (touches app.principal chain beyond 2 slots); quiescent epoch required;
  frontier2 modified during iteration; sequential by nature (Σ distance decreases by 1 each step).
  while let Some(c4) = frontier2.pop_lo_min():
    c3/c2 pre-checks on rep; fire c4_aux_fan_replication; may push new C4Candidates to frontier2

C1 sequential:
  single pass over reachable set from roots
  no parallelism (global traversal; all Phase1/Phase2 workers idle)
```

---

## Error Conditions

| Error | Phase | Cause |
|-------|-------|-------|
| `DnxError::DeltaOverflow` | R7, C2 | `hi.level + lo.delta_i` outside u32 |
| `DnxError::StalePair` | Any | `pair.epoch != slot.epoch` (CAS fail) |
| `DnxError::ABAViolation` | Any | `portid.gen_low != slot.gen & 1` |
| `DnxError::LOPathDepthExceeded` | R5/R7 | LO path overflow (> SmallVec capacity) |

---

## REF/Book model for recursion

Alternative to Y-net for expressing recursive definitions. Design:

**Book**: static side-table of named net-definition templates. Frozen after elaboration; acyclic; finite.

**Ref agent**: nullary leaf carrying a definition index. NOT a back-edge in the live net. The live net is always acyclic.

**Expansion (CALL rule)**: when a Ref principal port meets a consumer, splice a fresh copy of the referenced template into the arena. Every splice is finite and acyclic.

**Termination**: when the base case discards the recursive call, the Ref meets an Eraser → VOID (no expansion) → tail recursion in constant space.

**Level base-shift on splice**: rep levels in the template shift by the consumer's base level on copy. Deltas (level differences) stay invariant across the shift, preserving replicator annihilation conditions.

**Why this avoids Y-net pathology**: Y-net creates self-cloning rep topology → off-by-one level meeting → R7 commute instead of R6 annihilate → reps proliferate. REF removes self-cloning entirely (recursive call = single inert Ref leaf, never a rep tree). Sibling-tree / off-by-one level topology cannot form. Live net remains acyclic by construction.

---

## Settled — Do Not Revisit

- LAZY runtime: eval driven by `force_whnf` (demand-driven WHNF; reduces ONLY p's LO demand spine), NOT Ω_S full-normalize. `force_deep`=NF, used ONLY for output/hash/deepSeq. value-head = PrimVal|PrimFun|FanAbs (List/AttrSet=PrimVal). Sound via LO=normal-order + perfect confluence + optimality (= Nix call-by-need). Ω_S/normalize() retained for hashing/artifact export only.
- R1-R7 = interaction rules (principal⊗principal); embarrassingly parallel
- C1-C4 = NOT interaction rules; network-state maintenance; different semantics
- C1: global mark-sweep; single-threaded; once at end; O(reachable)
- C2/C3: lazy; applied immediately before R3/R5/R6/R7/C4 on Unpaired reps only
- C4: Phase2 exclusive; trigger = rep.principal↔app.aux0 (non-principal pair → frontier2); SEQUENTIAL on coordinator (non-local; quiescent required; frontier2 modified during iteration) — NOT parallelized
- Two frontiers: frontier1 (R1-R7 active pairs) + frontier2 (C4 candidates); separate
- Phase switch: frontier1 empty → Phase2 begins; no epoch sync required
- Phase2 end: frontier2 empty → C1 (if era_used/pending_c1) → `certify_canonical()` → `into_canonical(witness)`
- era_used=false (ΔI programs) → C1 skipped entirely
- R4 (Fan⊗Fan): cross-wire aux ports; both retired; no alloc; β-reduction
- R5 (Fan⊗Rep): 2 new Fans + 2 new Reps; new Reps PairedStatus=Unknown; fixed n=2
- R6 (Rep⊗Rep same level): cross-wire same-index aux; both retired; no alloc
- R7 (Rep⊗Rep diff levels): 4 new Reps; hi copies get level=hi.level+lo.delta_i (checked_add); lo copies keep level; inherit parent PairedStatus
- R7 delta overflow → DnxError::DeltaOverflow (checked_add on i32 intermediate)
- PairedStatus: Unpaired (elaboration/Unpaired copy) → Unknown (after R5); R7 inherits
- Optimality: LO + lazy C2 = no duplicate β-reductions (Unpaired reps merged before R5) [main.tex §4: "no unnecessary reduction steps"]
- Optimality scope: "interaction_count == β_count" holds ONLY for ΔL (R4 is only rule). For ΔK: R4_count == β_count, but total interactions > β_count (R5-R7 + C-rules add overhead). Paper never states step_count==β_count for ΔK.
- Completeness: LO order REQUIRED for completeness in ΔK-nets (not just optimality) [main.tex §4 L1081: ASSERTED, not proved — "critical to ensure normalizing λ-terms normalize"]
- Confluence: Church-Rosser [main.tex L1087: ASSERTED in 1 sentence, no proof]
- Non-canonical rep positions: different proper nets for same λ-term → same canonical form — implied by Church-Rosser, therefore also ASSERTED not proved
- All three above (Church-Rosser, completeness, non-canonical equivalence): believed correct, open formal verification
- Net<Canonical> has NO RepOut agents: Phase2 exhausts all C4 candidates; any RepOut after normalize() = bug
- Complexity (main.tex §4): n=2 fixed aux ports → total agents = effective SPACE complexity measure; total interactions = effective TIME complexity measure
- Old systems (GAL92/Lamping): Ω(2^n) delimiter interactions for n β-reductions. Δ-nets: constant memory for (λx.xx)(λy.yy); replicator consolidates delimiter info [main.tex §1]
- C2 constraint: 0 ≤ l_B - l_A ≤ delta_i (connecting aux delta); main.tex §4 exact formula; fixed n=2 = one real aux required
- C3 fixed n=2: both erased→era on principal; one erased delta=0→wire; else no-op
- C4 sub-case A: erased aux0 → erase principal+aux1 peers; retire app
- C4 sub-case B: full aux fan replication; new RepOut for arg sharing; may emit new C4 candidates
- Parallel: prefix-independent batch extraction; per-worker ArenaSegment; no cross-worker sync during rule firing
- C4 quiescence: batch isolation guarantees no overlapping writes between C4 firings in same batch
- Phase2 loop: C3+C2 applied before EACH C4 firing (not just Phase1); critical correctness invariant
- R5 new fans: inherit SAME kind as original (Abs→Abs, App→App)
- R5 RepIn/RepOut: determined by fan.aux_i port direction (child→RepIn, parent→RepOut); NOT fixed to aux0=RepIn
- R6 equality check: TRIPLE (level, delta0, delta1) — level-only insufficient for native nets (same-level different-delta reps possible after R7 with negative deltas); paper §2 level-only sufficient only for φ_K nets
- NO-TRAVERSAL: only C1 traverses the net (BFS O(reachable)); all other ops O(1) local
- All frontier routing via `net.connect()` → `detect_pair()`; rule bodies never touch frontier directly
- C4 Sub-case B: O(1) rotate+commute+unrotate; no arg subnet traversal; new RepOut = 1 alloc; produces ONLY C4-type pairs → frontier1 stays empty throughout Phase2
- C4 Sub-case B LOPath suffix table: new_app0=P.0b00, new_app1=P.0b01, new_rep=P.0b10, new_repout=P.0b11; derived from R5 suffix table applied to rotated fan (rotate app aux0→principal, apply R5 commute, unrotate result fans)
- C4 Sub-case A: erased ext_up/ext_arg = inert erasers on AUX ports (Phase1 exhaustion guarantees no principal-to-principal pair can exist); no frontier1 entries created
- By-construction: frontier populated during elaboration + rule firing; zero discovery scans
