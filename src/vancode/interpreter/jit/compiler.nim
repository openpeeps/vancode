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
  import std/[tables, sysatomics]

  {.passC:"-I/usr/local/include".}
  {.passL:"-L/usr/local/lib/gcc/current -lgccjit -Wl,-undefined,dynamic_lookup".}

  var jitFnTable*: array[65536, pointer]  # procId -> JIT function pointer
  var jitParamCount*: array[65536, int]    # procId -> parameter count

  var jitGlobalVm*: Vm = nil

  proc setJitVm*(vm: Vm) =
    jitGlobalVm = vm

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
                   opcPushL, opcPopL, opcPushNil, opcPushS,
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
    gcc_jit_context_set_int_option(ctx, GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, 2)
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
        let cond = popInt(stackI, spRval)
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_conditional(blk, nil,
            gcc_jit_context_new_cast(ctx, nil, cond, jt.boolType),
            nextBlk, getBlock(jtTargets[pc]))
        else:
          term()
      of opcJumpFwdT:
        let cond = popInt(stackI, spRval)
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
        if targetProcId != theProc.procId:
          return nil
        let nArgs = theProc.paramCount
        let argVal = popInt(stackI, spRval)
        let arrTy = gcc_jit_context_new_array_type(ctx, nil, i64Type, nArgs.cint.max(1))
        let arrL = gcc_jit_function_new_local(jitFn, nil, arrTy, "_ca")
        let slot0 = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(arrL),
          gcc_jit_context_zero(ctx, i64Type))
        gcc_jit_block_add_assignment(blk, nil, slot0, argVal)
        let arrAddr = gcc_jit_context_new_cast(ctx, nil,
          gcc_jit_lvalue_get_address(arrL, nil), i64PtrType)
        let argcV = gcc_jit_context_new_rvalue_from_long(ctx, i64Type, nArgs)
        var crv = [arrAddr, argcV]
        let r = gcc_jit_context_new_call(ctx, nil, jitFn, 2, addr crv[0])
        pushInt(stackI, gcc_jit_context_new_cast(ctx, nil, r, i64Type), spRval)
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

    type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
    let jitFnPtr = cast[JitFn](fnPtr)

    # Auto-detect total local count from opcodes
    var maxLocal = theProc.paramCount
    for pc in 0..<opCount:
      let oc = cached.opcodes[pc]
      if oc == opcPushL or oc == opcPopL:
        let idx = cached.getArg1Int(pc)
        if idx >= maxLocal: maxLocal = idx + 1

    # Store the raw function pointer and metadata on the Proc
    # Order matters: set maxLocal BEFORE codePtr (acts as release)
    theProc.jitMaxLocal = maxLocal
    atomicStoreN(addr theProc.jitCodePtr, fnPtr, AtomicRelease)

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
      for i in 0..<min(argc, localMaxLocal):
        args[i].intVal = flatLocals[i]
      initValue(resultI)

else:
  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc {.inline.} =
    return nil