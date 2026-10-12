
import pkg/gccjit
import pkg/voodoo/language/ast
import std/[strutils, tables, sequtils, options]

## This module implements a simple JIT & AOT code generator
## using the gccjit library. It compiles a subset of the Voodoo AST
## into machine code at runtime (JIT) or to object files/shared libraries (AOT).
## 
## The main purpose of this module is to build a high-performance
## code generation backend for Voodoo-based languages.
type
  JitContext* = object
    ctxt*: ptr gcc_jit_context
      ## The libgccjit context for managing types,
      ## functions, and code generation
    types*: Table[string, ptr gcc_jit_type]
      ## A mapping of type names to libgccjit type
      ## pointers for easy lookup during code generation
    functions*: Table[string, ptr gcc_jit_function]
      ## A mapping of function names to libgccjit function
      ## pointers for function definitions and calls
    blocks*: seq[ptr gcc_jit_block]
      ## A sequence of current blocks being generated,
      ## useful for managing control flow and nested blocks
  
  VoodooAotGenError* = object of CatchableError

#
# forward declarations
#
proc genStmt*(ctx: var JitContext, node: Node, jitBlock: ptr gcc_jit_block): ptr gcc_jit_block

proc initJitContext*(): JitContext =
  ## Initialize a new JIT context with basic types preloaded
  result.ctxt = gcc_jit_context_acquire()
  # Preload basic types
  result.types["int"]   = gcc_jit_context_get_type(result.ctxt, GCC_JIT_TYPE_INT)
  result.types["float"] = gcc_jit_context_get_type(result.ctxt, GCC_JIT_TYPE_DOUBLE)
  result.types["bool"]  = gcc_jit_context_get_type(result.ctxt, GCC_JIT_TYPE_BOOL)
  result.types["string"] = gcc_jit_context_get_type(result.ctxt, GCC_JIT_TYPE_CHAR)
  result.types["void"]   = gcc_jit_context_get_type(result.ctxt, GCC_JIT_TYPE_VOID)

proc freeJitContext*(ctx: var JitContext) =
  ## Release the JIT context
  if ctx.ctxt != nil:
    gcc_jit_context_release(ctx.ctxt)
    ctx.ctxt = nil

proc isAssignmentNode(n: Node): bool =
  n.kind == nkInfix and n.len >= 1 and n[0].kind == nkIdent and n[0].ident == "="

proc isStmtOnlyNode(n: Node): bool =
  n.kind in {nkFor, nkWhile, nkIf, nkReturn, nkBreak, nkContinue} or isAssignmentNode(n)

