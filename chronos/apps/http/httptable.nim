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

{.push raises: [Defect].}

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
  # Procedure returns values [0..9] for character [`0`..`9`] and -1 for all
  # other characters.
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
        return 0xFFFF_FFFF_FFFF_FFFF'u64
      else:
        v = nv
  v

proc add*(ht: var HttpTables, key: string, value: string) =
  ## Add string ``value`` to header with key ``key``.
  var default: seq[string]
  ht.table.mgetOrPut(key.toLowerAscii(), default).add(value)

proc add*(ht: var HttpTables, key: string, value: SomeInteger) =
  ## Add integer ``value`` to header with key ``key``.
  ht.add(key, $value)

proc set*(ht: var HttpTables, key: string, value: string) =
  ## Set/replace value of header with key ``key`` to value ``value``.
  let lowkey = key.toLowerAscii()
  ht.table[lowkey] = @[value]

proc contains*(ht: var HttpTables, key: string): bool =
  ## Returns ``true`` if header with name ``key`` is present in HttpTable/Ref.
  ht.table.contains(key.toLowerAscii())

proc getList*(ht: HttpTables, key: string,
              default: openarray[string] = []): seq[string] =
  ## Returns sequence of headers with key ``key``.
  var defseq = @default
  ht.table.getOrDefault(key.toLowerAscii(), defseq)

proc getString*(ht: HttpTables, key: string,
                default: string = ""): string =
  ## Returns concatenated value of headers with key ``key``.
  ##
  ## If there multiple headers with the same name ``key`` the result value will
  ## be concatenation using `,`.
  var defseq: seq[string]
  let res = ht.table.getOrDefault(key.toLowerAscii(), defseq)
  if len(res) == 0:
    return default
  else:
    res.join(",")

proc count*(ht: HttpTables, key: string): int =
  ## Returns number of headers with key ``key``.
  var default: seq[string]
  len(ht.table.getOrDefault(key.toLowerAscii(), default))

proc getInt*(ht: HttpTables, key: string): uint64 =
  ## Parse header with key ``key`` as unsigned integer.
  ##
  ## Integers are parsed in safe way, there no exceptions or errors will be
  ## raised.
  ##
  ## If a non-decimal character is encountered during the parsing of the string
  ## the current accumulated value will be returned. So if string starts with
  ## non-decimal character, procedure will always return `0` (for example "-1"
  ## will be decoded as `0`). But if non-decimal character will be encountered
  ## later, only decimal part will be decoded, like `1234_5678` will be decoded
  ## as `1234`.
  ## Also, if in the parsing process result exceeds `uint64` maximum allowed
  ## value, then `0xFFFF_FFFF_FFFF_FFFF'u64` will be returned (for example
  ## `18446744073709551616` will be decoded as `18446744073709551615` because it
  ## overflows uint64 maximum value of `18446744073709551615`).
  bytesToDec(ht.getString(key))

proc getLastString*(ht: HttpTables, key: string): string =
  ## Returns "last" value of header ``key``.
  ##
  ## If there multiple headers with the same name ``key`` the value of last
  ## encountered header will be returned.
  var default: seq[string]
  let item = ht.table.getOrDefault(key.toLowerAscii(), default)
  if len(item) == 0:
    ""
  else:
    item[^1]

proc getLastInt*(ht: HttpTables, key: string): uint64 =
  ## Returns "last" value of header ``key`` as unsigned integer.
  ##
  ## If there multiple headers with the same name ``key`` the value of last
  ## encountered header will be returned.
  ##
  ## Unsigned integer will be parsed using rules of getInt() procedure.
  bytesToDec(ht.getLastString())

proc init*(htt: typedesc[HttpTable]): HttpTable =
  ## Create empty HttpTable.
  HttpTable(table: initTable[string, seq[string]]())

proc new*(htt: typedesc[HttpTableRef]): HttpTableRef =
  ## Create empty HttpTableRef.
  HttpTableRef(table: initTable[string, seq[string]]())

proc init*(htt: typedesc[HttpTable],
           data: openArray[tuple[key: string, value: string]]): HttpTable =
  ## Create HttpTable using array of tuples with header names and values.
  var res = HttpTable.init()
  for item in data:
    res.add(item.key, item.value)
  res

proc new*(htt: typedesc[HttpTableRef],
          data: openArray[tuple[key: string, value: string]]): HttpTableRef =
  ## Create HttpTableRef using array of tuples with header names and values.
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
                      normKey = false): tuple[key: string, value: string] =
  ## Iterate over HttpTable/Ref values.
  ##
  ## If ``normKey`` is true, key name value will be normalized using
  ## normalizeHeaderName() procedure.
  for k, v in ht.table.pairs():
    let key = if normKey: normalizeHeaderName(k) else: k
    for item in v:
      yield (key, item)

iterator items*(ht: HttpTables,
                normKey = false): tuple[key: string, value: seq[string]] =
  ## Iterate over HttpTable/Ref values.
  ##
  ## If ``normKey`` is true, key name value will be normalized using
  ## normalizeHeaderName() procedure.
  for k, v in ht.table.pairs():
    let key = if normKey: normalizeHeaderName(k) else: k
    yield (key, v)

proc `$`*(ht: HttpTables): string =
  ## Returns string representation of HttpTable/Ref.
  var res = ""
  for key, value in ht.table.pairs():
    for item in value:
      res.add(key.normalizeHeaderName())
      res.add(": ")
      res.add(item)
      res.add("\p")
  res
