# δ-lang: Net Data Structure — SETTLED

## Design Constraints (Non-Negotiable)

- Extreme parallelism via LO-partition → disjoint write sets → lock-free
  [main.tex §1: interaction rules are local; applied simultaneously without synchronization]
- Arena allocation: no per-agent malloc; tombstone reuse; epoch-safe ABA
- Cache: 2 slots per 64B line; data-used-together co-located
- Rust: `#[repr(C, align(32))]` Slot, `u32` PortId, `PhantomData` typestate

**Mathematical backing (main.tex):**
- §2 "Core Interaction System": 3 agent types — fan (2 aux), eraser (0 aux), replicator (n≥1 aux, level l∈ℕ, deltas dᵢ∈ℤ)
- §4: "possible to limit replicators to have at most two auxiliary ports" → Slot.delta0/delta1 (n=2) is sound
- §4 complexity consequence: n=2 → total agents = effective SPACE complexity measure; total interactions = effective TIME complexity measure [tree of 2-port reps = any arity, so n=2 is not a loss]
- FanKind (App vs Abs) stored in tag bit[0]: paper §3 says FanKind determinable by path traversal from root; storing it in tag = O(1) optimization (avoids traversal during readback and dispatch)
- §2: perfect confluence of core → independent active pairs have disjoint write sets → lock-free parallel firing

---

## PortId — `u32`

```
bits[31..4]  slot_idx  (28 bits)  → max 268M agents in arena
bits[3..2]   port_kind (2 bits)   00=Principal 01=Aux0 10=Aux1
bits[1]      eraser    (1 bit)    virtual eraser flag; NO slot allocated
bits[0]      gen_low   (1 bit)    parity of slot.generation → ABA guard
```

**Eraser is virtual**: `PortId { eraser=1 }` — no Slot. Elaborator sets eraser_bit directly.
No null PortId: `slot_idx=0` reserved as sentinel (arena idx 0 = unused).


---

## Slot — 32 bytes, 32-byte aligned


**Cache layout**: 32B align → 2 Slots per 64B cache line. Rule fires on pair (A, B);
if A.slot_idx and B.slot_idx differ by 1 (adjacent) → single cache line fetch.
LOPath-shard affinity ensures related agents land close in arena.

### `tag` bitfield (u8)

All 8 bits used. Lower nibble = kind+status. Upper nibble = runtime flags.

```
bit[7]  aux1_erased   (Rep only): aux1 PortId is eraser; cached for O(1) C3/C2 dispatch
bit[6]  aux0_erased   (Rep only): aux0 PortId is eraser; cached for O(1) C3/C2 dispatch
bit[5]  c1_mark       (All):      BFS reachability mark during C1 sweep; cleared on alloc/retire
bit[4]  erasing_abs   (FanAbs only): aux1=eraser at construction → O(1) R4 erase-abs detection

bits[3..2]  major class:
  00 = Free    (free wire slot; var_id in data)
  01 = Fan
  10 = Rep
  11 = Prim/Effect

bit[1]  PairedStatus (Rep only):
  Rep:  0 = Unpaired  (paper §4: fresh from elaboration or Unpaired copy)
        1 = Unknown   (paper §4: after R5 Fan⊗Rep)
  Fan/Prim/Free: ignored

bit[0]  subkind:
  Fan:    0=App   1=Abs         (paper §3 L935/944)
  Rep:    0=In    1=Out         (paper §3 L954/956)
  Prim:   0=Val   1=Fun
  Free:   ignored
```

The `0b11xx` group (bits[3:2]=11) is the Prim group:
```
0xC = 0b1100  PrimVal     bit[1]=0, bit[0]=0 (Val)
0xD = 0b1101  PrimFun     bit[1]=0, bit[0]=1 (Fun)
```

**Upper-nibble maintenance rules**:
- `bit[7]/bit[6]` (aux1/aux0_erased): set by `set_eraser_on_port()` when eraser placed on that aux.
  Cleared when port reconnected to non-eraser. Rep-only; ignored on Fan/Free/Prim/Effect.
