# v0.1.8 - 2026-07-06

- **FIX:** `popVar` now always emits `opcPopL` for locals (removed `varSet` guard).
  `popScope` no longer emits `opcDiscard` since `popL` already consumes the value.
  Previously, the first assignment to a local left its initial value on the eval stack
  (relied on by the VM's `stackBottom + idx` scheme), but the JIT reads from a separate
  `flatArgs` array that was never written, causing `pushL` to read 0. This manifested as
  SIGFPE (`n / 0`) in bool-returning functions with `if` + `while` + division, and as
  infinite loops in for-range-lowered code.
- **FIX:** JIT `opcJumpFwdT`/`opcJumpFwdF` changed from `popInt` to peek (read
  `stackI[sp-1]` without decrementing `sp`), matching the VM interpreter behavior
  that for-range lowered bytecode depends on.
- **FIX:** `ensureLocal(idx)` calls added in `opcPushL`/`opcPopL` VM dispatch,
  preventing `IndexDefect` crashes when loops run inside function scope.
- **FIX:** Default return type for functions without explicit return type annotation
  changed from `stmt` (`ttyAny`) to `void` (`ttyVoid`), so untyped functions can be
  called as statements.
- **NEW:** Hot loop detection overhead eliminated — `hotLoopCount` and
  `hotLoopCompiled` moved from hash tables (`Table`/`HashSet` on VM) to direct fields
  on `Chunk`, removing per-iteration hashing.
- **NEW:** JIT bool return type support — `jitReturnBool` field on `Proc`, set during
  codegen when return type is `bool`; the JIT wrapper returns `tyBool` instead of
  `tyInt` for bool-returning functions.

# v0.1.7 - 2026-07-05
- minor changes
- libgcc jit work

# v0.1.6 - 2026-07-04

- **FIX:** Empty arrays (`items: []`) now compile to `array[any]` instead of
  crashing with "Cannot create an empty array without type inference"
- **FIX:** Nested `for` loops on object dot-access (`for sub in item.items:`)
  no longer segfault — resolves to `items(item.items)` iteration
- **FIX:** `pushDefault` now handles `ttyArray` by emitting `opcConstrArray` with
  0 elements, enabling variable declarations with array types but no initial value
  (e.g. `var x: array[string]`)
- **NEW:** `CompilationPolicy` enforcement in codegen — `CodeGen` now has a
  `policy: CompilationPolicy` field (threaded through `initCompiler`/`initCodeGen`)
  that controls which features are allowed at compile time. Supports `policyAny`
  (wildcard), `policyImports`, `policyStdlib`, `policyPackages`, `policyLoops`,
  `policyConditionals`, `policyAssignments`, and `policyLoadDynlib`.