proc genExpr*(ctx: var JitContext, node: Node): ptr gcc_jit_rvalue =
  ## Compile an AST expression node to a libgccjit rvalue
  case node.kind
  of nkInt:
    return gcc_jit_context_new_rvalue_from_int(ctx.ctxt, ctx.types["int"], node.intVal.cint)
  of nkFloat:
    return gcc_jit_context_new_rvalue_from_double(ctx.ctxt, ctx.types["float"], node.floatVal.cdouble)
  of nkBool:
    return gcc_jit_context_new_rvalue_from_int(ctx.ctxt, ctx.types["bool"], node.boolVal.cint)
  of nkString:
    return gcc_jit_context_new_string_literal(ctx.ctxt, node.stringVal)
  of nkIdent:
    # Variable lookup (param or local)
    if ctx.functions.hasKey(node.ident):
      let lval = cast[ptr gcc_jit_lvalue](ctx.functions[node.ident])
      return gcc_jit_lvalue_as_rvalue(lval)
    else:
      # TODO: support global lookup
      return nil
  of nkPrefix:
    let op = node[0]
    let rhs = genExpr(ctx, node[1])
    case op.kind
    of nkIdent:
      case op.ident
      of "-":
        return gcc_jit_context_new_unary_op(ctx.ctxt,
            nil, GCC_JIT_UNARY_OP_MINUS, ctx.types["int"], rhs)
      of "not":
        return gcc_jit_context_new_unary_op(ctx.ctxt,
            nil, GCC_JIT_UNARY_OP_LOGICAL_NEGATE, ctx.types["bool"], rhs)
      of "!":
        return gcc_jit_context_new_unary_op(ctx.ctxt,
            nil, GCC_JIT_UNARY_OP_BITWISE_NEGATE, ctx.types["int"], rhs)
      else:
        # TODO: support more prefix ops
        return nil
    else:
      return nil
  of nkInfix:
    let op = node[0]
    let lhs = genExpr(ctx, node[1])
    let rhs = genExpr(ctx, node[2])
    case op.kind
    of nkIdent:
      case op.ident
      of "+":
        return gcc_jit_context_new_binary_op(ctx.ctxt, nil, GCC_JIT_BINARY_OP_PLUS, ctx.types["int"], lhs, rhs)
      of "-":
        return gcc_jit_context_new_binary_op(ctx.ctxt, nil, GCC_JIT_BINARY_OP_MINUS, ctx.types["int"], lhs, rhs)
      of "*":
        return gcc_jit_context_new_binary_op(ctx.ctxt, nil, GCC_JIT_BINARY_OP_MULT, ctx.types["int"], lhs, rhs)
      of "/":
        return gcc_jit_context_new_binary_op(ctx.ctxt, nil, GCC_JIT_BINARY_OP_DIVIDE, ctx.types["int"], lhs, rhs)
      of "==":
        return gcc_jit_context_new_comparison(ctx.ctxt, nil, GCC_JIT_COMPARISON_EQ, lhs, rhs)
      of "!=":
        return gcc_jit_context_new_comparison(ctx.ctxt, nil, GCC_JIT_COMPARISON_NE, lhs, rhs)
      of "<":
        return gcc_jit_context_new_comparison(ctx.ctxt, nil, GCC_JIT_COMPARISON_LT, lhs, rhs)
      of "<=":
        return gcc_jit_context_new_comparison(ctx.ctxt, nil, GCC_JIT_COMPARISON_LE, lhs, rhs)
      of ">":
        return gcc_jit_context_new_comparison(ctx.ctxt, nil, GCC_JIT_COMPARISON_GT, lhs, rhs)
      of ">=":
        return gcc_jit_context_new_comparison(ctx.ctxt, nil, GCC_JIT_COMPARISON_GE, lhs, rhs)
      else:
        # TODO: support more infix ops
        return nil
    else:
      return nil
  of nkCall:
    # For now, only support direct function calls with arguments
    let fnNode = node[0]
    if fnNode.kind == nkIdent and ctx.functions.hasKey(fnNode.ident):
      let fn = ctx.functions[fnNode.ident]
      var args: seq[ptr gcc_jit_rvalue]
      for i in 1 ..< node.len:
        args.add(genExpr(ctx, node[i]))
      return gcc_jit_context_new_call(ctx.ctxt, nil, fn, args.len.cint, if args.len > 0: addr args[0] else: nil)
    else:
      # TODO: support more call types
      return nil
  else:
    # For now, just return nil for unsupported nodes
    return nil

proc genAssignment(ctx: var JitContext, node: Node, jitBlock: ptr gcc_jit_block): ptr gcc_jit_block =
  let lhs = node[1]
  let rhs = node[2]
  if lhs.kind == nkIdent:
    let varName = lhs.ident
    var lval: ptr gcc_jit_lvalue
    if ctx.functions.hasKey(varName):
      lval = cast[ptr gcc_jit_lvalue](ctx.functions[varName])
    else:
      lval = gcc_jit_function_new_local(jitBlock.gcc_jit_block_get_function, nil, ctx.types["int"], varName)
      ctx.functions[varName] = cast[ptr gcc_jit_function](lval)
    let rval = genExpr(ctx, rhs)
    gcc_jit_block_add_assignment(jitBlock, nil, lval, rval)
  result = jitBlock

proc genForLoop(ctx: var JitContext, node: Node, jitBlock: ptr gcc_jit_block): ptr gcc_jit_block =
  let varName = node[0].ident
  let startExpr = genExpr(ctx, node[1])
  let endExpr = genExpr(ctx, node[3])
  let bodyNode = node[4]

  let fn = jitBlock.gcc_jit_block_get_function
  let loopVar = gcc_jit_function_new_local(fn, nil, ctx.types["int"], varName)
  ctx.functions[varName] = cast[ptr gcc_jit_function](loopVar)
  gcc_jit_block_add_assignment(jitBlock, nil, loopVar, startExpr)

  let loopCond = gcc_jit_function_new_block(fn, "loop.cond")
  let loopBody = gcc_jit_function_new_block(fn, "loop.body")
  let loopEnd  = gcc_jit_function_new_block(fn, "loop.end")

  gcc_jit_block_end_with_jump(jitBlock, nil, loopCond)

  let condRval = gcc_jit_context_new_comparison(
    ctx.ctxt, nil, GCC_JIT_COMPARISON_LE, gcc_jit_lvalue_as_rvalue(loopVar), endExpr)
  gcc_jit_block_end_with_conditional(loopCond, nil, condRval, loopBody, loopEnd)

  var bodyBlk = loopBody
  if bodyNode.kind == nkBlock:
    for stmt in bodyNode.children:
      bodyBlk = genStmt(ctx, stmt, bodyBlk)
  else:
    bodyBlk = genStmt(ctx, bodyNode, bodyBlk)

  let one = gcc_jit_context_new_rvalue_from_int(ctx.ctxt, ctx.types["int"], 1)
  let inc = gcc_jit_context_new_binary_op(
    ctx.ctxt, nil, GCC_JIT_BINARY_OP_PLUS, ctx.types["int"],
    gcc_jit_lvalue_as_rvalue(loopVar), one)
  gcc_jit_block_add_assignment(bodyBlk, nil, loopVar, inc)
  gcc_jit_block_end_with_jump(bodyBlk, nil, loopCond)

  result = loopEnd

