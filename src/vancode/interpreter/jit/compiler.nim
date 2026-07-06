# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ../[chunk, vm, value]
import ./types

when defined(vancodeJit):
  import pkg/gccjit
  import std/[tables, sysatomics, critbits]

  {.passC:"-I/usr/local/include".}
  {.passL:"-L/usr/local/lib/gcc/current -lgccjit -Wl,-undefined,dynamic_lookup".}

  var jitFnTable*: array[65536, pointer]  # procId -> JIT function pointer
  var jitProcTable*: array[65536, pointer] # procId -> Proc pointer (for recompilation checks)
  var jitParamCount*: array[65536, int]    # procId -> parameter count
  var jitOptLevel*: cint = 3               # default GCC optimization level
  const hotRecompileThreshold = 100        # call count before recompiling at -O3

  var jitGlobalVm*: Vm = nil
  var jitGlobalsPtr*: pointer = nil  ## pointer to VM's globals CritBitTree

  proc setJitGlobalsPtr*(p: pointer) =
    jitGlobalsPtr = p

  proc jitBridgePushG*(namePtr: pointer): int64 {.cdecl, exportc.} =
    ## Bridge for opcPushG: reads a global variable value by name.
    let name = cast[cstring](namePtr)
    if name == nil or jitGlobalsPtr == nil: return 0
    let g = cast[ptr CritBitTree[Value]](jitGlobalsPtr)
    let key = $name
    if key notin g[]: return 0
    result = g[][key].intVal

  proc jitBridgePopG*(namePtr: pointer, val: int64) {.cdecl, exportc.} =
    ## Bridge for opcPopG: stores a value to a global variable by name.
    let name = cast[cstring](namePtr)
    if name == nil or jitGlobalsPtr == nil: return
    let g = cast[ptr CritBitTree[Value]](jitGlobalsPtr)
    g[][$name] = Value(typeId: tyInt, intVal: val)

  proc setJitVm*(vm: Vm) =
    jitGlobalVm = vm

  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc {.gcsafe.}

  proc jitRecompileAtO3(theProc: Proc) =
    if theProc.jitRecompiled: return
    theProc.jitRecompiled = true
    if jitOptLevel >= 3: return  # already at max optimization
    let savedOpt = jitOptLevel
    jitOptLevel = 3
    discard compileProc(jitGlobalVm, theProc)
    jitOptLevel = savedOpt

  proc findProcById(procId: int): Proc =
    if jitGlobalVm == nil: return nil
    for _, s in jitGlobalVm.importedModules:
      if procId >= 0 and procId < s.procs.len:
        return s.procs[procId]
    nil

  proc jitCallProcBridgeFlat*(procId: int32, flatArgs: ptr int64, argc: int32): int64 {.cdecl, exportc.} =
    ## Simplified bridge for JIT-to-JIT cross-function calls.
    ## Uses jitFnTable for O(1) lookup by procId.
    let fnPtr = jitFnTable[procId]
    if fnPtr != nil:
      let p = cast[Proc](jitProcTable[procId])
      if p != nil and not p.jitRecompiled:
        p.jitCallCount += 1
        if p.jitCallCount >= hotRecompileThreshold:
          jitRecompileAtO3(p)
      type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
      return cast[JitFn](fnPtr)(flatArgs, argc)
    let theProc = findProcById(procId.int)
    if theProc == nil: return 0
    let fnPtr2 = atomicLoadN(addr theProc.jitCodePtr, AtomicAcquire)
    if fnPtr2 != nil:
      jitFnTable[procId] = fnPtr2
      let p = cast[Proc](jitProcTable[procId])
      if p != nil and not p.jitRecompiled:
        p.jitCallCount += 1
        if p.jitCallCount >= hotRecompileThreshold:
          jitRecompileAtO3(p)
      type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
      return cast[JitFn](fnPtr2)(flatArgs, argc)
    var tmp: array[256, Value]
    if argc > 256: return 0
    let arr = cast[ptr UncheckedArray[int64]](flatArgs)
    for i in 0..<argc:
      tmp[i] = Value(typeId: tyInt, intVal: arr[i])
    let callResult =
      if theProc.jitForeign != nil:
        theProc.jitForeign(cast[StackView](addr tmp[0]), argc)
      elif theProc.kind == pkForeign and theProc.foreign != nil:
        theProc.foreign(cast[StackView](addr tmp[0]), argc)
      else:
        nil
    if callResult == nil: return 0
    case callResult.typeId
    of tyInt: return callResult.intVal
    of tyBool: return callResult.boolVal.ord.int64
    else: return 0

  proc jitCallProcBridge(procId: int32, stackIPtr: ptr int64, sp: int32, deltaPtr: ptr int32, resultIntPtr: ptr int64) {.cdecl, exportc.} =
    ## C-ABI bridge: called from JIT'd code to dispatch opcCallD.
    if jitGlobalVm == nil:
      deltaPtr[] = 0; return
    var theProc: Proc = nil
    for _, s in jitGlobalVm.importedModules:
      if procId >= 0 and procId < s.procs.len:
        theProc = s.procs[procId]; break
    if theProc == nil:
      deltaPtr[] = 0; return
    let argc = theProc.paramCount
    if argc == 0:
      deltaPtr[] = 0; return
    let arr = cast[ptr UncheckedArray[int64]](stackIPtr)
    var flatArgs = newSeq[int64](argc)
    for i in 0..<argc:
      flatArgs[i] = arr[sp.int - argc + i]
    if theProc.jitForeign != nil:
      let callResult = theProc.jitForeign(cast[StackView](addr flatArgs[0]), argc)
      if callResult != nil:
        case callResult.typeId
        of tyInt:
          resultIntPtr[] = callResult.intVal
          arr[sp.int - argc] = callResult.intVal
          deltaPtr[] = (argc - 1).int32
          return
        of tyBool:
          resultIntPtr[] = callResult.boolVal.ord.int64
          arr[sp.int - argc] = callResult.boolVal.ord.int64
          deltaPtr[] = (argc - 1).int32
          return
        else: discard
    arr[sp.int - argc] = 0
    deltaPtr[] = (argc - 1).int32

  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc =
    if theProc.kind != pkNative or theProc.chunk == nil: return nil
    let cached = vm.getCachedOps(theProc.chunk)
    let opCount = cached.opcodes.len
    if opCount == 0: return nil

    # Use the proc's procId (set during codegen) for self-recursion detection
    let selfProcId = theProc.procId
    for oc in cached.opcodes:
      if oc notin {opcPushI, opcPushF, opcPushTrue, opcPushFalse,
                    opcPushL, opcPopL, opcIncL, opcDecL, opcPushNil, opcPushS,
                   opcPushG, opcPopG,
                   opcAddI, opcSubI, opcMultI, opcDivI,
                   opcAddF, opcSubF, opcMultF, opcDivF,
                   opcEqI, opcLessI, opcGreaterI,
                   opcInvB, opcDiscard,
                   opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack,
                   opcReturnVal, opcReturnVoid, opcHalt,
                    opcNoop, opcCallD}:
        return nil  # unsupported opcode

    let ctx = gcc_jit_context_acquire()
    if ctx == nil: return nil
    gcc_jit_context_set_int_option(ctx, GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, jitOptLevel)
    gcc_jit_context_set_bool_option(ctx, GCC_JIT_BOOL_OPTION_DEBUGINFO, 0)
    gcc_jit_context_set_bool_option(ctx, GCC_JIT_BOOL_OPTION_DUMP_GENERATED_CODE, 0)
    gcc_jit_context_set_bool_allow_unreachable_blocks(ctx, 1)
    let jt = initJitTypes(ctx)

    let voidPtrType = jt.voidPtrType
    let i64Type = jt.i64Type

    let int32Type = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_INT)
    let int32PtrType = gcc_jit_type_get_pointer(int32Type)
    let i64PtrType = gcc_jit_type_get_pointer(i64Type)
    let retStructPtrType = gcc_jit_type_get_pointer(jt.returnStructType)

    let argsParam = gcc_jit_context_new_param(ctx, nil, i64PtrType, "args")
    let argcParam = gcc_jit_context_new_param(ctx, nil, i64Type, "argc")
    var params = [argsParam, argcParam]

    let jitFn = gcc_jit_context_new_function(ctx, nil, GCC_JIT_FUNCTION_EXPORTED,
      i64Type, theProc.name, 2, addr params[0], 0)

    let entryBlock = gcc_jit_function_new_block(jitFn, "entry")
    var blocks = newSeq[ptr gcc_jit_block](opCount)
    template getBlock(i: int): ptr gcc_jit_block =
      if blocks[i] == nil:
        blocks[i] = gcc_jit_function_new_block(jitFn, "bb" & $i)
      blocks[i]

    let stackSize = (opCount + 64).cint
    let stackI = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, i64Type, stackSize), "stackI")
    let stackF = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, jt.f64Type, stackSize), "stackF")
    let stackP = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, voidPtrType, stackSize), "stackP")
    let spLocal = gcc_jit_function_new_local(jitFn, nil, i64Type, "sp")

    # Copy args from flat array to stackI[0..paramCount-1]
    for i in 0..<theProc.paramCount:
      let argVal = gcc_jit_context_new_array_access(ctx, nil,
        gcc_jit_param_as_rvalue(argsParam),
        gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
      let stackSlot = gcc_jit_context_new_array_access(ctx, nil,
        gcc_jit_lvalue_as_rvalue(stackI),
        gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
      gcc_jit_block_add_assignment(entryBlock, nil, stackSlot,
        gcc_jit_lvalue_as_rvalue(argVal))
    gcc_jit_block_add_assignment(entryBlock, nil, spLocal,
      gcc_jit_context_new_rvalue_from_long(ctx, i64Type, theProc.paramCount))
    gcc_jit_block_end_with_jump(entryBlock, nil, getBlock(0))

    let jtTargets = cached.jumpTargets

    # Compute reachable opcodes
    var reachable = newSeq[bool](opCount)
    if opCount > 0: reachable[0] = true
    for pc in 0..<opCount:
      if not reachable[pc]: continue
      let oc = cached.opcodes[pc]
      if oc in {opcReturnVal, opcReturnVoid, opcHalt}: discard
      elif oc in {opcJumpFwd, opcJumpBack}:
        if jtTargets[pc] >= 0 and jtTargets[pc] < opCount:
          reachable[jtTargets[pc]] = true
        elif pc + 1 < opCount:
          reachable[pc + 1] = true
      elif oc in {opcJumpFwdF, opcJumpFwdT}:
        if pc + 1 < opCount: reachable[pc + 1] = true
        if jtTargets[pc] >= 0 and jtTargets[pc] < opCount:
          reachable[jtTargets[pc]] = true
      else:
        if pc + 1 < opCount: reachable[pc + 1] = true

    proc callThroughPtr(ctxt: ptr gcc_jit_context; loc: ptr gcc_jit_location;
        fn_ptr: ptr gcc_jit_rvalue; numargs: cint; args: ptr ptr gcc_jit_rvalue): ptr gcc_jit_rvalue
        {.cdecl, importc: "gcc_jit_context_new_call_through_ptr".}

    for pc in 0..<opCount:
      if not reachable[pc]: continue
      let oc = cached.opcodes[pc]
      let blk = getBlock(pc)
      let isLast = pc == opCount - 1
      let nextBlk = if not isLast and oc notin {opcReturnVal, opcReturnVoid, opcHalt,
          opcJumpFwd, opcJumpBack} and reachable[pc + 1]: getBlock(pc + 1) else: nil
      let spRval = gcc_jit_lvalue_as_rvalue(spLocal)

      template pushInt(arrField, val, sp: untyped) =
        let ap = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(arrField), sp)
        gcc_jit_block_add_assignment(blk, nil, ap, val)
        gcc_jit_block_add_assignment(blk, nil, spLocal,
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, sp, gcc_jit_context_one(ctx, i64Type)))

      template popInt(arrField; sp: untyped): ptr gcc_jit_rvalue =
        let spTemp = gcc_jit_function_new_local(jitFn, nil, i64Type, "os")
        gcc_jit_block_add_assignment(blk, nil, spTemp, sp)
        let idx = gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_MINUS,
          i64Type, gcc_jit_lvalue_as_rvalue(spTemp),
          gcc_jit_context_one(ctx, i64Type))
        let val = gcc_jit_lvalue_as_rvalue(
          gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(arrField), idx))
        gcc_jit_block_add_assignment(blk, nil, spLocal, idx)
        val

      template pushPtr(arrField, val, sp: untyped) =
        let ap = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(arrField), sp)
        gcc_jit_block_add_assignment(blk, nil, ap, val)
        gcc_jit_block_add_assignment(blk, nil, spLocal,
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, sp, gcc_jit_context_one(ctx, i64Type)))

      template popPtr(arrField; sp: untyped): ptr gcc_jit_rvalue =
        let spd = gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_MINUS,
          i64Type, sp, gcc_jit_context_one(ctx, i64Type))
        gcc_jit_block_add_assignment(blk, nil, spLocal, spd)
        gcc_jit_lvalue_as_rvalue(
          gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(arrField), sp))

      template term() =
        if nextBlk != nil: gcc_jit_block_end_with_jump(blk, nil, nextBlk)
        else: gcc_jit_block_end_with_return(blk, nil,
          gcc_jit_context_zero(ctx, i64Type))

      case oc
      of opcPushI:
        pushInt(stackI,
          gcc_jit_context_new_rvalue_from_long(ctx, i64Type, cached.getArg1Int(pc)), spRval)
        term()
      of opcPushF:
        let ap = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(stackF), spRval)
        gcc_jit_block_add_assignment(blk, nil, ap,
          gcc_jit_context_new_rvalue_from_double(ctx, jt.f64Type, cached.getArg1Float(pc)))
        gcc_jit_block_add_assignment(blk, nil, spLocal,
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, spRval, gcc_jit_context_one(ctx, i64Type)))
        term()
      of opcPushTrue:
        pushInt(stackI, gcc_jit_context_one(ctx, i64Type), spRval)
        term()
      of opcPushFalse:
        pushInt(stackI, gcc_jit_context_zero(ctx, i64Type), spRval)
        term()
      of opcPushL:
        pushInt(stackI,
          gcc_jit_lvalue_as_rvalue(
            gcc_jit_context_new_array_access(ctx, nil,
              gcc_jit_param_as_rvalue(argsParam),
              gcc_jit_context_new_rvalue_from_long(ctx, i64Type, cached.getArg1Int(pc)))), spRval)
        term()
      of opcPopL:
        let val = popInt(stackI, spRval)
        gcc_jit_block_add_assignment(blk, nil,
          gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_param_as_rvalue(argsParam),
            gcc_jit_context_new_rvalue_from_long(ctx, i64Type, cached.getArg1Int(pc))), val)
        term()
      of opcIncL:
        let slot = cached.getArg1Int(pc)
        let localLval = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_param_as_rvalue(argsParam),
          gcc_jit_context_new_rvalue_from_long(ctx, i64Type, slot))
        let cur = gcc_jit_lvalue_as_rvalue(localLval)
        let plusOne = gcc_jit_context_new_binary_op(ctx, nil,
          GCC_JIT_BINARY_OP_PLUS, i64Type, cur, gcc_jit_context_one(ctx, i64Type))
        gcc_jit_block_add_assignment(blk, nil, localLval, plusOne)
        term()
      of opcDecL:
        let slot = cached.getArg1Int(pc)
        let localLval = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_param_as_rvalue(argsParam),
          gcc_jit_context_new_rvalue_from_long(ctx, i64Type, slot))
        let cur = gcc_jit_lvalue_as_rvalue(localLval)
        let minusOne = gcc_jit_context_new_binary_op(ctx, nil,
          GCC_JIT_BINARY_OP_MINUS, i64Type, cur, gcc_jit_context_one(ctx, i64Type))
        gcc_jit_block_add_assignment(blk, nil, localLval, minusOne)
        term()
      of opcPushG:
        let sid = cached.getArg1Int(pc)
        let nameStr = theProc.chunk.strings[sid]
        let nameLit = gcc_jit_context_new_string_literal(ctx, nameStr)
        let namePtr = gcc_jit_context_new_cast(ctx, nil, nameLit, voidPtrType)
        let pushGParamTypes = [voidPtrType]
        let pushGFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 1, addr pushGParamTypes[0], 0)
        let pushGAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgePushG)
        let pushGFnRval = gcc_jit_context_new_cast(ctx, nil, pushGAddr, pushGFnType)
        var callArgs: array[1, ptr gcc_jit_rvalue] = [namePtr]
        let globalVal = callThroughPtr(ctx, nil, pushGFnRval, 1.cint, addr callArgs[0])
        pushInt(stackI, globalVal, spRval)
        term()
      of opcPopG:
        let sid = cached.getArg1Int(pc)
        let nameStr = theProc.chunk.strings[sid]
        let nameLit = gcc_jit_context_new_string_literal(ctx, nameStr)
        let namePtr = gcc_jit_context_new_cast(ctx, nil, nameLit, voidPtrType)
        let val = popInt(stackI, spRval)
        let voidType = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_VOID)
        let popGParamTypes = [voidPtrType, i64Type]
        let popGFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, voidType, 2, addr popGParamTypes[0], 0)
        let popGAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgePopG)
        let popGFnRval = gcc_jit_context_new_cast(ctx, nil, popGAddr, popGFnType)
        var callArgs: array[2, ptr gcc_jit_rvalue] = [namePtr, val]
        discard callThroughPtr(ctx, nil, popGFnRval, 2.cint, addr callArgs[0])
        term()
      of opcNoop:
        term()
      of opcAddI, opcSubI, opcMultI, opcDivI:
        let b = popInt(stackI, spRval)
        let a = popInt(stackI, spRval)
        let binOp = case oc
          of opcAddI:  GCC_JIT_BINARY_OP_PLUS
          of opcSubI:  GCC_JIT_BINARY_OP_MINUS
          of opcMultI: GCC_JIT_BINARY_OP_MULT
          of opcDivI:  GCC_JIT_BINARY_OP_DIVIDE
          else:        GCC_JIT_BINARY_OP_PLUS
        pushInt(stackI,
          gcc_jit_context_new_binary_op(ctx, nil, binOp, i64Type, a, b), spRval)
        term()
      of opcAddF, opcSubF, opcMultF, opcDivF:
        let b = popInt(stackF, spRval)
        let a = popInt(stackF, spRval)
        let binOp = case oc
          of opcAddF:  GCC_JIT_BINARY_OP_PLUS
          of opcSubF:  GCC_JIT_BINARY_OP_MINUS
          of opcMultF: GCC_JIT_BINARY_OP_MULT
          of opcDivF:  GCC_JIT_BINARY_OP_DIVIDE
          else:        GCC_JIT_BINARY_OP_PLUS
        let result = gcc_jit_context_new_binary_op(ctx, nil, binOp, jt.f64Type, a, b)
        let ap = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(stackF),
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, spRval, gcc_jit_context_one(ctx, i64Type)))
        gcc_jit_block_add_assignment(blk, nil, ap, result)
        gcc_jit_block_add_assignment(blk, nil, spLocal,
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, spRval, gcc_jit_context_one(ctx, i64Type)))
        term()
      of opcEqI, opcLessI, opcGreaterI:
        let b = popInt(stackI, spRval)
        let a = popInt(stackI, spRval)
        let cmp = case oc
          of opcEqI:      GCC_JIT_COMPARISON_EQ
          of opcLessI:    GCC_JIT_COMPARISON_LT
          of opcGreaterI: GCC_JIT_COMPARISON_GT
          else:           GCC_JIT_COMPARISON_EQ
        let boolVal = gcc_jit_context_new_comparison(ctx, nil, cmp, a, b)
        pushInt(stackI,
          gcc_jit_context_new_cast(ctx, nil, boolVal, i64Type), spRval)
        term()
      of opcInvB:
        let v = popInt(stackI, spRval)
        let notV = gcc_jit_context_new_unary_op(ctx, nil,
          GCC_JIT_UNARY_OP_LOGICAL_NEGATE, jt.boolType, v)
        pushInt(stackI,
          gcc_jit_context_new_cast(ctx, nil, notV, i64Type), spRval)
        term()
      of opcJumpFwd:
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_jump(blk, nil, getBlock(jtTargets[pc]))
        else: term()
      of opcJumpFwdF:
        let idx = gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_MINUS,
          i64Type, spRval, gcc_jit_context_one(ctx, i64Type))
        let cond = gcc_jit_lvalue_as_rvalue(
          gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(stackI), idx))
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_conditional(blk, nil,
            gcc_jit_context_new_cast(ctx, nil, cond, jt.boolType),
            nextBlk, getBlock(jtTargets[pc]))
        else:
          term()
      of opcJumpFwdT:
        # Peek (don't pop) — matches VM interpreter behavior
        let spCopy = gcc_jit_function_new_local(jitFn, nil, i64Type, "jft_sp")
        gcc_jit_block_add_assignment(blk, nil, spCopy, spRval)
        let idx = gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_MINUS,
          i64Type, spRval, gcc_jit_context_one(ctx, i64Type))
        let cond = gcc_jit_lvalue_as_rvalue(
          gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(stackI), idx))
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_conditional(blk, nil,
            gcc_jit_context_new_cast(ctx, nil, cond, jt.boolType),
            getBlock(jtTargets[pc]), nextBlk)
        else:
          term()
      of opcJumpBack:
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_jump(blk, nil, getBlock(jtTargets[pc]))
        else: term()
      of opcDiscard:
        let nd = gcc_jit_context_new_rvalue_from_long(ctx, i64Type, cached.getArg1Int(pc))
        let spMinusN = gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_MINUS,
          i64Type, spRval, nd)
        gcc_jit_block_add_assignment(blk, nil, spLocal, spMinusN)
        term()
      of opcCallD:
        let targetProcId = cached.arg2[pc].int
        if targetProcId == theProc.procId:
          let nArgs = theProc.paramCount
          let arrTy = gcc_jit_context_new_array_type(ctx, nil, i64Type, nArgs.int32.max(1))
          let arrL = gcc_jit_function_new_local(jitFn, nil, arrTy, "_ca")
          for i in countdown(nArgs - 1, 0):
            let argVal = popInt(stackI, spRval)
            let slot = gcc_jit_context_new_array_access(ctx, nil,
              gcc_jit_lvalue_as_rvalue(arrL),
              gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
            gcc_jit_block_add_assignment(blk, nil, slot, argVal)
          let arrAddr = gcc_jit_context_new_cast(ctx, nil,
            gcc_jit_lvalue_get_address(arrL, nil), i64PtrType)
          let argcV = gcc_jit_context_new_rvalue_from_long(ctx, i64Type, nArgs)
          var crv = [arrAddr, argcV]
          let r = gcc_jit_context_new_call(ctx, nil, jitFn, 2, addr crv[0])
          pushInt(stackI, gcc_jit_context_new_cast(ctx, nil, r, i64Type), spRval)
          term()
        else:
          var targetProc: Proc = nil
          let filePathIdx = cached.arg1[pc].uint16
          let chunkPath = theProc.chunk.strings[filePathIdx]
          if chunkPath in vm.importedModules:
            let s = vm.importedModules[chunkPath]
            if targetProcId >= 0 and targetProcId < s.procs.len:
              targetProc = s.procs[targetProcId]
          if targetProc == nil:
            for _, s in vm.importedModules:
              if targetProcId >= 0 and targetProcId < s.procs.len:
                targetProc = s.procs[targetProcId]; break
          if targetProc == nil:
            return nil
          else:
            let nArgs = targetProc.paramCount
            let arrTy = gcc_jit_context_new_array_type(ctx, nil, i64Type, nArgs.int32.max(1))
            let arrL = gcc_jit_function_new_local(jitFn, nil, arrTy, "_ca")
            for i in countdown(nArgs - 1, 0):
              let argVal = popInt(stackI, spRval)
              let slot = gcc_jit_context_new_array_access(ctx, nil,
                gcc_jit_lvalue_as_rvalue(arrL),
                gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
              gcc_jit_block_add_assignment(blk, nil, slot, argVal)
            let arrAddr = gcc_jit_context_new_cast(ctx, nil,
              gcc_jit_lvalue_get_address(arrL, nil), i64PtrType)
            let argcV = gcc_jit_context_new_rvalue_from_long(ctx, i64Type, nArgs)
            let bridgeParamTypes = [int32Type, i64PtrType, int32Type]
            let bridgeFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 3, addr bridgeParamTypes[0], 0)
            let bridgeAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitCallProcBridgeFlat)
            let bridgeFnRval = gcc_jit_context_new_cast(ctx, nil, bridgeAddr, bridgeFnType)
            var callArgs: array[3, ptr gcc_jit_rvalue] = [
              gcc_jit_context_new_rvalue_from_long(ctx, int32Type, targetProcId),
              arrAddr,
              gcc_jit_context_new_cast(ctx, nil, argcV, int32Type)
            ]
            let callResult = callThroughPtr(ctx, nil, bridgeFnRval, 3.cint, addr callArgs[0])
            pushInt(stackI, callResult, spRval)
            term()
      of opcPushNil:
        pushInt(stackI, gcc_jit_context_zero(ctx, i64Type), spRval)
        term()
      of opcPushS:
        let sid = cached.getArg1Int(pc)
        let strVal = theProc.chunk.strings[sid]
        let globalStr = gcc_jit_context_new_string_literal(ctx, strVal)
        let strPtr = gcc_jit_context_new_cast(ctx, nil, globalStr, voidPtrType)
        pushPtr(stackP, strPtr, spRval)
        term()
      of opcReturnVal:
        let val = popInt(stackI, spRval)
        gcc_jit_block_end_with_return(blk, nil, val)
      of opcReturnVoid, opcHalt:
        gcc_jit_block_end_with_return(blk, nil,
          gcc_jit_context_zero(ctx, i64Type))
      else:
        if nextBlk != nil: gcc_jit_block_end_with_jump(blk, nil, nextBlk)
        else: gcc_jit_block_end_with_return(blk, nil,
          gcc_jit_context_zero(ctx, i64Type))

    let compileResult = gcc_jit_context_compile(ctx)
    if compileResult == nil:
      gcc_jit_context_release(ctx)
      return nil

    let fnPtr = gcc_jit_result_get_code(compileResult, theProc.name)
    if fnPtr == nil:
      gcc_jit_result_release(compileResult)
      gcc_jit_context_release(ctx)
      raise newException(ValueError, "JIT: function '" & theProc.name & "' not found")

    var maxLocal = theProc.paramCount
    for pc in 0..<opCount:
      let oc = cached.opcodes[pc]
      if oc == opcPushL or oc == opcPopL:
        let idx = cached.getArg1Int(pc)
        if idx >= maxLocal: maxLocal = idx + 1

    theProc.jitMaxLocal = maxLocal
    atomicStoreN(addr theProc.jitCodePtr, fnPtr, AtomicRelease)
    jitFnTable[theProc.procId] = fnPtr
    jitProcTable[theProc.procId] = cast[pointer](theProc)
    jitParamCount[theProc.procId] = theProc.paramCount

    result = proc (args: StackView, argc: int): Value {.closure.} =
      let localFn = atomicLoadN(addr theProc.jitCodePtr, AtomicAcquire)
      if localFn == nil:
        return Value(typeId: tyNil)
      let localMaxLocal = theProc.jitMaxLocal
      var flatLocals = newSeq[int64](max(localMaxLocal, 1))
      for i in 0..<min(argc, localMaxLocal):
        flatLocals[i] = args[i].intVal
      if localMaxLocal == 0 and argc > 0:
        flatLocals[0] = args[0].intVal
      type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
      let resultI = cast[JitFn](localFn)(addr flatLocals[0], argc)
      theProc.jitCallCount += 1
      if theProc.jitCallCount >= hotRecompileThreshold:
        jitRecompileAtO3(theProc)
      for i in 0..<min(argc, localMaxLocal):
        args[i].intVal = flatLocals[i]
      if theProc.jitReturnBool:
        result = Value(typeId: tyBool, boolVal: resultI != 0)
      else:
        result = initValue(resultI)

else:
  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc {.inline.} =
    return nil