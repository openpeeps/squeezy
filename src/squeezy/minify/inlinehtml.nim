# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy
import std/strutils

import ./private
import ./inlinejs, ./inlinecss

type
  HtmlMinifier*  = object of Minifier
    ## Minifier for raw HTML content, with options to preserve comments and/or whitespace

const rawTags = ["pre", "code", "textarea", "script", "style"]

proc minify*(m: HtmlMinifier; code: string): string =
  ## Minify raw HTML by collapsing whitespace and removing comments,
  ## while preserving content inside <pre>, <code>, <textarea>, <script> and <style>.
  var
    i = 0
    pendingWs = false
    prevSig: char = '\0'
    rawTag = ""
    inRaw = false

  result = newStringOfCap(code.len)

  template emit(ch: char) =
    result.add(ch)
    if not ch.isSpaceAscii: prevSig = ch

  template emitStr(s: string) =
    if s.len == 0: return
    result.add(s)
    let last = s[^1]
    if not last.isSpaceAscii: prevSig = last

  proc parseTagName(pos: int): (string, int) =
    var j = pos; var name = ""
    while j < code.len and isIdentChar(code[j]):
      name.add(code[j].toLowerAscii); j.inc()
    (name, j)

  while i < code.len:
    let c = code[i]

    # ── inside a raw tag body ────────────────────────────────────────────────
    if inRaw:
      if c == '<' and i + 1 < code.len and code[i+1] == '/':
        var j = i + 2; var name = ""
        while j < code.len and isIdentChar(code[j]):
          name.add(code[j].toLowerAscii); j.inc()
        if name == rawTag:
          emitStr("</"); emitStr(name)
          while j < code.len and code[j].isSpaceAscii: j.inc()
          while j < code.len and code[j] != '>': emit(code[j]); j.inc()
          if j < code.len and code[j] == '>': emit('>'); j.inc()
          i = j; inRaw = false; rawTag = ""; pendingWs = false
          continue
        else:
          emit(c); i.inc(); continue
      else:
        result.add(c); i.inc(); continue

    # ── normal content ───────────────────────────────────────────────────────
    if c == '<':
      # HTML comment
      if i + 3 < code.len and code[i+1] == '!' and code[i+2] == '-' and code[i+3] == '-':
        if i + 4 < code.len and code[i+4] == '[':
          # preserve conditional comments <!--[if ...]>
          var j = i
          while j + 2 < code.len and not (code[j] == '-' and code[j+1] == '-' and code[j+2] == '>'):
            result.add(code[j]); j.inc()
          if j + 2 < code.len:
            result.add('-'); result.add('-'); result.add('>'); j += 3
          i = j; prevSig = '>'
        else:
          # strip comment entirely
          var j = i + 4
          while j + 2 < code.len and not (code[j] == '-' and code[j+1] == '-' and code[j+2] == '>'):
            j.inc()
          if j + 2 < code.len: j += 3
          i = j; pendingWs = false
        continue

      # normal tag — emit '<', optional '/', tag name
      emit('<'); i.inc()
      var closing = false
      if i < code.len and code[i] == '/':
        emit('/'); closing = true; i.inc()
      while i < code.len and code[i].isSpaceAscii: i.inc()

      let (tname, after) = parseTagName(i)
      if tname.len > 0: emitStr(tname); i = after

      # emit attributes, collapsing runs of whitespace to a single space
      var inS = false; var inD = false
      while i < code.len and code[i] != '>':
        let ch = code[i]
        if   ch == '\'' and not inD: emit(ch); inS = not inS
        elif ch == '"'  and not inS: emit(ch); inD = not inD
        elif ch.isSpaceAscii and not inS and not inD:
          var j = i
          while j < code.len and code[j].isSpaceAscii: j.inc()
          if result.len > 0 and result[^1] notin {'<', '/', ' '}: emit(' ')
          i = j - 1
        else: emit(ch)
        i.inc()

      if i < code.len and code[i] == '>': emit('>'); i.inc()

      # enter raw mode and optionally minify inline content
      if not closing and tname in rawTags:
        rawTag = tname; inRaw = true
        if rawTag in ["script", "style"]:
          var j = i; var content = ""
          while j < code.len:
            if code[j] == '<' and j + 1 < code.len and code[j+1] == '/':
              var k = j + 2; var cname = ""
              while k < code.len and isIdentChar(code[k]):
                cname.add(code[k].toLowerAscii); k.inc()
              if cname == rawTag: break
            content.add(code[j]); j.inc()
          if content.len > 0:
            case rawTag
            of "script": result.add(minifyInlineJs(content))
            of "style":  result.add(minifyInlineCSS(content))
            else: discard
          i = j
      continue

    elif c.isSpaceAscii:
      pendingWs = true; i.inc()

    else:
      if pendingWs:
        if needsSpace(prevSig, c): emit(' ')
        pendingWs = false
      emit(c); i.inc()