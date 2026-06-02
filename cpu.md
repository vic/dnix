# δ-lang: CPU Parallelism — SETTLED

## Mathematical Grounding (main.tex)

- §2 perfect confluence: every normalizing interaction ORDER → same result, same step count.
  Independent active pairs have disjoint write sets → fire simultaneously without sync.
- §4 optimality (Lévy): no step is unnecessary. Parallel batch = disjoint regions →
  no rule can erase work of another rule in the same batch → every fired rule is necessary.
- §4 max parallelism: frontier1 is an ANTICHAIN by construction.
  Proof: rule consumes path P, outputs at P.s (strictly longer). Outputs of prefix-independent
  P, Q extend to P.s₁, Q.s₂ which are prefix-independent. Induction: frontier1 is always
  a maximum independent set. drain_independent_batch returns the ENTIRE frontier1.
  Wall-clock time = max(rule_latency in batch), not Σ. Speedup(P) = |frontier1| / ceil(|frontier1|/P).
- Kahn 1974 KPN: each worker = deterministic process on its input stream. Rayon non-deterministic
  work-steal does NOT affect result — independent rules commute (confluence). Final normal form
  is scheduler-independent.
- Mokhov 2018: coordinator = topological scheduler; workers = rebuilders. Batch = static
  dependency set (prefix-independent); new pairs = dynamic deps discovered after firing.
  NOT a suspending scheduler — no task suspends; new pairs go into next batch.

---

## Scheduler Trait


Two schedulers here: `SequentialScheduler`, `ParallelScheduler`. GPU backend (`GpuScheduler`) lives in separate `dnx-gpu` crate.
All produce identical `Net<Canonical>` — non-negotiable acceptance criterion:
`ParallelScheduler` yields the same `Net<Canonical>` + equal total interaction count as
`SequentialScheduler` (paper perfect confluence guarantees same final net and equal
interaction COUNT, NOT an identical per-step trace).

---

## P Parameter


`P=1` → `SequentialScheduler` (separate code path, NOT `num_threads(1)` on rayon pool).
`P=0` / `ParallelMax` → `ParallelScheduler` with `rayon::ThreadPoolBuilder::new().build()` defaults.
`P=N` → `rayon::ThreadPoolBuilder::new().num_threads(N).build()`.

---

## SequentialScheduler (P=1)

Exact `normalize` loop from reducer.md. No changes.

- Single arena; inline alloc; no epoch sync between rules.
- `frontier1: BTreeMap<LOPath, ActivePair>` — plain `pop_first()` loop.
- `frontier2: BTreeMap<LOPath, C4Candidate>` — plain `pop_first()` loop.
- `claim` byte (slot[1]) unused — no contention.
- shard hint unused — no sharding (hint is derived on demand from `lo.first_bit()`, not stored; net.md Slot bytes[2..3] = `_pad0`).
- `gen_low` ABA check still runs — validates rule code correctness (Phase A intent).
- C2/C3 pre-checks inline in loop (same as sequential reducer).
- Phase1 → Phase2 switch: plain `frontier1.is_empty()` check after loop.
- C1 quiescent: trivially quiescent (single thread) — no `request_quiescent_epoch` needed.


---

## ParallelScheduler (P>1)

### Ownership Model — Zero Contention, Zero Mutex

**Coordinator thread** exclusively owns:
- `frontier1: BTreeMap<LOPath, ActivePair>`
- `frontier2: BTreeMap<LOPath, C4Candidate>`
- Global arena freelist

**Workers** never touch the frontier or arena freelist.
Workers write ONLY into their pre-partitioned `WorkerOutput[i]` slot — disjoint by index.
No Mutex anywhere. No lock-free queue. No atomic insert into frontier during batch.

### Antichain Guarantee → Entire Frontier is the Batch

frontier1 is always an antichain (proved above). Therefore:
- `drain_independent_batch` = `frontier1.drain(..)` (collect all into `Vec<ActivePair>`)
- The prefix-independence check is an invariant, not a filter — it never skips an entry.
- Batch size N = |frontier1|. No `BATCH_CAP` limit needed (entire frontier is safe).

