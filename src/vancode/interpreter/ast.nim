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

## This module defines the AST (Abstract Syntax Tree) data structures used by the
## VanCode interpreter. The AST is fully extensible, allowing for easy addition
## of new node kinds and fields without modifying existing code
## 
## The AST is designed to be simple and flexible, with a focus on ease of use and
## extensibility. It supports a wide range of node kinds, including literals,
## expressions, statements, and declarations.
## 
## Each node can have an arbitrary number of child nodes, which are stored
## in a sequence. Leaf nodes (such as literals and identifiers) have specific
## fields to store their values, while branch nodes use the children sequence
## to store their child nodes.

import std/[hashes, strutils, sequtils, options]
import std/htmlparser
export htmlparser

import pkg/openparser/json
import pkg/voodoo/extensibles

type
  NodeKind* {.extensible.} = enum
    # leafs
    nkEmpty          # empty node
    nkBool           # bool literal
    nkInt            # int literal
    nkFloat          # float literal
    nkString         # string literal
    nkIdent          # identifier
    nkVarTy          # identifier variable
    nkNil            # nil literal

    # general
    nkScript         # full script
    nkIdentDefs      # identifier definitions - a, b: s = x
    nkFormalParams   # formal params - (a: s, ...) -> t
    nkGenericParams  # generic params - [T, U: X]
    nkRecFields      # record fields - { a, b: t; c: u }

    # expressions
    nkPrefix         # prefix operator - op expr
    nkPostfix        # postfix operator - expr op
    nkInfix          # infix operator - left op right
    nkDot            # dot expression - left.right
    nkBracket
    nkColon          # colon expression - left: right
    nkIndex          # index expression - left[a, ...]
    nkCall           # call - left(a, ...)
    nkIf             # if expression - if expr {...} elif expr {...} else {...}

    # types
    nkProcTy         # procedure type - proc (...) -> t
    nkTypeDef        # type definition - type t = s
    
    # statements
    nkVar = "var"            # var declaration - var a = x
    nkLet = "let"            # let declaration - let a = x
    nkConst = "const"          # const declaration - const a = x
    nkWhile          # while loop - while cond {...}
    nkFor            # for loop - for x in y {...}
    nkBreak          # break statement - break
    nkContinue       # continue statement - continue
    nkReturn         # return statement - return x
    nkYield          # yield statement - yield x
    nkImport         # import statement - import "path/to/module"
    nkInclude        # include statement - include "path/to/file" 
    nkStatic         # static statement 

    # declarations
    nkObject         # object declaration - object o[T, ...] {...}
    nkArray          # array declaration - array[T, ...] {...}
    nkProc           # procedure declaration - proc p(a: s, ...) -> t {...}
    nkIterator       # iterator declaration - iterator i(a: s, ...) -> t {...}
    nkBlock          # block statement - block {...}
    nkDocComment     # doc comment - <!-- ... -->
    nkObjectStorage  # object storage - used to store JSON-like objects

  HtmlAttributeType* = enum
    htmlAttrClass, htmlAttrId, htmlAttrIdent, htmlAttr

  Node* {.acyclic, extensible.} = ref object
    ## An AST node.
    ln*, col*: int            ## Line information used for compile errors
    case kind* {.extensibleCase.}: NodeKind # The kind of the node
    of nkEmpty, nkNil:
      discard # no additional fields
    of nkBool:
      boolVal*: bool
        ## The boolean value
    of nkInt:
      intVal*: int64
        ## The integer value
    of nkFloat:
      floatVal*: float64
        ## The float value
    of nkString:
      stringVal*: string
        ## The string value
    of nkIdent:
      ident*: string
        ## The identifier name
    of nkVarTy:
      varType*: Node
        ## The variable type node
    of nkDocComment:
      comment*: string
        ## The doc comment content
    else:
      children*: seq[Node]
        ## Child nodes used to build the AST tree
        ## Used for all other node kinds not listed above

  Ast* {.acyclic.} = ref object
    sourcePath*: string
      ## The source path of the AST (e.g., the file path of the template)
    otherPaths*: seq[string]
      ## Other paths that this AST is associated with (imported/included templates)
    nodes*: seq[Node]
      ## The top-level nodes of the AST

const LeafNodes = {nkEmpty..nkIdent}

when not defined release:
  proc debugEcho*(node: Node) {.gcsafe.} =
    {.gcsafe.}:
      echo pretty(toJson(node).fromJson)

  proc debugEcho*(nodes: seq[Node]) {.gcsafe.} =
    {.gcsafe.}:
      echo pretty(toJson(nodes).fromJson)

proc len*(node: Node): int =
  result = node.children.len

