# DEPRECATED — Packager will be removed, use vancode/interpreter/manager.ModuleManager
# Kept for Tim compat until migrated to generic package generator.
{.warning: "vancode/manager/packager is deprecated, use vancode/interpreter/manager".}
# VanCode - A fast, extensible bytecode generator and VM for building
# Domain-Specific Languages (DSLs), or general-purpose programming language
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/vancode

import std/[tables, strutils, os, osproc, options, sequtils]
import pkg/openparser/[json, yaml]
import pkg/[semver, checksums/md5]
import pkg/flysystem
import ../interpreter/ast

import ./remote, ./configurator, ./fbe_ast
export fbe_ast, configurator, flysystem

type
  VersionedPackage*[C] = OrderedTableRef[string, C]
  PackagesTable*[C] = OrderedTableRef[string, VersionedPackage[C]]
  Packager*[C] = ref object
    driver*: LocalDriver
      ## Flysystem driver rooted at the packager home (default ~/.tim)
    remote*: RemoteSource
    packages*: PackagesTable[C]
      # An ordered table containing a versioned
      # table of `Package`
    flagNoCache*: bool
    flagRecache*: bool

# Default aliases for backward compat — Tim uses Packager[TimConfig], vancode uses Packager[PackageConfig]
type
  DefaultPackager* = Packager[PackageConfig]

const
  pkgrHomeDir* = getHomeDir() / ".tim"
  pkgrHomeDirTemp* = pkgrHomeDir / "tmp"
  pkgrPackagesDir* = pkgrHomeDir / "packages"
  pkgrTokenPath* = pkgrHomeDir / ".env"
  pkgrPackageCachedDir* = pkgrPackagesDir / "$1" / "$2" / ".cache"
  pkgrPackageSourceDir* = pkgrPackagesDir / "$1" / "$2" / "src"
  pkgrIndexPath* = pkgrPackagesDir / "index.json"

# Flysystem-relative paths (used with driver)
const
  relPackagesDir* = "packages"
  relIndexPath* = "packages/index.json"
  relTmpDir* = "tmp"
  relPackageCachedDir* = "packages/$1/$2/.cache"
  relPackageSourceDir* = "packages/$1/$2/src"

proc defaultPackagerRoot*(): string =
  ## Default root for the packager filesystem (Tim home)
  getHomeDir() / ".tim"

proc initPackager*[C](root = defaultPackagerRoot()): Packager[C] =
  ## Initialize a packager with a Flysystem LocalDriver rooted at `root`.
  ## Creates root, tmp and packages directories via Flysystem.
  let driver = newLocalDriver(root)
  # Ensure base directories exist
  # newLocalDriver already creates root; ensure subdirs
  driver.makeDir(relTmpDir)
  driver.makeDir(relPackagesDir)
  result = Packager[C](driver: driver)

proc initPackageRemote*[C](root = defaultPackagerRoot()): Packager[C] =
  ## Initialize Tim Engine Packager with Remote Source
  result = initPackager[C](root)
  if not result.driver.exists(".tokens"):
    result.driver.write(".tokens", "")
  result.remote = initRemoteSource(result.driver.root)

proc hasPackage*[C](pkgr: Packager[C], pkgName: string): bool =
  ## Determine if a `pkgName` is installed
  if pkgr.packages == nil: return false
  result = pkgr.packages.hasKey(pkgName)
  if result:
    result = pkgr.driver.exists(relPackagesDir / pkgName)
    if result:
      result = pkgr.driver.exists(relPackageSourceDir % [pkgName, "0.1.0"])

proc updatePackages*[C](pkgr: Packager[C]) =
  ## Update packages index
  pkgr.driver.write(relIndexPath, toJson(pkgr.packages))

