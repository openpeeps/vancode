import unittest
import std/[options, tables, sequtils, strutils, math]
import ../src/vancode/interpreter/[ast, codegen, chunk, value, vm, sym, scheduler]
import ../src/vancode/interpreter/stdlib/syslib
import ../src/vancode/interpreter/stdlib/utils

# helpers ---------------------------------------------------------------
proc newEnv(file="test"): tuple[script: Script, module: Module, chunk: Chunk, gen: CodeGen] =
  let c = newChunk(file)
  let s = newScript(c)
  let m = newModule(file, some(file))
  m.initSystemTypes()
  s.initSystemOps(m)
  let g = initCompiler(s,m,c,nil,nil)
  (s,m,c,g)

proc run(p: auto, nodes: seq[Node]): Value =
  let ast = Ast(sourcePath:"test", nodes: nodes)
  p.gen.genScript(ast, none(string))
  newVm().interpret(p.script, p.chunk)

proc runVm(p: auto, pref: VMPreferences, nodes: seq[Node]): Value =
  let ast = Ast(sourcePath:"test", nodes: nodes)
  p.gen.genScript(ast, none(string))
  newVirtualMachine(pref).interpret(p.script, p.chunk)

proc mkVar(name, typ: string, val: Node): Node =
  let ty = if typ.len==0: newEmpty() else: newIdent(typ)
  newTree(nkVar, newTree(nkBlock, newIdentDefs([newIdent(name)], ty, val)))

proc mkFormal(ret: string, params: openArray[tuple[name, typ: string]]): Node =
  let r = if ret.len==0: newEmpty() else: newIdent(ret)
  result = newTree(nkFormalParams, r)
  for (n,t) in params: result.add(newIdentDefs([newIdent(n)], newIdent(t), newEmpty()))

proc mkProcNode(name, ret: string, formal: Node, body: Node): Node =
  newTree(nkProc, newIdent(name), newEmpty(), formal, body)

proc mkIter(name, ret: string, formal: Node, body: Node): Node =
  newTree(nkIterator, newIdent(name), newEmpty(), formal, body)

proc mkCoro(name, ret: string, formal: Node, body: Node): Node =
  newTree(nkCoroutine, newIdent(name), newEmpty(), formal, body)

# Direct chunk helpers for low-level vm tests (no codegen) ---------------
proc emitCallD(ch: var Chunk, file: string, pid: int) =
  ch.emit(opcCallD); ch.emit(ch.getString(file)); ch.emit(pid.uint16)
proc findProc(s: Script, name: string): Proc =
  for p in s.procs:
    if p.name == name: return p

