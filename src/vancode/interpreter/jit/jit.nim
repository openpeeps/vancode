# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

## Top-level JIT orchestration for VanCode. Provides automatic detection of
## procedures with recursive-arithmetic patterns and compiles them iteratively
## to native code. Coordinates the compiler, cache, and bridge subsystems.
import pkg/threading/channels
import std/tables
import ../[chunk, vm, value]
import ./compiler, ./cache, ./compiler_bridge, ./compiler_trace, ./trace_types, ./jit_mem, ./dynasm/wrapper

var globalBackend {.global.}: pointer = nil
var globalVm {.global.}: Vm = nil

proc detectRecursiveAndCompile*(vm: Vm; enableJit: bool = true) =
  if not enableJit: return
  for scriptPath in keys(vm.importedModules):
    let s = vm.importedModules[scriptPath]
    for p in s.procs:
      if p.kind == pkNative and p.chunk != nil and p.jitForeign == nil:
        let cached = vm.getCachedOps(p.chunk)
        if cached != nil and hasBinaryRecursiveArith(cached):
          let code = compileRecursiveIterative(cached)
          if code != nil:
            let nLocals = p.paramCount
            type JitFn = proc (locals: ptr int64, count: cint): int64 {.cdecl.}
            p.jitForeign = proc (args: StackView, argc: int): Value {.closure.} =
              var flatLocals = newSeq[int64](max(nLocals, 1))
              for i in 0..<min(argc, nLocals):
                if args[i].typeId == tyInt:
                  flatLocals[i] = args[i].intVal
                else:
                  flatLocals[i] = 0
              let fn = cast[JitFn](code)
              let resultI = fn(addr flatLocals[0], argc.cint)
              result = initValue(resultI)

proc installJit*(vm: Vm) =
  globalBackend = cast[pointer](1)
  globalVm = vm
  setJitVm(vm)
  compileProcHook = compileProc
  jitRecompileHook = nil
  vm.jit = JitHooks(
    getForeign: nil,
    queueCompile: nil,
    setGlobalsPtr: setJitGlobalsPtr,
    compileTrace: proc (trace: pointer): pointer =
      let tb = cast[TraceBuffer](trace)
      result = compileTrace(vm, tb)
  )
