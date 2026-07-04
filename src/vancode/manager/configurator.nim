# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language# A super fast template engine for cool kids
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import pkg/[openparser/yaml, semver]
from std/net import Port, `$`

import pkg/openparser/[json, yaml]

export `$`

type
  ConfigType* = enum
    typeProject = "project"
    typePackage = "package"

  Requirement* = object
    id: string
    version: Version

  PolicyKind* = enum
    policyAny = "any"
      ## Allow all features (default)
    policyStdlib = "stdlib"
      ## Allow usage of the standard library
    policyPackages = "packages"
      ## Allow usage of packages
    policyImports = "imports"
      ## Allow import statements
    policyLoops = "loops"
      ## Allow for loops and while loops
    policyConditionals = "conditionals"
      ## Allow conditionals
    policyAssignments = "assignments"
      ## Allow variable assignments
    policyLoadDynlib = "loadDynlib"
      ## Allow loading dynamic libraries via FFI

  CompilationPolicy* = object
    disallow*: set[PolicyKind]

  CompilationSettings* = object
    source*, output*: string
    layoutsPath*, viewsPath*, partialsPath*: string
    basePath*: string
    policy*: CompilationPolicy
    release*: bool

  PackageConfig* = ref object
    name*: string
      ## Name of the package or project
      ## This must be a valid identifier
    version*: string
      ## The version of the package
    description*: string
      ## A short description of the package
    license*: string
      ## The license of the package
      ## See https://spdx.org/licenses/ for more information
    requires*: seq[string]
      ## A list of requirements for the package
      ## Each requirement must be a valid identifier
      ## and can be a version range, e.g. "tim >= 0.1.0"
    case `type`*: ConfigType
    of ConfigType.typeProject:
      compilation*: CompilationSettings
    else: discard

proc generateYaml*(c: PackageConfig): string =
  ## Generate a YAML representation of the PackageConfig
  ## This is used to generate the `tim.yml` file
  let str =
    if c.`type` == ConfigType.typePackage:
      json.toJson(c, JsonOptions(
        skipFields: @["type", "compilation", "browser_sync"]
      ))
    else:
      json.toJson(c)
  yaml.dump(json.fromJson(str))

proc `$`*(c: PackageConfig): string = 
  ## Generate a string representation of the PackageConfig
  ## using `pkg/voodoo`
  json.toJson(c)

# proc getBasePath*(config: PackageConfig): string =
#   return config.compilation.basePath