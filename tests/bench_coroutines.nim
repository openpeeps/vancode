import std/[monotimes, times, os]

import ../src/vancode/interpreter/[chunk, value, vm, scheduler]

const
  iterations = 100_000
  generatorYields = 1000
  largeStackSize = 50

proc main() =
  echo "=== VanCode Coroutine Benchmarks ==="
  echo ""

  #
  # 1. Baseline: direct opcCallD, no coroutine
  #
  block:
    echo "--- 1. Baseline: opcCallD (direct call, no coroutine) ---"
    var chunk = newChunk("bench")
    chunk.emit(opcPushI)
    chunk.emit(42'i64)
    chunk.emit(opcCallD)
    chunk.emit(chunk.getString("bench"))
    chunk.emit(uint16(0))
    chunk.emit(opcHalt)

    var procChunk = newChunk("bench")
    procChunk.emit(opcPushI)
    procChunk.emit(42'i64)
    procChunk.emit(opcReturnVal)

    let script = newScript(chunk)
    script.procs.add(Proc(name: "base", kind: pkNative, chunk: procChunk, paramCount: 0, hasResult: true))
    let vm = newVm()
    vm.prewarmScriptOps(script)

    for i in 0..<1000:
      discard vm.interpret(script, chunk)
    let start = getMonoTime()
    for i in 0..<iterations:
      discard vm.interpret(script, chunk)
    let elapsed = getMonoTime() - start
    let avgNs = elapsed.inNanoseconds div iterations
    echo "  opcCallD (return value)               ", avgNs, " ns/op  (", elapsed.inMilliseconds, " ms total over ", iterations, " iters)"

  #
  # 2. Create + resume (no yield, proc returns a value)
  #
  block:
    echo "--- 2. Create + resume (no yield) ---"
    var chunk = newChunk("bench")
    chunk.emit(opcCreateCoro)
    chunk.emit(uint16(0))
    chunk.emit(opcCoroResume)
    chunk.emit(opcHalt)

    var procChunk = newChunk("bench")
    procChunk.emit(opcPushI)
    procChunk.emit(42'i64)
    procChunk.emit(opcReturnVal)

    let script = newScript(chunk)
    script.procs.add(Proc(name: "fast", kind: pkNative, chunk: procChunk, paramCount: 0, hasResult: true))
    let vm = newVm()
    vm.prewarmScriptOps(script)

    for i in 0..<1000:
      discard vm.interpret(script, chunk)
    let start = getMonoTime()
    for i in 0..<iterations:
      discard vm.interpret(script, chunk)
    let elapsed = getMonoTime() - start
    let avgNs = elapsed.inNanoseconds div iterations
    echo "  create + resume (return)              ", avgNs, " ns/op  (", elapsed.inMilliseconds, " ms total over ", iterations, " iters)"

  #
  # 3. Yield + resume cycle
  #
  block:
    echo "--- 3. Yield + resume cycle ---"
    var chunk = newChunk("bench")
    chunk.emit(opcCreateCoro)
    chunk.emit(uint16(0))
    chunk.emit(opcPopG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcPushG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcCoroResume)
    chunk.emit(opcDiscard)
    chunk.emit(1'u8)
    chunk.emit(opcPushG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcCoroResume)
    chunk.emit(opcHalt)

    var procChunk = newChunk("bench")
    procChunk.emit(opcPushI)
    procChunk.emit(1'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(99'i64)
    procChunk.emit(opcReturnVal)

    let script = newScript(chunk)
    script.procs.add(Proc(name: "yielder", kind: pkNative, chunk: procChunk, paramCount: 0, hasResult: true))
    let vm = newVm()
    vm.prewarmScriptOps(script)

    for i in 0..<1000:
      discard vm.interpret(script, chunk)
    let start = getMonoTime()
    for i in 0..<iterations:
      discard vm.interpret(script, chunk)
    let elapsed = getMonoTime() - start
    let avgNs = elapsed.inNanoseconds div iterations
    echo "  yield + resume cycle                  ", avgNs, " ns/op  (", elapsed.inMilliseconds, " ms total over ", iterations, " iters)"

  #
  # 4. Generator throughput (N yields per coroutine)
  #
  block:
    echo "--- 4. Generator throughput (", generatorYields, " yields per coroutine) ---"
    var chunk = newChunk("bench")
    chunk.emit(opcCreateCoro)
    chunk.emit(uint16(0))
    chunk.emit(opcPopG)
    chunk.emit(chunk.getString("co"))
    for i in 0..<generatorYields:
      chunk.emit(opcPushG)
      chunk.emit(chunk.getString("co"))
      chunk.emit(opcCoroResume)
      chunk.emit(opcDiscard)
      chunk.emit(1'u8)
    chunk.emit(opcPushG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcCoroResume)
    chunk.emit(opcHalt)

    var procChunk = newChunk("bench")
    for i in 1..generatorYields:
      procChunk.emit(opcPushI)
      procChunk.emit(i.int64)
      procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(9999'i64)
    procChunk.emit(opcReturnVal)

    let script = newScript(chunk)
    script.procs.add(Proc(name: "gen", kind: pkNative, chunk: procChunk, paramCount: 0, hasResult: true))
    let vm = newVm()
    vm.prewarmScriptOps(script)

    let genIters = iterations div 10
    for i in 0..<100:
      discard vm.interpret(script, chunk)
    let start = getMonoTime()
    for i in 0..<genIters:
      discard vm.interpret(script, chunk)
    let elapsed = getMonoTime() - start
    let totalYields = genIters * generatorYields
    let yieldsPerSec = totalYields * 1000 div max(elapsed.inMilliseconds, 1)
    echo "  generator (", generatorYields, " yields)             ", elapsed.inNanoseconds div genIters, " ns/op  (", elapsed.inMilliseconds, " ms, ", totalYields, " total yields, ", yieldsPerSec, " yields/sec)"

  #
  # 5. Large stack save/restore
  #
  block:
    echo "--- 5. Large stack save/restore (", largeStackSize, " values on stack during yield) ---"
    var chunk = newChunk("bench")
    chunk.emit(opcCreateCoro)
    chunk.emit(uint16(0))
    chunk.emit(opcPopG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcPushG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcCoroResume)
    chunk.emit(opcDiscard)
    chunk.emit(uint8(largeStackSize + 1))
    chunk.emit(opcPushG)
    chunk.emit(chunk.getString("co"))
    chunk.emit(opcCoroResume)
    chunk.emit(opcHalt)

    var procChunk = newChunk("bench")
    for i in 1..largeStackSize:
      procChunk.emit(opcPushI)
      procChunk.emit(i.int64)
    procChunk.emit(opcPushI)
    procChunk.emit(99'i64)
    procChunk.emit(opcCoroYield)
    procChunk.emit(opcReturnVoid)

    let script = newScript(chunk)
    script.procs.add(Proc(name: "bigstack", kind: pkNative, chunk: procChunk, paramCount: 0, hasResult: false))
    let vm = newVm()
    vm.prewarmScriptOps(script)

    for i in 0..<1000:
      discard vm.interpret(script, chunk)
    let start = getMonoTime()
    for i in 0..<iterations:
      discard vm.interpret(script, chunk)
    let elapsed = getMonoTime() - start
    let avgNs = elapsed.inNanoseconds div iterations
    echo "  yield with ", largeStackSize, " stack values            ", avgNs, " ns/op  (", elapsed.inMilliseconds, " ms total over ", iterations, " iters)"

  #
  # 6. Scheduler overhead & parallel speedup
  #
  block:
    let schedCoroutines = 4
    let schedYields = 100
    echo "--- 6. Scheduler throughput (", schedCoroutines, " coroutines, ", schedYields, " yields each) ---"
    var chunk = newChunk("bench")
    let script = newScript(chunk)

    var procChunk = newChunk("bench")
    for i in 1..schedYields:
      procChunk.emit(opcPushI)
      procChunk.emit(i.int64)
      procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI)
    procChunk.emit(9999'i64)
    procChunk.emit(opcReturnVal)

    script.procs.add(Proc(name: "schedProc", kind: pkNative,
      chunk: procChunk, paramCount: 0, hasResult: true))

    let totalResults = schedCoroutines * (schedYields + 1)

    # Sequential baseline: stepCoroutine one after another
    var coros: seq[Coroutine]
    for i in 0..<schedCoroutines:
      coros.add(Coroutine(state: csCreated, callee: script.procs[0], script: script))
    let seqVm = newVm()
    let seqStart = getMonoTime()
    for i in 0..<schedCoroutines:
      while coros[i].state != csCompleted:
        discard stepCoroutine(seqVm, coros[i])
    let seqElapsed = getMonoTime() - seqStart
    echo "  sequential (stepCoroutine)            ", seqElapsed.inMilliseconds, " ms total (", totalResults, " yields + completions)"

    # Scheduler with varying thread counts
    for threads in [1, 2]:
      var scoros: seq[Coroutine]
      for i in 0..<schedCoroutines:
        scoros.add(Coroutine(state: csCreated, callee: script.procs[0], script: script))
      let sched = newCoroutineScheduler(SchedulerConfig(threadCount: threads, channelSize: 2048))
      let schedStart = getMonoTime()
      sched.start()
      for c in scoros:
        sched.schedule(c)
      var received = 0
      while received < totalResults:
        discard sched.receive()
        inc received
      sched.stop()
      let schedElapsed = getMonoTime() - schedStart
      let speedup = seqElapsed.inNanoseconds.float / schedElapsed.inNanoseconds.float
      let speedupInt = (speedup * 100).int
      echo "  scheduler (", threads, " threads)               ", schedElapsed.inMilliseconds, " ms total (", totalResults, " results, ", speedupInt div 100, ".", (speedupInt mod 100 + 5) div 10, "x speedup)"
    sleep(100)

  echo ""
  echo "Done."

main()
