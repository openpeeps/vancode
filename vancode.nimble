# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "A cool Codegen and VM library for Nim"
license       = "LGPL-3.0-or-later"
srcDir        = "src"
binDir        = "bin"
bin           = @["vancode"]


# Dependencies

requires "nim >= 2.0.0"
requires "gccjit"
requires "voodoo#head"
requires "openparser#head"
requires "flatty#head"
requires "checksums"
requires "dotenv"
requires "nyml"
requires "semver"