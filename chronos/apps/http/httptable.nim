#
#        Chronos HTTP/S case-insensitive non-unique
#              key-value memory storage
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import std/[tables, strutils]

type
  HttpTable* = object
    table: Table[string, seq[string]]

  HttpTableRef* = ref HttpTable

  HttpTables* = HttpTable | HttpTableRef

proc `-`(x: uint32): uint32 {.inline.} =
  (0xFFFF_FFFF'u32 - x) + 1'u32

proc LT(x, y: uint32): uint32 {.inline.} =
  let z = x - y
  (z xor ((y xor x) and (y xor z))) shr 31

proc decValue(c: byte): int =
  let x = uint32(c) - 0x30'u32
  let r = ((x + 1'u32) and -LT(x, 10))
  int(r) - 1

proc bytesToDec*[T: byte|char](src: openarray[T]): uint64 =
  var v = 0'u64
  for i in 0 ..< len(src):
    let d =
      when T is byte:
        decValue(src[i])
      else:
        decValue(byte(src[i]))
    if d < 0:
      # non-decimal character encountered
      return v
    else:
      let nv = ((v shl 3) + (v shl 1)) + uint64(d)
      if nv < v:
        # overflow happened
        return v
      else:
        v = nv
  v

proc add*(ht: var HttpTables, key: string, value: string) =
  let lowkey = key.toLowerAscii()
  var nitem = @[value]
  if ht.table.hasKeyOrPut(lowkey, nitem):
    var oitem = ht.table[lowkey]
    oitem.add(value)
    ht.table[lowkey] = oitem

proc add*(ht: var HttpTables, key: string, value: SomeInteger) =
  ht.add(key, $value)

proc set*(ht: var HttpTables, key: string, value: string) =
  let lowkey = key.toLowerAscii()
  ht.table[lowkey] = @[value]

proc contains*(ht: var HttpTables, key: string): bool =
  ht.table.contains(key.toLowerAscii())

proc getList*(ht: HttpTables, key: string,
              default: openarray[string] = []): seq[string] =
  var defseq = @default
  ht.table.getOrDefault(key.toLowerAscii(), defseq)

proc getString*(ht: HttpTables, key: string,
                default: string = ""): string =
  var defseq = newSeq[string]()
  let res = ht.table.getOrDefault(key.toLowerAscii(), defseq)
  if len(res) == 0:
    return default
  else:
    res.join(",")

proc count*(ht: HttpTables, key: string): int =
  var default: seq[string]
  len(ht.table.getOrDefault(key, default))

proc getInt*(ht: HttpTables, key: string): uint64 =
  bytesToDec(ht.getString(key))

proc getLastString*(ht: HttpTables, key: string): string =
  var default: seq[string]
  let item = ht.table.getOrDefault(key.toLowerAscii(), default)
  if len(item) == 0:
    ""
  else:
    item[^1]

proc getLastInt*(ht: HttpTables, key: string): uint64 =
  bytesToDec(ht.getLastString())

proc init*(htt: typedesc[HttpTable]): HttpTable =
  HttpTable(table: initTable[string, seq[string]]())

proc new*(htt: typedesc[HttpTableRef]): HttpTableRef =
  HttpTableRef(table: initTable[string, seq[string]]())

proc init*(htt: typedesc[HttpTable],
           data: openArray[tuple[key: string, value: string]]): HttpTable =
  var res = HttpTable.init()
  for item in data:
    res.add(item.key, item.value)
  res

proc new*(htt: typedesc[HttpTableRef],
          data: openArray[tuple[key: string, value: string]]): HttpTableRef =
  var res = HttpTableRef.new()
  for item in data:
    res.add(item.key, item.value)
  res

proc isEmpty*(ht: HttpTables): bool =
  ## Returns ``true`` if HttpTable ``ht`` is empty (do not have any values).
  len(ht.table) == 0

proc normalizeHeaderName*(value: string): string =
  ## Set any header name to have first capital letters in their name
  ##
  ## For example:
  ## "content-length" become "<C>ontent-<L>ength"
  ## "expect" become "<E>xpect"
  var res = value.toLowerAscii()
  var k = 0
  while k < len(res):
    if k == 0:
      res[k] = toUpperAscii(res[k])
      inc(k, 1)
    else:
      if res[k] == '-':
        if k + 1 < len(res):
          res[k + 1] = toUpperAscii(res[k + 1])
          inc(k, 2)
        else:
          break
      else:
        inc(k, 1)
  res

iterator stringItems*(ht: HttpTables,
                      normalizeKey = false): tuple[key: string, value: string] =
  ## Iterate over HttpTable values.
  ##
  ## If ``normalizeKey`` is true, key name value will be normalized using
  ## normalizeHeaderName() procedure.
  for k, v in ht.table.pairs():
    let key = if normalizeKey: normalizeHeaderName(k) else: k
    for item in v:
      yield (key, item)

iterator items*(ht: HttpTables,
                normalizeKey = false): tuple[key: string, value: seq[string]] =
  ## Iterate over HttpTable values.
  ##
  ## If ``normalizeKey`` is true, key name value will be normalized using
  ## normalizeHeaderName() procedure.
  for k, v in ht.table.pairs():
    let key = if normalizeKey: normalizeHeaderName(k) else: k
    yield (key, v)

proc `$`*(ht: HttpTables): string =
  var res = ""
  for key, value in ht.table.pairs():
    for item in value:
      res.add(key.normalizeHeaderName())
      res.add(": ")
      res.add(item)
      res.add("\p")
  res
