# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ./vancode/interpreter/[ast, codegen, chunk, value, vm, sym, policy, manager, resolver]
import ./vancode/interpreter/stdlib/[syslib, utils]
import ./vancode/interpreter/cache/fbe as fbeCache

export policy, manager, resolver, fbeCache
when defined(nimdocs):
  export ast, codegen, chunk, value, vm, sym
  export syslib, utils