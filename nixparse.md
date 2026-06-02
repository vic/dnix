# δ-lang: Nix → dnx AST Translation — SETTLED

## Goal

Translate **Pure Nix subset** directly to `Expr` (dnx AST) — no textual dnx intermediate.

**We do NOT implement a parser.** `rnix` handles all source→AST. We only implement
the `rnix::Expr → dnx::Ast` translation pass.

See **`ast.md`** for full `dnx::Ast` + `PrimValue` definitions.

Key points for this doc:
- `Ast::Lit(PrimValue)` carries integer/float/str/bool/null/path literals
- PrimFun refs (`prim_select` etc.) = `Ast::Name("prim_select")` → PrimTable in elaborator Pass 0
- Empty list/attrset = `Ast::Lit(PrimNix::List(vec![]))` / `Ast::Lit(PrimNix::AttrSet(vec![]))`

Round-trip validation (non-evaluating — NO elaboration, NO reduction):
```
Nix source: &str
  ↓ rnix::Root::parse(src).tree()
  ast::Root / ast::Expr    ← lossless rowan CST; whitespace+comments preserved
  ↓ nix_to_expr(scope)     ← THIS DOCUMENT
  dnx::Ast               ← dnx AST (no text intermediate)
  ↓ expr_to_nix()          ← inverse; structural only
  Nix expr text
```

Round-trip: `expr_to_nix(nix_to_expr(e))` yields Nix α-equivalent to `e` (modulo desugaring).
NOT identity: sugar (let/with/inherit) desugared and does not survive.
NOT evaluation: no Net construction, no normalize(), no psi_native().

---

## rnix API Reference (what we use)


---

## Scope

### In scope (Pure Nix subset)

| Nix construct | Maps to |
|---------------|---------|
| `x: body` (IdentParam) | `abs x . body` |
| `{ a, b ? d }: body` (Pattern) | desugared abs (see §Patterns) |
| `f arg` | `f arg` (App) |
| `let x = e; in body` | desugared (see §Let) |
| `let { ... }` (LegacyLet) | same as let-in after desugaring |
| `x` (Ident, bound) | wire |
| `true` / `false` (Ident) | Church lambda `abs t. abs e. t` / `abs t. abs e. e` (§Booleans, nix.md) — NO `Lit(Bool)` |
| `null` (Ident) | `Lit(Null)` |
| `x` (Ident, free — not in any scope) | Free slot (open term; valid) |
| `if c then t else f` | `App(App(c, t), f)` — native `if c t e ≡ c t e` (§Booleans); NO `prim_if` |
| `rec { ... }` | `fix (abs self . …)` (see §RecAttrSet) |
| `{ k = v; … }` (AttrSet, non-rec) | `Lit(AttrSet([]))` + `prim_insert` fold |
| `e.key` (static key) | `prim_select e "key"` |
| `e.key or default` | `prim_select_or e "key" default` |
| `e.${dyn}` (dynamic key) | `prim_select_dyn e dyn` |
| `e ? key` | `prim_has_attr e "key"` |
| `with e; body` | desugared (see §With) |
| `inherit` / `inherit (e)` | desugared (see §Inherit) |
| `assert cond; body` | `if cond body (Throw "assertion failed")` = `App(App(cond, body), Throw(..))` (§Booleans) |
| Integer / Float | `Lit(Int(n))` / `Lit(Float(f))` |
| Uri literal (`http://..`) | `Lit(Str(uri_text))` — Uri deprecated, treated as string |
| `"…"` / `''…''` (Str, no interpol) | `Lit(Str(..))` |
| `"…${e}…"` (Str, interpolated) | `prim_str_concat` chain |
| Path (TOKEN_PATH, no interpol) | `Lit(Path(..))` |
| Path with `${e}` | `prim_path_concat` chain |
| `[ e1 e2 … ]` | `prim_list_cons` chain |
| `e1 // e2` | `prim_update e1 e2` |
| `e1 ++ e2` | `prim_list_concat e1 e2` |
| `+` `-` `*` `/` `==` `<` etc. | PrimFun (see §Primitives); comparisons EMIT Church-bool nets |
| `a && b` / `a \|\| b` | `if a b false` / `if a true b` — native if-desugar (§Booleans), NOT prims |
| `!a` / `a -> b` | `if a false true` / `if a b true` — native if-desugar (§Booleans), NOT prims |
| `builtins.X` (Select on Ident "builtins") | PrimFun from registry |

