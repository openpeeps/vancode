import std/options

import ../src/vancode/interpreter/[ast, codegen, chunk, value, vm, sym]
import ../src/vancode/interpreter/stdlib/syslib

# 1. Build the AST for: 1 + 2 * 3
let astExpr =
  ast.newCall(
    ast.newIdent("echo"),
    ast.newTree(nkInfix,
      ast.newIdent("+"),
      ast.newIntLit(1),
      ast.newTree(nkInfix,
        ast.newIdent("*"),
        ast.newIntLit(2),
        ast.newIntLit(3)
      )
    )
  )

# 2. Wrap in a script AST node
let astScript = Ast(
  sourcePath: "calculator",
  nodes: @[astExpr]
)

# 3. Prepare codegen context
let mainChunk = newChunk("calculator")
let script = newScript(mainChunk)

let module = newModule("calculator", some("calculator"))
block init_system_module:
  module.initSystemTypes()
  script.initSystemOps(module)

  # Adding a FFI proc for `echo` so we can see the output of the calculation
  script.addProc(module, "echo", @[paramDef("x", ttyInt)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo args[0].intVal)

  script.addProc(module, "echo", @[paramDef("x", ttyFloat)], ttyVoid,
    proc (args: StackView, argc: int): Value =
      echo args[0].floatVal)

# 4. Generate bytecode from AST
let gen = initCompiler(script, module, mainChunk, nil, nil)
gen.genScript(astScript, none(string))

# 5. Run in the VM
let vmInstance = newVm()
discard vmInstance.interpret(script, mainChunk)
