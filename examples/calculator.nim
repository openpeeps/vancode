import std/[options, strutils]

import ../src/vancode/interpreter/[ast, codegen, chunk, value, vm, sym]
import ../src/vancode/interpreter/stdlib/syslib

when isMainModule:
  proc parseExpr(tokens: seq[string]): Node =
    # Recursive parser with operator precedence for +, -, *, /
    # Handles expressions like: 1 + 2 * 3 - 4 / 2

    proc parsePrimary(i: var int): Node =
      if i >= tokens.len:
        raise newException(ValueError, "Unexpected end of input.")
      let t = tokens[i]
      inc i
      try:
        if t.contains('.'):
          result = ast.newFloatLit(parseFloat(t))
        else:
          result = ast.newIntLit(parseInt(t))
      except ValueError:
        raise newException(ValueError, "Expected a number, got: '" & t & "'")

    proc precedence(op: string): int =
      case op
      of "+", "-": 1
      of "*", "/": 2
      else: -1

    proc parseBinOpRhs(i: var int, exprPrec: int, lhs: Node): Node =
      var lhs = lhs
      while i < tokens.len:
        let op = tokens[i]
        let opPrec = precedence(op)

        if opPrec < 0:
          raise newException(ValueError, "Unknown operator '" & op & "'.")
        if opPrec < exprPrec:
          break

        inc i
        var rhs = parsePrimary(i)
        # If next operator has higher precedence, parse it first
        while i < tokens.len:
          let nextOp = tokens[i]
          let nextPrec = precedence(nextOp)
          if nextPrec < 0:
            raise newException(ValueError, "Unknown operator '" & nextOp & "'.")
          if nextPrec > opPrec:
            rhs = parseBinOpRhs(i, opPrec + 1, rhs)
          else:
            break
        
        # Combine lhs and rhs into a new AST node
        lhs = ast.newTree(nkInfix, ast.newIdent(op), lhs, rhs)
      result = lhs
    
    # ain't good
    if tokens.len < 3 or tokens.len mod 2 == 0:
      raise newException(ValueError, "Usage: <int|float> <op> <int|float> [<op> <int|float>] ...")

    var i = 0
    let lhs = parsePrimary(i)
    result = parseBinOpRhs(i, 1, lhs)

    if i != tokens.len:
      raise newException(ValueError, "Unexpected token: '" & tokens[i] & "'.")

  proc evalLine(line: string) =
    let tokens = line.splitWhitespace()
    let exprAst = parseExpr(tokens)

    let astExpr = ast.newCall(ast.newIdent("echo"), exprAst)
    let astScript = Ast(
      sourcePath: "calculator-repl",
      nodes: @[astExpr]
    )

    # Setup the script and module
    let mainChunk = newChunk("calculator-repl")
    let script = newScript(mainChunk)
    let module = newModule("calculator", some("calculator"))

    module.initSystemTypes()
    script.initSystemOps(module)

    # Add an 'echo' procedure to print results, overloaded for int and float
    # basically, this is a FFI for Native Nim functions, we can add any proc we want
    # so we can build our own standard library on top of it. Crazy!
    script.addProc(module, "echo", @[paramDef("x", ttyInt)], ttyVoid,
      proc (args: StackView, argc: int): Value =
        echo args[0].intVal)

    script.addProc(module, "echo", @[paramDef("x", ttyFloat)], ttyVoid,
      proc (args: StackView, argc: int): Value =
        echo args[0].floatVal)

    # Generate bytecode for the script
    let gen = initCompiler(script, module, mainChunk, nil, nil)
    gen.genScript(astScript, none(string))

    # Execute the bytecode in the VM
    let vmInstance = newVm()
    discard vmInstance.interpret(script, mainChunk)
  
  # cli stuff
  echo "Calculator REPL. Type expressions like: 1 + 1 * 3"
  echo "Type 'exit' or 'quit' to stop."
  while true:
    stdout.write("calc> ")
    stdout.flushFile()

    var line: string
    if not stdin.readLine(line):
      break

    line = line.strip()
    if line.len == 0:
      continue
    if line == "exit" or line == "quit":
      break

    try:
      evalLine(line)
    except CatchableError as e:
      echo "Error: ", e.msg