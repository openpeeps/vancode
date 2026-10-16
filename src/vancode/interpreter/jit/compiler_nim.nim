# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Pure-Nim JIT compilers (method-at-a-time, traces, fib fast path)
## on emit_nim sessions.
import std/[tables, sysatomics]
import pkg/voodoo/extensibles
import dynasm

import ./compiler_bridge, ./emit_nim, ./host_emit
import ./trace_types, ./trace_cache
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
       opcPushG, opcPopG,
       opcAddI, opcSubI, opcMultI, opcDivI, opcModI, opcNegI,
       opcEqI, opcLessI, opcGreaterI,
       opcInvB, opcDiscard,
       opcGetI, opcSetI,
       opcJumpFwd, opcJumpFwdF, opcJumpFwdT, opcJumpBack,
       opcReturnVal, opcReturnVoid, opcHalt,
       opcNoop, opcCallD:
      result = true
    else:
      result = false

type SlotKind = enum
  ## Abstract type of one native-stack slot, tracked by both JIT compilers
  ## over the linear op stream. Decides inline-vs-bridge lowering (SetI
  ## value stores, `CallD` arg boxes) so guards stay sound: ints/bools are
  ## exact, everything else takes the slow bridge with full semantics.
  ## NOTE: a raw slot is ambiguous (int and bool share the encoding), so
  ## `skUnknown` holding a bool boxes as `tyInt` on slow paths — the same
  ## convention as the untyped `CallD` bridge (`jitUnpackArg`).
  skInt
  skBool
  skFloat
  skRef
  skUnknown

proc kindToTypeId*(k: SlotKind): int32 =
  ## Box tag baked per `CallD` arg / slow-bridge slot (`tyAny` = unpack).
  case k
  of skInt: tyInt.int32
  of skBool: tyBool.int32
  of skFloat: tyFloat.int32
  else: tyAny.int32

proc kindFromTypeId*(t: int32): SlotKind =
  ## Inverse for inlined call args (conservative: anything exotic is
  ## unknown; slow paths stay sound through resolve-first).
  case t
  of tyInt.int32: skInt
  of tyBool.int32: skBool
  of tyFloat.int32: skFloat
  else: skUnknown

proc procResultKind*(tp: Proc): SlotKind =
  ## Abstract result type from the callee's static return flags
  ## (set by codegen). All-false = int, matching the JIT closures.
  if tp == nil: return skUnknown
  if tp.jitReturnBool: skBool
  elif tp.jitReturnString or tp.jitReturnRef: skRef
  else: skInt

proc tpush*(s: var seq[SlotKind], k: SlotKind) {.inline.} =
  s.add(k)

proc tpop*(s: var seq[SlotKind]): SlotKind {.inline.} =
  if s.len == 0: return skUnknown
  result = s.pop()

proc tpopN*(s: var seq[SlotKind], n: int) {.inline.} =
  for _ in 0 ..< min(n, s.len): discard s.pop()

proc localKind*(locals: var seq[SlotKind], idx: int): SlotKind {.inline.} =
  while locals.len <= idx: locals.add(skUnknown)
  result = locals[idx]

const maxInlineOps* = 24
  ## Largest callee body eligible for inline expansion: small enough to
  ## keep code growth negligible, large enough for tiny predicates.

const inlineLeafOps* = {opcPushI, opcPushTrue, opcPushFalse, opcPushNil,
  opcPushL, opcPopL, opcIncL, opcDecL, opcPushG, opcPopG,
  opcAddI, opcSubI, opcMultI, opcDivI, opcModI, opcNegI,
  opcEqI, opcLessI, opcGreaterI, opcInvB, opcDiscard, opcNoop}
  ## Ops allowed inside an inlined body: pure stack/local/global effects.
  ## No jumps (caller label space), no calls (single-level only), no
  ## item/field access (their pc-suffixed slow labels would collide).

