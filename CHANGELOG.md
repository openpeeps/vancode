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