### Out of scope (translation error)

| Nix construct | Error |
|---------------|-------|
| `import e` | `NixError::ImportUnsupported` |
| `derivation { … }` | `NixError::DerivationUnsupported` |
| `builtins.fetchurl` / impure builtins | `NixError::ImpureBuiltin(name)` |
| `<nixpkgs>` (angle path) | `NixError::StorePath` |
| Mutual recursion in `let` | `NixError::MutualRecursion(names)` (Phase A) |
| `with e;` where keyspace unknown statically | `NixError::DynamicWith` |
| `ast::Error` node | `NixError::ParseError` |

---

## Core Translation: `nix_to_expr`

**Notation shorthand** used in this section:
`Lit(X)` = `Ast::Lit(PrimValue::X)` — e.g. `Lit(Str("foo"))` = `Ast::Lit(PrimValue::Str("foo".into()))`.

```
nix_to_expr : ast::Expr → Scope → Result<dnx::Ast, NixError>
Scope = {
  bound: HashSet<Name>,     // lambda/let-bound names in current scope
  // with-desugared names substituted at desugar time; no runtime stack needed
}
```

Usage analysis (rep/era insertion) performed as **pre-pass** before translation;
result stored in `UsageMap: HashMap<Name, usize>` keyed by binding site.

### Ident

```
nix_to_expr(Ident("true"))  = abs t. abs e. t   -- Church bool (§Booleans, nix.md); NO Lit(Bool)
nix_to_expr(Ident("false")) = abs t. abs e. e   -- Church bool
nix_to_expr(Ident("null"))  = Lit(Null)
nix_to_expr(Ident(x))       = x     -- wire (if lambda/let-bound) or Free slot (open term)
```

`true`, `false`, `null` are `TOKEN_IDENT` in rnix — special-cased before scope lookup.

### Lambda — IdentParam

```
nix_to_expr(Lambda { param: IdentParam(x), body: e }) =
  usage_wrap(x, e, abs x . nix_to_expr(e))
```

`usage_wrap` inserts `rep` / `era` based on usage count (see §UsageAnalysis).

### Lambda — Pattern (destructuring)

See §Patterns for full desugaring. Short form:

```
{ a, b ? d, ... }: body
```
→
```
abs __pat .
  <rep __pat for each use in selects + body>
  (abs a . abs b . nix_to_expr(body))
    (prim_select __pat_1 "a")
    (prim_select_or __pat_2 "b" nix_to_expr(d))
```

### Application

```
nix_to_expr(Apply { lambda: f, argument: a }) =
  nix_to_expr(f)  nix_to_expr(a)
```

Left-associative (rnix already encodes this as nested Apply nodes).

### If-Then-Else

```
nix_to_expr(IfElse { condition: c, body: t, else_body: f }) =
  App(App(nix_to_expr(c), nix_to_expr(t)), nix_to_expr(f))   -- native: if c t e ≡ c t e
```

Native Church-bool `if` (§Booleans, nix.md) — NO `prim_if`. Strict on condition (`c` is
forced to a Church-bool head λt.λe.·), lazy on branches: the untaken branch lands on an
eraser via LO-optimality and never enters an active redex — net structure gives laziness for free.

### Literals

```
nix_to_expr(Literal(lit)):
  match lit.kind():
    LiteralKind::Integer(i) → Lit(Int(i.value()?))
    LiteralKind::Float(f)   → Lit(Float(f.value()?))
    LiteralKind::Uri(u)     → Lit(Str(u.syntax().text().to_string()))
    // Uri deprecated in Nix; treated as plain string
```

### String

No interpolation:
```
nix_to_expr(Str) where normalized_parts = [Literal(s)] =
  Lit(Str(s))
```

With interpolation `"prefix ${e} suffix"`:
```
prim_str_concat
  (prim_str_concat
    (Lit(Str("prefix")))
    (prim_to_str (nix_to_expr(e))))
  (Lit(Str(" suffix")))
```

Walk `normalized_parts()`: fold `prim_str_concat` left-to-right.
`Literal(s)` → `Lit(Str(s))`, `Interpolation(i)` → `prim_to_str(nix_to_expr(i.expr().unwrap()))`.

