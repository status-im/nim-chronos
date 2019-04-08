type
  SrcLoc* = object
    file*: cstring
    line*: int

proc `$`*(loc: ptr SrcLoc): string =
  result.add loc.file
  result.add ":"
  result.add $loc.line

proc srcLocImpl(file: static string, line: static int): ptr SrcLoc =
  var loc {.global.} = SrcLoc(file: cstring(file), line: line)
  return addr(loc)

template getSrcLocation*(): ptr SrcLoc =
  srcLocImpl(instantiationInfo(-2).filename, instantiationInfo(-2).line)
