# Distribution and Reuse — Design

> STATUS: DESIGN SETTLED. Architecture committed; implementation pending.

## Identity model

Two representations of one identity (see `canonical-hash.md`):

- **LOCAL** (`intern(serialize)` → u64): kernel `conv` only; structural-exact; no collision; soundness TCB.
- **WIRE** (`BLAKE3(serialize)` → 32 bytes): distribution only; integrity address; collision = dedup miss, NOT unsoundness.

Distribution operates on the WIRE representation only. Kernel conv never touches the network. A WIRE collision cannot corrupt kernel correctness.

**Trust root**: importing node trusts only its own runtime core and its own primitive table + handler environment. Trusts the peer for NOTHING — bytes are untrusted until all validation steps pass, in order.

---

## Artifact unit

Unit of distribution = a canonical net blob (fully normalized `Net<Canonical>`).

Identified by `ArtifactId = (net_hash: BLAKE3[32], effect_row: EffectRow)`.

- `net_hash` = WIRE hash of canonical serialization; the storage and lookup key.
- `effect_row` = capability metadata; travels alongside the blob but NOT part of the hash key. Same net bytes behind different effect rows = same `net_hash`, different `ArtifactId`.

---

## Pure vs effectful artifacts

| Artifact | Result-cacheable? | Code-distributable? |
|---|---|---|
| Pure (`effect_row.is_pure()`) | YES — Church–Rosser unique NF makes `net_hash → result` a function | YES |
| Effectful | NO — result depends on handler/world | YES — share unapplied code; execute behind capability gate |

Result cache is a pure function `net_hash → canonical_net`. Effectful artifacts are stored and forwarded as code; their values are never cached.

---

## Import validation pipeline

Untrusted bytes pass ALL steps in order; any failure = REJECT:

1. **Recompute hash**: `BLAKE3(blob) == claimed net_hash`. Integrity check; free via content-addressing. Altered bytes hash differently → rejected here.
2. **Structural well-formedness**: deserialize blob → must produce valid canonical net (no active pairs, no unresolved replicators, no disconnected subnets). An adversary cannot craft bytes that both hash-match AND deserialize into a well-formed canonical net for a different meaning.
3. **Primitive compatibility**: every primitive reference in the blob must resolve in the importing runtime's primitive table. Unknown primitives → REJECT.
4. **Format version**: first serialization byte must match current format version constant. Unknown version → reject or migrate.
5. **Capability gate (execution only)**: before EXECUTING — `validate_handlers(local_env, effect_row)` — every required effect label must resolve to a locally-installed handler. Storage and forwarding SKIP this step (may cache code you cannot run).

Result-cache acceptance additionally requires `effect_row.is_pure()`.

---

## Security analysis

**Artifact poisoning (top threat)**: peer serves wrong bytes for a claimed hash. Mitigated by step 1 (recompute-hash) and step 2 (canonical typestate). A forged blob must simultaneously survive a BLAKE3 second-preimage (cost 2^128) AND deserialize into a valid canonical net — strictly harder than a raw collision. Step 2 is the second independent wall.

**BLAKE3 collision**: probability 2^−256 per pair. Accidental collision = dedup miss, NOT unsoundness (WIRE is outside soundness TCB). Adversarial grind costs 2^128 and must additionally pass step 2. Not a practical threat.

**Capability escalation**: imported code cannot conjure a capability the importing node did not install. Effect row is the capability contract; every required label must resolve to a pre-installed handler before execution is permitted. Effect over-approximation (declaring effects that dead branches never fire) is fail-safe — the importing node may be asked for a capability never used at runtime, never the reverse.

**Accepted residual risks (MVP)**: availability/withhold (peer can refuse or lie about having a hash — integrity unaffected); no authenticity (unsigned, no provenance); BLAKE3 dedup-miss (2^−256, non-soundness by design).

---

## Trust tiers

| Concern | MVP | Future |
|---|---|---|
| Integrity | Content-address recompute-hash — free, no PKI | Complete |
| Authenticity / provenance | None — unsigned | Signed artifact IDs + provenance metadata |
| Well-formedness | Canonical typestate — stronger than hash-only | Complete |
| Effect safety | Pure-only result cache + capability gate on execute; handlers pre-installed | Shipped handlers by hash (requires hash-linked dependency graph) |
| Peer trust | Trusted-peer list; peer trusted for nothing re: integrity | Content-advertisement manifest; untrusted-peer hardening |
| Primitive identity | Single runtime: match by construction; version byte for semantics changes | Cross-runtime structural namespacing |
| Dependency model | Monolithic blobs — no transitive hash-graph, minimal attack surface | Hash-linked reference leaves + lazy transitive sync |

---

## Dependency models

**Option A — Monolithic blobs (MVP)**: each artifact is a self-contained canonical net. Definitions inlined at elaboration time; no inter-artifact references in the blob. No transitive sync complexity. Ships first.

**Option B — Hash-linked graph (future)**: definitions carry `Const(ArtifactId)` reference leaves pointing to dependencies by hash rather than embedding them. Enables:
- Lazy transitive sync: fetch only missing hashes; staging table holds unresolved deps until all arrive.
- Structural sharing: identical sub-nets stored once across all artifacts.
- Free rename: names are metadata mapping name → `ArtifactId`; renaming edits only the namespace, never the blob.
- Result caching by definition hash: changing any transitive dependency changes the hash → automatic cache invalidation without explicit cache-busting.

Each fetched dependency in Option B runs the full import validation pipeline independently.

---

## Phase roadmap

- **Phase 0**: in-process result cache; `net_hash → result` lookup before normalize; 0-interaction hit on cache.
- **Phase 1**: on-disk content-addressed store; persist blobs keyed by `net_hash`; integrity verified on read.
- **Phase 2**: two-node fetch-by-hash demo; Node A normalizes + stores; Node B given hash → fetch → validate pipeline → use without recompute.
- **Phase 3**: hash-linked dependency graph (Option B) + lazy transitive sync.

---

## Relationship to other settled docs

- `canonical-hash.md`: WIRE/LOCAL split, serialize algorithm, format version, ArtifactId.
- `effects-and-handlers.md`: effect rows, capability labels, validate_handlers, purity boundary.
- `net.md`: `Net<Canonical>` typestate, canonical serialization, certify_canonical.
- `driver.md`: end-to-end export/import/reuse flow.
