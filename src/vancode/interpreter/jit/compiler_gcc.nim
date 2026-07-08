# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ../[chunk, vm, value]
import ./types, ./compiler_bridge

when defined(vancodeJit) or defined(vancodeJitGcc):
  import pkg/gccjit
  import std/[tables, sysatomics, critbits]

  {.passC:"-I/usr/local/include".}
  {.passL:"-L/usr/local/lib/gcc/current -lgccjit -Wl,-undefined,dynamic_lookup".}

  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc =
    if theProc.kind != pkNative or theProc.chunk == nil: return nil
    let cached = vm.getCachedOps(theProc.chunk)
    let opCount = cached.opcodes.len
    if opCount == 0: return nil

    let selfProcId = theProc.procId
    for oc in cached.opcodes:
      if oc notin {opcPushI, opcPushF, opcPushTrue, opcPushFalse,
                    opcPushL, opcPopL, opcIncL, opcDecL, opcPushNil, opcPushS,
                   opcPushG, opcPopG,
                   opcConstrArray, opcConstrObj,
                   opcAddI, opcSubI, opcMultI, opcDivI, opcNegI,
                   opcAddF, opcSubF, opcMultF, opcDivF, opcNegF,
                   opcEqI, opcLessI, opcGreaterI,
                   opcEqB, opcEqF, opcLessF, opcGreaterF,
                   opcInvB, opcDiscard,
                   opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack,
                    opcReturnVal, opcReturnVoid, opcHalt,
                     opcNoop, opcCallD,
                     opcPushProc, opcCallI,
                     opcGetF, opcSetF,
                     opcGetI, opcSetI,
                     opcConcatStr}:
        return nil

    let ctx = gcc_jit_context_acquire()
    if ctx == nil: return nil
    gcc_jit_context_set_int_option(ctx, GCC_JIT_INT_OPTION_OPTIMIZATION_LEVEL, jitOptLevel)
    gcc_jit_context_add_command_line_option(ctx, "-ffast-math")
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
    let typeStack = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, int32Type, stackSize), "typeStack")
    let stackF = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, jt.f64Type, stackSize), "stackF")
    let stackP = gcc_jit_function_new_local(jitFn, nil,
      gcc_jit_context_new_array_type(ctx, nil, voidPtrType, stackSize), "stackP")
    let spLocal = gcc_jit_function_new_local(jitFn, nil, i64Type, "sp")

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

    # Static type simulation for call args
    var simStack = newSeq[TypeId]()
    var localTypes = newSeq[TypeId](256)
    var globalTypes = initTable[string, TypeId]()
    # Pre-scan: collect known-call arg types indexed by pc
    var callArgTypes = newSeq[seq[TypeId]](opCount)
    var popGType = newSeq[TypeId](opCount)  # type for each popG
    var divFTypes = newSeq[tuple[a, b: TypeId]](opCount)  # operand types for opcDivF
    for pc in 0..<opCount:
      if not reachable[pc]: continue
      let oc = cached.opcodes[pc]
      case oc
      of opcPushI: simStack.add(tyInt)
      of opcPushTrue, opcPushFalse: simStack.add(tyBool)
      of opcPushF: simStack.add(tyFloat)
      of opcPushS: simStack.add(tyString)
      of opcPushNil: simStack.add(tyNil)
      of opcConstrArray: simStack.add(tyArrayObject)
      of opcPushG:
        let name = theProc.chunk.strings[cached.getArg1Int(pc)]
        simStack.add(globalTypes.getOrDefault(name, tyInt))
      of opcPopG:
        let name = theProc.chunk.strings[cached.getArg1Int(pc)]
        if simStack.len > 0:
          let t = simStack.pop()
          popGType[pc] = t
          globalTypes[name] = t
      of opcPushL:
        let idx = cached.getArg1Int(pc)
        simStack.add(localTypes[idx])
      of opcPopL:
        let idx = cached.getArg1Int(pc)
        if simStack.len > 0: localTypes[idx] = simStack.pop()
      of opcAddI, opcSubI, opcMultI, opcDivI, opcNegI:
        if oc == opcNegI:
          if simStack.len >= 1: simStack.setLen(simStack.len - 1)
        else:
          if simStack.len >= 2: simStack.setLen(simStack.len - 2)
        simStack.add(tyInt)
      of opcAddF, opcSubF, opcMultF, opcDivF, opcNegF:
        if oc == opcDivF and simStack.len >= 2:
          divFTypes[pc] = (simStack[^2], simStack[^1])
        if oc == opcNegF:
          if simStack.len >= 1: simStack.setLen(simStack.len - 1)
        elif simStack.len >= 2:
          simStack.setLen(simStack.len - 2)
        simStack.add(tyFloat)
      of opcEqI, opcLessI, opcGreaterI, opcInvB:
        if oc == opcInvB:
          if simStack.len >= 1: simStack.setLen(simStack.len - 1)
        elif simStack.len >= 2: simStack.setLen(simStack.len - 2)
        simStack.add(tyBool)
      of opcEqB, opcEqF, opcLessF, opcGreaterF:
        if simStack.len >= 2: simStack.setLen(simStack.len - 2)
        simStack.add(tyBool)
      of opcDiscard:
        let n = cached.getArg1Int(pc)
        if simStack.len >= n: simStack.setLen(simStack.len - n)
      of opcJumpFwdT, opcJumpFwdF:
        if simStack.len >= 1: simStack.setLen(simStack.len - 1)
      of opcConcatStr:
        if simStack.len >= 2: simStack.setLen(simStack.len - 2)
        simStack.add(tyString)
      of opcPushProc:
        simStack.add(tyInt)
      of opcCallI:
        let nArgs = cached.getArg1Int(pc).int
        if nArgs >= 0 and simStack.len >= nArgs + 1:
          simStack.setLen(simStack.len - nArgs - 1)
        simStack.add(tyInt)
      of opcGetF:
        if simStack.len >= 1: simStack.setLen(simStack.len - 1)
        simStack.add(tyInt)
      of opcSetF:
        if simStack.len >= 2: simStack.setLen(simStack.len - 2)
      of opcGetI:
        if simStack.len >= 2: simStack.setLen(simStack.len - 2)
        simStack.add(tyInt)
      of opcSetI:
        if simStack.len >= 3: simStack.setLen(simStack.len - 3)
      of opcConstrObj:
        let n = cached.getArg1Int(pc).int
        if simStack.len >= n: simStack.setLen(simStack.len - n)
        simStack.add(tyArrayObject)
      else: discard
      if oc == opcCallD:
        let targetProcId2 = cached.arg2[pc].int
        var nArgs = 0
        if targetProcId2 == theProc.procId:
          nArgs = theProc.paramCount
        else:
          # try to find target proc for its paramCount
          var tp: Proc = nil
          let fpIdx = cached.arg1[pc].uint16
          let cpStr = theProc.chunk.strings[fpIdx]
          if cpStr in vm.importedModules:
            let s2 = vm.importedModules[cpStr]
            if targetProcId2 >= 0 and targetProcId2 < s2.procs.len:
              tp = s2.procs[targetProcId2]
          if tp == nil:
            for _, s2 in vm.importedModules:
              if targetProcId2 >= 0 and targetProcId2 < s2.procs.len:
                tp = s2.procs[targetProcId2]; break
          if tp != nil: nArgs = tp.paramCount
        if nArgs > 0 and simStack.len >= nArgs:
          var argTypes = newSeq[TypeId](nArgs)
          for i in 0..<nArgs:
           argTypes[nArgs - 1 - i] = simStack[simStack.len - 1 - i]
          callArgTypes[pc] = argTypes
          simStack.setLen(simStack.len - nArgs)
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
        let popGTypeId = if pc < popGType.len: popGType[pc].int32 else: tyInt.int32
        let voidType = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_VOID)
        let popGParamTypes = [voidPtrType, i64Type, int32Type]
        let popGFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, voidType, 3, addr popGParamTypes[0], 0)
        let popGAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgePopG)
        let popGFnRval = gcc_jit_context_new_cast(ctx, nil, popGAddr, popGFnType)
        var callArgs: array[3, ptr gcc_jit_rvalue] = [namePtr, val,
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, popGTypeId)]
        discard callThroughPtr(ctx, nil, popGFnRval, 3.cint, addr callArgs[0])
        term()
      of opcNoop:
        term()
      of opcConstrArray:
        let count = cached.arg1[pc].int
        let constrArrayParamTypes = [int32Type]
        let constrArrayFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 1, addr constrArrayParamTypes[0], 0)
        let constrArrayAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeConstrArray)
        let constrArrayFnRval = gcc_jit_context_new_cast(ctx, nil, constrArrayAddr, constrArrayFnType)
        var callArgs: array[1, ptr gcc_jit_rvalue] = [
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, count.int32)
        ]
        let arrVal = callThroughPtr(ctx, nil, constrArrayFnRval, 1.cint, addr callArgs[0])
        pushInt(stackI, arrVal, spRval)
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
        let types = if oc == opcDivF and pc < divFTypes.len: divFTypes[pc]
                    else: (tyFloat, tyFloat)
        # pop top (second operand) first
        let bVal = if types.b == tyInt:
          gcc_jit_context_new_cast(ctx, nil, popInt(stackI, spRval), jt.f64Type)
        else: popInt(stackF, spRval)
        # pop second (first operand) next
        let aVal = if types.a == tyInt:
          gcc_jit_context_new_cast(ctx, nil, popInt(stackI, spRval), jt.f64Type)
        else: popInt(stackF, spRval)
        let binOp = case oc
          of opcAddF:  GCC_JIT_BINARY_OP_PLUS
          of opcSubF:  GCC_JIT_BINARY_OP_MINUS
          of opcMultF: GCC_JIT_BINARY_OP_MULT
          of opcDivF:  GCC_JIT_BINARY_OP_DIVIDE
          else:        GCC_JIT_BINARY_OP_PLUS
        let result = gcc_jit_context_new_binary_op(ctx, nil, binOp, jt.f64Type, aVal, bVal)
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
          # Tail-call optimization: if the next opcode is opcReturnVal,
          # reuse the caller's stack frame instead of making a real call.
          let inTailPos = pc + 1 < opCount and cached.opcodes[pc + 1] == opcReturnVal
          if inTailPos:
            # Write new args into the parameter array (in-place) and jump to entry
            for i in 0..<nArgs:
              let slot = gcc_jit_context_new_array_access(ctx, nil,
                gcc_jit_param_as_rvalue(argsParam),
                gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
              let arg = gcc_jit_lvalue_as_rvalue(
                gcc_jit_context_new_array_access(ctx, nil,
                  gcc_jit_lvalue_as_rvalue(arrL),
                  gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i)))
              gcc_jit_block_add_assignment(blk, nil, slot, arg)
            gcc_jit_block_end_with_jump(blk, nil, entryBlock)
          else:
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
            let callArgTys = if pc < callArgTypes.len: callArgTypes[pc] else: @[]
            let useFastAdd = nArgs == 2 and callArgTys.len >= 2 and
              callArgTys[0] == tyArrayObject and callArgTys[1] == tyInt
            let arrTy = gcc_jit_context_new_array_type(ctx, nil, i64Type, nArgs.int32.max(1))
            let arrL = gcc_jit_function_new_local(jitFn, nil, arrTy, "_ca")
            let typeArrTy = gcc_jit_context_new_array_type(ctx, nil, int32Type, nArgs.int32.max(1))
            let typeArrL = gcc_jit_function_new_local(jitFn, nil, typeArrTy, "_ta")
            var fastAddArg1: ptr gcc_jit_lvalue = nil
            for i in countdown(nArgs - 1, 0):
              let argVal = popInt(stackI, spRval)
              if useFastAdd and i == 1:
                fastAddArg1 = gcc_jit_function_new_local(jitFn, nil, i64Type, "_fa1")
                gcc_jit_block_add_assignment(blk, nil, fastAddArg1, argVal)
              else:
                let slot = gcc_jit_context_new_array_access(ctx, nil,
                  gcc_jit_lvalue_as_rvalue(arrL),
                  gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
                gcc_jit_block_add_assignment(blk, nil, slot, argVal)
              let argType = if i < callArgTys.len:
                gcc_jit_context_new_rvalue_from_long(ctx, int32Type, callArgTys[i].int32)
              else:
                gcc_jit_context_new_rvalue_from_long(ctx, int32Type, tyInt.int32)
              let typeSlot = gcc_jit_context_new_array_access(ctx, nil,
                gcc_jit_lvalue_as_rvalue(typeArrL),
                gcc_jit_context_new_rvalue_from_long(ctx, int32Type, i))
              gcc_jit_block_add_assignment(blk, nil, typeSlot, argType)
            if useFastAdd:
              let fastAddParamTypes = [i64Type, i64Type]
              let fastAddFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 2, addr fastAddParamTypes[0], 0)
              let fastAddAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeFastAdd)
              let fastAddFnRval = gcc_jit_context_new_cast(ctx, nil, fastAddAddr, fastAddFnType)
              let fastAddSlot = gcc_jit_context_new_array_access(ctx, nil,
                gcc_jit_lvalue_as_rvalue(arrL),
                gcc_jit_context_new_rvalue_from_long(ctx, i64Type, 0))
              var fastArgs: array[2, ptr gcc_jit_rvalue] = [
                gcc_jit_lvalue_as_rvalue(fastAddSlot),
                gcc_jit_lvalue_as_rvalue(fastAddArg1)
              ]
              let callResult = callThroughPtr(ctx, nil, fastAddFnRval, 2.cint, addr fastArgs[0])
              if targetProc.hasResult:
                pushInt(stackI, callResult, spRval)
              else:
                let dummyVar = gcc_jit_function_new_local(jitFn, nil, i64Type, "dummy")
                gcc_jit_block_add_assignment(blk, nil, dummyVar, callResult)
            else:
              let arrAddr = gcc_jit_context_new_cast(ctx, nil,
                gcc_jit_lvalue_get_address(arrL, nil), i64PtrType)
              let typeArrAddr = gcc_jit_context_new_cast(ctx, nil,
                gcc_jit_lvalue_get_address(typeArrL, nil), int32PtrType)
              let argcV = gcc_jit_context_new_rvalue_from_long(ctx, i64Type, nArgs)
              let bridgeParamTypes = [int32Type, i64PtrType, int32Type, int32PtrType]
              let bridgeFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 4, addr bridgeParamTypes[0], 0)
              let bridgeAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitCallProcBridgeFlat)
              let bridgeFnRval = gcc_jit_context_new_cast(ctx, nil, bridgeAddr, bridgeFnType)
              var callArgs: array[4, ptr gcc_jit_rvalue] = [
                gcc_jit_context_new_rvalue_from_long(ctx, int32Type, targetProcId),
                arrAddr,
                gcc_jit_context_new_cast(ctx, nil, argcV, int32Type),
                typeArrAddr
              ]
              let callResult = callThroughPtr(ctx, nil, bridgeFnRval, 4.cint, addr callArgs[0])
              if targetProc.hasResult:
                pushInt(stackI, callResult, spRval)
              else:
                let dummyVar = gcc_jit_function_new_local(jitFn, nil, i64Type, "dummy")
                gcc_jit_block_add_assignment(blk, nil, dummyVar, callResult)
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
      of opcNegI:
        let a = popInt(stackI, spRval)
        let negI = gcc_jit_context_new_unary_op(ctx, nil,
          GCC_JIT_UNARY_OP_MINUS, i64Type, a)
        pushInt(stackI, negI, spRval)
        term()
      of opcNegF:
        let a = popInt(stackF, spRval)
        let negF = gcc_jit_context_new_unary_op(ctx, nil,
          GCC_JIT_UNARY_OP_MINUS, jt.f64Type, a)
        let ap = gcc_jit_context_new_array_access(ctx, nil,
          gcc_jit_lvalue_as_rvalue(stackF), spRval)
        gcc_jit_block_add_assignment(blk, nil, ap, negF)
        gcc_jit_block_add_assignment(blk, nil, spLocal,
          gcc_jit_context_new_binary_op(ctx, nil, GCC_JIT_BINARY_OP_PLUS,
            i64Type, spRval, gcc_jit_context_one(ctx, i64Type)))
        term()
      of opcEqB:
        let b = popInt(stackI, spRval)
        let a = popInt(stackI, spRval)
        let eqBVal = gcc_jit_context_new_comparison(ctx, nil, GCC_JIT_COMPARISON_EQ, a, b)
        pushInt(stackI, gcc_jit_context_new_cast(ctx, nil, eqBVal, i64Type), spRval)
        term()
      of opcEqF, opcLessF, opcGreaterF:
        let bF = popInt(stackF, spRval)
        let aF = popInt(stackF, spRval)
        let cmpF = case oc
          of opcEqF:      GCC_JIT_COMPARISON_EQ
          of opcLessF:    GCC_JIT_COMPARISON_LT
          of opcGreaterF: GCC_JIT_COMPARISON_GT
          else:           GCC_JIT_COMPARISON_EQ
        let boolF = gcc_jit_context_new_comparison(ctx, nil, cmpF, aF, bF)
        pushInt(stackI, gcc_jit_context_new_cast(ctx, nil, boolF, i64Type), spRval)
        term()
      of opcConcatStr:
        let bStr = popInt(stackI, spRval)
        let aStr = popInt(stackI, spRval)
        let concatParamTypes = [i64Type, i64Type]
        let concatFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 2, addr concatParamTypes[0], 0)
        let concatAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeConcatStr)
        let concatFnRval = gcc_jit_context_new_cast(ctx, nil, concatAddr, concatFnType)
        var concatArgs: array[2, ptr gcc_jit_rvalue] = [aStr, bStr]
        let concatResult = callThroughPtr(ctx, nil, concatFnRval, 2.cint, addr concatArgs[0])
        pushInt(stackI, concatResult, spRval)
        term()
      of opcPushProc:
        let sid = cached.getArg1Int(pc)
        let pid = cached.arg2[pc].int
        let srcPath = theProc.chunk.strings[sid]
        let srcPathLit = gcc_jit_context_new_string_literal(ctx, srcPath)
        let srcPathPtr = gcc_jit_context_new_cast(ctx, nil, srcPathLit, voidPtrType)
        let pushProcParamTypes = [voidPtrType, int32Type]
        let pushProcFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 2, addr pushProcParamTypes[0], 0)
        let pushProcAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgePushProc)
        let pushProcFnRval = gcc_jit_context_new_cast(ctx, nil, pushProcAddr, pushProcFnType)
        var pushProcArgs: array[2, ptr gcc_jit_rvalue] = [
          srcPathPtr,
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, pid.int32)
        ]
        let pushProcResult = callThroughPtr(ctx, nil, pushProcFnRval, 2.cint, addr pushProcArgs[0])
        pushInt(stackI, pushProcResult, spRval)
        term()
      of opcCallI:
        let nArgs = cached.getArg1Int(pc).int
        let callIArrTy = gcc_jit_context_new_array_type(ctx, nil, i64Type, nArgs.int32.max(1))
        let callIArrL = gcc_jit_function_new_local(jitFn, nil, callIArrTy, "_cia")
        for i in countdown(nArgs - 1, 0):
          let argVal = popInt(stackI, spRval)
          let slot = gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(callIArrL),
            gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
          gcc_jit_block_add_assignment(blk, nil, slot, argVal)
        let procRefVal = popInt(stackI, spRval)
        let callIArrAddr = gcc_jit_context_new_cast(ctx, nil,
          gcc_jit_lvalue_get_address(callIArrL, nil), i64PtrType)
        let callIParamTypes = [i64Type, i64PtrType, int32Type, int32PtrType]
        let callIFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 4, addr callIParamTypes[0], 0)
        let callIAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeCallI)
        let callIFnRval = gcc_jit_context_new_cast(ctx, nil, callIAddr, callIFnType)
        var callIArgs: array[4, ptr gcc_jit_rvalue] = [
          procRefVal,
          callIArrAddr,
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, nArgs.int32),
          gcc_jit_context_null(ctx, int32PtrType)
        ]
        let callIResult = callThroughPtr(ctx, nil, callIFnRval, 4.cint, addr callIArgs[0])
        pushInt(stackI, callIResult, spRval)
        term()
      of opcGetF:
        let gfId = cached.getArg1Int(pc).int32
        let gfObjVal = popInt(stackI, spRval)
        let getFieldParamTypesArr = [i64Type, int32Type]
        let getFieldFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 2, addr getFieldParamTypesArr[0], 0)
        let getFieldAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeGetField)
        let getFieldFnRval = gcc_jit_context_new_cast(ctx, nil, getFieldAddr, getFieldFnType)
        var getFieldArgs: array[2, ptr gcc_jit_rvalue] = [gfObjVal,
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, gfId)]
        let getFieldResult = callThroughPtr(ctx, nil, getFieldFnRval, 2.cint, addr getFieldArgs[0])
        pushInt(stackI, getFieldResult, spRval)
        term()
      of opcSetF:
        let sfVal = popInt(stackI, spRval)
        let sfObjVal = popInt(stackI, spRval)
        let sfId = cached.getArg1Int(pc).int32
        let setFieldVoidType = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_VOID)
        let setFieldParamTypesArr = [i64Type, int32Type, i64Type]
        let setFieldFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, setFieldVoidType, 3, addr setFieldParamTypesArr[0], 0)
        let setFieldAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeSetField)
        let setFieldFnRval = gcc_jit_context_new_cast(ctx, nil, setFieldAddr, setFieldFnType)
        var setFieldArgs: array[3, ptr gcc_jit_rvalue] = [sfObjVal,
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, sfId), sfVal]
        discard callThroughPtr(ctx, nil, setFieldFnRval, 3.cint, addr setFieldArgs[0])
        term()
      of opcGetI:
        let giIdx = popInt(stackI, spRval)
        let giArrVal = popInt(stackI, spRval)
        let getItemParamTypesArr = [i64Type, i64Type]
        let getItemFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 2, addr getItemParamTypesArr[0], 0)
        let getItemAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeGetItem)
        let getItemFnRval = gcc_jit_context_new_cast(ctx, nil, getItemAddr, getItemFnType)
        var getItemArgs: array[2, ptr gcc_jit_rvalue] = [giArrVal, giIdx]
        let getItemResult = callThroughPtr(ctx, nil, getItemFnRval, 2.cint, addr getItemArgs[0])
        pushInt(stackI, getItemResult, spRval)
        term()
      of opcSetI:
        let siValPtr = popInt(stackI, spRval)
        let siIdx = popInt(stackI, spRval)
        let siArrVal = popInt(stackI, spRval)
        let setItemVoidType = gcc_jit_context_get_type(ctx, GCC_JIT_TYPE_VOID)
        let setItemParamTypesArr = [i64Type, i64Type, i64Type]
        let setItemFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, setItemVoidType, 3, addr setItemParamTypesArr[0], 0)
        let setItemAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeSetItem)
        let setItemFnRval = gcc_jit_context_new_cast(ctx, nil, setItemAddr, setItemFnType)
        var setItemArgs: array[3, ptr gcc_jit_rvalue] = [siArrVal, siIdx, siValPtr]
        discard callThroughPtr(ctx, nil, setItemFnRval, 3.cint, addr setItemArgs[0])
        term()
      of opcConstrObj:
        let coCount = cached.getArg1Int(pc).int
        let coArrTy = gcc_jit_context_new_array_type(ctx, nil, i64Type, coCount.int32.max(1))
        let coArrL = gcc_jit_function_new_local(jitFn, nil, coArrTy, "_coa")
        for i in countdown(coCount - 1, 0):
          let argVal = popInt(stackI, spRval)
          let slot = gcc_jit_context_new_array_access(ctx, nil,
            gcc_jit_lvalue_as_rvalue(coArrL),
            gcc_jit_context_new_rvalue_from_long(ctx, i64Type, i))
          gcc_jit_block_add_assignment(blk, nil, slot, argVal)
        let coArrAddr = gcc_jit_context_new_cast(ctx, nil,
          gcc_jit_lvalue_get_address(coArrL, nil), i64PtrType)
        let constrObjParamTypesArr = [int32Type, i64PtrType]
        let constrObjFnType = gcc_jit_context_new_function_ptr_type(ctx, nil, i64Type, 2, addr constrObjParamTypesArr[0], 0)
        let constrObjAddr = gcc_jit_context_new_rvalue_from_ptr(ctx, voidPtrType, jitBridgeConstrObj)
        let constrObjFnRval = gcc_jit_context_new_cast(ctx, nil, constrObjAddr, constrObjFnType)
        var constrObjArgs: array[2, ptr gcc_jit_rvalue] = [
          gcc_jit_context_new_rvalue_from_long(ctx, int32Type, coCount.int32),
          coArrAddr
        ]
        let constrObjResult = callThroughPtr(ctx, nil, constrObjFnRval, 2.cint, addr constrObjArgs[0])
        pushInt(stackI, constrObjResult, spRval)
        term()
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
        if args[i].typeId == tyInt:
          flatLocals[i] = args[i].intVal
        else:
          flatLocals[i] = cast[int64](args[i])
      if localMaxLocal == 0 and argc > 0:
        flatLocals[0] = args[0].intVal
      type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
      let resultI = cast[JitFn](localFn)(addr flatLocals[0], argc)
      when defined(vancodeJitLog):
        stderr.writeLine "[jit-wrapper] flatLocals[0]=" & $flatLocals[0]
      theProc.jitCallCount += 1
      if theProc.jitCallCount >= hotRecompileThreshold:
        jitRecompileAtO3(theProc)
      for i in 0..<min(argc, localMaxLocal):
        if args[i].typeId == tyInt:
          args[i].intVal = flatLocals[i]
      if theProc.jitReturnString:
        result = cast[Value](resultI)
      elif theProc.jitReturnBool:
        result = Value(typeId: tyBool, boolVal: resultI != 0)
      else:
        result = initValue(resultI)

else:
  proc compileProc*(vm: Vm, theProc: Proc): ForeignProc {.inline.} =
    return nil
