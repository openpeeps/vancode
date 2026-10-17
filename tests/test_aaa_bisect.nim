## TEMPORARY ARM bisect, part 3 (delete after diagnosis).
## Runs FIRST alphabetically so its signals survive even if a later
## file hangs. Isolates the nfib hang: fib(0) takes the early-return
## branch, fib(1) falls through with zero loop laps, fib(2) runs one
## lap (backward branch), and t6 derefs flatArgs with no branches.
import unittest
import dynasm

when defined(vancodeJitNim):
  import ../src/vancode/interpreter/jit/emit_nim

when defined(vancodeJitNim):
  type JitFn = proc(flatArgs: ptr int64, argc: int): int64 {.cdecl.}

  proc mark(s: string) =
    stderr.writeLine("[bisect3] " & s)
    stderr.flushFile()

  test "bisect3 t6 args deref":
    mark("t6 assemble")
    var s = initNimJit()
    nprologue(s.a)
    npushL(s.a, 0)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    var cell: int64 = 12345
    mark("t6 call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(addr cell, 0) == 12345
    buf.destroy()

  test "bisect3 t7a fib zero":
    mark("t7a assemble")
    var s = initNimJit()
    nfib(s.a)
    var buf = nimJitFinish(s)
    var cell: int64 = 0
    mark("t7a call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(addr cell, 0) == 0
    buf.destroy()

  test "bisect3 t7b fib one":
    mark("t7b assemble")
    var s = initNimJit()
    nfib(s.a)
    var buf = nimJitFinish(s)
    var cell: int64 = 1
    mark("t7b call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(addr cell, 0) == 1
    buf.destroy()

  test "bisect3 t7c fib two":
    mark("t7c assemble")
    var s = initNimJit()
    nfib(s.a)
    var buf = nimJitFinish(s)
    var cell: int64 = 2
    mark("t7c call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(addr cell, 0) == 1
    buf.destroy()
else:
  test "nim jit disabled":
    skip()