proc genIf(ctx: var JitContext, node: Node, jitBlock: ptr gcc_jit_block): ptr gcc_jit_block =
  # Expected layout: [cond0, body0, cond1, body1, ..., elseBody?]
  let fn = jitBlock.gcc_jit_block_get_function
  var currBlock = jitBlock
  let endBlock = gcc_jit_function_new_block(fn, "if.end")

  let n = node.len
  let hasElse = (n mod 2) == 1
  let branchLimit = (if hasElse: n - 1 else: n)

  var i = 0
  while i + 1 < branchLimit:
    let cond = node[i]
    let thenBody = node[i + 1]

    let thenBlock = gcc_jit_function_new_block(fn, "if.then")
    let nextBlock = gcc_jit_function_new_block(fn, "if.next")

    let condExpr = genExpr(ctx, cond)
    gcc_jit_block_end_with_conditional(currBlock, nil, condExpr, thenBlock, nextBlock)

    let afterThen = genStmt(ctx, thenBody, thenBlock)
    gcc_jit_block_end_with_jump(afterThen, nil, endBlock)

    currBlock = nextBlock
    i += 2

  if hasElse:
    let elseBody = node[n - 1]
    let afterElse = genStmt(ctx, elseBody, currBlock)
    gcc_jit_block_end_with_jump(afterElse, nil, endBlock)
  else:
    gcc_jit_block_end_with_jump(currBlock, nil, endBlock)

  result = endBlock

proc genStmt*(ctx: var JitContext, node: Node, jitBlock: ptr gcc_jit_block): ptr gcc_jit_block =
  ## Compile a statement node into a block
  case node.kind
  of nkInfix:
    if node[0].kind == nkIdent and node[0].ident == "=":
      return ctx.genAssignment(node, jitBlock)
    else:
      let rval = genExpr(ctx, node)
      if rval != nil:
        gcc_jit_block_add_eval(jitBlock, nil, rval)
  of nkFor:
    return ctx.genForLoop(node, jitBlock)
  of nkIf:
    return ctx.genIf(node, jitBlock)
  else:
    # Expression statement
    let rval = genExpr(ctx, node)
    if rval != nil:
      gcc_jit_block_add_eval(jitBlock, nil, rval)
  result = jitBlock

proc genFunction*(ctx: var JitContext, node: Node) =
  ## Compile a function definition node into a libgccjit function
  if node.kind == nkProc:
    let name =
      if node[0].kind == nkIdent: node[0].ident
      else: "anonymous"
    let retType = ctx.types["int"] # TODO: infer from AST

    var params: seq[ptr gcc_jit_param]
    var pNameStrs: seq[string]
    if node.len > 2 and node[2].kind == nkFormalParams:
      for i in 1 ..< node[2].len:
        let paramDef = node[2][i]
        if paramDef.kind == nkIdentDefs and paramDef.len >= 2:
          let pName: Node = paramDef[0]
          let pType: Node = paramDef[1]
          let pNameStr =
            if pName.kind == nkIdent: pName.ident
            else: "param" & $i
          let paramType =
            if pType.kind == nkIdent and ctx.types.hasKey(pType.ident):
              ctx.types[pType.ident]
            else:
              ctx.types["int"]
          let param = gcc_jit_context_new_param(ctx.ctxt, nil, paramType, pNameStr)
          params.add(param)
          pNameStrs.add(pNameStr)

    let fn = gcc_jit_context_new_function(
      ctx.ctxt, nil, GCC_JIT_FUNCTION_EXPORTED, retType, name, params.len.cint,
      if params.len > 0: addr params[0] else: nil, 0)

    ctx.functions[name] = fn

    for i, pNameStr in pNameStrs:
      let paramLval = gcc_jit_param_as_lvalue(params[i])
      ctx.functions[pNameStr] = cast[ptr gcc_jit_function](paramLval)

    let entry = gcc_jit_function_new_block(fn, "entry")
    var currBlock = entry
    var lastRval: ptr gcc_jit_rvalue = nil

    if node[3].kind == nkBlock and node[3].len > 0:
      let lastIdx = node[3].len - 1
      for i, stmt in node[3].children:
        if i < lastIdx:
          currBlock = genStmt(ctx, stmt, currBlock)
        else:
          if isStmtOnlyNode(stmt):
            currBlock = genStmt(ctx, stmt, currBlock)
          else:
            lastRval = genExpr(ctx, stmt)
            if lastRval == nil:
              currBlock = genStmt(ctx, stmt, currBlock)
    else:
      currBlock = genStmt(ctx, node[3], currBlock)

    if lastRval != nil:
      gcc_jit_block_end_with_return(currBlock, nil, lastRval)
    else:
      gcc_jit_block_end_with_return(
        currBlock, nil, gcc_jit_context_new_rvalue_from_int(ctx.ctxt, retType, 0))