proc `[]`*(node: Node, index: int | BackwardsIndex): Node =
  result = node.children[index]

proc `[]`*(node: Node, slice: HSlice): seq[Node] =
  result = node.children[slice]

proc `[]=`*(node: Node, index: int | BackwardsIndex, child: Node) =
  node.children[index] = child

iterator items*(node: Node): Node =
  when compiles(NodeKind.nkHtmlElement):
    if node.kind == nkHtmlElement:
      for child in node.childElements:
        yield child
    else:  
      for child in node.children:
        yield child
  else:
    for child in node.children:
      yield child

iterator pairs*(node: Node): tuple[i: int, n: Node] =
  for i, child in node.children:
    yield (i, child)

proc add*(node, child: Node): Node {.discardable.} =
  node.children.add(child)
  result = node

proc add*(node: Node, children: openarray[Node]): Node {.discardable.} =
  node.children.add(children)
  result = node

proc hash*(node: Node): Hash =
  var h = Hash(0)
  h = h !& hash(node.kind)
  extendableCase "astHashCase":
    case node.kind
    of nkEmpty: discard
    of nkBool: h = h !& hash(node.boolVal)
    of nkInt: h = h !& hash(node.intVal)
    of nkFloat: h = h !& hash(node.floatVal)
    of nkString: h = h !& hash(node.stringVal)
    of nkIdent: h = h !& hash(node.ident)
    else:
      h = h !& hash(node.len)
      h = h !& hash(node.children)
  result = h

proc `$`*(node: Node): string =
  ## Stringify a node. This only supports leaf nodes, for trees,
  ## use ``treeRepr``.
  assert node.kind in LeafNodes, "only leaf nodes can be `$`'ed. Got " & $node.kind
  result =
    case node.kind
    of nkBool: $node.boolVal
    of nkInt: $node.intVal
    of nkFloat: $node.floatVal
    of nkString: node.stringVal.escape
    of nkIdent: node.ident
    of nkNil: "nil"
    else: ""

proc treeRepr*(node: Node): string =
  ## Stringify a node into a tree representation.
  case node.kind
  of nkEmpty: result = "Empty"
  of nkBool: result = "Bool " & $node.boolVal
  of nkInt: result = "Int " & $node.intVal
  of nkFloat: result = "Float " & $node.floatVal
  of nkString: result = "String " & escape(node.stringVal)
  of nkIdent: result = "Ident " & node.ident
  else:
    result = ($node.kind)[2..^1]
    var children = ""
    for i, child in node.children:
      children.add('\n' & child.treeRepr)
    result.add(children.indent(2))

proc render*(node: Node): string =
  ## Renders the node's AST representation into a string. Note that this is
  ## imperfect and can't fully reproduce the actual user input (this, for
  ## instance, omits parentheses, as they are ignored by the parser).
  proc join(nodes: seq[Node], delimiter: string): string =
    for i, node in nodes:
      result.add(node.render)
      if i != nodes.len - 1:
        result.add(delimiter)
  case node.kind
  of nkEmpty:
    result = ""
  of nkNil:
    result = "nil"
  of nkScript:
    result = node.children.join("\n")
  of nkStatic:
    result = "static"
  of nkBlock:
    result =
      if node.len == 0: "{}"
      else: "{\n" & node.children.join("\n").indent(2) & "\n}"
  of nkArray:
    discard # todo
  of nkIdentDefs:
    result = node[0..^3].join(", ")
    if node[^2].kind != nkEmpty: result.add(": " & node[^2].render)
    if node[^1].kind != nkEmpty: result.add(" = " & node[^1].render)
  of nkFormalParams:
    result = '(' & node[1..^1].join(", ") & ')'
    if node[0].kind != nkEmpty: result.add(" -> " & node[0].render)
  of nkGenericParams:
    result = '[' & node.children.join(", ") & ']'
  of nkRecFields:
    result = node.children.join("\n")
  of nkBool, nkInt, nkFloat, nkString:
    result = $node
  of nkIdent:
    let identName = $node
    result =
      if identName.validIdentifier: identName
      else: identName
  of nkVarTy:
    result = "var " & node.varType.render
  of nkPrefix, nkPostfix:
    result = node[0].render & node[1].render
  of nkInfix:
    result = node[1].render & ' ' & node[0].render & ' ' & node[2].render
  of nkImport:
    result = "@import " & node[0].render
  of nkInclude:
    result = "@include " & node[0].render
  of nkDot:
    result = node[0].render & '.' & node[1].render
  of nkBracket:
    result = node[0].render & "[" & node[1].render & "]"
  of nkColon:
    result = node[0].render & ": " & node[1].render
  of nkIndex:
    result = node[0].render & '[' & node[1].render & ']'
  of nkCall:
    result = node[0].render & '(' & node[1..^1].join(", ") & ')'
  of nkIf:
    result = "if " & node[0].render & ' ' & node[1].render
    let
      hasElse = node.children.len mod 2 == 1
      elifBranches =
        if hasElse: node[2..^2]
        else: node[2..^1]
    for i in countup(0, elifBranches.len - 1, 2):
      result.add(" elif " & elifBranches[i].render & ' ' &
                 elifBranches[i + 1].render)
    if hasElse:
      result.add(" else " & node[^1].render)
  of nkProcTy:
    result = "proc " & node[0].render
  of nkTypeDef:
    discard # todo
  of nkVar, nkLet, nkConst:
    result = $node.kind & " " & node[0].render
  of nkWhile: result = "while " & node[0].render & ' ' & node[1].render
  of nkFor:
    result = "for " & node[0].render & " in " & node[1].render &
             ' ' & node[2].render
  of nkBreak: result = "break"
  of nkContinue: result = "continue"
  of nkReturn, nkYield:
    result =
      if node.kind == nkReturn: "return"
      else: "yield"
    if node[0].kind != nkEmpty: result.add(' ' & node[0].render)
  of nkObject:
    result = "object " & node[0].render & node[1].render & " {\n" &
             node[2].render.indent(2) & "\n}\n"
  of nkObjectStorage:
    discard # todo
  of nkProc, nkIterator:
    result = (
        if node.kind == nkProc:
          "proc "
        else: "iterator "
      ) & (node[0].render & node[1].render & node[2].render & ' ' & node[3].render)
    if node[0].kind != nkEmpty:
      result.add('\n')
  of nkDocComment:
    result = "<!-- " & node[0].render & " -->"
  # of nkClientBlock:
  #   result = "@client\n" & node[0].render.indent(2) & "\n@end"
  else: discard

