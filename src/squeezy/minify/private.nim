# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy
import std/strutils

type
  Minifier* = object of RootObj
    ## Base type for minifiers, with options to preserve comments and/or whitespace
    preserveComments*: bool
      ## If true, comments will be preserved in the minified output. Default is false.
    preserveWhitespace*: bool
      ## If true, extra whitespace will be preserved in the minified output. Default is false.

proc isIdentChar*(c: char): bool =
  ## Checks if a character can be part of a JavaScript identifier (letter, digit, underscore, or dollar sign).
  c.isAlphaAscii or c.isDigit or c == '_' or c == '$'

proc needsSpace*(a, b: char): bool =
  ## Determines if a space is needed between two characters to prevent them from merging into a single token.
  (isIdentChar(a) and isIdentChar(b)) or
  (a == '+' and b == '+') or
  (a == '-' and b == '-')
