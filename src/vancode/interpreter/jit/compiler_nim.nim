# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Pure-Nim JIT compilers (method-at-a-time, traces, fib fast path).
## Mirrors compiler_dynasm.nim / compiler_trace.nim emission logic on the
## emit_nim session; only compiled under `-d:vancodeJitNim`. The Lua
## DynASM backend stays untouched until parity is proven (then deleted).
import std/[tables, sysatomics]
import pkg/voodoo/extensibles
import dynasm

import ./compiler_bridge, ./emit_nim, ./host_emit
import ./trace_types, ./trace_cache, ./compiler_trace
import ../[vm, value, chunk]

proc jitNimSupported*(oc: Opcode): bool =
  ## Allowlist for the pure-Nim proc compiler: the same opcode set the
  ## Lua backend accepts, so accept/reject decisions stay identical.
  ## Hosts admit their own opcodes via
  ## `extendCaseStmt "vmJitNimAllowCase"` (separate anchor: injected
  ## bodies run against the Nim session, not `dasm_State`).
  extendableCase "vmJitNimAllowCase":
    case oc
    of opcPushI, opcPushTrue, opcPushFalse,
       opcPushL, opcPopL, opcIncL, opcDecL, opcPushNil,
       opcAddI, opcSubI, opcMultI, opcDivI, opcModI, opcNegI,
       opcEqI, opcLessI, opcGreaterI,
       opcInvB, opcDiscard,
       opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack,
       opcReturnVal, opcReturnVoid, opcHalt,
       opcNoop, opcCallD:
      result = true
    else:
      result = false

proc publishNimCode(theProc: Proc, codeBuf: ExecutableBuffer,
    opcodes: seq[Opcode], cached: CachedOps, opCount: int,
    vm: Vm, isMain: bool): ForeignProc =
  ## Publish a finished buffer: track it, expose the entry point,
  ## and build the interpreter-facing closure (backend-agnostic,
  ## identical contract to the Lua backend's closure).
  let fnPtr = codeBuf.mem
  jitTrackCodeBuf(fnPtr, codeBuf.length)
  jitTrackNimBuf(codeBuf)

  var maxLocal = theProc.paramCount
  for pc in 0 ..< opCount:
    let oc = opcodes[pc]
    if oc == opcPushL or oc == opcPopL or oc == opcIncL or oc == opcDecL:
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
    # Hot tiny procs (1-2 int args) must not heap-alloc per call: a stack
    # buffer covers them, larger frames fall back to a seq. This closure
    # runs once per interpreted->native call, so the alloc used to cost
    # ~5-10% of every bridged call.
    const jitSmallFrame = 8
    let needLocals = max(localMaxLocal, 1)
    if needLocals <= jitSmallFrame:
      var smallBuf: array[jitSmallFrame, int64]
      for i in 0 ..< min(argc, localMaxLocal):
        # Native-stack convention: raw int64 for ints/bools, tagged ring
        # index for everything else (raw pointers are GC-invisible).
        if args[i].typeId == tyInt:
          smallBuf[i] = args[i].intVal
        elif args[i].typeId == tyBool:
          smallBuf[i] = args[i].boolVal.ord.int64
        else:
          smallBuf[i] = jitRootValue(args[i])
      if localMaxLocal == 0 and argc > 0:
        smallBuf[0] = args[0].intVal
      type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
      let resultI = cast[JitFn](localFn)(addr smallBuf[0], argc)
      for i in 0 ..< min(argc, localMaxLocal):
        if args[i].typeId == tyInt:
          args[i].intVal = smallBuf[i]
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
      return
    var flatLocals = newSeq[int64](needLocals)
    for i in 0 ..< min(argc, localMaxLocal):
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
    for i in 0 ..< min(argc, localMaxLocal):
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

proc patchSelfCalls(codeBuf: var ExecutableBuffer, holes: seq[int]) =
  ## Back-patch self-call address holes once the final base is known.
  if holes.len == 0: return
  makeWritable(codeBuf.mem, codeBuf.mappedSize)
  for h in holes:
    ncallSelfPatch(codeBuf.mem, h, codeBuf.mem)
  makeExecutable(codeBuf.mem, codeBuf.mappedSize, codeBuf.length)

