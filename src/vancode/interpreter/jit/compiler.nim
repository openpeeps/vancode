# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode
## Dispatches `compileProc` to the active JIT backend. Currently routes to
## `compiler_dynasm` for DynASM-based native code generation.

import ../[chunk, vm, value]
import ./compiler_dynasm

proc compileProc*(vm: Vm, theProc: Proc): ForeignProc =
  if theProc == nil or theProc.kind != pkNative or theProc.chunk == nil: return nil
  compiler_dynasm.compileProc(vm, theProc)

proc compileMainHookImpl*(vm: Vm, script: Script, main: Chunk): ForeignProc =
  ## Eagerly JIT-compile a main chunk so hosts can run it natively instead
  ## of interpreting. Disabled unless the host provides `vm.jit.getOutput`
  ## (the JIT cannot see interpret()'s `result` local); nil = interpret.
  if vm.jit.getOutput == nil: return nil
  let fake = Proc(name: "$main", kind: pkNative, chunk: main,
    paramCount: 0, hasResult: true, jitReturnString: true)
  fake.procId = -1
  # Lifetime anchor: the compiled closure captures `fake` as a raw pointer
  # (capturing the ref would be harmless here, but every other JIT closure
  # uses raw captures to avoid ARC-untraced cycles, so this one does too).
  # `fake` is owned by no table (procId -1 skips them) and its only other
  # owner is this frame, which returns before the caller runs the closure;
  # without an anchor the pointer would dangle. `Script.mainProc` exists
  # for exactly this and outlives the interpret() call using the closure.
  script.mainProc = fake
  compiler_dynasm.compileProc(vm, fake, isMain = true)
