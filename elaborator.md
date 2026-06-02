# δ-lang: Elaborator Design — SETTLED

## Pipeline

```
Source AST (LambdaAst — from frontend; includes Ann/Perform/Handle)
  ↓ Pass 0: def resolution + fix desugar + Ann strip
Resolved AST (no def refs, no fix nodes, no Ann wrappers)
  ↓ Pass 1: linear check + usage_level collection + NetClass flags
(usage_levels: HashMap<Name, u32>, net_flags_bits: u8)
  ↓ Pass 2: net emission
Net<Proper, C>           -- C determined by era_used/rep_used
```

Pass 0.5 (System F + effect rows type inference) is **deferred** — not needed for
net correctness. Tier 2 effects elaborate to pure λ-terms; Tier 1 effects use D8
`validate_handlers` at runtime. See Open Items.

### NetClass — 2-bit static ΔS classification (packed into net_flags / root PortId)

No separate struct or allocation. Two bits computed in Pass 1:
- `bit0 = has_era` (any `era` in source → weakening)
- `bit1 = has_rep` (any `rep` or `fix` in source → contraction)

Stored zero-waste in two places:
- **Whole-net**: `net_flags bits[1..0]` on `Net<S, C>` (shared byte with `pending_c1` in bit[2])
- **Per-def**: `bits[15..14]` of the def's Free Slot `data` field (bits[13..0] = var_id ≤ 16383; `LinError::TooManyFreeVars` if exceeded). PortId bits[3..2] = port_kind = always 00 = never touched.

```
L = 0b00  ΔL linear:   no era, no rep → R4 only, zero C-rules
A = 0b01  ΔA affine:   era only       → R4+R2 + C1
I = 0b10  ΔI relevant: rep only       → R4-R7 + C2+C4 (no C1/C3)
K = 0b11  ΔK full:     era + rep      → all rules
```


**Per-def class enables per-shard C-rule skipping** in Phase C parallel runtime:
workers query `def_class(their root PortId)` rather than whole-net union.

---

## Pass 0 — Def Resolution

- Build def dependency graph; topological sort
- Cycle without `fix` → error: `LinError::MutualRecursion(names)`
- `fix e` → desugar to Y-net AST (macro expand before any analysis):
  ```
  fix e  ≡  (abs f .
               rep (abs x . rep x as (x0,x1) in f (x0 x1)) as (m,m') in
               m m') e
  ```
  `f` fresh name. `f` used once inside inner abs (linear ✓). R5 handles runtime replication.
- Def ref → copy def's AST at call site (fresh instantiation; not sharing)
- Primitives (mul, pred, etc.) → PrimFun agent per reference; NOT in linear scope

**Rationale**: def names = templates. Each call = independent net copy. `rep` = share
a computed value (single node). Semantically distinct. Paper: interior sharing via
replicators = for sharing computed values, not function definitions.

---

## Pass 1 — Linear Check + Usage Level Collection

Two maps, separate concerns:
- `counts: Vec<HashMap<Name, u32>>` — count per binder (linear checking only)
- `usage_levels: HashMap<Name, u32>` — use-site level per name (Pass 2 delta source)

```
collect(level: u32, counts: &mut ScopeStack, usage_levels: &mut HashMap<Name,u32>, expr):

  abs x . body:
    counts.push(x → 0)
    collect(level, counts, usage_levels, body)
    n = counts.pop(x)
    if n == 0 → LinError::Unused(x)
    if n > 1  → LinError::MultiUse(x, n)

  e1 e2:
    collect(level,     counts, usage_levels, e1)   -- func: same level
    collect(level + 1, counts, usage_levels, e2)   -- arg: level + 1

  rep e as (a, b) in body:
    rep_used = true                             -- ← sets NetClass bit1
    collect(level, counts, usage_levels, e)
    counts.push(a → 0)
    counts.push(b → 0)
    collect(level, counts, usage_levels, body)
    -- usage_levels[a], usage_levels[b] filled at leaf visits in body
    if counts.pop(a) != 1 → LinError
    if counts.pop(b) != 1 → LinError

  era e in body:
    era_used = true                             -- ← sets NetClass bit0
    collect(level, counts, usage_levels, e)
    collect(level, counts, usage_levels, body)

  name:
    counts.increment(name)
    usage_levels[name] = level      -- use-site level for Pass 2 delta computation
```

