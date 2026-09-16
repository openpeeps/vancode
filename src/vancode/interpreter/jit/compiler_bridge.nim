# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Bridge layer between the VM and JIT-compiled code. Maintains global tables
## for fast proc/function pointer lookup (jitFnTable, jitProcTable), provides
## the recompilation hook infrastructure, and exposes helper routines for the
## DynASM-generated code to interact with the VM (globals, callbacks, etc.).
import std/[tables, sysatomics, critbits, hashes]
import ./dynasm/wrapper
import ./jit_mem
import ./jit_values
export jit_values
import ../[vm, value, chunk]

proc emitCallArgs*(d: ptr ptr dasm_State, nArgs: int) =
  ## Move the top `nArgs` native-stack operands down into a reserved
  ## flatArgs array in interpreter order (deepest first, matching
  ## `stack{^n}`): `call_alloc` reserves below them, then the operand at
  ## depth `i` from the bottom moves to `[rsp+i*8]`. Unrolled (no labels,
  ## so any arity is safe). On return rsp points at the array base; the
  ## stale operand slots above are dropped by `call_finish` (pass
  ## `2*nArgs*8`).
  vancode_call_alloc(d, nArgs.cint)
  for i in 0 ..< nArgs:
    vancode_call_move_one(d, (2 * nArgs * 8 - (i + 1) * 8).cint, (i * 8).cint)

var jitFnTable*: array[65536, pointer]
var jitProcTable*: array[65536, pointer]
var jitParamCount*: array[65536, int]
var jitOptLevel*: cint = 2
const hotRecompileThreshold* = 100

var jitGlobalVm*: Vm = nil
var jitGlobalsPtr*: pointer = nil
var jitBridgeTmpBuf: array[256, Value]
var jitCallbackResult: Value = nil  # GC root for execCallback result

var jitRecompileHook*: proc(theProc: Proc) {.nimcall.} = nil
var compileProcHook*: proc(vm: Vm, theProc: Proc): ForeignProc {.nimcall.} = nil

type JitForeignFast* = object
  ## Fast path for a `CallD` to a foreign proc from JIT-compiled code.
  ## The bridge has the same C ABI as `jitCallProcBridgeFlat` and receives
  ## the raw native-stack int64s; plain ints/bools arrive as values while
  ## `Value` payloads cross as GC-rooted ring indices (see `jitRootValue`).
  arity*: int       ## exact argc served, or -1 for any arity
  bridgeFn*: pointer

var jitForeignFastTable = initTable[(string, int), JitForeignFast]()

proc registerJitForeignFast*(name: string, desc: JitForeignFast) =
  ## Hosts (e.g. bowdy) register per-builtin fast paths at startup, before the
  ## first JIT compile. Keyed by (name, arity); arity -1 serves any arity.
  ## Misses fall back to `jitCallProcBridgeFlat` (sound, slower).
  jitForeignFastTable[(name, desc.arity)] = desc

proc findJitForeignFast*(name: string, argc: int): pointer =
  ## Returns the registered bridge for `name`/`argc`, or nil.
  if (name, argc) in jitForeignFastTable:
    return jitForeignFastTable[(name, argc)].bridgeFn
  if (name, -1) in jitForeignFastTable:
    return jitForeignFastTable[(name, -1)].bridgeFn
  nil

proc jitFillTmpBuf*(arr: ptr UncheckedArray[int64], argc: int32,
    argTypes: ptr int32) =
  ## Fill the shared bridge arg buffer from native-stack slots: untagged
  ## slots box as `tyInt`, tagged slots resolve, explicitly typed bools
  ## decode. Never a raw pointer cast (the old `else: cast[Value]` read
  ## tagged indices as pointers).
  if argTypes == nil:
    for i in 0..<argc:
      jitBridgeTmpBuf[i] = jitUnpackArg(arr[i])
  else:
    let types = cast[ptr UncheckedArray[int32]](argTypes)
    for i in 0..<argc:
      case types[i]
      of tyInt: jitBridgeTmpBuf[i] = initValue(arr[i])
      of tyBool: jitBridgeTmpBuf[i] = Value(typeId: tyBool, boolVal: arr[i] != 0)
      else: jitBridgeTmpBuf[i] = jitUnpackArg(arr[i])

