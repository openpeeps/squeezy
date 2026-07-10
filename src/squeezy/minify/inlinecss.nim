# A dead simple JavaScript and CSS validator, bundler and minifier
#
# (c) 2025 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/squeezy

import std/strutils
import ./private

type
  CssMinifier*  = object of Minifier
    ## Minifier for raw CSS content, with options to preserve comments and/or whitespace

proc minify*(m: CssMinifier; css: string): string =
  ## Minify a chunk of CSS: strip /* comments */, collapse whitespace,
  ## remove unnecessary spaces around punctuation and drop the last
  ## semicolon before a closing brace.
  type CssState = enum
    cssNormal, cssSQuote, cssDQuote, cssComment, cssUrl, cssUrlSQuote, cssUrlDQuote

  var
    i = 0
    pendingWs = false
    prevSig: char = '\0'
    escape = false
    state = cssNormal

  result = newStringOfCap(css.len)

  template emit(ch: char) =
    result.add(ch)
    if not ch.isSpaceAscii:
      prevSig = ch

  while i < css.len:
    let c = css[i]
    let n = if i + 1 < css.len: css[i + 1] else: '\0'

    case state
    of cssNormal:
      # comments
      if c == '/' and n == '*':
        state = cssComment
        i += 2
        continue

      # strings
      elif c == '\'':
        if pendingWs:
          if needsSpace(prevSig, c): emit(' ')
          pendingWs = false
        emit(c); state = cssSQuote; escape = false; i += 1; continue
      elif c == '"':
        if pendingWs:
          if needsSpace(prevSig, c): emit(' ')
          pendingWs = false
        emit(c); state = cssDQuote; escape = false; i += 1; continue

      # detect url( case (case-insensitive)
      elif c.toLowerAscii == 'u' and i + 3 < css.len and
           css[i+1].toLowerAscii == 'r' and css[i+2].toLowerAscii == 'l':
        # emit 'url' and then expect '(' possibly after spaces
        pendingWs = false
        emit('u'); emit('r'); emit('l')
        var j = i + 3
        # skip spaces between url and '('
        while j < css.len and css[j].isSpaceAscii:
          j += 1
        if j < css.len and css[j] == '(':
          # before entering url state, ensure we emit '(' and advance
          emit('(')
          i = j + 1
          state = cssUrl
          continue
        else:
          i = j
          continue

      # whitespace handling
      elif c.isSpaceAscii:
        pendingWs = true
        i += 1
        continue

      else:
        # punctuation where we usually remove surrounding spaces
        if c in {':', ';', '{', '}', '(', ')', ',', '>', '+', '~', '='}:
          # drop any emitted trailing space before punctuation
          if result.len > 0 and result[^1].isSpaceAscii:
            result.setLen(result.len - 1)
          # if closing brace, drop trailing semicolon if present
          if c == '}' and result.len > 0 and result[^1] == ';':
            result.setLen(result.len - 1)
          # emit punctuation
          emit(c)
          pendingWs = false
          i += 1
          continue
        else:
          if pendingWs:
            if needsSpace(prevSig, c):
              emit(' ')
            pendingWs = false
          emit(c)
          i += 1
          continue

    of cssComment:
      # skip until */
      if c == '*' and n == '/':
        state = cssNormal
        i += 2
      else:
        i += 1

    of cssSQuote:
      emit(c)
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == '\'':
        state = cssNormal
      i += 1

    of cssDQuote:
      emit(c)
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == '"':
        state = cssNormal
      i += 1

    of cssUrl:
      # inside url(...) copies until matching ')' while honoring quotes
      if c == '\'':
        emit(c); state = cssUrlSQuote; escape = false; i += 1; continue
      elif c == '"':
        emit(c); state = cssUrlDQuote; escape = false; i += 1; continue
      elif c == ')':
        # trim trailing whitespace inside url(...) (common minifier behavior)
        while result.len > 0 and result[^1].isSpaceAscii:
          result.setLen(result.len - 1)
        emit(')')
        state = cssNormal
        i += 1
        continue
      else:
        # emit verbatim (including spaces inside url)
        emit(c)
        i += 1
        continue

    of cssUrlSQuote:
      emit(c)
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == '\'':
        state = cssUrl
      i += 1

    of cssUrlDQuote:
      emit(c)
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == '"':
        state = cssUrl
      i += 1

  # final cleanup: remove leading/trailing whitespace
  result = result.strip()

proc minifyInlineCSS*(css: sink string): owned string =
  ## Minify a chunk of CSS: strip /* comments */, collapse whitespace,
  ## remove unnecessary spaces around punctuation and drop the last
  ## semicolon before a closing brace.
  var minifier = CssMinifier(preserveComments: false, preserveWhitespace: false)
  minifier.minify(css)