### Path

No interpolation (`parts()` = single Literal): `Lit(Path(path_content.syntax().text().to_string()))`.
With `${e}` parts: fold `prim_path_concat` left-to-right over parts.
`InterpolPart::Literal(pc)` → `Lit(Path(pc.syntax().text()))`;
`InterpolPart::Interpolation(i)` → `prim_to_str(nix_to_expr(i.expr().unwrap()))`.

### Attribute Set (non-rec)

`{ k1 = v1; k2 = v2; inherit x y; inherit (e) a b; … }`

Desugar inherits first (see §Inherit), then:
```
entries folded left into Lit(AttrSet({})):
  prim_insert "k1" nix_to_expr(v1)
    (prim_insert "k2" nix_to_expr(v2)
      Lit(AttrSet({})))
```

Dynamic key `${e} = v` → `prim_insert_dyn (nix_to_expr(e)) (nix_to_expr(v)) acc`.

AttrSet linearity: each `prim_insert` call takes the accumulator as linear argument.

### Select

Static key:
```
nix_to_expr(Select { expr: e, attrpath: [k], default_expr: None }) =
  prim_select  nix_to_expr(e)  (Lit(Str(k)))

nix_to_expr(Select { … , default_expr: Some(d) }) =
  prim_select_or  nix_to_expr(e)  (Lit(Str(k)))  nix_to_expr(d)
```

Multi-segment `e.a.b.c` → chained selects (left-to-right):
```
prim_select (prim_select (nix_to_expr(e)) "a") "b") "c"
```

Dynamic key `e.${dyn}` → `prim_select_dyn (nix_to_expr(e)) (nix_to_expr(dyn))`.

`Attr` variants in `Attrpath`:
- `Attr::Ident(i)` → static string key `Lit(Str(i.ident_token().text()))`
- `Attr::Dynamic(d)` → `nix_to_expr(d.expr())`
- `Attr::Str(s)` → `nix_to_expr(s)` (string expression as key)

### HasAttr

```
nix_to_expr(HasAttr { expr: e, attrpath: [k] }) =
  prim_has_attr  nix_to_expr(e)  (Lit(Str(k)))
```

Multi-segment: fold prim_has_attr checks left-to-right (stops at first missing key).

### List

```
nix_to_expr(List { items: [e1, e2, e3] }) =
  prim_list_cons  nix_to_expr(e1)
    (prim_list_cons  nix_to_expr(e2)
      (prim_list_cons  nix_to_expr(e3)
        Lit(List([]))))
```

Fold right from empty list. Empty list `[]` → `Lit(List([]))`.

### Assert

```
nix_to_expr(Assert { condition: c, body: b }) =
  App(App(nix_to_expr(c), nix_to_expr(b)), Throw("assertion failed"))   -- if c b (throw …); native
```

### Binary / Unary Ops

`BinOp { lhs, op, rhs }` → `prim_<op>  nix_to_expr(lhs)  nix_to_expr(rhs)` — EXCEPT logic ops
(`&&`/`||`/`->`), which are native if-desugar, NOT prims (§Booleans).

| `BinOpKind` | Maps to |
|-------------|---------|
| Add/Sub/Mul/Div | prim_add/sub/mul/div |
| Equal/NotEqual | prim_eq/ne (EMIT Church-bool) |
| Less/LessOrEq/More/MoreOrEq | prim_lt/le/gt/ge (EMIT Church-bool) |
| And `&&` | `if lhs rhs false` = `App(App(lhs, rhs), FALSE)` — native (§Booleans) |
| Or `\|\|` | `if lhs true rhs` = `App(App(lhs, TRUE), rhs)` — native |
| Implication `->` | `if lhs rhs true` = `App(App(lhs, rhs), TRUE)` — native |
| Concat | prim_list_concat |
| Update | prim_update |
| PipeRight (`\|>`) | desugar: `e1 \|> e2` → App(e2, e1) — no PrimFun |
| PipeLeft (`<\|`) | desugar: `e1 <\| e2` → App(e1, e2) — no PrimFun |