proc prepareJIT*(ctx: var JitContext, program: Ast) =
  ## Prepare the JIT context by compiling all functions and
  ## top-level statements into libgccjit structures. This does
  ## not yet execute the code
  var mainBlock: ptr gcc_jit_block
  for node in program.nodes:
    case node.kind
    of nkProc:
      genFunction(ctx, node)
    else:
      if not ctx.functions.hasKey("main"):
        let fn = gcc_jit_context_new_function(
          ctx.ctxt, nil, GCC_JIT_FUNCTION_EXPORTED, ctx.types["int"], "main", 0, nil, 0)
        ctx.functions["main"] = fn
        mainBlock = gcc_jit_function_new_block(fn, "entry")
      mainBlock = genStmt(ctx, node, mainBlock)

  if mainBlock != nil:
    gcc_jit_block_end_with_return(
      mainBlock, nil, gcc_jit_context_new_rvalue_from_int(ctx.ctxt, ctx.types["int"], 0))

type
  VoodooAotType* = enum
    aotShared # Compile to a shared library (.so) instead of an executable
    aotObject # Compile to an object file (.o) instead of an executable

proc compileAot*(ctx: var JitContext, program: Ast, outputPath: string, flags: static VoodooAotType = aotShared) =
  ## Compile the script AST to an object file or executable
  ## using Ahead-Of-Time (AOT) compilation
  var mainBlock: ptr gcc_jit_block = nil
  for node in program.nodes:
    case node.kind
    of nkProc:
      genFunction(ctx, node)
    else:
      # Top-level statements go in 'main'
      if mainBlock == nil:
        if ctx.functions.hasKey("main"):
          # main already exists (e.g. generated earlier)
          let fn = ctx.functions["main"]
          mainBlock = gcc_jit_function_new_block(fn, "entry.aot")
        else:
          let fn = gcc_jit_context_new_function(
            ctx.ctxt, nil, GCC_JIT_FUNCTION_EXPORTED, ctx.types["int"], "main", 0, nil, 0)
          ctx.functions["main"] = fn
          mainBlock = gcc_jit_function_new_block(fn, "entry")
      mainBlock = genStmt(ctx, node, mainBlock)

  # Ensure main returns 0 only if we emitted top-level statements here
  if mainBlock != nil:
    gcc_jit_block_end_with_return(
      mainBlock, nil,
      gcc_jit_context_new_rvalue_from_int(ctx.ctxt, ctx.types["int"], 0))
  
  let outputPath = 
    when defined(windows):
      if flags == aotShared: outputPath.changeFileExt(".dll")
      else: outputPath.changeFileExt(".obj")
    else:
      if flags == aotShared: outputPath.changeFileExt(".so")
      else: outputPath.changeFileExt(".o")
  gcc_jit_context_compile_to_file(
    ctx.ctxt,
    (
      when flags == aotShared:
        # For shared libraries, we need to specify the output
        # kind to ensure proper linking and symbol visibility
        GCC_JIT_OUTPUT_KIND_DYNAMIC_LIBRARY
      else:
        # For object files, we specify the output kind
        # to generate a .o file
        GCC_JIT_OUTPUT_KIND_OBJECT_FILE
    ),
    outputPath
  )

  let err = gcc_jit_context_get_first_error(ctx.ctxt)
  if err != nil:
    raise newException(VoodooAotGenError, "AOT compilation failed: " & $err)

