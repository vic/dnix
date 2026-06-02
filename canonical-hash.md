# δ-lang: Canonical Artifact Identity — SETTLED

Content-addressed identity for normalized pure programs (Unison-style): equal `Net<Canonical>`
artifacts get equal identity, stable across machines and independent of representation/handler placement.

## THE identity is ONE thing — `ArtifactId` (Unison model)

**UNIFIED MODEL (2026-06-04, Vic + supervisor — supersedes the 2026-06-03 "two identities" note below).**
The system has exactly **one** content identity: **`ArtifactId` = the canonical `serialize` bytes** (the
deterministic root-DFS below). It is NOT two ids — it is ONE id with **two representations** of the same
bytes:

- **LOCAL (conv / kernel TCB):** exact equality via an **intern table** — `intern(serialize) → u64`,
  table bytes are ground-truth (hash only buckets) → **structural-exact, O(1), NO collision in the
  soundness TCB**. This IS the mechanism formerly named
  `CanonId`; it is now "ArtifactId **local equality**." This preserves the SETTLED no-crypto-in-conv-TCB
  decision (conv = ArtifactId local-exact eq, a byte-`Eq` on intern hit, NOT a hash compare).
- **WIRE (distribution / cross-machine):** **`BLAKE3(serialize)`** — a compact content-address for
  transport/storage. A collision there = **dedup miss, NOT a conv/soundness dependency** (Unison-style,
  already accepted).

Both representations are derived from the SAME `serialize` (below); they are two views of one identity,
not two identities. `effect_row` stays **derived metadata on `ArtifactId`** (§ArtifactId), never folded
into the bytes. See proofs.md §1/§2b/§6 + trusted.md §Conv-mechanism + T6.

> ⚑ **OPEN — Vic-confirm (one soundness sub-decision, do NOT treat as closed):** the LOCAL form =
> **structural-exact intern** (RECOMMENDED — keeps crypto OUT of the conv TCB, which Vic earlier
> rejected putting in) **vs** **BLAKE3-only everywhere** (simpler: one BLAKE3 compare for both local and
> wire, but that puts a cryptographic hash *inside* the conv/soundness TCB — collision would become an
> unsoundness, the thing Vic rejected). This doc **encodes the structural-exact recommendation**;
> flagged here as the remaining Vic-confirm.


## Hash domain — what may be hashed

The hash domain is **deep-forced canonical nets** (`Net<Canonical>`): fully reduced (NF), pure.
- A value is hashable only after `force_deep` (reducer.md): all thunks resolved, all lazy `Term`s forced.
- `certify_canonical` (net.md) must succeed: no active pairs, no `RepOut`, no replicator trees, no
  disconnected subnets. The `Net<Canonical>` typestate is the unforgeable proof (net.md §Canonical).
- **Not hashable**: a value whose `force_deep` diverges (infinite structure) or requires an effect.
  For code-sharing, hash the canonical net of the *unapplied definition* (finite) — not infinite data.
  Hashing an effectful/non-terminating value → `HashError::NotForceable`.

Why canonical nets are a sound identity: Church–Rosser (paper §4) ⇒ every λ-term has a UNIQUE canonical
net `φ_S(λ)`, and every proper net reducing to it normalizes to the SAME canonical net. So two artifacts
are semantically equal **iff** their canonical nets coincide ⇒ hashing the canonical net is a sound
equality. (Paper asserts confluence; readback.md flags it unproved — same caveat applies here.)

## Canonical serialization (the hash input)

A canonical net is hashed via a **deterministic root-DFS** that erases all representation freedom
(slot/PortId allocation order, bound-variable names):

```
serialize(net, root) -> bytes:
  idx: Map<AgentId, u32> = {}          # canonical index = first-visit order
  out: ByteSink = []
  visit(root_agent)                    # DFS in fixed port order
  return out

visit(a):
  if a in idx: return                  # shared node (DAG) already emitted — edges will reference its idx
  i = idx.len(); idx[a] = i            # assign canonical index in first-visit order
  for child in ports_in_canonical_order(a): visit(child_agent)   # depth-first, fixed order
  emit_record(i, a)                    # node record (children now have indices)
```

**`ports_in_canonical_order(a)`** (fixed, total):
- Fan (Abs/App): principal, aux0, aux1.
- Rep: principal, aux0, aux1.
- Eraser: (none — it is virtual; encoded inline on the referencing port).
- PrimVal List: elements in list order.
- PrimVal AttrSet: entries in **sorted key order** (byte-order on key) — Nix attrset equality is key-set based.
- PrimVal Int/Float/Str/Path/Null: leaf.
- PrimFun: captured args in capture order.

