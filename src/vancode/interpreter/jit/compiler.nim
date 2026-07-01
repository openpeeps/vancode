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

  {.passC:"-I/usr/local/include".}
  {.passL:"-L/usr/local/lib/gcc/current -lgccjit -Wl,-undefined,dynamic_lookup".}

  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc =
    if theProc.kind != pkNative or theProc.chunk == nil: return nil
    let cached = vm.getCachedOps(theProc.chunk)
    let opCount = cached.opcodes.len
    if opCount == 0: return nil

    # Check if any unsupported opcodes exist
    for oc in cached.opcodes:
      if oc notin {opcPushI, opcPushF, opcPushTrue, opcPushFalse,
                   opcPushL, opcPopL,
                   opcAddI, opcSubI, opcMultI, opcDivI,
                   opcAddF, opcSubF, opcMultF, opcDivF,
                   opcEqI, opcLessI, opcGreaterI,
                   opcInvB,
                   opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack,
                   opcReturnVal, opcReturnVoid, opcHalt,
                   opcNoop}:
        return nil  # unsupported opcode

    let ctx = gcc_jit_context_acquire()
    if ctx == nil: return nil
    gcc_jit_context_set_int_option(ctx, GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, 2)
    let jt = initJitTypes(ctx)

    let voidPtrType = jt.voidPtrType
    let i64Type = jt.i64Type

    let retParam = gcc_jit_context_new_param(ctx, nil,
      gcc_jit_type_get_pointer(jt.returnStructType), "result")
    let argsParam = gcc_jit_context_new_param(ctx, nil, gcc_jit_type_get_pointer(i64Type), "args")
    let argcParam = gcc_jit_context_new_param(ctx, nil, i64Type, "argc")
    var params = [argsParam, argcParam, retParam]

    let jitFn = gcc_jit_context_new_function(ctx, nil, GCC_JIT_FUNCTION_EXPORTED,
      jt.voidType, theProc.name, 3, addr params[0], 0)

    let entryBlock = gcc_jit_function_new_block(jitFn, "entry")
    var blocks = newSeq[ptr gcc_jit_block](opCount)
    for i in 0..<opCount:
      blocks[i] = gcc_jit_function_new_block(jitFn, "bb" & $i)

    let stackSize = (opCount + 64).cint
    let stackI = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, i64Type, stackSize), "stackI")
    let stackF = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, jt.f64Type, stackSize), "stackF")
    let spLocal = gcc_jit_function_new_local(jitFn, nil, i64Type, "sp")

    gcc_jit_block_add_assignment(entryBlock, nil, spLocal,
      gcc_jit_context_zero(ctx, i64Type))
    gcc_jit_block_end_with_jump(entryBlock, nil, blocks[0])

    let jtTargets = cached.jumpTargets

    for pc in 0..<opCount:
      let oc = cached.opcodes[pc]
      let blk = blocks[pc]
      let isLast = pc == opCount - 1
      let nextBlk = if not isLast and oc notin {opcReturnVal, opcReturnVoid, opcHalt,
          opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack}: blocks[pc + 1] else: nil
      let spRval = gcc_jit_lvalue_as_rvalue(spLocal)

      template pushInt(arrField, val, sp: untyped) =
        let ap = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(arrField), sp)
        gcc_jit_block_add_assignment(blk, nil, ap, val)
        gcc_jit_block_add_assignment(blk, nil, spLocal,
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, sp, gcc_jit_context_one(ctx, i64Type)))

      template popInt(arrField; sp: untyped): ptr gcc_jit_rvalue =
        let spd = gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_MINUS,
          i64Type, sp, gcc_jit_context_one(ctx, i64Type))
        gcc_jit_block_add_assignment(blk, nil, spLocal, spd)
        gcc_jit_lvalue_as_rvalue(
          gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(arrField), sp))

      template term() =
        if nextBlk != nil: gcc_jit_block_end_with_jump(blk, nil, nextBlk)
        else: gcc_jit_block_end_with_void_return(blk, nil)

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
        pushInt(stackI,
          gcc_jit_context_new_comparison(ctx, nil, cmp, a, b), spRval)
        term()
      of opcInvB:
        let v = popInt(stackI, spRval)
        let notV = gcc_jit_context_new_unary_op(ctx, nil,
          GCC_JIT_UNARY_OP_LOGICAL_NEGATE, jt.boolType, v)
        pushInt(stackI, notV, spRval)
        term()
      of opcJumpFwd:
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_jump(blk, nil, blocks[jtTargets[pc]])
      of opcJumpFwdF:
        let cond = popInt(stackI, spRval)
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_conditional(blk, nil, cond, nextBlk, blocks[jtTargets[pc]])
      of opcJumpFwdT:
        let cond = popInt(stackI, spRval)
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_conditional(blk, nil, cond, blocks[jtTargets[pc]], nextBlk)
      of opcJumpBack:
        if jtTargets[pc] >= 0:
          gcc_jit_block_end_with_jump(blk, nil, blocks[jtTargets[pc]])
      of opcReturnVal:
        let val = popInt(stackI, spRval)
        let rp = gcc_jit_param_as_rvalue(retParam)
        let rpLval = gcc_jit_rvalue_dereference(rp, nil)
        let rf0 = gcc_jit_lvalue_access_field(rpLval, nil,
          gcc_jit_struct_get_field(jt.returnStruct, 0))
        let rf1 = gcc_jit_lvalue_access_field(rpLval, nil,
          gcc_jit_struct_get_field(jt.returnStruct, 1))
        gcc_jit_block_add_assignment(blk, nil, rf0,
          gcc_jit_context_new_rvalue_from_long(ctx, i64Type, tyInt))
        gcc_jit_block_add_assignment(blk, nil, rf1, val)
        gcc_jit_block_end_with_void_return(blk, nil)
      of opcReturnVoid, opcHalt:
        gcc_jit_block_end_with_void_return(blk, nil)
      else:
        if nextBlk != nil: gcc_jit_block_end_with_jump(blk, nil, nextBlk)
        else: gcc_jit_block_end_with_void_return(blk, nil)

    let compileResult = gcc_jit_context_compile(ctx)
    if compileResult == nil:
      let err = $gcc_jit_context_get_first_error(ctx)
      gcc_jit_context_release(ctx)
      raise newException(ValueError, "JIT compile failed: " & err)

    let fnPtr = gcc_jit_result_get_code(compileResult, theProc.name)
    if fnPtr == nil:
      gcc_jit_result_release(compileResult)
      gcc_jit_context_release(ctx)
      raise newException(ValueError, "JIT: function '" & theProc.name & "' not found")

    type JitFn = proc (flatArgs: ptr int64, argc: int, result: ptr JitReturn) {.cdecl.}
    let jitFnPtr = cast[JitFn](fnPtr)

    # Auto-detect total local count from opcodes
    var maxLocal = theProc.paramCount
    for pc in 0..<opCount:
      let oc = cached.opcodes[pc]
      if oc == opcPushL or oc == opcPopL:
        let idx = cached.getArg1Int(pc)
        if idx >= maxLocal: maxLocal = idx + 1

    result = proc (args: StackView, argc: int): Value {.closure.} =
      var flatLocals = newSeq[int64](max(maxLocal, 1))
      for i in 0..<min(argc, maxLocal):
        flatLocals[i] = args[i].intVal
      if maxLocal == 0 and argc > 0:
        flatLocals[0] = args[0].intVal

      var jr: JitReturn
      when not defined(release):
        if jitFnPtr == nil:
          return Value(typeId: tyNil)
      jitFnPtr(addr flatLocals[0], argc, addr jr)

      for i in 0..<min(argc, maxLocal):
        args[i].intVal = flatLocals[i]

      case jr.typeId
      of tyBool: initValue(jr.intVal != 0)
      of tyInt:  initValue(jr.intVal)
      of tyFloat: initValue(jr.floatVal)
      of tyString:
        if jr.ptrVal != nil: Value(typeId: tyString, stringVal: cast[ref string](jr.ptrVal))
        else: Value(typeId: tyNil)
      else:      Value(typeId: tyNil)

else:
  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc {.inline.} =
    return nil