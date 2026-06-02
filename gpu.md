# δ-lang: GPU Parallelism — SETTLED

## Mathematical Grounding (main.tex)

Same three properties as cpu.md apply identically to GPU:
- **Confluence**: GPU batch = antichain = disjoint regions → GPU thread scheduling order is
  non-deterministic but irrelevant — independent rules commute → same result every run.
- **Optimality (Lévy)**: disjoint regions → no GPU thread can erase work of another thread
  in the same batch → every GPU rule firing is necessary → no wasted GPU cycles.
- **Max parallelism**: frontier1 is always the max independent set → GPU dispatches over the
  ENTIRE frontier1 in one kernel → wall-clock = max(rule latency across all threads).

GPU adds no new reduction semantics. It is a faster executor of R1-R7 only.
All paper guarantees (§2 confluence, §4 optimality) hold unchanged.

---

## Crate Separation

GPU scheduler lives in **`dnx-gpu`** (separate crate), NOT in `dnx-sched`.

Rationale:
- `wgpu` is a heavy dependency (pulls in SPIRV toolchain, Metal/Vulkan/DX12 backends).
- `dnx-sched` must compile on machines without GPU (CI, servers, embedded).
- `dnx-gpu` re-exports `impl Scheduler for GpuScheduler` using the same trait from `dnx-sched`.
- Feature flag at top level: `dnx = { features = ["gpu"] }` pulls in `dnx-gpu`.

```
dnx-core        (Net, Slot, PortId, Arena, LOPath)
    ↑
dnx-sched       (Scheduler trait, SequentialScheduler, ParallelScheduler)
    ↑
dnx-gpu         (GpuScheduler — wgpu, WGSL kernels)
    ↑
dnx             (top-level; feature="gpu" enables dnx-gpu)
```

---

## Target Hardware

Everyday laptops — **integrated GPUs**:
- AMD iGPU (RDNA via Vulkan/ROCm)
- Intel iGPU (Iris/Arc via Vulkan)
- Nvidia iGPU/MX via Vulkan
- macOS (Metal)

**wgpu** is the crate: cross-platform via `wgpu-hal` abstracting Metal / Vulkan / DX12.
No CUDA. No proprietary compute APIs. WGSL as shader language — portable, no SPIRV tools at
user build time (wgpu compiles WGSL → backend IR internally).

---

## Rule Split: GPU vs CPU

| Rules | Executor | Reason |
|---|---|---|
| R1-R7 | GPU (dnx-gpu kernel) | Pure local rewrite; 2-slot read + bounded write; no traversal |
| C2/C3 | CPU coordinator | Lazy pre-rule on Unpaired reps; abort/retry logic; sequential |
| C4 | CPU coordinator | Non-local; quiescent epoch required; sequential by nature |
| C1 | CPU coordinator | Global BFS; irregular memory; quiescent required; runs once |

R1-R7 are the ONLY rules on the GPU. No exception.

---

## Zero-Transcoding Invariant

`Slot` layout (`#[repr(C, align(32))]`, 32 bytes) is identical on CPU and GPU.
`PortId` = `u32` = identical.
Uploading a `Vec<Slot>` to a `StorageBuffer` = plain `memcpy`. No transcoding. No marshalling.

GPU sees the arena as `var<storage, read_write> arena: array<u32>` (32B slot = 8 × u32).
GPU sees active pair input as `var<storage, read> pairs: array<GpuActivePair>`.

```wgsl
struct GpuActivePair {
    p0:       u32,   // PortId of agent0 principal
    p1:       u32,   // PortId of agent1 principal
    lo_hi:    u32,   // LOPath bits[127..96]
    lo_mid1:  u32,   // LOPath bits[95..64]
    lo_mid0:  u32,   // LOPath bits[63..32]
    lo_lo:    u32,   // LOPath bits[31..0]
    lo_len:   u32,   // LOPath length (bits used); padded to u32 for alignment
    _pad:     u32,   // 32-byte struct alignment
}
// 8 × u32 = 32 bytes. Matches CPU ActivePair layout (zero-copy upload).
```

