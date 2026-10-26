import unittest
import std/[options, tables]
import ../src/vancode/interpreter/[ast, codegen, chunk, value, vm, sym]
import ../src/vancode/interpreter/stdlib/syslib
import ../src/vancode/interpreter/stdlib/utils

proc newEnv(file = "test"): tuple[script: Script, module: Module, chunk: Chunk, gen: CodeGen] =
  let c = newChunk(file)
  let s = newScript(c)
  let m = newModule(file, some(file))
  m.initSystemTypes()
  s.initSystemOps(m)
  let g = initCompiler(s, m, c, nil, nil)
  g.allowExprResult = true
  (s, m, c, g)

suite "addVar":
  test "exported bool const is visible and has the host value":
    let e = newEnv()
    e.script.addVar(e.module, "windows", ttyBool, initValue(true))
    check "windows" in e.module.exportVariables
    let ast = Ast(sourcePath: "test", nodes: @[newIdent("windows")])
    e.gen.genScript(ast, none(string))
    check $newVm().interpret(e.script, e.chunk) == "true"

  test "false value round-trips":
    let e = newEnv()
    e.script.addVar(e.module, "linux", ttyBool, initValue(false))
    let ast = Ast(sourcePath: "test", nodes: @[newIdent("linux")])
    e.gen.genScript(ast, none(string))
    check $newVm().interpret(e.script, e.chunk) == "false"

  test "unexported var stays out of exportVariables":
    let e = newEnv()
    e.script.addVar(e.module, "priv", ttyBool, initValue(true), exportSym = false)
    check "priv" notin e.module.exportVariables
