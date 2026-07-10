import std/[json, tables, algorithm]

type
  SegmentEntry* = object
    genCol*: int
    sourceIdx*: int
    origLine*: int
    origCol*: int
    nameIdx*: int

  SourceMap* = ref object
    file*: string
    sources*: seq[string]
    sourcesContent*: seq[string]
    names*: seq[string]
    nameTable*: Table[string, int]
    lines*: seq[seq[SegmentEntry]]

proc newSourceMap*(file: string): SourceMap =
  SourceMap(file: file, nameTable: initTable[string, int]())

proc addSource*(sm: SourceMap, source: string, content: string): int =
  result = sm.sources.len
  sm.sources.add(source)
  sm.sourcesContent.add(content)

proc addName*(sm: SourceMap, name: string): int =
  if name in sm.nameTable:
    return sm.nameTable[name]
  result = sm.names.len
  sm.names.add(name)
  sm.nameTable[name] = result

proc ensureLine(sm: SourceMap, line: int) =
  while sm.lines.len <= line:
    sm.lines.add(@[])

proc addMapping*(sm: SourceMap, genLine, genCol, srcLine, srcCol, sourceIdx: int, nameIdx: int = -1) =
  ensureLine(sm, genLine)
  sm.lines[genLine].add(SegmentEntry(
    genCol: genCol, sourceIdx: sourceIdx,
    origLine: srcLine, origCol: srcCol, nameIdx: nameIdx
  ))

const Base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc encodeVLQ*(value: int): string =
  var v = if value < 0: (-value shl 1) or 1 else: value shl 1
  while true:
    var digit = v and 0x1F
    v = v shr 5
    if v > 0:
      digit = digit or 0x20
    result.add(Base64Chars[digit])
    if v == 0: break

proc generateMappings*(sm: SourceMap): string =
  for lineIdx, segments in sm.lines:
    if lineIdx > 0:
      result.add(';')
    var prevGenCol, prevSourceIdx, prevOrigLine, prevOrigCol, prevNameIdx: int
    if segments.len == 0:
      continue
    let sorted = segments.sorted do (a, b: SegmentEntry) -> int: cmp(a.genCol, b.genCol)
    for i, seg in sorted:
      if i > 0:
        result.add(',')
      result.add(encodeVLQ(seg.genCol - prevGenCol))
      result.add(encodeVLQ(seg.sourceIdx - prevSourceIdx))
      result.add(encodeVLQ(seg.origLine - prevOrigLine))
      result.add(encodeVLQ(seg.origCol - prevOrigCol))
      if seg.nameIdx >= 0:
        result.add(encodeVLQ(seg.nameIdx - prevNameIdx))
      prevGenCol = seg.genCol
      prevSourceIdx = seg.sourceIdx
      prevOrigLine = seg.origLine
      prevOrigCol = seg.origCol
      if seg.nameIdx >= 0:
        prevNameIdx = seg.nameIdx

proc generate*(sm: SourceMap, sourceRoot: string = ""): string =
  var obj = %*{
    "version": 3,
    "file": sm.file,
    "sources": sm.sources,
    "sourcesContent": sm.sourcesContent,
    "names": sm.names,
    "mappings": sm.generateMappings()
  }
  if sourceRoot.len > 0:
    obj["sourceRoot"] = %sourceRoot
  result = $obj
