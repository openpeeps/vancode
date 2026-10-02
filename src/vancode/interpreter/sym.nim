# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) iLiquid, 2019-2020
#     https://github.com/liquidev/
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Implements the symbol and scope system for the interpreter. This is used to manage
## variables, functions, types, and other symbols in the interpreter. It also
## handles symbol lookup, overloading, and type checking.

import std/[tables, json, hashes, options, sequtils, strutils, os]
import pkg/voodoo/extensibles

import ./[ast, value]

var globalTypeOrdinal* {.global.}: int = 0
  ## Per-file declaration counter backing `Sym.stamp`. Exposed so frontends
  ## that build type symbols outside `newType` can stamp them the same way.

type
  Context* = distinct uint16
    ## A scope context.

  ImportedTypes* = object
    ## One import's worth of exported type symbols, kept as a separate layer.
    ##
    ## Imports used to be flattened into a single `typeDefs` table keyed by
    ## bare name, so two modules declaring the same type name collided and the
    ## loser was dropped without a word. Keeping each import in its own layer
    ## lets a lookup tell "the local declaration" from "two imported
    ## candidates that disagree", which is the difference between a working
    ## program and a silently wrong one.
    alias*: string
      ## the `import "x" as alias` binding, empty when unaliased
    path*: string
      ## the imported module's source path, for diagnostics
    types*: Table[string, Sym]
      ## the module's exported types, keyed by canonical name

  Scope* {.acyclic.} = ref object of RootObj
    ## A local scope.
    syms*: Table[string, Sym]
    exportSyms*: Table[string, Sym]
      ## A table of exported symbols
    otherSyms*: Table[string, Sym]
      ## A table of symbols imported from other modules
      
    variables*, exportVariables*: Table[string, Sym]
      ## A table of variables. This is used for fast lookups of variables
      ## in the current scope. The key is the hash of the variable's name.
    functions*, exportFunctions*: Table[string, Sym]
      ## A table of functions. This is used for fast lookups of functions
      ## in the current scope.
    typeDefs*, exportTypeDefs*: Table[string, Sym]
      ## A table of type definitions declared *in this scope*. This is used
      ## for fast lookups of type definitions in the current scope.
    importedTypes*: seq[ImportedTypes]
      ## one layer per import, in import order. consulted only after
      ## `typeDefs` misses, so a local declaration always wins.
    context*: Context
      ## the scope's context. this is used for scope hygiene
  
  Module* {.acyclic.} = ref object of Scope
    ## A module representing the global scope of a single source file.
    name*: string
      ## the name of the module
    src*: Option[string]
      ## the source file where the module was defined
      ## this is used for type checking and error reporting
    modules*: Table[string, Module]
      ## a table of modules imported by this module
      ## where the key is the path to the module

  SymKind* = enum
    ## The kind of a symbol.
    skVar = "var"
    skConst = "const"
    skLet = "let"
    skType = "type"
    skProc = "fn"
    skIterator = "iterator"
    skCoroutine = "coroutine"
    skGenericParam = "generic param"
    skHtmlType = "html"
    skChoice = "(...)"  ## an overloaded symbol, stores many symbols with \
                        ## the same name

  TypeKind* {.extensible.} = enum
    ## The kind of a type.
    # meta-types
    ttyVoid = "void"      # matches no types
    ttyAny = "any"        # matches any and all types

    # concrete types
    ttyBool = "bool"
    ttyInt = "int"        # int64
    ttyFloat = "float"    # float64
    ttyString = "string"  # ref string
    ttyPointer = "pointer" # a raw pointer type
    ttyProc = "proc"       # a callable proc reference
    ttyJson = "json"
    ttyArray = "array"
    
    ttyNil = "nil"        # matches nil

    # user-defined types
    ttyObject = "object"
    ttyClass = "class"
    ttyInterface = "interface"
    ttyCoroutine = "coroutine"
    ttyAlias = "alias"
    ttyCustom = "custom"
      # a user-defined type that doesn't have a
      # special representation in the VM
    ttyHtmlElement = "HtmlElement"

  ProcType* = enum
    ## The type of a procedure (function)
    procTypeFunction
    procTypeMacro

  Stamp* = object
    ## Where a symbol was declared. Two symbols are the same *declared* symbol
    ## when their stamps match, which is what keeps a type named `Veg` in one
    ## file from being satisfied by a different `Veg` declared elsewhere.
    path*: string
      ## the declaring file, empty for generated (builtin) symbols
    ordinal*: uint32
      ## the declaration's index within that file

  Sym* {.acyclic.} = ref object
    ## A symbol. This represents an ident that can be looked up.
    name*: Node  ## the name of the symbol
    impl*: Node  ## the implementation of the symbol. may be ``nil`` if the symbol is generated
    src*: Option[string]
      ## the source file where the symbol was defined
      ## this is used for type checking and error reporting
    stamp*: Stamp
      ## the declaration site. Unlike `src` this is total: two builtins
      ## declared in the same file still get distinct ordinals.
    case kind*: SymKind
    of skVar, skLet, skConst:
      varTy*: Sym        ## the type of the variable
      varSet*: bool      ## is the variable set?
      varLocal*: bool    ## is the variable local?
      varStackPos*: int  ## the position of this local variable on the stack
      varExport*: bool   ## whether the variable is exported or not
    of skType:
      typeExport*: bool
        ## This is used to determine whether the type
        ## can be used in other modules or not.
      case tyKind*: TypeKind
      of ttyNil: discard # nil is a special case
      of ttyVoid..ttyString:
        isMutable*: bool
      of ttyJson:
        jsonTy*: JsonNodeKind     ## the type of the JSON value, used for type checking
        jsonNode*: JsonNode       ## a statically defined JSON node (when available)
      of ttyArray:
        arrayTy*: Sym             ## the type of the array
        arrayMutable*: bool       ## used to determine whether the array is mutable or not
        arrayItems*: seq[Sym]     ## the items of the array
      of ttyObject:
        objectId*: TypeId         ## a unique id for this object type, used for type checking and comparisons
        objectFields*: OrderedTable[string, ObjectField]
      of ttyAlias:
        aliasId*: TypeId          ## the id of the alias, used for lookups and type checking
        aliasTy*: Sym             ## the type this alias refers to
      of ttyCoroutine:
        coroResultTy*: Sym             ## the result type of resume()
      of ttyCustom:
        discard # todo
      of ttyHtmlElement: discard
      of ttyPointer:
        pointerTarget*: Sym       ## The type this pointer points to (type info only)
      else: discard               # other types don't have any special fields
    of skHtmlType:
      tag*, innerText*: string    ## the tag of the HTML element (e.g., "div", "span", etc.)
      isVoidElement*: bool        ## whether this HTML element is a void element or not (e.g., "img", "br", etc.)
    of skProc:
      procId*: uint16             ## the unique number of the proc
      sourcePath*: string         ## the source path of the proc
      procParams*: seq[ProcParam] ## the proc's parameters
      procReturnTy*: Sym          ## the return type of the proc
      procType*: ProcType         ## whether the proc is a normal function or a macro
      procExport*: bool           ## whether the proc is exported or not
      procMemoize*: bool          ## whether the proc is memoized or not. todo: implement memoization
    of skCoroutine:
      coroId*: uint16                  ## the unique number of the coroutine's proc
      coroParams*: seq[ProcParam]      ## the coroutine's parameters
      coroReturnTy*: Sym               ## the return type of the coroutine
      coroYieldTy*: Sym                ## the yield type of the coroutine
      coroExport*: bool                ## whether the coroutine is exported or not
    of skIterator:
      iterParams*: seq[ProcParam]       ## the iterator's parameters
      iterYieldTy*: Sym                 ## the yield type of the iterator
      iterExport*: bool                 ## whether the iterator is exported or not
    of skGenericParam:
      constraint*: Sym                  ## the generic type constraint
    of skChoice:
      choices*: seq[Sym]                ## the different choices for this overloaded symbol
    genericParams*: Option[seq[Sym]]    ## some if the sym is generic
    genericInstCache*: Table[seq[Sym], Sym]
    genericBase*: Option[Sym]           ## contains the base generic type if the sym is an instantiation
    genericInstArgs*: Option[seq[Sym]]  ## some if the sym is an instantiation

  ObjectField* = tuple
    id: int     # every object field has an id that's used for lookups on
                # runtime. this id is simply a seq index so field lookups are
                # fast
    name: Node  # the name of the field
    ty: Sym     # the type of the field
    implVal: Sym

  ProcParam* = tuple
    ## A single param of a proc.
    name: Node
    ty: Sym
    implSym: Sym
    isMut: bool
    isOpt: bool

  ArgTuple* = tuple
    sym: Sym
    exprSym: Sym

    # TODO: default param values

  CodeGenError* = object of ValueError
    file*: string
    ln*, col*: int

