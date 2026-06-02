# δ-lang: LOPath — SETTLED

## What It Is

`LOPath` is a finite binary bitstring — the dynamic address of an active pair (redex)
within the interaction net, measuring its position relative to root in leftmost-outermost
(LO) order. Confluence and optimality follow from LO-prefix ordering (main.tex §4):

- **Prefix conflict**: two redexes where one path is a prefix of the other are
  ancestor-descendant → serialized by selecting the LO-minimum (outer) first.
- **Prefix independence**: two redexes where neither is a prefix of the other operate
  on disjoint net regions → fire in parallel without synchronization.

LO paths are **assigned by construction** during elaboration and **propagated
rule-locally** at runtime. No global scan is ever needed.

---

## Rust Type


**Depth formula**:
- `cold.is_some()` → `256 + len`
- `warm.is_some()` → `128 + len`
- else → `len`

**Max depth**: 384 bits (3 × 128 limbs). No heap allocation. Zero deps.

---

## Constants


---

## Core Operations

### extend_right() — right branch (arg side)

Appends a `1` bit. Called when elaborating the *argument* of an application `e1 e2`,
and by runtime rules R4/R5/R7 for right-side output agents.


### extend_left() — left branch (body/func side)

Appends a `0` bit. Called by runtime rules R4 (body/result side) and R2/R3 (erased aux0 peer)
for left-side output agents. (R6 inherits `lo` unchanged — no extend.)


### extend_bit(bit: u8) — internal


**O(1)** on all paths (limb promotion hot→warm→cold; no heap).

### is_prefix_of(&self, other: &LOPath) → bool

Returns `true` if `self` is a proper prefix of `other` OR equal.


### prefix_independent(&self, other: &LOPath) → bool


Used by coordinator to form safe parallel batches (entire frontier1 = antichain).

### depth() → usize


---

## Ordering — Leftmost-Outermost

`LOPath` implements `Ord` via **lexicographic bit-order** (MSB-first).
Shorter paths that are prefixes of longer paths compare as **less** (outer before inner).


`BTreeMap<LOPath, ActivePair>` = LO-ordered frontier. `pop_first()` = leftmost-outermost redex.

**Proof**: LO path = binary address of position in LO tree. Lexicographic order on addresses
= left-before-right + outer-before-inner = leftmost-outermost order. ✓ (main.tex §4)

---

## Depth Limit

```
Max depth: 3 limbs × 128 bits = 384 bits
```

**Why 384?** Each `e1 e2` application arg increments elaboration `level` by 1 via
`extend_right()`. Level field `Slot.data: u16` must not overflow.
`level ≤ LOPath.depth ≤ 384 < u16::MAX = 65535` — single gate, no separate overflow check.
(main.tex §2/§3: level = replicator depth = bounded by LOPath depth. net.md §Slot.)
384 nested application arguments is sufficient for all practical Nix/δ-lang programs.

`DnxError::LOPathDepthExceeded` fires when `extend_bit()` would exceed 384 bits
(all 3 limbs full).

**Note on limb promotion**: at `len==128` the active limb is full → promote hot→warm→cold
(no error). `LOPathDepthExceeded` fires only when all 3 limbs are full (depth would exceed 384).

---

## Elaboration-Time Assignment

Every `connect(net, port_a, port_b, lo)` call passes the LOPath of the current
context. The elaboration function receives `lo: LOPath` and threads it structurally:

| Construct | LOPath passed to sub-elaboration |
|-----------|----------------------------------|
| `abs x . body` | body: `lo.extend_left()?` |
| `e1 e2` (func `e1`) | `lo.extend_left()?` |
| `e1 e2` (arg `e2`) | `lo.extend_right()?` |
| `rep e as (a,b) in body` (e) | same `lo` |
| `rep e as (a,b) in body` (body) | same `lo` |
| `era e in body` (e) | same `lo` |
| `era e in body` (body) | same `lo` |
| `name x` | — (no sub-elaboration) |
| def root | `LOPath::ROOT` |

**Intuition**: only `e1 e2` arg-side descends right (one `extend_right` per application).
All other constructs stay at the same LO depth as their parent.

---

## Runtime Rule Suffix Tables

