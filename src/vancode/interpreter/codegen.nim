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

## Bytecode code generator for VanCode. Takes an AST produced by the parser and
## emits bytecode for the VM. Supports global and local variables, procedures
## (with parameters, return types, and exports), iterators, generic instantiation
## with type inference, object/array constructors, infix and prefix operators
## (built-in and proc-call fallback), control flow (for/while/if/block) with
## break/continue flow blocks, overload resolution, module imports, field access
## (get/set), compilation policy enforcement, and a standard library hook system.
## The codegen is modular and extensible via parser callbacks and the `codegen`
## macro for injecting line-information guards.

import std/[macros, options, os, hashes,
            sequtils, strutils, tables, json]

import ./[ast, chunk, errors, sym, value, resolver]
import ../manager/[configurator, packager]
import pkg/voodoo/extensibles

var globalTypeCounter* {.global.}: int = 0

type
  ContextAllocator {.acyclic.} = ref object
    # A context allocator. shared between codegen instances
    occupied: seq[Context]
      # a list of occupied contexts. this is used to allocate and free contexts.

  FlowBlockKind = enum
    # the kind of flow block. this is used to determine how
    # breaks and continues should work in the current block
    fbLoopOuter  # outer loop flow block, used by ``break``
    fbLoopIter   # iteration loop flow block, used by ``continue``

  FlowBlock {.acyclic.} = ref object
    # a flow block. this is used to handle control flow for
    # loops and other flow control structures. it keeps track of any breaks
    kind: FlowBlockKind
      # the kind of flow block
    breaks: seq[int]
      # a list of the positions of any breaks in this flow block
    bottomScope: int
      # the index of the scope at which this flow block was created
    context: Context
      # the context of the flow block. this is used to determine if a break or

  GenKind = enum
    # the kind of code generator. this is used to
    # determine how certain nodes are
    gkToplevel
    gkProc
    gkBlockProc
    gkIterator
    gkHtmlNest

  CodeGenCache* = object
    ## A cache for code generation. This is used to store
    ## the ASTs of included files, so that they don't need
    ## to be re-parsed every time they're included
    cachedAst*: Table[string, Ast]

  ParserCallback* = proc(astProgram: var Ast, path: string, resolver: FileResolver)
    ## Used to parse custom nodes during code generation.

  CodeGen* {.acyclic.} = ref object
    ## a code generator for a module or proc.
    includeBasePath: Option[string]
      ## the base path for including partials
    script: Script
      # the script all procs go into
    module*: Module
      ## the global scope for this code generator. this is where all
      ## global variables and procs are declared
    chunk: Chunk
      # the chunk of code we're generating into. this is used to
      # emit bytecode instructions
    scopes: seq[Scope]
      # a stack of scopes. this is used to handle variable declarations and lookups
    flowBlocks: seq[FlowBlock]
      # a stack of flow blocks. this is used to handle control
      # flow for loops and other flow control structures
    ctxAllocator: ContextAllocator
    context: Context
      # the codegen's scope context. this is used to achieve \
      # scope hygiene with iterators
    case kind: GenKind          # what this generator generates
    of gkToplevel, gkHtmlNest: discard
    of gkProc, gkBlockProc:
      procReturnTy: Sym         # the proc's return type
    of gkIterator:
      iter: Sym                 # the symbol representing the iterator
      iterForBody: Node         # the for loop's body
      iterForVar: Node          # the for loop variable's name
      iterForCtx: Context       # the for loop's context
    resolver*: FileResolver
      ## the file resolver used for resolving imports and includes. This is shared
      ## between codegen instances to maintain a consistent cache of resolved files.
    pkgr: Packager
      # the package manager used for resolving packages
    parserCallback*: ParserCallback
      ## a callback used to parse custom nodes
    stdlibs: StandardLibrary
    triggerFromPath: Option[string]
    allowExprResult*: bool
      # Whether to allow expressions to produce a value in
      # statement position. This is used for the REPL or embedding codegen in other tools
    counter: uint16
      # a counter used for generating unique labels and symbols. this is used to
      # avoid name collisions when generating code for things like loops and if statements
    policy*: CompilationPolicy
      ## Compilation policy controlling which features are allowed
    fwdDecl: seq[Node]
    # instantiationCache: Table[Hash, Sym]

  ModuleLibrary* = proc(script: Script, systemModule: Module): Module
    # a procedure where we can add FFI procs and types to a module
   
  StandardLibrary* = TableRef[string, ModuleLibrary]
    # a table of standard library modules

var codegenCache* = CodeGenCache()
var vanCodeStmtNodeKinds*: seq[NodeKind] = @[nkFor, nkWhile, nkIf, nkBlock]
proc count*(gen: CodeGen): uint =
  ## Get the current value of the codegen's counter, and increment it.
  result = gen.counter
  inc(gen.counter)

proc error*(node: Node, msg: string) =
  ## Raise a compile error on the given node.
  raise (ref CodeGenError)(
          # file: node.file,
          ln: node.ln,
          col: node.col,
          msg: ErrorFmt % ["", $node.ln, $node.col, msg]
        )

import std/terminal
proc warn(node: Node, msg: string) =
  # Output a warning message on the given node.
  stdout.styledWriteLine(fgYellow, styleBright, "Warning ",
      resetStyle, fgDefault, ErrorFmt % ["", $node.ln, $node.col, msg])

proc allocCtx*(allocator: ContextAllocator): Context =
  ## Allocate a new context
  while result in allocator.occupied:
    result = Context(result.int + 1)
  allocator.occupied.add(result)

proc freeCtx*(allocator: ContextAllocator, ctx: Context) =
  ## Free a context
  let index = allocator.occupied.find(ctx)
  assert index != -1, "freeCtx called on a context more than one time"
  allocator.occupied.del(index)

proc initCodeGen*(script: Script, module: Module, chunk: Chunk,
        kind = gkToplevel, ctxAllocator: ContextAllocator = nil,
        pkgr: Packager = nil,
        parserCallback: ParserCallback = nil,
        policy: CompilationPolicy = CompilationPolicy()): CodeGen =
  result = CodeGen(
    script: script,
    module: module,
    chunk: chunk,
    kind: kind,
    pkgr: pkgr,
    parserCallback: parserCallback,
    policy: policy,
  )
  if ctxAllocator == nil:
    result.ctxAllocator = ContextAllocator()
    result.context = result.ctxAllocator.allocCtx()
  result.resolver = initResolver()

proc clone(gen: CodeGen, kind: GenKind): CodeGen =
  # Clone a code generator, using a different kind for the new one.
  result = CodeGen(script: gen.script, module: gen.module, chunk: gen.chunk,
                   scopes: gen.scopes, flowBlocks: gen.flowBlocks,
                   ctxAllocator: gen.ctxAllocator, context: gen.context,
                   kind: kind)

template genGuard(body) =
  # Wraps ``body`` in a "guard" used for code generation. The guard sets the
  # line* information in the target chunk. This is a helper used by {.codegen.}.
  when declared(node):
    let
      oldFile = gen.chunk.file
      oldLn = gen.chunk.ln
      oldCol = gen.chunk.col
    # gen.chunk.file = node.file
    gen.chunk.ln = node.ln
    gen.chunk.col = node.col
  body
  when declared(node):
    gen.chunk.file = oldFile
    gen.chunk.ln = oldLn
    gen.chunk.col = oldCol

macro codegen(theProc: untyped): untyped =
  # Wrap ``theProc``'s body in a call to ``genGuard``.
  theProc.params.insert(1,
    newIdentDefs(ident"gen", ident"CodeGen"))
  if theProc[6].kind != nnkEmpty:
    theProc[6] = newCall("genGuard", theProc[6])
  result = theProc

#
# forward declarations
#
proc declareVar*(gen: CodeGen, name: Node, kind: SymKind,
              ty: Sym, isMagic = false, varExport = false): Sym {.discardable.}
proc pushDefault(gen: CodeGen, ty: Sym)
proc popVar(gen: CodeGen, name: Node)
proc lookup(gen: CodeGen, symName: Node, quiet = false): Sym
proc genScript*(program: Ast, includePath: Option[string], emitHalt: static bool = true) {.codegen.}
proc genExpr*(node: Node, varUnwrap = true): Sym {.codegen.}
proc genBlock*(node: Node, isStmt: bool): Sym {.codegen.}
proc genStmt*(node: Node) {.codegen.}
proc genProc*(node: Node, isInstantiation = false): Sym {.codegen.}
proc genIterator*(node: Node, isInstantiation = false): Sym {.codegen.}
proc genObject*(node: Node, isInstantiation = false): Sym {.codegen.}
proc genObjectStorage*(node: Node, isInstantiation = false): Sym {.codegen.}
proc genArray*(node: Node, isInstantiation = false): Sym {.codegen.}
proc genGetField*(node: Node): Sym {.codegen.}
proc genTypeDef*(node: Node): Sym {.codegen.}
proc genFor*(node: Node) {.codegen.}
proc procCall*(node: Node, procSym: Sym): Sym {.codegen.}

let callBuiltinEcho = ast.newCall(ast.newIdent"echo")
  # some cached nodes for codegen optimizations

proc varCount(scope: Scope): int =
  # Count the number of variables in a scope.
  len(scope.variables)

proc varCount(gen: CodeGen, bottom = 0): int =
  # Count the number of variables in all of the codegen's scopes.
  for scope in gen.scopes[bottom..^1]:
    result += scope.varCount

proc currentScope(gen: CodeGen): Scope =
  # Returns the current scope.
  result = gen.scopes[^1]

proc pushScope(gen: CodeGen) =
  # Push a new scope.
  gen.scopes.add(Scope(context: gen.context))

proc popScope(gen: CodeGen) =
  # Pop the top scope, discarding its variables.
  let s = gen.scopes.pop()
  # Emit discard for each variable in the scope to clean up its
  # stack slot. popVar stores values into slots via opcPopL, but
  # the slot value is still on the stack array and would leak as
  # the script result. Emitting opcDiscard removes it.
  if s.variables.len > 0:
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(s.variables.len.uint8)

proc scope(gen: CodeGen, index: int): Scope =
  ## Gets the local scope at level ``index``.
  ## This treats -1 as the global scope.
  result =
    if index == -1: gen.module # returns the global scope
    else: gen.scopes[index] # returns the local scope at index

proc addSym(gen: CodeGen, sym: Sym,
        lookupName: Node = nil, scopeOffset = 0) =
  ## Add a symbol to a scope. If ``name.len != 0``, ``$name`` is used as the
  ## symbol's lookup name instead of ``$sym.name``.
  let name: Node =
    if lookupName != nil: lookupName
    else: sym.name
  if gen.scopes.len > 0:
    # local sym
    if not gen.scope(gen.scopes.high - scopeOffset).add(sym, name):
      name.error(ErrLocalRedeclaration % [$name])
  else:
    # global sym
    if not gen.module.add(sym, name):
      name.error(ErrGlobalRedeclaration % [$name])

proc newProc*(script: Script, name, impl: Node,
        params: seq[ProcParam], returnTy: Sym,
        kind: ProcKind, exported = false,
        genKind: GenKind = gkToplevel): (Sym, Proc) =
  ## Creates a procedure for the given script. Returns its symbol and Proc
  ## object. This does not add the procedure to the script!
  var
    exported = exported
    identName: Node
  if name.kind == nkIdent:
    # when name is nkIdent we create a named proc
    identName = name
  elif name.kind == nkEmpty:
    # when name is nkEmpty we create an anonymous proc
    identName = ast.newNode(nkIdent)
    identName.ident = "anonymous:" & $script.procs.len
  else:
    # when name is a postfix node, we create a named proc
    # and mark it as exported if the name is a postfix node
    exported = true
    assert name.kind == nkPostfix, "Invalid postfix node for function identifier"
    identName = name[1] # returns the function ident name

  if identName.ident.len > 0:
    identName.ident = identName.ident[0] & identName.ident[1..^1].toLowerAscii()
  
  if genKind != gkToplevel and exported:
    # if the proc is not a top-level proc, it cannot be exported
    identName.error(ErrExportOnlyTopLevel)
  let
    id = script.procs.len.uint16
    hasReturnType =
      if returnTy.kind == skType:
        returnTy.tyKind != ttyVoid
      else:
        returnTy.kind == skGenericParam
    theProc =
      Proc(
        name: identName.ident, kind: kind,
        paramCount: params.len,
        hasResult: hasReturnType,
        jitReturnBool: returnTy.kind == skType and returnTy.tyKind == ttyBool,
        jitReturnString: returnTy.kind == skType and returnTy.tyKind == ttyString
      )
    sym = newSym(skProc, identName, impl)
  sym.procId = id
  sym.src = some(script.mainChunk.file)
  sym.procParams = params
  sym.procReturnTy = returnTy
  sym.procExport = exported
  result = (sym, theProc)