proc maxLocalFor*(cached: CachedOps, paramCount: int): int =
  ## Highest local slot index + 1 over the op stream (frame width).
  result = paramCount
  for pc in 0 ..< cached.opcodes.len:
    let oc = cached.opcodes[pc]
    if oc == opcPushL or oc == opcPopL or oc == opcIncL or oc == opcDecL:
      let idx = cached.getArg1Int(pc)
      if idx + 1 > result: result = idx + 1

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
    var typeStack: seq[SlotKind] = @[]
    var localTypes: seq[SlotKind] = @[]
    let callerMaxLocal = maxLocalFor(cached, theProc.paramCount)
    var inlineHigh = callerMaxLocal

    for pc in 0 ..< opCount:
      let oc = cached.opcodes[pc]

      if pc in labelForTarget:
        ndefLabel(jit.a, labelForTarget[pc])

      extendableCase "vmJitNimEmitCase":
        case oc
        of opcPushI:
          npushI(jit.a, cached.getArg1Int(pc).int)
          inc stackDepth
          typeStack.tpush(skInt)
        of opcPushTrue:
          npushTrue(jit.a)
          inc stackDepth
          typeStack.tpush(skBool)
        of opcPushFalse:
          npushFalse(jit.a)
          inc stackDepth
          typeStack.tpush(skBool)
        of opcPushNil:
          npushNil(jit.a)
          inc stackDepth
          typeStack.tpush(skRef)
        of opcPushL:
          let pushIdx = cached.getArg1Int(pc).int
          npushL(jit.a, pushIdx)
          inc stackDepth
          typeStack.tpush(localTypes.localKind(pushIdx))
        of opcPopL:
          let popIdx = cached.getArg1Int(pc).int
          npopL(jit.a, popIdx)
          dec stackDepth
          while localTypes.len <= popIdx: localTypes.add(skUnknown)
          localTypes[popIdx] = typeStack.tpop()
        of opcIncL:
          let incIdx = cached.getArg1Int(pc).int
          nincL(jit.a, incIdx)
          while localTypes.len <= incIdx: localTypes.add(skUnknown)
          localTypes[incIdx] = skInt
        of opcDecL:
          let decIdx = cached.getArg1Int(pc).int
          ndecL(jit.a, decIdx)
          while localTypes.len <= decIdx: localTypes.add(skUnknown)
          localTypes[decIdx] = skInt
        of opcPushG:
          npushG(jit.a,
            jitImmortalStr(cached.getArg1Str(pc, theProc.chunk)),
            cast[pointer](jitBridgePushG))
          inc stackDepth
          # Globals are untyped at compile time (they mutate): unknown is
          # sound — inline guards still fire on the runtime value, only
          # slow paths consult the kind.
          typeStack.tpush(skUnknown)
        of opcPopG:
          let popGKind = typeStack.tpop().kindToTypeId
          npopG(jit.a,
            jitImmortalStr(cached.getArg1Str(pc, theProc.chunk)),
            cast[pointer](jitBridgePopG), popGKind)
          dec stackDepth
        of opcAddI:
          naddI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skInt)
        of opcSubI:
          nsubI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skInt)
        of opcMultI:
          nmulI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skInt)
        of opcDivI:
          ndivI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skInt)
        of opcModI:
          nmodI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skInt)
        of opcNegI:
          nnegI(jit.a)
          discard typeStack.tpop()
          typeStack.tpush(skInt)
        of opcEqI:
          neqI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skBool)
        of opcLessI:
          nlessI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skBool)
        of opcGreaterI:
          ngreaterI(jit.a)
          dec stackDepth
          typeStack.tpopN(2)
          typeStack.tpush(skBool)
        of opcInvB:
          ninvB(jit.a)
          discard typeStack.tpop()
          typeStack.tpush(skBool)
        of opcGetI:
          let getIdxK = typeStack.tpop()
          let getArrK = typeStack.tpop()
          typeStack.tpush(skInt)
          ngetI(jit.a, jitGetItemSlow,
            getArrK.kindToTypeId or (getIdxK.kindToTypeId shl 8), pc)
          dec stackDepth
        of opcSetI:
          let setValK = typeStack.tpop()
          let setIdxK = typeStack.tpop()
          let setArrK = typeStack.tpop()
          nsetI(jit.a, jitSetItemSlow,
            setArrK.kindToTypeId or (setIdxK.kindToTypeId shl 8) or
            (setValK.kindToTypeId shl 16), pc)
          stackDepth -= 3
        of opcDiscard:
          let n = cached.getArg1Int(pc).int
          if pc in labelForTarget:
            # Jump target: condition already popped by jump_fwd_f/t. The
            # interpreter's trailing Discard would pop it, but native already
            # did. Skip to keep stack balanced. Depth already accounts for
            # the pop at the jump, so no change here.
            discard typeStack.tpop()
          elif stackDepth >= n and n > 0:
            ndiscard(jit.a, n)
            stackDepth -= n
            typeStack.tpopN(n)
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
          let condK = typeStack.tpop()
          typeStack.tpush(condK)
        of opcJumpFwdT:
          njumpFwdT(jit.a, labelForTarget.getOrDefault(jtTargets[pc], 0))
          let condKT = typeStack.tpop()
          typeStack.tpush(condKT)
        of opcReturnVal:
          nreturnVal(jit.a)
          dec stackDepth
          discard typeStack.tpop()
        of opcReturnVoid, opcHalt:
          nreturnVoid(jit.a)
        of opcNoop:
          discard
        of opcCallD:
          let targetProcId = cached.arg2[pc].int
          let callee = resolveCallTarget(vm, theProc, cached, pc,
            targetProcId)
          var callArgKinds = newSeq[int32](callee.nArgs)
          for k in 0 ..< callee.nArgs:
            # Pops come off last-arg-first; the bridge reads flatArgs order
            # (first arg at index 0), so fill back to front.
            callArgKinds[callee.nArgs - 1 - k] = typeStack.tpop().kindToTypeId
          let callTypes = jitImmortalTypes(callArgKinds)
          if targetProcId == theProc.procId:
            # Direct self-recursion: the buffer address is only final
            # after finalize, so emit a hole and back-patch below.
            # Void callees leave nothing behind (FinishVoid), matching the
            # interpreter; anything else would leak a phantom slot.
            if callee.nArgs > 0:
              emitCallArgsNim(jit.a, callee.nArgs)
              selfHoles.add(ncallSelfHole(jit.a, callee.nArgs))
              if callee.hasResult:
                ncallFinish(jit.a, jitCallDropBytes(callee.nArgs))
              else:
                ncallFinishVoid(jit.a, jitCallDropBytes(callee.nArgs))
            else:
              selfHoles.add(ncallSelfHole(jit.a, 0))
              if callee.hasResult:
                ncallFinish(jit.a, 0)
              else:
                ncallFinishVoid(jit.a, 0)
            # Native self-call consumes args and pushes result (if any).
            stackDepth -= callee.nArgs
            if callee.hasResult:
              inc stackDepth
              typeStack.tpush(theProc.procResultKind)
          else:
            # Non-self call: try inline expansion first for tiny
            # straight-line leaf callees (e.g. a predicate called per loop
            # iteration), bridge otherwise. Inlining removes the per-call
            # frame/bridge round trip; locals remap above the caller's.
            var didInline = false
            if callee.tp != nil and callee.tp.kind == pkNative and
                callee.tp.chunk != nil:
              let cCached = vm.getCachedOps(callee.tp.chunk)
              let cOps = cCached.opcodes
              let cCount = cOps.len
              if cCount >= 2 and cCount <= maxInlineOps and
                  (cOps[^1] == opcReturnVal or cOps[^1] == opcReturnVoid):
                var leafOk = true
                for cpc in 0 ..< cCount - 1:
                  if cOps[cpc] notin inlineLeafOps:
                    leafOk = false
                    break
                if leafOk:
                  didInline = true
                  let base = inlineHigh
                  inlineHigh = base + maxLocalFor(cCached,
                    callee.tp.paramCount)
                  for ai in countdown(callee.nArgs - 1, 0):
                    npopL(jit.a, base + ai)
                  stackDepth -= callee.nArgs
                  for ai in 0 ..< callee.nArgs:
                    while localTypes.len <= base + ai:
                      localTypes.add(skUnknown)
                    localTypes[base + ai] = kindFromTypeId(callArgKinds[ai])
                  for cpc in 0 ..< cCount - 1:
                    case cOps[cpc]
                    of opcPushI:
                      npushI(jit.a, cCached.getArg1Int(cpc).int)
                      inc stackDepth
                      typeStack.tpush(skInt)
                    of opcPushTrue:
                      npushTrue(jit.a)
                      inc stackDepth
                      typeStack.tpush(skBool)
                    of opcPushFalse:
                      npushFalse(jit.a)
                      inc stackDepth
                      typeStack.tpush(skBool)
                    of opcPushNil:
                      npushNil(jit.a)
                      inc stackDepth
                      typeStack.tpush(skRef)
                    of opcPushL:
                      let ibL = cCached.getArg1Int(cpc).int + base
                      npushL(jit.a, ibL)
                      inc stackDepth
                      typeStack.tpush(localTypes.localKind(ibL))
                    of opcPopL:
                      let ibP = cCached.getArg1Int(cpc).int + base
                      npopL(jit.a, ibP)
                      dec stackDepth
                      while localTypes.len <= ibP:
                        localTypes.add(skUnknown)
                      localTypes[ibP] = typeStack.tpop()
                    of opcIncL:
                      let ibI = cCached.getArg1Int(cpc).int + base
                      nincL(jit.a, ibI)
                      while localTypes.len <= ibI:
                        localTypes.add(skUnknown)
                      localTypes[ibI] = skInt
                    of opcDecL:
                      let ibD = cCached.getArg1Int(cpc).int + base
                      ndecL(jit.a, ibD)
                      while localTypes.len <= ibD:
                        localTypes.add(skUnknown)
                      localTypes[ibD] = skInt
                    of opcPushG:
                      npushG(jit.a,
                        jitImmortalStr(cCached.getArg1Str(cpc,
                          callee.tp.chunk)),
                        cast[pointer](jitBridgePushG))
                      inc stackDepth
                      typeStack.tpush(skUnknown)
                    of opcPopG:
                      let ibGKind = typeStack.tpop().kindToTypeId
                      npopG(jit.a,
                        jitImmortalStr(cCached.getArg1Str(cpc,
                          callee.tp.chunk)),
                        cast[pointer](jitBridgePopG), ibGKind)
                      dec stackDepth
                    of opcAddI:
                      naddI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skInt)
                    of opcSubI:
                      nsubI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skInt)
                    of opcMultI:
                      nmulI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skInt)
                    of opcDivI:
                      ndivI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skInt)
                    of opcModI:
                      nmodI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skInt)
                    of opcNegI:
                      nnegI(jit.a)
                      discard typeStack.tpop()
                      typeStack.tpush(skInt)
                    of opcEqI:
                      neqI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skBool)
                    of opcLessI:
                      nlessI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skBool)
                    of opcGreaterI:
                      ngreaterI(jit.a)
                      dec stackDepth
                      typeStack.tpopN(2)
                      typeStack.tpush(skBool)
                    of opcInvB:
                      ninvB(jit.a)
                      discard typeStack.tpop()
                      typeStack.tpush(skBool)
                    of opcDiscard:
                      let ibN = cCached.getArg1Int(cpc).int
                      if stackDepth >= ibN and ibN > 0:
                        ndiscard(jit.a, ibN)
                        stackDepth -= ibN
                        typeStack.tpopN(ibN)
                    of opcNoop:
                      discard
                    else:
                      discard
                  # Terminal ReturnVal/ReturnVoid: the result value (and its
                  # kind) is already on top from the body ops — nothing to
                  # emit, depth and types already account for it.
            if not didInline:
              if callee.nArgs > 0:
                emitCallArgsNim(jit.a, callee.nArgs)
                ncallInvokeTyped(jit.a, callee.nArgs, targetProcId,
                  callee.bridgeFn, callTypes)
                if callee.hasResult:
                  ncallFinish(jit.a, jitCallDropBytes(callee.nArgs))
                else:
                  ncallFinishVoid(jit.a, jitCallDropBytes(callee.nArgs))
              else:
                ncallAlloc(jit.a, 0)
                ncallInvokeTyped(jit.a, 0, targetProcId, callee.bridgeFn,
                  callTypes)
                if callee.hasResult:
                  ncallFinish(jit.a, 0)
                else:
                  ncallFinishVoid(jit.a, 0)
              # Native call sequence consumes args and pushes result.
              stackDepth -= callee.nArgs
              if callee.hasResult:
                inc stackDepth
                typeStack.tpush(callee.tp.procResultKind)
        else:
          discard

    var codeBuf = nimJitFinish(jit)
    if codeBuf.length == 0:
      codeBuf.destroy()
      return nil
    patchSelfCalls(codeBuf, selfHoles)
    result = publishNimCode(theProc, codeBuf, cached.opcodes, cached,
      opCount, vm, isMain)
    # Inlined bodies address remapped locals above the caller's frame:
    # widen the published frame when inlining reserved more.
    if inlineHigh > theProc.jitMaxLocal:
      theProc.jitMaxLocal = inlineHigh
  except DynasmError as e:
    when defined(vancodeJitLog):
      stderr.writeLine "[jit-nim] proc compile failed: ", theProc.name,
        ": ", e.msg
    jit.a.execBuf.destroy()
    return nil

