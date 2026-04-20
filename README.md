<p align="center">
  <img src="https://github.com/openpeeps/vancode/blob/main/.github/vancode.png" width="200px"><br>
  A flexible AST, Codegen and Virtual Machine library<br>
  for building your own toy language, scripting engines and DSLs.
</p>

<p align="center">
  <code>nimble install vancode</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/vancode">API reference</a><br>
  <img src="https://github.com/openpeeps/vancode/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/vancode/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About
VanCode is a tiny library for building bytecode interpreters and virtual machines in Nim. It provides a simple and efficient way to define and execute bytecode instructions, making it easier to create custom programming languages, scripting engines and DSLs (domain-specific languages).

This is a _bring-your-own-parsing_ library, so it doesn't come with a built-in Parser or Lexer. When implementing your own Parser you must use the [VanCode AST](https://openpeeps.github.io/vancode/vancode/interpreter/ast.html) provided by the library. No worries, most of the AST is pretty self-explanatory and easy to use.

It's also pretty flexible so you can easily extend it with your own custom nodes via Nim's macro system at compile-time without having to modify the library's source code.

## 😍 Key Features
- [x] Bring-your-own Lexer and Parser for maximum flexibility
- [x] Built-in AST (Abstract Syntax Tree) representation
- [x] Simple and efficient bytecode instruction definition and execution
- [x] Support for multiple data types and operations
- [ ] FFI for calling Nim code or external libraries
- [ ] Generate self-contained executables
- [ ] JIT (Just-In-Time) compilation for improved performance
- [ ]  (Ahead-Of-Time) compilation for static binaries
- [ ] Built-in package manager for easy distribution and installation
- [x] Written in Nim language

> [!NOTE]
> VanCode is far from being a complete solution, I'm planning to add more features and improvements as I go, while still learning about how to design a good flexible interpreter and VM.

## Examples
Let's showcase some cool examples!

### Calculator example

Here is a simple calculator example that demonstrates how to use VanCode to construct the AST for a simple expression, pass it trough the code generator to produce bytecode, and then execute it in the VM.

```nim
import std/options
import vancode/interpreter/[ast, codegen, chunk, value, vm, sym]
import vancode/interpreter/stdlib/syslib

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
```

👉 Check the [examples/calculator.nim](https://github.com/openpeeps/vancode/blob/main/examples/calculator.nim) for a more complete REPL implementation of the calculator example.

## Extend AST, Codegen and VM with Voodoo
VanCode provides a powerful and flexible way to extend the AST, Codegen and VM with your own custom nodes, instructions and operations using Nim's macro system.

For a full example of how to use Voodoo to extend the AST, Codegen and VM, check the [Tim Engine](https://github.com/openpeeps/tim/blob/main/src/tim/engine/transformers.nim) transformers module.


## Projects using VanCode
- [Tim Engine](https://github.com/openpeeps/tim) - A beautiful template engine and DSL for generating HTML templates

## Roadmap
- [ ] AOT/JIT compilation using [gccjit](https://github.com/openpeeps/gccjit.nim) bindings
- [ ] Self-contained executable generation (Similar to how Node/Bun generate self-contained executables)
- [ ] VM Hot code optimization
- [ ] Add more Voodoo flexibility and extensibility features to the AST, Codegen and VM

Notes:
- https://vivekn.dev/blog/bytecode-vm-scratch/
- https://github.com/liquidev/hayago - VanCode contains work from hayago, a very interesting project that is no longer maintained but provides a good reference for Nim-based bytecode VMs. Cheers to the author! 😻

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/vancode/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/vancode/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
LGPLv3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