proc resolveCallTarget(vm: Vm, theProc: Proc, cached: CachedOps,
    pc: int, targetProcId: int): tuple[tp: Proc, nArgs: int,
    hasResult: bool, bridgeFn: pointer] =
  ## Shared CallD callee lookup for method and trace compilers.
  result = (nil, 0, true, cast[pointer](jitCallProcBridgeFlat))
  if targetProcId == theProc.procId:
    result.nArgs = theProc.paramCount
    result.hasResult = theProc.hasResult
    return
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
    result.tp = tp
    result.nArgs = tp.paramCount
    result.hasResult = tp.hasResult
    let fastFn = findJitForeignFast(tp.name, result.nArgs)
    if fastFn != nil: result.bridgeFn = fastFn

proc resolveCallTargetTrace(vm: Vm, trace: TraceBuffer, cached: CachedOps,
    pc: int, targetProcId: int): tuple[tp: Proc, nArgs: int,
    hasResult: bool, bridgeFn: pointer] =
  ## Trace-flavored callee lookup: the chunk comes from the trace,
  ## not a compiling proc.
  result = (nil, 0, true, cast[pointer](jitCallProcBridgeFlat))
  var tp: Proc = nil
  let ch = cast[Chunk](trace.chunk)
  let fpIdx = cached.arg1[pc].uint16
  if ch != nil and fpIdx.int < ch.strings.len:
    let cpStr = ch.strings[fpIdx]
    if cpStr in vm.importedModules:
      let s2 = vm.importedModules[cpStr]
      if targetProcId >= 0 and targetProcId < s2.procs.len:
        tp = s2.procs[targetProcId]
  if tp == nil:
    for _, s2 in vm.importedModules:
      if targetProcId >= 0 and targetProcId < s2.procs.len:
        tp = s2.procs[targetProcId]; break
  if tp != nil:
    result.tp = tp
    result.nArgs = tp.paramCount
    result.hasResult = tp.hasResult
    let fastFn = findJitForeignFast(tp.name, result.nArgs)
    if fastFn != nil: result.bridgeFn = fastFn