- `bit[5]` (c1_mark): set during C1 BFS mark phase. Cleared by `retire_slot()` (so reused slots start unmarked). Never propagated to other slots.
- `bit[4]` (erasing_abs): set by `alloc_abs()` / `set_eraser_on_port()` when aux1=eraser on FanAbs.
  Cleared if aux1 replaced with non-eraser (rare). FanAbs-only; 0 for Perform/Handle at construction.

**Variant table** (lower nibble, upper nibble = 0 at construction):

| Variant         | Code   | Paper ref |
|-----------------|--------|-----------|
| Free            | 0b0000 | §3 L927   |
| FanApp          | 0b0100 | §3 L944   |
| FanAbs          | 0b0101 | §3 L935   |
| RepIn-Unpaired  | 0b1000 | §3 L954 + §4 L1066 |
| RepOut-Unpaired | 0b1001 | §3 L956 + §4 L1066 |
| RepIn-Unknown   | 0b1010 | §4 L1067  |
| RepOut-Unknown  | 0b1011 | §4 L1067  |
| PrimVal         | 0b1100 | Phase C, NOT in paper |
| PrimFun         | 0b1101 | Phase C, NOT in paper |

**Branch-free predicates** (lower nibble — mask off upper before comparing):

**`set_eraser_on_port()` — single maintenance point**:

Unused ports (e.g. PrimFun.aux1, PrimVal.principal) = sentinel PortId(0).

---

## Arena

Single contiguous `Vec<Slot>` pre-allocated at init (e.g. 64M slots = 2 GB).
No `malloc` per agent. Slot index = `PortId.slot_idx`.


`live_list` invariant: exactly the set of currently-live (non-tombstoned) slot indices.
- `alloc_slot(idx)` → `live_list.push(idx)`
- `retire_slot(idx)` → `live_list.swap_remove(pos(idx))` (O(1) with index map)
- Used by C1 to sweep only live slots: O(live) not O(arena_capacity)

Index map for O(1) swap_remove:

### Per-Worker Segment

Each worker owns a local `ArenaSegment` (e.g. 1M slot range). Allocation from
local segment = zero atomic ops. Segment exhausted → claim next segment from
`Arena` with single `fetch_add` on segment cursor.


Tombstone reuse:
1. `free_slot(idx)` → push to `local_free`
2. `alloc_slot()` → pop `local_free` first; else `cursor++`
3. Batch-return overflow local_free → `global_free` when `local_free.len() > THRESHOLD`

**ABA safety**: on reuse, `slot.generation += 1`. `PortId.gen_low = generation & 1`.
CAS on `claim` byte checks `gen_low` matches before claiming.

**ABA requires ≥2 generation bits**: 1-bit parity (gen_low) is insufficient. A slot retired then reallocated twice between a cache-write and cache-read aliases back to the original parity → `port_live` sees false-live on a 2-generation-stale PortId. Correct ABA detection requires at least 2 generation bits (wrapping counter, check equality not parity). Heavy R4 churn on small nets can trigger the 2-cycle path.

### Epoch-based Deferred Reclamation

Used only in Phase C (parallel); Phase A (sequential) uses immediate reuse.
`sweep_retired()` called by coordinator after epoch advance; safe when
`current_epoch - retire_epoch >= 2` (all workers past the epoch).

---

## LOPath

From elaborator.md (unchanged here):


**Extend rules** (matching elaborator LO assignment):
- `abs body`:      body = same `lo`
- `e1 e2` func:   same `lo`
- `e1 e2` arg:    `lo.extend_right()` (append `1` bit)
- `rep/era e`:    e = same `lo`; body = same `lo`

Prefix independence: `a.is_prefix_of(b) == false && b.is_prefix_of(a) == false`
→ disjoint net regions → disjoint write sets → no synchronization needed.

---

## ActivePair & Frontier


`BTreeMap<LOPath, _>` → natural LO-order iteration (leftmost-outermost = smallest LO).

### Batch Extraction — `drain_independent_batch`

