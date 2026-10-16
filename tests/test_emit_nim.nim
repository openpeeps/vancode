import unittest
import dynasm

when defined(vancodeJitNim):
  import ../src/vancode/interpreter/jit/emit_nim

when defined(vancodeJitNim):
  type JitFn = proc(flatArgs: ptr int64, argc: int): int64 {.cdecl.}

  test "emit method body: 40 + 2 == 42":
    var s = initNimJit()
    nprologue(s.a)
    npushI(s.a, 40)
    npushI(s.a, 2)
    naddI(s.a)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 42
    buf.destroy()

  test "emit comparisons and jumps":
    var s = initNimJit()
    nprologue(s.a)
    # if 3 < 5: push 7 else push 9; the ndiscard mirrors the
    # statement-cleanup Discard codegen emits (jumpFwdF consumes the
    # bool on the taken path, pushes it back on fallthrough).
    npushI(s.a, 3)
    npushI(s.a, 5)
    nlessI(s.a)
    njumpFwdF(s.a, 0)
    ndiscard(s.a, 1)
    npushI(s.a, 7)
    njumpFwd(s.a, 1)
    ndefLabel(s.a, 0)
    npushI(s.a, 9)
    ndefLabel(s.a, 1)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 7
    buf.destroy()

  test "emit fib standalone: fib(10) == 55":
    var s = initNimJit()
    nfib(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    var cell: int64 = 10
    check f(addr cell, 0) == 55
    cell = 0
    check f(addr cell, 0) == 0
    cell = 1
    check f(addr cell, 0) == 1
    buf.destroy()

  test "emit locals roundtrip":
    var s = initNimJit()
    nprologue(s.a)
    npushI(s.a, 11)
    npopL(s.a, 2)
    npushL(s.a, 2)
    nincL(s.a, 2)
    npushL(s.a, 2)
    naddI(s.a)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    var locals = newSeq[int64](4)
    check f(addr locals[0], 0) == 23
    check locals[2] == 12
    buf.destroy()
else:
  test "nim jit disabled":
    skip()
