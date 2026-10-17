## TEMPORARY ARM execution bisect 3a: the void cross-proc call shape
## from test_jit_items ("void calls leave no phantom slot behind"), the
## first test with no [OK] in the macos-15 SIGBUS log. Delete after
## diagnosis (with test_zz_arm_bisect3b.nim).
import unittest
import dynasm

when defined(vancodeJitNim):
  import ../src/vancode/interpreter/value
  import ../src/vancode/interpreter/jit/jit_values
  import ../src/vancode/interpreter/jit/emit_nim
  import ../src/vancode/interpreter/jit/compiler_bridge

when defined(vancodeJitNim):
  type JitFn = proc(flatArgs: ptr int64, argc: int): int64 {.cdecl.}

  proc voidSentinelBridge(procId: int32, flatArgs: ptr int64, argc: int32,
      argTypes: ptr int32): int64 {.cdecl.} =
    result = 999

  test "bisect3a void cross-proc call":
    stderr.writeLine("[bisect3a] assemble")
    stderr.flushFile()
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
    stderr.writeLine("[bisect3a] call")
    stderr.flushFile()
    check f(nil, 0) == 1
    stderr.writeLine("[bisect3a] returned ok")
    stderr.flushFile()
    buf.destroy()
else:
  test "nim jit disabled":
    skip()
