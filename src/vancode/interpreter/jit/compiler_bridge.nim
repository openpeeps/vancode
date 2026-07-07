# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ../[chunk, vm, value]
import std/[tables, sysatomics, critbits]

var jitFnTable*: array[65536, pointer]
var jitProcTable*: array[65536, pointer]
var jitParamCount*: array[65536, int]
var jitOptLevel*: cint = 3
const hotRecompileThreshold* = 100

var jitGlobalVm*: Vm = nil
var jitGlobalsPtr*: pointer = nil
var jitBridgeTmpBuf: array[256, Value]

var jitRecompileHook*: proc(theProc: Proc) {.nimcall.} = nil
var compileProcHook*: proc(vm: Vm, theProc: Proc): ForeignProc {.nimcall.} = nil

proc jitRecompileAtO3*(theProc: Proc) {.nimcall.} =
  if theProc.jitRecompiled: return
  theProc.jitRecompiled = true
  if jitOptLevel >= 3: return
  let savedOpt = jitOptLevel
  jitOptLevel = 3
  if compileProcHook != nil:
    discard compileProcHook(jitGlobalVm, theProc)
  jitOptLevel = savedOpt

proc setJitGlobalsPtr*(p: pointer) =
  jitGlobalsPtr = p

proc setJitVm*(vm: Vm) =
  jitGlobalVm = vm

proc jitBridgePushG*(namePtr: pointer): int64 {.cdecl, exportc.} =
  let name = cast[cstring](namePtr)
  if name == nil or jitGlobalsPtr == nil: return 0
  let g = cast[ptr CritBitTree[Value]](jitGlobalsPtr)
  let key = $name
  if key notin g[]: return 0
  result = cast[int64](g[][key])

proc jitBridgePopG*(namePtr: pointer, val: int64, typeId: int32) {.cdecl, exportc.} =
  let name = cast[cstring](namePtr)
  if name == nil or jitGlobalsPtr == nil: return
  let g = cast[ptr CritBitTree[Value]](jitGlobalsPtr)
  let key = $name
  if typeId == tyInt:
    g[][key] = Value(typeId: tyInt, intVal: val)
  elif typeId == tyBool:
    g[][key] = Value(typeId: tyBool, boolVal: val != 0)
  else:
    g[][key] = cast[Value](val)

proc findProcById*(procId: int): Proc =
  if jitGlobalVm == nil: return nil
  for _, s in jitGlobalVm.importedModules:
    if procId >= 0 and procId < s.procs.len:
      return s.procs[procId]
  nil

proc jitBridgeMakeInt*(val: int64): int64 {.cdecl, exportc.} =
  result = cast[int64](Value(typeId: tyInt, intVal: val))

proc jitBridgeMakeBool*(val: bool): int64 {.cdecl, exportc.} =
  result = cast[int64](Value(typeId: tyBool, boolVal: val))

proc jitBridgeExtractInt*(valPtr: int64): int64 {.cdecl, exportc.} =
  result = cast[Value](valPtr).intVal

proc jitBridgeConstrArray*(count: int32): int64 {.cdecl, exportc.} =
  let arr = initArray(count)
  result = cast[int64](arr)

var jitProcCache: array[65536, pointer]

proc jitBridgeFastAdd*(listPtr: int64, itemVal: int64): int64 {.cdecl, exportc.} =
  cast[Value](listPtr).objectVal.fields.add(ValueStorage(typeId: tyInt, intVal: itemVal))
  0

proc jitCallProcBridgeFlat*(procId: int32, flatArgs: ptr int64, argc: int32, argTypes: ptr int32): int64 {.cdecl, exportc.} =
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
        jitBridgeTmpBuf[i] = cast[Value](arr[i])
  let callResult =
    if theProc.jitForeign != nil:
      theProc.jitForeign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    elif theProc.kind == pkForeign and theProc.foreign != nil:
      theProc.foreign(cast[StackView](addr jitBridgeTmpBuf[0]), argc)
    else:
      nil
  for i in 0..<argc:
    jitBridgeTmpBuf[i] = nil
  if callResult == nil: return 0
  case callResult.typeId
  of tyInt: return callResult.intVal
  of tyBool: return callResult.boolVal.ord.int64
  else: return 0

proc jitCallProcBridge*(procId: int32, stackIPtr: ptr int64, sp: int32, deltaPtr: ptr int32, resultIntPtr: ptr int64) {.cdecl, exportc.} =
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
