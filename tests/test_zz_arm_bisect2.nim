## TEMPORARY ARM execution bisect, part 2: ring-load shape alone in its
## own process, so its crash signal is independent of the branch tests.
## Delete after diagnosis (with test_zz_arm_bisect.nim).
import unittest
import std/strutils
import dynasm

when defined(vancodeJitNim):
  import ../src/vancode/interpreter/value
  import ../src/vancode/interpreter/jit/jit_values
  import ../src/vancode/interpreter/jit/emit_nim
  import ../src/vancode/interpreter/jit/compiler_bridge

when defined(vancodeJitNim):
  type JitFn = proc(flatArgs: ptr int64, argc: int): int64 {.cdecl.}

  test "bisect t5 ring load":
    stderr.writeLine("[bisect] t5 assemble")
    stderr.flushFile()
    let arr = initArray(2)
    arr.objectVal.fields[0] = ValueStorage(typeId: tyInt, intVal: 111)
    arr.objectVal.fields[1] = ValueStorage(typeId: tyInt, intVal: 222)
    let tag = jitRootValue(arr)
    var s = initNimJit()
    nprologue(s.a)
    npushL(s.a, 0)
    npushI(s.a, 1)
    ngetI(s.a, jitGetItemSlow,
      (tyAny.int32 or (tyInt.int32 shl 8)).int32, 8101)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    var locals = @[tag]
    stderr.writeLine("[bisect] t5 call")
    stderr.flushFile()
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(addr locals[0], 1) == 222
    buf.destroy()
else:
  test "nim jit disabled":
    skip()