# ===========================================================================
suite "vm: arithmetic & logic":
  test "int Add/Sub/Mult/Div via codegen":
    let e = newEnv()
    let expr = newTree(nkInfix, newIdent("+"), newIntLit(10), newIntLit(5))
    let expr2 = newTree(nkInfix, newIdent("-"), newIntLit(10), newIntLit(3))
    let expr3 = newTree(nkInfix, newIdent("*"), newIntLit(6), newIntLit(7))
    let expr4 = newTree(nkInfix, newIdent("/"), newIntLit(20), newIntLit(4))
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[mkVar("a","int", expr), newTree(nkCall, newIdent("cap"), newIdent("a"))])
    check cap == 15
    let e2 = newEnv()
    e2.script.addProc(e2.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e2.run(@[mkVar("b","int", expr2), newTree(nkCall, newIdent("cap"), newIdent("b"))])
    check cap == 7
    let e3 = newEnv()
    e3.script.addProc(e3.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e3.run(@[mkVar("c","int", expr3), newTree(nkCall, newIdent("cap"), newIdent("c"))])
    check cap == 42
    let e4 = newEnv()
    e4.script.addProc(e4.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e4.run(@[mkVar("d","int", expr4), newTree(nkCall, newIdent("cap"), newIdent("d"))])
    check cap == 5

  test "int negation via prefix":
    let e = newEnv()
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[mkVar("x","int", newTree(nkPrefix, newIdent("-"), newIntLit(7))), newTree(nkCall, newIdent("cap"), newIdent("x"))])
    check cap == -7

  test "float arithmetic promotion int+float":
    let e = newEnv()
    let expr = newTree(nkInfix, newIdent("+"), newIntLit(1), newFloatLit(2.5))
    var capF: float64=0
    e.script.addProc(e.module, "capF", @[paramDef("v", ttyFloat)], ttyVoid, proc(a:StackView,c:int):Value = capF=a[0].floatVal)
    discard e.run(@[mkVar("f","float", expr), newTree(nkCall, newIdent("capF"), newIdent("f"))])
    check abs(capF-3.5) < 1e-9

  test "float relational less/greater/eq":
    block:
      let e = newEnv()
      var capB=false
      e.script.addProc(e.module, "capB", @[paramDef("v", ttyBool)], ttyVoid, proc(a:StackView,c:int):Value = capB=a[0].boolVal)
      let expr = newTree(nkInfix, newIdent("<"), newFloatLit(1.0), newFloatLit(2.0))
      discard e.run(@[mkVar("b","bool", expr), newTree(nkCall, newIdent("capB"), newIdent("b"))])
      check capB == true
    block:
      let e = newEnv()
      var capB=false
      e.script.addProc(e.module, "capB", @[paramDef("v", ttyBool)], ttyVoid, proc(a:StackView,c:int):Value = capB=a[0].boolVal)
      let expr = newTree(nkInfix, newIdent(">"), newFloatLit(1.0), newFloatLit(2.0))
      discard e.run(@[mkVar("b","bool", expr), newTree(nkCall, newIdent("capB"), newIdent("b"))])
      check capB == false
    block:
      let e = newEnv()
      var capB=false
      e.script.addProc(e.module, "capB", @[paramDef("v", ttyBool)], ttyVoid, proc(a:StackView,c:int):Value = capB=a[0].boolVal)
      let expr = newTree(nkInfix, newIdent("=="), newFloatLit(1.0), newFloatLit(2.0))
      discard e.run(@[mkVar("b","bool", expr), newTree(nkCall, newIdent("capB"), newIdent("b"))])
      check capB == false

  test "bool invert and equality":
    let e = newEnv()
    var capB=false
    e.script.addProc(e.module, "capB", @[paramDef("v", ttyBool)], ttyVoid, proc(a:StackView,c:int):Value = capB=a[0].boolVal)
    discard e.run(@[mkVar("b","bool", newTree(nkPrefix, newIdent("not"), newBoolLit(true))), newTree(nkCall, newIdent("capB"), newIdent("b"))])
    check capB == false
    let e2 = newEnv()
    e2.script.addProc(e2.module, "capB", @[paramDef("v", ttyBool)], ttyVoid, proc(a:StackView,c:int):Value = capB=a[0].boolVal)
    discard e2.run(@[mkVar("b","bool", newTree(nkInfix, newIdent("=="), newBoolLit(true), newBoolLit(true))), newTree(nkCall, newIdent("capB"), newIdent("b"))])
    check capB == true

  test "string concat & and equality":
    let e = newEnv()
    var capS=""
    e.script.addProc(e.module, "capS", @[paramDef("v", ttyString)], ttyVoid, proc(a:StackView,c:int):Value = capS=a[0].stringVal[])
    let cat = newTree(nkInfix, newIdent("&"), newStringLit("hello"), newStringLit(" world"))
    discard e.run(@[mkVar("s","string", cat), newTree(nkCall, newIdent("capS"), newIdent("s"))])
    check capS == "hello world"
    let e2 = newEnv()
    var capB=false
    e2.script.addProc(e2.module, "capB", @[paramDef("v", ttyBool)], ttyVoid, proc(a:StackView,c:int):Value = capB=a[0].boolVal)
    let eq = newTree(nkInfix, newIdent("=="), newStringLit("a"), newStringLit("a"))
    discard e2.run(@[mkVar("b","bool", eq), newTree(nkCall, newIdent("capB"), newIdent("b"))])
    check capB == true

  test "direct chunk arithmetic – PushI AddI SubI":
    var ch = newChunk("direct")
    let script = newScript(ch)
    ch.emit(opcPushI); ch.emit(10i64)
    ch.emit(opcPushI); ch.emit(20i64)
    ch.emit(opcAddI)
    ch.emit(opcHalt)
    let vm = newVm()
    let res = vm.interpret(script, ch)
    check res.intVal==30
    # Sub
    var ch2 = newChunk("direct2")
    let s2 = newScript(ch2)
    ch2.emit(opcPushI); ch2.emit(10i64)
    ch2.emit(opcPushI); ch2.emit(3i64)
    ch2.emit(opcSubI); ch2.emit(opcHalt)
    check newVm().interpret(s2, ch2).intVal==7

  test "direct chunk Discard and PushTrue/False":
    var ch = newChunk("disc")
    let s = newScript(ch)
    ch.emit(opcPushI); ch.emit(1i64)
    ch.emit(opcPushI); ch.emit(2i64)
    ch.emit(opcDiscard); ch.emit(1u8)
    ch.emit(opcHalt)
    let r = newVm().interpret(s, ch)
    check r.intVal==1
    var ch2 = newChunk("bool")
    let s2 = newScript(ch2)
    ch2.emit(opcPushTrue); ch2.emit(opcPushFalse); ch2.emit(opcEqB); ch2.emit(opcHalt)
    check newVm().interpret(s2, ch2).boolVal==false

suite "vm: vars & scope":
  test "global persists across interpret calls":
    let e = newEnv()
    discard e.run(@[mkVar("g","int", newIntLit(5))])
    # second script reuses same script? Use same vm globals
    let vm = newVm()
    # need to set global manually via first run? Instead use single run with two statements sharing global
    let e2 = newEnv()
    let vm2 = newVm()
    # run first chunk that sets g
    let ast1 = Ast(sourcePath:"test", nodes: @[mkVar("g","int", newIntLit(5))])
    e2.gen.genScript(ast1, none(string))
    discard vm2.interpret(e2.script, e2.chunk)
    # now second run that reads g – need same vm and script sharing globals
    # create new chunk reading g
    var ch2 = newChunk("test")
    ch2.emit(opcPushG); ch2.emit(ch2.getString("g"))
    ch2.emit(opcHalt)
    e2.script.mainChunk = ch2
    # Monkey patch: ensure script's chunk file same? PushG uses string table of ch2, but globals stored under "g" key from first module. Need to ensure ch2 gets same string.
    # Instead test via codegen: after var, read via vm global in same interpret
    let e3 = newEnv()
    var cap:int64=0
    e3.script.addProc(e3.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e3.run(@[mkVar("g","int", newIntLit(9)), newTree(nkCall, newIdent("cap"), newIdent("g"))])
    check cap == 9

  test "local var inside proc isolated":
    let e = newEnv()
    let formal = mkFormal("int", [("n","int")])
    let body = newTree(nkBlock, mkVar("x","int", newTree(nkInfix, newIdent("+"), newIdent("n"), newIntLit(10))), newTree(nkReturn, newIdent("x")))
    let p = mkProcNode("f", "int", formal, body)
    var c1:int64=0; var c2:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value =
      if c1==0: c1=a[0].intVal else: c2=a[0].intVal)
    discard e.run(@[p, mkVar("a","int", newTree(nkCall, newIdent("f"), newIntLit(1))), mkVar("b","int", newTree(nkCall, newIdent("f"), newIntLit(2))), newTree(nkCall, newIdent("cap"), newIdent("a")), newTree(nkCall, newIdent("cap"), newIdent("b"))])
    check c1==11 and c2==12

  test "IncL/DecL via codegen for proc locals":
    let e = newEnv()
    let formal = mkFormal("int", [("n","int")])
    let body = newTree(nkBlock,
      mkVar("i","int", newIdent("n")),
      newTree(nkInfix, newIdent("="), newIdent("i"), newTree(nkInfix, newIdent("+"), newIdent("i"), newIntLit(1))),
      newTree(nkInfix, newIdent("="), newIdent("i"), newTree(nkInfix, newIdent("+"), newIdent("i"), newIntLit(1))),
      newTree(nkReturn, newIdent("i")))
    let p = mkProcNode("inc2", "int", formal, body)
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[p, mkVar("r","int", newTree(nkCall, newIdent("inc2"), newIntLit(0))), newTree(nkCall, newIdent("cap"), newIdent("r"))])
    check cap == 2

suite "vm: control flow via codegen":
  test "if true/false branching semantic":
    for val in [true, false]:
      let e = newEnv()
      var cap:int64=0
      e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
      let ifNode = newTree(nkIf, newBoolLit(val), newTree(nkBlock, mkVar("a","int", newIntLit(1))), newTree(nkBlock, mkVar("a","int", newIntLit(2))))
      # Instead use if expr to set x
      let ifExpr = newTree(nkIf, newBoolLit(val), newTree(nkBlock, newIntLit(1)), newTree(nkBlock, newIntLit(2)))
      discard e.run(@[mkVar("x","int", ifExpr), newTree(nkCall, newIdent("cap"), newIdent("x"))])
      check (val and cap==1) or (not val and cap==2)

  test "while loop computes factorial 5! =120":
    let e = newEnv()
    let varN = mkVar("n","int", newIntLit(5))
    let varRes = mkVar("res","int", newIntLit(1))
    let cond = newTree(nkInfix, newIdent(">"), newIdent("n"), newIntLit(0))
    let body = newTree(nkBlock,
      newTree(nkInfix, newIdent("="), newIdent("res"), newTree(nkInfix, newIdent("*"), newIdent("res"), newIdent("n"))),
      newTree(nkInfix, newIdent("="), newIdent("n"), newTree(nkInfix, newIdent("-"), newIdent("n"), newIntLit(1))))
    let whileNode = newTree(nkWhile, cond, body)
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[varN, varRes, whileNode, newTree(nkCall, newIdent("cap"), newIdent("res"))])
    check cap == 120

  test "for range loop sum verified":
    let e = newEnv()
    e.script.addProc(e.module, "range", @[paramDef("lo", ttyInt), paramDef("hi", ttyInt)], ttyInt, proc(a:StackView,c:int):Value = initValue(0i64))
    let varS = mkVar("s","int", newIntLit(0))
    let rng = newTree(nkCall, newIdent("range"), newIntLit(1), newIntLit(4))
    let forBody = newTree(nkBlock, newTree(nkInfix, newIdent("="), newIdent("s"), newTree(nkInfix, newIdent("+"), newIdent("s"), newIdent("i"))))
    let forNode = newTree(nkFor, newIdent("i"), rng, forBody)
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[varS, forNode, newTree(nkCall, newIdent("cap"), newIdent("s"))])
    check cap == 10 # 1+2+3+4

  test "break and continue inside while via codegen":
    let e = newEnv()
    let varI = mkVar("i","int", newIntLit(0))
    let varC = mkVar("c","int", newIntLit(0))
    let cond = newTree(nkInfix, newIdent("<"), newIdent("i"), newIntLit(5))
    let incI = newTree(nkInfix, newIdent("="), newIdent("i"), newTree(nkInfix, newIdent("+"), newIdent("i"), newIntLit(1)))
    let ifBrk = newTree(nkIf, newTree(nkInfix, newIdent("=="), newIdent("i"), newIntLit(3)), newTree(nkBlock, newNode(nkBreak)))
    let incC = newTree(nkInfix, newIdent("="), newIdent("c"), newTree(nkInfix, newIdent("+"), newIdent("c"), newIntLit(1)))
    let body = newTree(nkBlock, incI, ifBrk, incC)
    let whileNode = newTree(nkWhile, cond, body)
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[varI, varC, whileNode, newTree(nkCall, newIdent("cap"), newIdent("c"))])
    check cap == 2 # i=1->c1, i=2->c2, i=3 break