const
  skVars* = {skVar, skLet, skConst}
  skCallable* = {skProc, skIterator, skCoroutine}
  skDecl* = {skType} + skCallable + skVars
  skTyped* = {skType, skHtmlType, skGenericParam}

  tyPrimitives* = {ttyVoid..ttyString}
  tyMeta* = {ttyVoid, ttyAny}

proc `==`*(a, b: Context): bool {.borrow.}

proc clone*(sym: Sym): Sym =
  ## Clones a symbol, returning a newly allocated instance with the same fields.
  new(result)
  result[] = sym[]

proc params*(sym: Sym): seq[ProcParam] =
  ## Get the proc/iterator's params.
  assert sym.kind in skCallable
  case sym.kind
  of skProc: result = sym.procParams
  of skIterator: result = sym.iterParams
  of skCoroutine: result = sym.coroParams
  else: discard

proc returnTy*(sym: Sym): Sym =
  ## Get the proc/iterator's return or yield type.
  assert sym.kind in skCallable
  case sym.kind
  of skProc: result = sym.procReturnTy
  of skIterator: result = sym.iterYieldTy
  of skCoroutine: result = sym.coroReturnTy
  else: discard

proc `$`*(sym: Sym): string

proc `$`*(params: seq[ProcParam]): string =
  ## Stringify a seq of proc parameters.
  result = "("
  for i, param in params:
    result.add($param.name & ": ")

    # mutable parameters are prefixed with a `var
    if param.isMut: result.add($skVar & " ")

    result.add($param.ty) # add the type

    # if param.ty.name.ident == "any":
      # temp. fix this!
      # if param.implVal == nil:
      #   result.add(" = nil")
    if i != params.len - 1: result.add(", ") # add comma, move to next param
  result.add(")")

