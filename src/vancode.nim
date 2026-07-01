# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ./vancode/interpreter/[ast, codegen, chunk, value, vm, sym]
import ./vancode/interpreter/stdlib/[syslib, utils]

when defined(vancodeJit):
  import ./vancode/interpreter/jit/jit

when defined(nimdocs):
  export ast, codegen, chunk, value, vm, sym
  export syslib, utils
  when defined(vancodeJit):
    export jit