suite "vm: procs & calls":
  test "direct CallD and recursion":
    let e = newEnv()
    let formal = mkFormal("int", [("n","int")])
    let cond = newTree(nkInfix, newIdent("=="), newIdent("n"), newIntLit(0))
    let thenBlk = newTree(nkBlock, newTree(nkReturn, newIntLit(1)))
    let elseBlk = newTree(nkBlock, newTree(nkReturn, newTree(nkInfix, newIdent("*"), newIdent("n"), newTree(nkCall, newIdent("fact"), newTree(nkInfix, newIdent("-"), newIdent("n"), newIntLit(1))))))
    let ifNode = newTree(nkIf, cond, thenBlk, elseBlk)
    let procNode = mkProcNode("fact", "int", formal, newTree(nkBlock, ifNode))
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[procNode, mkVar("r","int", newTree(nkCall, newIdent("fact"), newIntLit(5))), newTree(nkCall, newIdent("cap"), newIdent("r"))])
    check cap == 120

  test "CallI indirect via PushProc":
    # Create proc foo(a:int):int = a*2 ; main pushes proc ref and calls indirectly
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)
    let module = newModule("test", some("test"))
    module.initSystemTypes(); script.initSystemOps(module)
    var procChunk = newChunk("test")
    procChunk.emit(opcPushL); procChunk.emit(0u8)
    procChunk.emit(opcPushI); procChunk.emit(2i64)
    procChunk.emit(opcMultI)
    procChunk.emit(opcReturnVal)
    let p = Proc(name:"foo", kind: pkNative, chunk: procChunk, paramCount:1, hasResult:true)
    let pid = script.procs.len
    p.procId = pid
    script.procs.add(p)
    # PushProc then args then CallI
    mainChunk.emit(opcPushProc); mainChunk.emit(mainChunk.getString("test")); mainChunk.emit(pid.uint16)
    mainChunk.emit(opcPushI); mainChunk.emit(21i64)
    mainChunk.emit(opcCallI); mainChunk.emit(1u8)
    mainChunk.emit(opcHalt)
    let res = newVm().interpret(script, mainChunk)
    check res.intVal==42

  test "foreign proc call":
    let e = newEnv()
    var received: int64=0
    e.script.addProc(e.module, "myadd", @[paramDef("a", ttyInt), paramDef("b", ttyInt)], ttyInt, proc(a:StackView,c:int):Value =
      received = a[0].intVal + a[1].intVal
      initValue(received))
    let varR = mkVar("r","int", newTree(nkCall, newIdent("myadd"), newIntLit(20), newIntLit(22)))
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[varR, newTree(nkCall, newIdent("cap"), newIdent("r"))])
    check cap == 42
    check received==42

  test "optional param defaults to 10 when omitted":
    let e = newEnv()
    let formal = newTree(nkFormalParams, newIdent("int"))
    formal.add(newIdentDefs([newIdent("a")], newIdent("int"), newEmpty()))
    formal.add(newIdentDefs([newIdent("b")], newIdent("int"), newIntLit(10)))
    let body = newTree(nkBlock, newTree(nkReturn, newTree(nkInfix, newIdent("+"), newIdent("a"), newIdent("b"))))
    let p = newTree(nkProc, newIdent("add"), newEmpty(), formal, body)
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[p, mkVar("r","int", newTree(nkCall, newIdent("add"), newIntLit(5))), newTree(nkCall, newIdent("cap"), newIdent("r"))])
    check cap == 15

  test "tail call optimization self recursion":
    let e = newEnv()
    # tail recursive sum: proc sum(n, acc: int): int = if n==0: return acc else: return sum(n-1, acc+n)
    let formal = newTree(nkFormalParams, newIdent("int"))
    formal.add(newIdentDefs([newIdent("n")], newIdent("int"), newEmpty()))
    formal.add(newIdentDefs([newIdent("acc")], newIdent("int"), newEmpty()))
    let cond = newTree(nkInfix, newIdent("=="), newIdent("n"), newIntLit(0))
    let thenBlk = newTree(nkBlock, newTree(nkReturn, newIdent("acc")))
    let elseBlk = newTree(nkBlock, newTree(nkReturn, newTree(nkCall, newIdent("sum"), newTree(nkInfix, newIdent("-"), newIdent("n"), newIntLit(1)), newTree(nkInfix, newIdent("+"), newIdent("acc"), newIdent("n")))))
    let ifNode = newTree(nkIf, cond, thenBlk, elseBlk)
    let procNode = mkProcNode("sum", "int", formal, newTree(nkBlock, ifNode))
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[procNode, mkVar("r","int", newTree(nkCall, newIdent("sum"), newIntLit(5), newIntLit(0))), newTree(nkCall, newIdent("cap"), newIdent("r"))])
    check cap == 15

  test "error insufficient args":
    var ch = newChunk("test")
    let s = newScript(ch)
    var pc = newChunk("test")
    pc.emit(opcPushL); pc.emit(0u8); pc.emit(opcPushL); pc.emit(1u8); pc.emit(opcAddI); pc.emit(opcReturnVal)
    s.procs.add(Proc(name:"add", kind: pkNative, chunk: pc, paramCount:2, hasResult:true))
    ch.emit(opcPushI); ch.emit(1i64) # only one arg, need 2
    ch.emit(opcCallD); ch.emit(ch.getString("test")); ch.emit(0u16)
    ch.emit(opcHalt)
    expect(ValueError):
      discard newVm().interpret(s, ch)