proc `$`*(sym: Sym): string =
  ## Stringify a symbol in a user-friendly way.
  case sym.kind
  of skVar, skLet, skConst:
    # we don't have a runtime value for the variable,
    # so we just show the name and the type
    result =
      if sym.kind == skVar: "var "
      else: "let "
    result.add(sym.name.render)
    result.add(": ")
    result.add($sym.varTy)
  of skType:
    case sym.tykind
    of ttyArray:
      # assert sym.arrayTy != nil, "array type must have a type"
      result = "array["
      if sym.arrayTy != nil:
        result.add(sym.arrayTy.name.render)
      else:
        if sym.genericInstArgs.isSome:
          result.add(sym.genericInstArgs.get()[0].name.render)
      result.add("]")
    of ttyObject:
      # Name the type rather than listing its fields. Two same-named types in a
      # type error rendered as `{ carrot: (...); leek: (...)}` and
      # `{ pea: (...);}`, which says nothing about *which* `Veg` was wanted, and
      # for an enum the field list is the entire type. `name (file)` identifies
      # both the type and the file that declared it.
      result = sym.name.render
      if sym.stamp.path.len > 0:
        result.add(" (" & sym.stamp.path.extractFilename & ")")
    else:
      result = sym.name.render
      if sym.genericInstArgs.isSome:
        let argsStr = sym.genericInstArgs.get.mapIt($it).join(", ")
        result.add('[' & argsStr & ']')
  of skGenericParam:
    result = sym.name.render
    if sym.constraint != nil:
      if sym.constraint.name.ident != "any":
        result.add(": " & $sym.constraint)
  of skCallable:
    result =
      if sym.kind == skProc:
        if sym.name.ident.startsWith("@"):
          "macro " & sym.name.ident[1..^1]
        else:
          $skProc & " " & sym.name.render
      elif sym.kind == skCoroutine:
        $skCoroutine & " " & sym.name.render
      else:
        $skIterator & " " & sym.name.render
    if sym.genericParams.isSome or sym.genericInstArgs.isSome:
      # let genericParams =
      #   sym.genericParams.get(otherwise = sym.genericInstArgs.get)
      # result.add('[' & genericParams.join(", ") & ']')
      let genericParams = sym.genericParams.get()
      let paramsStr = genericParams.mapIt($it).join(", ")
      result.add('[' & paramsStr & ']')
    result.add($sym.params)
    case sym.returnTy.kind
    of skType:
      if sym.returnTy.tyKind != ttyVoid:
        result.add(": ")
        result.add($sym.returnTy)
    of skGenericParam:
      result.add(": ")
      result.add($sym.returnTy.name)
    else: discard # error?
  of skChoice:
    result = sym.choices.mapIt($it).join("\n").indent(2)
  else: discard
  # When two same-named types meet in a type error, the bare name is useless on
  # its own, so name the declaring file: a `Veg` in a.dfkup and a `Veg` in
  # b.dfkup otherwise render identically. Only the bare-name branch qualifies,
  # since that is the one that reads as a type name rather than a value.
  if sym.kind == skType and sym.tyKind notin tyPrimitives and
     sym.stamp.path.len > 0 and result == sym.name.render:
    result.add(" (" & sym.stamp.path.extractFilename & ")")

