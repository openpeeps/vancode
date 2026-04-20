# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# Powered by Nim.
#
# (c) iLiquid, 2019-2020
#     https://github.com/liquidev/
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import ../[chunk, ast, sym, value]

import ./utils
export utils

proc initSystemOps*(script: Script, module: Module) =
  ## Add builtin operations into the module

  # bool operators
  script.addProc(module, "not", @[paramDef("x", ttyBool)], ttyBool)
  script.addProc(module, "==", @[paramDef("a", ttyBool), paramDef("b", ttyBool)], ttyBool)
  script.addProc(module, "!=", @[paramDef("a", ttyBool), paramDef("b", ttyBool)], ttyBool)

  # number type operators

  for T in [(ttyInt, ttyFloat), (ttyFloat, ttyInt)]:
    script.addProc(module, "+", @[paramDef("a", T[0])], T[0])
    script.addProc(module, "-", @[paramDef("a", T[0])], T[0])
    
    script.addProc(module, "+", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyFloat)
    script.addProc(module, "-", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyFloat)
    script.addProc(module, "*", @[paramDef("X", T[0]), paramDef("b", T[1])], ttyFloat)
    script.addProc(module, "/", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyFloat)
  
    script.addProc(module, "==", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, "!=", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, "<", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, "<=", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, ">", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, ">=", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)

  for T in [(ttyInt, ttyInt), (ttyFloat, ttyFloat)]:
    script.addProc(module, "+=", @[paramDef("a", T[0], mut = true), paramDef("b", T[1])], ttyVoid)
    script.addProc(module, "-=", @[paramDef("a", T[0], mut = true), paramDef("b", T[1])], ttyVoid)
    script.addProc(module, "*=", @[paramDef("a", T[0], mut = true), paramDef("b", T[1])], ttyVoid)
    script.addProc(module, "/=", @[paramDef("a", T[0], mut = true), paramDef("b", T[1])], ttyVoid)

    script.addProc(module, ">=", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, "<=", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, ">",  @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
    script.addProc(module, "<",  @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool)
  
  script.addProc(module, "==", @[paramDef("a", ttyBool), paramDef("b", ttyBool)], ttyBool)
  script.addProc(module, "!=", @[paramDef("a", ttyBool), paramDef("b", ttyBool)], ttyBool)