var jitHostBridges = initTable[string, pointer]()

proc registerJitHostBridge*(name: string, fn: pointer) =
  ## Hosts (e.g. bowdy) register named bridge entry points here at startup.
  ## Host-injected JIT emit branches call them through the existing
  ## `vancode_pushg`/`vancode_call_invoke` DynASM actions; a missing entry
  ## must make the host branch reject compilation (fall back to the VM).
  jitHostBridges[name] = fn

proc findJitHostBridge*(name: string): pointer =
  result = jitHostBridges.getOrDefault(name, nil)

type JitHostMeta* = object
  ## Per-site metadata baked at JIT-compile time, referenced by int32 id
  ## smuggled in the call_invoke procId slot. Ids never outlive the
  ## compile that made them: `resetJitState` clears the table at every
  ## generation boundary.
  ints*: seq[int64]
  strs*: seq[string]

var jitHostMetaTable: seq[JitHostMeta] = @[]

proc registerJitHostMeta*(m: JitHostMeta): int32 =
  result = jitHostMetaTable.len.int32
  jitHostMetaTable.add(m)

proc resetJitHostMeta*() =
  jitHostMetaTable.setLen(0)

proc getJitHostMeta*(id: int32): JitHostMeta =
  result = jitHostMetaTable[id]

var jitFloatConsts = initTable[float64, pointer]()

proc jitImmortalFloat*(f: float64): pointer =
  ## Immortal 8-byte double cache for baking float constants into JIT
  ## code (mirrors `jitImmortalStr`). Bounded by unique constants.
  if f in jitFloatConsts: return jitFloatConsts[f]
  let p = allocShared0(8)
  var tmp = f
  copyMem(p, addr tmp, 8)
  jitFloatConsts[f] = p
  p

var jitStrConsts = initTable[string, pointer]()

proc jitImmortalStr*(s: string): pointer =
  ## Immortal C string cache for baking string constants into JIT code.
  ## Shared-alloc memory never moves and is never freed; bounded by the
  ## number of unique constants compiled.
  if s in jitStrConsts: return jitStrConsts[s]
  let p = allocShared0(s.len + 1)
  if s.len > 0:
    copyMem(p, unsafeAddr s[0], s.len)
  jitStrConsts[s] = p
  p

proc jitRecompileAtO3*(theProc: Proc) {.nimcall.} =
  ## JIT recompile `theProc` at -O3 optimization level if not already recompiled
  discard

# JIT global cache using raw C arrays to avoid ARC/GC issues.
# `jitGlobalsCount` is the number of globals. Each global is stored as a
# (name_hash: uint32, value: int64) pair in two parallel arrays.
var jitGlobalsCount*: int32 = 0
var jitGlobalsKeys: array[256, uint32]
var jitGlobalsVals: array[256, int64]
var jitGlobalsTypes: array[256, int32]

proc setJitGlobalsFromTable*(t: ptr Table[string, Value]) {.cdecl, exportc.} =
  ## Copy globals from the VM's table into the JIT raw cache.
  jitGlobalsCount = 0
  for k, v in t[]:
    if v != nil:
      jitGlobalsKeys[jitGlobalsCount] = hash(k).uint32
      case v.typeId
      of tyInt: jitGlobalsVals[jitGlobalsCount] = v.intVal
      of tyBool: jitGlobalsVals[jitGlobalsCount] = int64(v.boolVal.ord)
      else: jitGlobalsVals[jitGlobalsCount] = cast[int64](v)
      jitGlobalsTypes[jitGlobalsCount] = v.typeId.int32
      inc jitGlobalsCount

proc setJitGlobalsPtr*(p: pointer) =
  ## Set the global VM globals pointer for JIT bridge access and populate cache
  jitGlobalsPtr = p
  if p != nil:
    setJitGlobalsFromTable(cast[ptr Table[string, Value]](p))