proc isGeneric*(sym: Sym): bool =
  ## Returns whether the symbol is generic or not.
  ## A symbol is generic if it has generic params or *is* a generic param.
  (sym.genericParams.isSome or sym.kind == skGenericParam) and
  sym.genericBase.isNone

proc isInstantiation*(sym: Sym): bool =
  ## Returns whether the symbol is an instantiation.
  result = sym.genericBase.isSome

proc hash*(sym: Sym): Hash =
  ## Hashes a sym (for use in Tables).
  # we don't do any special hashing, just hash it by instance to make sure that
  # even if there are two symbols named the same, they'll stay different when
  # used in table lookups

  # side note: this efficient hashing of integers that Nim claims to provide
  # is just converting the int to a Hash (which is a distinct int) :)
  result = hash(cast[int](sym))

proc lowerName*(s: string): string {.inline.} =
  ## Canonical first-letter-case symbol form (Nim-like languages).
  if s.len > 1: s[0] & s[1..^1].toLowerAscii() else: s

proc sameStamp*(a, b: Stamp): bool =
  ## Whether two declaration sites are the same.
  ##
  ## Symbols with no stamp at all (built before stamping existed, or injected
  ## by a frontend that skipped it) are treated as equal to each other, so a
  ## missing stamp degrades to the old name-based behaviour rather than making
  ## every such type distinct from every other.
  if a.ordinal == 0 and b.ordinal == 0: return true
  a.ordinal == b.ordinal and a.path == b.path

proc newStamp*(src: Option[string], ordinal: uint32): Stamp =
  ## Where a symbol was declared: the file that declared it, plus a per-file
  ## ordinal so two declarations in one file stay distinct.
  result.path = if src.isSome: src.get else: ""
  result.ordinal = ordinal

proc `$`*(stamp: Stamp): string =
  if stamp.path.len == 0: return $stamp.ordinal
  $stamp.ordinal & " @" & stamp.path.extractFilename

proc nextTypeOrdinal(): uint32 =
  ## Per-file ordinal for the next declared type. Identity needs to distinguish
  ## `Veg` in a.dfkup from `Veg` in b.dfkup, and two same-named types declared
  ## in the same file, which a path alone cannot do.
  globalTypeOrdinal.inc()
  uint32(globalTypeOrdinal)

proc newSym*(kind: SymKind, name: Node, impl: Node = nil): Sym =
  ## Create a new symbol from a Node.
  result = Sym(name: name, impl: impl, kind: kind)

proc newType*(kind: TypeKind, name: Node, impl: Node = nil,
              src: Option[string] = none(string)): Sym =
  ## Create a new type symbol from a Node.
  ##
  ## The stored name is canonicalized with `lowerName`, exactly as `newProc`
  ## does for procedure names. Lookups already normalize through `normName`,
  ## so without this a type whose name carries an uppercase letter after the
  ## first could be declared but never found again: `type BadFruit` worked,
  ## `BadFruit` did not. A fresh node is built rather than rewriting the
  ## caller's, so the AST still reports the name as it was written.
  let nameNode =
    if name == nil: nil
    elif name.kind == nkIdent:
      Node(kind: nkIdent, ident: lowerName(name.ident), ln: name.ln, col: name.col)
    else:
      name
  result = Sym(name: nameNode, impl: impl, kind: skType, tyKind: kind,
               src: src, stamp: newStamp(src, nextTypeOrdinal()))