proc newNode*(kind: NodeKind): Node =
  ## Construct a new node.
  Node(kind: kind)

proc newEmpty*: Node =
  ## Construct a new empty node.
  newNode(nkEmpty)

proc newNil*: Node =
  ## Construct a new nil node.
  newNode(nkNil)

proc nkBlock*(children: varargs[Node]): Node =
  ## Construct a new block.
  newNode(nkBlock)  

proc newTree*(kind: NodeKind, children: varargs[Node]): Node =
  ## Construct a new branch node with the given kind.
  assert kind notin LeafNodes, "kind must denote a branch node"
  result = newNode(kind)
  result.add(children)

proc newBoolLit*(val: bool): Node =
  ## Construct a new bool literal.
  result = newNode(nkBool)
  result.boolVal = val

proc newIntLit*(val: int64): Node =
  ## Construct a new integer literal.
  result = newNode(nkInt)
  result.intVal = val

proc newFloatLit*(val: float64): Node =
  ## Construct a new float literal.
  result = newNode(nkFloat)
  result.floatVal = val

proc newStringLit*(val: string): Node =
  ## Construct a new string literal.
  result = newNode(nkString)
  result.stringVal = val

proc newIdent*(ident: string, ln, col: int = 0): Node =
  ## Construct a new ident node.
  result = newNode(nkIdent)
  result.ident = ident
  result.ln = ln
  result.col = col

proc newIdentDefs*(names: openarray[Node], ty: Node, value = newEmpty()): Node =
  ## Construct a new nkIdentDefs node.
  result = newTree(nkIdentDefs, names)
  result.add([ty, value])

proc newInfix*(op, left, right: Node): Node =
  ## Construct a new infix node.
  result = newTree(nkInfix, op, left, right)

proc newCall*(ident: Node, args: varargs[Node]): Node =
  ## Construct a new call node.
  result = newTree(nkCall, ident)
  for arg in args:
    result.add(arg)

proc newFunction*(ident, body: Node, genericParams,
            formalParams: Node = newEmpty()): Node =
  ## Construct a new function declaration node.
  assert ident.kind == nkIdent, "ident must be an identifier node"
  if genericParams.kind != nkEmpty:
    assert genericParams.kind == nkGenericParams, "genericParams must be a nkGenericParams node"
  if formalParams.kind != nkEmpty:
    assert formalParams.kind == nkFormalParams, "formalParams must be a nkFormalParams node"
    if formalParams[0].kind != nkEmpty:
      assert formalParams[0].kind == nkIdent, "formalParams return type must be an identifier node"
  newTree(nkProc, ident, genericParams, formalParams, body)

let defaultNil* = newIdent("nil")
  # Used to represent `nil` in the AST

injectExtendedModule()