proc setJitVm*(vm: Vm) =
  ## Set the global VM instance used by JIT bridge functions
  jitGlobalVm = vm

proc jitBridgePushG*(namePtr: pointer): int64 {.cdecl, exportc.} =
  ## JIT bridge: push a global variable value by name
  let name = cast[cstring](namePtr)
  if name == nil: return 0
  let h = hash($name).uint32
  for i in 0..<jitGlobalsCount:
    if jitGlobalsKeys[i] == h:
      return jitGlobalsVals[i]
  0

proc jitBridgePopG*(namePtr: pointer, val: int64, typeId: int32) {.cdecl, exportc.} =
  ## JIT bridge: pop a value into a global variable by name
  let name = cast[cstring](namePtr)
  if name == nil: return
  let h = hash($name).uint32
  for i in 0..<jitGlobalsCount:
    if jitGlobalsKeys[i] == h:
      jitGlobalsVals[i] = val
      jitGlobalsTypes[i] = typeId
      return
  # New global: add it
  if jitGlobalsCount < 256:
    jitGlobalsKeys[jitGlobalsCount] = h
    jitGlobalsVals[jitGlobalsCount] = val
    jitGlobalsTypes[jitGlobalsCount] = typeId
    inc jitGlobalsCount

proc findProcById*(procId: int): Proc =
  ## Find a Proc by its procId across all imported modules
  if jitGlobalVm == nil: return nil
  for _, s in jitGlobalVm.importedModules:
    if procId >= 0 and procId < s.procs.len:
      return s.procs[procId]
  nil