Level NOT stored in counts. Def names absent from counts (resolved in Pass 0).

**Pass 1 output**: `(era_used: bool, rep_used: bool)` per def → selects `C` phantom type (ΔL/ΔA/ΔI/ΔK) + packed into `net_flags` bits[1..0] (whole-net OR) and into Free Slot `data` bits[15..14] per def (class = (era_used as u16) | ((rep_used as u16) << 1); PortId bits[3..2] left as 00 = Principal, never touched).

**Type construction**: elaborator produces `Net<Proper, C>` where `C` is known statically. App emission calls `merge_nets` to compute `ClassUnion` when joining two subnets.
`fix e` desugars in Pass 0 to AST with `rep` → always sets `rep_used=true` (NetClass ≥ I).
Primitives (PrimFun/PrimVal) affect neither flag — they are Phase C only, outside the ΔS system.

---

## Pass 2 — Net Emission


### result_level rules

| Construct | result_level |
|-----------|-------------|
| `abs x . body` | `level` (abs.principal at current level) |
| `e1 e2` | `level` (app.aux0 at current level) |
| `rep e as(a,b) in body` | result_level of body |
| `era e in body` | result_level of body (eraser virtual, no level) |
| `name x` | `env[x].1` (stored = abs_level+1 if abs-bound) |
| `perform l e` | `level` (outermost Abs of free monad term) |
| `handle comp with {…}` | `level` (App result of fold term) |

### perform l e → free monad λ-terms

No net agent allocated. Elaborated to pure Abs/App tree:

```
-- perform "l" arg ≡ λpure. λh. h "l" arg (λresult. pure result)
-- Handler receives LABEL first (Str), then arg, then continuation k.
-- Label is required for multi-branch dispatch (effects-and-handlers.md D10).

fresh pure_var, handler_var, result_var

elaborate(Ast::Perform(l, arg)) =
  elaborate(
    Abs(pure_var,
      Abs(handler_var,
        App(App(App(Name(handler_var), Val(Str(l))),
                arg),
            Abs(result_var, App(Name(pure_var), Name(result_var)))))))
```

Variable usage: pure_var, handler_var, result_var each used once → λL-term.
One-shot effects incur zero Rep overhead (φ_L: fans only).

### handle comp with { l x k → body } → free monad fold

No net agent allocated. Elaborated to pure Abs/App tree:

```
-- handle comp with { "l" x k → body }
-- ≡ comp (λr. r) (λlbl. λx. λk. era lbl in body)
--
-- comp receives two args:
--   1) λr.r         — pure return (identity)
--   2) λlbl.λx.λk.era lbl in body — handler (takes label, erases it for single-branch)
-- For multi-branch: dispatcher uses lbl before erasing (effects-and-handlers.md D10).

fresh r_var, lbl_var

elaborate(Ast::Handle(comp, [("l", x, k, body)])) =
  elaborate(
    App(App(comp,
            Abs(r_var, Name(r_var))),          -- pure = identity
        Abs(lbl_var,                           -- receives label Str
          Abs(x,
            Abs(k, Era(Name(lbl_var), body)))))) -- era lbl (unused for single-branch)
```

Variable usage: r_var, lbl_var each used once (linear). x, k linear if body linear.

**Multi-shot handler** (k used 2×): `rep k as (k0,k1) in ...` in body → rep_used=true
→ NetClass ≥ I. Existing R5/R6/R7 handle correctly.

**Abort** (era k): era_used=true → NetClass ≥ A. C1 cleans disconnected subnet.

---

### abs x . body → Abs

```
abs = alloc_abs(net)
env[x] = (abs.aux1, level + 1)
lo_body = lo.extend_left()?
(body_p, _) = elaborate(level, env, lo_body, body)?
connect(net, abs.aux0, body_p, lo_body)?  -- body descends left (collision-free)
return Ok((abs.principal, level))
```

### e1 e2 → App

```
app = alloc_app(net)
(f_p, _) = elaborate(level,     env, lo.extend_left()?,   e1)?
(a_p, _) = elaborate(level + 1, env, lo.extend_right()?,  e2)?
connect(net, app.principal, f_p, lo.extend_left()?)?
connect(net, app.aux1,      a_p, lo.extend_right()?)?
return Ok((app.aux0, level))
```

### rep e as (a,b) in body → RepIn