const currentContext = Context(high(uint16))

proc pushFlowBlock(gen: CodeGen, kind: FlowBlockKind,
                   context = currentContext) =
  # Push a new flow block. This creates a new scope for the flow block.
  let fblock = FlowBlock(kind: kind, bottomScope: gen.scopes.len)
  if context == currentContext:
    fblock.context = gen.context
  else:
    fblock.context = context
  gen.flowBlocks.add(fblock)
  gen.pushScope()

proc breakFlowBlock(gen: CodeGen, fblock: FlowBlock) =
  # Break a code block. This discards the flow block's scope's variables *and*
  # generates a jump past the block.
  # This does not remove the flow block from the stack, it only jumps past it
  # and discards any already declared variables.
  gen.chunk.emit(opcDiscard)
  gen.chunk.emit(gen.varCount(fblock.bottomScope).uint8)
  gen.chunk.emit(opcJumpFwd)
  fblock.breaks.add(gen.chunk.emitHole(2))

proc popFlowBlock(gen: CodeGen) =
  ## Pop the topmost flow block, popping its scope and filling in any breaks.
  gen.popScope()
  for brk in gen.flowBlocks[^1].breaks:
    gen.chunk.patchHole(brk)
  discard gen.flowBlocks.pop()

proc findFlowBlock(gen: CodeGen, kinds: set[FlowBlockKind]): FlowBlock =
  # Find the topmost flow block, with the given kind, and defined in the same
  # context as ``gen``'s current context.
  # Returns ``nil`` if a matching flow block can't be found.
  for i in countdown(gen.flowBlocks.len - 1, 0):
    let fblock = gen.flowBlocks[i]
    if fblock.context == gen.context and fblock.kind in kinds:
      return fblock

proc declareVar*(gen: CodeGen, name: Node, kind: SymKind, ty: Sym,
                isMagic = false, varExport = false): Sym {.discardable.} =
  ## Declare a new variable with the given ``name``, of the given ``kind``, with
  ## the given type ``ty``.
  ## If ``isMagic == true``, this will disable some error checks related to
  ## magic variables (eg. shadowing ``result``).

  # check if the variable's name is not ``result`` when in a non-void proc
  if not isMagic and gen.kind == gkProc and gen.procReturnTy.tyKind != ttyVoid:
    if name.ident == "result": name.error(ErrShadowResult)

  # create the symbol for the variable
  assert kind in skVars, "Got " & $(kind) & " expected " & $(skVars)
  name.ident = 
    if name.ident.len > 1:
      name.ident[0] & name.ident[1..^1].toLowerAscii()
    else:
      name.ident
  result = newSym(kind, name)
  result.varTy = ty
  # result.varSet = false
  result.varLocal =
    if gen.scopes.len > 0:
      result.varStackPos = gen.varCount;
      true
    else: false
  if not result.varLocal:
    result.varExport = varExport
  gen.addSym(result) # add the symbol to the current scope

proc instantiate(gen: CodeGen, sym: Sym, args: seq[Sym],
                 errorNode: Node): Sym =
  ## Instantiate a generic symbol using the given ``params``.
  assert sym.genericParams.isSome, "symbol must be generic"

  # we need to handle some special cases when dealing with generic generic
  # arguments, more on that below
  let hasGenericGenericArgs = args.anyIt(it.isGeneric)

  # if an instantiation has already been made, return it
  if not hasGenericGenericArgs and args in sym.genericInstCache:
    result = sym.genericInstCache[args]
  # otherwise, we need to create the instantiation from scratch
  else:
    # we need to create a temporary scope for the
    # resulting instantiation and the generic arguments
    gen.pushScope()
    # and of course, in that scope, we add those generic arguments
    if args.len != sym.genericParams.get.len:
      errorNode.error(ErrGenericArgLenMismatch %
                      [$args.len, $sym.genericParams.get.len])
    for i, param in sym.genericParams.get:
      gen.addSym(args[i], lookupName = param.name)

    case sym.kind
    of skType:
      # instantiations are only special for object types,
      # if we don't have any generic generic args
      if not hasGenericGenericArgs and sym.tyKind == ttyObject:
        # result = gen.genObject(sym.impl, isInstantiation = true)
        result = gen.genObjectStorage(sym.impl, isInstantiation = true)
      # anything else creates a copy that makes a given
      # type distinct for the given generic arguments
      else:
        result = sym.clone()
        result.genericInstCache.clear()
    of skProc:
      result = gen.genProc(sym.impl, isInstantiation = true)
    of skIterator:
      result = gen.genIterator(sym.impl, isInstantiation = true)
    else:
      errorNode.error(ErrNotGeneric % $errorNode)
    # after we're done, we can remove the instantiation scope
    gen.popScope()
  result.genericInstArgs = some(args)
  result.genericBase = some(sym)

proc inferGenericArgs(gen: CodeGen, sym: Sym,
                      argTypes: seq[Sym], callNode: Node): seq[Option[Sym]] =
  ## Use a simple recursive algorithm to infer the generic arguments for an
  ## expression. ``sym`` is the generic symbol, and ``argTypes`` are the types
  ## of arguments in a procedure or iterator call. The resulting sequence are
  ## the inferred generic argument types. If a type could not be inferred,
  ## it will be ``None``.
  assert sym.isGeneric, "symbol must be generic for type inference"

  proc walkType(types: var Table[Sym, Sym], procTy, callTy: Sym) =
    # this procedure walks through the given type and
    # fills in the ``types`` table with the appropriate types.

    # generic parameters are our main point of interest:
    # we take the call type and bind it to the type in the proc signature.
    # if the type is already bound, we compare the two and see if there's a type
    # mismatch.
    if procTy.kind == skGenericParam:
      if procTy notin types:
        types[procTy] = callTy
      else:
        let existing = types[procTy]
        let existingIsAny = existing.kind == skType and existing.tyKind == ttyAny
        let callTyIsAny = callTy.kind == skType and callTy.tyKind == ttyAny
        if existingIsAny and not callTyIsAny:
          types[procTy] = callTy
        elif not existingIsAny and not callTyIsAny and existing != callTy:
          callNode.error(ErrTypeMismatch % [$callTy, $existing])

    # as for generic types: we take all their arguments and recursively walk
    # through them. we know that ``callTy`` is compatible with this, because
    # overload resolution is done before generic param inference.
    elif procTy.genericInstArgs.isSome():
      for i, procArg in procTy.genericInstArgs.get():
        if callTy.genericInstArgs.isSome():
          let callArg = callTy.genericInstArgs.get()[i]
          walkType(types, procArg, callArg)

    # we don't care about any other types, as they're not related to generic
    # types inference.

  # to infer the generic parameters, we're going to call walkType with the
  # 'root' type pairs. those are the types in the proc's signature and the types
  # passed in through ``argTypes``.
  var types: Table[Sym, Sym]
  for i, procParam in sym.params:
    let
      procTy = procParam.ty
      callTy = argTypes[i]
    walkType(types, procTy, callTy)

  # after we walk the types, we'll collect them into our resulting seq.
  for genericParam in sym.genericParams.get():
    result.add(if genericParam in types: some(types[genericParam])
               else: Sym.none)

template sameScope(): untyped =
  (gen.scopes[i].context == gen.context or gen.scopes[i].context == gen.iterForCtx)

proc varLookup(gen: CodeGen, id: string): Sym =
  # Look up the symbol with the given `name`.
  if gen.scopes.len > 0:
    for i in countdown(gen.scopes.high, 0):
      if sameScope() and id in gen.scopes[i].variables:
        return gen.scopes[i].variables[id]

  # try to find a global symbol if no local symbol was found
  if result == nil and id in gen.module.variables:
    return gen.module.variables[id]

proc funcLookup(gen: CodeGen, id: string): Sym =
  # Look up the symbol with the given `name`.
  if gen.scopes.len > 0:
    for i in countdown(gen.scopes.high, 0):
      if sameScope() and id in gen.scopes[i].functions:
        return gen.scopes[i].functions[id]

  # try to find a global symbol if no local symbol was found
  if result == nil and id in gen.module.functions:
    return gen.module.functions[id]

proc typeLookup(gen: CodeGen, id: string): Sym =
  # Look up the symbol with the given `name`.
  if gen.scopes.len > 0:
    for i in countdown(gen.scopes.high, 0):
      if sameScope() and id in gen.scopes[i].typeDefs:
        return gen.scopes[i].typeDefs[id]

  # try to find a global symbol if no local symbol was found
  if result == nil and id in gen.module.typeDefs:
    return gen.module.typeDefs[id]

proc unwrapBaseIdent(n: Node): Node =
  # Extract left-most identifier from nested bracket/dot expressions
  var cur = n
  while cur != nil:
    case cur.kind
    of nkIdent:
      return cur
    of nkBracket, nkDot:
      if cur.len == 0: return nil
      cur = cur[0]
    else:
      return nil

proc lookup(gen: CodeGen, symName: Node, quiet = false): Sym =
  # Look up the symbol with the given ``name``. If ``quiet`` is true,
  # an error will not be raised on undefined reference
  var name: Node
  case symName.kind
  of nkIdent:
    name = symName     # regular ident
  of nkCall:
    name = symName[0]  # function call
  of nkVarTy:
    name = symName.varType
  of nkIndex:
    if symName[0].kind == nkIndex:
      # todo handle deeply nested generic instantiation
      return gen.lookup(symName[0], quiet)  # generic instantiation
    name = symName[0]  # generic instantiation
  of nkBracket:
    name = unwrapBaseIdent(symName)
  else: discard
  
  if name == nil or name.kind != nkIdent:
    # invalid symbol name
    symName.error(ErrInvalidSymName % symName.render)

  let id = 
    if name.ident.len > 1:
      name.ident[0] & name.ident[1..^1].toLowerAscii()
    else:
      name.ident

  # try find the symbol in the types table
  result = gen.typeLookup(id)
  
  # try find the symbol in the variables table
  if result == nil: result = gen.varLookup(id)

  # try find the symbol in the functions table
  if result == nil:
    result = gen.funcLookup(id)

  if result == nil:
    if not quiet:
      name.error(ErrUndefinedReference % $name)
      return

  if symName.kind == nkIndex:
    if result.isGeneric:
      var genericParams: seq[Sym]
      if symName.kind == nkIndex:
        for param in symName[1..^1]:
          genericParams.add(gen.lookup(param))
      result = gen.instantiate(result, genericParams, errorNode = name)
    else:
      name.error(ErrNotGeneric % name.render)

proc popVar(gen: CodeGen, name: Node) =
  # Pop the value at the top of the stack to the variable ``name``.
  let id = 
    if name.ident.len > 1:
      name.ident[0] & name.ident[1..^1].toLowerAscii()
    else:
      name.ident
  let sym: Sym = gen.varLookup(id)
  assert sym != nil
  
  if sym.varLocal:
    gen.chunk.emit(opcPopL)
    gen.chunk.emit(sym.varStackPos.uint8)
  else:
    # if it's a global, always use popG
    gen.chunk.emit(opcPopG)
    gen.chunk.emit(gen.chunk.getString(id))
  # mark the variable as set
  sym.varSet = true

proc pushVar(gen: CodeGen, sym: Sym) =
  ## Push the variable represented by ``sym`` to the top of the stack.
  # assert sym.kind in skVars, "The symbol must represent
  # a variable. Got " & $sym.kind
  case sym.kind
  of skVars:
    if sym.varLocal:
      gen.chunk.emit(opcPushL)
      gen.chunk.emit(sym.varStackPos.uint8)
    else:
      gen.chunk.emit(opcPushG)
      gen.chunk.emit(gen.chunk.getString(sym.name.ident))
  of skProc:
    gen.chunk.emit(opcPushProc)
    gen.chunk.emit(gen.chunk.getString(gen.chunk.file))
    gen.chunk.emit(sym.procId.uint16)
  else: discard

