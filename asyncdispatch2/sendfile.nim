#
#               Asyncdispatch2 SendFile
#                 (c) Copyright 2018
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module provides cross-platform wrapper for ``sendfile()`` syscall.

when defined(nimdoc):
  proc sendfile*(outfd, infd: int, offset: int, count: int): int =
    ## Copies data between file descriptor ``infd`` and ``outfd``. Because this
    ## copying is done within the kernel, ``sendfile()`` is more efficient than
    ## the combination of ``read(2)`` and ``write(2)``, which would require
    ## transferring data to and from user space.
    ## 
    ## ``infd`` should be a file descriptor opened for reading and
    ## ``outfd`` should be a descriptor opened for writing.
    ## 
    ## The ``infd`` argument must correspond to a file which supports
    ## ``mmap(2)``-like operations (i.e., it cannot be a socket).
    ## 
    ## ``offset`` the file offset from which ``sendfile()`` will start reading
    ## data from ``infd``.
    ## 
    ## ``count`` is the number of bytes to copy between the file descriptors.
    ## 
    ## If the transfer was successful, the number of bytes written to ``outfd``
    ## is returned.  Note that a successful call to ``sendfile()`` may write
    ## fewer bytes than requested; the caller should be prepared to retry the
    ## call if there were unsent bytes.
    ## 
    ## On error, ``-1`` is returned.

when defined(linux) or defined(android):

  proc osSendFile*(outfd, infd: cint, offset: ptr int, count: int): int
      {.importc: "sendfile", header: "<sys/sendfile.h>".}

  proc sendfile*(outfd, infd: int, offset: int, count: int): int =
    var o = offset
    result = osSendFile(cint(outfd), cint(infd), addr offset, count)

elif defined(freebsd) or defined(openbsd) or defined(netbsd) or
     defined(dragonflybsd):

  type
    sendfileHeader* = object {.importc: "sf_hdtr",
                               header: """#include <sys/types.h>
                                          #include <sys/socket.h>
                                          #include <sys/uio.h>""",
                               pure, final.}

  proc osSendFile*(outfd, infd: cint, offset: int, size: int,
                   hdtr: ptr sendfileHeader, sbytes: ptr int,
                   flags: int): int {.importc: "sendfile",
                                      header: """#include <sys/types.h>
                                                 #include <sys/socket.h>
                                                 #include <sys/uio.h>""".}

  proc sendfile*(outfd, infd: int, offset: int, count: int): int =
    var o = 0
    result = osSendFile(cint(outfd), cint(infd), offset, count, nil,
                        addr o, 0)

elif defined(macosx):

  type
    sendfileHeader* = object {.importc: "sf_hdtr",
                               header: """#include <sys/types.h>
                                          #include <sys/socket.h>
                                          #include <sys/uio.h>""",
                               pure, final.}

  proc osSendFile*(fd, s: cint, offset: int, size: ptr int,
                   hdtr: ptr sendfileHeader,
                   flags: int): int {.importc: "sendfile",
                                      header: """#include <sys/types.h>
                                                 #include <sys/socket.h>
                                                 #include <sys/uio.h>""".}

  proc sendfile*(outfd, infd: int, offset: int, count: int): int =
    var o = 0
    result = osSendFile(cint(fd), cint(s), offset, addr o, nil, 0)
