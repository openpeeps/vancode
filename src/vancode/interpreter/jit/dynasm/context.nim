import std/[sysatomics, os]
import ../[vm, chunk, value, proc_ops]
import ../jit/[compiler_bridge]
import ./wrapper

type
  DynasmContext* = object
    state: ptr dasm_State
    globals: array[64, pointer]
    labels: int
    labelSlots: int
    buf: pointer
    bufSize: csize

proc initDynasm*(ctx: var DynasmContext) =
  ctx.state = nil
  ctx.labels = 0
  ctx.labelSlots = 16
  ctx.buf = nil
  ctx.bufSize = 0
  dasm_init(addr ctx.state, DASM_MAXSECTION)
  dasm_setupglobal(addr ctx.state, addr ctx.globals[0], 64)
  dasm_setup(addr ctx.state, unsafeAddr dfkup_actions)
  dasm_growpc(addr ctx.state, ctx.labelSlots.cuint)

proc allocLabel*(ctx: var DynasmContext): int =
  result = ctx.labels
  ctx.labels += 1
  if ctx.labels >= ctx.labelSlots:
    ctx.labelSlots *= 2
    dasm_growpc(addr ctx.state, ctx.labelSlots.cuint)

proc finalizeDynasm*(ctx: var DynasmContext): pointer =
  var sz: csize
  let err = dasm_link(addr ctx.state, addr sz)
  if err != 0 or sz == 0:
    dasm_free(addr ctx.state)
    return nil

  ctx.bufSize = sz
  ctx.buf = alloc0(sz)
  if ctx.buf == nil:
    dasm_free(addr ctx.state)
    return nil

  let encodeErr = dasm_encode(addr ctx.state, ctx.buf)
  if encodeErr != 0:
    dealloc(ctx.buf)
    ctx.buf = nil
    dasm_free(addr ctx.state)
    return nil

  result = ctx.buf

proc freeDynasm*(ctx: var DynasmContext) =
  if ctx.state != nil:
    dasm_free(addr ctx.state)
    ctx.state = nil
  if ctx.buf != nil:
    dealloc(ctx.buf)
    ctx.buf = nil