```
batch = []
for (lo, pair) in frontier.iter_mut() (LO order):
    if batch.is_empty() || no entry in batch has lo as prefix or vice-versa:
        batch.push(frontier.remove(lo))
    else:
        break   // stop at first conflict (greedy)
return batch
```

Workers receive batch → fire rules → push new ActivePairs → publish to local queue.
Coordinator merges worker queues back to Frontier between batches.

**FAN⊗FREE is not an active pair**: The Free slot variant (result-interface wire, no agent) must never enter the frontier as part of an active pair. `detect_pair` must exclude Free-tagged ports. A principal port connected to a Free slot is the computation's output interface, not an interaction to fire.

### Shard Optimization (future)

Partition Frontier by `lo.first_bit()` → N shards → N worker groups.
Each shard = independent BTreeMap → zero cross-shard contention.
Shard hint derivable on demand from `lo.first_bit()` — no per-slot storage needed.

---

## Net<S, C> Typestate


`Net<Canonical, C>` constructed only via `pub(crate) fn into_canonical<C: NetClassMarker>(net: Net<Proper, C>, witness: CanonicalWitness) -> Net<Canonical, C>`.
`CanonicalWitness` is produced only after Phase 1 + Phase 2 complete + C1 run and invariants pass.

Readback (`psi_native`) takes `&Net<Canonical, C>`. Cannot be called on `Net<Proper, C>`.

### Canonical By Construction (type-enforced)

`main.tex` defines `\Omega_S : \Delta_S^p \to \Delta_S^c` (proper → canonical).
Implementation mirrors this as an unforgeable witness transition, not a boolean flag.


Canonical agent view excludes non-canonical variants at type level:


`Net<Canonical>` APIs expose only `RepCanonicalKind`. Therefore safe code cannot
construct/read a canonical rep as `RepOut` (variant does not exist in canonical view).
Any decode of slot-tag `RepOut` while building canonical view is an internal reducer bug.

Unsafe boundary rule:
- Raw slot/tag mutation helpers remain `pub(crate)` and confined to reducer/elaborator internals.
- Public API never exposes a way to write arbitrary tag bits on `Net<Canonical>`.
- `Net<Canonical>` has no mutators that can create active pairs or reintroduce `RepOut`.

---

## Allocation API (used by Elaborator Pass 2)


`connect(a, b, lo)` calls `detect_pair(a, b, lo)` — the SINGLE detection point.
No traversal anywhere else. Three cases:

| Connection | Action |
|---|---|
| principal ⊗ principal | → `frontier1.insert(ActivePair{p0,p1,lo})` (R1-R7) |
| rep.principal ↔ app_fan.aux0 | → `frontier2.insert(C4Candidate{..})` (C4) |
| any other | → slot fields only; no frontier entry |


**Invariant**: no scan, no traversal. Pair detection = O(1) per `connect()` call.

---

## No-Traversal Guarantee

**Only traversal in entire system**: C1 mark-sweep (single BFS from roots, once at end).
Everything else = O(1) per step:

| Operation | Cost |
|---|---|
| Rule fire (R1-R7, C4) | O(1): local slot reads/writes + O(new_agents) alloc |
| C2/C3 pre-check | O(1): check 2 aux ports of one rep |
| Active pair detection | O(1): in `connect()` via `detect_pair` |
| Frontier insert | O(log F) where F = frontier size |
| Frontier batch extract | O(B log F) where B = batch size |
| Slot alloc | O(1): per-worker segment cursor |
| Slot retire | O(1): push to local freelist |
| C1 mark-sweep | O(R): R = reachable agent count — **only unavoidable traversal** |

LOPath suffix tables: static per-rule → O(1) LO assignment for new agents, no scan.
Frontier populated by-construction during elaboration + rule firing → no discovery scan ever.

---

## Invariants (enforced at construction)

