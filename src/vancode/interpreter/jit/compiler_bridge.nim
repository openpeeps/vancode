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
import ../[vm, value, chunk]

var jitFnTable*: array[65536, pointer]
var jitProcTable*: array[65536, pointer]
var jitParamCount*: array[65536, int]
var jitOptLevel*: cint = 2
const hotRecompileThreshold* = 100

var jitGlobalVm*: Vm = nil
var jitGlobalsPtr*: pointer = nil
var jitBridgeTmpBuf: array[256, Value]
var jitCallbackResult: Value

var jitRecompileHook*: proc(theProc: Proc) {.nimcall.} = nil
var compileProcHook*: proc(vm: Vm, theProc: Proc): ForeignProc {.nimcall.} = nil

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
    if v.typeId == tyNil: continue
    jitGlobalsKeys[jitGlobalsCount] = hash(k).uint32
    case v.typeId
    of tyInt: jitGlobalsVals[jitGlobalsCount] = v.intVal
    of tyBool: jitGlobalsVals[jitGlobalsCount] = int64(v.boolVal.ord)
    else: jitGlobalsVals[jitGlobalsCount] = 0
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
  jitBridgeTmpBuf[0] = Value(typeId: tyInt, intVal: val)
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgeMakeBool*(val: bool): int64 {.cdecl, exportc.} =
  jitBridgeTmpBuf[0] = Value(typeId: tyBool, boolVal: val)
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgeExtractInt*(valPtr: int64): int64 {.cdecl, exportc.} =
  let v = cast[ptr Value](cast[pointer](valPtr))[]
  result = v.intVal

proc jitBridgeConstrArray*(count: int32): int64 {.cdecl, exportc.} =
  let arr = initArray(count)
  jitBridgeTmpBuf[0] = arr
  result = cast[int64](addr jitBridgeTmpBuf[0])

var jitProcCache: array[65536, pointer]

proc jitBridgeFastAdd*(listPtr: int64, itemVal: int64): int64 {.cdecl, exportc.} =
  let v = cast[ptr Value](cast[pointer](listPtr))[]
  v.objectVal.fields.add(ValueStorage(typeId: tyInt, intVal: itemVal))
  0

proc jitBridgeConcatStr*(a: int64, b: int64): int64 {.cdecl, exportc.} =
  let ap = cast[ptr Value](cast[pointer](a))[]
  let bp = cast[ptr Value](cast[pointer](b))[]
  jitBridgeTmpBuf[0] = Value(typeId: tyString, stringVal: ap.stringVal & bp.stringVal)
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgeEqStr*(a: int64, b: int64): int64 {.cdecl, exportc.} =
  let ap = cast[ptr Value](cast[pointer](a))[]
  let bp = cast[ptr Value](cast[pointer](b))[]
  result = int64(ap.stringVal == bp.stringVal)

proc jitBridgeGetField*(objVal: int64, fieldId: int32): int64 {.cdecl, exportc.} =
  let obj = cast[ptr Value](cast[pointer](objVal))[]
  if obj.objectVal == nil or obj.objectVal.isNil or fieldId < 0 or fieldId >= obj.objectVal.fields.len:
    return 0
  let vs = obj.objectVal.fields[fieldId]
  jitBridgeTmpBuf[0] = vs.toValue
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgeSetField*(objVal: int64, fieldId: int32, val: int64) {.cdecl, exportc.} =
  let obj = cast[ptr Value](cast[pointer](objVal))[]
  if obj.objectVal == nil or obj.objectVal.isNil or fieldId < 0 or fieldId >= obj.objectVal.fields.len:
    return
  let vs = cast[ptr Value](cast[pointer](val))[]
  obj.objectVal.fields[fieldId] = vs.toStorage

proc jitBridgeGetItem*(arrVal: int64, index: int64): int64 {.cdecl, exportc.} =
  let arr = cast[ptr Value](cast[pointer](arrVal))[]
  if arr.objectVal == nil or arr.objectVal.isNil or index < 0 or index >= arr.objectVal.fields.len:
    return 0
  jitBridgeTmpBuf[0] = arr.objectVal.fields[index.int].toValue
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgeSetItem*(arrVal: int64, index: int64, valPtr: int64) {.cdecl, exportc.} =
  let arr = cast[ptr Value](cast[pointer](arrVal))[]
  if arr.objectVal == nil or arr.objectVal.isNil or index < 0 or index >= arr.objectVal.fields.len:
    return
  let vs = cast[ptr Value](cast[pointer](valPtr))[]
  arr.objectVal.fields[index.int] = vs.toStorage

proc jitBridgeConstrObj*(count: int32, flatArgs: ptr int64): int64 {.cdecl, exportc.} =
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  if count > 0:
    var fields = newSeq[ValueStorage](count)
    for i in 0..<count:
      let valPtr = cast[ptr Value](cast[pointer](arr[i]))[]
      fields[i] = valPtr.toStorage
    jitBridgeTmpBuf[0] = Value(typeId: tyArrayObject, objectVal:
      Object(isForeign: false, fields: fields))
  else:
    jitBridgeTmpBuf[0] = Value(typeId: tyArrayObject, objectVal:
      Object(isForeign: false))
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgePushProc*(scriptPath: cstring, procId: int32): int64 {.cdecl, exportc.} =
  if jitGlobalVm == nil: return 0
  let path = if scriptPath != nil: $scriptPath else: ""
  jitBridgeTmpBuf[0] = Value(typeId: tyProc, procVal: ProcRef(procId: procId.int, procScript: path))
  result = cast[int64](addr jitBridgeTmpBuf[0])

