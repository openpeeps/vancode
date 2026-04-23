# A super fast template engine for cool kids
#
# (c) 2024 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/tim
import pkg/[nyml, semver]
from std/net import Port, `$`

when not defined napibuild:
  import pkg/openparser/json

export `$`

type
  ConfigType* = enum
    typeProject = "project"
    typePackage = "package"

  Requirement* = object
    id: string
    version: Version

  PolicyName* = enum
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
    allow: set[PolicyName]

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

# when not defined napibuild:
#   proc generateYaml*(c: TimConfig): string =
#     ## Generate a YAML representation of the TimConfig
#     ## This is used to generate the `tim.yml` file
#     let str =
#       if c.`type` == ConfigType.typePackage:
#         json.toJson(c, JsonOptions(
#           skipFields: @["type", "compilation", "browser_sync"]
#         ))
#       else:
#         json.toJson(c)
#     dump(json.fromJson(str))

#   proc `$`*(c: TimConfig): string = 
#     ## Generate a string representation of the TimConfig
#     ## using `pkg/voodoo`
#     json.toJson(c)

# proc getBasePath*(config: TimConfig): string =
#   return config.compilation.basePath