`UnaryOp` Invert (`!a`) → `if a false true` = `App(App(a, FALSE), TRUE)` — native (§Booleans);
Negate (`-a`) → `prim_neg`. (`TRUE` = `abs t.abs e.t`, `FALSE` = `abs t.abs e.e`.)

### Paren

```
nix_to_expr(Paren { inner }) = nix_to_expr(inner)
```

---

## Usage Analysis (Rep/Era Insertion)

**Pre-pass**: bottom-up walk of the expression tree to count occurrences of each
lambda-bound variable in the body where it is bound.

```
count_uses(expr, name) -> usize
  // count syntactic occurrences of `name` as free variable in `expr`
  // excludes re-bound shadowed occurrences
```

After counting, wrap each lambda body at binding introduction point:

```
usage_wrap(name, count, body_expr) =
  | 0 → era <body_expr_no_name> in body_expr  // name not in body
  | 1 → body_expr                              // direct wire
  | n → rep_chain(name, n, body_expr)          // chain of n-1 reps
```

### Rep chain (n uses → n-1 rep nodes, left-linear)

For `name` with 3 uses `n1, n2, n3` in body:
```
rep name as (n_a, n_rest) in
  rep n_rest as (n2, n3) in
  body[name ← n_a, uses already substituted]
```

Each `rep x as (a, b) in body` = one sharing split.
`n` uses → n−1 splits. Left-linear: leftmost use gets the `a` wire at each level.

### Where insertion happens

For `abs x . body`:
1. Count uses of `x` in `body`
2. Emit `abs x . usage_wrap(x, count, translated_body)`

For `rep e as (a, b) in body`: `a`, `b` each must be used exactly once (dnx linearity).
Usage analysis on body of `rep` must confirm each binding used once.

For pattern lambdas: count uses of each pattern variable in body separately.

---

## Let Binding Desugaring

All Nix `let` is recursive (bindings see each other and themselves).

### Single non-recursive binding

Detected by: `x ∉ FV(rhs)` and no other binding in the group references `x` recursively.

```
let x = rhs; in body
```
→
```
(abs x . usage_wrap(x, count_body, nix_to_expr(body)))
  (nix_to_expr(rhs))
```

= `(abs x . body') rhs`

### Single self-recursive binding

Detected by: `x ∈ FV(rhs)`.

```
let x = rhs[x]; in body
```
→
```
(abs x . usage_wrap(x, count_body, nix_to_expr(body)))
  (fix (abs x . usage_wrap(x, count_rhs, nix_to_expr(rhs))))
```

### Multiple bindings — topological sort

1. Build dependency graph: edge `xi → xj` if `xj ∈ FV(rhs_i)`
2. Topological sort of SCCs (Tarjan/Kosaraju)
3. Non-recursive SCC (single node, no self-edge): emit as non-recursive single binding
4. Self-recursive SCC (single node, self-edge): emit as single fix
5. Mutually recursive SCC (multiple nodes): `NixError::MutualRecursion(names)` Phase A

Emit binding groups in topo-order (inner first, outer last):
```
let a = 1; b = a + 1; c = b + 1; in c
```
→ topo-sort: a, then b, then c →
```
(abs a .
  (abs b .
    (abs c . c)
    (prim_add b 1))
  (prim_add a 1))
1
```

### `let { … }` (LegacyLet)

`let { body = e; x = v; }` ≡ `let x = v; in e` with implicit `body` binding.
Desugar: find `body` key → use as `in` expression; remaining keys are bindings.
Then apply same algorithm as let-in.

---

## Inherit Desugaring

Performed as part of let/attrset entry processing, before translation.

### `inherit x y z;` (no source)

In let binding context: `x = x; y = y; z = z;` — references current scope variables.
In attrset context: same.

### `inherit (e) x y z;`

`x = e.x; y = e.y; z = e.z;`

If `e` is used multiple times: rep chain over `e_translated`.
```
rep e_t as (e1, e2) in
  ...
  { x = prim_select e1 "x"; y = prim_select e2 "y"; }
```

Count uses = number of inherited names from `e`.

---

## With Desugaring

`with e; body` — identifiers in `body` not bound in current scope may come from `e`.

**Algorithm** (static scope analysis):
1. Compute `FV(body)` relative to current scope (names used but not bound)
2. For each free var `k` in `FV(body)`: replace occurrence of `k` in body with
   `prim_select __ns_k "k"` where `__ns_k` is a fresh linear copy of the namespace