when isMainModule:
  import std/[os, strformat]
  # Sample AST: proc add(a: int, b: int): int = a + b; add(2, 3)
  let addProc = newNode(nkProc)
  addProc.add(newIdent("add")) # name
  addProc.add(newEmpty())      # generic params
  let formalParams = newNode(nkFormalParams)
  formalParams.add(newNode(nkEmpty)) # return type (empty for now)
  let paramA = newNode(nkIdentDefs)
  paramA.add(newIdent("a"))
  paramA.add(newIdent("int"))
  paramA.add(newEmpty())
  let paramB = newNode(nkIdentDefs)
  paramB.add(newIdent("b"))
  paramB.add(newIdent("int"))
  paramB.add(newEmpty())
  formalParams.add(paramA)
  formalParams.add(paramB)
  addProc.add(formalParams)
  let body = newNode(nkBlock)
  let sumExpr = newTree(nkInfix, newIdent("+"), newIdent("a"), newIdent("b"))
  body.add(sumExpr)
  
  # example a loop: for i in 0..100_000: echo(i); hello()
  var loopBody = newNode(nkBlock)
  let iIdent = newIdent("i")

  let printfICall = newTree(nkCall, newIdent("printf"), newStringLit("%d\n"), iIdent)
  loopBody.add(printfICall)
  let helloCallInLoop = newTree(nkCall, newIdent("hello"))
  loopBody.add(helloCallInLoop)

  var forLoop = newNode(nkFor)
  forLoop.add(newIdent("i"))
  forLoop.add(newIntLit(0))
  forLoop.add(newIdent(".."))
  forLoop.add(newIntLit(5))
  forLoop.add(loopBody)
  body.add(forLoop)
  
  addProc.add(body)

  let mainCall = newTree(nkCall, newIdent("add"), newIntLit(2), newIntLit(3))

  # Example: proc hello(): int = echo("Hello, World"); 0; hello()
  let helloProc = newNode(nkProc)
  helloProc.add(newIdent("hello")) # name
  helloProc.add(newEmpty())        # generic params
  let helloFormalParams = newNode(nkFormalParams)
  helloFormalParams.add(newNode(nkEmpty)) # return type (empty for now)
  helloProc.add(helloFormalParams)
  let helloBody = newNode(nkBlock)
  
  # Simulate echo by calling puts (C stdio) via libgccjit builtin
  let putsCall = newTree(nkCall, newIdent("puts"), newStringLit("Hello, World"))
  helloBody.add(putsCall)
  helloBody.add(newIntLit(0)) # return 0

  var ifNodes = @[ast.newInfix(newIdent("=="), newIntLit(10), newIntLit(10))]
  ifNodes.add(newTree(nkCall, newIdent("puts"), newStringLit("Hello!")))
  let ifNode = newTree(nkIf, ifNodes)
  helloBody.add(ifNode)

  helloProc.add(helloBody)

  let helloCall = newTree(nkCall, newIdent("hello"))
  var astProgram = Ast(nodes: @[addProc, mainCall, helloProc, helloCall])


  var ctx = initJitContext()
  # Register C builtin 'puts' for echo simulation
  ctx.functions["puts"] = gcc_jit_context_get_builtin_function(ctx.ctxt, "puts")
  ctx.functions["printf"] = gcc_jit_context_get_builtin_function(ctx.ctxt, "printf")

  # ctx.genScript(astProgram)
  ctx.compileAot(astProgram, "./myprog.so") # or "/tmp/myprog" for executable

  proc compileAndRun() =
    # Compile and run
    let result = gcc_jit_context_compile(ctx.ctxt)
    if result == nil:
      echo "JIT compilation failed: ", $gcc_jit_context_get_first_error(ctx.ctxt)
      quit(1)
    let fnPtr = gcc_jit_result_get_code(result, "main")
    if fnPtr == nil:
      echo "Could not find 'main' function in JIT result"
      quit(1)
    
    echo "JIT compilation succeeded, executing 'main'..."
    # now we can call the JIT-compiled `main` function

    type
      MainFunctionType = proc(): cint {.cdecl.}
        # Define the expected signature of the 'main' function (no params, returns int)
      AddFunctionType = proc(a: cint, b: cint): cint {.cdecl.}
        # Define the expected signature of the 'add' function (two int params, returns int)
    let theMainFunc = cast[MainFunctionType](fnPtr)
    # let theAddFunc = cast[AddFunctionType](gcc_jit_result_get_code(result, "add"))
    let ret = theMainFunc()
    # discard theAddFunc(10, 20) # Test calling the 'add' function directly

    # echo &"main() returned: {ret}"
    gcc_jit_result_release(result)
    freeJitContext(ctx)
  compileAndRun()