proc hasBinaryRecursiveArith*(cached: CachedOps): bool =
  ## Fib-pattern detector: exactly two self-calls plus add+sub.
  ## Routes matching procs to the iterative native fib fast path.
  if cached == nil or cached.opcodes.len < 10: return false
  let oc = cached.opcodes
  var callCount = 0
  for i in 0 ..< oc.len:
    if oc[i] == opcCallD and cached.arg2[i].int > 0: inc callCount
  if callCount != 2: return false
  var hasAdd = false
  var hasSub = false
  for i in 0 ..< oc.len:
    if oc[i] == opcAddI: hasAdd = true
    if oc[i] == opcSubI: hasSub = true
  result = hasAdd and hasSub

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
  var traceTypeStack: seq[SlotKind] = @[]
  var traceLocalTypes: seq[SlotKind] = @[]
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
          traceTypeStack.tpush(skInt)
        of opcPushTrue:
          npushTrue(jit.a)
          traceTypeStack.tpush(skBool)
        of opcPushFalse:
          npushFalse(jit.a)
          traceTypeStack.tpush(skBool)
        of opcPushNil:
          npushNil(jit.a)
          traceTypeStack.tpush(skRef)
        of opcPushL:
          let tPushIdx = cached.getArg1Int(pc).int
          npushL(jit.a, tPushIdx)
          traceTypeStack.tpush(traceLocalTypes.localKind(tPushIdx))
        of opcPopL:
          let tPopIdx = cached.getArg1Int(pc).int
          npopL(jit.a, tPopIdx)
          while traceLocalTypes.len <= tPopIdx: traceLocalTypes.add(skUnknown)
          traceLocalTypes[tPopIdx] = traceTypeStack.tpop()
        of opcIncL:
          let tIncIdx = cached.getArg1Int(pc).int
          nincL(jit.a, tIncIdx)
          while traceLocalTypes.len <= tIncIdx: traceLocalTypes.add(skUnknown)
          traceLocalTypes[tIncIdx] = skInt
        of opcDecL:
          let tDecIdx = cached.getArg1Int(pc).int
          ndecL(jit.a, tDecIdx)
          while traceLocalTypes.len <= tDecIdx: traceLocalTypes.add(skUnknown)
          traceLocalTypes[tDecIdx] = skInt
        of opcAddI:
          naddI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skInt)
        of opcSubI:
          nsubI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skInt)
        of opcMultI:
          nmulI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skInt)
        of opcDivI:
          ndivI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skInt)
        of opcModI:
          nmodI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skInt)
        of opcNegI:
          nnegI(jit.a)
          discard traceTypeStack.tpop()
          traceTypeStack.tpush(skInt)
        of opcEqI:
          neqI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skBool)
        of opcLessI:
          nlessI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skBool)
        of opcGreaterI:
          ngreaterI(jit.a)
          traceTypeStack.tpopN(2)
          traceTypeStack.tpush(skBool)
        of opcInvB:
          ninvB(jit.a)
          discard traceTypeStack.tpop()
          traceTypeStack.tpush(skBool)
        of opcGetI:
          let tGetIdxK = traceTypeStack.tpop()
          let tGetArrK = traceTypeStack.tpop()
          traceTypeStack.tpush(skInt)
          ngetI(jit.a, jitGetItemSlow,
            tGetArrK.kindToTypeId or (tGetIdxK.kindToTypeId shl 8), pc)
        of opcSetI:
          let tSetValK = traceTypeStack.tpop()
          let tSetIdxK = traceTypeStack.tpop()
          let tSetArrK = traceTypeStack.tpop()
          nsetI(jit.a, jitSetItemSlow,
            tSetArrK.kindToTypeId or (tSetIdxK.kindToTypeId shl 8) or
            (tSetValK.kindToTypeId shl 16), pc)
        of opcDiscard:
          if pc in labelForTarget:
            discard traceTypeStack.tpop()  # jump already popped natively
          else:
            ndiscard(jit.a, cached.getArg1Int(pc).int)
            traceTypeStack.tpopN(cached.getArg1Int(pc).int)
        of opcPushG, opcPopG:
          let ch = cast[Chunk](trace.chunk)
          if oc == opcPushG:
            npushG(jit.a, jitImmortalStr(cached.getArg1Str(pc, ch)),
              cast[pointer](jitBridgePushG))
            traceTypeStack.tpush(skUnknown)
          else:
            let tPopGKind = traceTypeStack.tpop().kindToTypeId
            npopG(jit.a, jitImmortalStr(cached.getArg1Str(pc, ch)),
              cast[pointer](jitBridgePopG), tPopGKind)
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
          let tCondK = traceTypeStack.tpop()
          traceTypeStack.tpush(tCondK)
        of opcJumpFwdT:
          let tgt = jtTargets[pc]
          if tgt >= 0 and tgt in labelForTarget:
            njumpFwdT(jit.a, labelForTarget[tgt])
          else:
            njumpFwdT(jit.a, 1)
          let tCondKT = traceTypeStack.tpop()
          traceTypeStack.tpush(tCondKT)
        of opcJumpBack:
          let tgt = jtTargets[pc]
          if tgt >= 0 and tgt in labelForTarget:
            njumpBack(jit.a, labelForTarget[tgt])
          else:
            njumpBack(jit.a, 0)
        of opcCallD:
          let targetProc = cached.arg2[pc].int
          if targetProc == trace.selfProcId:
            # Native self-call passes raw slots straight through (no
            # bridge, no boxing): arg kinds are only stack accounting.
            # Void self-callees push nothing (FinishVoid).
            traceTypeStack.tpopN(trace.selfParamCount)
            if trace.selfParamCount > 0:
              emitCallArgsNim(jit.a, trace.selfParamCount)
              selfHoles.add(ncallSelfHole(jit.a, trace.selfParamCount))
              if trace.selfHasResult:
                ncallFinish(jit.a,
                  jitCallDropBytes(trace.selfParamCount))
              else:
                ncallFinishVoid(jit.a,
                  jitCallDropBytes(trace.selfParamCount))
            else:
              selfHoles.add(ncallSelfHole(jit.a, 0))
              if trace.selfHasResult:
                ncallFinish(jit.a, 0)
              else:
                ncallFinishVoid(jit.a, 0)
            if trace.selfHasResult:
              traceTypeStack.tpush(skUnknown)
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
            var tCallArgKinds = newSeq[int32](callee.nArgs)
            for k in 0 ..< callee.nArgs:
              tCallArgKinds[callee.nArgs - 1 - k] =
                traceTypeStack.tpop().kindToTypeId
            let tCallTypes = jitImmortalTypes(tCallArgKinds)
            if callee.nArgs > 0:
              emitCallArgsNim(jit.a, callee.nArgs)
              ncallInvokeTyped(jit.a, callee.nArgs, targetProc,
                callee.bridgeFn, tCallTypes)
              if callee.hasResult:
                ncallFinish(jit.a, jitCallDropBytes(callee.nArgs))
              else:
                ncallFinishVoid(jit.a, jitCallDropBytes(callee.nArgs))
            else:
              ncallAlloc(jit.a, 0)
              ncallInvokeTyped(jit.a, 0, targetProc, callee.bridgeFn,
                tCallTypes)
              if callee.hasResult:
                ncallFinish(jit.a, 0)
              else:
                ncallFinishVoid(jit.a, 0)
            if callee.hasResult:
              traceTypeStack.tpush(callee.tp.procResultKind)
        of opcReturnVal:
          nreturnVal(jit.a)
          discard traceTypeStack.tpop()
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