proc genType*(kind: TypeKind, name: string, exportSym: bool,
      genericParams: Option[seq[Sym]] = none(seq[Sym])): Sym =
  ## Generate a new type symbol from a string name.
  ##
  ## Deliberately left unstamped. These are the builtin and library types
  ## (`int`, `json`, `void`, every `addProc` parameter type), which are global
  ## singletons rather than per-file declarations, so they must keep matching
  ## each other by `tyKind`. Only `newType` stamps, because only it describes a
  ## type declared at a particular place in a particular file.
  result = Sym(
    name: newIdent(name),
    kind: skType,
    tyKind: kind,
    typeExport: exportSym
  )
  if genericParams.isSome:
    result.genericParams = genericParams

when compiles(voidHtmlElements.len > 0):
  proc genHtmlType*(kind: TypeKind, tag: string): Sym =
    ## Generate a new type symbol from a string name
    result = Sym(
      name: newIdent(tag),
      kind: skHtmlType,
      isVoidElement: tag in voidHtmlElements
    )

proc unwrapType*(ty: Sym): Sym =
  ## Unwraps a type from any `skVar` or `skLet` wrappers.
  if ty.kind in skVars:
    return ty.varTy
  return ty

proc sameType*(a, b: Sym): bool =
  ## Returns ``true`` if ``a`` and ``b`` are compatible types.
  if a.isNil or b.isNil:
    # nil never matches: callers that propagate nil get a clean
    # mismatch instead of a segfault on `.kind` below.
    return false
  # Unwrap variables to their types
  var (a, b) = (a, b)
  if a.kind in skVars: a = a.varTy
  if b.kind in skVars: b = b.varTy

  # echo "sameType: ", $a, " (kind: ", a.kind, ") vs ", $b, " (kind: ", b.kind, ")"

  # Unwrap generic params to their constraints
  if a.kind == skGenericParam: a = a.constraint
  if b.kind == skGenericParam: b = b.constraint

  # Special case: 'any' matches anything
  if a.kind == skType and a.tyKind == ttyAny: return true
  if b.kind == skType and b.tyKind == ttyAny: return true

  # If both are types, compare their kind and details
  if a.kind == skType and b.kind == skType:
    if a.tyKind == b.tyKind:
      case a.tyKind
      of ttyArray:
        # Compare array item types
        if a.arrayTy != nil and b.arrayTy != nil:
          return a.arrayTy.sameType(b.arrayTy)
        # If generic, compare inst args
        if a.genericInstArgs.isSome and b.genericInstArgs.isSome:
          let aArgs = a.genericInstArgs.get
          let bArgs = b.genericInstArgs.get
          if aArgs.len != bArgs.len: return false
          for i in 0..<aArgs.len:
            if not aArgs[i].sameType(bArgs[i]): return false
          return true
        return true # return a == b
      of ttyObject:
        # Compare object type ids (structural comparison could be added)
        return a.objectId == b.objectId
      of ttyAlias, ttyCustom:
        return a == b
      of ttyVoid..ttyString:
        # primitives are global: every `int` is the same `int`
        return true
      else:
        # A declared type of any other kind (class, interface, coroutine, ...)
        # is identified by where it was declared, not by its name. Returning
        # `true` here made every same-kind type match every other, so a
        # `Veg` from one file quietly satisfied a `Veg` parameter declared in
        # another.
        return sameStamp(a.stamp, b.stamp)
    else:
      return false

  # If both are generic instantiations, compare base and args
  if a.isInstantiation and b.isInstantiation:
    if a.genericBase.isSome and b.genericBase.isSome:
      if not a.genericBase.get.sameType(b.genericBase.get): return false
      let aArgs = a.genericInstArgs.get
      let bArgs = b.genericInstArgs.get
      if aArgs.len != bArgs.len: return false
      for i in 0..<aArgs.len:
        if not aArgs[i].sameType(bArgs[i]): return false
      return true

  # If only one is an instantiation, try to compare to the other's base or arg
  if a.isInstantiation and not b.isInstantiation:
    if a.genericBase.isSome:
      return a.genericBase.get.sameType(b)
  if not a.isInstantiation and b.isInstantiation:
    if b.genericBase.isSome:
      return a.sameType(b.genericBase.get)

  # skProc (function value) is compatible with ttyProc type
  if (a.kind == skProc and b.kind == skType and b.tyKind == ttyProc) or
     (b.kind == skProc and a.kind == skType and a.tyKind == ttyProc):
    return true

  # Fallback: compare by identity
  if a.kind != b.kind: return false
  return a == b

