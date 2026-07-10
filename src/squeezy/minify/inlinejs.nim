# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/strutils
import ./private

type
  JsState = enum
    jsNormal, jsSQuote, jsDQuote, jsTemplate, jsRegex,
    jsLineComment, jsBlockComment

  JSMinifier* = object of Minifier
    ## Minifier for inline JavaScript code, with options to preserve comments and/or whitespace

proc canStartRegex(prevSig: char; lastWord: string): bool =
  if prevSig == '\0': return true
  if prevSig in {'(', '[', '{', ':', ';', ',', '=', '!', '?', '&', '|',
                 '+', '-', '*', '%', '^', '~', '<', '>'}:
    return true
  lastWord in ["return", "throw", "case", "delete", "void", "typeof",
               "instanceof", "in", "new", "else", "do"]

proc shouldInsertSemi(prevSig, next: char; lastWord: string): bool =
  if lastWord in ["return", "throw", "break", "continue", "yield", "await"]:
    return true
  let prevCanEnd = isIdentChar(prevSig) or prevSig in {'"', '\'', '`', ')', ']', '}'}
  let nextCanStart = isIdentChar(next) or next in {'"', '\'', '`', '(', '[', '{'}
  prevCanEnd and nextCanStart

proc minify*(m: JSMinifier; code: string): string =
  ## Minify a chunk of JavaScript code by removing comments and unnecessary
  ## whitespace, while preserving string literals, template literals, and regexes.
  var
    st = jsNormal
    i = 0
    pendingWs = false
    pendingNl = false
    prevSig: char = '\0'
    lastWord = ""
    currWord = ""
    escape = false

  result = newStringOfCap(code.len)

  template emit(ch: char) =
    result.add(ch)
    if not ch.isSpaceAscii:
      prevSig = ch
      if isIdentChar(ch):
        currWord.add(ch)
      else:
        if currWord.len > 0:
          lastWord = currWord
          currWord.setLen(0)

  while i < code.len:
    let c = code[i]
    let n = if i + 1 < code.len: code[i + 1] else: '\0'

    case st
    of jsNormal:
      if c == '/' and n == '/':
        st = jsLineComment; i += 2; continue
      elif c == '/' and n == '*':
        st = jsBlockComment; i += 2; continue
      elif c.isSpaceAscii:
        if c == '\n' or c == '\r':
          pendingNl = true
          pendingWs = false
        else:
          pendingWs = true
      else:
        # flush pending whitespace / newline
        if pendingNl:
          if shouldInsertSemi(prevSig, c, lastWord): emit(';')
          elif needsSpace(prevSig, c): emit(' ')
          pendingNl = false; pendingWs = false
        elif pendingWs:
          if needsSpace(prevSig, c): emit(' ')
          pendingWs = false
        # dispatch on current character
        case c
        of '\'': emit(c); st = jsSQuote
        of '"':  emit(c); st = jsDQuote
        of '`':  emit(c); st = jsTemplate
        of '/':
          if canStartRegex(prevSig, lastWord): emit(c); st = jsRegex
          else: emit(c)
        else: emit(c)

    of jsLineComment:
      if c == '\n' or c == '\r':
        st = jsNormal; pendingNl = true

    of jsBlockComment:
      if c == '*' and n == '/':
        st = jsNormal; pendingWs = true; i.inc()

    of jsSQuote:
      emit(c)
      if escape: escape = false
      elif c == '\\': escape = true
      elif c == '\'': st = jsNormal

    of jsDQuote:
      emit(c)
      if escape: escape = false
      elif c == '\\': escape = true
      elif c == '"': st = jsNormal

    of jsTemplate:
      emit(c)
      if escape: escape = false
      elif c == '\\': escape = true
      elif c == '`': st = jsNormal

    of jsRegex:
      emit(c)
      if escape: escape = false
      elif c == '\\': escape = true
      elif c == '/':
        st = jsNormal
        # consume trailing flags: /gi, /gim, etc.
        var j = i + 1
        while j < code.len and code[j].isAlphaAscii:
          emit(code[j]); j.inc()
        i = j - 1

    i.inc()

  # flush any remaining word
  if currWord.len > 0:
    lastWord = currWord

proc minifyInlineJS*(code: sink string): owned string =
  ## Minify a chunk of JavaScript code by removing comments and unnecessary
  ## whitespace, while preserving string literals, template literals, and regexes.
  var minifier = JSMinifier(preserveComments: false, preserveWhitespace: false)
  minifier.minify(code)