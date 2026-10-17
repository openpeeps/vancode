## TEMPORARY ARM execution bisect (delete after diagnosis).
## Each test prints a stderr marker BEFORE the risky call and goldens the
## committed bytes against clang-verified values, so the CI log shows
## whether a crash is byte-divergence or execution-environment.
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

  proc mark(s: string) =
    stderr.writeLine("[bisect] " & s)
    stderr.flushFile()

  proc words(buf: ExecutableBuffer): seq[uint32] =
    let bytes = buf.toSeq()
    for i in 0 ..< bytes.len div 4:
      result.add(uint32(bytes[i*4]) or (uint32(bytes[i*4+1]) shl 8) or
        (uint32(bytes[i*4+2]) shl 16) or (uint32(bytes[i*4+3]) shl 24))

  test "bisect t1 prologue push ret":
    mark("t1 assemble")
    var s = initNimJit()
    nprologue(s.a)
    npushI(s.a, 7)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    mark("t1 call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 7
    buf.destroy()

  test "bisect t2 less only":
    mark("t2 assemble")
    var s = initNimJit()
    nprologue(s.a)
    npushI(s.a, 3)
    npushI(s.a, 5)
    nlessI(s.a)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    mark("t2 call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 1
    buf.destroy()

  test "bisect t3 full cond stream":
    # Byte-identical to test_emit_nim "emit comparisons and jumps".
    mark("t3 assemble")
    var s = initNimJit()
    nprologue(s.a)
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
    let got = words(buf)
    for i, w in got:
      mark("t3 word " & $i & " 0x" & w.toHex(8))
    when defined(arm64):
      # Clang-verified goldens (41 words). A mismatch here means the
      # on-runner assembler diverges; a match means bytes are exonerated
      # and the fault is execution-environment.
      const want: array[41, uint32] = [0xA9BD7BFD'u32, 0x910003FD'u32,
        0xF9000BF3'u32, 0xF9000FF4'u32, 0xAA0003F3'u32, 0xD2800069'u32,
        0xF2A00009'u32, 0xD3607D29'u32, 0x9360FD29'u32, 0xF81F0FE9'u32,
        0xD28000A9'u32, 0xF2A00009'u32, 0xD3607D29'u32, 0x9360FD29'u32,
        0xF81F0FE9'u32, 0xF84107E9'u32, 0xF84107EA'u32, 0xEB09015F'u32,
        0x1A9FA7E9'u32, 0xF81F0FE9'u32, 0xF84107E9'u32, 0xF100013F'u32,
        0x54000140'u32, 0xF81F0FE9'u32, 0xD2800209'u32, 0x8B0903FF'u32,
        0xD28000E9'u32, 0xF2A00009'u32, 0xD3607D29'u32, 0x9360FD29'u32,
        0xF81F0FE9'u32, 0x14000006'u32, 0xD2800129'u32, 0xF2A00009'u32,
        0xD3607D29'u32, 0x9360FD29'u32, 0xF81F0FE9'u32, 0xF84107E0'u32,
        0xA94153F3'u32, 0xA8C37BFD'u32, 0xD65F03C0'u32]
      check got.len == want.len
      for i in 0 ..< want.len:
        check got[i] == want[i]
    mark("t3 call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 7
    buf.destroy()

  test "bisect t4 fwd cond taken":
    mark("t4 assemble")
    var s = initNimJit()
    nprologue(s.a)
    npushI(s.a, 0)
    njumpFwdF(s.a, 0)
    ndiscard(s.a, 1)
    npushI(s.a, 7)
    njumpFwd(s.a, 1)
    ndefLabel(s.a, 0)
    npushI(s.a, 9)
    ndefLabel(s.a, 1)
    nreturnVal(s.a)
    var buf = nimJitFinish(s)
    mark("t4 call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(nil, 0) == 9
    buf.destroy()

  test "bisect t5 ring load":
    mark("t5 assemble")
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
    mark("t5 call")
    let f = cast[JitFn](buf.ptrAt(AssemblyOffset(0)))
    check f(addr locals[0], 1) == 222
    buf.destroy()
else:
  test "nim jit disabled":
    skip()
