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
  if theProc.kind != pkNative or theProc.chunk == nil: return nil
  compiler_dynasm.compileProc(vm, theProc)
