# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import std/[locks, sysatomics]
import pkg/threading/channels
import ../[chunk, vm, value]
import ./types, ./compiler, ./cache

const WorkerCount* = 4

type
  JitBackend* = ref object
    cache*: cache.JitCache
    enabled*: bool
    workers: array[WorkerCount, Thread[ptr JitBackend]]
    channel: Channel[ptr Proc]
    running: bool
    vmPtr: pointer

var globalBackend {.global.}: JitBackend = nil
var globalVm {.global.}: Vm = nil

proc queueCompile(theProcPtr: pointer) =
  if globalBackend == nil or not globalBackend.running: return
  let p = cast[Proc](theProcPtr)
  if p == nil: return
  # Atomic check: skip if already compiled (either sync or async)
  if atomicLoadN(addr p.jitCodePtr, AtomicAcquire) != nil: return
  globalBackend.channel.send(cast[ptr Proc](p))

proc worker(backend: ptr JitBackend) {.thread.} =
  let vm = cast[Vm](backend[].vmPtr)
  while true:
    let pp = backend[].channel.recv()
    if pp == nil: break
    let p = cast[Proc](pp)
    if p.kind != pkNative: continue
    # Double-check: skip if already compiled (e.g., by sync JIT or another worker)
    if atomicLoadN(addr p.jitCodePtr, AtomicAcquire) != nil: continue
    discard compileProc(vm, p)

proc newJitBackend*(): JitBackend =
  JitBackend(cache: newJitCache(), enabled: true)

proc jitGetForeign(procPtr: pointer): ForeignProc =
  if procPtr == nil or globalBackend == nil: return nil
  let p = cast[Proc](procPtr)
  if p.kind == pkNative and p.jitForeign == nil:
    let compiled = compileProc(globalVm, p)
    if compiled != nil:
      p.jitForeign = compiled
      result = compiled

proc installJit*(vm: Vm) =
  globalBackend = newJitBackend()
  globalVm = vm
  compiler.setJitVm(vm)
  vm.jit = JitHooks(getForeign: jitGetForeign)

proc startAsyncJit*(vm: Vm) =
  globalBackend = newJitBackend()
  globalBackend.channel.open()
  globalBackend.running = true
  globalBackend.vmPtr = cast[pointer](vm)
  globalVm = vm
  compiler.setJitVm(vm)
  for i in 0..<WorkerCount:
    createThread(globalBackend.workers[i], worker, addr globalBackend)
  vm.jit = JitHooks(
    getForeign: jitGetForeign,
    queueCompile: queueCompile
  )

proc stopAsyncJit*() =
  if globalBackend == nil or not globalBackend.running: return
  globalBackend.running = false
  for i in 0..<WorkerCount:
    globalBackend.channel.send(nil)
  globalBackend.channel.close()