proc sameParams*(sym: Sym, args: seq[Sym]): bool =
  ## Returns ``true`` if both ``a`` and ``b`` are called with the same
  ## parameters.
  assert sym.kind in skCallable, "symbol must be callable: " & $skCallable

  if args.len > sym.params.len: return # false
  
  for i, param in sym.params:
    try:
      if not param.ty.sameType(args[i]): return
    except IndexDefect:
      if param.isOpt == false: return
        
  result = true
  # if param.isMut and args[i].kind != skVar:
  #   return false

proc sameParams*(a, b: Sym): bool =
  ## Overload of ``sameParams`` for two symbols.
  assert b.kind in skCallable, "symbol must be callable: " & $skCallable
  result = a.sameParams(b.params.mapIt(it.ty))

proc canAdd*(choice, sym: Sym): bool =
  ## Tests if ``sym`` can be added into ``choice``. Refer to ``add``
  ## documentation below for details.
  assert choice.kind == skChoice
  if sym.kind notin skDecl: return false
  case sym.kind
  of skVars:
    result = choice.choices.allIt(it.kind notin skVars)
  of skType:
    result = choice.choices.allIt(it.kind != skType)
  of skCallable:
    result = choice.choices.allIt(not sym.sameParams(it))
  of skHtmlType:
    result = choice.choices.allit(it.kind != skHtmlType)
  of skGenericParam, skChoice: discard

proc canExport(sym: Sym): bool =
  ## Returns ``true`` if the symbol can be exported.
  ## This is used to determine whether the symbol can be
  ## used in other modules or not.
  result = 
    case sym.kind
    of skVar, skLet, skConst:
      sym.varExport
    of skType:
      sym.typeExport
    of skProc:
      sym.procExport
    of skIterator:
      sym.iterExport
    of skCoroutine:
      sym.coroExport
    else: false

proc addVariable*(scope: Scope, sym: Sym, lookupName: Node,
                fromOtherModule: static bool = false): bool {.discardable.} =
  ## Add a variable to the given scope.
  if not scope.variables.hasKey(lookupName.ident):
    scope.variables[lookupName.ident] = sym
    # scope.syms[lookupName.ident] = sym # todo remove `syms`
    when fromOtherModule == false:
      if sym.canExport():
        # add the symbol to the export table so it can be used
        # in other modules that import this module
        scope.exportVariables[lookupName.ident] = sym
    return true

proc addCallable*(scope: Scope, sym: Sym, lookupName: Node,
            fromOtherModule: static bool = false): bool {.discardable.} =
  ## Add a callable to the given scope.
  ## If ``sym`` is itself an overload choice, add each overload individually.
  if sym.kind == skChoice:
    for ch in sym.choices:
      discard scope.addCallable(ch, lookupName, fromOtherModule)
    return true

  if not scope.functions.hasKey(lookupName.ident):
    scope.functions[lookupName.ident] = sym
    when fromOtherModule == false:
      if sym.canExport():
        # just like with variables, if a function is suffixed with `*`,
        # it will be available in other modules that import this module
        scope.exportFunctions[lookupName.ident] = sym
    return true

  # otherwise, add it to a shared 'choice' symbol
  # if an overload with the same name doesn't already exist
  let other = scope.functions[lookupName.ident]
  if other.kind != skChoice:
    var choice = newSym(skChoice, other.name)
    choice.choices.add(other)
    scope.functions[lookupName.ident] = choice
    when fromOtherModule == false:
      if sym.canExport():
        if scope.exportFunctions.hasKey(lookupName.ident) and
           scope.exportFunctions[lookupName.ident].kind != skChoice:
          scope.exportFunctions[lookupName.ident] = choice

  if scope.functions[lookupName.ident].canAdd(sym):
    # Only add if not already present
    if sym notin scope.functions[lookupName.ident].choices:
      scope.functions[lookupName.ident].choices.add(sym)
      when fromOtherModule == false:
        if sym.canExport():
          if scope.exportFunctions.hasKey(lookupName.ident):
            if sym notin scope.exportFunctions[lookupName.ident].choices:
              scope.exportFunctions[lookupName.ident].choices.add(sym)
    return true