| Invariant | Where enforced |
|-----------|----------------|
| Fan always has 2 aux ports | `alloc_abs/app` only path |
| Rep always has exactly 2 aux ports (fixed n=2) | `alloc_rep_in` only path |
| Rep PairedStatus = Unpaired at construction | `alloc_rep_in` sets tag bit 3 = 0 |
| Every allocated slot has all ports connected before Net<Proper> returned | Elaborator Pass 2 connects eagerly |
| Net<Proper> CAN have cycles (e.g. Ω = (λx.xx)(λy.yy) is cyclic) | Cycles = non-normalizing terms; LO order ensures normalizable terms still normalize |
| eraser_bit slots have slot_idx=0 (no real slot) | `eraser_port()` const fn |
| PortId.gen_low == slot.generation & 1 | set on alloc; checked on CAS claim |

---

## Memory Sizing

| Entity | Size | Notes |
|--------|------|-------|
| Slot | 32 B | 2 per 64B cache line |
| PortId | 4 B | fits in register |
| LOPath | 4 limbs | hot+warm+cold+frozen (u128 each; warm/cold/frozen lazy None) + len:u8 |
| ActivePair | p0,p1,lo,epoch | arena-allocated |
| Arena (64M slots) | 2 GB | pre-allocated at init |
| Per-worker segment | 32 MB | 1M slots × 32 B |

---

## Parallelism Grounding: Haiku Paper Connections

These inform open design questions and advanced extensions.

### Radul 2009 — Monotone PairedStatus Lattice

**Paper**: radul-2009-art-of-the-propagator  
**Core finding**: propagator cells accumulate partial info via `merge` (meet). `nothing` = top (no info); `the-contradiction` = bottom (contradiction). Info flows monotonically: cells only refine, never retract.

**Mapping to PairedStatus**:
- Current binary `{Unpaired=0, Unknown=1}` is already monotone (only ever transitions 0→1).
- Radul insight: instead of a batch-driven status transition, use **cell notification**. When C2/C3 determines a Rep is definitively Unpaired, propagate that immediately to adjacent Reps (like `add-content` alerting interested propagators).
- **Open improvement**: C2/C3 today fire in batch passes. A propagator-style `notify_unpaired(rep)` → cascades to neighbors → enables earlier canonicalization → fewer total reductions.
- Lattice: ⊥ = `Unpaired` (most informative; merging two Unpairedremains Unpaired), ⊤ = `Unknown` (least informative). Status flows toward ⊥ through canonicalization.

**Implementation note**: `merge(Unknown, Unknown) = Unknown`; `merge(Unpaired, _) = Unpaired`. C2/C3 are the `propagator` functions that push the cell toward Unpaired.

---

### Neron 2015 / van Antwerpen 2016–2018 — Scope Graph Path Ordering

**Papers**: neron-2015-scope-graphs, van-antwerpen-2016-statix-constraint-scope-graphs  
**Core finding**: paths in scope graphs are ordered lexicographically by segment specificity: `D(local) < I(import) < P(parent)`. A declaration is visible only if no more-specific path resolves the same name. WF predicate restricts valid paths to define reachability regions.

**Mapping to LO paths**:
- LO path bits (0=left/body, 1=right/arg) define a binary lexicographic ordering — directly analogous to scope path segment ordering.
- The existing LO prefix-independence check (`neither is prefix of the other`) is the interaction-net analog of scope graph's WF-bounded region disjointness.
- **Refinement opportunity**: borrow the WF-predicate concept to define *valid path shapes* for LOPath (e.g., paths of form `0*1*` = body-then-arg extensions represent well-structured lambda nesting). Malformed paths could indicate elaboration bugs before hitting the reducer.
- **Path specificity → shard priority**: deeper LO paths (more bits) shadow shallower ones; within a shard, leftmost-outermost (smallest LO) = highest priority. This matches scope graph specificity: inner declarations shadow outer, exactly as inner redexes are reduced first under LO strategy.

**Implementation note**: `drain_independent_batch` already exploits this — BTreeMap<LOPath,_> iteration = LO-order = specificity order. No change needed; theoretical backing confirmed.

---

### Kahn 1974 — Confluence as Unique KPN Fixpoint

**Paper**: kahn-1974-parallel-programming-semantics  
**Core finding**: Kahn Process Networks guarantee determinism via continuous, monotone functions on CPOs of streams (FIFO channels). Unique minimal fixpoint = deterministic output regardless of scheduling.

