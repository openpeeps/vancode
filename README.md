<p align="center">
  <img src="https://github.com/openpeeps/PKG/blob/main/.github/logo.png" width="90px"><br>
  OpenPeeps repository template for developing libraries,<br>projects and other cool things. 👑 Written in Nim language
</p>

<p align="center">
  <code>nimble install vancode</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/vancode">API reference</a><br>
  <img src="https://github.com/openpeeps/vancode/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/vancode/workflows/docs/badge.svg" alt="Github Actions">
</p>

## About
Vancode is a tiny library for building bytecode interpreters and virtual machines in Nim. It provides a simple and efficient way to define and execute bytecode instructions, making it easier to create custom programming languages, scripting engines and DSLs (domain-specific languages).

> [!NOTE]
> Vancode contains work from [hayago](https://github.com/liquidev/hayago), a very interesting project that is no longer maintained but had a good starting point so I decided to bring it back to life and work on it while still learning about, bytecode VMs and interpreter desing in general.

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

## Examples

Vancode is a bring-your-own-parsing library, so it doesn't come with a built-in Parser or Lexer. When impplementing your own Parser you must use the VanCode AST provided by the library. No worries, most of the AST is pretty self-explanatory and easy to use. It's also pretty flexible so you can easily extend it with your own custom nodes via Nim's macro system at compile-time without having to modify the library's source code.

The AST provides a macro-like API for constructing nodes, so you can easily create nodes like this:

```nim
import vancode/interpreter/ast

var node = ast.newIntLit(10)
```

> [!NOTE]
> Vancode is far from being a complete solution, I'm planning to add more features and improvements as I go, while still learning about how to design a good flexible interpreter and VM.

## Projects using Vancode
- [Tim Engine](https://github.com/openpeeps/tim) - A beautiful template engine and DSL for generating HTML templates

## Roadmap
- [ ] AOT/JIT compilation using [gccjit](https://github.com/openpeeps/gccjit.nim) bindings
- [ ] Self-contained executable generation (Similar to how Node/Bun generate self-contained executables)
- [ ] VM Hot code optimization
- [ ] Add more Voodoo flexibility and extensibility features to the AST, Codegen and VM

Notes:
- https://vivekn.dev/blog/bytecode-vm-scratch/
- https://github.com/liquidev/hayago

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/vancode/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/vancode/fork)
- 😎 [Get €20 in cloud credits from Hetzner](https://hetzner.cloud/?ref=Hm0mYGM9NxZ4)

### 🎩 License
LGPLv3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