```
la = usage_levels[a]
lb = usage_levels[b]
(e_p, rep_level) = elaborate(level, env, lo, e)?

d0 = (la as i32) - (rep_level as i32)    -- CAN BE NEGATIVE
d1 = (lb as i32) - (rep_level as i32)
if d0 not in i16::MIN..=i16::MAX → DeltaOverflow
if d1 not in i16::MIN..=i16::MAX → DeltaOverflow

rep = alloc_rep_in(net, rep_level as u16, d0 as i16, d1 as i16)  // rep_level ≤ 513; debug_assert
connect(net, rep.principal, e_p, lo)?
env[a] = (rep.aux0, la)     -- a-wire = aux0
env[b] = (rep.aux1, lb)     -- b-wire = aux1

(body_p, body_level) = elaborate(level, env, lo, body)?
return Ok((body_p, body_level))
```

**rep_level = result_level(e):**
- `e = name x` (abs-bound): rep_level = abs_level+1 → matches φ_K exactly
- `e = complex expr` at level L: rep_level = L (native killer feature; d ≥ 0 here)
- Deltas i16, **CAN BE NEGATIVE**: `abs x . rep x as(a,b) in a b` → rep=1, d0=-1, d1=0

### era e in body → Eraser

```
(e_p, _) = elaborate(level, env, lo, e)?
connect(net, eraser_port(), e_p, lo)?     -- INERT if e_p is aux port; lazy via R4/R5
(body_p, body_level) = elaborate(level, env, lo, body)?
return Ok((body_p, body_level))
```

Eraser = virtual (bit on PortId, no slot). Connects to e's result port. If that port
is AUX (e.g., abs.aux1 for a name), eraser is **inert** — fires lazily when R4
routes it to the argument's principal port.

### name → wire consumption

```
(port, stored_level) = env.remove(name)    -- consume (Pass 1 guarantees presence)
return Ok((port, stored_level))
```

### def root

```
(result_p, _) = elaborate(0, env, LOPath::ROOT, def.expr)?
connect(net, free_slot(def.name), result_p, LOPath::ROOT)?
```

Inlined def refs wire directly into caller's position (Pass 0 copied AST).

---

## LO Path Rules

| Construct | LO assignment |
|-----------|--------------|
| `abs x . body` | body: `lo.extend_left()?` |
| `e1 e2` (func) | `lo.extend_left()?` |
| `e1 e2` (arg) | `lo.extend_right()?` |
| `rep e / era e` | e: same `lo` |

**Why fn-side `extend_left`:** φ assigns *levels* (main.tex:819-820), not LOPaths;
LOPath is our encoding of the leftmost-outermost reduction *order* (main.tex:979)
into the `frontier1` BTreeMap key. The fn and arg children of one App must get
distinct paths (`...0` vs `...1`) or two live active pairs collide on one key and
the second eviction-drops the first. App-fn `extend_left` mirrors App-arg
`extend_right` (R4 cross-wire, lopath.md R4) → collision-free by construction.
| `rep _ in body / era _ in body` | body: same `lo` |

`lo.extend_right()` → promotes hot→warm→cold limb when active limb full (len == 128).
4-limb fixed `{hot,warm,cold,frozen:u128,len:u8}`, max depth 512, zero-alloc (lopath.md).
API transparent to caller: `extend_right()` / `extend_left()` / `is_prefix_of()` same signature.
Reduction rules (R4/R5/R7) use same limb-promotion scheme at runtime.

---

## Net<Proper> Invariants (enforced by Pass 2)

| Invariant | Enforcement |
|-----------|-------------|
| Fan = 2 aux ports | `alloc_abs/app` always 2 |
| Rep = 2 aux ports (fixed) | `alloc_rep_in` always 2; chain for >2 |
| RepKind = RepIn at construction | Pass 2 only allocates RepIn |
| PairedStatus = Unpaired | `alloc_rep_in` sets Unpaired |
| Every port connected before return | Pass 2 connects eagerly |
| Wire polarity: child ↔ parent | Port types enforced by alloc API |

---

## Delta Arithmetic

**Source: main.tex §3 — "d_i = l_i − (l+1)" for abs-bound reps in φ_K translation.**
(Native δ-lang generalizes: d_i = usage_level − rep_level; may be negative for non-φ_K positions)

```
rep_level = result_level returned by elaborate(e)
d_i = (usage_levels[name_i] as i32) - (rep_level as i32)   →  i16
```