**Mapping to dnx parallelism**:
- Workers = Kahn processes. Input = per-shard frontier queue (FIFO within shard). Output = new ActivePair stream.
- Monotonicity: firing a rule adds new redexes to the frontier, never retracts existing ones → frontier only grows before draining.
- Unique fixpoint analogy: interaction nets' **perfect confluence** (one-step diamond) is the operational correlate of KPN's unique minimal fixpoint. Both guarantee that all evaluation orders yield the same result.
- **Lock-free justification**: KPN determinism relies on no shared mutable state beyond FIFO channels. Dnx maps FIFO channels to per-shard Frontier shards — inter-shard communication via coordinator merge. No synchronization within a shard = no locks needed within a batch.
- Sharded Frontier → each shard = independent KPN channel; coordinator = KPN scheduler that merges output channels between steps.

---

### Rondon 2008 — Liquid Types for Flow Polarity (Future Extension)

**Paper**: rondon-2008-liquid-types  
**Core finding**: liquid types combine HM inference with predicate abstraction; path-sensitive (branch-aware). Refinement predicates like `{ν : T | P(ν)}` enforce value-level invariants statically.

**Mapping to deadlock safety**:
- Vicious cycles (deadlocks) in nets = cyclic active pair dependency where no rule can fire.
- Liquid-style refinement of `PortId`: `{p : PortId | polarity(p) = Producer}` vs `Consumer`.
- A deadlock-free type rule: `connect(p: Producer, q: Consumer)` — only valid connections. Cyclic producer→producer connections would fail the type check.
- **Gap**: liquid types are path-sensitive for values, not graph topology. Full deadlock prevention requires a flow graph type system beyond liquid types (e.g., session types).
- **Current mitigation**: `Net<Canonical>` typestate already prevents the most dangerous forms by restricting canonical rep variants. Liquid-style refinements are a future layer for Phase C topology.

---

### Mokhov 2018 — Build Systems → Scheduler/Rebuilder Decomposition

**Paper**: mokhov-2018-build-systems-a-la-carte  
**Core finding**: build systems decompose orthogonally into (1) **Scheduler** (task ordering) and (2) **Rebuilder** (out-of-date detection). Parallel scheduling = topological order + start independent keys simultaneously.

**Mapping to dnx runtime**:

| Build System | dnx Equivalent |
|---|---|
| Scheduler | Coordinator (`drain_independent_batch`) |
| Rebuilder | Worker (fires rules on assigned ActivePairs) |
| Topological scheduler | BTreeMap<LOPath,_> LO-ordered frontier |
| Independent keys | Prefix-independent redex batch |
| Suspending scheduler | Work-stealing (idle workers steal batch tails) |
| Static dependencies | Redexes whose LO paths are known at elaboration |
| Dynamic dependencies | New redexes discovered during rule firing |

- **Suspending parallel scheduler** (Mokhov): starts static deps in parallel while dynamic ones resolve → exact analog of dnx workers firing known-independent redexes while coordinator forms the next batch from newly published pairs.
- **Key insight**: the coordinator/worker split is not just an engineering choice — Mokhov proves it captures the full scheduler design space. Dnx's batch formation + work stealing = the Suspending scheduler with Topological ordering inside each batch.

---

## Settled — Do Not Revisit

