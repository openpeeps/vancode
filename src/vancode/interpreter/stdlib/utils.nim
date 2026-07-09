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

import ../[chunk, codegen, ast, sym, value]

type
  TempParamDef* = tuple
    pName: string
      # the name of the parameter, used for error messages and stuff
    pKind: TypeKind
      # the type of the parameter, used for type checking and codegen
    pKindIdent: string
      # the identifier of the parameter type, used for codegen
    pImplSym: Sym
      # the symbol of the parameter implementation, used for codegen
    isMut, isOpt: bool
      # whether the parameter is mutable or optional, used for codegen
    val: Value
      # the default value of the parameter, used for optional parameters

proc defaultNodeFromValue*(v: Value): Node =
  ## Converts runtime Value -> AST literal for default parameter codegen.
  if v == nil: return ast.newNode(nkNil)
  case v.typeId
  of tyBool:
    result = ast.newNode(nkBool)
    result.boolVal = v.boolVal
  of tyInt:
    result = ast.newNode(nkInt)
    result.intVal = v.intVal
  of tyFloat:
    result = ast.newNode(nkFloat)
    result.floatVal = v.floatVal
  of tyString:
    result = ast.newNode(nkString)
    result.stringVal = v.stringVal[]
  of tyNil:
    result = ast.newNode(nkNil)
  else:
    # Unsupported as compile-time default literal in bridge path
    result = nil

proc addProc*(script: Script, module: Module, name: string,
              params: seq[TempParamDef] = @[], returnTy: TypeKind,
              impl: ForeignProc = nil, exportSym = true,
              returnTySym: Sym = nil) =
  var nodeParams: seq[ProcParam]

  for raw in params:
    var param = raw
    let paramTy =
      case param.pKind
      of ttyHtmlElement: module.sym(param.pKindIdent)
      else: module.sym($param.pKind)

    # If a default Value is provided, expose it through implSym.impl
    # so callProc -> genExpr(...) pushes that exact value.
    if param.val != nil and param.pImplSym == nil:
      let n = defaultNodeFromValue(param.val)
      if n != nil:
        param.pImplSym = newSym(
          skConst,
          ast.newIdent("__default_" & param.pName),
          impl = n
        )

    let optional = param.isOpt or param.val != nil

    nodeParams.add((
      ast.newIdent(param.pName),
      paramTy,
      param.pImplSym,
      param.isMut,
      optional
    ))

  let resolvedReturnTy =
    if returnTySym != nil: returnTySym
    else: module.sym($returnTy)

  let (sym, theProc) =
    script.newProc(
      ast.newIdent(name),
      impl = nil,
      nodeParams,
      resolvedReturnTy,
      pkForeign,
      exportSym
    )

  theProc.foreign = impl
  discard module.addCallable(sym, sym.name)
  if impl != nil:
    script.procs.add(theProc)

proc paramDef*(name: string, kind: TypeKind, val: Value = nil,
              sym: Sym = nil; mut: bool = false,
              isOpt: bool = false, kindStr = ""): TempParamDef {.inline.} =
  ## Create a new parameter definition.
  result = (name, kind, kindStr, sym, mut, (isOpt or val != nil), val)

proc p*(name: string, kind: TypeKind, val: Value = nil,
              sym: Sym = nil; mut: bool = false,
              isOpt: bool = false, kindStr = ""): TempParamDef {.inline.} =
  ## Create a new parameter definition
  result = (name, kind, kindStr, sym, mut, (isOpt or val != nil), val)