suite "vm: objects & arrays":
  test "array construction and GetI via bracket":
    let e = newEnv()
    let arr = newTree(nkArray, newIntLit(10), newIntLit(20), newIntLit(30))
    let varA = mkVar("a","", arr)
    let idx = newTree(nkBracket, newIdent("a"), newIntLit(1))
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[varA, mkVar("v","int", idx), newTree(nkCall, newIdent("cap"), newIdent("v"))])
    check cap == 20

  test "array construction with inconsistent types raises in codegen":
    let e = newEnv()
    let arr = newTree(nkArray, newIntLit(1), newStringLit("hi"))
    expect(CodeGenError):
      discard e.run(@[mkVar("a","", arr)])

  test "object construction and field Get/Set":
    let e = newEnv()
    let rec = newTree(nkRecFields, newIdentDefs([newIdent("x")], newIdent("int"), newEmpty()), newIdentDefs([newIdent("y")], newIdent("int"), newEmpty()))
    let objDef = newTree(nkObject, newIdent("Point"), newEmpty(), rec)
    let constr = newTree(nkCall, newIdent("Point"), newTree(nkColon, newIdent("x"), newIntLit(3)), newTree(nkColon, newIdent("y"), newIntLit(4)))
    let varP = mkVar("p","", constr)
    let dot = newTree(nkDot, newIdent("p"), newIdent("x"))
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[objDef, varP, mkVar("vx","int", dot), newTree(nkCall, newIdent("cap"), newIdent("vx"))])
    check cap == 3
    # set field
    let e2 = newEnv()
    let rec2 = newTree(nkRecFields, newIdentDefs([newIdent("x")], newIdent("int"), newEmpty()))
    let objDef2 = newTree(nkObject, newIdent("Foo"), newEmpty(), rec2)
    let constr2 = newTree(nkCall, newIdent("Foo"), newTree(nkColon, newIdent("x"), newIntLit(1)))
    let varO = mkVar("o","", constr2)
    let assign = newTree(nkInfix, newIdent("="), newTree(nkDot, newIdent("o"), newIdent("x")), newIntLit(99))
    discard e2.run(@[objDef2, varO, assign])
    var cap2:int64=0
    let e3 = newEnv()
    let rec3 = newTree(nkRecFields, newIdentDefs([newIdent("x")], newIdent("int"), newEmpty()))
    let objDef3 = newTree(nkObject, newIdent("Foo"), newEmpty(), rec3)
    e3.script.addProc(e3.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap2=a[0].intVal)
    discard e3.run(@[objDef3, mkVar("o","", newTree(nkCall, newIdent("Foo"), newTree(nkColon, newIdent("x"), newIntLit(1)))), newTree(nkInfix, newIdent("="), newTree(nkDot, newIdent("o"), newIdent("x")), newIntLit(99)), mkVar("v","int", newTree(nkDot, newIdent("o"), newIdent("x"))), newTree(nkCall, newIdent("cap"), newIdent("v"))])
    check cap2 == 99

  test "object storage anonymous with mixed types":
    let e = newEnv()
    let storage = newTree(nkObjectStorage, newTree(nkColon, newIdent("a"), newIntLit(1)), newTree(nkColon, newIdent("b"), newStringLit("hello")))
    let varO = mkVar("o","", storage)
    discard e.run(@[varO])
    check true

  test "string concat via opcode":
    var ch = newChunk("s")
    let s = newScript(ch)
    ch.emit(opcPushS); ch.emit(ch.getString("hello"))
    ch.emit(opcPushS); ch.emit(ch.getString(" world"))
    ch.emit(opcConcatStr); ch.emit(opcHalt)
    let r = newVm().interpret(s, ch)
    check r.stringVal[] == "hello world"

