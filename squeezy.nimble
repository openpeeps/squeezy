# Package

version       = "0.1.1"
author        = "George Lemon"
description   = "JS & CSS validator, bundler and minifier"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
installDirs   = @["squeezy"]
bin           = @["squeezy"]
binDir        = "bin"


# Dependencies

requires "nim >= 2.0.0"
requires "openparser >= 0.1.5"
requires "sweetsyntax >= 0.2.2"