proc compileProcNim*(vm: Vm, theProc: Proc,
    isMain = false): ForeignProc =
  if theProc.kind != pkNative or theProc.chunk == nil: return nil
  let cached = vm.getCachedOps(theProc.chunk)
  let opCount = cached.opcodes.len
  if opCount == 0: return nil
  let jtTargets = cached.jumpTargets

  for oc in cached.opcodes:
    if not jitNimSupported(oc): return nil

  var jit = initNimJit()
  var selfHoles: seq[int] = @[]
  try:
    var labelForTarget = initTable[int, int]()
    var nextLabel = 0
    for pc in 0 ..< opCount:
      let oc = cached.opcodes[pc]
      if oc in {opcJumpFwd, opcJumpBack, opcJumpFwdF, opcJumpFwdT}:
        let target = jtTargets[pc]
        if target >= 0 and target < opCount and target notin labelForTarget:
          labelForTarget[target] = nextLabel
          inc nextLabel

    nprologue(jit.a)

    # Static operand-stack depth. Mirrors the interpreter's safe Discard
    # (`if stack.len >= n`), which is a no-op on underflow. Codegen emits
    # statement-cleanup `Discard 1` after assignments (e.g. `result = i` ->
    # PushL/PopL/Discard) where the stack is already empty. Emitting those
    # unconditionally (`add rsp,n*8`) corrupts the native stack and crashes
    # on `ret`. Skip no-op discards instead.
    var stackDepth = 0

    for pc in 0 ..< opCount:
      let oc = cached.opcodes[pc]

      if pc in labelForTarget:
        ndefLabel(jit.a, labelForTarget[pc])

      extendableCase "vmJitNimEmitCase":
        case oc
        of opcPushI:
          npushI(jit.a, cached.getArg1Int(pc).int)
          inc stackDepth
        of opcPushTrue:
          npushTrue(jit.a)
          inc stackDepth
        of opcPushFalse:
          npushFalse(jit.a)
          inc stackDepth
        of opcPushNil:
          npushNil(jit.a)
          inc stackDepth
        of opcPushL:
          npushL(jit.a, cached.getArg1Int(pc).int)
          inc stackDepth
        of opcPopL:
          npopL(jit.a, cached.getArg1Int(pc).int)
          dec stackDepth
        of opcIncL:
          nincL(jit.a, cached.getArg1Int(pc).int)
        of opcDecL:
          ndecL(jit.a, cached.getArg1Int(pc).int)
        of opcAddI:
          naddI(jit.a)
          dec stackDepth
        of opcSubI:
          nsubI(jit.a)
          dec stackDepth
        of opcMultI:
          nmulI(jit.a)
          dec stackDepth
        of opcDivI:
          ndivI(jit.a)
          dec stackDepth
        of opcModI:
          nmodI(jit.a)
          dec stackDepth
        of opcNegI:
          nnegI(jit.a)
        of opcEqI:
          neqI(jit.a)
          dec stackDepth
        of opcLessI:
          nlessI(jit.a)
          dec stackDepth
        of opcGreaterI:
          ngreaterI(jit.a)
          dec stackDepth
        of opcInvB:
          ninvB(jit.a)
        of opcDiscard:
          let n = cached.getArg1Int(pc).int
          if pc in labelForTarget:
            # Jump target: condition already popped by jump_fwd_f/t. The
            # interpreter's trailing Discard would pop it, but native already
            # did. Skip to keep stack balanced. Depth already accounts for
            # the pop at the jump, so no change here.
            discard
          elif stackDepth >= n and n > 0:
            ndiscard(jit.a, n)
            stackDepth -= n
          else:
            # No-op in interpreter (`if stack.len >= n`), skip to avoid
            # corrupting saved regs / return address.
            discard
        of opcJumpFwd:
          njumpFwd(jit.a, labelForTarget.getOrDefault(jtTargets[pc], 0))
        of opcJumpBack:
          njumpBack(jit.a, labelForTarget.getOrDefault(jtTargets[pc], 0))
        of opcJumpFwdF:
          njumpFwdF(jit.a, labelForTarget.getOrDefault(jtTargets[pc], 0))
          # Fall-through keeps depth (pop then push back, Discard pops next).
          # Jump path pops (no push back) and lands on a skipped Discard.
          # Linear tracking follows fall-through, so no change here.
          discard
        of opcJumpFwdT:
          njumpFwdT(jit.a, labelForTarget.getOrDefault(jtTargets[pc], 0))
          discard
        of opcReturnVal:
          nreturnVal(jit.a)
          dec stackDepth
        of opcReturnVoid, opcHalt:
          nreturnVoid(jit.a)
        of opcNoop:
          discard
        of opcCallD:
          let targetProcId = cached.arg2[pc].int
          let callee = resolveCallTarget(vm, theProc, cached, pc,
            targetProcId)
          if targetProcId == theProc.procId:
            # Direct self-recursion: the buffer address is only final
            # after finalize, so emit a hole and back-patch below.
            if callee.nArgs > 0:
              emitCallArgsNim(jit.a, callee.nArgs)
              selfHoles.add(ncallSelfHole(jit.a, callee.nArgs))
              ncallFinish(jit.a, jitCallDropBytes(callee.nArgs))
            else:
              selfHoles.add(ncallSelfHole(jit.a, 0))
              ncallFinish(jit.a, 0)
          elif callee.nArgs > 0:
            emitCallArgsNim(jit.a, callee.nArgs)
            ncallInvoke(jit.a, callee.nArgs, targetProcId,
              callee.bridgeFn)
            ncallFinish(jit.a, jitCallDropBytes(callee.nArgs))
          else:
            ncallAlloc(jit.a, 0)
            ncallInvoke(jit.a, 0, targetProcId, callee.bridgeFn)
            ncallFinish(jit.a, 0)
          # Native call sequence consumes args and pushes result (if any).
          stackDepth -= callee.nArgs
          if callee.hasResult:
            inc stackDepth
        else:
          discard

    var codeBuf = nimJitFinish(jit)
    if codeBuf.length == 0:
      codeBuf.destroy()
      return nil
    patchSelfCalls(codeBuf, selfHoles)
    result = publishNimCode(theProc, codeBuf, cached.opcodes, cached,
      opCount, vm, isMain)
  except DynasmError as e:
    when defined(vancodeJitLog):
      stderr.writeLine "[jit-nim] proc compile failed: ", theProc.name,
        ": ", e.msg
    jit.a.execBuf.destroy()
    return nil

