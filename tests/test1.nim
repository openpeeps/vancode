import unittest

import ../src/vancode/interpreter/[ast, chunk, value, vm, sym, scheduler]
import std/critbits

suite "coroutines":
  test "create coroutine and resume with return value":
    # Proc: identity(x: int): int = x
    # Main: coro identity(42) -> result should be 42
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)

    # Build the proc's chunk
    var procChunk = newChunk("test")
    procChunk.emit(opcPushL)
    procChunk.emit(0'u8)
    procChunk.emit(opcReturnVal)

    let theProc = Proc(
      name: "identity", kind: pkNative,
      chunk: procChunk, paramCount: 1, hasResult: true
    )
    script.procs.add(theProc) # pid = 0

    # Build the main chunk
    mainChunk.emit(opcPushI)
    mainChunk.emit(42'i64)
    mainChunk.emit(opcCreateCoro)
    mainChunk.emit(uint16(0))
    mainChunk.emit(opcCoroResume)
    mainChunk.emit(opcHalt)

    let vmInstance = newVm()
    let result = vmInstance.interpret(script, mainChunk)
    check result.typeId == tyInt
    check result.intVal == 42

  test "coroutine with yield and resume":
    # Proc: generator(x: int): int = yield 10; return x
    # Main: coro generator(99) -> first resume yields 10, second resume returns 99
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)

    # Build the proc's chunk
    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(10'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushL)
    procChunk.emit(0'u8)
    procChunk.emit(opcReturnVal)

    let theProc = Proc(
      name: "generator", kind: pkNative,
      chunk: procChunk, paramCount: 1, hasResult: true
    )
    script.procs.add(theProc) # pid = 0

    # Build the main chunk:
    #   coro = createCoro(generator)
    #   resume coro(99)           -> yields 10
    #   resume coro               -> returns 99
    mainChunk.emit(opcPushI)
    mainChunk.emit(99'i64)
    mainChunk.emit(opcCreateCoro)
    mainChunk.emit(uint16(0))
    mainChunk.emit(opcPopG)
    mainChunk.emit(mainChunk.getString("co"))
    # First resume
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume) # yields 10, stack: [10]
    mainChunk.emit(opcDiscard)
    mainChunk.emit(1'u8)
    # Second resume
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume) # returns 99
    mainChunk.emit(opcHalt)

    let vmInstance = newVm()
    let result = vmInstance.interpret(script, mainChunk)
    check result.typeId == tyInt
    check result.intVal == 99

  test "multiple yields (generator pattern)":
    # Proc: yields 1, 2, 3, returns 4
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(1'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(2'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(3'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(4'i64)
    procChunk.emit(opcReturnVal)

    let theProc = Proc(
      name: "multi", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true
    )
    script.procs.add(theProc)

    # Main: store coroutine, then 4 resumes (3 yields + 1 return)
    mainChunk.emit(opcCreateCoro)
    mainChunk.emit(uint16(0))
    mainChunk.emit(opcPopG)
    mainChunk.emit(mainChunk.getString("co"))
    for i in 0..<3:
      mainChunk.emit(opcPushG)
      mainChunk.emit(mainChunk.getString("co"))
      mainChunk.emit(opcCoroResume)
      mainChunk.emit(opcDiscard)
      mainChunk.emit(1'u8)
    # Fourth resume returns 4
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume)
    mainChunk.emit(opcHalt)

    let vmInstance = newVm()
    let result = vmInstance.interpret(script, mainChunk)
    check result.typeId == tyInt
    check result.intVal == 4

  test "void coroutine (no return value)":
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcReturnVoid)

    let theProc = Proc(
      name: "voidProc", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: false
    )
    script.procs.add(theProc)

    mainChunk.emit(opcCreateCoro)
    mainChunk.emit(uint16(0))
    mainChunk.emit(opcCoroResume)
    mainChunk.emit(opcHalt)

    let vmInstance = newVm()
    let result = vmInstance.interpret(script, mainChunk)
    check result.typeId == tyNil

  test "coroutine can call other procs":
    # Proc: calls a helper that returns 10, yields that, returns
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)

    # Helper proc: returns 10
    var helperChunk = newChunk("test")
    helperChunk.emit(opcPushI)
    helperChunk.emit(10'i64)
    helperChunk.emit(opcReturnVal)
    let helperProc = Proc(
      name: "helper", kind: pkNative,
      chunk: helperChunk, paramCount: 0, hasResult: true
    )
    script.procs.add(helperProc) # pid = 0

    # Coroutine proc: calls helper, yields the result, returns 99
    var coroChunk = newChunk("test")
    coroChunk.emit(opcCallD)
    coroChunk.emit(coroChunk.getString("test"))
    coroChunk.emit(uint16(0))
    coroChunk.emit(opcCoroYield)
    coroChunk.emit(opcPushI)
    coroChunk.emit(99'i64)
    coroChunk.emit(opcReturnVal)
    let coroProc = Proc(
      name: "coroProc", kind: pkNative,
      chunk: coroChunk, paramCount: 0, hasResult: true
    )
    script.procs.add(coroProc) # pid = 1

    mainChunk.emit(opcCreateCoro)
    mainChunk.emit(uint16(1))
    mainChunk.emit(opcPopG)
    mainChunk.emit(mainChunk.getString("co"))
    # First resume yields 10
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume)
    mainChunk.emit(opcDiscard)
    mainChunk.emit(1'u8)
    # Second resume returns 99
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume)
    mainChunk.emit(opcHalt)

    let vmInstance = newVm()
    let result = vmInstance.interpret(script, mainChunk)
    check result.typeId == tyInt
    check result.intVal == 99

  test "resume completed coroutine raises error":
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(7'i64)
    procChunk.emit(opcReturnVal)

    let theProc = Proc(
      name: "simple", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true
    )
    script.procs.add(theProc)

    mainChunk.emit(opcCreateCoro)
    mainChunk.emit(uint16(0))
    mainChunk.emit(opcPopG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume)  # returns 7
    mainChunk.emit(opcPopG)
    mainChunk.emit(mainChunk.getString("tmp"))
    mainChunk.emit(opcPushG)
    mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcCoroResume)  # error: already completed
    mainChunk.emit(opcHalt)

    let vmInstance = newVm()
    expect ValueError:
      discard vmInstance.interpret(script, mainChunk)

  test "yield outside coroutine raises error":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    chunk.emit(opcPushI)
    chunk.emit(5'i64)
    chunk.emit(opcCoroYield)  # error: not in a coroutine
    chunk.emit(opcHalt)

    let vmInstance = newVm()
    expect ValueError:
      discard vmInstance.interpret(script, chunk)

suite "stepCoroutine":
  test "step coroutine from created state (no yield)":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(42'i64)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "simple", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    let vm = newVm()
    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
    let result = stepCoroutine(vm, coro)
    check result.kind == crCompleted
    check result.resultValue.intVal == 42

  test "step coroutine yield and complete":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(10'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(99'i64)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "yielder", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    let vm = newVm()
    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)

    # First step: should yield 10
    let r1 = stepCoroutine(vm, coro)
    check r1.kind == crYielded
    check r1.yieldedValue.intVal == 10
    check coro.state == csSuspended

    # Second step: should complete with 99
    let r2 = stepCoroutine(vm, coro)
    check r2.kind == crCompleted
    check r2.resultValue.intVal == 99
    check coro.state == csCompleted

  test "step coroutine with args":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushL)
    procChunk.emit(0'u8)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "identity", kind: pkNative,
      chunk: procChunk, paramCount: 1, hasResult: true))

    let vm = newVm()
    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
    coro.savedStack = @[initValue(7i64)]
    coro.savedStackBottom = 0

    let result = stepCoroutine(vm, coro)
    check result.kind == crCompleted
    check result.resultValue.intVal == 7

  test "step coroutine void return":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcReturnVoid)

    script.procs.add(Proc(name: "voidProc", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: false))

    let vm = newVm()
    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
    let result = stepCoroutine(vm, coro)
    check result.kind == crCompleted
    check result.resultValue.typeId == tyNil

  test "step coroutine invalid state":
    let vm = newVm()
    let coro = Coroutine(state: csRunning, callee: nil, script: nil)
    let result = stepCoroutine(vm, coro)
    check result.kind == crErrored

suite "scheduler":
  test "schedule and complete a single coroutine":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(42'i64)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "simple", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
    let sched = newCoroutineScheduler(SchedulerConfig(threadCount: 2))
    sched.start()
    sched.schedule(coro)

    let (doneCoro, result) = sched.receive()
    check result.kind == crCompleted
    check result.resultValue.intVal == 42

    sched.stop()

  test "schedule multiple coroutines":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushL)
    procChunk.emit(0'u8)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "identity", kind: pkNative,
      chunk: procChunk, paramCount: 1, hasResult: true))

    let coroCount = 10
    var coros: seq[Coroutine]
    for i in 1..coroCount:
      let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
      coro.savedStack = @[initValue(i.int64)]
      coro.savedStackBottom = 0
      coros.add(coro)

    let sched = newCoroutineScheduler(SchedulerConfig(threadCount: 4))
    sched.start()
    for coro in coros:
      sched.schedule(coro)

    var results: seq[int]
    for i in 0..<coroCount:
      let (doneCoro, result) = sched.receive()
      check result.kind == crCompleted
      results.add(result.resultValue.intVal)

    sched.stop()
    check results.len == coroCount
    var s = 0; for r in results: s += r
    check s == (coroCount * (coroCount + 1) div 2)

  test "scheduler with yielding coroutine":
    var chunk = newChunk("test")
    let script = newScript(chunk)

    var procChunk = newChunk("test")
    procChunk.emit(opcPushI)
    procChunk.emit(1'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(2'i64)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "yielder", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
    let sched = newCoroutineScheduler(SchedulerConfig(threadCount: 2))
    sched.start()
    sched.schedule(coro)

    # First result: yield (1)
    let (c1, r1) = sched.receive()
    check r1.kind == crYielded
    check r1.yieldedValue.intVal == 1

    # Second result: completed (2)
    let (c2, r2) = sched.receive()
    check r2.kind == crCompleted
    check r2.resultValue.intVal == 2

    sched.stop()

