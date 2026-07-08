# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import std/[locks, sysatomics, dynlib]
import pkg/threading/channels
import ../[chunk, vm, value]
import ./types, ./compiler, ./cache, ./compiler_bridge

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
  if atomicLoadN(addr p.jitCodePtr, AtomicAcquire) != nil: return
  globalBackend.channel.send(cast[ptr Proc](p))

proc worker(backend: ptr JitBackend) {.thread.} =
  let vm = cast[Vm](backend[].vmPtr)
  when defined(vancodeJitLog): stderr.writeLine "[jit] worker started"
  while true:
    when defined(vancodeJitLog): stderr.writeLine "[jit] worker waiting for channel"
    let pp = backend[].channel.recv()
    when defined(vancodeJitLog): stderr.writeLine "[jit] worker received " & (if pp == nil: "nil" else: "proc")
    if pp == nil: break
    let p = cast[Proc](pp)
    if p.kind != pkNative: continue
    if atomicLoadN(addr p.jitCodePtr, AtomicAcquire) != nil: continue
    when defined(vancodeJitLog): stderr.writeLine "[jit] worker compiling " & p.name
    let compiled = compileProc(vm, p)
    when defined(vancodeJitLog): stderr.writeLine "[jit] worker compile result: " & (if compiled != nil: "ok" else: "nil")
    if compiled != nil:
      p.jitForeign = compiled
  when defined(vancodeJitLog): stderr.writeLine "[jit] worker exiting"

proc newJitBackend*(): JitBackend =
  JitBackend(cache: newJitCache(), enabled: true)

proc jitGetForeign(procPtr: pointer): ForeignProc =
  if procPtr == nil or globalBackend == nil: return nil
  let p = cast[Proc](procPtr)
  if p.kind == pkNative:
    result = p.jitForeign  # may be nil if not compiled yet

proc detectBackend*(): JitBackendKind =
  when defined(vancodeJitLlvm):
    let lib = loadLib("libLLVM-20.dylib")
    if lib != nil:
      result = jbkLlvm
      lib.unloadLib()
    else:
      result = jbkNone
  if result == jbkNone:
    when defined(vancodeJitGcc) or defined(vancodeJit):
      result = jbkGcc
    else:
      result = jbkNone

proc installJitWithBackend*(vm: Vm, backend: JitBackendKind) =
  compiler.selectedBackend = backend
  globalBackend = newJitBackend()
  globalVm = vm
  setJitVm(vm)
  compileProcHook = compileProc
  jitRecompileHook = jitRecompileAtO3
  vm.jit = JitHooks(
    getForeign: jitGetForeign,
    setGlobalsPtr: setJitGlobalsPtr
  )

proc startAsyncJit*(vm: Vm) =
  let backend = detectBackend()
  compiler.selectedBackend = backend
  globalBackend = newJitBackend()
  globalBackend.channel.open()
  globalBackend.running = true
  globalBackend.vmPtr = cast[pointer](vm)
  globalVm = vm
  setJitVm(vm)
  compileProcHook = compileProc
  jitRecompileHook = jitRecompileAtO3
  for i in 0..<WorkerCount:
    createThread(globalBackend.workers[i], worker, addr globalBackend)
  vm.jit = JitHooks(
    getForeign: jitGetForeign,
    queueCompile: queueCompile,
    setGlobalsPtr: setJitGlobalsPtr
  )

proc installJit*(vm: Vm) =
  startAsyncJit(vm)

proc stopAsyncJit*() =
  if globalBackend == nil or not globalBackend.running: return
  globalBackend.running = false
  for i in 0..<WorkerCount:
    globalBackend.channel.send(nil)
  globalBackend.channel.close()