3. Bind namespace: `(abs __ns . <substituted_body>) (nix_to_expr(e))`
4. Each `__ns_k` is one rep-split of `__ns`

```
with { x = 1; y = 2; }; x + y
```
FV = {x, y} → 2 uses of namespace →

```
(abs __ns .
  rep __ns as (__ns1, __ns2) in
  prim_add (prim_select __ns1 "x") (prim_select __ns2 "y"))
(Lit(AttrSet({x=Lit(Int(1)), y=Lit(Int(2))})))
```

**Phase A restriction**: `FV(body)` must be determinable statically.
This requires that all enclosing `with`s resolve before inner ones (shadowing).
If a name is in scope as a lambda-bound variable, it shadows the `with` namespace.
If `e` is a computation (not literal), we cannot know its keys → `NixError::DynamicWith`.

Phase A: only allow `with` where namespace `e` is a literal attrset or a name bound
to a literal attrset in enclosing let/lambda scope.

---

## Recursive AttrSet

`rec { x = f x; y = g y x; }` — all bindings visible to each other.

Same algorithm as self/mutually-recursive let:
1. Treat each `key = value` as a binding
2. Topo-sort; if mutually recursive → `NixError::MutualRecursion` Phase A
3. Self-recursive or non-recursive groups: emit with fix or direct

Self-recursive single binding `rec { x = f x; }`:
```
prim_mk_singleton "x" (fix (abs x . nix_to_expr(f x)))
```

Non-recursive `rec { a = 1; b = a + 1; }` — treat exactly like non-rec attrset
(topo-sort shows no cycles, just ordered dependency).

---

## Lambda Patterns

`{ a, b ? da, c ? dc, ... }@name: body`

Desugaring steps:
1. Intro fresh `__pat` binding
2. Bind `@name` alias if present: `rep __pat as (name, __pat2) in …`
3. For each `PatEntry(k, default_opt)`:
   - Without default: `prim_select __pat_n "k"` → binds `k`
   - With default: `App(App(prim_has_attr __pat_n "k", prim_select __pat_n2 "k"), nix_to_expr(default))` → binds `k` (native if; `has_attr` EMITs a Church-bool)
   (needs 2 copies of `__pat_n` for has_attr + select check → 1 extra rep)
4. With ellipsis `...`: no extra check
5. Without ellipsis: add `App(App(prim_keys_eq (prim_keys __pat_n) known_keys_list, body), Throw("unexpected argument"))` (native assert)

Full translation of `{ a, b ? db }: body`:
```
abs __pat .
  rep __pat as (__pat_a, __pat_b_check) in
  rep __pat_b_check as (__pat_b_has, __pat_b_sel) in
  (abs a . abs b . nix_to_expr(body))
    (prim_select __pat_a "a")
    (App(App
      (prim_has_attr __pat_b_has "b")    -- Church-bool
      (prim_select __pat_b_sel "b"))
      (nix_to_expr(db))))                -- native if: has_attr ? sel : db
```

For `@name` (accessed via `pattern.pat_bind().unwrap().ident()`):
```
abs __pat .
  rep __pat as (name, __pat2) in
  … rest uses __pat2 for selects …
```

---

## Primitives Table

All PrimFun are curried single-argument (per settled/primitives.md).

| PrimFun | Arity | Nix source |
|---------|-------|------------|
| _(native, not a prim)_ | — | `if`/`assert`/`&&`/`\|\|`/`!`/`->` → Church-bool if-desugar (§Booleans) |
| `prim_select` | 2 | `e.key` |
| `prim_select_or` | 3 | `e.key or default` |
| `prim_select_dyn` | 2 | `e.${dyn}` |
| `prim_has_attr` | 2 | `e ? key` |
| `prim_insert` | 3 | attrset key insertion |
| `prim_insert_dyn` | 3 | `{ ${e} = v; }` |
| `prim_mk_singleton` | 2 | single-key attrset |
| `prim_update` | 2 | `e1 // e2` |
| `prim_keys` | 1 | enumerate attrset keys |
| `prim_keys_eq` | 2 | pattern exhaustiveness |
| `prim_list_cons` | 2 | list construction `[e …]` |
| `prim_list_concat` | 2 | `e1 ++ e2` |
| `prim_str_concat` | 2 | string join |
| `prim_to_str` | 1 | coerce to string |
| `prim_path_concat` | 2 | path interpolation |
| `prim_add/sub/mul/div` | 2 | `+ - * /` |
| `prim_eq/ne/lt/le/gt/ge` | 2 | `== != < <= > >=` (EMIT Church-bool) |
| `prim_neg` | 1 | unary `-` |
| `builtins.X` | varies | looked up in PrimFun registry |