proc pushDefault(gen: CodeGen, ty: Sym) =
  ## Push the default value for the type ``ty`` onto the stack.
  assert ty.kind == skType, "Only types have default values"
  # assert ty.tyKind notin tyMeta, "Type `" & $ty.tyKind & "` does not have a default value"
  case ty.tyKind
  of ttyBool:
    gen.chunk.emit(opcPushFalse)
  of ttyInt:
    gen.chunk.emit(opcPushI)
    gen.chunk.emit(0'i64)
  of ttyFloat:
    gen.chunk.emit(opcPushF)
    gen.chunk.emit(0'f64)
  of ttyString:
    gen.chunk.emit(opcPushS)
    gen.chunk.emit(gen.chunk.getString(""))
  of ttyObject:
    gen.chunk.emit(opcPushNil)
    gen.chunk.emit(uint16(tyFirstObject + ty.objectId))
  of ttyJson:
    gen.chunk.emit(opcPushJNil)
    gen.chunk.emit(uint16(tyJsonStorage))
  of ttyPointer:
    gen.chunk.emit(opcPushPointer)
    gen.chunk.emit(uint16(ttyPointer))
  of ttyAny:
    gen.chunk.emit(opcPushS)
    gen.chunk.emit(gen.chunk.getString(""))
  of ttyArray:
    gen.chunk.emit(opcConstrArray)
    gen.chunk.emit(uint16(0))
  of ttyNil:
    gen.chunk.emit(opcPushS)
    gen.chunk.emit(gen.chunk.getString(""))
    # gen.chunk.emit(opcPushNil)
    # gen.chunk.emit(uint16(0))
  else: discard  # unreachable

proc getDefaultSym*(gen: CodeGen, kind: NodeKind): Sym =
  ## Returns the default type for the given node kind.
  case kind
  of nkBool:   result = gen.module.sym"bool"
  of nkInt:    result = gen.module.sym"int"
  of nkFloat:  result = gen.module.sym"float"
  of nkString: result = gen.module.sym"string"
  of nkArray:  result = gen.module.sym"array"
  of nkNil:    result = gen.module.sym"nil"
  of nkObjectStorage: result = gen.module.sym"object"
  else: discard

proc pushConst*(node: Node): Sym {.codegen.} =
  ## Generate a push instruction for a constant value.
  case node.kind
  of nkBool:
    # bools - use pushTrue and pushFalse
    if node.boolVal == true:
      gen.chunk.emit(opcPushTrue)
    else:
      gen.chunk.emit(opcPushFalse)
    result = gen.module.sym"bool"
  of nkInt:
    # ints - use pushI with an int Value
    gen.chunk.emit(opcPushI)
    gen.chunk.emit(node.intVal)
    result = gen.module.sym"int"
  of nkFloat:
    # floats - use pushF with a float Value
    gen.chunk.emit(opcPushF)
    gen.chunk.emit(node.floatVal)
    result = gen.module.sym"float"
  of nkString:
    # strings - use pushS with a string ID
    gen.chunk.emit(opcPushS)
    gen.chunk.emit(gen.chunk.getString(node.stringVal))
    result = gen.module.sym"string"
  of nkNil:
    # nil - use pushNil
    gen.chunk.emit(opcPushNil)
    gen.chunk.emit(uint16(0))
    result = gen.module.sym"nil"
  else: discard

proc findOverload*(sym: Sym, args: seq[Sym],
          errorNode: Node = nil, quiet = false): Sym {.codegen.} =
  ## Finds the correct overload for ``sym``, given the parameter types.
  case sym.kind:
  of skProc:
    # if we don't have multiple choices, we just
    # check if the param lists are compatible
    result =
      # todo
      # if sym.procType == ProcType.procTypeMacro:
      #   if sym.sameParams(args[0..^2]): sym
      #   else: nil
      # else:
      if sym.sameParams(args): sym
      else: nil
  of skIterator:
    # same as above, but for iterators
    result =
      if sym.sameParams(args): sym
      else: nil
  of skChoice:
    # otherwise, we find a matching overload by iterating through the list of
    # choices. this isn't the most efficient solution and can be optimized to use
    # a table for O(1) lookups, but time will tell if that's necessary.
    for choice in sym.choices:
      case choice.kind:
      of skProc:
        if choice.procType == ProcType.procTypeMacro:
          if choice.kind in skCallable and choice.sameParams(args[0..^2]):
            result = choice
            break
        else:
          if choice.kind in skCallable and choice.sameParams(args):
            result = choice
            break
      of skIterator:
        if choice.kind in skCallable and choice.sameParams(args):
          result = choice
          break
      else: discard
  else: discard

  # if we failed to find an appropriate overload,
  # we give a nice error message to the user
  if (errorNode != nil and result == nil) and quiet == false:
    # <T, U, ...>
    var paramList = args.mapIt($it).join(", ")
    # possible overloads
    var overloadList: string
    let overloads =
      if sym.kind == skChoice: sym.choices
      else: @[sym]
    for overload in overloads:
      if overload.kind in skCallable:
        overloadList.add("\n  " & $overload)
    # the error
    errorNode.error(ErrTypeMismatchChoice % [paramList, overloadList])

template withBlock*(node: Node, isStmt: bool = false, body: untyped) =
  gen.pushScope()
  for i, s in node:
    if isStmt:
      # if it's a statement block,
      # generate its children normally
      gen.genStmt(s)
    else:
      # otherwise, treat the last statement as
      # an expression (and the value of the block)
      if i < node.len - 1:
        gen.genStmt(s)
      else:
        result = gen.genExpr(s)
  body
  # pop the block's scope
  gen.popScope()

const splittableCallKinds = {nkPrefix, nkInfix, nkCall, nkDot, nkBracket, nkString, nkIdent, nkArray}
proc splitCall*(ast: Node): tuple[callee: Sym, args: seq[Node]] {.codegen.} =
  ## Splits any call node (prefix, infix, call, dot access, dot call) into a
  ## callee (the thing being called) and parameters. The callee is resolved to a
  ## symbol.
  var
    callee: Node
    args: seq[Node]
  
  if ast.kind notin splittableCallKinds:
    # the AST node must be one of the following kinds
    ast.error("Cannot split call for node kind: " & $ast.kind)

  case ast.kind
  of nkPrefix:
    callee = ast[0]
    args = @[ast[1]]
  of nkInfix:
    callee = ast[0]
    args = ast[1..2]
  of nkCall:
    if ast[0].kind == nkDot:
      let lhs = ast[0]
      callee = lhs[1]
      args = @[lhs[0]]
      args.add(ast[1..^1])
    else:
      callee = ast[0]
      args = ast[1..^1]
  of nkDot:
    let calleeLookup = gen.lookup(ast[0])
    assert calleeLookup.kind in skVars,
      "Expected a variable, got " & $calleeLookup.kind
    case calleeLookup.varTy.tyKind
      of ttyObject:
        if ast[1].kind == nkCall:
          return (calleeLookup.varTy, @[ast])
        else:
          callee = newIdent("items")
          args = @[ast]
      of ttyPointer:
        # echo "Pointer dot access not implemented yet"
        # return (calleeLookup.varTy, @[ast])
        discard
      of ttyJson:
        # if the callee is a json storage we'll emit an error
        # because json fields/items cannot be called using dot notation
        if ast[1].kind == nkCall:
          callee = ast[1]
          args = @[ast[0]]
          args.add(ast[1..^1])
        else:
          ast[1].error("Use bracket notation to access JSON fields or items")
      else:
        callee = ast[1]
        args.add(ast[0])
        args.add(ast[1][1..^1])
  of nkBracket:
    # this is an array access, so we return the array and the index
    # as the callee and the argument, respectively
    # assert ast[0].kind == nkIdent, "Expected an identifier for array access, got " & $ast[0].kind
    let calleeLookup = gen.lookup(ast[0])
    assert calleeLookup.kind in skVars, "Expected a variable, got " & $calleeLookup.kind
    
    if calleeLookup.varTy.tyKind in {ttyArray, ttyJson}:
      callee = newIdent("items") # the built-in items() iterator
      args = @[ast]
    else:
      callee = ast[0]
      args = @[ast[1]]  # the index is the only argument
  of nkString:
    callee = ast
  of nkIdent:
    callee = newIdent("items") # the built-in items() iterator
    args = @[ast]
  of nkArray:
    callee = newIdent("items")
    args = @[ast]
  else: discard
  
  assert callee != nil
  result = (gen.lookup(callee), args)

proc resolveGenerics*(gen: CodeGen, callable: var Sym,
                    callArgTypes: seq[Sym], errorNode: Node) =
  ## Helper used to resolve generic parameters via inference.
  if callable.isGeneric:
    let genericArgs =
      gen.inferGenericArgs(callable, callArgTypes, errorNode).mapIt do:
        if it.isSome(): it.get()
        else:
          errorNode.error(ErrCouldNotInferGeneric % errorNode.render)
          nil
    callable = gen.instantiate(callable, genericArgs, errorNode)

proc callProc*(procSym: Sym, argTypes: seq[Sym],
              errorNode: Node = nil): Sym {.codegen.} =
  ## Generate code that calls a procedure. `errorNode`
  ## is used for error reporting.
  if procSym.kind in {skProc, skChoice}:
    # find the overload
    var theProc = gen.findOverload(procSym, argTypes, errorNode)
    if theProc.kind != skProc:
      errorNode.error(ErrSymKindMismatch % [$skProc, $theProc.kind])
  
    # resolve generic params
    gen.resolveGenerics(theProc, argTypes, errorNode)

    # Array type inference: when `add` is called on an array with `any`
    # element type, fix the element type from the item argument
    if theProc.name.ident == "add" and argTypes.len >= 2:
      let arrTy = unwrapType(argTypes[0])
      if arrTy.tyKind == ttyArray:
        let itemTy = unwrapType(argTypes[1])
        if arrTy.arrayTy == nil or arrTy.arrayTy.tyKind == ttyAny:
          arrTy.arrayTy = itemTy
        elif errorNode != nil and not arrTy.arrayTy.sameType(itemTy):
          errorNode.error(ErrTypeMismatch % [$itemTy, $arrTy.arrayTy])

    # Fill omitted optional parameters with defaults
    let params = theProc.procParams
    if argTypes.len < params.len:
      for i in argTypes.len ..< params.len:
        let p = params[i]
        if not p.isOpt:
          errorNode.error("missing required argument: " & p.name.ident)

        if p.implSym != nil and p.implSym.impl != nil:
          discard gen.genExpr(p.implSym.impl)  # pushes default value
        else:
          gen.pushDefault(unwrapType(p.ty))    # fallback by type

    # call the proc
    gen.chunk.emit(opcCallD)
    let theSource =
      if procSym.src.isSome(): procSym.src.get()
      else: gen.chunk.file # fallback to current file
    gen.chunk.emit(gen.chunk.getString(theSource))
    gen.chunk.emit(theProc.procId)
    
    # set the result type
    result = theProc.procReturnTy

  elif procSym.kind in skVars:
    discard # TODO: call through reference in variable
  # elif procSym.kind == skHtmlType:
  #   var theProc = gen.findOverload(procSym, argTypes, errorNode)
  #   gen.chunk.emit(opcCallD)
  #   gen.chunk.emit(theProc.procId)
  #   result = theProc.procReturnTy
  else:
    # anything that is not a proc cannot be called
    if errorNode != nil:
      errorNode.error(ErrNotAProc % $procSym.name)

proc prefix*(node: Node): Sym {.codegen.} =
  ## Generate instructions for a prefix operator.
  # TODO: see infix()
  var noBuiltin = false # is no builtin operator available?
  let ty = gen.genExpr(node[1]) # generate the operand's code
  
  # number operators
  if ty in [gen.module.sym"int", gen.module.sym"float"]:
    let isFloat = ty == gen.module.sym"float"
    case node[0].ident
      of "+": discard # + is a noop
      of "-": gen.chunk.emit(if isFloat: opcNegF else: opcNegI)
      else: noBuiltin = true # non-builtin operator
    return ty
  
  # bool operators
  if ty == gen.module.sym"bool":
    case node[0].ident
      of "not": gen.chunk.emit(opcInvB)
      else: noBuiltin = true # non-builtin operator
    return ty
  else: noBuiltin = true
  
  if noBuiltin:
    # if no builtin operator is available, will try
    # to call a procedure for the operator
    let procSym = gen.lookup(node[0])
    result = gen.callProc(procSym, argTypes = @[ty], node)

proc infix*(node: Node): Sym {.codegen.} =
  ## Generate instructions for an infix operator.

  # TODO: split this behemoth into compiler magic procs that deal with this
  # instead of keeping all the built-in operators here

  if node[0].ident notin ["=", "or", "and"]:
    # primitive operators
    var noBuiltin: bool # is there no built-in operator available?
    var
      aTy = gen.genExpr(node[1]) # generate the left operand's code
      bTy = gen.genExpr(node[2]) # generate the right operand's code
    case aTy.kind
    of skVars:
      aTy = aTy.varTy
    else: discard

    case bTy.kind
    of skVars:
      bTy = bTy.varTy
    else: discard

    let numOp = [gen.module.sym"float", gen.module.sym"int"]
    if (aTy in numOp and bTy in numOp):
      # number operators
      let areFloats =
        aTy == gen.module.sym"float" or bTy == gen.module.sym"float"
      case node[0].ident
      # arithmetic
      of "+": gen.chunk.emit(if areFloats: opcAddF else: opcAddI)
      of "-": gen.chunk.emit(if areFloats: opcSubF else: opcSubI)
      of "*": gen.chunk.emit(if areFloats: opcMultF else: opcMultI)
      of "/": gen.chunk.emit(if areFloats: opcDivF else: opcDivI)
      # relational
      of "==": gen.chunk.emit(if areFloats: opcEqF else: opcEqI)
      of "!=":
        gen.chunk.emit(if areFloats: opcEqF else: opcEqI)
        gen.chunk.emit(opcInvB)
      of "<": gen.chunk.emit(if areFloats: opcLessF else: opcLessI)
      of "<=":
        gen.chunk.emit(if areFloats: opcGreaterF else: opcGreaterI)
        gen.chunk.emit(opcInvB)
      of ">": gen.chunk.emit(if areFloats: opcGreaterF else: opcGreaterI)
      of ">=":
        gen.chunk.emit(if areFloats: opcLessF else: opcLessI)
        gen.chunk.emit(opcInvB)
      else: noBuiltin = true # unknown operator
      result =
        case node[0].ident
        # arithmetic operators return numbers.
        of "+", "-", "*", "/":
          if areFloats: gen.module.sym"float"
          else: gen.module.sym"int"
        # relational operators return bools
        of "==", "!=", "<", "<=", ">", ">=":
          gen.module.sym"bool"
        else: nil # type mismatch; we don't care
    elif aTy == bTy and aTy == gen.module.sym"bool":
      # bool operators
      case node[0].ident
      # relational
      of "==": gen.chunk.emit(opcEqB)
      of "!=": gen.chunk.emit(opcEqB); gen.chunk.emit(opcInvB)
      else: noBuiltin = true
      # bool operators return bools (duh.)
      result = gen.module.sym"bool"
    elif aTy == bTy and aTy == gen.module.sym"string":
      # string operators
      case node[0].ident
      of "&":
        gen.chunk.emit(opcConcatStr)
        result = gen.module.sym"string"
      of "==":
        gen.chunk.emit(opcEqS)
        result = gen.module.sym"bool"
      of "!=":
        gen.chunk.emit(opcEqS)
        gen.chunk.emit(opcInvB)
        result = gen.module.sym"bool"
      else: noBuiltin = true
    else: noBuiltin = true # no optimized operators for given type
    if noBuiltin:
      let procSym = gen.lookup(node[0])
      result = gen.callProc(procSym, argTypes = @[aTy, bTy], node)
  else:
    case node[0].ident
    # assignment is special
    of "=":
      if policyAny in gen.policy.disallow or policyAssignments in gen.policy.disallow:
        node.error(ErrPolicyViolation % "assignments are disabled")
      let
        receiver = node[1]
        value = node[2]
      case receiver.kind
      of nkIdent: # to a variable
        let sym = gen.lookup(receiver) # look the variable up
        # Detect x = x +/- 1 → incL/decL (local vars only)
        if sym.kind == skVar and sym.varLocal and value.kind == nkInfix and value[0].kind == nkIdent and
           value[0].ident in ["+", "-"]:
          let receiverName = if receiver.kind == nkIdent: receiver.ident else: ""
          let lhs = value[1]; let rhs = value[2]
          if (lhs.kind == nkIdent and lhs.ident == receiverName and
              rhs.kind == nkInt and rhs.intVal == 1) or
             (rhs.kind == nkIdent and rhs.ident == receiverName and
              lhs.kind == nkInt and lhs.intVal == 1):
            if value[0].ident == "+":
              gen.chunk.emit(opcIncL); gen.chunk.emit(sym.varStackPos.uint8)
            else:
              gen.chunk.emit(opcDecL); gen.chunk.emit(sym.varStackPos.uint8)
            return gen.module.sym"void"
        let valTy = gen.genExpr(value)
        if valTy == sym.varTy:
          if sym.kind == skVar:
            gen.popVar(receiver)
          else:
            receiver.error(ErrImmutableReassignment % $sym.name)
        else:
          node.error(ErrTypeMismatch % [$valTy.name, $sym.varTy.name])
      of nkDot: # to an object field
        if receiver[1].kind != nkIdent:
          # object fields are always identifiers
          receiver[1].error(ErrInvalidField % $node[1][1])
        let
          typeSym = gen.genExpr(receiver[0]) # generate the receiver's code
          fieldName = receiver[1].ident
          valTy = gen.genExpr(value) # generate the value's code
        if typeSym.tyKind == ttyObject and fieldName in typeSym.objectFields:
          # assign the field if it's valid, using popF
          let field = typeSym.objectFields[fieldName]
          if valTy != field.ty:
            node[2].error(ErrTypeMismatch % [$field.ty.name, $valTy.name])
          gen.chunk.emit(opcSetF)
          gen.chunk.emit(field.id.uint8)
        else:
          # otherwise, try to find a matching setter
          let setter = gen.lookup(newIdent(fieldName & '='))
          if setter == nil:
            receiver.error(ErrNonExistentField % [fieldName, $typeSym])
          result = gen.callProc(setter, argTypes = @[typeSym, valTy],
                                errorNode = node)
      else: node.error(ErrInvalidAssignment % $node)
      # assignment doesn't return anything (in most cases, setters can be
      # declared to return a value, albeit it's not that useful)
      if result == nil:
        result = gen.module.sym"void"
    # ``or`` and ``and`` are special, because they're short-circuiting.
    # that's why they need a little more special care.
    of "or": # ``or``
      let
        lhs = node[1]
        rhs = node[2]
      let aTy = gen.genExpr(lhs) # generate the left-hand side
      # if it's ``true``, jump over the rest of the expression
      gen.chunk.emit(opcJumpFwdT)
      let hole = gen.chunk.emitHole(2)
      # otherwise, check the right-hand side
      gen.chunk.emit(opcDiscard)
      gen.chunk.emit(1'u8)
      let bTy = gen.genExpr(rhs) # generate the right-hand side
      if aTy.tyKind != ttyBool: lhs.error(ErrTypeMismatch % [$aTy, "bool"])
      if bTy.tyKind != ttyBool: rhs.error(ErrTypeMismatch % [$bTy, "bool"])
      gen.chunk.patchHole(hole)
      result = gen.module.sym"bool"
    of "and": # ``and``
      let
        lhs = node[1]
        rhs = node[2]
      let aTy = gen.genExpr(lhs) # generate the left-hand side
      # if it's ``false``, jump over the rest of the expression
      gen.chunk.emit(opcJumpFwdF)
      let hole = gen.chunk.emitHole(2)
      # otherwise, check the right-hand side
      gen.chunk.emit(opcDiscard)
      gen.chunk.emit(1'u8)
      let bTy = gen.genExpr(rhs) # generate the right-hand side
      if aTy.tyKind != ttyBool: lhs.error(ErrTypeMismatch % [$aTy, "bool"])
      if bTy.tyKind != ttyBool: rhs.error(ErrTypeMismatch % [$bTy, "bool"])
      gen.chunk.patchHole(hole)
      result = gen.module.sym"bool"
    of "&":
      # string concatenation
      let
        lhs = node[1]
        rhs = node[2]
      let aTy = gen.genExpr(lhs) # generate the left-hand side
      let bTy = gen.genExpr(rhs) # generate the right-hand side 
      if aTy.tyKind != ttyString:
        lhs.error(ErrTypeMismatch % [$aTy, "string"])
      if bTy.tyKind != ttyString:
        rhs.error(ErrTypeMismatch % [$bTy, "string"])
      gen.chunk.emit(opcConcatStr)
      result = gen.module.sym"string"
    else: discard

proc objConstr*(node: Node, ty: Sym, constructFromIdent = false): Sym {.codegen.} =
  ## Generate code for an object constructor
  result =
    if not constructFromIdent:
      gen.lookup(node[0])
    else:
      gen.lookup(node)

  if result.tyKind != ttyObject:
    node.error(ErrTypeIsNotAnObject % $result.name)

  var explicitFields: Table[string, Node]
  # Only parse explicit fields for call-style constructors: User(...)
  if not constructFromIdent and node.len > 1:
    for f in node[1..^1]:
      # Expected infix-like shape: [op, fieldIdent, valueExpr]
      if f.len < 2 or f[0].kind != nkIdent:
        f.error("Invalid object constructor field: " & f.render)
      elif f.kind != nkColon:
        f.error("Expected ':' in object constructor field: " & f.render)
      let fname = f[0].ident
      if not result.objectFields.hasKey(fname):
        f[0].error(ErrNonExistentField % [fname, $result])
      explicitFields[fname] = f[1]

  # OrderedTable preserves declaration order, so this is deterministic.
  var
    emittedCount = 0
    keyIds: seq[uint16]
  for k, field in result.objectFields:
    keyIds.add(gen.chunk.getString(k))
    if explicitFields.hasKey(k):
      let valTy = gen.genExpr(explicitFields[k])
      if not unwrapType(valTy).sameType(field.ty):
        node.error(ErrTypeMismatch % [$unwrapType(valTy).name, $field.ty.name])
    elif field.implVal != nil:
      discard gen.genExpr(field.implVal.impl) # default expr from type definition
    else:
      gen.pushDefault(field.ty)               # default(T)
    inc(emittedCount)

  gen.chunk.emit(opcConstrObj)
  gen.chunk.emit(uint16(emittedCount))
  for kid in keyIds:
    gen.chunk.emit(kid)

proc call*(node: Node): Sym {.codegen.} =
  ## Generates code for an nkCall (proc call or object constructor).
  ## TODO: Indirect calls
  case node[0].kind
  of nkIdent:
    # the call is direct or from a variable
    let sym = gen.lookup(node[0])  # lookup the left-hand side
    case sym.kind
    of skType: # object construction
      result = gen.objConstr(node, sym)
    else: # procedure call
      result = gen.procCall(node, sym)
  of nkDot:
    # the call is an indirect call or a method call
    let
      lhs = node[0]
      callee = gen.lookup(lhs[1], quiet = true)
    if callee == nil:
      assert false, "indirect calls are not implemented yet: " & node.render
    else:
      var argTypes = @[gen.genExpr(lhs[0])]
      for arg in node[1..^1]:
        argTypes.add(gen.genExpr(arg))
      result = gen.callProc(callee, argTypes, errorNode = node)
  else:
    # the call is an indirect call
    assert false, "indirect calls are not implemented yet: " & node.render

proc genGetField*(node: Node): Sym {.codegen.} =
  # Evaluate the receiver (can be an ident, bracket access, etc.)
  var recvSym = gen.genExpr(node[0], varUnwrap = false)
  var valTy: Sym =
    if recvSym.kind in skVars: recvSym.varTy else: recvSym

  # Pointers go through FFI
  if valTy.tyKind == ttyPointer:
    if policyAny in gen.policy.disallow or policyLoadDynlib in gen.policy.disallow:
      node.error(ErrPolicyViolation % "dynamic library loading is disabled")
    if node[1].kind == nkCall:
      for arg in node[1].children[1..^1]:
        discard gen.genExpr(arg)
      gen.chunk.emit(opcFFIGetProc)
      gen.chunk.emit(gen.chunk.getString(node[1][0].ident))
      gen.chunk.emit(uint8(node[1].children.len - 1))
      return valTy
    else:
      node[1].error("Pointer member access must be a call")

  if valTy.tyKind notin {ttyObject}:
    # Only objects can be accessed with dot/bracket
    # For non object/json receiver: treat `a.b` as `b(a)` and `a.b(x)` as `b(a, x)`.
    var
      calleeNode: Node
      argTypes: seq[Sym] = @[valTy]

    case node[1].kind
    of nkIdent, nkIndex:
      calleeNode = node[1]
    of nkCall:
      calleeNode = node[1][0]
      for arg in node[1].children[1..^1]:
        argTypes.add(gen.genExpr(arg))
    else:
      node[1].error(ErrInvalidField % $node[1])

    let fnSym = gen.lookup(calleeNode)
    return gen.callProc(fnSym, argTypes, node)

    # node[0].error(ErrTypeMismatch % [$valTy.name, "object|json"])

  # If it's JSON, dot notation is not supported
  if valTy.tyKind == ttyJson and node[1].kind notin {nkBracket, nkCall}:
    node[1].error("Use bracket notation to access JSON fields or items")

  # Method call on receiver: item.fn(...)
  if node[1].kind == nkCall:
    let callee = node[1][0]
    var fnSym = gen.lookup(callee)
    var argTypes: seq[Sym] = @[valTy]  # receiver first; it's already on stack
    for arg in node[1].children[1..^1]:
      argTypes.add(gen.genExpr(arg))
    return gen.callProc(fnSym, argTypes, node)

  if node[1].kind notin {nkIdent, nkBracket}:
    node[1].error(ErrInvalidField % $node[1])

  # Resolve field name
  var fieldName: string
  if node[1].kind == nkIdent:
    fieldName = node[1].ident
  elif node[1].kind == nkBracket and node[1][0].kind == nkIdent:
    fieldName = node[1][0].ident

  # Direct object field access
  if valTy.tyKind == ttyObject and valTy.objectFields.hasKey(fieldName):
    let field = valTy.objectFields[fieldName]
    result = field.ty
    gen.chunk.emit(opcGetF)
    gen.chunk.emit(field.id.uint8)
  else:
    let getter = gen.lookup(node[1], quiet = true)
    if getter != nil:
      result = gen.callProc(getter, argTypes = @[valTy], errorNode = node)
    else:
      if valTy.tyKind == ttyJson:
        node[1].error("Use bracket notation to access JSON fields or items")
      else:
        node[1].error(ErrNonExistentField % [fieldName, $valTy])

proc genArrayAccess*(node: Node): Sym {.codegen.} =
  # Handle array access using bracket notation.
  # also handles JSON object/array access using bracket notation.
  var
    valTy = gen.genExpr(node[0])
    indexTy = gen.genExpr(node[1])
  # unwrap value type if it's a variable
  if valTy.kind in skVars:  valTy = valTy.varTy
  
  # unwrap index type if it's a variable
  if indexTy.kind in skVars: indexTy = indexTy.varTy

  case valTy.tyKind
  of ttyJson:
    # generate the code for accessing a JSON array
    if indexTy.tyKind notin {ttyInt, ttyString, ttyJson}:
      node[1].error(ErrTypeMismatch % [$indexTy.name, "int|string|json<int|string>"])
    gen.chunk.emit(opcGetJ)
    result = valTy
  of ttyObject:
    if indexTy.tyKind != ttyString:
      node[1].error(ErrTypeMismatch % [$indexTy.name, "string"])
    # Allow bracket access for constant string keys
    if node[1].kind == nkString:
      let key = node[1].stringVal
      if valTy.objectFields.hasKey(key):
        let field = valTy.objectFields[key]
        gen.chunk.emit(opcGetF)
        gen.chunk.emit(field.id.uint8)
        return field.ty
      else:
        node[1].error(ErrNonExistentField % [key, $valTy])
    # dynamic string keys not supported at codegen time yet
    echo "not implemented yet: accessing object fields using dynamic string keys"
    result = valTy
  of ttyArray:
    if indexTy.tyKind != ttyInt:
      node[1].error(ErrTypeMismatch % [$indexTy.name, "int"])
    assert valTy.arrayTy != nil, "Array type must have an element type"
    gen.chunk.emit(opcGetI)
    return valTy.arrayTy
  else:
    gen.chunk.emit(opcGetI)
    result = valTy

proc genIf*(node: Node, isStmt: bool): Sym {.codegen.} =
  ## Generate code for an if expression/statement.
  if policyAny in gen.policy.disallow or policyConditionals in gen.policy.disallow:
    node.error(ErrPolicyViolation % "conditionals are disabled")

  # get some properties about the statement
  let
    hasElse = node.len mod 2 == 1
    branches =
      # separate the else branch from the rest of branches and conditions
      if hasElse: node[0..^2]
      else: node.children

  # then, we compile all the branches
  var jumpsToEnd: seq[int]
  for i in countup(0, branches.len - 1, 2):
    # if there was a previous branch, discard its condition
    if i != 0:
      gen.chunk.emit(opcDiscard)
      gen.chunk.emit(1'u8)

    # first, we compile the condition and check its type
    let
      cond = branches[i]
      condTy = gen.genExpr(cond)
    if condTy.tyKind notin {ttyBool, ttyJson}:
      cond.error(ErrTypeMismatch % [$condTy.name, "bool"])

    # if the condition is false, jump past the branch
    gen.chunk.emit(opcJumpFwdF)
    let afterBranch = gen.chunk.emitHole(2)

    # otherwise, discard the condition's value and execute the body
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)
    let
      branch = branches[i + 1]
      branchTy = gen.genBlock(branch, isStmt)

    # if the ``if`` is an expression, check its type
    if not isStmt:
      if result == nil: result = branchTy
      else:
        if branchTy != result:
          branch.error(ErrTypeMismatch % [$branchTy.name, $result.name])


    # after the block is done, jump to the end of the whole statement
    gen.chunk.emit(opcJumpFwd)
    jumpsToEnd.add(gen.chunk.emitHole(2))

    # we also need to fill in the previously created jump after the branch
    gen.chunk.patchHole(afterBranch)
    # after the branch, there's another branch or the end of the if statement

  # discard the last branch's condition
  gen.chunk.emit(opcDiscard)
  gen.chunk.emit(1'u8)

  # if we have an else branch, we need to compile it, too
  if hasElse:
    let
      elseBranch = node[^1]
      elseTy = gen.genBlock(elseBranch, isStmt)
    # check its type
    if not isStmt and elseTy != result:
      elseBranch.error(ErrTypeMismatch % [$elseTy.name, $result.name])
  else:
    if not isStmt:
      # raise an error if the if statement is an expression and
      # the else branch is missing
      node.error(ErrTypeMismatch % ["void", "expression"])

  # finally, fill all the jump gaps
  for jmp in jumpsToEnd:
    gen.chunk.patchHole(jmp)

  # if the 'if' is a statement, its type is void
  if isStmt:
    result = gen.module.sym"void"

# proc* storeJavaScript(node: Node): Sym {.codegen.} =
#   ## Store a JavaScript snippet into the current module.
#   gen.script.jsOutput.add(node.snippetCode)

proc genParam(name: Node, ty: Sym, sym: Sym = nil, isMut, isOpt = false): ProcParam =
  (name, ty, sym, isMut, isOpt)

proc collectParams*(formalParams: Node,
              genericParams: Option[seq[Sym]] = none(seq[Sym])): seq[ProcParam] {.codegen.} =
  # Helper used to collect parameters from an
  # `nkFormalParams` to a `seq[ProcParam]`
  if formalParams.len == 0: return
  for defs in formalParams[1..^1]:
    let
      rawTyNode = defs[^2]
      tyNode =
        if rawTyNode.kind == nkVarTy: rawTyNode.varType
        else: rawTyNode
      defaultNode = defs[^1]

    # Resolve declared parameter type (always from type position).
    var paramTy: Sym
    if tyNode.kind == nkEmpty:
      paramTy = gen.module.sym"stmt"
    elif tyNode.kind == nkIndex and tyNode[0].kind == nkIdent and tyNode[0].ident == "array":
      let
        baseArraySym = gen.lookup(tyNode[0])
        elemTy = gen.lookup(tyNode[1])
      paramTy = gen.instantiate(baseArraySym, @[elemTy], tyNode)
      paramTy.arrayTy = elemTy
    else:
      paramTy = gen.lookup(tyNode)

    # Optional lightweight type-check for literal defaults.
    if defaultNode.kind != nkEmpty:
      var defaultTy: Sym = nil
      case defaultNode.kind
      of nkBool, nkInt, nkFloat, nkString, nkNil, nkArray, nkObjectStorage:
        defaultTy = gen.getDefaultSym(defaultNode.kind)
      of nkIdent:
        let s = gen.lookup(defaultNode, quiet = true)
        if s != nil:
          defaultTy = unwrapType(s)
      else:
        discard

      if defaultTy != nil and not unwrapType(defaultTy).sameType(unwrapType(paramTy)):
        defaultNode.error(ErrTypeMismatch % [$unwrapType(defaultTy).name, $unwrapType(paramTy).name])

    # Build ProcParam entries (one per declared name).
    for name in defs[0..^3]:
      var implSym: Sym = nil
      let isOptional = defaultNode.kind != nkEmpty
      if isOptional:
        let defName =
          if name.kind == nkIdent: name.ident
          else: "param"
        implSym = newSym(
          skConst,
          newIdent("__default_" & defName & "_" & $gen.count()),
          impl = defaultNode
        )
      result.add(
        genParam(
          name,
          paramTy,
          implSym,
          isMut = rawTyNode.kind == nkVarTy,
          isOpt = isOptional
        )
      )

proc collectGenericParams*(genericParams: Node): Option[seq[Sym]] {.codegen.} =
  # Helper used to collect and declare
  # generic parameters from an nkGenericParams.
  if genericParams.kind == nkEmpty: return
  result = some[seq[Sym]](@[])
  for defs in genericParams:
    let constraint =
      if defs[^2].kind == nkEmpty:
        gen.module.sym"any"
      else:
        gen.lookup(defs[^2])
    for name in defs[0..^3]:
      let sym = newSym(skGenericParam, name, impl = name)
      sym.constraint = constraint
      gen.addSym(sym)
      result.get.add(sym)

proc genProc*(node: Node, isInstantiation = false): Sym {.codegen.} =
  # Process and compile a procedure.
  # push a new scope for generic parameters, if any
  if not isInstantiation and node[1].kind != nkEmpty:
    gen.pushScope()
  # get some basic metadata
  let
    name = node[0]
    formalParams = node[2]
    body = node[3]
    genericParams =
      if not isInstantiation:
        gen.collectGenericParams(node[1])
      else:
        seq[Sym].none
    params = gen.collectParams(formalParams, genericParams)
    returnTy = # empty return type == void
      if formalParams[0].kind != nkEmpty:
        gen.lookup(formalParams[0])
      else:
        gen.module.sym"void"
  
  # forward declaration: register symbol but don't compile body
  if body.kind == nkEmpty:
    var (sym, theProc) =
      newProc(gen.script, name, impl = node,
                params, returnTy, kind = pkNative,
                genKind = gen.kind)
    sym.genericParams = genericParams
    gen.addSym(sym, scopeOffset = ord(sym.genericParams.isSome))
    theProc.procId = gen.script.procs.len
    gen.script.procs.add(theProc)
    if sym.procExport:
      gen.script.procsExport.add(theProc)
    if not isInstantiation and sym.isGeneric:
      gen.popScope()
    return sym

  # check for matching forward declaration
  let nameIdent =
    if name.kind == nkPostfix: name[1]
    else: name
  let fwdMatchIdx = block:
    var idx = -1
    let lookupName = nameIdent.ident.toLowerAscii
    for i, fwd in gen.fwdDecl:
      let fwdName =
        if fwd[0].kind == nkPostfix: fwd[0][1]
        else: fwd[0]
      if fwdName.ident.toLowerAscii == lookupName:
        idx = i
        break
    idx

  if fwdMatchIdx >= 0:
    # Sync: compile body into the existing forward declaration's proc
    # Use lowered name since newProc normalizes idents to lowercase
    let fwdLookup = nameIdent.ident.toLowerAscii
    let fwdSym = gen.funcLookup(fwdLookup)
    if fwdSym == nil:
      node.error("forward declaration registered but symbol not found")
      return nil
    var
      chunk = newChunk(gen.chunk.file)
      procGen = initCodeGen(gen.script, gen.module, chunk, gkProc,
        ctxAllocator =
          if gen.kind == gkToplevel: nil
          else: gen.ctxAllocator
      )
    let theProc = gen.script.procs[fwdSym.procId]
    theProc.chunk = chunk
    chunk.file = gen.chunk.file
    procGen.procReturnTy = returnTy

    procGen.pushScope()
    for (pname, ty, implSym, isMut, isOpt) in params:
      var varType =
        if isMut: skVar
        else: skLet
      let param = procGen.declareVar(pname, varType, ty)
      param.varSet = true

    if returnTy.tyKind != ttyVoid:
      let res = newIdent("result")
      procGen.declareVar(res, skVar, returnTy, isMagic = true)
      procGen.pushDefault(returnTy)
      procGen.popVar(res)

    discard procGen.genBlock(body, isStmt = true)

    if returnTy.tyKind != ttyVoid:
      let resultSym = procGen.lookup(newIdent("result"))
      procGen.chunk.emit(opcPushL)
      procGen.chunk.emit(resultSym.varStackPos.uint8)
      procGen.chunk.emit(opcReturnVal)
    else:
      procGen.chunk.emit(opcReturnVoid)
    procGen.popScope()

    if not isInstantiation and fwdSym.isGeneric:
      gen.popScope()
    return fwdSym

  # normal function declaration (no forward decl)
  var (sym, theProc) =
    newProc(gen.script, name, impl = node,
              params, returnTy, kind = pkNative,
              genKind = gen.kind)
  sym.genericParams = genericParams
  gen.addSym(sym, scopeOffset = ord(sym.genericParams.isSome))

  if not sym.isGeneric or isInstantiation:
    var
      chunk = newChunk(gen.chunk.file)
      procGen = initCodeGen(gen.script, gen.module, chunk, gkProc,
        ctxAllocator =
          if gen.kind == gkToplevel: nil
          else: gen.ctxAllocator
      )
    theProc.chunk = chunk
    chunk.file = gen.chunk.file
    procGen.procReturnTy = returnTy

    procGen.pushScope()
    for (pname, ty, implSym, isMut, isOpt) in params:
      var varType =
        if isMut: skVar
        else: skLet
      let param = procGen.declareVar(pname, varType, ty)
      param.varSet = true

    if returnTy.tyKind != ttyVoid:
      let res = newIdent("result")
      procGen.declareVar(res, skVar, returnTy, isMagic = true)
      procGen.pushDefault(returnTy)
      procGen.popVar(res)

    theProc.procId = gen.script.procs.len
    gen.script.procs.add(theProc)
    if sym.procExport:
      gen.script.procsExport.add(theProc)

    discard procGen.genBlock(body, isStmt = true)

    if returnTy.tyKind != ttyVoid:
      let resultSym = procGen.lookup(newIdent("result"))
      procGen.chunk.emit(opcPushL)
      procGen.chunk.emit(resultSym.varStackPos.uint8)
      procGen.chunk.emit(opcReturnVal)
    else:
      procGen.chunk.emit(opcReturnVoid)
    procGen.popScope()
  else:
    theProc.procId = gen.script.procs.len
    gen.script.procs.add(theProc)

  if not isInstantiation and sym.isGeneric:
    gen.popScope()
  result = sym

proc genTypeDef*(node: Node): Sym {.codegen.} =
  # Generates code for a type definition
  for defNode in node:
    case defNode.kind
    of nkObject:
      discard gen.genObject(defNode)
    else: discard # todo

# This injects the extended module, which contains built-in procedures and types
injectExtendedModule()

when not declared(procCallOverwrite):
  proc procCall*(node: Node, procSym: Sym): Sym {.codegen.} =
    ## Generate code for a procedure call
    var argTypes: seq[Sym]
    for arg in node[1..^1]:
      let argSym: Sym = gen.genExpr(arg)
      assert argSym != nil, "Expression must return a symbol"
      argTypes.add(argSym)
    return gen.callProc(procSym, argTypes, errorNode = node)

proc genExpr*(node: Node, varUnwrap = true): Sym {.codegen.} =
  # Generates code for an expression.
  extendableCase "codeGenExpr":
    case node.kind
    of nkBool, nkInt, nkFloat, nkString, nkNil:  # constants
      result = gen.pushConst(node)
    of nkIdent:                     # variables
      var symNode = gen.lookup(node)
      case symNode.kind:
        of skType:
          case symNode.tyKind
            of ttyObject:
              # object construction from type identifier
              return gen.objConstr(node, symNode, constructFromIdent = true)
            else: discard
        else: discard
      # push the variable's value onto the stack
      gen.pushVar(symNode)
      if symNode.kind == skProc:
        return symNode
      return (
        if varUnwrap: symNode.varTy
        else: symNode
      )
    of nkPrefix:
      result = gen.prefix(node)
    of nkInfix:
      extendableCase "codegenInfixExpr":
        case node[0].ident:
        else:
          result = gen.infix(node)
    of nkDot:
      # handle field access using dot notation `$a.b`
      result = gen.genGetField(node)
    of nkBracket:
      # handle array access using square brackets `$a[0]`
      result = gen.genArrayAccess(node)
    of nkCall:                      # calls and object construction
      result = gen.call(node)
    of nkIf:                        # if expressions
      result = gen.genIf(node, isStmt = false)
    of nkArray:
      result = gen.genArray(node)        # array declaration
    of nkObjectStorage:
      result = gen.genObjectStorage(node)
    of nkObject:
      result = gen.genObject(node)
    of nkProc:
      result = gen.genProc(node)
    else:
      # handle statement-like nodes used as lazy-injected macro bodies
      if node.kind in vanCodeStmtNodeKinds:
        # emit the statement into the current chunk (this will produce the
        # code the macro expects as the default 'body' param)
        discard gen.genBlock(node, isStmt = true)
        if gen.module.sym"stmt".isNil:
          return gen.module.sym"any"
        return gen.module.sym"stmt"

      debugEcho "Unsupported node kind in genExpr: " & $node.kind
      node.error(ErrValueIsVoid)

proc tryElideWhile*(node: Node): bool {.codegen.} =
  ## Tries to elide a simple monotonic while-loop into O(1) code.
  ## Supported patterns:
  ##   while i <  N: inc(i) / i = i + 1
  ##   while i <= N: inc(i) / i = i + 1
  ##   while i >  N: dec(i) / i = i - 1
  ##   while i >= N: dec(i) / i = i - 1
  ## Also allows extra trivially-dead local var/let/const declarations
  ## in the loop body (e.g. `var x = 0`), as long as they don't affect control flow.
  if node.len < 2: return false
  let
    cond = node[0]
    body = node[1]

  # Condition must be: <ident> <op> <int>
  if cond.kind != nkInfix or cond[0].kind != nkIdent: return false
  let op = cond[0].ident
  if op notin ["<", "<=", ">", ">="]: return false
  if cond[1].kind != nkIdent or cond[2].kind != nkInt: return false

  let loopVarNode = cond[1]
  let loopSym = gen.lookup(loopVarNode, quiet = true)
  if loopSym == nil or loopSym.kind != skVar: return false
  if unwrapType(loopSym.varTy).tyKind != ttyInt: return false

  proc isPureLiteralExpr(n: Node): bool =
    case n.kind
    of nkEmpty, nkBool, nkInt, nkFloat, nkString, nkNil:
      true
    else:
      false

  proc isTriviallyDeadDeclStmt(stmt: Node, loopVarName: string): bool =
    if stmt.kind notin {nkVar, nkLet, nkConst}: return false
    for decl in stmt:
      # prevent shadowing loop var inside body
      for name in decl[0..^3]:
        var n = name
        if n.kind == nkPostfix and n.len == 2:
          n = n[1]
        if n.kind == nkIdent and n.ident == loopVarName:
          return false

      let implNode = decl[^1]
      # only allow literal/no-op initializers
      if not isPureLiteralExpr(implNode):
        return false
    true

  proc stepOf(stmt: Node, loopVarName: string): int =
    ## returns +1, -1, or 0 (no supported step)
    # inc(i) / dec(i)
    if stmt.kind == nkCall and stmt.len == 2 and
       stmt[0].kind == nkIdent and stmt[1].kind == nkIdent and
       stmt[1].ident == loopVarName:
      case stmt[0].ident
      of "inc": return 1
      of "dec": return -1
      else: discard

    # i = i + 1 / i = i - 1
    if stmt.kind == nkInfix and stmt[0].kind == nkIdent and stmt[0].ident == "=" and
       stmt[1].kind == nkIdent and stmt[1].ident == loopVarName:
      let rhs = stmt[2]
      if rhs.kind == nkInfix and rhs[0].kind == nkIdent and
         rhs[1].kind == nkIdent and rhs[1].ident == loopVarName and
         rhs[2].kind == nkInt and rhs[2].intVal == 1:
        case rhs[0].ident
        of "+": return 1
        of "-": return -1
        else: discard

    0

  # Normalize body to statements
  var stmts: seq[Node]
  if body.kind == nkBlock:
    stmts = body.children
  else:
    stmts = @[body]

  # Find exactly one step statement; all others must be trivially dead.
  var
    step = 0
    stepCount = 0
  for s in stmts:
    let sstep = stepOf(s, loopVarNode.ident)
    if sstep != 0:
      inc(stepCount)
      if step == 0:
        step = sstep
      elif step != sstep:
        return false
    else:
      if not isTriviallyDeadDeclStmt(s, loopVarNode.ident):
        return false

  if stepCount != 1 or step == 0: return false

  # Ensure loop converges.
  if not ((step == 1 and op in ["<", "<="]) or (step == -1 and op in [">", ">="])):
    return false

  let bound = cond[2].intVal
  var finalVal = bound

  # Final value after loop exits.
  if step == 1 and op == "<=":
    if bound == high(typeof(bound)): return false
    finalVal = bound + 1
  elif step == -1 and op == ">=":
    if bound == low(typeof(bound)): return false
    finalVal = bound - 1

  # Emit:
  # if cond(loopVar, bound): loopVar = finalVal
  gen.pushVar(loopSym)
  gen.chunk.emit(opcPushI)
  gen.chunk.emit(bound)

  case op
  of "<":
    gen.chunk.emit(opcLessI)
  of "<=":
    gen.chunk.emit(opcGreaterI)
    gen.chunk.emit(opcInvB)
  of ">":
    gen.chunk.emit(opcGreaterI)
  of ">=":
    gen.chunk.emit(opcLessI)
    gen.chunk.emit(opcInvB)
  else:
    return false

  gen.chunk.emit(opcJumpFwdF)
  let skipAssign = gen.chunk.emitHole(2)

  gen.chunk.emit(opcDiscard)
  gen.chunk.emit(1'u8)
  gen.chunk.emit(opcPushI)
  gen.chunk.emit(finalVal)
  gen.popVar(loopVarNode)

  gen.chunk.emit(opcJumpFwd)
  let done = gen.chunk.emitHole(2)

  gen.chunk.patchHole(skipAssign)
  gen.chunk.emit(opcDiscard)
  gen.chunk.emit(1'u8)
  gen.chunk.patchHole(done)

  result = true

proc genWhile*(node: Node) {.codegen.} =
  ## Generates code for a while loop.
  if policyAny in gen.policy.disallow or policyLoops in gen.policy.disallow:
    node.error(ErrPolicyViolation % "loops are disabled")
  
  # Fast-path - loop elision for simple monotonic loops
  if gen.tryElideWhile(node): return

  # we'll need some stuff before generating any code
  var
    isWhileTrue = false  # an optimization for while true loops
    afterLoop: int       # a hole pointer to the end of the loop
  let beforeLoop = gen.chunk.code.len

  # begin a new loop by pushing the outer flow control block
  gen.pushFlowBlock(fbLoopOuter)

  # literal bool conditions are optimized
  case node[0].kind
  of nkBool:
    if node[0].boolVal == true:
      # 'while true' is optimized: the condition is not evaluated at all, so
      # there's only one jump
      isWhileTrue = true
    else:
      # 'while false' is optimized out completely, because it's a no-op.
      # first we must pop the flow block, otherwise stuff would go haywire
      gen.popFlowBlock()
      return
  else: discard

  if not isWhileTrue:
    # if it's not a while true loop, execute the condition
    let condTy = gen.genExpr(node[0])
    if condTy.tyKind != ttyBool:
      node[0].error(ErrTypeMismatch % [$condTy.name, "bool"])

    # if it's false, jump over the loop's body
    gen.chunk.emit(opcJumpFwdF)
    afterLoop = gen.chunk.emitHole(2)

    # otherwise, discard the condition, and execute the body
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)

  # generate the body. we don't care about its type, because while loops are not
  # expressions. this also creates the `iteration` flow block used by
  # ``continue`` statements
  # XXX: creating a flow block here creates a scope without any unique
  # variables, then genBlock creates another scope. optimize this
  gen.pushFlowBlock(fbLoopIter)
  discard gen.genBlock(node[1], isStmt = true)
  gen.popFlowBlock()

  # after the body's done, jump back to reevaluate the condition
  gen.chunk.emit(opcJumpBack)
  gen.chunk.emit(uint16(gen.chunk.code.len - beforeLoop - 1))
  if not isWhileTrue:
    # if it wasn't a while true, we need to fill in
    # the hole after the loop
    gen.chunk.patchHole(afterLoop)
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)

  # finish the loop by popping its outer flow block.
  gen.popFlowBlock()

proc genFor*(node: Node) {.codegen.} =
  ## Generate code for a ``for`` loop.
  if policyAny in gen.policy.disallow or policyLoops in gen.policy.disallow:
    node.error(ErrPolicyViolation % "loops are disabled")

  let
    loopVarName = node[0]
    (iterSym, iterParams) = gen.splitCall(node[1])
    body = node[2]

  # --- For-range inlining: for x in range(lo, hi) with known-constant bounds ---
  if loopVarName.kind == nkIdent and
     iterSym.name.ident == "range" and
     iterParams.len == 2 and
     iterParams[0].kind == nkInt and
     iterParams[1].kind == nkInt:
    let startVal = iterParams[0].intVal
    let endVal = iterParams[1].intVal
    let intTy = gen.module.sym("int")

    # scoped counter so multiple for-range loops don't clash
    gen.pushScope()
    let counterName = ast.newIdent("__counter")
    let counterSym = gen.declareVar(counterName, skVar, intTy)
    counterSym.varSet = true
    gen.chunk.emit(opcPushI)
    gen.chunk.emit(startVal)
    gen.popVar(counterName)

    gen.pushFlowBlock(fbLoopOuter)
    let beforeLoop = gen.chunk.code.len

    # condition: counter > endVal → jump to exit
    gen.pushVar(counterSym)
    gen.chunk.emit(opcPushI)
    gen.chunk.emit(endVal)
    gen.chunk.emit(opcGreaterI)
    gen.chunk.emit(opcJumpFwdT)
    let afterLoop = gen.chunk.emitHole(2)
    # discard the condition bool (opcJumpFwdT peeks, doesn't pop)
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)

    # iteration body: declare loop var $x in its own scope
    gen.pushFlowBlock(fbLoopIter)
    gen.pushScope()
    let loopVar = gen.declareVar(loopVarName, skLet, intTy)
    loopVar.varSet = true
    gen.pushVar(counterSym)
    gen.popVar(loopVarName)
    discard gen.genBlock(body, isStmt = true)
    gen.popScope()
    gen.popFlowBlock()

    # counter += 1
    gen.pushVar(counterSym)
    gen.chunk.emit(opcPushI)
    gen.chunk.emit(1'i64)
    gen.chunk.emit(opcAddI)
    gen.popVar(counterName)

    # jump back
    gen.chunk.emit(opcJumpBack)
    gen.chunk.emit(uint16(gen.chunk.code.len - beforeLoop - 1))

    # patch exit hole
    gen.chunk.patchHole(afterLoop)
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)

    gen.popFlowBlock()
    gen.popScope()
    return

  var isTuple = false
  var tupleVars: seq[Node]

  # detect tuple pattern in loop variable
  case loopVarName.kind
  of nkBracket:
    isTuple = true
    tupleVars = loopVarName.children
  else: discard

  # create a new code generator for the iterator with a separated context
  var iterGen = gen.clone(gkIterator)
  iterGen.iterForBody = body
  iterGen.iterForVar = loopVarName
  iterGen.iterForCtx = gen.context
  iterGen.context = gen.ctxAllocator.allocCtx()

  # generate the arguments passed to the iterator
  # the context is switched only *after* the loop's outer flow block is pushed,
  # so that the loop can be ``break`` properly
  iterGen.pushFlowBlock(fbLoopOuter)
  var argTypes: seq[Sym]
  for arg in iterParams:
    argTypes.add(iterGen.genExpr(arg))
  
  # resolve the iterator's overload
  var theIter = gen.findOverload(iterSym, argTypes, node[1], quiet = true)
  
  if theIter.kind != skIterator:
    node[1].error(ErrSymKindMismatch % [$skIterator, $theIter.kind])
  gen.resolveGenerics(theIter, argTypes, node[1])

  # If the iterator's yield type is an "empty object", try to adopt the
  # element shape from the first argument when it's an array of objects.
  if theIter.iterYieldTy.tyKind == ttyObject and theIter.iterYieldTy.objectFields.len == 0:
    if argTypes.len > 0:
      var src = argTypes[0]
      if src.kind in skVars: src = src.varTy
      let srcTy = unwrapType(src)
      if srcTy.tyKind == ttyArray and srcTy.arrayTy != nil:
        let elem = unwrapType(srcTy.arrayTy)
        if elem.tyKind == ttyObject and elem.objectFields.len > 0:
          theIter.iterYieldTy = elem

  iterGen.iter = theIter

  # declare all the variables passed as the iterator's arguments
  for (name, ty, implSym, isMut, isOpt) in theIter.iterParams:
    var varType = if isMut: skVar else: skLet
    var arg = iterGen.declareVar(name, varType, ty)
    arg.varSet = true

  # iterate
  discard iterGen.genBlock(theIter.impl[3], isStmt = true)

  # clean up the argument scope and free the scope context
  iterGen.popFlowBlock()
  gen.ctxAllocator.freeCtx(iterGen.context)

proc genBreak*(node: Node) {.codegen.} =
  ## Generate code for a ``break`` statement.

  # break from the current loop's outer flow block
  let fblock = gen.findFlowBlock({fbLoopOuter})
  if fblock == nil:
    node.error(ErrOnlyUsableInABlock % "break")
  gen.breakFlowBlock(fblock)

proc genDiscard*(node: Node) {.codegen.} =
  if node.len > 0:
    let ty = gen.genExpr(node[0])
    if ty.sameType(gen.module.sym"void"):
      node[0].error(ErrCannotDiscardVoid % node[0].render)
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)

proc genContinue*(node: Node) {.codegen.} =
  ## Generate code for a ``continue`` statement.

  # break from the current loop's iteration flow block
  let fblock = gen.findFlowBlock({fbLoopIter})
  if fblock == nil:
    node.error(ErrOnlyUsableInALoop % "continue")
  gen.breakFlowBlock(fblock)

proc genReturn*(node: Node) {.codegen.} =
  ## Generate code for a ``return`` statement.

  # return is only valid in procedures, of course
  if gen.kind != gkProc:
    node.error(ErrOnlyUsableInAProc % "return")

  # for non-void returns where we don't have a
  # value specified, we return the magic 'result' variable
  # this is exactly why shadowing 'result' is prohibited
  if node[0].kind == nkEmpty:
    if gen.procReturnTy.tyKind != ttyVoid:
      let resultSym = gen.lookup(newIdent("result"))
      gen.chunk.emit(opcPushL)
      gen.chunk.emit(resultSym.varStackPos.uint16)
  # otherwise if we have a value, use that
  else:
    let valTy = gen.genExpr(node[0])
    if not unwrapType(valTy).sameType(unwrapType(gen.procReturnTy)):
      node[0].error(ErrTypeMismatch % [$valTy.name, $gen.procReturnTy.name])

  # hayago uses two different opcodes for
  # void and non-void return, so we handle that
  if gen.procReturnTy.tyKind != ttyVoid:
    gen.chunk.emit(opcReturnVal)
  else:
    gen.chunk.emit(opcReturnVoid)

proc genYield*(node: Node) {.codegen.} =
  ## Generate code for a ``yield`` statement.

  # yield can only be used inside of an iterator,
  # but never in a for loop's body. using yield in a for loop's
  # body would trigger an infinite recursion, so we prevent that
  if gen.kind != gkIterator or gen.context == gen.iterForCtx:
    node.error(ErrOnlyUsableInAnIterator % "yield")

  # generate the iterator value
  let valTy = gen.genExpr(node[0])
  if not valTy.sameType(gen.iter.iterYieldTy):
    node[0].error(ErrTypeMismatch % [$valTy.name, $gen.iter.iterYieldTy.name])

  # switch context to the for loop
  let myCtx = gen.context
  gen.context = gen.iterForCtx

  # create a new iter flow block with the for loop variable
  gen.pushFlowBlock(fbLoopIter)

  # declare the for loop's variable
  var loopVar: Sym
  var loopVarKey: Sym
  if gen.iterForVar.kind == nkIdent:
    loopVar = gen.declareVar(gen.iterForVar, skLet, gen.iter.iterYieldTy)
  else:
    loopVar = gen.declareVar(gen.iterForVar[0], skLet, gen.iter.iterYieldTy)
    loopVarKey = gen.declareVar(gen.iterForVar[1], skLet, gen.module.sym"string")
  loopVar.varSet = true
  if gen.iterForVar.kind == nkIdent:
    gen.popVar(gen.iterForVar)
  
  # run the for loop's body
  discard gen.genBlock(gen.iterForBody, isStmt = true)

  # go back to the iterator's context
  gen.popFlowBlock()
  gen.context = myCtx

proc genArray*(node: Node, isInstantiation = false): Sym {.codegen.} =
  ## Generate code for an array literal, instantiating array[T] for the element type.
  let elemTy =
    if node.children.len > 0:
      gen.genExpr(node[0])
    else:
      gen.module.sym"any"

  if node.children.len > 0:
    gen.chunk.emit(opcDiscard)
    gen.chunk.emit(1'u8)

  # Instantiate array[T] with the element type
  let arrayTypeSym = gen.typeLookup("array")
  let instArrayType = gen.instantiate(arrayTypeSym, @[elemTy], node)
  
  # Store all items and check their type
  let firstItemTy = unwrapType(elemTy)
  for n in node.children:
    let itemTy = gen.genExpr(n)
    let itemTyUnwrap = unwrapType(itemTy)
    if not itemTyUnwrap.sameType(firstItemTy):
      # checking if the other type is the same as the first element's type
      n.error(ErrTypeMismatch % [$itemTyUnwrap.name, $firstItemTy.name])
    instArrayType.arrayItems.add(itemTy)
  
  instArrayType.arrayTy = elemTy
  instArrayType.genericInstArgs = some(@[elemTy])
  # Emit code to construct the array
  gen.chunk.emit(opcConstrArray)
  gen.chunk.emit(uint16(node.children.len))
  result = instArrayType

proc genObjectStorage*(node: Node, isInstantiation = false): Sym {.codegen.} =
  # Generate code for an object storage. This creates an anonymous object type
  # with the given fields, and emits code to construct it.
  result = newType(ttyObject, name = nil, impl = node)
  var keyIds: seq[uint16]
  for n in node.children:
    let key =
      if n[0].kind == nkIdent: n[0].ident
      elif n[0].kind == nkString: n[0].stringVal
      else: n[0].error("Invalid object field key: " & $n[0].kind); ""

    keyIds.add(gen.chunk.getString(key))
    
    # push the field's value
    let valTy = gen.genExpr(n[1])

    result.objectFields[key] = (
      id: result.objectFields.len,
      name: n[0],
      ty: valTy,
      implVal: valTy
    )

  gen.chunk.emit(opcConstrObj)
  gen.chunk.emit(uint16(result.objectFields.len))
  for kid in keyIds:
    gen.chunk.emit(kid)

proc genObject*(node: Node, isInstantiation = false): Sym {.codegen.} =
  # Process an object declaration, and add the new type into the current
  # module or scope.
  #
  # Supported shapes:
  #   object Name[T] { ... }   -> [name, genericParams, recFields]
  #   type Name = object ...   -> [name, recFields]

  var
    nameNode = node[0]
    genericNode = ast.newEmpty()
    recFieldsNode: Node

  if node.len >= 3:
    # legacy/full object declaration shape
    genericNode = node[1]
    recFieldsNode = node[^1]
  elif node.len == 2 and node[1].kind == nkRecFields:
    # type Alias = object ...
    recFieldsNode = node[1]
  else:
    node.error("Invalid object declaration shape: " & node.render)

  # create a new type for the object
  result = newType(ttyObject, name = nameNode, impl = node)
  result.impl = node

  # check if the object is generic
  if not isInstantiation and genericNode.kind == nkGenericParams:
    gen.pushScope()
    result.genericParams = gen.collectGenericParams(genericNode)

  # process object fields
  result.objectId = globalTypeCounter
  inc(globalTypeCounter)
  result.src = some(gen.chunk.file)

  for fields in recFieldsNode:
    let fieldsTy = gen.lookup(fields[^2])
    var fieldImplSym: Sym = nil
    if fields[^1].kind != nkEmpty:
      fieldImplSym = newSym(
        skConst,
        newIdent("__field_default_" & $gen.count()),
        impl = fields[^1]
      )

    # create all fields declared in this ident-defs group
    for name in fields[0..^3]:
      result.objectFields[name.ident] = (
        id: result.objectFields.len,
        name: name,
        ty: fieldsTy,
        implVal: fieldImplSym
      )

  # if object had generic params, pop their scope
  if not isInstantiation and result.isGeneric:
    gen.popScope()
  gen.addSym(result)

proc genIterator*(node: Node, isInstantiation = false): Sym {.codegen.} =
  ## Process an iterator declaration,
  ## and add it into the current module or scope.
  var iterExport: bool
  let identNode: Node = 
    case node[0].kind
    of nkPostfix:
      assert node[0][0].ident == "*"
      iterExport = true
      node[0][1]
    else:
      node[0]
      
  # create a new symbol for the iterator
  result = newSym(skIterator, name = identNode, impl = node)

  # collect the generic params from the iterator into a new, temporary scope
  if not isInstantiation and node[1].kind != nkEmpty:
    gen.pushScope()
    result.genericParams = gen.collectGenericParams(node[1])

  # get some metadata about its params
  let
    formalParams = node[2]
    params = gen.collectParams(formalParams, result.genericParams)

  # get the yield type
  if formalParams[0].kind == nkEmpty:
    node.error(ErrIterMustHaveYieldType)

  let yieldTy = gen.lookup(formalParams[0])
  if yieldTy.kind == skType and yieldTy.tyKind == ttyVoid:
    node.error(ErrIterMustHaveYieldType)

  # fill in the iterator
  result.iterParams = params
  result.iterYieldTy = yieldTy
  result.iterExport = iterExport

  # remove the generic param scope
  if not isInstantiation and result.isGeneric:
    gen.popScope()

  # add the resulting iterator to the current scope
  gen.addSym(result)

proc genVar*(node: Node) {.codegen.} =
  # handle variable declarations
  if policyAny in gen.policy.disallow or policyAssignments in gen.policy.disallow:
    node.error(ErrPolicyViolation % "assignments are disabled")
  for decl in node.children[0]:
    let implNode = decl[^1]
    if implNode.kind == nkEmpty and node.kind != nkVar:
      decl[^1].error(ErrVarMustHaveValue)
    var valTy: Sym            # the type of the value
    var valTyImpl: Sym        # the specified type of the variable (if any)
    for name in decl[0..^3]:
      # generate the value
      if implNode.kind != nkEmpty:
        # generate the value and check its type
        valTy = gen.genExpr(implNode)
        if decl[^2].kind != nkEmpty:
          # if both the type and the value are specified
          valTyImpl = gen.lookup(decl[^2])
        else:
          valTyImpl = valTy
      elif decl[^2].kind != nkEmpty:
        # otherwise, use the provided type
        # to generate the default value
        valTyImpl = gen.lookup(decl[^2])
        gen.pushDefault(valTyImpl)
      else:
        # if neither the value nor the type is specified,
        # we emit error that the variable must have a value
        decl[^1].error(ErrTypeMismatch % ["none", "none"])
      
      # determine the variable's type based on the declaration kind
      # if the variable is declared as `var`, it is mutable
      # otherwise, it is immutable (cannot be reassigned and requires
      # an implicit value to be set)
      let varTy =
        case node.kind
        of nkVar: skVar
        of nkLet: skLet
        else: skConst
      
      # declare the variable
      var varExport: bool # whether the variable is exported
      let name = 
        if name.kind == nkPostfix and name[0].ident == "*":
          # when the variable is suffixed with a '*', it is a
          # public variable declared in the global scope
          varExport = true
          name[1]
        else:
          name # otherwise, it's a private variable
      if valTy != nil and valTyImpl != nil:
        # before declaring the variable, we need to check if
        # the variable's type matches the expected type
        if not unwrapType(valTy).sameType(unwrapType(valTyImpl)):
          decl[^1].error(ErrTypeMismatch % [$unwrapType(valTy).name, $unwrapType(valTyImpl).name])
      else:
        valTy = valTyImpl

      # declare the variable in the current scope
      gen.declareVar(name, varTy, valTy, varExport = varExport)
      gen.popVar(name) # and pop the value into it

proc genImport*(node: Node) {.codegen.} =
  ## Generate code for an import or include statement
  if policyAny in gen.policy.disallow or policyImports in gen.policy.disallow:
    node.error(ErrPolicyViolation % "imports are disabled")
  for pathNode in node.children:
    var path: string
    var astProgram: Ast
    # handle package imports
    # e.g. `import "pkg/mypackage/mymodule"`
    if pathNode.stringVal.startsWith("pkg/") and gen.pkgr != nil:
      if policyAny in gen.policy.disallow or policyPackages in gen.policy.disallow:
        pathNode.error(ErrPolicyViolation % "packages are disabled")
      let pkgPath = pathNode.stringVal.split("/")
      if gen.pkgr.hasPackage(pkgPath[1]):
        let filePath = if pkgPath.len > 2:
          pkgPath[2..^1].join("/") # specific file in module, exclude main module
        else:
          pkgPath[1..^1].join("/") # default to main module
        path = gen.pkgr.getModulePath(pkgPath[1], filePath)
      else:
        pathNode.error(ErrImportError % pkgPath[1])
    elif pathNode.stringVal.startsWith("std/"):
      if policyAny in gen.policy.disallow or policyStdlib in gen.policy.disallow:
        pathNode.error(ErrPolicyViolation % "stdlib access is disabled")
      # handle standard library imports
      let stdLibName = pathNode.stringVal.split("/")[1]
      
      # load the standard library module
      if gen.stdlibs.hasKey(stdLibName):
        gen.module.load(gen.stdlibs[stdLibName](gen.script, gen.module.modules["system.timl"]))
      else:
        pathNode.error(ErrImportError % stdLibName)
      # skip the rest of the import handling
      # as the stdlib is already preloaded
      # at compile time
      continue
    else:
      # handle file imports and includes
      if node.kind == nkImport:
        path = absolutePath(
            if pathNode.stringVal.endsWith".timl": pathNode.stringVal
            else: pathNode.stringVal & ".timl"
          )
      else:
        path =
          if pathNode.stringVal.endsWith".timl": pathNode.stringVal
          else: pathNode.stringVal & ".timl"
    case node.kind
    of nkImport:
      # resolve the module's path
      let aFile = absolutePath(gen.module.src.get())
      try:
        gen.resolver.resolveFile(aFile, path)
      except ResolverError as e:
        pathNode.error(ErrImportError % [e.msg])

      if gen.kind != gkToplevel:
        node.error(ErrImportOnlyTopLevel)
        return
      if codegenCache.cachedAst.hasKey(path):
        # first, check if we have a cached AST for the module
        astProgram = codegenCache.cachedAst[path]
      else:
        # parse the module's source code into an AST
        # pass the active resolver so the callback can read from VFS
        gen.parserCallback(astProgram, path, gen.resolver)

      var
        importChunk = newChunk(astProgram.sourcePath)
        importScript = newScript(importChunk)
        importModule = newModule(path.extractFilename, some(path))

      # load the system module
      importModule.load(gen.module.modules["system.timl"])

      let stdpos = gen.script.stdpos
      importScript.procs = gen.script.procs[0..stdpos]
      importScript.stdpos = stdpos

      # initialize the code generator
      var moduleGen: CodeGen = initCodeGen(importScript, importModule, importChunk)
      moduleGen.resolver = gen.resolver
      
      # generate the module's script based
      # on the parsed module AST program
      moduleGen.genScript(astProgram, gen.includeBasePath)
      
      # once the module is generated, we can load it
      # into the current module
      if not gen.module.load(moduleGen.module, fromOtherModule = true):
        node.warn(WarnModuleAlreadyImported % pathNode.stringVal)

      # add the module to the current script's modules
      gen.script.scripts[importChunk.file] = moduleGen.script

      # emit the import opcode
      gen.chunk.emit(opcImportModule)
      gen.chunk.emit(gen.chunk.getString(importChunk.file))

    of nkInclude:
      if gen.includeBasePath.isSome:
        # if the include path is set, we can use it to resolve the module
        path = absolutePath(gen.includeBasePath.get() / path)

      # resolve the module's path
      let aFile = absolutePath(gen.module.src.get())
      
      try:
        gen.resolver.resolveFile(aFile, path)
      except ResolverError as e:
        pathNode.error(ErrImportError % [e.msg])
      if codegenCache.cachedAst.hasKey(path):
        astProgram = codegenCache.cachedAst[path]
      else:
        # parse the module's source code into an AST
        gen.parserCallback(astProgram, path, gen.resolver)
      for n in astProgram.nodes:
        gen.genStmt(n)
    else: discard

    # cache the parsed AST for future imports
    codegenCache.cachedAst[path] = astProgram

proc genComment*(node: Node) {.codegen.} =
  ## Generate an HTML comment.
  # this is a no-op, because comments are not compiled
  # into the final code, but they are useful for documentation
  gen.chunk.emit(opcNoop)

proc genStmt*(node: Node) {.codegen.} =
  ## Generate code for a statement. The case of this procedure is fully extendable,
  ## so that new statement types can be added by other modules without modifying this file
  extendableCase "codeGenStmt":
    case node.kind:
    of nkVar, nkLet, nkConst: gen.genVar(node)    # variable declaration
    of nkBlock: discard gen.genBlock(node, true)  # block statement
    of nkIf: discard gen.genIf(node, true)        # if statement
    of nkWhile: gen.genWhile(node)                # while loop
    of nkFor: gen.genFor(node)                    # for loop
    of nkBreak: gen.genBreak(node)                # break statement
    of nkDiscard: gen.genDiscard(node)             # discard statement
    of nkContinue: gen.genContinue(node)          # continue statement
    of nkReturn: gen.genReturn(node)              # return statement
    of nkYield: gen.genYield(node)                # yield statement
    of nkProc: discard gen.genProc(node)          # procedure declaration
    of nkIterator: discard gen.genIterator(node)  # iterator declaration
    of nkObjectStorage: discard gen.genObjectStorage(node)      # object declaration
    of nkObject: discard gen.genObject(node)
    of nkTypeDef: discard gen.genTypeDef(node)    # type definition
    of nkImport, nkInclude: gen.genImport(node) # import statement
    of nkDocComment: gen.genComment(node) # generate HTML comment
    else:                                         # expression statement
      let ty = gen.genExpr(node)
      # if ty != gen.module.sym"void":
      if not ty.sameType(gen.module.sym"void"):
        if not gen.allowExprResult:
          node.error(ErrUseOrDiscard % [node.render, $ty.name])

proc genBlock*(node: Node, isStmt: bool): Sym {.codegen.} =
  ## Generate a block of code. Every block creates a new scope
  gen.pushScope()
  for i, s in node:
    if isStmt:
      # if it's a statement block,
      # generate its children normally
      gen.genStmt(s)
    else:
      # otherwise, treat the last statement as
      # an expression (and the value of the block)
      if i < node.len - 1:
        gen.genStmt(s)
      else:
        result = gen.genExpr(s)
  # pop the block's scope
  gen.popScope()
  
  if isStmt:
    # if it was a statement, the block's type is void
    result = gen.module.sym"void"
  
  # if node.children.len > 0 == false:
    # warn if the block is empty. not sure if this works
    # all the time, but it should warn when node has no 
    # node.warn(WarnEmptyStmt)

proc genScript*(program: Ast, includePath: Option[string],
                  emitHalt: static bool = true) {.codegen.} =
  ## Generates the code for a full script.
  gen.includeBasePath = includePath
  gen.fwdDecl = program.forwardDecl
  for node in program.nodes:
    gen.genStmt(node)
  when emitHalt == true:
    gen.chunk.emit(opcHalt)

proc hashIdentity(id: string): Hash {.inline.} =
  let id = id[0] & id[1..^1].toLowerAscii
  hashIgnoreStyle(id, 1, id.high)

proc addIterator*(script: Script, module: Module, name: string) =
  ## Add a foreign iterator into the specified module.
  discard # todo
  ## Add a foreign iterator into the specified module.
  discard # todo

proc initCompiler*(script: Script, module: Module,
          chunk: Chunk, pkgr: Packager = nil,
          stdlibs: StandardLibrary,
          parserCallback: ParserCallback = nil,
          triggerFromPath: Option[string] = none(string),
          policy: CompilationPolicy = CompilationPolicy()
  ): CodeGen =
  ## Initialize a new code generator with a new script and module
  ## 
  ## This is the main entry point for code generation, and can be called by
  ## your main module or by other modules to initialize code generation for a new script
  result = initCodeGen(script, module, chunk, pkgr = pkgr, policy = policy)
  result.triggerFromPath = triggerFromPath
  result.stdlibs = stdlibs
  result.parserCallback = parserCallback
