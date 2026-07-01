# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ../[chunk, vm, value]
import ./types, ./compiler, ./cache

type
  JitBackend* = ref object
    cache*: cache.JitCache
    enabled*: bool

var globalBackend: JitBackend = nil
var globalVm*: Vm = nil

proc newJitBackend*(): JitBackend =
  JitBackend(cache: newJitCache(), enabled: true)

proc compileProc*(jit: JitBackend, vm: Vm, theProc: Proc): ForeignProc =
  if theProc == nil: return nil
  jit.cache.getOrCompile(vm, theProc)

proc jitGetForeign(procPtr: pointer): ForeignProc =
  if procPtr == nil or globalBackend == nil: return nil
  let p = cast[Proc](procPtr)
  if p.kind == pkNative and p.jitForeign == nil:
    let compiled = globalBackend.cache.getOrCompile(globalVm, p)
    if compiled != nil:
      p.jitForeign = compiled
      result = compiled

proc installJit*(vm: Vm) =
  globalBackend = newJitBackend()
  globalVm = vm
  vm.jit = JitHooks(getForeign: jitGetForeign)