**`emit_record(i, a)`** (length-prefixed fields, all little-endian):
- `kind` byte: distinct code per agent kind (FanAbs, FanApp, RepIn, Eraser, Int, Float, Str, Path, Null,
  List, AttrSet, PrimFun, FreeVar). (RepOut/Unknown cannot occur in canonical — debug_assert.)
- Rep: `level: u16`, `delta0: i16`, `delta1: i16`.
- PrimVal leaf value, **canonicalized**:
  - Int: `i64` LE. Float: IEEE-754 bits with `-0.0 → +0.0`, all NaN → one canonical NaN. Str/Path: `len:u32 ++ utf8`.
  - Null: empty.
- List/AttrSet: `n:u32`; AttrSet also emits each sorted key (`len ++ utf8`) before its child edge.
- PrimFun: stable `prim_id:u32` (nixprim.nix §prim_id = index into sorted stdlib name list).
- FreeVar: `name` (`len ++ utf8`) — free vars are the interface, hashed by name.
- edges: for each port, the neighbor's **canonical index** (`u32`) + neighbor port selector (2 bits).
  An eraser-connected port emits the sentinel index `ERASER`. Edges live in canonical-index space,
  so they are invariant to allocation order.

**Invariances** (the point):
- allocation order → erased (canonical first-visit indices, never slot indices).
- α-renaming → erased (bound vars are wires = edges, never names; only free vars carry names).
- sharing topology → captured faithfully (DAG: a shared node is emitted once, referenced by index),
  and it is unique because the canonical net is unique.

## Algorithm


BLAKE3: fast, 256-bit, no length-extension, parallel-friendly. Single algorithm (no multi-hash scheme).
Format version tag = first byte of the serialization (`CANON_HASH_V1 = 0x01`) → safe future migration.

## ArtifactId — THE identity (one id, two representations)

`ArtifactId` IS the content identity = the canonical `serialize` bytes (§Canonical serialization). The two
representations are derived from those bytes; `effect_row` is metadata carried alongside, not part of the
identity. Conceptual shape:

`effect_row` is derived (effects-and-handlers.md D6/D7): metadata for fast remote-capability checks,
**not** mixed into the identity (a pure value and the same value behind a handled effect share the same
`ArtifactId`). Pure artifact → `EffectRow::pure()`. Distribution syncs missing dependencies by the WIRE
representation `BLAKE3(serialize)` (Unison-style); conv compares the LOCAL representation (intern-exact).

**Kernel definitions are content-addressed by `ArtifactId`.** `Const` / `Ind` / `Ctor` / `Elim`
(proofs.md §1) are identified by the `ArtifactId` of their definition's canonical net (the Unison model) —
NOT by separate interned `ConstId` / `IndId` name-ids. Human names are **metadata mapping name →
`ArtifactId`**. `GlobalEnv` is keyed by `ArtifactId` (proofs.md §6). The transient arena coordinates
(`slot` / `PortId` / `generation` / `var_id`) and the stable-stdlib `prim_id` are **physical/runtime
indices, NOT "ids" in the `ArtifactId` sense** — they carry no semantic identity.

## API surface


## Settled — Do Not Revisit

- Hash domain = deep-forced `Net<Canonical>` (NF, pure); non-forceable/effectful → `HashError::NotForceable`.
- Identity is sound because the canonical net is UNIQUE per value (Church–Rosser; same caveat as readback.md).
- **ONE identity = `ArtifactId` (2026-06-04 unified, supersedes the 2026-06-03 "two identities" note):**
  `ArtifactId` = the `serialize` bytes, with two derived representations — LOCAL = `intern(serialize)`
  (structural-exact, in conv TCB, no collision; = the former `CanonId`); WIRE = `BLAKE3(serialize)`
  (distribution; collision = dedup miss, NOT unsoundness). Not two ids — two views of one. See proofs.md
  §1/§2b/§6. ⚑ structural-exact-vs-BLAKE3-only local form = open Vic-confirm (top of this doc).
- Input = deterministic root-DFS serialization; canonical first-visit indices erase alloc order; bound vars = edges (α-invariant); free vars + prim_id + canonical literal bytes carry identity.
- AttrSet children in sorted-key order; Float `-0.0→+0.0` + canonical NaN; Str/Path length-prefixed UTF-8.
- Algorithm = BLAKE3, 32 bytes; version byte `0x01` prefix (WIRE representation + intern-table hash fn).
- `ArtifactId` = identity of `serialize` bytes; `{ wire: BLAKE3(serialize), effect_row }`; effect_row is
  DERIVED metadata, NOT in the identity. Kernel `Const`/`Ind`/`Ctor`/`Elim` content-addressed by
  `ArtifactId`; names = metadata→`ArtifactId`; `GlobalEnv` keyed by `ArtifactId`.
- Lives in `dnx-core`; consumed by `distribution.md`.