proc jitBridgeMakeInt*(val: int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: create a tyInt Value from an int64, returns cast[int64]
  result = cast[int64](Value(typeId: tyInt, intVal: val))

proc jitBridgeMakeBool*(val: bool): int64 {.cdecl, exportc.} =
  ## JIT bridge: create a tyBool Value from a bool, returns cast[int64]
  result = cast[int64](Value(typeId: tyBool, boolVal: val))

proc jitBridgeExtractInt*(valPtr: int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: extract intVal from a Value pointer, returns int64
  result = cast[Value](valPtr).intVal

proc jitBridgeConstrArray*(count: int32): int64 {.cdecl, exportc.} =
  ## JIT bridge: construct an array Value with `count` slots
  let arr = initArray(count)
  result = cast[int64](arr)

var jitProcCache: array[65536, pointer]

proc resetJitTables*() =
  ## Clear the process-global JIT caches (procId-keyed native code and proc
  ## lookups). ProcIds are per-script, so hosts must call this when starting
  ## a fresh compile in a long-lived process (embedders, test suites);
  ## otherwise a new script reuses another script's compiled code.
  ## Prefer `resetJitState`: tables alone orphan the native code buffers.
  zeroMem(addr jitFnTable[0], sizeof(jitFnTable))
  zeroMem(addr jitProcTable[0], sizeof(jitProcTable))
  zeroMem(addr jitParamCount[0], sizeof(jitParamCount))
  zeroMem(addr jitProcCache[0], sizeof(jitProcCache))

const jitCodeBufReuseSize* = 128 * 1024
  ## Size class shared by every JIT code buffer, so one retained spare
  ## always fits the next pre-allocation.

var jitLiveCodeBufs: seq[tuple[p: pointer, size: int]] = @[]
var jitSpareCodeBuf: pointer = nil

proc jitTrackCodeBuf*(p: pointer, size: int) =
  ## Register a live native code buffer of the current generation.
  ## Compilers call this exactly once per buffer they hand out; buffers
  ## freed inline on compile failure are never tracked.
  if p == nil: return
  for (q, _) in jitLiveCodeBufs:
    if q == p: return
  jitLiveCodeBufs.add((p, size))

proc jitTakeSpareCodeBuf*(size: int): pointer =
  ## Take the retained spare buffer when it fits, else nil (caller mmaps).
  if jitSpareCodeBuf != nil and size <= jitCodeBufReuseSize:
    result = jitSpareCodeBuf
    jitSpareCodeBuf = nil

proc jitDebugCounts*(meta, strs, floats, live: var int) =
  ## TEMP DEBUG (remove before commit): census of per-generation tables.
  meta = jitHostMetaTable.len
  strs = jitStrConsts.len
  floats = jitFloatConsts.len
  live = jitLiveCodeBufs.len

proc resetJitState*() =
  ## Generation boundary for long-lived hosts (watch mode, embedders,
  ## test suites): call before compiling a fresh script, never while
  ## native code from this generation can still run.
  ## Frees every tracked code buffer but retains one 128KB spare, clears
  ## the procId tables, immortal constant caches (with their shared-heap
  ## memory), the root ring, and bridge scratch state.
  ## Detector state (hot counts, proc call counts) intentionally survives
  ## so the next generation keeps climbing toward its thresholds.
  var keptSpare = false
  for (p, size) in jitLiveCodeBufs:
    if not keptSpare and size == jitCodeBufReuseSize:
      if jitSpareCodeBuf != nil and jitSpareCodeBuf != p:
        freeJitCode(jitSpareCodeBuf, jitCodeBufReuseSize)
      jitSpareCodeBuf = p
      keptSpare = true
    else:
      freeJitCode(p, size)
  jitLiveCodeBufs.setLen(0)
  resetJitTables()
  resetJitHostMeta()
  for _, p in jitFloatConsts:
    deallocShared(p)
  jitFloatConsts.clear()
  for _, p in jitStrConsts:
    deallocShared(p)
  jitStrConsts.clear()
  jitClearRing()
  jitCallbackResult = nil
  # Plain assignment, never `zeroMem`: the scratch buffer holds traced
  # `Value` refs and zeroing would orphan them without destructors (same
  # leak class as the ring; see `jitClearRing`). Pointer/int tables above
  # are untraced, so `zeroMem` stays safe for those.
  for i in 0 ..< len(jitBridgeTmpBuf):
    jitBridgeTmpBuf[i] = nil
  jitGlobalsCount = 0
  zeroMem(addr jitGlobalsKeys[0], sizeof(jitGlobalsKeys))
  zeroMem(addr jitGlobalsVals[0], sizeof(jitGlobalsVals))
  zeroMem(addr jitGlobalsTypes[0], sizeof(jitGlobalsTypes))

proc jitBridgeFastAdd*(listPtr: int64, itemVal: int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: fast path for array.add(int), appends int64 item
  cast[Value](listPtr).objectVal.fields.add(ValueStorage(typeId: tyInt, intVal: itemVal))
  0

proc jitBridgeConcatStr*(a: int64, b: int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: concatenate two string Values, returns cast[int64] of result
  let av = cast[Value](a)
  let bv = cast[Value](b)
  if av == nil or bv == nil: return 0
  let resultVal = Value(typeId: tyString, stringVal: new string)
  resultVal.stringVal[] = av.stringVal[] & bv.stringVal[]
  result = cast[int64](resultVal)

proc jitBridgeEqStr*(a: int64, b: int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: compare two string Values for equality, returns 0/1
  let av = cast[Value](a)
  let bv = cast[Value](b)
  if av == nil or bv == nil: return int64(av == bv)
  result = int64(av.stringVal[] == bv.stringVal[])

proc jitBridgeGetField*(objVal: int64, fieldId: int32): int64 {.cdecl, exportc.} =
  ## JIT bridge: get field by index from an object Value
  let obj = cast[Value](objVal)
  if obj == nil or obj.objectVal.isNil or fieldId < 0 or fieldId >= obj.objectVal.fields.len:
    return 0
  let vs = obj.objectVal.fields[fieldId]
  result = cast[int64](vs.toValue)

proc jitBridgeSetField*(objVal: int64, fieldId: int32, val: int64) {.cdecl, exportc.} =
  ## JIT bridge: set field by index on an object Value
  let obj = cast[Value](objVal)
  if obj == nil or obj.objectVal.isNil or fieldId < 0 or fieldId >= obj.objectVal.fields.len:
    return
  let vs = cast[Value](val)
  if vs != nil:
    obj.objectVal.fields[fieldId] = vs.toStorage

proc jitBridgeGetItem*(arrVal: int64, index: int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: get array element by int64 index
  let arr = cast[Value](arrVal)
  if arr == nil or arr.objectVal.isNil or index < 0 or index >= arr.objectVal.fields.len:
    return 0
  result = cast[int64](arr.objectVal.fields[index.int].toValue)

proc jitBridgeSetItem*(arrVal: int64, index: int64, valPtr: int64) {.cdecl, exportc.} =
  ## JIT bridge: set array element by int64 index
  let arr = cast[Value](arrVal)
  if arr == nil or arr.objectVal.isNil or index < 0 or index >= arr.objectVal.fields.len:
    return
  let vs = cast[Value](valPtr)
  if vs != nil:
    arr.objectVal.fields[index.int] = vs.toStorage

proc jitBridgeConstrObj*(count: int32, flatArgs: ptr int64): int64 {.cdecl, exportc.} =
  ## JIT bridge: construct an object from flat arg array (positional values, no keys).
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  if count > 0:
    var fields = newSeq[ValueStorage](count)
    for i in 0..<count:
      let valPtr = cast[Value](arr[i])
      if valPtr != nil:
        fields[i] = valPtr.toStorage
    result = cast[int64](Value(typeId: tyArrayObject, objectVal:
      Object(isForeign: false, fields: fields)))
  else:
    result = cast[int64](Value(typeId: tyArrayObject, objectVal:
      Object(isForeign: false)))

proc jitBridgePushProc*(scriptPath: cstring, procId: int32): int64 {.cdecl, exportc.} =
  ## JIT bridge: create a tyProc Value from scriptPath and procId
  if jitGlobalVm == nil: return 0
  let path = if scriptPath != nil: $scriptPath else: ""
  let val = Value(typeId: tyProc)
  new(val.procVal)
  val.procVal[] = ProcRef(procId: procId.int, procScript: path)
  result = cast[int64](val)

proc jitBridgeCallI*(procRefVal: int64, flatArgs: ptr int64, argc: int32, argTypes: ptr int32): int64 {.cdecl, exportc.} =
  ## JIT bridge: indirect proc call via a tyProc Value on the stack
  let val = cast[Value](procRefVal)
  if val == nil or val.typeId != tyProc: return 0
  let pref = val.procVal
  var target: Script = nil
  if jitGlobalVm != nil and pref.procScript in jitGlobalVm.importedModules:
    target = jitGlobalVm.importedModules[pref.procScript]
  if target == nil or pref.procId < 0 or pref.procId >= target.procs.len:
    return 0
  let theProc = target.procs[pref.procId]
  if argc > 256: return 0
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  jitFillTmpBuf(arr, argc, argTypes)
  let callResult =
    if theProc.jitForeign != nil:
      theProc.jitForeign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    elif theProc.kind == pkForeign and theProc.foreign != nil:
      theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    else:
      nil
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = nil
  result = jitPackResult(callResult)

proc jitCallProcBridgeFlat*(procId: int32, flatArgs: ptr int64, argc: int32, argTypes: ptr int32): int64 {.cdecl, exportc.} =
  ## JIT bridge: call a proc by procId with flat int64 args (used by opcCallD JIT codegen)
  let fnPtr = jitFnTable[procId]
  if fnPtr != nil:
    let p = cast[Proc](jitProcTable[procId])
    if p != nil and not p.jitRecompiled:
      p.jitCallCount += 1
      if p.jitCallCount >= hotRecompileThreshold:
        if jitRecompileHook != nil: jitRecompileHook(p)
    type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
    return cast[JitFn](fnPtr)(flatArgs, argc)
  let theProc =
    if jitProcCache[procId] != nil:
      cast[Proc](jitProcCache[procId])
    else:
      let p = findProcById(procId.int)
      when defined(vancodeJitLog):
        if p == nil: stderr.writeLine "[jit] bridge: findProcById(", procId, ") returned nil"
      if p != nil: jitProcCache[procId] = cast[pointer](p)
      p
  if theProc == nil: return 0
  let fnPtr2 = atomicLoadN(addr theProc.jitCodePtr, AtomicAcquire)
  if fnPtr2 != nil:
    jitFnTable[procId] = fnPtr2
    jitProcTable[procId] = cast[pointer](theProc)
    if not theProc.jitRecompiled:
      theProc.jitCallCount += 1
      if theProc.jitCallCount >= hotRecompileThreshold:
        if jitRecompileHook != nil: jitRecompileHook(theProc)
    type JitFn = proc (flatArgs: ptr int64, argc: int): int64 {.cdecl.}
    return cast[JitFn](fnPtr2)(flatArgs, argc)
  if argc > 256: return 0
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  jitFillTmpBuf(arr, argc, argTypes)
  when defined(vancodeJitLog):
    stderr.writeLine "[jit] bridge: calling proc " & theProc.name
  let callResult =
    if theProc.jitForeign != nil:
      theProc.jitForeign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    elif theProc.kind == pkForeign and theProc.foreign != nil:
      theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    else:
      nil
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = nil
  return jitPackResult(callResult)

proc jitCallProcBridge*(procId: int32, stackIPtr: ptr int64, sp: int32, deltaPtr: ptr int32, resultIntPtr: ptr int64) {.cdecl, exportc.} =
  ## JIT bridge: call a proc by procId with stack-relative args (used by legacy JIT codegen)
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

proc callCallback*(procScript: cstring, procId: int32,
                   flatArgs: ptr int64, argc: int32,
                   argTypes: ptr int32): int64 {.cdecl, exportc.} =
  ## Set up a pending callback for the main interpret loop (JIT path or pendingCallback)
  if jitGlobalVm == nil: return 0
  let scriptPath = $procScript
  var target: Script = nil
  if scriptPath in jitGlobalVm.importedModules:
    target = jitGlobalVm.importedModules[scriptPath]
  if target == nil or procId < 0 or procId >= target.procs.len:
    return 0
  let theProc = target.procs[procId]
  if theProc.jitForeign != nil:
    discard theProc.jitForeign(nil, 0)
    return 1
  var cbVal = Value(typeId: tyProc)
  new(cbVal.procVal)
  cbVal.procVal[] = ProcRef(procId: procId, procScript: scriptPath)
  jitGlobalVm.pendingCallback = cbVal
  result = 1

proc execCallback*(procScript: cstring, procId: int32,
                   flatArgs: ptr int64, argc: int32,
                   argTypes: ptr int32): int64 {.cdecl, exportc.} =
  ## Execute a callback proc synchronously (JIT/foreign path, falls back to interpret for native)
  if jitGlobalVm == nil: return 0
  let scriptPath = $procScript
  var target: Script = nil
  if scriptPath in jitGlobalVm.importedModules:
    target = jitGlobalVm.importedModules[scriptPath]
  if target == nil or procId < 0 or procId >= target.procs.len:
    return 0
  let theProc = target.procs[procId]
  if argc > 256: return 0
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  jitFillTmpBuf(arr, argc, argTypes)
  if compileProcHook != nil and theProc.jitForeign == nil:
    let compiled = compileProcHook(jitGlobalVm, theProc)
    if compiled != nil:
      theProc.jitForeign = compiled

  var callbackResult: Value = nil
  if theProc.kind == pkForeign and theProc.foreign != nil:
    callbackResult = theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
  else:
    callbackResult = interpret(jitGlobalVm, target, theProc.chunk,
      jitBridgeTmpBuf[0..<argc])
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = nil
  jitCallbackResult = callbackResult  # keep alive as GC root
  if callbackResult != nil:
    result = cast[int64](callbackResult)
