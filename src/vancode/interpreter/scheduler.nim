## Coroutine scheduler with worker thread pool.

import std/locks
import ./[vm, value, chunk]

type
  SchedMsgKind* = enum
    smtCoroutine
    smtStop

  SchedMsgObj* = object
    kind*: SchedMsgKind
    coroutine*: Coroutine

  SchedulerConfig* = object
    threadCount*: int
    channelSize*: int

  CompletedObj* = object
    coro*: Coroutine
    res*: CoroutineResult

  CoroutineScheduler* = ref object
    threadCount*: int
    threads: seq[Thread[tuple[threadIdx: int, sched: CoroutineScheduler]]]
    readyQueue: Channel[pointer]
    completedQueue: Channel[pointer]
    shutdownLock: Lock
    running: bool

proc newCoroutineScheduler*(config: SchedulerConfig): CoroutineScheduler =
  new(result)
  result.threadCount = config.threadCount
  result.threads = newSeq[Thread[tuple[threadIdx: int, sched: CoroutineScheduler]]](config.threadCount)
  if config.channelSize > 0:
    result.readyQueue.open(config.channelSize)
    result.completedQueue.open(config.channelSize)
  else:
    result.readyQueue.open()
    result.completedQueue.open()
  initLock(result.shutdownLock)
  result.running = true

proc workerFunc(arg: tuple[threadIdx: int, sched: CoroutineScheduler]) {.thread.} =
  let vm = newVm()
  let sched = arg.sched
  while true:
    var p: pointer
    withLock sched.shutdownLock:
      if not sched.running:
        break
    try:
      p = sched.readyQueue.recv()
    except:
      break
    if p == nil:
      break
    let msg = cast[ptr SchedMsgObj](p)
    # copy and free
    let kind = msg[].kind
    let coro = if kind == smtCoroutine: msg[].coroutine else: nil
    dealloc(msg)
    if kind == smtStop:
      break
    if coro == nil:
      break
    let coroResult =
      try:
        stepCoroutine(vm, coro)
      except:
        CoroutineResult(kind: crErrored, errorMsg: getCurrentExceptionMsg())
    let outPtr = cast[ptr CompletedObj](alloc0(sizeof(CompletedObj)))
    outPtr[].coro = coro
    outPtr[].res = coroResult
    try: sched.completedQueue.send(cast[pointer](outPtr)) except: discard
    if coroResult.kind == crYielded:
      let redoPtr = cast[ptr SchedMsgObj](alloc0(sizeof(SchedMsgObj)))
      redoPtr[].kind = smtCoroutine
      redoPtr[].coroutine = coro
      try: sched.readyQueue.send(cast[pointer](redoPtr)) except: discard

proc start*(sched: CoroutineScheduler) =
  for i in 0..<sched.threadCount:
    createThread(sched.threads[i], workerFunc, (i, sched))

proc stop*(sched: CoroutineScheduler) =
  withLock sched.shutdownLock:
    sched.running = false
  for i in 0..<sched.threadCount:
    let p = cast[ptr SchedMsgObj](alloc0(sizeof(SchedMsgObj)))
    p[].kind = smtStop
    try: sched.readyQueue.send(cast[pointer](p)) except: discard
  for i in 0..<sched.threadCount:
    joinThread(sched.threads[i])
  sched.readyQueue.close()
  sched.completedQueue.close()
  deinitLock(sched.shutdownLock)

proc schedule*(sched: CoroutineScheduler, coro: Coroutine) =
  let p = cast[ptr SchedMsgObj](alloc0(sizeof(SchedMsgObj)))
  p[].kind = smtCoroutine
  p[].coroutine = coro
  try: sched.readyQueue.send(cast[pointer](p)) except: discard

proc receive*(sched: CoroutineScheduler, timeout: int = -1):
    tuple[coro: Coroutine, result: CoroutineResult] =
  let p = sched.completedQueue.recv()
  let msg = cast[ptr CompletedObj](p)
  result = (msg[].coro, msg[].res)
  dealloc(msg)

proc tryReceive*(sched: CoroutineScheduler):
    tuple[dataAvailable: bool, msg: (Coroutine, CoroutineResult)] =
  let (ok, p) = sched.completedQueue.tryRecv()
  if ok:
    let msg = cast[ptr CompletedObj](p)
    result = (true, (msg[].coro, msg[].res))
    dealloc(msg)
  else:
    result = (false, (nil, CoroutineResult(kind: crErrored)))