| Case | rep_level | d_i |
|------|-----------|-----|
| `abs x . rep x as(a,b) in a b` (abs-bound) | 1 (abs_level+1) | d0=-1, d1=0 |
| `rep id as(a,b) in a b` (top-level, killer feature) | 0 | d0=0, d1=1 |

- Negative when rep-ing abs-bound name: rep_level=abs_level+1 > usage_level
- Non-negative when rep-ing complex expr: rep_level=current_level ≤ usage_levels
- i16 range: -32768..32767; overflow → `DeltaOverflow`
- R7 uses `checked_add` on deltas → `DeltaOverflow` at runtime too
- φ_K equivalence: abs-bound rep → rep_level=abs_level+1 = identical to φ_K

---

## Error Types

| Error | Pass | Cause |
|-------|------|-------|
| `LinError::Unused(name)` | 1 | bound name count == 0 |
| `LinError::MultiUse(name, n)` | 1 | bound name count > 1 |
| `LinError::MutualRecursion(names)` | 0 | def cycle without fix |
| `DnxError::LOPathDepthExceeded` | 2 + runtime | lo.extend at depth 512 (all 4 limbs full) |
| `DnxError::DeltaOverflow` | 2 + runtime | delta outside i16 range |

---

## C1 Status

**C1 still required** for programs using `era`.

`abs x . era x in body` places eraser_bit on Abs.aux1 — identical net structure
to φK implicit erasure. R4 on `(abs x . era x in body)(arg)` routes eraser to arg's
result port. If arg subnet has no live wires back to root (closed value), arg
disconnects. C1 finds and erases it.

Eraser on AUX port = **INERT** (not active pair). Erasure lazy, propagated via R4/R5.
Eraser only fires when it reaches a PRINCIPAL port.

Programs using only `abs`/`app`/`rep` (zero `era`) = ΔI-style → C1 finds nothing.

---

## C2 / C3 / C4 Status

All still needed — arise from R5/R7 dynamics regardless of source language:
- C2: unpaired rep merge (after R5 creates adjacent same-level reps)
- C3: rep decay (rep with all aux ports erased → era on principal)
- C4: aux fan replication (rep.principal ↔ app.aux0, Phase 2 trigger)

---

## Settled — Do Not Revisit

- 3-pass ARCH-A: optimal over single-pass-mutable (ARCH-B) and CPS (ARCH-C)
- Def names = templates (not linear); fresh AST copy per ref; rep = share values
- elaborate() returns (PortId, result_level); rep_level = result_level(e)
- Deltas i16, CAN BE NEGATIVE; φ_K equivalence for abs-bound reps (d_i = l_i−(l+1), main.tex §3)
- LO by construction → ΔA/ΔI/ΔK optimality (main.tex §4)
- C1 skipped when `net.net_flags & 0x04 == 0` (pending_c1 bit clear at runtime); era_used=false → pending_c1 bit never set → skip without runtime check
- C2/C3/C4 always needed (from reduction dynamics)
- Eraser on aux = inert; lazy propagation via R4/R5
- Mutual recursion via fix only; def cycles → LinError::MutualRecursion
- Pass 1 three outputs: counts (linear check) + usage_levels (delta source) + era_used (compile-time C1 guard)
- era_used + pending_c1 two-level C1 guard: era_used=false → skip unconditionally; era_used=true → check pending_c1 at runtime
- LOPath: 512-bit max (hot/warm/cold/frozen: 4×u128 + len:u8); see lopath.md
- PrimFun: opaque native fns; Tier 1 ForeignCall effects via `PrimImpl::Effectful(label)`; NOT in linear scope
- Pass 0.5 (type inference): DEFERRED — not needed for net correctness; see Open Items
- Perform/Handle: Tier 2 algebraic effects; Ast variants elaborate to free monad λ-terms (no new net agents)
- Two-tier effects: Tier1=PrimFun+HandlerEnv (ForeignCall); Tier2=free monad Church encoding (pure Abs/App/Rep/Era)
- psi_native: two-step composition; see readback.md

---

## Open Items

### Pass 0.5 — Type inference (deferred)

System F + effect rows (Koka-style). Would catch unhandled effects statically.
Not needed for net correctness with free monad Tier 2 encoding.
Tier 1 covered by D8 `validate_handlers` at runtime.
Separate sprint. Do not block current implementation on this.