PrimFun partial application: `prim_select_or e` → new PrimFun(arity=2) carrying `e`.
Applied again → PrimFun(arity=1). Final application → fires prim_apply rule.

---

## Error Cases

| Error | Trigger |
|-------|---------|
| `NixError::ParseError(e)` | `parse.errors()` non-empty |
| (no error) | Ident not in any scope → `dnx::Ast::Name(x)` → Free slot (open term) |
| `NixError::MutualRecursion(names)` | Mutually recursive SCC in let/rec-attrset |
| `NixError::DynamicWith` | `with e;` where `e` keyspace unknown statically |
| `NixError::DynamicAttrKey` | Lhs of attrset binding is purely dynamic (Phase A) |
| `NixError::ImportUnsupported` | `import` expression |
| `NixError::DerivationUnsupported` | `derivation` identifier |
| `NixError::ImpureBuiltin(name)` | `builtins.currentSystem` etc. |
| `NixError::StorePath` | `<nixpkgs>` angle-path |
| `NixError::LegacyLetNoBody` | `let { … }` missing `body` binding |

---

## Round-Trip Contract

Non-evaluating: parse → dnx::Ast → Nix text. No Net, no reduction.

**Scope**: Fix-free programs only. Self-recursive `let`/`rec {}` desugar to `Ast::Fix`;
`expr_to_nix(Fix(e))` emits a Nix Y-combinator form that `nix_to_expr` does NOT
re-parse as `Ast::Fix` (it parses as a regular let-with-Y-comb application).
Round-trip is intentionally not tested for Fix-containing programs.


### What is preserved

- Structure: every construct maps to dnx::Ast and back structurally
- α-equivalence of bound variable names
- PrimNix identity (Int/Float/Str/Bool/Null/Path values round-trip exactly)

### What is NOT preserved

- Syntactic sugar (let/with/inherit → desugared; does not survive)
- Original variable names (α-renamed for freshness in expr_to_nix)
- Comments/whitespace (rowan CST lossless on input; expr_to_nix emits fresh text)

---

## Implementation Notes

### Crate: `dnx-lang`

Dependencies: `rnix` (nix-community/rnix-parser), `dnx-core`.
No dependency on `dnx-elab` — this crate does NOT elaborate or reduce.

### File structure

```
  lib.rs           -- nix_to_expr entry point
  scope.rs         -- Scope + FreeVarSet tracking
  usage.rs         -- count_uses pre-pass + usage_wrap
  desugar/
    let.rs          -- let-in + legacy-let desugaring
    with.rs         -- with desugaring (static scope analysis)
    inherit.rs      -- inherit desugaring
    pattern.rs      -- pattern lambda desugaring
    rec_attrset.rs  -- rec { } → fix
  emit.rs          -- expr_to_nix: dnx::Ast → Nix text (structural α-equiv; no eval)
  prim.rs          -- PrimFun registry + builtin name table
  error.rs         -- NixError enum
```

### `nix_to_expr` signature


`Scope` tracks: `bound: HashSet<Name>` (lambda/let-bound).
`with` desugaring substitutes free-var references inline (no runtime `with_ns`).
Names not in `bound` after all desugaring → `dnx::Ast::Name(x)` → Free slot in elaborator.

### `expr_to_nix` — inverse


Structural inverse of `nix_to_expr`. No Net, no reduction. Pure AST→text.

