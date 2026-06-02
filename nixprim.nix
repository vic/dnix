# δ-lang: Pure Nix Primitive Catalogue — SETTLED
#
# SCOPE: Pure Nix subset. No IO, no filesystem, no store, no derivation,
# no import, no getEnv, no currentSystem, no currentTime, no flakes.
#
# GOAL: Enumerate every NixPrimVal and NixPrimFun needed for a delta-net
# based Pure Nix runtime. Each function → one PrimFun agent with fixed arity.
#
# HOW LAZINESS WORKS: Nix thunks = unreduced delta-net terms.
# LO-optimal (outermost-first) reduction = Nix's call-by-need for free.
# No explicit thunk heap needed. Laziness is structural.
#
# HOW OPERATORS WORK: All Nix infix/prefix operators desugar to PrimFun
# calls during nixparse translation pass (nixparse.md). No operator nodes
# in Ast<NixPrimVal, NixPrimFun>.
#
# PRIM_ID ORDERING: Canonical alphabetical sort of names within each
# category block (matches PrimTable in elaborator Pass 0). Do not reorder.
# prim_id = position in the flat sorted list across all categories.

let

  # ── Helper constructors ────────────────────────────────────────────────
  # f  = PrimFun entry: arity + type signature hint + impl note
  # op = infix/prefix operator desugaring rule (no prim_id; compile-time only)

  f = arity: sig: note: { inherit arity sig note; kind = "fun"; };
  op = nix_syntax: desugars_to: args: { inherit nix_syntax desugars_to args; kind = "op"; };
  val = rust_type: nix_types: note: { inherit rust_type nix_types note; kind = "val"; };

in

# ══════════════════════════════════════════════════════════════════════════
# SECTION 1: VALUE TYPES (NixPrimVal variants)
# Stored in Net.prim_vals side table. No principal port. Inert agents.
# ══════════════════════════════════════════════════════════════════════════

