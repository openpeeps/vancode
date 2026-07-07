# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode
#
# This module dispatches compileProc to the active JIT backend.

import ../[chunk, vm, value]
import ./compiler_bridge

type JitBackendKind* = enum
  jbkNone
  jbkGcc
  jbkLlvm

var selectedBackend*: JitBackendKind = jbkNone

when defined(vancodeJitGcc) or defined(vancodeJit):
  from ./compiler_gcc import nil

when defined(vancodeJitLlvm):
  from ./compiler_llvm import nil

proc compileProc*(vm: Vm, theProc: Proc): ForeignProc =
  case selectedBackend
  of jbkGcc:
    when defined(vancodeJitGcc) or defined(vancodeJit):
      compiler_gcc.compileProc(vm, theProc)
    else:
      nil
  of jbkLlvm:
    when defined(vancodeJitLlvm):
      compiler_llvm.compileProc(vm, theProc)
    else:
      nil
  of jbkNone:
    nil
