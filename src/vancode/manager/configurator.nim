# Shim — configurator is deprecated, use vancode/interpreter/policy
import ../interpreter/policy
export policy

# Legacy types kept for one release for tim compat
import std/options
type
  ConfigType* {.deprecated: "ConfigType moved, use Tim's own config".} = enum
    typeProject = "project"
    typePackage = "package"

  CompilationSettings* {.deprecated.} = object
    source*, output*: string
    layoutsPath*, viewsPath*, partialsPath*: string
    basePath*: string
    policy*: CompilationPolicy
    release*: bool

  PackageConfig* {.deprecated: "PackageConfig moved to Tim/generic packager".} = ref object
    name*, version*, description*, license*: string
    requires*: seq[string]
    case `type`*: ConfigType
    of typeProject: compilation*: CompilationSettings
    else: discard