{
  values = {
    # Nix type → Rust variant → prim_apply result type
    Int    = val "i64"           ["int"]                  "add/sub/mul/div; bitAnd/Or/Xor; lessThan";
    Float  = val "f64"           ["float"]                "floor/ceil; mixed int+float ops";
    Str    = val "Arc<str>"      ["string"]               "string context DROPPED — pure strings only";
    Null   = val "unit"          ["null"]                 "isNull; == null; toString → empty string";
    Path   = val "Arc<str>"      ["path"]                 "IN SCOPE (D3): path value; pure ops (toString, +); fs reads = Tier-1 effect";
    List   = val "Cons(Term,Term)|Nil" ["list"]           "LAZY SPINE + lazy elements: cons-cell = head Term + tail Term, both unforced. ++/concat/map/filter lazy-spine; head forces 1 cons; length forces whole spine. Infinite lists PRODUCTIVE — dnet BETTER than stock Nix, NO overflow";
    AttrSet= val "Vec<(Arc<str>, Term)>" ["set"]          "LAZY values: (key,Term); getAttr forces selected value; key order=insertion, attrNames sorted";

    # NOTE: Bool is NOT a PrimVal. Booleans are CHURCH-ENCODED native nets (true=λt.λe.t, false=λt.λe.e).
    #   `if c t e` ≡ `c t e` (pure FanApp); comparison/logic prims EMIT a Church-bool net (not a PrimVal).
    #   isBool/typeOf recognize the Church-bool WHNF shape. (Known: untyped true≡K — see nix.md §Booleans.)
    # NOTE: Function type is NOT a PrimVal. Lambda = delta-net FanAbs node.
    # NOTE: Path IN SCOPE (D3) — pure Nix runtime is the project goal. Path VALUES + pure path ops are pure;
    #   builtins that READ the filesystem (readFile, pathExists, …) are Tier-1 effects (nix.md effects module).
    # NOTE: String context = DROPPED. All strings are plain Arc<str>; unsafeDiscardStringContext = no-op.
  };

# ══════════════════════════════════════════════════════════════════════════
# SECTION 2: OPERATOR DESUGARING (compile-time, nixparse.md)
# No prim_ids. These become PrimFun App chains in Ast<NixPrimVal, NixPrimFun>.
# ══════════════════════════════════════════════════════════════════════════

  operators = {
    # Arithmetic
    add_int    = op "e1 + e2 (int)"     "nix_add"        ["e1" "e2"];  # int+int OR float+int etc
    add_str    = op "e1 + e2 (str)"     "nix_str_concat" ["e1" "e2"];  # string concat (NOT +; separate primfun)
    sub        = op "e1 - e2"           "nix_sub"        ["e1" "e2"];
    mul        = op "e1 * e2"           "nix_mul"        ["e1" "e2"];
    div        = op "e1 / e2"           "nix_div"        ["e1" "e2"];  # NixError::DivByZero if e2=0

    # Comparison — all EMIT a Church-bool net (true=λt.λe.t | false=λt.λe.e), NOT a PrimVal
    eq         = op "e1 == e2"          "nix_eq"         ["e1" "e2"];  # structural equality
    neq        = op "e1 != e2"          "nix_neq"        ["e1" "e2"];  # = ! (e1 == e2)
    lt         = op "e1 < e2"           "nix_lt"         ["e1" "e2"];  # = lessThan e1 e2
    lte        = op "e1 <= e2"          "nix_lte"        ["e1" "e2"];  # = ! (lessThan e2 e1)
    gt         = op "e1 > e2"           "nix_gt"         ["e1" "e2"];  # = lessThan e2 e1
    gte        = op "e1 >= e2"          "nix_gte"        ["e1" "e2"];  # = ! (lessThan e1 e2)

    # Boolean — Church-encoded, native, LAZY (short-circuit) via if-desugar.
    # true = λt.λe.t ; false = λt.λe.e ; if c t e ≡ (c t e) = pure FanApp.
    # e1 && e2  ≡  if e1 then e2 else false   (e2 erased+unforced if e1=false)
    # e1 || e2  ≡  if e1 then true else e2    (e2 erased+unforced if e1=true)
    # !e        ≡  if e then false else true  (native; no prim)
    bool_and   = op "e1 && e2"          "if_native"      ["e1" "e2" "false"];
    bool_or    = op "e1 || e2"          "if_native"      ["e1" "true" "e2"];
    bool_not   = op "! e"               "if_native"      ["e" "false" "true"];

    # Attrset merge (right-biased)
    merge      = op "e1 // e2"          "nix_merge"      ["e1" "e2"];

    # List concat
    list_concat= op "e1 ++ e2"          "nix_list_concat"["e1" "e2"];

    # Has-attribute (pure, structural)
    has_attr   = op "e ? key"           "nix_has_attr"   ["e" "key"];  # key is string literal or dyn

    # if-then-else: NATIVE — desugars to pure application of the Church-bool condition.
    # if c then t else e  ≡  c t e   (App(App(c, t), e)). NO prim, NO new rule.
    # LAZINESS: branch laziness = paper optimality — the untaken branch lands on the
    # condition-abstraction's eraser-side aux (λt.λe.t discards e) → never on a spine → never forced.
    if_then_else = op "if c then t else e" "(c t e)" ["c" "t" "e"];

    # assert: assert cond; body  ≡  if cond then body else (throw "assertion failed")  (native if + throw prim)
    assert_op  = op "assert cond; body" "if cond body (throw …)" ["cond" "body"];
  };

# ══════════════════════════════════════════════════════════════════════════
# SECTION 3: PURE BUILTIN FUNCTIONS (NixPrimFun variants, prim_apply rules)
# All entries MUST be in alphabetical order (determines prim_id in PrimTable).
# Source: `nix-instantiate --eval --json --expr 'builtins.attrNames builtins'`
#
# BOOL RESULTS: any prim whose result type is Bool EMITS a Church-bool net
#   (true=λt.λe.t | false=λt.λe.e), NOT a PrimVal — this is what makes native `if` work.
#   Affects: eq/neq/lt/lte/gt/gte, lessThan, elem, hasAttr, all/any, isInt…isString (type preds).
# PRIM RESULT KIND: a prim_apply result is a PrimVal, a partial PrimFun, OR a net fragment
#   (Church-bool; fromJSON/fromTOML emit List/AttrSet PrimVals). See primitives.md §prim-result.
# ══════════════════════════════════════════════════════════════════════════

  funs = {

    # ── A ─────────────────────────────────────────────────────────────────

    # builtins.abort s — halt evaluation with error message (deterministic: same input → same error)
    # NOT caught by tryEval (unlike throw). Runtime halts normalization immediately.
    abort            = f 1 "Str → a"
                         "raises NixError::Abort(msg); uncatchable; delta-net normalization halts";

    # builtins.add e1 e2 — sum of numbers (already an operator; also directly callable)
    add              = f 2 "Num → Num → Num"
                         "int+int→int; int+float or float+float→float; NixError::TypeError otherwise";

    # builtins.all pred list — universal quantifier
    all              = f 2 "(a → Bool) → [a] → Bool"
                         "short-circuits on first false; LO reduction = lazy pred application";

    # builtins.any pred list — existential quantifier
    any              = f 2 "(a → Bool) → [a] → Bool"
                         "short-circuits on first true";

    # builtins.attrNames set — sorted list of attribute names
    attrNames        = f 1 "AttrSet → [Str]"
                         "returns alphabetically sorted name list as PrimVal::List of PrimVal::Str";

    # builtins.attrValues set — values in attrNames order
    attrValues       = f 1 "AttrSet → [a]"
                         "values in alphabetically sorted key order; elements are Terms (lazy)";

    # ── B ─────────────────────────────────────────────────────────────────

    # builtins.bitAnd e1 e2
    bitAnd           = f 2 "Int → Int → Int"
                         "bitwise AND; NixError::TypeError if not both Int";

    # builtins.bitOr e1 e2
    bitOr            = f 2 "Int → Int → Int"
                         "bitwise OR";

    # builtins.bitXor e1 e2
    bitXor           = f 2 "Int → Int → Int"
                         "bitwise XOR";

    # ── C ─────────────────────────────────────────────────────────────────

    # builtins.catAttrs attr list — collect named attr from list of attrsets
    catAttrs         = f 2 "Str → [AttrSet] → [a]"
                         "skips attrsets missing the key; returns list of values in input order";

    # builtins.ceil double
    ceil             = f 1 "Float → Int"
                         "IEEE-754 ceiling; NixError::TypeError if not numeric";

    # builtins.compareVersions s1 s2
    compareVersions  = f 2 "Str → Str → Int"
                         "returns -1/0/1; same algorithm as nix-env -u version comparison";

    # builtins.concatLists lists
    concatLists      = f 1 "[[a]] → [a]"
                         "flatten one level; NixError::TypeError if element not a list";

    # builtins.concatMap f list  (= concatLists (map f list) but faster)
    concatMap        = f 2 "(a → [b]) → [a] → [b]"
                         "equivalent to concatLists (map f list)";

    # builtins.concatStringsSep sep list
    concatStringsSep = f 2 "Str → [Str] → Str"
                         "join list of strings with separator; NixError::TypeError if element not Str";

    # builtins.convertHash { hash, hashAlgo?, toHashFormat }
    # Pure: just reencodes a hash string. hashAlgo optional when hash is SRI.
    convertHash      = f 1 "{ hash: Str, hashAlgo?: Str, toHashFormat: Str } → Str"
                         "pure hash reencoding; formats: base16/nix32/base64/sri; algo: md5/sha1/sha256/sha512";

    # ── D ─────────────────────────────────────────────────────────────────

    # builtins.deepSeq e1 e2
    deepSeq          = f 2 "a → b → b"
                         "force-evaluate e1 deeply (all nested lists/attrsets), then return e2";

    # builtins.div e1 e2
    div              = f 2 "Num → Num → Num"
                         "integer division truncates toward zero; NixError::DivByZero; float/float ok";

    # ── E ─────────────────────────────────────────────────────────────────

    # builtins.elem x xs
    elem             = f 2 "a → [a] → Bool"
                         "structural equality check; O(n) scan";

    # builtins.elemAt xs n
    elemAt           = f 2 "[a] → Int → a"
                         "0-indexed; NixError::IndexOutOfBounds if n >= length";

    # ── F ─────────────────────────────────────────────────────────────────

    # builtins.filter pred list
    filter           = f 2 "(a → Bool) → [a] → [a]"
                         "keep elements where pred returns true";

    # builtins.floor double
    floor            = f 1 "Float → Int"
                         "IEEE-754 floor; NixError::TypeError if not numeric";

    # builtins.foldl' op nul list  (strict left fold)
    foldl_strict     = f 3 "(b → a → b) → b → [a] → b"
                         "name: foldl' (tick = strict); accumulator evaluated immediately each step";

    # builtins.fromJSON e — JSON string → Nix value
    fromJSON         = f 1 "Str → NixVal"
                         "parse JSON; objects→AttrSet, arrays→List, numbers→Int|Float, strings→Str, bool→Bool, null→Null";

    # builtins.fromTOML e — TOML string → Nix value
    fromTOML         = f 1 "Str → NixVal"
                         "parse TOML; tables→AttrSet, arrays→List, etc.";

    # builtins.functionArgs f
    functionArgs     = f 1 "(AttrSet → a) → AttrSet"
                         "returns { argname: Bool(has_default) } for pattern-lambda; {} for plain lambda";

    # ── G ─────────────────────────────────────────────────────────────────

    # builtins.genList generator length
    genList          = f 2 "(Int → a) → Int → [a]"
                         "generate list of size n; element i = generator(i); lazy in elements";

    # builtins.genericClosure { startSet, operator }
    genericClosure   = f 1 "{ startSet: [AttrSet], operator: AttrSet → [AttrSet] } → [AttrSet]"
                         "fixed-point closure; each item must have key attr; dedup by key equality";

    # builtins.getAttr s set — dynamic attribute access
    getAttr          = f 2 "Str → AttrSet → a"
                         "dynamic version of set.attr; NixError::MissingAttr if absent";

    # builtins.groupBy f list — group list elements by string key
    groupBy          = f 2 "(a → Str) → [a] → AttrSet"
                         "result: { key: [elements_with_that_key] }; key order = input encounter order";

    # ── H ─────────────────────────────────────────────────────────────────

    # builtins.hasAttr s set
    hasAttr          = f 2 "Str → AttrSet → Bool"
                         "dynamic version of set ? attr; always pure";

    # builtins.hashString type s — pure crypto hash of a string
    hashString       = f 2 "Str → Str → Str"
                         "type: md5/sha1/sha256/sha512; returns hex string; PURE (no file access)";

    # builtins.head list
    head             = f 1 "[a] → a"
                         "first element; NixError::EmptyList if []";

    # ── I ─────────────────────────────────────────────────────────────────

    # builtins.intersectAttrs e1 e2 — keep attrs of e2 that exist in e1
    intersectAttrs   = f 2 "AttrSet → AttrSet → AttrSet"
                         "result: { k: e2[k] | k ∈ keys(e1) }; O(n log m)";

    # Type predicates — all arity 1, return Bool
    isAttrs          = f 1 "a → Bool" "true iff AttrSet";
    isBool           = f 1 "a → Bool" "true iff Bool";
    isFloat          = f 1 "a → Bool" "true iff Float";
    isFunction       = f 1 "a → Bool" "true iff lambda (Abs node) or PrimFun";
    isInt            = f 1 "a → Bool" "true iff Int";
    isList           = f 1 "a → Bool" "true iff List";
    isNull           = f 1 "a → Bool" "true iff Null";
    isString         = f 1 "a → Bool" "true iff Str";

    # NOTE: isPath intentionally OMITTED — Path type out of scope.

    # ── L ─────────────────────────────────────────────────────────────────

    # builtins.length list
    length           = f 1 "[a] → Int"
                         "list length; O(1) if List stored with cached length";

    # builtins.lessThan e1 e2 (also the < operator)
    lessThan         = f 2 "Num → Num → Bool"
                         "int or float; NixError::TypeError on string comparison (use < directly for strings too)";

    # builtins.listToAttrs e — [{name, value}] → AttrSet
    listToAttrs      = f 1 "[{ name: Str, value: a }] → AttrSet"
                         "first-wins on duplicate names; NixError::TypeError if element missing name/value";

    # ── M ─────────────────────────────────────────────────────────────────

    # builtins.map f list
    map              = f 2 "(a → b) → [a] → [b]"
                         "lazy in elements: element i reduced only when forced";

    # builtins.mapAttrs f attrset
    mapAttrs         = f 2 "(Str → a → b) → AttrSet → AttrSet"
                         "f receives name then value; result is new AttrSet with same keys";

    # builtins.match regex str — POSIX extended regex match
    match            = f 2 "Str → Str → [Str] | Null"
                         "null if no full match; list of groups if match (empty list if no groups)";

    # builtins.mul e1 e2
    mul              = f 2 "Num → Num → Num"
                         "int*int→int; any float→float";

    # ── P ─────────────────────────────────────────────────────────────────

    # builtins.parseDrvName s — split package name + version
    parseDrvName     = f 1 "Str → { name: Str, version: Str }"
                         "split on first dash-not-followed-by-letter; pure string parsing";

    # builtins.partition pred list
    partition        = f 2 "(a → Bool) → [a] → { right: [a], wrong: [a] }"
                         "right = matching, wrong = non-matching; stable relative order";

    # ── R ─────────────────────────────────────────────────────────────────

    # builtins.removeAttrs set list — remove named keys from attrset
    removeAttrs      = f 2 "AttrSet → [Str] → AttrSet"
                         "missing keys silently ignored; O(n log m)";

    # builtins.replaceStrings from to s
    replaceStrings   = f 3 "[Str] → [Str] → Str → Str"
                         "replace each from[i] with to[i] in s; from/to must be same length; lazy in to";

    # ── S ─────────────────────────────────────────────────────────────────

    # builtins.seq e1 e2 — force e1 (WHNF), return e2
    seq              = f 2 "a → b → b"
                         "weak-head normal form of e1 forced before returning e2; useful for strictness";

    # builtins.sort comparator list
    sort             = f 2 "(a → a → Bool) → [a] → [a]"
                         "stable sort; comparator(a,b)=true iff a < b";

    # builtins.split regex str — split string by POSIX regex
    split            = f 2 "Str → Str → [Str | [Str]]"
                         "interleaved: [non-match, [groups], non-match, [groups], ...]; empty strings included";

    # builtins.splitVersion s — split version string into components
    splitVersion     = f 1 "Str → [Str]"
                         "same logic as compareVersions splitting; '1.2.3' → ['1','2','3']";

    # builtins.stringLength e
    stringLength     = f 1 "Str → Int"
                         "byte count (NOT character count); NixError::TypeError if not Str";

    # builtins.sub e1 e2
    sub              = f 2 "Num → Num → Num"
                         "subtraction; same type rules as add";

    # builtins.substring start len s
    substring        = f 3 "Int → Int → Str → Str"
                         "byte-indexed; len=-1 → to end; start > length → ''; NixError if start < 0";

    # ── T ─────────────────────────────────────────────────────────────────

    # builtins.tail list
    tail             = f 1 "[a] → [a]"
                         "all but first element; O(n) copy; NixError::EmptyList if []";

    # builtins.throw s — propagate error (deterministic, pure)
    throw            = f 1 "Str → a"
                         "raises NixError::Throw(msg); caught by tryEval; NOT caught by deepSeq";

    # builtins.toJSON e
    toJSON           = f 1 "NixVal → Str"
                         "serialize to JSON; functions → NixError::CannotSerialize; paths OUT OF SCOPE";

    # builtins.toString e — coerce to string
    toString         = f 1 "a → Str"
                         "Int→decimal, Float→decimal, Bool→'1'/'', Null→'', Str→identity, List→space-joined, AttrSet with __toString→call it, AttrSet with outPath→outPath; NixError::TypeError otherwise";

    # builtins.toXML e — serialize to XML string
    toXML            = f 1 "NixVal → Str"
                         "XML representation; functions → NixError::CannotSerialize";

    # builtins.tryEval e — catch throw/assert errors
    tryEval          = f 1 "a → { success: Bool, value: a | false }"
                         "shallow eval only; catches throw+assert; does NOT catch abort+TypeError; value=false on failure";

    # builtins.typeOf e — string name of type
    typeOf           = f 1 "a → Str"
                         "returns: 'int'|'bool'|'string'|'null'|'set'|'list'|'lambda'|'float'";

    # ── Z ─────────────────────────────────────────────────────────────────

    # builtins.zipAttrsWith f list — transpose list of attrsets
    zipAttrsWith     = f 2 "(Str → [a] → b) → [AttrSet] → AttrSet"
                         "f(name, values_list) for each key in union of all keys; non-empty values list guaranteed";

    # ── INTERNAL / OPERATOR DESUGARING HELPERS ────────────────────────────
    # Not in builtins.*. Generated internally during nixparse desugaring.
    # These are PrimFun agents with no user-visible name; reached only via operator desugaring.

    nix_add          = f 2 "NixNum → NixNum → NixNum"
                         "operator +; dispatches Int+Int→Int, else Float; NixError::TypeError on non-numeric";
    nix_sub          = f 2 "NixNum → NixNum → NixNum"          "operator -";
    nix_mul          = f 2 "NixNum → NixNum → NixNum"          "operator *";
    nix_div          = f 2 "NixNum → NixNum → NixNum"          "operator /; NixError::DivByZero";
    # comparison/logic — EMIT a Church-bool net (force_deep operands for structural ==):
    nix_eq           = f 2 "a → a → Church-bool"               "operator ==; structural deep equality";
    nix_neq          = f 2 "a → a → Church-bool"               "operator !=; Church-not of nix_eq";
    nix_lt           = f 2 "a → a → Church-bool"               "operator <; Int/Float numeric; Str lexicographic";
    nix_lte          = f 2 "a → a → Church-bool"               "operator <=";
    nix_gt           = f 2 "a → a → Church-bool"               "operator >";
    nix_gte          = f 2 "a → a → Church-bool"               "operator >=";
    nix_merge        = f 2 "AttrSet → AttrSet → AttrSet"       "operator //; right-biased; shallow merge";
    nix_list_concat  = f 2 "[a] → [a] → [a]"                  "operator ++";
    nix_str_concat   = f 2 "Str → Str → Str"                   "operator + on strings";
    nix_has_attr     = f 2 "Str → AttrSet → Church-bool"       "operator ?; dynamic key";
  };
  # REMOVED — now NATIVE Church-bool if-desugar, no prim, no new rule:
  #   nix_not        (!e            ≡ if e then false else true)
  #   nix_if_then_else (if c t e    ≡ c t e   — pure FanApp of Church-bool condition)
  #   nix_assert     (assert c; b   ≡ if c then b else (throw "assertion failed"))

# ══════════════════════════════════════════════════════════════════════════
# SECTION 4: EXCLUDED BUILTINS (OUT OF SCOPE — impure or store-related)
# ══════════════════════════════════════════════════════════════════════════

  excluded = {
    # Impure — environment, clock, system
    currentSystem    = "impure: reads eval-system config";
    currentTime      = "impure: reads wall clock";
    getEnv           = "impure: reads environment variable";
    nixPath          = "impure: reads NIX_PATH env";
    nixVersion       = "impure: evaluator version constant";
    langVersion      = "impure: language version constant";
    storeDir         = "impure: depends on store configuration";

    # Store / derivation
    derivation          = "store: produces store derivation";
    derivationStrict    = "store: internal derivation primitive";
    addDrvOutputDependencies = "store: string context manipulation";
    appendContext       = "store: string context manipulation";
    getContext          = "store: reads string context";
    hasContext          = "store: checks string context";
    unsafeDiscardOutputDependency = "store: string context strip (unsafe)";
    unsafeDiscardStringContext    = "store: string context strip";
    placeholder         = "store: derivation output placeholder";
    storePath           = "store: reference to existing store path";
    toFile              = "store: writes string to nix store";

    # Filesystem IO
    hashFile         = "IO: hashes a file on disk";
    import           = "IO: loads and parses a .nix file";
    scopedImport     = "IO: scoped import of .nix file";
    path             = "IO: copies path into store";
    pathExists       = "IO: stat() filesystem check";
    readDir          = "IO: lists directory contents";
    readFile         = "IO: reads file content as string";
    readFileType     = "IO: stat() file type check";
    filterSource     = "IO: filtered filesystem copy to store";
    findFile         = "IO: searches NIX_PATH for file";

    # Network fetch
    fetchGit         = "network: git fetch";
    fetchMercurial   = "network: mercurial fetch";
    fetchTarball     = "network: tarball download + unpack";
    fetchTree        = "network: generic tree fetch";
    fetchurl         = "network: URL download";

    # Flakes (experimental, out of scope)
    flakeRefToString = "flakes: flake ref → string";
    parseFlakeRef    = "flakes: parse flake URL";
    getFlake         = "flakes+network: fetch flake";

    # Debug / side effects
    break            = "debug: enters REPL debugger";
    trace            = "debug: prints to stderr (side effect)";
    traceVerbose     = "debug: prints to stderr (side effect)";
    warn             = "debug: prints warning to stderr (side effect)";
    addErrorContext  = "debug: adds context to error messages";
    unsafeGetAttrPos = "debug: source position lookup";

    # Deprecated / internal
    toPath           = "deprecated: use /. + string instead";
    builtins         = "meta: the builtins attrset itself";

    # true/false = Church-encoded native nets (NOT literals, NOT PrimVal); null = literal PrimVal
    true             = "Church net λt.λe.t (Church-encoded; see nix.md §Booleans); not a PrimFun";
    false            = "Church net λt.λe.e (Church-encoded; see nix.md §Booleans); not a PrimFun";
    null             = "literal Null PrimVal; not a PrimFun";

    # abort is in funs above — deterministic (same input → same halt), not excluded.
  };

# ══════════════════════════════════════════════════════════════════════════
# SECTION 5: RUNTIME ERROR MODEL
# All errors terminate normalization. No exception objects in the net.
# ══════════════════════════════════════════════════════════════════════════

  errors = {
    # From prim_apply failures:
    TypeError        = "wrong type argument (e.g. add 'hello' 1)";
    DivByZero        = "integer or float division by zero";
    IndexOutOfBounds = "elemAt beyond list length";
    EmptyList        = "head or tail on []";
    MissingAttr      = "getAttr / .attr on absent key";
    AssertFailed     = "assert condition evaluated to false";
    Throw            = "throw s — message from user; caught by tryEval";
    Abort            = "abort s — uncatchable; halts normalization immediately";
    CannotSerialize  = "toJSON/toXML on a lambda or PrimFun";
    ImpurePath       = "path literal encountered; out of scope";
    ParseError       = "fromJSON/fromTOML: malformed input string";

    # From elaboration (not prim_apply):
    # LinError, DeltaOverflow, LOPathDepthExceeded — see elaborator.md
  };

# ══════════════════════════════════════════════════════════════════════════
# SECTION 6: LAZINESS MODEL
# ══════════════════════════════════════════════════════════════════════════

  laziness = {
    model = ''
      Nix is lazy (call-by-need). Delta-nets with LO reduction ARE lazy:
      leftmost-outermost = normal order = function body before argument = call-by-need.

      EVALUATION IS DEMAND-DRIVEN. The runtime NEVER eagerly full-normalizes (Ω_S) the program.
      It calls reducer.md `force_whnf(port)` on demand: reduce ONLY the port's LO demand spine
      until its head is a value (PrimVal | FanAbs | List/AttrSet). Off-spine subnets stay unreduced.
      Sound via paper: LO = normal-order + perfect-confluence + optimality (reducer.md §Forcing).

      "thunk" = unreduced sub-net. "force" = force_whnf. No thunk heap.

      Consequences:
      - prim_apply fires only when the PrimFun is saturated AND its result is demanded (on a forced spine).
      - List elements are lazy Terms (sub-nets); head/elemAt/map/filter force elements on demand.
      - AttrSet values are lazy (key,Term); getAttr forces the selected value only.
      - seq = force_whnf(arg0); deepSeq = force_deep(arg0) (= NF of that arg).
      - `head [ 1 (1/0) ]` = 1: elem1 never demanded → no error. `length [ (1/0) ]` = 1: no element forced.
      - `head [ (1/0) ]` ERRORS: head's result IS the div thunk; observing it forces it (like `nix --eval`).
      - `let xs = [1] ++ xs; in head xs` = 1: LAZY SPINE — only first cons forced. Infinite list PRODUCTIVE (dnet BETTER than stock Nix; NO overflow).

      Short-circuit / conditionals — NATIVE Church-bool (no prim, no new rule):
      - if c t e ≡ c t e (FanApp). && / || / ! desugar to if. The untaken branch lands on the
        condition-abstraction's eraser-side aux (λt.λe.t discards e) → never on a spine → never forced.
    '';

    whnf_vs_nf = ''
      WHNF (weak head normal form) = outermost value visible. force_whnf stops here.
        PrimVal / List / AttrSet: already WHNF (elements/values remain lazy Terms).
        FanAbs (lambda, incl. Church bool): already WHNF (do NOT reduce the body).
        Otherwise: reduce the demand spine until a value-head appears.

      NF (normal form) = fully reduced everywhere. force_deep / deepSeq reach it.
        Used ONLY for observation: final output serialization + canonical hashing (canonical-hash.md).
        Ω_S/normalize() = force_deep(root); retained for the hash/artifact path, NOT for eval.
    '';
  };

# ══════════════════════════════════════════════════════════════════════════
# SECTION 7: PRIM_TABLE ORDERING (prim_id assignment)
# ══════════════════════════════════════════════════════════════════════════
#
# prim_id = index into Net.prim_fns. Assigned at elaborator startup.
# Order: alphabetical over ALL names in funs attrset above (builtins.* first,
# then nix_* internal helpers at the end).
#
# This ordering is STABLE across sessions (deterministic via sorted insertion).
# Changing the order = incompatible net format — settle this before first impl.
#
# prim_id = index into the byte-order alphabetical sort of ALL `funs` attr names,
# computed at elaborator startup (`builtins.attrNames funs` is ALREADY sorted).
# This sort is the SINGLE SOURCE OF TRUTH — deterministic + stable across sessions →
# stable net/artifact format. Do NOT hand-number (error-prone). Count = (# entries in funs).
# REMOVED (now native if-desugar, no prim): nix_not, nix_if_then_else, nix_assert.
# The numbered list below is ILLUSTRATIVE ONLY (pre-removal) — recompute at impl; do not trust it.
#
#  0  abort            29  groupBy          58  nix_lt
#  1  add              30  hasAttr          59  nix_lte
#  2  all              31  hashString       60  nix_merge
#  3  any              32  head             61  nix_mul
#  4  attrNames        33  intersectAttrs   62  nix_neq
#  5  attrValues       34  isAttrs          63  nix_not
#  6  bitAnd           35  isBool           64  nix_str_concat
#  7  bitOr            36  isFloat          65  nix_sub
#  8  bitXor           37  isFunction       66  parseDrvName
#  9  catAttrs         38  isInt            67  partition
# 10  ceil             39  isList           68  removeAttrs
# 11  compareVersions  40  isNull           69  replaceStrings
# 12  concatLists      41  isString         70  seq
# 13  concatMap        42  length           71  sort
# 14  concatStringsSep 43  lessThan         72  split
# 15  convertHash      44  listToAttrs      73  splitVersion
# 16  deepSeq          45  map              74  stringLength
# 17  div              46  mapAttrs         75  sub
# 18  elem             47  match            76  substring
# 19  elemAt           48  mul              77  tail
# 20  filter           49  nix_add          78  throw
# 21  floor            50  nix_assert       79  toJSON
# 22  foldl_strict     51  nix_div          80  toString
# 23  fromJSON         52  nix_eq           81  toXML
# 24  fromTOML         53  nix_gt           82  tryEval
# 25  functionArgs     54  nix_gte          83  typeOf
# 26  genericClosure   55  nix_has_attr     84  zipAttrsWith
# 27  genList          56  nix_if_then_else
# 28  getAttr          57  nix_list_concat
#
# NOTE: exact table = builtins.attrNames funs evaluated at impl startup.
#
# FINAL prim_id table: use `builtins.attrNames funs` to compute at impl time.
# Impl MUST sort funs attrNames and assign prim_ids in that sorted order.

}