LOPath **GPU hot-limb subset (≤128)**: GPU packs only the LOPath hot limb (1×u128 = 4×u32)
+ u32 len. This is an INTENTIONAL SUBSET, not a conflicting cap — the full canonical LOPath is
3 limbs / 384 bits (see lopath.md). Any pair whose path has depth >128 (warm/cold limb present)
is NOT GPU-eligible: the coordinator checks `lo.depth() <= 128` before placing a pair in a GPU
batch (see lopath.md §GPU Serialization); deeper paths → CPU scheduler fallback. GPU does NOT
support 384-bit paths.
Prefix check on GPU = bitwise compare on 4 u32s (not needed during kernel — batch is already
prefix-independent). LOPath suffix append = bit-shift + OR on limb pair. O(1), no cross-thread reads.

---

## Slot Allocation on GPU — No Atomics

Before each GPU dispatch, CPU coordinator:

1. Drains frontier1 into `Vec<GpuActivePair>` (entire antichain, N pairs).
2. Reserves `N × MAX_OUTPUTS` (= `N × 4`) contiguous arena slot indices:
   `base_slot = arena.reserve(N * 4)` — single coordinator call, no GPU involvement.
3. Uploads: active pair buffer + `base_slot` as push constant.

GPU thread `i` writes new agents into arena slots `[base_slot + i×4, base_slot + i×4 + k)`
where `k ≤ MAX_OUTPUTS = 4`. Thread `i` never touches any other thread's range.
Zero atomics for allocation. Pre-partitioned by index = disjoint by construction.

After GPU batch, CPU:
- Reads back output buffer (new active pairs with LOPaths).
- Commits used slots, returns unused to freelist.
- Inserts new pairs into frontier1/frontier2.
- Bumps epoch.

No Mutex. No lock-free queue. No atomic insert. Same ownership model as cpu.md.

---

## Output Buffer (Pre-Partitioned, No Mutex)

```wgsl
struct GpuOutputPair {
    p0:      u32,   // PortId
    p1:      u32,
    lo_hi:   u32,
    lo_mid1: u32,
    lo_mid0: u32,
    lo_lo:   u32,
    lo_len:  u32,
    kind:    u32,   // 0=ActivePair(frontier1), 1=C4Candidate(frontier2)
}

// Output buffer: N × MAX_INNER_PAIRS (max new active pairs per rule firing)
// MAX_INNER_PAIRS = 4 (R7 worst case: 4 new principal↔principal pairs)
@group(0) @binding(2)
var<storage, read_write> out_pairs: array<GpuOutputPair>;
// Thread i writes to out_pairs[i * MAX_INNER_PAIRS .. i * MAX_INNER_PAIRS + k]

@group(0) @binding(3)
var<storage, read_write> out_counts: array<atomic<u32>>;
// out_counts[i] = number of output pairs written by thread i (0..MAX_INNER_PAIRS)
// Atomic only for final count; no cross-thread contention (each thread owns index i)
```

CPU reads `out_counts[i]` then `out_pairs[i*MAX_INNER_PAIRS .. i*MAX_INNER_PAIRS + out_counts[i]]`
for each `i`. No sorting needed on GPU — CPU inserts into BTreeMap (LOPath-ordered).

---

## GPU Dispatch Loop

### Single-Step (Simple Mode)


`TPB = 128` (threads per block; interaction net GPU precedent).

### Multi-Step GPU Loop (Amortized Mode)

For nets with many sequential reduction rounds, avoid per-step CPU roundtrip:
encode N_STEPS compute passes in a single `CommandEncoder`; each pass reads from
the output of the previous via ping-pong StorageBuffers.


`N_STEPS = 128` default (tunable). When GPU frontier empties early, GPU writes `count=0` into
`indirect_buf` → remaining passes dispatch 0 workgroups (no-ops). CPU never polls mid-batch.

---

## WGSL Kernel Structure