- Slot = 32B, `repr(C, align(32))`; 2 per cache line; layout fixed as above
- PortId = `u32`; 28b slot_idx (max 268M agents); eraser_bit; gen_low ABA
- Eraser = virtual; no Slot; eraser_bit only
- Arena = pre-allocated Vec<Slot>; per-worker segments; local tombstone freelist; epoch deferred reclaim
- tag bitfield: ALL 8 BITS USED; lower nibble: major class bits[3..2] (Free=00/Fan=01/Rep=10/Prim=11), PairedStatus bit[1] (Rep only), subkind bit[0]; upper nibble: bit[7]=aux1_erased(Rep), bit[6]=aux0_erased(Rep), bit[5]=c1_mark(all), bit[4]=erasing_abs(FanAbs)
- **net_flags: u8 on Net; bits[1..0]=NetClass(whole-net OR: L=00/A=01/I=10/K=11); bit[2]=pending_c1. Zero-waste: replaces class:NetClass+pending_c1:bool (was 2 bytes; now 1 byte).**
- **free_slots: HashMap<Arc<str>, PortId>; plain PortId (no bits[3..2] reuse — those = port_kind, must stay 00). Per-def class stored in Free Slot data bits[15..14]. accessor: def_class(slot) = (slot.data >> 14) & 0x03.**
- set_eraser_on_port(): single maintenance point for all tag upper-bit + net_flags bit[2] updates; called from connect() and rule code
- rep_c3_candidate(tag): single-mask `(tag & 0xCA) == 0x88` = unpaired rep + aux1_erased + aux0_NOT_erased; gates (false,true) branch only. (true,*) cases reached via unconditional c3_rep_decay call from set_eraser_on_port() when aux0 gets eraser.
- abs_is_erasing(tag): O(1) R4 erase-abs detection via bit[4]; avoids PortId load for aux1
- data field u16: level(Rep) = abs_level+1 ≤ 513 (abs_level ≤ LOPath max depth 512) < 2^14 so Free bits[15..14] safe, < u16::MAX; Free: bits[15..14]=def_class + bits[13..0]=var_id(≤16383); Prim: prim_id; Fan: 0. Bound via GLOBAL max arg-depth, NOT rep's own LOPath depth; LOPathDepthExceeded at 512 gates it.
- delta0/delta1 i16 in Slot directly (not side table); Rep only; co-located with data at bytes 20-25 (Rep hot data contiguous, 6 bytes)
- Net<S> typestate: Proper (mutable) → Canonical (readback-only); `into_canonical(net, witness)` pub(crate)
- Canonical transition uses unforgeable witness (`CanonicalWitness`) produced only after `\Omega` conditions hold
- Canonical rep kind is type-restricted (`RepCanonicalKind::InUnpaired` only); `RepOut` unrepresentable in `Net<Canonical>` safe API
- Frontier = BTreeMap<LOPath, ActivePair>; LO-order = leftmost-outermost by construction
- drain_independent_batch = greedy prefix-independence check; batch = disjoint write sets
- connect() calls detect_pair(): principal⊗principal→frontier1; rep.principal↔app.aux0→frontier2; else slot fields only
- detect_pair() is THE ONLY active-pair detection point; no traversal; O(1) per connect()
- Per-worker ArenaSegment = zero-atomic allocation path; batch tombstone return to global
- LO prefix independence → disjoint net regions → lock-free parallel rule firing
- LOPath = 4-limb `{hot,warm,cold,frozen:u128,len:u8}`; max depth 512; zero-alloc, zero-dep (authority: lopath.md)
- PortId sentinel: slot_idx=0 reserved (never allocated); used for eraser_port() and null check
- alloc_rep_in sets PairedStatus=Unpaired in tag; only reducer can change to Unknown
- claim byte (slot[1]): atomic CAS claim token; claim_pair() CAS both slots' claim fields (lower slot_idx first to avoid deadlock); on CAS failure → retry with backoff; full generation check in claim to detect ABA
- epoch (slot[26-27] u16): retire epoch for deferred reclaim; sweep_retired() safe when current_epoch − retire_epoch ≥ 2
- _pad0 (slot[2-3]), _pad1 (slot[28-31]): structural padding to maintain 32B; no semantics. Shard affinity derivable on demand from lo.first_bit() — no per-slot storage needed.
- prim_vals / prim_fns: side tables indexed by prim_id from slot.data; not in Slot body
- pending_effects: Tier-1 ForeignCall effect queue; drained by normalize_effectful trampoline
- free_slots: name→PortId map for def roots; consumed by readback to recover def names
- No Perform/Handle agent kinds: Tier 2 effects elaborate to free monad λ-terms (see effects-and-handlers.md D10)
