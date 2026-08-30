# VanCode - policy
import std/options

type
  PolicyKind* = enum
    policyAny = "any"
    policyStdlib = "stdlib"
    policyPackages = "packages"
    policyImports = "imports"
    policyLoops = "loops"
    policyConditionals = "conditionals"
    policyAssignments = "assignments"
    policyLoadDynlib = "loadDynlib"

  CompilationPolicy* = object
    disallow*: set[PolicyKind]