proc jitBridgeCallI*(procRefVal: int64, flatArgs: ptr int64, argc: int32, argTypes: ptr int32): int64 {.cdecl, exportc.} =
  let val = cast[ptr Value](cast[pointer](procRefVal))[]
  if val.typeId != tyProc: return 0
  let pref = val.procVal
  var target: Script = nil
  if jitGlobalVm != nil and pref.procScript in jitGlobalVm.importedModules:
    target = jitGlobalVm.importedModules[pref.procScript]
  if target == nil or pref.procId < 0 or pref.procId >= target.procs.len:
    return 0
  let theProc = target.procs[pref.procId]
  if argc > 256: return 0
  let arr = cast[ptr UncheckedArray[int64]](flatArgs)
  if argTypes == nil:
    for i in 0..<argc:
      jitBridgeTmpBuf[i] = Value(typeId: tyInt, intVal: arr[i])
  else:
    let types = cast[ptr UncheckedArray[int32]](argTypes)
    for i in 0..<argc:
      let t = types[i]
      case t
      of tyInt: jitBridgeTmpBuf[i] = Value(typeId: tyInt, intVal: arr[i])
      of tyBool: jitBridgeTmpBuf[i] = Value(typeId: tyBool, boolVal: arr[i] != 0)
      else: jitBridgeTmpBuf[i] = cast[ptr Value](cast[pointer](arr[i]))[]
  let callResult =
    if theProc.jitForeign != nil:
      theProc.jitForeign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    elif theProc.kind == pkForeign and theProc.foreign != nil:
      theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    else:
      Value(typeId: tyNil)
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = Value(typeId: tyNil)
  if callResult.typeId == tyNil: return 0
  result = cast[int64](addr jitBridgeTmpBuf[0])
  jitBridgeTmpBuf[0] = callResult

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
  if argTypes == nil:
    for i in 0..<argc:
      jitBridgeTmpBuf[i] = Value(typeId: tyInt, intVal: arr[i])
  else:
    let types = cast[ptr UncheckedArray[int32]](argTypes)
    for i in 0..<argc:
      let t = types[i]
      if t == tyInt:
        jitBridgeTmpBuf[i] = Value(typeId: tyInt, intVal: arr[i])
      elif t == tyBool:
        jitBridgeTmpBuf[i] = Value(typeId: tyBool, boolVal: arr[i] != 0)
      else:
        jitBridgeTmpBuf[i] = cast[ptr Value](cast[pointer](arr[i]))[]
  when defined(vancodeJitLog):
    stderr.writeLine "[jit] bridge: calling proc " & theProc.name
  let callResult =
    if theProc.jitForeign != nil:
      theProc.jitForeign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    elif theProc.kind == pkForeign and theProc.foreign != nil:
      theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    else:
      Value(typeId: tyNil)
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = Value(typeId: tyNil)
  if callResult.typeId == tyNil: return 0
  case callResult.typeId
  of tyInt: return callResult.intVal
  of tyBool: return callResult.boolVal.ord.int64
  else: return 0

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
    if callResult.typeId != tyNil:
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
  jitGlobalVm.pendingCallback = Value(typeId: tyProc, procVal: ProcRef(procId: procId.int, procScript: scriptPath))
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
  if argTypes == nil:
    for i in 0..<argc:
      jitBridgeTmpBuf[i] = Value(typeId: tyInt, intVal: arr[i])
  else:
    let types = cast[ptr UncheckedArray[int32]](argTypes)
    for i in 0..<argc:
      let t = types[i]
      if t == tyInt:
        jitBridgeTmpBuf[i] = Value(typeId: tyInt, intVal: arr[i])
      elif t == tyBool:
        jitBridgeTmpBuf[i] = Value(typeId: tyBool, boolVal: arr[i] != 0)
      elif t == tyString:
        jitBridgeTmpBuf[i] = cast[ptr Value](cast[pointer](arr[i]))[]
      elif t == tyFloat:
        jitBridgeTmpBuf[i] = Value(typeId: tyFloat, floatVal: cast[float64](arr[i]))
      else:
        jitBridgeTmpBuf[i] = cast[ptr Value](cast[pointer](arr[i]))[]
  if compileProcHook != nil and theProc.jitForeign == nil:
    let compiled = compileProcHook(jitGlobalVm, theProc)
    if compiled != nil:
      theProc.jitForeign = compiled

  var callbackResult: Value
  if theProc.kind == pkForeign and theProc.foreign != nil:
    callbackResult = theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
  else:
    callbackResult = interpret(jitGlobalVm, target, theProc.chunk,
      jitBridgeTmpBuf[0..<argc])
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = Value(typeId: tyNil)
  jitCallbackResult = callbackResult
  jitBridgeTmpBuf[0] = callbackResult
  if callbackResult.typeId != tyNil:
    result = cast[int64](addr jitBridgeTmpBuf[0])
