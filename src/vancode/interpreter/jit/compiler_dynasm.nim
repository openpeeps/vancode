# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## DynASM-based JIT compiler for VanCode. Compiles individual procedures that
## use a restricted subset of opcodes (arithmetic, locals, jumps, calls) into
## native machine code via the DynASM assembler. Falls back to the interpreter
## for unsupported opcodes.
import std/[tables, sysatomics, critbits, os]
import pkg/voodoo/extensibles

import ./compiler_bridge, ./jit_mem, ./host_emit
import ./dynasm/wrapper
import ../[vm, value, chunk]

const DASM_MAXSECTION = 1

proc jitDynasmSupported*(oc: Opcode): bool =
  ## Allowlist for the DynASM proc compiler. Hosts (e.g. bowdy) admit their own
  ## opcodes via `extendCaseStmt "vmJitDynasmAllowCase"`. Anything rejected
  ## here falls back to the interpreter — never a compile error.
  extendableCase "vmJitDynasmAllowCase":
    case oc
    of opcPushI, opcPushTrue, opcPushFalse,
       opcPushL, opcPopL, opcIncL, opcDecL, opcPushNil,
       opcAddI, opcSubI, opcMultI, opcDivI, opcNegI,
       opcEqI, opcLessI, opcGreaterI,
       opcInvB, opcDiscard,
       opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack,
       opcReturnVal, opcReturnVoid, opcHalt,
       opcNoop, opcCallD:
      result = true
    else:
      result = false

