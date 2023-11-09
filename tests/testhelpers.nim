#                Chronos Test Suite
#            (c) Copyright 2019-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

func toBytes*(src: openArray[char]): seq[byte] =
  var default: seq[byte]
  if len(src) > 0:
    var dst = newSeq[byte](len(src))
    copyMem(addr dst[0], unsafeAddr src[0], len(src))
    dst
  else:
    default

func toString*(src: openArray[byte]): string =
  var default: string
  if len(src) > 0:
    var dst = newString(len(src))
    copyMem(addr dst[0], unsafeAddr src[0], len(src))
    dst
  else:
    default