**Note**: `BATCH_CAP = 4 × P` is a tunable ceiling for memory-bounded machines only
(avoids pre-allocating N×4 slots when N is enormous). Default: uncapped.

### Pre-Partitioned Output Buffer — No Mutex

Before dispatch, coordinator allocates:


Each worker `i` gets:
- `batch[i]: ActivePair` (input pair — read only from arena)
- `&mut output_buf[i]` (exclusive write; no other worker touches index i)
- Arena base offset: `base_slot + i * MAX_OUTPUTS` (pre-assigned slot range; no alloc during rule)

Workers write new `Slot` data directly into `output_buf[i].new_agents[0..k]`.
Workers record new active pairs as `(LOPath, ActivePair)` with pre-known slot indices.
No atomics. No CAS. No synchronization between workers during batch execution.

### Rayon Dispatch


`net_ro`: read-only shared reference to arena slots (workers only READ existing slots,
WRITE only into their pre-reserved range). Rust ownership: `&Arena` for reads; `&mut WorkerOutput[i]`
for writes — disjoint, safe without `unsafe`.

### Post-Batch Merge (Coordinator Only)


### Per-Worker Persistent Arena Segment (ThreadPoolBuilder)

For runs where a single rayon pool services many normalize calls (long-lived runtime),
workers hold a persistent `ArenaSegment` via `ThreadPoolBuilder::build_scoped` +
`scoped_thread_local!`. This avoids re-allocating `WorkerOutput` Vec on every batch.


For short-lived single normalize calls, pre-partitioned `Vec<WorkerOutput>` per batch suffices.

### Phase1 → Phase2 Switch


**Why C4 stays on coordinator (CPU single-thread)**:
- Non-local: touches app.principal chain, not just the 2 slots of the pair.
- Requires quiescent epoch: no workers may be active when C4 fires.
- Generates new C4 candidates → frontier2 modified during iteration.
- Sequential by nature: each C4 step reduces Σ(rep-to-Abs distance) by exactly 1.

**Why C1 stays on coordinator (CPU single-thread)**:
- Global BFS/DFS traversal: irregular memory access pattern.
- Quiescent: no concurrent workers.
- Runs once at end; amortized cost is low.

**Why C2/C3 stay on coordinator (CPU sequential)**:
- Lazy pre-rule checks on Unpaired reps.
- C2/C3 may abort and retry outer rule (sequential abort logic).
- Not a separate phase — inline in Phase1/Phase2 loops.

### Shard Hint (Deferred Optimization)

The shard hint is **derived on demand from `lo.first_bit()`** — there is NO per-slot storage
for it (net.md Slot bytes[2..3] are `_pad0`, unnamed structural padding, not a named
`shard_hint` field). This optimization is reserved for Phase C.2+ when coordinator contention is
measured to be a bottleneck. The optimization: partition frontier by `lo.first_bit()` into
P sub-BTreeMaps, each owned by a shard-coordinator. Shards are prefix-independent by
construction (first bit of LO path partitions the net). Not implemented in initial design.

---

## Correctness Properties Preserved Under P>1

| Property | Guarantee |
|---|---|
| Confluence | Batch = antichain → disjoint regions → independent rules commute → same result regardless of rayon scheduling order |
| Optimality | Disjoint regions → no rule erases another rule's work in same batch → every fired rule is necessary (Lévy) |
| Max parallelism | frontier1 is always max independent set → entire frontier fires per batch → wall-clock = max(rule latency) |
| Determinism | Coordinator frontier drain is deterministic (BTreeMap iteration order); Kahn KPN: worker outputs are pure functions of their input pair |
| Scheduler independence | Same Net<Canonical> for any P; trace equivalence with P=1 is acceptance test |

---

## Settled — Do Not Revisit

- Pre-partitioned output buffer (not Mutex, not MPSC, not CAS-on-frontier) ✓
- SequentialScheduler is a SEPARATE code path (not num_threads(1)) ✓
- Coordinator exclusively owns frontier — zero contention during batch ✓
- C1, C2, C3, C4 always on CPU coordinator, never workers ✓
- shard_hint deferred until contention is measured ✓
- GPU in separate `dnx-gpu` crate (not in `dnx-sched`) ✓
- frontier1 antichain → drain_independent_batch = drain all ✓
