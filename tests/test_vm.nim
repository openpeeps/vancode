import unittest
import std/[monotimes, times, math]
import ../src/vancode/interpreter/[ast, chunk, value, vm, sym]
when defined(vancodeJitDynasm):
  import ../src/vancode/interpreter/jit/jit

suite "hotCode":
  test "hot proc counter increments on each call":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(1'i64)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "hot", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    chunk.emit(opcCallD)
    chunk.emit(chunk.getString("test"))
    chunk.emit(uint16(0))
    chunk.emit(opcHalt)

    let prefs = VMPreferences(enableHotCodeDetection: true, hotProcThreshold: 5)
    let vm = newVirtualMachine(prefs)

    discard vm.interpret(script, chunk)
    check vm.getHotProcCount("hot") == 1
    discard vm.interpret(script, chunk)
    discard vm.interpret(script, chunk)
    check vm.getHotProcCount("hot") == 3

  test "hot code detection disabled does not count":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(1'i64)
    procChunk.emit(opcReturnVal)
    script.procs.add(Proc(name: "nocount", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    chunk.emit(opcCallD)
    chunk.emit(chunk.getString("test"))
    chunk.emit(uint16(0))
    chunk.emit(opcHalt)

    let vm = newVm()
    discard vm.interpret(script, chunk)
    discard vm.interpret(script, chunk)
    check vm.getHotProcCount("nocount") == 0

  test "hot proc threshold reached":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(7'i64)
    procChunk.emit(opcReturnVal)
    script.procs.add(Proc(name: "threshold", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    chunk.emit(opcCallD)
    chunk.emit(chunk.getString("test"))
    chunk.emit(uint16(0))
    chunk.emit(opcHalt)

    let prefs = VMPreferences(enableHotCodeDetection: true, hotProcThreshold: 3)
    let vm = newVirtualMachine(prefs)

    discard vm.interpret(script, chunk)
    discard vm.interpret(script, chunk)
    check vm.getHotProcCount("threshold") == 2

    discard vm.interpret(script, chunk)
    check vm.getHotProcCount("threshold") == 3

when defined(vancodeJitDynasm):
  suite "JIT":
    test "JIT module initializes and compiles a trivial proc":
      var chunk = newChunk("jit_test")
      let script = newScript(chunk)

      var procChunk = newChunk("jit_test")
      procChunk.emit(opcReturnVoid)
      script.procs.add(Proc(name: "void_jit", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: false))

      let vm = newVm()
      let jitBackend = newJitBackend()
      let compiled = jitBackend.compileProc(vm, script.procs[0])
      if compiled == nil:
        echo "  [SKIP] libgccjit not available"
      else:
        check compiled != nil

    test "JIT compile returns nil for nil proc":
      let vm = newVm()
      let jitBackend = newJitBackend()
      let compiled = jitBackend.compileProc(vm, nil)
      check compiled == nil

    test "JIT with PopL (write-then-read local)":
      # Proc: inc(x): x = x + 1; return x
      var c = newChunk("jit_test")
      let s = newScript(c)
      var p = newChunk("jit_test")
      p.emit(opcPushL); p.emit(0'u8)
      p.emit(opcPushI); p.emit(1'i64)
      p.emit(opcAddI)
      p.emit(opcPopL); p.emit(0'u8)
      p.emit(opcPushL); p.emit(0'u8)
      p.emit(opcReturnVal)
      s.procs.add(Proc(name: "inc", kind: pkNative,
        chunk: p, paramCount: 1, hasResult: true))
      c.emit(opcCallD); c.emit(c.getString("jit_test"))
      c.emit(uint16(0)); c.emit(opcHalt)

      let vm3 = newVm()
      let jitBackend3 = newJitBackend()
      let compiled3 = jitBackend3.compileProc(vm3, s.procs[0])
      check compiled3 != nil

      s.procs.add(Proc(name: "inc_jit", kind: pkForeign,
        foreign: compiled3, paramCount: 1, hasResult: true))
      var jc = newChunk("jit_test")
      jc.emit(opcPushI); jc.emit(5'i64)
      jc.emit(opcCallD); jc.emit(jc.getString("jit_test"))
      jc.emit(uint16(1)); jc.emit(opcHalt)
      let result = vm3.interpret(s, jc)
      check result.typeId == tyInt

    test "installJit hooks into VM":
      let prefs = VMPreferences(enableHotCodeDetection: true, hotProcThreshold: 3)
      let vm = newVirtualMachine(prefs)
      vm.installJit()
      check vm.jit.getForeign != nil

    test "JIT closure produces correct value":
      # Direct closure call bypasses all VM machinery
      var procChunk = newChunk("jit_correct")
      procChunk.emit(opcPushI); procChunk.emit(42'i64)
      procChunk.emit(opcReturnVal)
      let p = Proc(name: "jit_correct", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true)

      let vm = newVm()
      let jit = newJitBackend()
      let compiled = jit.compileProc(vm, p)
      check compiled != nil

      let r = compiled(nil, 0)
      check r.typeId == tyInt
      check r.intVal == 42

    test "JIT fast path via p.jitForeign in opcCallD":
      # Set p.jitForeign manually, then call through interpret
      var chunk = newChunk("jit_fastpath")
      let script = newScript(chunk)
      var procChunk = newChunk("jit_fastpath")
      procChunk.emit(opcPushI); procChunk.emit(7'i64)
      procChunk.emit(opcReturnVal)
      script.procs.add(Proc(name: "jit_fastpath", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true))
      chunk.emit(opcCallD); chunk.emit(chunk.getString("jit_fastpath"))
      chunk.emit(uint16(0)); chunk.emit(opcHalt)

      let vm = newVm()
      let jit = newJitBackend()
      let compiled = jit.compileProc(vm, script.procs[0])
      check compiled != nil

      script.procs[0].jitForeign = compiled

      let vm2 = newVm()
      let r = vm2.interpret(script, chunk)
      check r.typeId == tyInt
      check r.intVal == 7

    test "JIT via installJit + jitGetForeign + interpret":
      # Pre-compile via the JIT hook, then interpret
      var chunk = newChunk("jit_hook")
      let script = newScript(chunk)
      var procChunk = newChunk("jit_hook")
      procChunk.emit(opcPushI); procChunk.emit(55'i64)
      procChunk.emit(opcReturnVal)
      script.procs.add(Proc(name: "jit_hook", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true))
      chunk.emit(opcCallD); chunk.emit(chunk.getString("jit_hook"))
      chunk.emit(uint16(0)); chunk.emit(opcHalt)

      let vm = newVm()
      vm.installJit()

      let compiled = vm.jit.getForeign(cast[pointer](script.procs[0]))
      check compiled != nil
      check script.procs[0].jitForeign != nil

      let r = vm.interpret(script, chunk)
      check r.typeId == tyInt
      check r.intVal == 55

    test "JIT hot path with threshold via installJit":
      # Verify the end-to-end: hot code detection -> JIT -> fast path
      var chunk = newChunk("jit_hotpath")
      let script = newScript(chunk)
      var procChunk = newChunk("jit_hotpath")
      procChunk.emit(opcPushI); procChunk.emit(99'i64)
      procChunk.emit(opcReturnVal)
      script.procs.add(Proc(name: "jit_hotpath", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true))
      chunk.emit(opcCallD); chunk.emit(chunk.getString("jit_hotpath"))
      chunk.emit(uint16(0)); chunk.emit(opcHalt)

      let prefs = VMPreferences(enableHotCodeDetection: true, hotProcThreshold: 2)
      let vm = newVirtualMachine(prefs)
      vm.installJit()

      # Pre-compile via jitGetForeign (what markHotProc does)
      discard vm.jit.getForeign(cast[pointer](script.procs[0]))
      check script.procs[0].jitForeign != nil

      let r = vm.interpret(script, chunk)
      check r.typeId == tyInt
      check r.intVal == 99

    test "JIT compile + call in same interpret (crash repro)":
      # Trigger JIT via hot threshold inside interpret, then immediately take fast path
      var chunk = newChunk("jit_crash")
      let script = newScript(chunk)
      var procChunk = newChunk("jit_crash")
      procChunk.emit(opcPushI); procChunk.emit(42'i64)
      procChunk.emit(opcReturnVal)
      script.procs.add(Proc(name: "jit_crash", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true))
      chunk.emit(opcCallD); chunk.emit(chunk.getString("jit_crash"))
      chunk.emit(uint16(0)); chunk.emit(opcHalt)

      let prefs = VMPreferences(enableHotCodeDetection: true, hotProcThreshold: 2)
      let vm = newVirtualMachine(prefs)
      vm.installJit()

      # First call: hot count = 1, no JIT
      let r1 = vm.interpret(script, chunk)
      check r1.typeId == tyInt
      check r1.intVal == 42

      # Second call: hot count = 2, triggers JIT + fast path in same interpret
      let r2 = vm.interpret(script, chunk)
      check r2.typeId == tyInt
      check r2.intVal == 42

suite "perf":
  let perfIter = 100_000

  test "interpreted (simple return)":
    var chunk = newChunk("perf")
    let script = newScript(chunk)
    var procChunk = newChunk("perf")
    procChunk.emit(opcPushI)
    procChunk.emit(42'i64)
    procChunk.emit(opcReturnVal)
    script.procs.add(Proc(name: "simple", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))
    chunk.emit(opcCallD); chunk.emit(chunk.getString("perf"))
    chunk.emit(uint16(0)); chunk.emit(opcHalt)

    let vm = newVm()
    for i in 0..<100: discard vm.interpret(script, chunk)
    let t = getMonoTime()
    for i in 0..<perfIter: discard vm.interpret(script, chunk)
    let e = getMonoTime() - t
    echo "  interpreted (simple return)  ", e.inMicroseconds, " us (", e.inNanoseconds div perfIter, " ns/call)"

  test "interpreted (arithmetic 100 adds)":
    var chunk = newChunk("perf")
    let script = newScript(chunk)
    var procChunk = newChunk("perf")
    for i in 0..<100:
      procChunk.emit(opcPushI); procChunk.emit(i.int64)
    for i in 0..<100:
      procChunk.emit(opcPushI); procChunk.emit(i.int64)
      procChunk.emit(opcAddI)
    procChunk.emit(opcReturnVal)
    script.procs.add(Proc(name: "arith", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))
    chunk.emit(opcCallD); chunk.emit(chunk.getString("perf"))
    chunk.emit(uint16(0)); chunk.emit(opcHalt)

    let vm = newVm()
    for i in 0..<100: discard vm.interpret(script, chunk)
    let t = getMonoTime()
    for i in 0..<perfIter: discard vm.interpret(script, chunk)
    let e = getMonoTime() - t
    echo "  interpreted (arithmetic 100)  ", e.inMicroseconds, " us (", e.inNanoseconds div perfIter, " ns/call)"

  when defined(vancodeJitDynasm):
    test "JIT (simple return)":
      var chunk = newChunk("perf")
      let script = newScript(chunk)
      var procChunk = newChunk("perf")
      procChunk.emit(opcPushI); procChunk.emit(42'i64)
      procChunk.emit(opcReturnVal)
      script.procs.add(Proc(name: "simple", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true))
      chunk.emit(opcCallD); chunk.emit(chunk.getString("perf"))
      chunk.emit(uint16(0)); chunk.emit(opcHalt)

      let vm = newVm()
      let jit = newJitBackend()
      let compiled = jit.compileProc(vm, script.procs[0])
      if compiled == nil:
        echo "  JIT (simple return)           SKIP (no gccjit)"
      else:
        script.procs.add(Proc(name: "simple_jit", kind: pkForeign,
          foreign: compiled, paramCount: 0, hasResult: true))
        var jitChunk = newChunk("perf")
        jitChunk.emit(opcCallD); jitChunk.emit(jitChunk.getString("perf"))
        jitChunk.emit(uint16(1)); jitChunk.emit(opcHalt)
        for i in 0..<100: discard vm.interpret(script, jitChunk)
        let t = getMonoTime()
        for i in 0..<perfIter: discard vm.interpret(script, jitChunk)
        let e = getMonoTime() - t
        echo "  JIT (simple return)           ", e.inMicroseconds, " us (", e.inNanoseconds div perfIter, " ns/call)"

    test "JIT (arithmetic 100 adds)":
      var chunk = newChunk("perf")
      let script = newScript(chunk)
      var procChunk = newChunk("perf")
      for i in 0..<100:
        procChunk.emit(opcPushI); procChunk.emit(i.int64)
      for i in 0..<100:
        procChunk.emit(opcPushI); procChunk.emit(i.int64)
        procChunk.emit(opcAddI)
      procChunk.emit(opcReturnVal)
      script.procs.add(Proc(name: "arith", kind: pkNative,
        chunk: procChunk, paramCount: 0, hasResult: true))
      chunk.emit(opcCallD); chunk.emit(chunk.getString("perf"))
      chunk.emit(uint16(0)); chunk.emit(opcHalt)

      let vm = newVm()
      let jit = newJitBackend()
      let compiled = jit.compileProc(vm, script.procs[0])
      if compiled == nil:
        echo "  JIT (arithmetic 100)          SKIP (no gccjit)"
      else:
        script.procs.add(Proc(name: "arith_jit", kind: pkForeign,
          foreign: compiled, paramCount: 0, hasResult: true))
        var jitChunk = newChunk("perf")
        jitChunk.emit(opcCallD); jitChunk.emit(jitChunk.getString("perf"))
        jitChunk.emit(uint16(1)); jitChunk.emit(opcHalt)
        for i in 0..<100: discard vm.interpret(script, jitChunk)
        let t = getMonoTime()
        for i in 0..<perfIter: discard vm.interpret(script, jitChunk)
        let e = getMonoTime() - t
        echo "  JIT (arithmetic 100)          ", e.inMicroseconds, " us (", e.inNanoseconds div perfIter, " ns/call)"