proc addType*(scope: Scope, sym: Sym, lookupName: Node, fromOtherModule: static bool = false): bool {.discardable.} =
  ## Add a type to the given scope.
  ##
  ## This is for declarations made *in* this scope. Imported types go through
  ## `addImportedTypes` instead, so they land in a per-import layer rather
  ## than being flattened into `typeDefs`.
  if not scope.typeDefs.hasKey(lookupName.ident):
    scope.typeDefs[lookupName.ident] = sym
    scope.syms[lookupName.ident] = sym # todo remove `syms`
    when fromOtherModule == false:
      if sym.canExport(): # export the type as well
        scope.exportTypeDefs[lookupName.ident] = sym
    return true

proc addImportedTypes*(scope: Scope, alias, path: string,
                       types: Table[string, Sym]) =
  ## Record one import's exported types as a lookup layer on ``scope``.
  ##
  ## Layers are consulted in import order, after ``scope``'s own ``typeDefs``.
  ## Re-importing the same path replaces the existing layer so a module loaded
  ## twice does not appear twice in ambiguity reports.
  for i, layer in scope.importedTypes:
    if layer.path == path:
      scope.importedTypes[i] = ImportedTypes(alias: alias, path: path, types: types)
      return
  scope.importedTypes.add(ImportedTypes(alias: alias, path: path, types: types))

proc importedTypesCandidates*(scope: Module, id: string): seq[ImportedTypes] =
  ## Every import layer that provides a type named ``id``.
  for layer in scope.importedTypes:
    if id in layer.types:
      result.add(layer)

proc importedTypeByAlias*(scope: Module, alias, id: string): Sym =
  ## Look up ``id`` only within the import bound to ``alias``.
  for layer in scope.importedTypes:
    if layer.alias == alias and id in layer.types:
      return layer.types[id]

proc importAlias*(scope: Module, alias: string): bool =
  ## Whether ``alias`` is bound by an `import ... as alias`.
  for layer in scope.importedTypes:
    if layer.alias == alias:
      return true

proc systemModule*(scope: Module): Module =
  ## The system module linked into ``scope``, however it was linked.
  ##
  ## `load` keys `modules` by source path and `importModule` by alias, so a
  ## frontend using either would otherwise have to know which. An embedder's
  ## system module is the one named `system` or backed by a `system.timl` path.
  for key, m in scope.modules:
    if m.name == "system": return m
    if key.endsWith("system.timl"): return m
    if m.src.isSome and m.src.get().extractFilename == "system.timl":
      return m

proc importAliases*(scope: Module): seq[string] =
  ## Every alias bound in this module, in import order.
  for layer in scope.importedTypes:
    if layer.alias.len > 0:
      result.add(layer.alias)

proc add*(scope: Scope, sym: Sym,
    lookupName: Node = nil, fromOtherModule: static bool = false): bool {.discardable.} =
  ## Add a symbol to the given scope. If a symbol under the given name already
  ## exists, it's added into an skChoice. The rules for overloading are:
  ## - there may only be one skVar or skLet under a given skChoice,
  ## - there may only be one skType under a given skChoice,
  ## - there may be any number of skProcs with unique parameters under a
  ##   single skChoice.
  ## If any one of these checks fails, the proc will return ``false``.
  ## These checks will probably made more strict in the future.

  # this proc can override the name of the ident. this is used for generic
  # instantiations to make type aliases under the names of the generic
  # parameters
  let name =
    if lookupName == nil: sym.name
    else: lookupName

  case sym.kind
  of skVars:
    return addVariable(scope, sym, name, fromOtherModule)
  of skCallable:
    return addCallable(scope, sym, name, fromOtherModule)
  of skType:
    return addType(scope, sym, name, fromOtherModule)
  of skGenericParam:
    if not scope.variables.hasKey(lookupName.ident):
      scope.variables[lookupName.ident] = sym
      # scope.syms[lookupName.ident] = sym # todo remove `syms`
      # if sym.canExport(): # export the type as well
      #   scope.exportTypeDefs[lookupName.ident] = sym
      return true
  else: discard # todo

proc `$`*(scope: Scope): string =
  ## Stringifies a scope.
  ## This is only really useful for debugging.
  for name, sym in scope.syms:
    result.add("\n  ")
    result.add(name)
    result.add(": ")
    # result.add($$sym)

proc `$`*(module: Module): string =
  ## Stringifies a module.
  ## This is only really useful for debugging.
  result = "module " & module.name & ":" & $module.Scope

proc sym*(module: Module, name: string): Sym =
  ## Get the symbol ``name`` from a module.
  result = module.syms[name]

