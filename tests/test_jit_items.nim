import unittest
import std/tables
import dynasm

when defined(vancodeJitNim):
  import ../src/vancode/interpreter/value
  import ../src/vancode/interpreter/vm
  import ../src/vancode/interpreter/jit/jit_values
  import ../src/vancode/interpreter/jit/jit_layout
  import ../src/vancode/interpreter/jit/emit_nim
  import ../src/vancode/interpreter/jit/compiler_bridge

when defined(vancodeJitNim):
  type JitFn = proc(flatArgs: ptr int64, argc: int): int64 {.cdecl.}

  proc voidSentinelBridge(procId: int32, flatArgs: ptr int64, argc: int32,
      argTypes: ptr int32): int64 {.cdecl.} =
    ## Void-call stand-in: returns a sentinel that must never surface.
    result = 999

  test "layout consts match live objects":
    let arr = initArray(3)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 11)
    arr.objectVal.fields[1] = ValueStorage(typeId: tyInt, intVal: 22)
    arr.objectVal.fields[2] = ValueStorage(typeId: tyBool, boolVal: true)
    let base = cast[int](addr(arr[]))
    # Value tag at +0
    check (cast[ptr int64](base + offValType))[] == tyArrayObject
    # Object pointer at +8
    let objp = (cast[ptr int](base + offValObj))[]
    check objp == cast[int](addr(arr.objectVal[]))
    # isForeign byte at +0 of Object
    check (cast[ptr byte](objp + offObjForeign))[] == 0
    # Seq value slot: inline length at +0, block pointer at +8
    let fslot = cast[int](addr(arr.objectVal.fields))
    check fslot == objp + offObjFields
    check (cast[ptr int64](fslot + seqLenOff))[] == 3
    let blk = (cast[ptr int](fslot + seqPtrOff))[]
    check blk != 0
    # Element 0 starts 8 past the block pointer
    check cast[int](addr(arr.objectVal.fields[0])) == blk + blockDataOff
    let e0 = blk + blockDataOff
    check (cast[ptr int64](e0 + offVsType))[] == tyInt
    check (cast[ptr int64](e0 + offVsInt))[] == 11
    check (cast[ptr int64](e0 + sizeVs + offVsInt))[] == 22
    check (cast[ptr int64](e0 + 2 * sizeVs + offVsType))[] == tyBool

  test "ngetI fast path loads int element":
    let arr = initArray(2)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 111)
    arr.objectVal.fields[1] = ValueStorage(typeId: tyInt, intVal: 222)
    let tag = jitRootValue(arr)
    var s = initNimJit()
    nprologue(s.a)
    npushL(s.a, 0)
    npushI(s.a, 1)
    ngetI(s.a, jitGetItemSlow, (tyAny.int32 or (tyInt.int32 shl 8)).int32, 7001)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    var locals = @[tag]
    check f(addr locals[0], 1) == 222
    buf.destroy()

  test "ngetI slow path raises like the interpreter":
    let arr = initArray(1)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 9)
    let tag = jitRootValue(arr)
    var s = initNimJit()
    nprologue(s.a)
    npushL(s.a, 0)
    npushI(s.a, 5)
    ngetI(s.a, jitGetItemSlow, (tyAny.int32 or (tyInt.int32 shl 8)).int32, 7002)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    var locals = @[tag]
    expect IndexDefect:
      discard f(addr locals[0], 1)
    buf.destroy()

  test "nsetI fast path stores int element":
    let arr = initArray(2)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 1)
    arr.objectVal.fields[1] = ValueStorage(typeId: tyInt, intVal: 2)
    let tag = jitRootValue(arr)
    var s = initNimJit()
    nprologue(s.a)
    npushL(s.a, 0)
    npushI(s.a, 0)
    npushI(s.a, 42)
    nsetI(s.a, jitSetItemSlow,
      (tyAny.int32 or (tyInt.int32 shl 8) or (tyInt.int32 shl 16)).int32, 7003)
    npushI(s.a, 7)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    var locals = @[tag]
    check f(addr locals[0], 1) == 7
    check arr.objectVal.fields[0].intVal == 42
    check arr.objectVal.fields[0].typeId == tyInt
    buf.destroy()

  test "nsetI unknown value kind takes the slow bridge":
    let arr = initArray(1)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 1)
    let tag = jitRootValue(arr)
    var s = initNimJit()
    nprologue(s.a)
    npushL(s.a, 0)
    npushI(s.a, 0)
    npushTrue(s.a)
    # value kind unknown -> slow bridge; raw true (1) boxes as tyInt:
    # documented convention, same as the untyped CallD bridge
    nsetI(s.a, jitSetItemSlow,
      (tyAny.int32 or (tyInt.int32 shl 8) or (tyAny.int32 shl 16)).int32, 7004)
    npushI(s.a, 0)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    var locals = @[tag]
    discard f(addr locals[0], 1)
    check arr.objectVal.fields[0].typeId == tyInt
    buf.destroy()

  test "slow bridges match interpreter semantics":
    let arr = initArray(2)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 5)
    let tag = jitRootValue(arr)
    check jitGetItemSlow(tag, 0,
      (tyAny.int32 or (tyInt.int32 shl 8)).int32) == 5
    expect IndexDefect:
      discard jitGetItemSlow(tag, 9,
        (tyAny.int32 or (tyInt.int32 shl 8)).int32)
    # non-array container raises FieldDefect like opcGetI
    expect FieldDefect:
      discard jitGetItemSlow(7, 0,
        (tyInt.int32 or (tyInt.int32 shl 8)).int32)
    discard jitSetItemSlow(tag, 1, 77,
      (tyAny.int32 or (tyInt.int32 shl 8) or (tyInt.int32 shl 16)).int32)
    check arr.objectVal.fields[1].intVal == 77
    check arr.objectVal.fields[1].typeId == tyInt

  test "global bridges roundtrip live vm.globals":
    let vm = newVm()
    setJitVm(vm)
    vm.globals["gnum"] = initValue(41i64)
    check jitBridgePushG(jitImmortalStr("gnum")) == 41
    jitBridgePopG(jitImmortalStr("gnum"), 42, tyInt.int32)
    check vm.globals["gnum"].intVal == 42
    let arr = initArray(1)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 7)
    vm.globals["garr"] = arr
    let t = jitBridgePushG(jitImmortalStr("garr"))
    let (rv, rok) = jitTryUnroot(t)
    check rok
    check rv == arr
    # the pushed tag feeds GetI directly (the hot-loop shape)
    check jitGetItemSlow(t, 0,
      (tyAny.int32 or (tyInt.int32 shl 8)).int32) == 7
    # missing keys raise like the interpreter's opcPushG
    expect KeyError:
      discard jitBridgePushG(jitImmortalStr("g-missing"))

  test "npushG npopG emitters roundtrip a global":
    let vmA = newVm()
    setJitVm(vmA)
    vmA.globals["xg"] = initValue(10i64)
    var s = initNimJit()
    nprologue(s.a)
    npushG(s.a, jitImmortalStr("xg"), cast[pointer](jitBridgePushG))
    npushI(s.a, 5)
    naddI(s.a)
    npopG(s.a, jitImmortalStr("xg"), cast[pointer](jitBridgePopG),
      tyInt.int32)
    npushG(s.a, jitImmortalStr("xg"), cast[pointer](jitBridgePushG))
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 15
    check vmA.globals["xg"].intVal == 15
    buf.destroy()

  test "void calls leave no phantom slot behind":
    var s = initNimJit()
    nprologue(s.a)
    npushI(s.a, 10)
    npushI(s.a, 20)
    emitCallArgsNim(s.a, 2)
    ncallInvokeTyped(s.a, 2, 0, cast[pointer](voidSentinelBridge),
      jitImmortalTypes([tyInt.int32, tyInt.int32]))
    ncallFinishVoid(s.a, jitCallDropBytes(2))
    npushI(s.a, 1)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    # with the pushing finish the sentinel 999 would surface instead of 1
    check f(nil, 0) == 1
    buf.destroy()
else:
  test "jit items disabled":
    skip()