proc createPackage*[C](pkgr: Packager[C], orgName, pkgName: string, pkgConfig: C): bool =
  ## Create package directory for `pkgConfig`
  ## Returns `true` if succeed.
  # C is expected to have `name` and `version: string` fields (PackageConfig/TimConfig)
  if pkgr.packages == nil:
    new(pkgr.packages)
  let v = pkgConfig.version
  pkgr.driver.makeDir(relPackagesDir / pkgConfig.name)
  let relTempPath = relTmpDir / pkgConfig.name & "@" & v & ".tar"
  let relPkgPath = relPackagesDir / pkgConfig.name / v
  # Use driver.exists for checks, but need absolute paths for tar/disk ops
  if not pkgr.driver.exists(relPkgPath):
    if not pkgr.driver.exists(relTempPath):
      let absTempPath = pkgr.driver.root / relTempPath
      if pkgr.remote.download("repo_tarball_ref", absTempPath, @[orgName, pkgName, "main"]):
        let absPkgPath = pkgr.driver.root / relPkgPath
        discard execProcess("tar", args = ["-xzf", absTempPath, "-C", absPkgPath, "--strip-components=1"],
          options = {poStdErrToStdOut, poUsePath})
        result = true
    else:
      let absTempPath = pkgr.driver.root / relTempPath
      let absPkgPath = pkgr.driver.root / relPkgPath
      discard execProcess("tar", args = ["-xzf", absTempPath, "-C", absPkgPath, "--strip-components=1"],
        options = {poStdErrToStdOut, poUsePath})
      result = true
  if result:
    if not pkgr.packages.hasKey(pkgConfig.name):
      pkgr.packages[pkgConfig.name] = VersionedPackage[C]()
    pkgr.packages[pkgConfig.name][v] = pkgConfig

proc deletePackage*[C](pkgr: Packager[C], pkgName: string, pkgVersion: Option[Version] = none(Version)) =
  ## Delete a package by name and semantic version (when provided).
  ## Running the `remove` command over an aliased package
  ## will delete de alias and keep the original package folder in place
  let pkgConfig = pkgr.packages[pkgName]
  let version =
    if pkgVersion.isSome:
      # use the specified version
      $(pkgVersion.get())
    else:
      # always choose the latest version
      let versions = pkgConfig.keys.toSeq
      pkgConfig[versions[versions.high]].version
  echo pkgr.driver.root / (relPackagesDir / pkgConfig[version].name / version)

proc loadModule*[C](pkgr: Packager[C], pkgName: string): string =
  ## Load a Tim Engine module from a specific package
  let pkgName = pkgName[4..^1].split("/")
  let relPkgPath = relPackageSourceDir % [pkgName[0], "0.1.0"]
  result = pkgr.driver.read(relPkgPath / pkgName[1..^1].join("/") & ".timl")

proc getModulePath*[C](pkgr: Packager[C], pkgName, path: string): string =
  ## Get the file path of a Tim Engine module from a specific package
  let relPkgPath = relPackageSourceDir % [pkgName, "0.1.0"]
  result = pkgr.driver.root / (relPkgPath / path & ".timl")
  result = normalizedPath(result)

proc cacheModule*[C](pkgr: Packager[C], pkgName: string, ast: Ast, version: uint32) =
  ## Cache a Tim Engine module to binary AST via FBE using Flysystem
  let pkgName = pkgName[4..^1].split("/")
  let relCachePath = relPackageCachedDir % [pkgName[0], "0.1.0"]
  let relCacheAstPath = relCachePath / getMD5(pkgName[1..^1].join("/")) & ".ast"
  pkgr.driver.makeDir(relCachePath)
  pkgr.driver.write(relCacheAstPath, toFbe(ast, version))

proc getCachedModule*[C](pkgr: Packager[C], pkgName: string, version: uint32): Ast =
  ## Retrieve a cached binary AST via FBE using Flysystem
  let pkgName = pkgName[4..^1].split("/")
  let relCachePath = relPackageCachedDir % [pkgName[0], "0.1.0"]
  let relCacheAstPath = relCachePath / getMD5(pkgName[1..^1].join("/")) & ".ast"
  if pkgr.driver.exists(relCacheAstPath):
    result = fromFbe(pkgr.driver.read(relCacheAstPath), Ast, version)

proc hasLoadedPackages*[C](pkgr: Packager[C]): bool =
  ## Determine if packager has loaded the local database in memory
  pkgr.packages != nil

proc loadPackages*[C](pkgr: Packager[C]) =
  ## Load the local database of packages in memory
  if pkgr.driver.exists(relIndexPath):
    let db = pkgr.driver.read(relIndexPath)
    if db.len > 0:
      pkgr.packages = fromJson(db, PackagesTable[C])
      return
  new(pkgr.packages)
