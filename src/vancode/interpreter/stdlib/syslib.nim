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
  script.addProc(module, "is", @[paramDef("x", ttyString)], ttyBool)

  # support for strings
  script.addProc(module, "==", @[paramDef("a", ttyBool), paramDef("b", ttyBool)], ttyBool)
  script.addProc(module, "==", @[paramDef("a", ttyString), paramDef("b", ttyString)], ttyBool)
  
  script.addProc(module, "!=", @[paramDef("a", ttyBool), paramDef("b", ttyBool)], ttyBool)
  script.addProc(module, "!=", @[paramDef("a", ttyString), paramDef("b", ttyString)], ttyBool)

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

  # is / isnot — value equality comparison (infix)
  let isImpl = proc (args: StackView; argc: int): Value =
    if args[0].typeId != args[1].typeId:
      return initValue(false)
    case args[0].typeId
    of tyBool: result = initValue(args[0].boolVal == args[1].boolVal)
    of tyInt: result = initValue(args[0].intVal == args[1].intVal)
    of tyFloat: result = initValue(args[0].floatVal == args[1].floatVal)
    of tyString: result = initValue(args[0].stringVal == args[1].stringVal)
    else: result = initValue(false)
  let isnotImpl = proc (args: StackView; argc: int): Value =
    result = isImpl(args, argc)
    result.boolVal = not result.boolVal

  for T in [(ttyInt, ttyInt), (ttyInt, ttyFloat), (ttyFloat, ttyInt), (ttyFloat, ttyFloat),
            (ttyString, ttyString), (ttyBool, ttyBool)]:
    script.addProc(module, "is", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool, impl = isImpl)
    script.addProc(module, "isnot", @[paramDef("a", T[0]), paramDef("b", T[1])], ttyBool, impl = isnotImpl)