proc compileRecursiveIterativeNim*(cached: CachedOps): pointer =
  var jit = initNimJit()
  try:
    nfib(jit.a)
    var codeBuf = nimJitFinish(jit)
    if codeBuf.length == 0:
      codeBuf.destroy()
      return nil
    jitTrackCodeBuf(codeBuf.mem, codeBuf.length)
    jitTrackNimBuf(codeBuf)
    result = codeBuf.mem
  except DynasmError as e:
    when defined(vancodeJitLog):
      stderr.writeLine "[jit-nim] fib compile failed: ", e.msg
    jit.a.execBuf.destroy()
    return nil

proc compileTraceNim*(vm: Vm, trace: TraceBuffer): pointer =
  let cached = cast[CachedOps](trace.cached)
  let opCount = trace.pcs.len
  trace.failKind = tfNone
  if opCount == 0:
    trace.failKind = tfShape
    return nil

  if hasBinaryRecursiveArith(cached):
    let fibCode = compileRecursiveIterativeNim(cached)
    if fibCode != nil:
      return fibCode

  var labelForTarget = initTable[int, int]()
  var nextLabel = 2
  let jtTargets = cached.jumpTargets

  for pc in trace.pcs:
    let oc = cached.opcodes[pc]
    if oc in {opcJumpFwd, opcJumpFwdF, opcJumpFwdT}:
      let target = jtTargets[pc]
      if target >= 0 and target in trace.pcs and target notin labelForTarget:
        labelForTarget[target] = nextLabel
        inc nextLabel
    elif oc == opcJumpBack and trace.anchorPc >= 0:
      let target = jtTargets[pc]
      if target >= 0 and target in trace.pcs and target notin labelForTarget:
        labelForTarget[target] = nextLabel
        inc nextLabel

  var numJBack = 0
  for p in trace.pcs:
    if cached.opcodes[p] == opcJumpBack: inc numJBack
  if numJBack > 1:
    trace.failKind = tfShape
    return nil

  # Reject traces where a conditional forward jump has its target inside the
  # recorded Pc range but the Pc immediately after the jump (the discard that
  # cleans up the pushed-back condition on the true path) is NOT in the trace.
  let minPc = trace.pcs[0]
  let maxPc = trace.pcs[^1]
  block checkForwardJumps:
    for pc in trace.pcs:
      let oc = cached.opcodes[pc]
      if oc in {opcJumpFwdF, opcJumpFwdT}:
        let tgt = jtTargets[pc]
        if tgt >= minPc and tgt <= maxPc:
          block targetCheck:
            for tp in trace.pcs:
              if tp == tgt: break targetCheck
            trace.failKind = tfShape
            return nil
          block nextPcCheck:
            for tp in trace.pcs:
              if tp == pc + 1: break nextPcCheck
            trace.failKind = tfShape
            return nil

  var jit = initNimJit()
  var selfHoles: seq[int] = @[]
  try:
    nprologue(jit.a)
    ndefLabel(jit.a, 0)

    var definedLabels: seq[int] = @[]
    for pc in trace.pcs:
      let oc = cached.opcodes[pc]

      if pc in labelForTarget and labelForTarget[pc] notin definedLabels:
        definedLabels.add(labelForTarget[pc])
        ndefLabel(jit.a, labelForTarget[pc])

      extendableCase "vmJitNimTraceEmitCase":
        case oc
        of opcPushI:
          npushI(jit.a, cached.getArg1Int(pc).int)
        of opcPushTrue:
          npushTrue(jit.a)
        of opcPushFalse:
          npushFalse(jit.a)
        of opcPushNil:
          npushNil(jit.a)
        of opcPushL:
          npushL(jit.a, cached.getArg1Int(pc).int)
        of opcPopL:
          npopL(jit.a, cached.getArg1Int(pc).int)
        of opcIncL:
          nincL(jit.a, cached.getArg1Int(pc).int)
        of opcDecL:
          ndecL(jit.a, cached.getArg1Int(pc).int)
        of opcAddI:
          naddI(jit.a)
        of opcSubI:
          nsubI(jit.a)
        of opcMultI:
          nmulI(jit.a)
        of opcDivI:
          ndivI(jit.a)
        of opcModI:
          nmodI(jit.a)
        of opcNegI:
          nnegI(jit.a)
        of opcEqI:
          neqI(jit.a)
        of opcLessI:
          nlessI(jit.a)
        of opcGreaterI:
          ngreaterI(jit.a)
        of opcInvB:
          ninvB(jit.a)
        of opcDiscard:
          if pc in labelForTarget:
            discard  # this discard is the target of a forward jump — the
                     # jump_fwd_f already popped the condition natively
          else:
            ndiscard(jit.a, cached.getArg1Int(pc).int)
        of opcPushG, opcPopG:
          discard
        of opcJumpFwd:
          let tgt = jtTargets[pc]
          if tgt >= 0 and tgt in labelForTarget:
            njumpFwd(jit.a, labelForTarget[tgt])
          else:
            discard
        of opcJumpFwdF:
          let tgt = jtTargets[pc]
          if tgt >= 0 and tgt in labelForTarget:
            njumpFwdF(jit.a, labelForTarget[tgt])
          else:
            njumpFwdF(jit.a, 1)
        of opcJumpFwdT:
          let tgt = jtTargets[pc]
          if tgt >= 0 and tgt in labelForTarget:
            njumpFwdT(jit.a, labelForTarget[tgt])
          else:
            njumpFwdT(jit.a, 1)
        of opcJumpBack:
          let tgt = jtTargets[pc]
          if tgt >= 0 and tgt in labelForTarget:
            njumpBack(jit.a, labelForTarget[tgt])
          else:
            njumpBack(jit.a, 0)
        of opcCallD:
          let targetProc = cached.arg2[pc].int
          if targetProc == trace.selfProcId:
            if trace.selfParamCount > 0:
              emitCallArgsNim(jit.a, trace.selfParamCount)
              selfHoles.add(ncallSelfHole(jit.a, trace.selfParamCount))
              ncallFinish(jit.a,
                jitCallDropBytes(trace.selfParamCount))
            else:
              selfHoles.add(ncallSelfHole(jit.a, 0))
              ncallFinish(jit.a, 0)
          else:
            # Cross-proc call inside a hot loop: same bridge sequence the
            # method compiler uses. The bridge resolves the callee per call
            # and goes direct once the target itself is compiled.
            let callee = resolveCallTargetTrace(vm, trace, cached, pc,
              targetProc)
            if callee.tp == nil:
              trace.failKind = tfOpcode
              jit.a.execBuf.destroy()
              return nil
            if callee.nArgs > 0:
              emitCallArgsNim(jit.a, callee.nArgs)
              ncallInvoke(jit.a, callee.nArgs, targetProc,
                callee.bridgeFn)
              ncallFinish(jit.a, jitCallDropBytes(callee.nArgs))
            else:
              ncallAlloc(jit.a, 0)
              ncallInvoke(jit.a, 0, targetProc, callee.bridgeFn)
              ncallFinish(jit.a, 0)
        of opcReturnVal:
          nreturnVal(jit.a)
        of opcReturnVoid, opcHalt:
          nreturnVoid(jit.a)
        of opcNoop:
          discard
        else:
          trace.failKind = tfOpcode
          jit.a.execBuf.destroy()
          return nil
        discard

    ndefLabel(jit.a, 1)
    ntraceExit(jit.a)

    var codeBuf = nimJitFinish(jit)
    if codeBuf.length == 0:
      trace.failKind = tfResource
      codeBuf.destroy()
      return nil
    patchSelfCalls(codeBuf, selfHoles)
    jitTrackCodeBuf(codeBuf.mem, codeBuf.length)
    jitTrackNimBuf(codeBuf)
    result = codeBuf.mem
  except DynasmError as e:
    trace.failKind = tfResource
    when defined(vancodeJitLog):
      stderr.writeLine "[jit-nim] trace compile failed: ", e.msg
    jit.a.execBuf.destroy()
    return nil