```wgsl
@group(0) @binding(0) var<storage, read>       pairs:      array<GpuActivePair>;
@group(0) @binding(1) var<storage, read_write> arena:      array<u32>;  // 32B slots as u32[8]
@group(0) @binding(2) var<storage, read_write> out_pairs:  array<GpuOutputPair>;
@group(0) @binding(3) var<storage, read_write> out_counts: array<atomic<u32>>;

var<push_constant> base_slot: u32;
var<push_constant> n_pairs:   u32;

@compute @workgroup_size(128)
fn rewrite_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x;
    if i >= n_pairs { return; }

    let pair = pairs[i];
    let slot0 = read_slot(arena, pair.p0 >> 4u);  // slot_idx = PortId >> 4
    let slot1 = read_slot(arena, pair.p1 >> 4u);
    let k0 = slot0.tag & 0x0Fu;  // AgentKind from low nibble of tag
    let k1 = slot1.tag & 0x0Fu;

    let my_slot_base = base_slot + i * 4u;
    var out_count: u32 = 0u;

    // Tag-dispatch: R1-R7
    // NOTE: the match key must mask to net.md's tag layout (major class bits[3..2] +
    //   subkind bit[0]); the REP variants (RepIn-Unpaired 0b1000 / RepOut 0b1001 /
    //   RepIn-Unknown 0b1010 / RepOut-Unknown 0b1011) otherwise collide.
    // NOTE: case labels r1..r7 correspond to net.md/reducer.md R1-R7:
    //   R1 era⊗era, R2 era⊗fan, R3 era⊗rep, R4 fan⊗fan, R5 fan⊗rep,
    //   R6 rep⊗rep annihilate, R7 rep⊗rep commute. Erasure cases (R1/R2/R3) MUST be
    //   matched before any default/catch-all branch.
    switch (k0 | (k1 << 4u)) {
        case ERA_ERA:   { r1_era_era(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
        case ERA_FAN,
             FAN_ERA:   { r2_era_fan(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
        case ERA_REP,
             REP_ERA:   { r3_era_rep(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
        case FAN_FAN:   { r4_fan_fan(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
        case REP_FAN,
             FAN_REP:   { r5_rep_fan(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
        case REP_REP:   { r6_rep_rep(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
        default:        { r7_rep_copy(i, pair, arena, my_slot_base, &out_pairs, &out_count); }
    }

    // Write count (thread i owns index i — no cross-thread contention)
    atomicStore(&out_counts[i], out_count);
}
```

`push_constants` feature required: `wgpu::Features::PUSH_CONSTANTS` in `DeviceDescriptor`.
Fallback for backends that lack push_constants: write `base_slot`/`n_pairs` into a small uniform buffer.

---

## LOPath Computation on GPU (Local Only)

Each rule's suffix table is embedded in the WGSL kernel as constants.
GPU thread computes output LOPath = parent LOPath ++ suffix (bit-shift + OR on 4 u32 limbs).
No cross-thread LOPath reads. No global scans. O(1) per output pair.

```wgsl
// Example: R5 fan-commute suffix table (from reducer.md)
// new_rep0  ← parent.lo ++ 0b00
// new_fan0  ← parent.lo ++ 0b01
// new_rep1  ← parent.lo ++ 0b10
// new_fan1  ← parent.lo ++ 0b11
fn lo_extend(lo: LOPath4, bit: u32) -> LOPath4 {
    // Shift the 4-limb bitstring left by 1, insert bit at position lo_len
    // lo_len < 128 here = GPU hot-limb subset only (full LOPath cap is 384, see lopath.md);
    // deeper paths never reach the GPU (coordinator filters depth>128 → CPU fallback).
    // lo_len fits in u8 stored as u32 in GpuActivePair
    ...
}
```

---

## CPU↔GPU Epoch and ABA Safety

GPU does NOT read or write `slot.generation` or `slot.epoch`.
All epoch/ABA management is CPU-only:

1. CPU validates `gen_low` parity before uploading pair to GPU input buffer.
   (Stale pair detected before dispatch → dropped, not uploaded.)
2. GPU fires rule on arena slots; writes new slots into pre-reserved range.
3. CPU reads back output; increments `slot.generation` for retired input slots.
4. CPU bumps global epoch after full merge.

GPU sees arena as a plain flat `array<u32>`. No generation field reads on GPU.
Pre-reserved output range is never concurrently written by CPU → no ABA possible.

---

## GpuScheduler Interface


Phase2 (C4) and C1 use the SAME code as `SequentialScheduler` — no GPU involvement.
`normalize_gpu` calls into `dnx-sched`'s `sequential::c4_phase` and `sequential::c1_sweep`.

---

## Amdahl ceiling and benchmark discipline