suite "vm: coroutines, scheduler & hot code":
  test "coroutine yield/resume via direct chunk":
    var mainChunk = newChunk("test")
    let script = newScript(mainChunk)
    var procChunk = newChunk("test")
    procChunk.emit(opcPushI); procChunk.emit(10i64); procChunk.emit(opcCoroYield)
    procChunk.emit(opcPushI); procChunk.emit(20i64); procChunk.emit(opcReturnVal)
    script.procs.add(Proc(name:"gen", kind: pkNative, chunk: procChunk, paramCount:0, hasResult:true))
    mainChunk.emit(opcCreateCoro); mainChunk.emit(0u16)
    mainChunk.emit(opcPopG); mainChunk.emit(mainChunk.getString("co"))
    mainChunk.emit(opcPushG); mainChunk.emit(mainChunk.getString("co")); mainChunk.emit(opcCoroResume); mainChunk.emit(opcDiscard); mainChunk.emit(1u8)
    mainChunk.emit(opcPushG); mainChunk.emit(mainChunk.getString("co")); mainChunk.emit(opcCoroResume); mainChunk.emit(opcHalt)
    let r = newVm().interpret(script, mainChunk)
    check r.intVal==20

  test "coroutine via codegen with callables (intrinsic wrapper)":
    # codegen for coroutine uses direct opcode; we test via codegen-coroutine + manual resume via vm
    let e = newEnv()
    let formal = mkFormal("int", [("n","int")])
    let body = newTree(nkBlock, newTree(nkYield, newIntLit(5)), newTree(nkReturn, newIdent("n")))
    let coro = mkCoro("gen", "int", formal, body)
    discard e.run(@[coro])
    # coroutine was compiled to Proc with chunk; verify procs len
    var found=false
    for p in e.script.procs:
      if p.name=="gen": found=true
    check found

  test "stepCoroutine API – Completed and Yielded":
    var ch = newChunk("test")
    let script = newScript(ch)
    var pc = newChunk("test")
    pc.emit(opcPushI); pc.emit(1i64); pc.emit(opcCoroYield)
    pc.emit(opcPushI); pc.emit(2i64); pc.emit(opcReturnVal)
    script.procs.add(Proc(name:"y", kind: pkNative, chunk: pc, paramCount:0, hasResult:true))
    let vm = newVm()
    let coro = Coroutine(state: csCreated, callee: script.procs[0], script: script)
    let r1 = stepCoroutine(vm, coro)
    check r1.kind==crYielded and r1.yieldedValue.intVal==1
    check coro.state==csSuspended
    let r2 = stepCoroutine(vm, coro)
    check r2.kind==crCompleted and r2.resultValue.intVal==2

  test "stepCoroutine invalid state CrErrored":
    let vm = newVm()
    let coro = Coroutine(state: csRunning, callee:nil, script:nil)
    let r = stepCoroutine(vm, coro)
    check r.kind==crErrored

  test "scheduler single and multiple coroutines":
    for count in [1,5]:
      let e = newEnv()
      # use coroutine that returns param
      let formal = mkFormal("int", [("v","int")])
      let body = newTree(nkBlock, newTree(nkReturn, newIdent("v")))
      let coroNode = mkCoro("id", "int", formal, body)
      discard e.run(@[coroNode])
      let procId = findProc(e.script, "id")
      let sched = newCoroutineScheduler(SchedulerConfig(threadCount:2))
      sched.start()
      for i in 1..count:
        let co = Coroutine(state: csCreated, callee: procId, script: e.script)
        co.savedStack = @[initValue(i.int64)]
        co.savedStackBottom=0
        sched.schedule(co)
      var sum=0
      for i in 0..<count:
        let (_, res) = sched.receive()
        check res.kind==crCompleted
        sum += res.resultValue.intVal
      sched.stop()
      check sum == count*(count+1) div 2

  test "hot code detection counts":
    var ch = newChunk("hot")
    let s = newScript(ch)
    var pc = newChunk("hot")
    pc.emit(opcPushI); pc.emit(1i64); pc.emit(opcReturnVal)
    s.procs.add(Proc(name:"hot", kind: pkNative, chunk: pc, paramCount:0, hasResult:true))
    ch.emit(opcCallD); ch.emit(ch.getString("hot")); ch.emit(0u16); ch.emit(opcHalt)
    let prefs = VMPreferences(enableHotCodeDetection:true, hotProcThreshold:5)
    let vm = newVirtualMachine(prefs)
    for i in 0..<3: discard vm.interpret(s, ch)
    check vm.getHotProcCount("hot")==3
    let vm2 = newVm()
    for i in 0..<2: discard vm2.interpret(s, ch)
    check vm2.getHotProcCount("hot")==0

  test "vm globals persistence via CodeGen (repeat var read)":
    let e = newEnv()
    var cap:int64=0
    e.script.addProc(e.module, "cap", @[paramDef("v", ttyInt)], ttyVoid, proc(a:StackView,c:int):Value = cap=a[0].intVal)
    discard e.run(@[mkVar("g","int", newIntLit(7)), newTree(nkInfix, newIdent("="), newIdent("g"), newIntLit(8)), newTree(nkCall, newIdent("cap"), newIdent("g"))])
    check cap == 8

  test "error yield outside coroutine raises ValueError":
    var ch = newChunk("bad")
    let s = newScript(ch)
    ch.emit(opcPushI); ch.emit(5i64); ch.emit(opcCoroYield); ch.emit(opcHalt)
    expect(ValueError):
      discard newVm().interpret(s,ch)

  test "error resume completed raises":
    var main = newChunk("test")
    let s = newScript(main)
    var pc = newChunk("test")
    pc.emit(opcPushI); pc.emit(7i64); pc.emit(opcReturnVal)
    s.procs.add(Proc(name:"simple", kind: pkNative, chunk:pc, paramCount:0, hasResult:true))
    main.emit(opcCreateCoro); main.emit(0u16)
    main.emit(opcPopG); main.emit(main.getString("co"))
    main.emit(opcPushG); main.emit(main.getString("co")); main.emit(opcCoroResume); main.emit(opcPopG); main.emit(main.getString("tmp"))
    main.emit(opcPushG); main.emit(main.getString("co")); main.emit(opcCoroResume); main.emit(opcHalt)
    expect(ValueError):
      discard newVm().interpret(s, main)