At runtime, each R-rule fires at some `lo: LOPath` (the redex's address) and assigns
LOPaths to newly detected active pairs. C-rules inherit the triggering pair's `lo` unchanged.

### R1 — Era⊗Era

Both erasers vanish. No new agents. No new active pairs. **No LOPath assignment.**

### R2 — Era⊗Fan

Eraser bits set on peer(fan.aux0) and peer(fan.aux1). Fan slot freed. No new active pairs.
(Eraser propagation is lazy — fires when eraser reaches a principal port via R4/R5.)
**No LOPath assignment.**

### R3 — Era⊗Rep

Eraser bits set on peer(rep.aux0) and peer(rep.aux1). Rep slot freed. No new active pairs.
(C3 pre-check fires on rep before R3 if rep is Unpaired — inherits `lo`, no extension.)
**No LOPath assignment.**

### R4 — Fan⊗Fan (β-reduction)

Cross-wire: `peer(fan_abs.aux0)` ↔ `peer(fan_app.aux0)`, `peer(fan_abs.aux1)` ↔ `peer(fan_app.aux1)`.

If cross-wired ports both have principals → `detect_pair()` → new active pairs:

| New pair | LOPath suffix |
|----------|--------------|
| peer(abs.aux0) ↔ peer(app.aux0) | `lo.extend_left()?`  (body/result side) |
| peer(abs.aux1) ↔ peer(app.aux1) | `lo.extend_right()?` (var/arg side) |

### R5 — Fan⊗Rep (commutation)

Emits 4 new agents: FanA, FanB (copies of original Fan), RepIn, RepOut (copies of Rep):

| Emitted agent | LOPath suffix | bits | suffix_len |
|---------------|--------------|------|------------|
| FanA | `lo ++ 0b00` | 2 bits |
| FanB | `lo ++ 0b01` | 2 bits |
| RepIn | `lo ++ 0b10` | 2 bits |
| RepOut | `lo ++ 0b11` | 2 bits |

New active pairs detected among the 4 new agents' ports. All at their respective LOPaths.

### R6 — Rep⊗Rep Annihilation (same level)

Cross-wire: `peer(rep_a.aux0)` ↔ `peer(rep_b.aux0)`, `peer(rep_a.aux1)` ↔ `peer(rep_b.aux1)`.
Both reps freed. No new agents created.

If cross-wired ports form active pairs → inherit **same `lo`** (no extension):

| New pair | LOPath |
|----------|--------|
| peer(rep_a.aux0) ↔ peer(rep_b.aux0) | `lo` (unchanged) |
| peer(rep_a.aux1) ↔ peer(rep_b.aux1) | `lo` (unchanged) |

**Why no extension?** R6 is structural annihilation at the same LO depth, not a
β-reduction advancing depth. The resulting pairs occupy the same LO position as the
consumed rep-rep pair. (main.tex §4: rep⊗rep same-level = identity on normal forms.)

### R7 — Rep⊗Rep Commutation (different levels)

Emits 4 new replicators: higher[0], higher[1] (copies of higher-level rep), lower[0], lower[1] (copies of lower-level rep):

| Emitted agent | LOPath suffix | bits |
|---------------|--------------|------|
| higher[0] | `lo ++ 0b00` | 2 bits |
| higher[1] | `lo ++ 0b01` | 2 bits |
| lower[0]  | `lo ++ 0b10` | 2 bits |
| lower[1]  | `lo ++ 0b11` | 2 bits |

Same 2-bit suffix table as R5. Inner cross-wires between new replicators detected by
`connect()`; new active pairs inserted at their respective LOPaths.

### C-Rules — No LOPath Extension

| C-rule | LOPath behavior |
|--------|----------------|
| C1 (BFS sweep) | No active pairs; no LOPath |
| C2 (rep merge) | New pairs inherit triggering pair's `lo` — no extension |
| C3 (rep decay) | New pairs inherit triggering pair's `lo` — no extension |
| C4 (aux fan replication) | Inherits `lo` of the rep.principal↔app.aux0 connection |

C-rules are **topological rewires** at the same LO position. (main.tex §4; syntax.md §C-Rules.)

---

## Antichain Property

**Theorem**: `frontier1` is always a maximum independent set (antichain under prefix-independence).

**Proof sketch**:
1. At elaboration: ROOT is empty — trivially antichain.
2. R-rules consume pair at `P`; emit outputs at `P ++ suffix_i`. Since suffixes are distinct
   (e.g., 0b00, 0b01, 0b10, 0b11), outputs are pairwise prefix-independent.
3. All outputs extend `P` — so outputs are NOT prefixes of any existing pair `Q` in the frontier
   (existing pairs at depth ≤ |P| are already consumed or prefix-independent of `P`).
4. `P` is removed from frontier before outputs are inserted → no stale P-prefix conflict.
5. By induction: frontier1 is always an antichain. ✓

**Consequence**: `drain_independent_batch` = `frontier1.drain(..)` — the ENTIRE frontier is
always the batch. No per-entry prefix-independence filter is needed.
(cpu.md §Antichain Guarantee; main.tex §4.)

---

## GPU Serialization

GPU kernel operates on the hot-path representation only (128-bit paths).
Programs with LOPath depth > 128 bits fall back to CPU scheduler automatically.

```wgsl
// LOPath packed as 4 u32 limbs (= 1 u128) + u32 len
// Matches GpuActivePair layout in gpu.md
struct GpuLOPath {
    lo_hi:   u32,   // bits[127..96]
    lo_mid1: u32,   // bits[95..64]
    lo_mid0: u32,   // bits[63..32]
    lo_lo:   u32,   // bits[31..0]
    lo_len:  u32,   // bit count (0..=128); padded to u32
}
```

**Zero-transcoding**: CPU `LOPath` first limb `{ hot: u128, len: u8 }` ↔ GPU 4×u32 = plain `transmute` (GPU uses hot limb only; depth>128 → CPU fallback).
Prefix check on GPU (within kernel): not needed — batch is already prefix-independent.

For GPU dispatch: coordinator checks `lo.depth() <= 128` before placing in GPU batch.
Paths > 128 bits remain in CPU fallback frontier.

---

## Shard Key

For sharded parallel dispatch (cpu.md §ParallelScheduler), shard = first bit of LOPath:


First bit of LOPath partitions left/right subtrees → inherently disjoint shards.
Workers assigned to distinct shards never share frontier entries.

---

## `connect()` and `detect_pair()` Contract

Every port connection in the system MUST go through `connect(net, port_a, port_b, lo)`.
Never bypass via `connect_peers` or raw field writes.

`connect()` calls `detect_pair(port_a, port_b, lo)` which:
1. Checks if both ports are principals → insert `ActivePair` into `frontier1` at `lo`.
2. Checks if `port_a = rep.principal` and `port_b = fan_app.aux0` (or vice versa) → insert
   `C4Candidate` into `frontier2` at `lo`.
3. Otherwise: plain wire (no frontier insertion).

This single invariant ensures every emergent active pair is captured with correct LOPath.
(syntax.md §C-Rules: "connect(a, b, lo) must always be called".)

---

## Depth Limit vs Level Bound

```
LOPath depth:    0 ≤ depth ≤ 384   (3 limbs × 128)
Slot.data level: rep.level = abs_level+1 ≤ 385  (abs_level ≤ max arg-depth ≤ 384)

Proof: level is NOT the rep's own LOPath depth — rep.level = abs_level+1 can exceed it
(e.g. `abs x.rep x as(a,b) in a b`: rep at depth 0, level 1). But abs_level ≤ global max
arg-nesting depth ≤ 384, so level ≤ 385 < 2^14 (Rep data bits[15..14]=0 safe) < u16::MAX.
LOPathDepthExceeded (at depth 384) is the single gate. (main.tex §3; net.md §LEVEL BOUND PROOF)
```

---

## Settled — Do Not Revisit

- Type: `LOPath { hot: u128, warm: Option<u128>, cold: Option<u128>, len: u8 }` — zero alloc, no deps
- Bit order: MSB-first (bit 0 = first branch from root; stored at bit[127] of `hot`)
- `0` = left branch (body/func), `1` = right branch (arg/var)
- `extend_right()` = right (arg); `extend_left()` = left (body)
- Depth limit: **384 bits** (3 × 128); `DnxError::LOPathDepthExceeded` when all 3 limbs full
- Tier promotion: len==128 → advance hot→warm→cold; no heap alloc ever
- BTreeMap ord = lexicographic MSB-first = leftmost-outermost order
- `is_prefix_of` = prefix-independence check; `prefix_independent` for batch safety
- Elaboration: `abs` body + `e1 e2` fn-side call `extend_left()`, `e1 e2` arg-side `extend_right()` (F2: antichain — distinct sub-terms get distinct paths); only `rep`/`era` bodies inherit same `lo`
- R1/R2/R3: no LOPath assignment (no new active pairs created directly)
- R4: extend_left + extend_right for 2 cross-wire pairs
- R5/R7: 4 new agents at 0b00/0b01/0b10/0b11 (2-bit suffixes)
- R6: same-level annihilation → cross-wire pairs inherit `lo` unchanged
- C-rules: inherit `lo` unchanged — not depth-advancing rewrites
- GPU: 4×u32 = 128-bit hot path only; >128-bit paths stay on CPU
- Shard key: first bit of LOPath
- `connect()` is the SOLE entry point for active pair detection — never bypass
- Antichain invariant: entire frontier1 is always a maximum independent set → batch = full drain