proc mergeModule*(module: Module, other: Module,
                  fromOtherModule: static bool, alias, key: string): bool =
  ## Merge `other`'s exported symbols into `module`. Shared by `load` and
  ## `importModule`.
  ##
  ## Types are recorded as a per-import layer (``alias`` names it) instead of
  ## being flattened into `typeDefs`. Flattening meant the first import to
  ## claim a type name silently won, so a file that declared `Veg` itself could
  ## end up resolving `Veg` to another file's enum. Variables and functions keep
  ## their existing flat tables: those already overload by name via `skChoice`,
  ## so a same-named entry is a genuine overload rather than a lost declaration.
  
  # `syms` is the legacy flat table still read by `module.sym`, so imported
  # types have to land there too even though lookup uses the layers.
  for k, sy in other.exportTypeDefs:
    if k notin module.syms:
      module.syms[k] = sy
  module.addImportedTypes(alias, key, other.exportTypeDefs)
  
  for k, sy in other.exportVariables:
    discard module.addVariable(sy, sy.name, fromOtherModule)

  for k, sy in other.exportFunctions:
    discard module.addCallable(sy, sy.name, fromOtherModule)
  
  module.modules[key] = other
  result = true

proc load*(module: Module, other: Module, fromOtherModule: static bool = false,
           alias = ""): bool {.discardable.} =
  ## Import public symbols from `other` into `module`
  ## If the module is already imported it will return `false`
  let otherModulePath = other.src.get()
  if module.modules.hasKey(otherModulePath):
    return # false
  result = mergeModule(module, other, fromOtherModule, alias, otherModulePath)

proc importModule*(module: Module, other: Module, alias = ""): bool {.discardable.} =
  ## Make `other`'s exported symbols visible in `module` under `alias`.
  ##
  ## This is the low-level module link for an embedder that builds its own
  ## module graph in Nim (a stdlib importing the system module, say), rather
  ## than for a source-level `import`. Unlike `load` it does not require
  ## `other.src` to be set, because an embedder's modules are not files, and
  ## it keys on `alias` so the same module can be reached under a name.
  ##
  ## Types land in a layer, exactly as `load` does, so a module keeps its own
  ## declarations ahead of anything it imports and two imports disagreeing
  ## about a name is reported rather than silently resolved.
  result = mergeModule(module, other, false, alias, alias)

proc newModule*(name: string, src: Option[string] = none(string)): Module =
  ## Initialize a new module.
  result = Module(name: name, src: src)

proc initSystemTypes*(module: Module) =
  ## Add primitive types into the module.
  ## This should only ever be called when creating the ``system`` module.
  for kind in tyPrimitives:
    let name = $kind
    module.add(genType(kind, name, true))

  let genT = ast.newIdent("T")
  let genArrayType = newSym(skGenericParam, genT, impl = genT)
  genArrayType.constraint = module.sym"any"
  module.add(genType(ttyArray, "array", true, some(@[genArrayType])))

  module.add(genType(ttyNil, "nil", true))
  module.add(genType(ttyAny, "stmt", true))
  module.add(genType(ttyJson, "json", true))
  module.add(genType(ttyObject, "object", true))
  module.add(genType(ttyPointer, "pointer", true))
  module.add(genType(ttyProc, "proc", true))

  let genCoroT = ast.newIdent("T")
  let genCoroTypeParam = newSym(skGenericParam, genCoroT, impl = genCoroT)
  genCoroTypeParam.constraint = module.sym"any"
  module.add(genType(ttyCoroutine, "coroutine", true, some(@[genCoroTypeParam])))

proc genPtr*(module: Module, typeId: TypeId, name: string): Sym =
  let kind = case typeId
    of tyPointer: ttyPointer
    else: ttyPointer
  result = genType(kind, name, true)
  module.add(result)

proc getModuleName*(module: Module): string =
  ## Get the module name for the JS export
  ## This proc will transform the file name into a valid JS identifier
  assert module.name.len > 0
  let name = module.name.splitFile().name
  # Remove any non-alphanumeric characters and replace with underscores
  var i = 0
  while i < name.len:
    case name[i]
    of 'a'..'z', 'A'..'Z', '0'..'9':
      result.add(name[i])
    of '-', '_':
      # skip dashes and underscores
      # and convert the next character to uppercase
      if i + 1 < name.high and name[i + 1].isAlphaAscii:
        result.add(name[i + 1].toUpperAscii())
      inc(i)
    else: continue
    inc(i)
  result = result.capitalizeAscii()