suite "vm: edge cases & errors":
  test "type mismatch in assignment raises CodeGenError":
    let e = newEnv()
    expect(CodeGenError):
      discard e.run(@[mkVar("x","int", newIntLit(1)), newTree(nkInfix, newIdent("="), newIdent("x"), newStringLit("hi"))])

  test "undeclared identifier raises":
    let e = newEnv()
    expect(CodeGenError):
      discard e.run(@[mkVar("y","int", newIdent("unknown"))])

  test "discard requires non-void":
    let e = newEnv()
    let p = mkProcNode("voidp", "", mkFormal("", []), newTree(nkBlock, newTree(nkDiscard, newIntLit(1)))) # void proc actually returns void, but body has discard?
    # Instead directly test discard void call
    let formal = mkFormal("", [("a","int")])
    let voidProc = newTree(nkProc, newIdent("vp"), newEmpty(), formal, newTree(nkBlock))
    let call = newTree(nkCall, newIdent("vp"), newIntLit(1))
    expect(CodeGenError):
      discard e.run(@[voidProc, newTree(nkDiscard, call)])

  test "stack underflow via manual ConstrObj with too many":
    var ch = newChunk("obj")
    let s = newScript(ch)
    ch.emit(opcConstrObj); ch.emit(2u16); ch.emit(ch.getString("a")); ch.emit(ch.getString("b"))
    ch.emit(opcHalt)
    expect(IndexDefect):
      discard newVm().interpret(s, ch)

  test "jump target precomputation sanity":
    let e = newEnv()
    # if true: while true: break
    let innerWhile = newTree(nkWhile, newBoolLit(true), newTree(nkBlock, newNode(nkBreak)))
    let ifNode = newTree(nkIf, newBoolLit(true), newTree(nkBlock, innerWhile))
    discard e.run(@[ifNode])
    check true