**Amdahl ceiling**: only R1–R7 fire on GPU; C1–C4 run on CPU coordinator (C4 is inherently sequential — each step reduces rep-to-Abs distance by 1; C1 is a global mark-sweep). For nets where C-phase is a large fraction of total work, GPU speedup is bounded regardless of R-phase parallelism. The R-phase vs C-phase time split on real programs must be measured before any speedup claim is credible.

**Amortized multi-step loop as default**: single-round dispatch (upload batch → kernel → readback → apply C-rules → repeat) has a PCIe round-trip cost per batch. For real programs this dominates the kernel time. The multi-step ping-pong loop (dispatch N_STEPS interactions per launch via indirect dispatch, staying on GPU until a C-rule trigger or termination) is the design for real end-to-end performance. The single-round path is a correctness baseline and microbench tool, not the production path.

**Credible benchmark framing**: a synthetic max-width antichain (N disjoint independent pairs) shows peak parallel throughput but does not represent real programs where inter-dependent chains limit width. Credible end-to-end numbers require: (a) real program with inherent parallel structure, (b) comparison to sequential baseline on the SAME hardware (not a different evaluator's published numbers), (c) report total wall-clock including all host encode/decode/merge, not just kernel+PCIe. The speedup figure only means something when the absolute baseline is strong.

**Incremental arena sync**: current design re-uploads the entire arena per round. For multi-step loops the dominant cost shifts to PCIe bandwidth. Design: track dirty slots (writes since last upload), upload only deltas. This is the single optimization with highest impact on real end-to-end GPU timing.

---

## Arena Sync Strategy

Full arena upload (N slots × 32B) = 32MB for 1M agents. Too large for every batch.
Strategy: dirty-page tracking. CPU marks slot indices written since last GPU sync.
Before dispatch: upload only dirty slots (`queue.write_buffer` for each dirty range).
After batch: GPU output slots are new — CPU commits them to CPU arena + marks clean.

This keeps GPU arena in sync without full-arena copy per batch.
On first call: full upload. Thereafter: incremental dirty-page sync.

---

## Subgroup Ops (Optional, Feature-Gated)

WGSL `subgroupShuffleXor` for intra-warp output redistribution (interaction net precedent):
balance output pair counts between threads in same subgroup before writing to out_pairs.
This reduces per-thread output buffer waste.

Gated behind `wgpu::Features::SUBGROUP_COMPUTE`. Fallback: no redistribution; each thread
writes independently. Correctness identical; throughput slightly lower without subgroup ops.

---

## Correctness Properties Preserved on GPU

| Property | Guarantee |
|---|---|
| Confluence | GPU thread order non-deterministic; batch = antichain = disjoint regions; rules commute; result identical every run |
| Optimality | Disjoint regions → no GPU thread erases another's work → every thread's rule is necessary |
| Max parallelism | Entire frontier1 dispatched at once; GPU threads = active pairs; wall-clock = max(rule latency) |
| No wasted cycles | Antichain guarantee → no thread is a no-op due to a conflict with another thread |
| CPU/GPU parity | GPU fires R1-R7 only; C1-C4 on CPU; same Net<Canonical> result as Sequential/ParallelScheduler |

---

## Settled — Do Not Revisit

- GPU crate is `dnx-gpu`, separate from `dnx-sched` ✓
- wgpu is the only GPU abstraction (Metal/Vulkan/DX12; covers everyday laptop iGPU) ✓
- WGSL only (no CUDA, no SPIRV hand-authoring) ✓
- Pre-partitioned output buffer: thread i → out_pairs[i*4..i*4+k]; no Mutex, no atomic insert ✓
- Slot allocation: CPU pre-reserves N×4 slots; GPU uses offset i*4; zero GPU-side atomics for alloc ✓
- LOPath on GPU: 4×u32 limbs; computation purely local per thread; no cross-thread reads ✓
- GPU does not read/write slot.generation or slot.epoch; ABA is CPU-only ✓
- Phase2 (C4) + C1 always on CPU coordinator, reusing SequentialScheduler code ✓
- Arena sync: dirty-page incremental upload (not full 32MB per batch) ✓
- Subgroup ops: feature-gated optional optimization ✓
- TPB = 128 (interaction net GPU precedent) ✓