| `dnx::Ast` variant | Nix output |
|--------------------|------------|
| `Name(x)` | `x` (identifier) |
| `Abs(x, body)` | `x: expr_to_nix(body)` |
| `App(f, a)` | `(expr_to_nix(f)) (expr_to_nix(a))` |
| `Rep(e, a, b, body)` | no Nix surface; emit as let: `let ${a} = expr_to_nix(e); ${b} = ${a}; in expr_to_nix(body)` — α only |
| `Era(e, body)` | no Nix surface; emit `let _ = expr_to_nix(e); in expr_to_nix(body)` — structural only |
| `Fix(e)` | no Nix surface; emit `let __fix = f: (x: f (x x)) (x: f (x x)); in __fix (expr_to_nix(e))` |
| `Lit(Int(n))` | `n` |
| `Lit(Float(f))` | `f` (decimal notation) |
| `Lit(Str(s))` | `"s"` (escaped) |
| Church-bool Abs `λt.λe.t` | `true` (shape recognizer; §Booleans) |
| Church-bool Abs `λt.λe.e` | `false` (shape recognizer) |
| `Lit(Null)` | `null` |
| `Lit(Path(p))` | `p` |
| `Lit(List([]))` | `[]` |
| `Lit(AttrSet([]))` | `{}` |

**Rep/Era/Fix have no Nix surface syntax** — desugared forms emitted for structural round-trip only.
α-equivalence only: variable names may differ from source.

---

## Invariants (enforced at translation)

| Invariant | Enforcement |
|-----------|-------------|
| Every lambda-bound var used exactly once in translated dnx::Ast | usage_wrap pre-pass |
| `true`/`false` → Church lambda, `null` → PrimNix; never wire | ident special-case first |
| `inherit (e)` desugared before attrset/let translation | desugar pass |
| All Pattern lambdas desugared to IdentParam abs chain | desugar pass |
| No `import`/`derivation`/angle-path survives | hard error at encountered node |
| All Attrpath multi-segment selects folded to chain | single-pass fold |
| `rec {}` with mutual recursion is an error Phase A | topo-sort + NixError |
| `with` only for statically-known keyspace Phase A | scope analysis guard |

---

## Settled — Do Not Revisit

- No parser implementation: `rnix::Root::parse` does all parsing
- No LambdaIR intermediate: rnix `ast::Expr` → `dnx::Ast` directly
- `true`/`false`/`null` = `TOKEN_IDENT` in rnix → special-case before scope lookup; `true`/`false` → Church lambda (`λt.λe.t` / `λt.λe.e`, §Booleans), `null` → `Lit(Null)`
- `ast::Literal::kind()` = only Float/Integer/Uri (NOT bool/null/string/path)
- Strings: `ast::Str::normalized_parts()` → `Vec<InterpolPart<String>>`
- Let: topo-sort SCCs; non-rec → nested abs; self-rec → fix; mutual → NixError Phase A
- With: static scope analysis; FV(body) → prim_select substitutions; dynamic → NixError
- Pattern: desugar to abs __pat + rep chain + prim_select/prim_select_or per entry
- Rep/era: pre-pass count_uses, then usage_wrap wraps each lambda body
- Round-trip: nix_to_expr → expr_to_nix; structural α-equiv only; NO elaborate/normalize/psi_native
- dnx::Ast + PrimNix: see ast.md; Lit(PrimNix) for literals; PrimFun refs = Ast::Name → PrimTable in Pass 0
- expr_to_nix: structural AST→text; Rep/Era/Fix no Nix surface → let/__fix forms; α-equiv only
- Round-trip Fix-free only: Fix→Y-comb Nix→nix_to_expr gives different AST; skip Fix programs in test
- Pattern @name: Pattern::pat_bind() → PatBind::ident(); PatEntry::default() → Option<Expr>
- Free vars (unbound idents after all desugaring) → Free slots; valid open terms; NOT errors
- if/assert/&&/||/!/-> = native Church-bool if-desugar (NOT prims); `if c t e ≡ App(App(c,t),e)`; untaken branch lands on an eraser via LO-optimality → never reduced (lazy, NO thunk wrapping). See nix.md §Booleans.
- PipeRight/PipeLeft: desugar to App (no PrimFun); `e1 |> e2` = App(e2,e1); `e1 <| e2` = App(e1,e2)
- ast::Path::parts() → InterpolPart<PathContent>; PathContent.syntax().text() for raw segment
- ast::LegacyLet: HasEntry trait → entries()/attrpath_values()/inherits(); find body by attrpath=="body"
- Scope = {bound: HashSet<Name>} only; with-desugaring substitutes inline, no with_ns stack
