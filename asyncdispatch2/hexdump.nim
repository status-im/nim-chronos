#
# Copyright (c) 2016 Eugene Kabanov <ka@hardcore.kiev.ua>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

from strutils import toHex, repeat

proc dumpHex*(pbytes: pointer, nbytes: int, items = 1, ascii = true): string =
  ## Return hexadecimal memory dump representation pointed by ``p``.
  ## ``nbytes`` - number of bytes to show
  ## ``items``  - number of bytes in group (supported ``items`` count is
  ##  1, 2, 4, 8)
  ## ``ascii``  - if ``true`` show ASCII representation of memory dump.
  result = ""
  let hexSize = items * 2
  var i = 0
  var slider = pbytes
  var asciiText = ""
  while i < nbytes:
    if i %% 16 == 0:
      result = result & toHex(cast[BiggestInt](slider),
                              sizeof(BiggestInt) * 2) & ":  "
    var k = 0
    while k < items:
      var ch = cast[ptr char](cast[uint](slider) + k.uint)[]
      if ord(ch) > 31 and ord(ch) < 127: asciiText &= ch else: asciiText &= "."
      inc(k)
    case items:
    of 1:
      result = result & toHex(cast[BiggestInt](cast[ptr uint8](slider)[]),
                              hexSize)
    of 2:
      result = result & toHex(cast[BiggestInt](cast[ptr uint16](slider)[]),
                              hexSize)
    of 4:
      result = result & toHex(cast[BiggestInt](cast[ptr uint32](slider)[]),
                              hexSize)
    of 8:
      result = result & toHex(cast[BiggestInt](cast[ptr uint64](slider)[]),
                              hexSize)
    else:
      raise newException(ValueError, "Wrong items size!")
    result = result & " "
    slider = cast[pointer](cast[uint](slider) + items.uint)
    i = i + items
    if i %% 16 == 0:
      result = result & " " & asciiText
      asciiText.setLen(0)
      result = result & "\n"

  if i %% 16 != 0:
    var spacesCount = ((16 - (i %% 16)) div items) * (hexSize + 1) + 1
    result = result & repeat(' ', spacesCount)
    result = result & asciiText
  result = result & "\n"

proc dumpHex*[T](v: openarray[T], items: int = 0, ascii = true): string =
  ## Return hexadecimal memory dump representation of openarray[T] ``v``.
  ## ``items``  - number of bytes in group (supported ``items`` count is
  ##  0, 1, 2, 4, 8). If ``items`` is ``0`` group size will depend on
  ## ``sizeof(T)``.
  ## ``ascii``  - if ``true`` show ASCII representation of memory dump.
  var i = 0
  if items == 0:
    when sizeof(T) == 2:
      i = 2
    elif sizeof(T) == 4:
      i = 4
    elif sizeof(T) == 8:
      i = 8
    else:
      i = 1
  else:
    i = items
  result = dumpHex(unsafeAddr v[0], sizeof(T) * len(v), i, ascii)