proc compileProc*(vm: Vm, theProc: Proc, isMain = false): ForeignProc =
  if theProc.kind != pkNative or theProc.chunk == nil: return nil
  let cached = vm.getCachedOps(theProc.chunk)
  let opCount = cached.opcodes.len
  if opCount == 0: return nil
  let jtTargets = cached.jumpTargets

  for oc in cached.opcodes:
    if not jitDynasmSupported(oc): return nil

  var d: ptr dasm_State = nil
  dasm_init(addr d, DASM_MAXSECTION)

  var globals: array[64, pointer]
  dasm_setupglobal(addr d, addr globals[0], 64)
  dasm_setup(addr d, get_vancode_actions())

  var labelForTarget = initTable[int, int]()
  var nextLabel = 0
  for pc in 0..<opCount:
    let oc = cached.opcodes[pc]
    if oc in {opcJumpFwd, opcJumpBack, opcJumpFwdF, opcJumpFwdT}:
      let target = jtTargets[pc]
      if target >= 0 and target < opCount and target notin labelForTarget:
        labelForTarget[target] = nextLabel
        inc nextLabel

  if nextLabel > 0:
    dasm_growpc(addr d, nextLabel.cuint)

  # Pre-allocate code buffer for self-recursion fast path, reusing the
  # spare retained by the previous generation's reset when one survived.
  const maxCodeSize = 128 * 1024
  static: assert maxCodeSize == jitCodeBufReuseSize
  var preAllocBuf = jitTakeSpareCodeBuf(maxCodeSize)
  if preAllocBuf == nil:
    preAllocBuf = allocJitCode(maxCodeSize)

  vancode_prologue(addr d)

  for i in 0..<theProc.paramCount:
    vancode_load_param(addr d, i.cint)

  for pc in 0..<opCount:
    let oc = cached.opcodes[pc]

    if pc in labelForTarget:
      vancode_define_label(addr d, labelForTarget[pc].cint)

    extendableCase "vmJitDynasmEmitCase":
      case oc
      of opcPushI:
        vancode_push_i(addr d, cached.getArg1Int(pc).cint)
      of opcPushTrue:
        vancode_push_true(addr d)
      of opcPushFalse:
        vancode_push_false(addr d)
      of opcPushNil:
        vancode_push_nil(addr d)
      of opcPushL:
        vancode_push_l(addr d, cached.getArg1Int(pc).cint)
      of opcPopL:
        vancode_pop_l(addr d, cached.getArg1Int(pc).cint)
      of opcIncL:
        vancode_inc_l(addr d, cached.getArg1Int(pc).cint)
      of opcDecL:
        vancode_dec_l(addr d, cached.getArg1Int(pc).cint)
      of opcAddI:
        vancode_add_i(addr d)
      of opcSubI:
        vancode_sub_i(addr d)
      of opcMultI:
        vancode_mul_i(addr d)
      of opcDivI:
        vancode_div_i(addr d)
      of opcNegI:
        vancode_neg_i(addr d)
      of opcEqI:
        vancode_eq_i(addr d)
      of opcLessI:
        vancode_less_i(addr d)
      of opcGreaterI:
        vancode_greater_i(addr d)
      of opcInvB:
        vancode_inv_b(addr d)
      of opcDiscard:
        vancode_discard(addr d, cached.getArg1Int(pc).cint)
      of opcJumpFwd:
        vancode_jump_fwd(addr d, labelForTarget.getOrDefault(jtTargets[pc], 0).cint)
      of opcJumpBack:
        vancode_jump_back(addr d, labelForTarget.getOrDefault(jtTargets[pc], 0).cint)
      of opcJumpFwdF:
        vancode_jump_fwd_f(addr d, labelForTarget.getOrDefault(jtTargets[pc], 0).cint)
      of opcJumpFwdT:
        vancode_jump_fwd_t(addr d, labelForTarget.getOrDefault(jtTargets[pc], 0).cint)
      of opcReturnVal:
        vancode_return_val(addr d)
      of opcReturnVoid, opcHalt:
        vancode_return_void(addr d)
      of opcNoop:
        discard
      of opcCallD:
        let targetProcId = cached.arg2[pc].int
        var nArgs = 0
        if targetProcId == theProc.procId:
          nArgs = theProc.paramCount
          if preAllocBuf != nil and nArgs > 0:
            emitCallArgs(addr d, nArgs)
            vancode_call_self(addr d, nArgs.cint, preAllocBuf)
            vancode_call_finish(addr d, (2 * nArgs * 8).cint)
          elif nArgs > 0:
            emitCallArgs(addr d, nArgs)
            vancode_call_invoke(addr d, nArgs.cint, targetProcId.cint,
              cast[pointer](jitCallProcBridgeFlat))
            vancode_call_finish(addr d, (2 * nArgs * 8).cint)
          else:
            vancode_call_alloc(addr d, 0)
            vancode_call_invoke(addr d, 0, targetProcId.cint,
              cast[pointer](jitCallProcBridgeFlat))
            vancode_call_finish(addr d, 0)
        else:
          var tp: Proc = nil
          let fpIdx = cached.arg1[pc].uint16
          let cpStr = theProc.chunk.strings[fpIdx]
          if cpStr in vm.importedModules:
            let s2 = vm.importedModules[cpStr]
            if targetProcId >= 0 and targetProcId < s2.procs.len:
              tp = s2.procs[targetProcId]
          if tp == nil:
            for _, s2 in vm.importedModules:
              if targetProcId >= 0 and targetProcId < s2.procs.len:
                tp = s2.procs[targetProcId]; break
          if tp != nil:
            nArgs = tp.paramCount
          # Host-registered fast path (e.g. bowdy builtins): same invoke
          # sequence, alternate bridge. Misses keep the generic bridge.
          var bridgeFn = cast[pointer](jitCallProcBridgeFlat)
          if tp != nil:
            let fastFn = findJitForeignFast(tp.name, nArgs)
            if fastFn != nil: bridgeFn = fastFn
          if nArgs > 0:
            emitCallArgs(addr d, nArgs)
            vancode_call_invoke(addr d, nArgs.cint, targetProcId.cint, bridgeFn)
            vancode_call_finish(addr d, (2 * nArgs * 8).cint)
          else:
            vancode_call_alloc(addr d, 0)
            vancode_call_invoke(addr d, 0, targetProcId.cint, bridgeFn)
            vancode_call_finish(addr d, 0)
      else:
        discard

  var sz: csize_t
  let linkErr = dasm_link(addr d, addr sz)
  if linkErr != 0 or sz == 0:
    freeJitCode(preAllocBuf, maxCodeSize)
    dasm_free(addr d)
    return nil

  let usePreAlloc = sz <= maxCodeSize
  let buf = if usePreAlloc: preAllocBuf else: allocJitCode(sz.int)
  if buf == nil:
    freeJitCode(preAllocBuf, maxCodeSize)
    dasm_free(addr d)
    return nil

  let encodeErr = dasm_encode(addr d, buf)
  if encodeErr != 0:
    if not usePreAlloc: freeJitCode(buf, sz.int)
    else: freeJitCode(preAllocBuf, maxCodeSize)
    dasm_free(addr d)
    return nil

  let fnPtr = buf
  if not usePreAlloc:
    # Encoded into the overflow buffer; release the unused pre-alloc.
    freeJitCode(preAllocBuf, maxCodeSize)
    jitTrackCodeBuf(fnPtr, sz.int)
  else:
    jitTrackCodeBuf(fnPtr, maxCodeSize)
  dasm_free(addr d)

  var maxLocal = theProc.paramCount
  for pc in 0..<opCount:
    let oc = cached.opcodes[pc]
    if oc == opcPushL or oc == opcPopL:
      let idx = cached.getArg1Int(pc)
      if idx >= maxLocal: maxLocal = idx + 1

  theProc.jitMaxLocal = maxLocal
  atomicStoreN(addr theProc.jitCodePtr, fnPtr, AtomicRelease)
  if theProc.procId >= 0:
    # Synthetic mains (procId -1) skip the process-global tables: they run
    # once via their own closure, never through procId-keyed bridges.
    jitFnTable[theProc.procId] = fnPtr
    jitProcTable[theProc.procId] = cast[pointer](theProc)
    jitParamCount[theProc.procId] = theProc.paramCount

  # Capture raw pointers, not refs: this closure is stored back into the
  # proc (`p.jitForeign`) and reachable from the VM, so capturing refs
  # would close a cycle ARC never collects (`Vm`/`Proc` are `{.acyclic.}`),
  # leaking the whole VM per generation. Lifetimes still match: the
  # closure dies with its owning proc, the buffer with `resetJitState`.
  let theProcPtr = cast[pointer](theProc)
  let vmPtr = cast[pointer](vm)
  result = proc (args: StackView, argc: int): Value {.closure.} =
    let tp = cast[Proc](theProcPtr)
    let localFn = atomicLoadN(addr tp.jitCodePtr, AtomicAcquire)
    if localFn == nil:
      return Value(typeId: tyNil)
    let localMaxLocal = tp.jitMaxLocal
    var flatLocals = newSeq[int64](max(localMaxLocal, 1))
    for i in 0..<min(argc, localMaxLocal):
      # Native-stack convention: raw int64 for ints/bools, tagged ring
      # index for everything else (raw pointers are GC-invisible).
      if args[i].typeId == tyInt:
        flatLocals[i] = args[i].intVal
      elif args[i].typeId == tyBool:
        flatLocals[i] = args[i].boolVal.ord.int64
      else:
        flatLocals[i] = jitRootValue(args[i])
    if localMaxLocal == 0 and argc > 0:
      flatLocals[0] = args[0].intVal
    type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
    let resultI = cast[JitFn](localFn)(addr flatLocals[0], argc)
    for i in 0..<min(argc, localMaxLocal):
      if args[i].typeId == tyInt:
        args[i].intVal = flatLocals[i]
    if isMain:
      let vx = cast[Vm](vmPtr)
      if vx.jit.getOutput != nil:
        # Main chunks report through the host output buffer (the native
        # Halt returns 0); interpret()-equivalent result comes from there.
        return vx.jit.getOutput(vmPtr)
    if tp.jitReturnString or tp.jitReturnRef:
      # Non-int/bool results travel as tagged ring indices (bridges root
      # them); resolve back to the Value for the interpreted caller.
      result = jitUnrootValue(resultI)
    elif tp.jitReturnBool:
      result = Value(typeId: tyBool, boolVal: resultI != 0)
    else:
      result = initValue(resultI)
