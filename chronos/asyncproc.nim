#
#         Chronos' asynchronous process management
#
#  (c) Copyright 2022-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
{.push raises: [Defect].}

import std/[options, strtabs]
import "."/[asyncloop, handles, osdefs], streams/asyncstream
import stew/[results, byteutils]
export options, strtabs, results

const
  asyncProcShellPath* {.strdefine.} =
    when defined(windows):
      "cmd.exe"
    else:
      when defined(android):
        "/system/bin/sh"
      else:
        "/bin/sh"

  AsyncProcessTrackerName* = "async.process"
    ## AsyncProcess leaks tracker name

type
  AsyncProcessError* = object of CatchableError

  AsyncProcessResult*[T] = Result[T, OSErrorCode]

  AsyncProcessOption* {.pure.} = enum
    UsePath,
    EvalCommand,
    EchoCommand,
    StdErrToStdOut,
    ParentStreams,
    ProcessGroup

  StandardKind {.pure.} = enum
    Stdin, Stdout, Stderr

  ProcessFlag {.pure.} = enum
    UserStdin, UserStdout, UserStderr

  ProcessStreamHandleKind {.pure.} = enum
    None, Handle, Transport, StreamReader, StreamWriter

  ProcessStreamHandle* = object
    case kind: ProcessStreamHandleKind
    of ProcessStreamHandleKind.None:
      discard
    of ProcessStreamHandleKind.Handle:
      handle: AsyncFD
    of ProcessStreamHandleKind.Transport:
      transp: StreamTransport
    of ProcessStreamHandleKind.StreamReader:
      reader: AsyncStreamReader
    of ProcessStreamHandleKind.StreamWriter:
      writer: AsyncStreamWriter

  StreamHolderFlag {.pure.} = enum
    Transport, Stream

  StreamKind {.pure.} = enum
    None, Reader, Writer

  AsyncStreamHolder = object
    case kind: StreamKind
    of StreamKind.Reader:
      reader: AsyncStreamReader
    of StreamKind.Writer:
      writer: AsyncStreamWriter
    of StreamKind.None:
      discard
    flags: set[StreamHolderFlag]

  AsyncProcessPipes = object
    flags: set[ProcessFlag]
    stdinHolder: AsyncStreamHolder
    stdoutHolder: AsyncStreamHolder
    stderrHolder: AsyncStreamHolder
    stdinHandle: AsyncFD
    stdoutHandle: AsyncFD
    stderrHandle: AsyncFD

  AsyncProcessImpl = object of RootObj
    when defined(windows):
      processHandle: HANDLE
      threadHandle: HANDLE
      processId: DWORD
    else:
      processId: Pid
    pipes: AsyncProcessPipes
    exitStatus: Option[int]
    flags: set[ProcessFlag]
    options: set[AsyncProcessOption]

  AsyncProcessRef* = ref AsyncProcessImpl

  CommandExResponse* = object
    stdOutput*: string
    stdError*: string
    status*: int

  AsyncProcessTracker* = ref object of TrackerBase
    opened*: int64
    closed*: int64

proc setupAsyncProcessTracker(): AsyncProcessTracker {.
     gcsafe, raises: [Defect].}

proc getAsyncProcessTracker(): AsyncProcessTracker {.inline.} =
  var res = cast[AsyncProcessTracker](getTracker(AsyncProcessTrackerName))
  if isNil(res):
    res = setupAsyncProcessTracker()
  res

proc dumpAsyncProcessTracking(): string {.gcsafe.} =
  var tracker = getAsyncProcessTracker()
  let res = "Started async processes: " & $tracker.opened & "\n" &
            "Closed async processes: " & $tracker.closed
  res

proc leakAsyncProccessTracker(): bool {.gcsafe.} =
  var tracker = getAsyncProcessTracker()
  tracker.opened != tracker.closed

proc trackAsyncProccess(t: AsyncProcessRef) {.inline.} =
  var tracker = getAsyncProcessTracker()
  inc(tracker.opened)

proc untrackAsyncProcess(t: AsyncProcessRef) {.inline.}  =
  var tracker = getAsyncProcessTracker()
  inc(tracker.closed)

proc setupAsyncProcessTracker(): AsyncProcessTracker {.gcsafe.} =
  var res = AsyncProcessTracker(
    opened: 0,
    closed: 0,
    dump: dumpAsyncProcessTracking,
    isLeaked: leakAsyncProccessTracker
  )
  addTracker(AsyncProcessTrackerName, res)
  res

proc init*(t: typedesc[AsyncFD], handle: ProcessStreamHandle): AsyncFD =
  case handle.kind
  of ProcessStreamHandleKind.Handle:
    handle.handle
  of ProcessStreamHandleKind.Transport:
    handle.transp.fd
  of ProcessStreamHandleKind.StreamReader:
    doAssert(not(isNil(handle.reader.tsource)))
    handle.reader.tsource.fd
  of ProcessStreamHandleKind.StreamWriter:
    doAssert(not(isNil(handle.writer.tsource)))
    handle.writer.tsource.fd
  of ProcessStreamHandleKind.None:
    raiseAssert "ProcessStreamHandle could not be empty at this moment"

proc init*(t: typedesc[AsyncStreamHolder], handle: AsyncStreamReader,
           baseFlags: set[StreamHolderFlag] = {}): AsyncStreamHolder =
  AsyncStreamHolder(kind: StreamKind.Reader, reader: handle, flags: baseFlags)

proc init*(t: typedesc[AsyncStreamHolder], handle: AsyncStreamWriter,
           baseFlags: set[StreamHolderFlag] = {}): AsyncStreamHolder =
  AsyncStreamHolder(kind: StreamKind.Writer, writer: handle, flags: baseFlags)

proc init*(t: typedesc[AsyncStreamHolder]): AsyncStreamHolder =
  AsyncStreamHolder(kind: StreamKind.None)

proc init*(t: typedesc[AsyncStreamHolder], handle: ProcessStreamHandle,
           kind: StreamKind, baseFlags: set[StreamHolderFlag] = {}
          ): AsyncProcessResult[AsyncStreamHolder] =
  case handle.kind
  of ProcessStreamHandleKind.Handle:
    case kind
    of StreamKind.Reader:
      let transp =
        try:
          fromPipe(handle.handle)
        except CatchableError:
          return err(osLastError())
      let
        reader = newAsyncStreamReader(transp)
        flags = baseFlags + {StreamHolderFlag.Stream,
                             StreamHolderFlag.Transport}
      ok(AsyncStreamHolder(kind: StreamKind.Reader, reader: reader,
                           flags: flags))
    of StreamKind.Writer:
      let transp =
        try:
          fromPipe(handle.handle)
        except CatchableError:
          return err(osLastError())
      let
        writer = newAsyncStreamWriter(transp)
        flags = baseFlags + {StreamHolderFlag.Stream,
                             StreamHolderFlag.Transport}
      ok(AsyncStreamHolder(kind: StreamKind.Writer, writer: writer,
                           flags: flags))
    of StreamKind.None:
      ok(AsyncStreamHolder(kind: StreamKind.None))
  of ProcessStreamHandleKind.Transport:
    case kind
    of StreamKind.Reader:
      let
        reader = newAsyncStreamReader(handle.transp)
        flags = baseFlags + {StreamHolderFlag.Stream}
      ok(AsyncStreamHolder(kind: StreamKind.Reader, reader: reader,
                           flags: flags))
    of StreamKind.Writer:
      let
        writer = newAsyncStreamWriter(handle.transp)
        flags = baseFlags + {StreamHolderFlag.Stream}
      ok(AsyncStreamHolder(kind: StreamKind.Writer, writer: writer,
                           flags: flags))
    of StreamKind.None:
      ok(AsyncStreamHolder(kind: StreamKind.None))
  of ProcessStreamHandleKind.StreamReader:
    ok(AsyncStreamHolder(kind: StreamKind.Reader, reader: handle.reader,
                         flags: baseFlags))
  of ProcessStreamHandleKind.StreamWriter:
    ok(AsyncStreamHolder(kind: StreamKind.Writer, writer: handle.writer,
                         flags: baseFlags))
  of ProcessStreamHandleKind.None:
    ok(AsyncStreamHolder(kind: StreamKind.None))

proc init*(t: typedesc[ProcessStreamHandle]): ProcessStreamHandle =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.None)

proc init*(t: typedesc[ProcessStreamHandle],
           handle: AsyncFD): ProcessStreamHandle =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.Handle, handle: handle)

proc init*(t: typedesc[ProcessStreamHandle],
           transp: StreamTransport): ProcessStreamHandle =
  doAssert(transp.kind == TransportKind.Pipe,
           "Only pipe transports can be used as process streams")
  ProcessStreamHandle(kind: ProcessStreamHandleKind.Handle, transp: transp)

proc init*(t: typedesc[ProcessStreamHandle],
           reader: AsyncStreamReader): ProcessStreamHandle =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.StreamReader,
                      reader: reader)

proc init*(t: typedesc[ProcessStreamHandle],
           writer: AsyncStreamWriter): ProcessStreamHandle =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.StreamWriter,
                      writer: writer)

proc isEmpty*(handle: ProcessStreamHandle): bool =
  handle.kind == ProcessStreamHandleKind.None

proc suspend*(p: AsyncProcessRef): AsyncProcessResult[void] {.gcsafe.}

proc resume*(p: AsyncProcessRef): AsyncProcessResult[void] {.gcsafe.}

proc terminate*(p: AsyncProcessRef): AsyncProcessResult[void] {.gcsafe.}

proc kill*(p: AsyncProcessRef): AsyncProcessResult[void] {.gcsafe.}

proc running*(p: AsyncProcessRef): AsyncProcessResult[bool] {.gcsafe.}

proc peekExitCode*(p: AsyncProcessRef): AsyncProcessResult[int] {.gcsafe.}

proc getParentStdin(): AsyncProcessResult[AsyncStreamHolder]

proc getParentStdout(): AsyncProcessResult[AsyncStreamHolder]

proc getParentStderr(): AsyncProcessResult[AsyncStreamHolder]

proc preparePipes(options: set[AsyncProcessOption],
                  stdinHandle, stdoutHandle, stderrHandle: ProcessStreamHandle
                 ): AsyncProcessResult[AsyncProcessPipes] {.
     raises: [Defect], gcsafe.}

proc closeProcessHandles(pipes: var AsyncProcessPipes,
                         options: set[AsyncProcessOption],
                         lastError: OSErrorCode): OSErrorCode {.
     raises: [Defect].}

proc closeProcessStreams(pipes: AsyncProcessPipes): Future[void] {.
     raises: [Defect], gcsafe.}

proc closeWait(holder: AsyncStreamHolder): Future[void] {.
     raises: [Defect], gcsafe.}

template isOk(code: OSErrorCode): bool =
  when defined(windows):
    code == ERROR_SUCCESS
  else:
    code == 0

template closePipe(handle: AsyncFD): bool =
  when defined(windows):
    osdefs.closeHandle(HANDLE(handle)) == TRUE
  else:
    osdefs.close(cint(handle)) != -1

proc closeProcessHandles(pipes: var AsyncProcessPipes,
                         options: set[AsyncProcessOption],
                         lastError: OSErrorCode): OSErrorCode =
  # We trying to preserve error code of last failed operation.
  var currentError = lastError
  if AsyncProcessOption.ParentStreams notin options:
    if ProcessFlag.UserStdin notin pipes.flags:
      if pipes.stdinHandle != asyncInvalidPipe:
        if currentError.isOk():
          if not(closePipe(pipes.stdinHandle)):
            currentError = osLastError()
        else:
          discard closePipe(pipes.stdinHandle)
        pipes.stdinHandle = asyncInvalidPipe
    if ProcessFlag.UserStdout notin pipes.flags:
      if pipes.stdoutHandle != asyncInvalidPipe:
        if currentError.isOk():
          if not(closePipe(pipes.stdoutHandle)):
            currentError = osLastError()
        else:
          discard closePipe(pipes.stdoutHandle)
        pipes.stdoutHandle = asyncInvalidPipe
    if ProcessFlag.UserStderr notin pipes.flags:
      if pipes.stderrHandle != asyncInvalidPipe:
        if currentError.isOk():
          if not(closePipe(pipes.stderrHandle)):
            currentError = osLastError()
        else:
          discard closePipe(pipes.stderrHandle)
        pipes.stderrHandle = asyncInvalidPipe
  currentError

proc raiseAsyncProcessError(msg: string, exc: ref CatchableError = nil) {.
     noreturn, noinit, noinline, raises: [AsyncProcessError].} =
  let message =
    if isNil(exc):
      msg
    else:
      msg & " ([" & $exc.name & "]: " & $exc.msg & ")"
  raise newException(AsyncProcessError, message)

proc raiseAsyncProcessError(msg: string, error: OSErrorCode) {.
     noreturn, noinit, noinline, raises: [AsyncProcessError].} =
  let message = msg & " ([OSError]: " & osErrorMsg(error) & ")"
  raise newException(AsyncProcessError, message)

when defined(windows):

  proc toString*(w: WideCString): AsyncProcessResult[string] =
    if isNil(w):
      ok("")
    else:
      let bytesNeeded = wideCharToMultiByte(CP_UTF8, 0'u32, w, cint(-1), nil,
                                            cint(0), nil, nil)
      if bytesNeeded <= cint(0):
        return err(osLastError())

      var buffer = newString(bytesNeeded)
      let res = wideCharToMultiByte(CP_UTF8, 0'u32, w, cint(-1),
                                    addr buffer[0], cint(len(buffer)), nil, nil)
      if res != bytesNeeded:
        err(osLastError())
      else:
        # We need to strip trailing `\x00`.
        for i in countdown(len(buffer) - 1, 0):
          if buffer[i] != '\x00':
            buffer.setLen(i + 1)
            break
        ok(buffer)

  proc getProcessEnvironment*(): StringTableRef =
    var res = newStringTable(modeCaseInsensitive)
    var env = getEnvironmentStringsW()
    if isNil(env):
      return res
    var slider = env
    while int(slider[0]) != 0:
      let pos = wcschr(slider, Utf16Char(0x0000))
      let line =
        block:
          let res = slider.toString()
          if res.isErr(): "" else: res.get()
      slider = cast[WideCString](cast[ByteAddress](pos) + sizeof(Utf16Char))
      if len(line) > 0:
        let delim = line.find('=')
        if delim > 0:
          res[substr(line, 0, delim - 1)] = substr(line, delim + 1)
    discard freeEnvironmentStringsW(env)
    res

  proc buildCommandLine(a: string, args: openArray[string]): string {.
     raises: [Defect].} =
    # TODO: Procedures quoteShell/(Windows, Posix)() needs security and bug review
    # or reimplementation, for example quoteShellWindows() do not handle `\`
    # properly.
    # https://docs.microsoft.com/en-us/cpp/cpp/main-function-command-line-args?redirectedfrom=MSDN&view=msvc-170#parsing-c-command-line-arguments
    var res = quoteShell(a)
    for i in 0 ..< len(args):
      res.add(' ')
      res.add(quoteShell(args[i]))
    res

  proc getStdTransport(k: StandardKind): AsyncProcessResult[StreamTransport] =
    # Its impossible to use handles returned by GetStdHandle() because this
    # handles created without flag `FILE_FLAG_OVERLAPPED` being set.
    var sa = getSecurityAttributes(false)
    let (fileName, desiredAccess, shareMode) =
      case k
      of StandardKind.Stdin:
        (newWideCString("CONIN$"), GENERIC_WRITE, FILE_SHARE_WRITE)
      of StandardKind.Stdout:
        (newWideCString("CONOUT$"), GENERIC_READ, FILE_SHARE_READ)
      of StandardKind.Stderr:
        # There is no such thing like CONERR$ so we create new handle to CONOUT$
        (newWideCString("CONOUT$"), GENERIC_READ, FILE_SHARE_READ)
    let
      fileFlags = FILE_FLAG_OVERLAPPED
      hFile = createFile(fileName, desiredAccess, shareMode,
                         cast[pointer](addr sa), OPEN_EXISTING, fileFlags,
                         HANDLE(0))
    if hFile == INVALID_HANDLE_VALUE:
      return err(osLastError())

    let res =
      try:
        fromPipe(AsyncFD(hFile))
      except CatchableError:
        discard closeHandle(hFile)
        return err(osLastError())
    ok(res)

  proc buildEnvironment(env: StringTableRef): WideCString =
    var str: string
    for key, value in pairs(env):
      doAssert('=' notin key, "`=` must not be present in key name")
      str.add(key)
      str.add('=')
      str.add(value)
      str.add('\x00')
    str.add("\x00\x00")
    newWideCString(str)

  proc closeThreadAndProcessHandle(p: AsyncProcessRef
                                  ): AsyncProcessResult[void] =
    if p.threadHandle != HANDLE(0):
      if closeHandle(p.threadHandle) == FALSE:
        discard closeHandle(p.processHandle)
        return err(osLastError())
      p.threadHandle = HANDLE(0)

    if p.processHandle != HANDLE(0):
      if closeHandle(p.processHandle) == FALSE:
        return err(osLastError())
      p.processHandle = HANDLE(0)

  proc startProcess*(command: string, workingDir: string = "",
                     arguments: seq[string] = @[],
                     environment: StringTableRef = nil,
                     options: set[AsyncProcessOption] = {
                       AsyncProcessOption.StdErrToStdOut},
                     stdinHandle = ProcessStreamHandle(),
                     stdoutHandle = ProcessStreamHandle(),
                     stderrHandle = ProcessStreamHandle(),
                    ): Future[AsyncProcessRef] {.async.} =
    var
      pipes =
        block:
          let res = preparePipes(options, stdinHandle, stdoutHandle,
                                 stderrHandle)
          if res.isErr():
            raiseAsyncProcessError("Unable to initialze process pipes",
                                   res.error())
          res.get()
    let
      commandLine =
        if AsyncProcessOption.EvalCommand in options:
          asyncProcShellPath & " /C " & command
        else:
          buildCommandLine(command, arguments)
      workingDirectory =
        if len(workingDir) > 0:
          newWideCString(workingDir)
        else:
          nil
      environment =
        if not(isNil(environment)):
          buildEnvironment(environment)
        else:
          nil
      flags = CREATE_UNICODE_ENVIRONMENT
    var
      psa = getSecurityAttributes(false)
      tsa = getSecurityAttributes(false)
      startupInfo =
        block:
          var res = STARTUPINFO(cb: DWORD(sizeof(STARTUPINFO)))
          if AsyncProcessOption.ParentStreams notin options:
            res.dwFlags = STARTF_USESTDHANDLES
            res.hStdInput = HANDLE(pipes.stdinHandle)
            res.hStdOutput = HANDLE(pipes.stdoutHandle)
            res.hStdError = HANDLE(pipes.stderrHandle)
          res
      procInfo = PROCESS_INFORMATION()

    if AsyncProcessOption.EchoCommand in options:
      echo commandLine

    let res = createProcess(
      nil,
      newWideCString(commandLine),
      addr psa, addr tsa,
      TRUE, # NOTE: This is very important flag and MUST not be modified.
      flags,
      environment,
      workingDirectory,
      startupInfo, procInfo
    )

    var currentError = osLastError()
    if res == FALSE:
      await pipes.closeProcessStreams()
    currentError = closeProcessHandles(pipes, options, currentError)

    if res == FALSE:
      raiseAsyncProcessError("Unable to spawn process", currentError)

    let process = AsyncProcessRef(
      processHandle: procInfo.hProcess,
      threadHandle: procInfo.hThread,
      processId: procInfo.dwProcessId,
      pipes: pipes,
      options: options,
      flags: pipes.flags
    )

    trackAsyncProccess(process)
    return process

  proc peekProcessExitCode(p: AsyncProcessRef): AsyncProcessResult[int] {.
       raises: [Defect].} =
    var wstatus: DWORD = 0
    if p.exitStatus.isSome():
      return ok(p.exitStatus.get())

    let res = getExitCodeProcess(p.processHandle, wstatus)
    if res == TRUE:
      if wstatus != STILL_ACTIVE:
        let status = cast[int](wstatus)
        p.exitStatus = some(status)
        ok(status)
      else:
        ok(-1)
    else:
      err(osLastError())

  proc suspend(p: AsyncProcessRef): AsyncProcessResult[void] {.
       raises: [Defect].} =
    if suspendThread(p.threadHandle) != 0xFFFF_FFFF'u32:
      ok()
    else:
      err(osLastError())

  proc resume(p: AsyncProcessRef): AsyncProcessResult[void] {.
       raises: [Defect].} =
    if resumeThread(p.threadHandle) != 0xFFFF_FFFF'u32:
      ok()
    else:
      err(osLastError())

  proc terminate(p: AsyncProcessRef): AsyncProcessResult[void] {.
       raises: [Defect].} =
    if terminateProcess(p.processHandle, 0) != 0'u32:
      ok()
    else:
      err(osLastError())

  proc kill(p: AsyncProcessRef): AsyncProcessResult[void] {.
       raises: [Defect].} =
    p.terminate()

  proc running(p: AsyncProcessRef): AsyncProcessResult[bool] =
    let res = ? p.peekExitCode()
    if res == -1:
      ok(true)
    else:
      ok(false)

  proc waitForExit*(p: AsyncProcessRef,
                    timeout = InfiniteDuration): Future[int] {.async.} =
    if p.exitStatus.isSome():
      return p.exitStatus.get()

    let wres =
      try:
        await waitForSingleObject(p.processHandle, timeout)
      except ValueError as exc:
        raiseAsyncProcessError("Unable to wait for process handle", exc)

    if wres == WaitableResult.Timeout:
      let res = p.terminate()
      if res.isErr():
        raiseAsyncProcessError("Unable to terminate process", res.error())

    let exitCode =
      block:
        let res = p.peekProcessExitCode()
        if res.isErr():
          raiseAsyncProcessError("Unable to peek process exit code",
                                 res.error())
        res.get()

    if exitCode >= 0:
      p.exitStatus = some(exitCode)
    return exitCode

  proc peekExitCode(p: AsyncProcessRef): AsyncProcessResult[int] =
    if p.exitStatus.isSome():
      return ok(p.exitStatus.get())
    let res = waitForSingleObject(p.processHandle, DWORD(0))
    if res != WAIT_TIMEOUT:
      let exitCode = ? p.peekProcessExitCode()
      ok(exitCode)
    else:
      ok(-1)
else:
  import std/strutils
  from selectors2 import IOSelectorsException

  proc envToCStringArray(t: StringTableRef): cstringArray {.
       raises: [Defect].} =
    let itemsCount = len(t)
    var
      res = cast[cstringArray](alloc0((itemsCount + 1) * sizeof(cstring)))
      i = 0
    for key, value in pairs(t):
      var x = key & "=" & value
      res[i] = cast[cstring](alloc0(len(x) + 1))
      copyMem(res[i], addr(x[0]), len(x))
      inc(i)
    res

  proc envToCStringArray(): cstringArray =
    let itemsCount =
      block:
        var res = 0
        for key, value in envPairs(): inc(res)
        res
    var
      res = cast[cstringArray](alloc0((itemsCount + 1) * sizeof(cstring)))
      i = 0
    for key, value in envPairs():
      var x = string(key) & "=" & string(value)
      res[i] = cast[cstring](alloc0(len(x) + 1))
      copyMem(res[i], addr(x[0]), len(x))
      inc(i)
    res

  when defined(macosx) or defined(macos) or defined(ios):
    proc getEnvironment(): ptr cstringArray {.
      importc: "_NSGetEnviron", header: "<crt_externs.h>".}
  else:
    var globalEnv {.importc: "environ", header: "<unistd.h>".}: cstringArray

  proc getProcessEnvironment*(): StringTableRef =
    var res = newStringTable(modeCaseInsensitive)
    let env =
      when defined(macosx) or defined(macos) or defined(ios):
        getEnvironment()[]
      else:
        globalEnv
    var i = 0
    while not(isNil(env[i])):
      let line = $env[i]
      if len(line) > 0:
        let delim = line.find('=')
        if delim > 0:
          res[substr(line, 0, delim - 1)] = substr(line, delim + 1)
      inc(i)
    res

  proc getFullCommand(command: string, arguments: cstringArray): string =
    let length =
      if isNil(arguments):
        0
      else:
        var res = 0
        while not(isNil(arguments[res])): inc(res)
        res
    var res = @[command]
    if length > 0:
      for index in 1 ..< length:
        res.add($arguments[index])
    res.join(" ")

  template exitStatusLikeShell(status: int): int =
    if WAITIFSIGNALED(cint(status)):
      # like the shell!
      128 + WAITTERMSIG(cint(status))
    else:
      WAITEXITSTATUS(cint(status))

  proc getCurrentDirectory(): AsyncProcessResult[string] =
    var bufsize = 1024
    var res = newString(bufsize)

    proc strLength(a: string): int {.nimcall.} =
      for i in 0 ..< len(a):
        if a[i] == '\x00':
          return i
      len(a)

    while true:
      if osdefs.getcwd(res, bufsize) != nil:
        setLen(res, strLength(res))
        return ok(res)
      else:
        let errorCode = osLastError()
        if errorCode == osdefs.ERANGE:
          bufsize = bufsize shl 1
          doAssert(bufsize >= 0)
          res = newString(bufsize)
        else:
          return err(errorCode)

  proc setCurrentDirectory(dir: string): AsyncProcessResult[void] =
    let res = osdefs.chdir(cstring(dir))
    if res == -1:
      return err(osLastError())
    ok()

  proc getStdTransport(k: StandardKind): AsyncProcessResult[StreamTransport] =
    let fd =
      case k
      of StandardKind.Stdin:
        osdefs.dup(cint(0))
      of StandardKind.Stdout:
        osdefs.dup(cint(1))
      of StandardKind.Stderr:
        osdefs.dup(cint(2))

    if fd == -1:
      return err(osLastError())
    if osdefs.fcntl(fd, osdefs.F_SETFD, osdefs.FD_CLOEXEC) == -1:
      discard osdefs.close(fd)
      return err(osLastError())
    if not(setSocketBlocking(SocketHandle(fd), false)):
      discard osdefs.close(fd)
      return err(osLastError())

    let transp =
      try:
        fromPipe(AsyncFD(fd))
      except CatchableError:
        discard osdefs.close(fd)
        return err(osLastError())
    ok(transp)

  proc closeThreadAndProcessHandle(p: AsyncProcessRef
                                  ): AsyncProcessResult[void] =
    discard

  proc startProcess*(command: string, workingDir: string = "",
                     arguments: seq[string] = @[],
                     environment: StringTableRef = nil,
                     options: set[AsyncProcessOption] = {
                       AsyncProcessOption.StdErrToStdOut},
                     stdinHandle = ProcessStreamHandle(),
                     stdoutHandle = ProcessStreamHandle(),
                     stderrHandle = ProcessStreamHandle(),
                    ): Future[AsyncProcessRef] {.async.} =
    var
      posixAttr =
        block:
          var value: PosixSpawnAttr
          let res = posixSpawnAttrInit(value)
          if res != 0:
            raiseAsyncProcessError("Unable to initalize spawn attributes", res)
          value
      posixFops =
        block:
          var value: PosixSpawnFileActions
          let res = posixSpawnFileActionsInit(value)
          if res != 0:
            discard posixSpawnAttrDestroy(posixAttr)
            raiseAsyncProcessError("Unable to initialize spaw actions", res)
          value
      mask: Sigset
      pid: Pid
      pipes =
        block:
          var res = preparePipes(options, stdinHandle, stdoutHandle,
                                 stderrHandle)
          if res.isErr():
            raiseAsyncProcessError("Unable to initialze process pipes",
                                   res.error())
          res.get()
    let
      (commandLine, commandArguments) =
        if AsyncProcessOption.EvalCommand in options:
          let args = @[asyncProcShellPath, "-c", command]
          (asyncProcShellPath, allocCStringArray(args))
        else:
          var res = @[command]
          for arg in arguments.items():
            res.add(arg)
          (command, allocCStringArray(res))
      commandEnv =
        if isNil(environment):
          envToCStringArray()
        else:
          envToCStringArray(environment)

    template checkSpawnError(e: untyped) =
      let res = e
      if res != 0:
        currentError = OSErrorCode(res)
        raiseAsyncProcessError("Unable to prepare attributes and flags", res)

    template checkSigError(e: untyped) =
      let res = e
      if res != 0:
        currentError = osLastError()
        raiseAsyncProcessError("Unable to initalize signal set", currentError)

    var currentError: OSErrorCode
    var currentDir: string
    try:
      checkSigError sigemptyset(mask)
      checkSpawnError posixSpawnAttrSetSigMask(posixAttr, mask)
      let flags =
        if AsyncProcessOption.ProcessGroup in options:
          checkSpawnError posixSpawnAttrSetPgroup(posixAttr, 0)
          osdefs.POSIX_SPAWN_USEVFORK or osdefs.POSIX_SPAWN_SETSIGMASK or
          osdefs.POSIX_SPAWN_SETPGROUP
        else:
          osdefs.POSIX_SPAWN_USEVFORK or osdefs.POSIX_SPAWN_SETSIGMASK
      checkSpawnError posixSpawnAttrSetFlags(posixAttr, flags)

      if AsyncProcessOption.ParentStreams notin options:
        checkSpawnError:
          posixSpawnFileActionsAddDup2(posixFops, cint(pipes.stdinHandle),
                                       cint(0))
        checkSpawnError:
          posixSpawnFileActionsAddDup2(posixFops, cint(pipes.stdoutHandle),
                                       cint(1))
        checkSpawnError:
          if AsyncProcessOption.StdErrToStdOut in options:
            posixSpawnFileActionsAddDup2(posixFops, cint(pipes.stdoutHandle),
                                         cint(2))
          else:
            posixSpawnFileActionsAddDup2(posixFops, cint(pipes.stderrHandle),
                                         cint(2))

      currentDir =
        if len(workingDir) > 0:
          # Save current working directory and change it to `workingDir`.
          let cres = getCurrentDirectory()
          if cres.isErr():
            raiseAsyncProcessError("Unable to obtain current directory",
                                   cres.error())
          let sres = setCurrentDirectory(workingDir)
          if sres.isErr():
            raiseAsyncProcessError("Unable to change current directory",
                                   sres.error())
          cres.get()
        else:
          ""

      if AsyncProcessOption.EchoCommand in options:
        echo getFullCommand(commandLine, commandArguments)

      let res =
        if AsyncProcessOption.UsePath in options:
          posixSpawnp(pid, commandLine, posixFops, posixAttr, commandArguments,
                      commandEnv)
        else:
          posixSpawn(pid, commandLine, posixFops, posixAttr, commandArguments,
                     commandEnv)

      if res != 0:
        await pipes.closeProcessStreams()
      currentError = closeProcessHandles(pipes, options, OSErrorCode(res))

    finally:
      # Restore working directory
      if (len(workingDir) > 0) and (len(currentDir) > 0):
        # Restore working directory.
        let cres = getCurrentDirectory()
        if cres.isErr():
          # On error we still try to restore original working directory.
          if currentError == 0:
            currentError = cres.error()
          discard setCurrentDirectory(currentDir)
        else:
          if cres.get() != currentDir:
            let sres = setCurrentDirectory(currentDir)
            if sres.isErr():
              if currentError == 0:
                currentError = sres.error()

      # Cleanup allocated memory
      deallocCStringArray(commandArguments)
      deallocCStringArray(commandEnv)

      # Cleanup posix_spawn attributes and file operations
      if currentError == 0:
        currentError = OSErrorCode(posixSpawnAttrDestroy(posixAttr))
      else:
        discard posixSpawnAttrDestroy(posixAttr)
      if currentError == 0:
        currentError = OSErrorCode(posixSpawnFileActionsDestroy(posixFops))
      else:
        discard posixSpawnFileActionsDestroy(posixFops)

      # If currentError has been set, raising an exception.
      if currentError != 0:
        raiseAsyncProcessError("Unable to spawn process",
                               OSErrorCode(currentError))

    let process = AsyncProcessRef(
      processId: pid,
      pipes: pipes,
      options: options,
      flags: pipes.flags
    )

    trackAsyncProccess(process)
    return process

  proc peekProcessExitCode(p: AsyncProcessRef): AsyncProcessResult[int] =
    var wstatus: cint = 0
    if p.exitStatus.isSome():
      return ok(p.exitStatus.get())
    let res = osdefs.waitpid(p.processId, wstatus, osdefs.WNOHANG)
    if res == p.processId:
      if WAITIFEXITED(wstatus) or WAITIFSIGNALED(wstatus):
        let status = int(wstatus)
        p.exitStatus = some(status)
        ok(status)
      else:
        ok(-1)
    elif res == 0:
      ok(-1)
    else:
      err(osLastError())

  proc suspend(p: AsyncProcessRef): AsyncProcessResult[void] =
    if osdefs.kill(p.processId, osdefs.SIGSTOP) == 0:
      ok()
    else:
      err(osLastError())

  proc resume(p: AsyncProcessRef): AsyncProcessResult[void] =
    if osdefs.kill(p.processId, osdefs.SIGCONT) == 0:
      ok()
    else:
      err(osLastError())

  proc terminate(p: AsyncProcessRef): AsyncProcessResult[void] =
    if osdefs.kill(p.processId, osdefs.SIGTERM) == 0:
      ok()
    else:
      err(osLastError())

  proc kill(p: AsyncProcessRef): AsyncProcessResult[void] =
    if osdefs.kill(p.processId, osdefs.SIGKILL) == 0:
      ok()
    else:
      err(osLastError())

  proc running(p: AsyncProcessRef): AsyncProcessResult[bool] =
    let res = ? p.peekProcessExitCode()
    if res == -1:
      ok(true)
    else:
      ok(false)

  proc waitForExit*(p: AsyncProcessRef,
                    timeout = InfiniteDuration): Future[int] =
    var
      retFuture = newFuture[int]("chronos.waitForExit()")
      processHandle: int = 0
      wstatus: cint = 1
      timer: TimerCallback = nil

    if p.exitStatus.isSome():
      retFuture.complete(p.exitStatus.get())
      return retFuture

    if timeout == ZeroDuration:
      let res = p.terminate()
      if res.isErr():
        retFuture.fail(newException(AsyncProcessError, osErrorMsg(res.error())))
        return retFuture

    let exitCode =
      block:
        let res = p.peekProcessExitCode()
        if res.isErr():
          retFuture.fail(newException(AsyncProcessError,
                                      osErrorMsg(res.error())))
          return retFuture
        res.get()

    if exitCode != -1:
      retFuture.complete(exitStatusLikeShell(exitCode))
      return retFuture

    if timeout == ZeroDuration:
      retFuture.complete(-1)
      return retFuture

    proc continuation(udata: pointer) {.gcsafe.} =
      let source = cast[int](udata)
      if not(retFuture.finished()):
        try:
          removeProcess(processHandle)
        except IOSelectorsException:
          retFuture.fail(newException(AsyncProcessError,
                                      osErrorMsg(osLastError())))
          return
        if source == 1:
          if not(isNil(timer)):
            clearTimer(timer)
        else:
          let res = p.terminate()
          if res.isErr():
            retFuture.fail(newException(AsyncProcessError,
                                        osErrorMsg(res.error())))
            return
        let exitCode =
          block:
            let res = p.peekProcessExitCode()
            if res.isErr():
              retFuture.fail(newException(AsyncProcessError,
                                          osErrorMsg(res.error())))
              return
            res.get()
        if exitCode == -1:
          retFuture.complete(-1)
        else:
          retFuture.complete(exitStatusLikeShell(exitCode))

    proc cancellation(udata: pointer) {.gcsafe.} =
      if not(retFuture.finished()):
        if not(isNil(timer)):
          clearTimer(timer)
        try:
          removeProcess(processHandle)
        except IOSelectorsException:
          # Ignore any exceptions because of cancellation.
          discard

    if timeout != InfiniteDuration:
      timer = setTimer(Moment.fromNow(timeout), continuation, cast[pointer](2))

    processHandle =
      try:
        addProcess(int(p.processId), continuation, cast[pointer](1))
      except ValueError as exc:
        retFuture.fail(newException(AsyncProcessError, exc.msg))
        return retFuture
    return retFuture

  proc peekExitCode(p: AsyncProcessRef): AsyncProcessResult[int] =
    let res = ? p.peekProcessExitCode()
    ok(exitStatusLikeShell(res))

proc getParentStdin(): AsyncProcessResult[AsyncStreamHolder] =
  let
    transp = ? getStdTransport(StandardKind.Stdin)
    flags = {StreamHolderFlag.Transport, StreamHolderFlag.Stream}
    holder = AsyncStreamHolder.init(newAsyncStreamWriter(transp), flags)
  ok(holder)

proc getParentStdout(): AsyncProcessResult[AsyncStreamHolder] =
  let
    transp = ? getStdTransport(StandardKind.Stdout)
    flags = {StreamHolderFlag.Transport, StreamHolderFlag.Stream}
    holder = AsyncStreamHolder.init(newAsyncStreamReader(transp), flags)

  ok(holder)

proc getParentStderr(): AsyncProcessResult[AsyncStreamHolder] =
  let
    transp = ? getStdTransport(StandardKind.Stderr)
    flags = {StreamHolderFlag.Transport, StreamHolderFlag.Stream}
    holder = AsyncStreamHolder.init(newAsyncStreamReader(transp), flags)
  ok(holder)

proc preparePipes(options: set[AsyncProcessOption],
                  stdinHandle, stdoutHandle,
                  stderrHandle: ProcessStreamHandle
                 ): AsyncProcessResult[AsyncProcessPipes] =
  if AsyncProcessOption.ParentStreams notin options:
    let
      (stdinFlags, localStdin, stdinHandle) =
        if stdinHandle.isEmpty():
          let (pipeIn, pipeOut) = createAsyncPipe(true, false)
          if (pipeIn == asyncInvalidPipe) or (pipeOut == asyncInvalidPipe):
            return err(osLastError())
          let holder = ? AsyncStreamHolder.init(
            ProcessStreamHandle.init(pipeOut), StreamKind.Writer, {})
          (set[ProcessFlag]({}), holder, pipeIn)
        else:
          ({ProcessFlag.UserStdin},
           AsyncStreamHolder.init(), AsyncFD.init(stdinHandle))
      (stdoutFlags, localStdout, stdoutHandle) =
        if stdoutHandle.isEmpty():
          let (pipeIn, pipeOut) = createAsyncPipe(false, true)
          if (pipeIn == asyncInvalidPipe) or (pipeOut == asyncInvalidPipe):
            return err(osLastError())
          let holder = ? AsyncStreamHolder.init(
            ProcessStreamHandle.init(pipeIn), StreamKind.Reader, {})
          (set[ProcessFlag]({}), holder, pipeOut)
        else:
          ({ProcessFlag.UserStdout},
           AsyncStreamHolder.init(), AsyncFD.init(stdoutHandle))
      (stderrFlags, localStderr, stderrHandle) =
        if stderrHandle.isEmpty():
          let (pipeIn, pipeOut) = createAsyncPipe(false, true)
          if (pipeIn == asyncInvalidPipe) or (pipeOut == asyncInvalidPipe):
            return err(osLastError())
          let holder = ? AsyncStreamHolder.init(
            ProcessStreamHandle.init(pipeIn), StreamKind.Reader, {})
          (set[ProcessFlag]({}), holder, pipeOut)
        else:
          ({ProcessFlag.UserStderr},
           AsyncStreamHolder.init(), AsyncFD.init(stderrHandle))
    ok(AsyncProcessPipes(
      flags: stdinFlags + stdoutFlags + stderrFlags,
      stdinHolder: localStdin,
      stdoutHolder: localStdout,
      stderrHolder: localStderr,
      stdinHandle: stdinHandle,
      stdoutHandle: stdoutHandle,
      stderrHandle: stderrHandle
    ))
  else:
    doAssert(stdinHandle.isEmpty(),
             "ParentStreams flag has been already set!")
    doAssert(stdoutHandle.isEmpty(),
             "ParentStreams flag has been already set!")
    doAssert(stderrHandle.isEmpty(),
             "ParentStreams flag has been already set!")
    let
      resStdin = ? getParentStdin()
      resStdout = ? getParentStdout()
      resStderr = ? getParentStderr()

    ok(AsyncProcessPipes(
      flags: {},
      stdinHolder: resStdin, stdoutHolder: resStdout,
      stderrHolder: resStderr,
      stdinHandle: AsyncFD(0), stdoutHandle: AsyncFD(0),
      stderrHandle: AsyncFD(0)
    ))

proc closeWait(holder: AsyncStreamHolder) {.async.} =
  let (future, transp) =
    case holder.kind
    of StreamKind.None:
      (nil, nil)
    of StreamKind.Reader:
      if StreamHolderFlag.Stream in holder.flags:
        (holder.reader.closeWait(), holder.reader.tsource)
      else:
        (nil, holder.reader.tsource)
    of StreamKind.Writer:
      if StreamHolderFlag.Stream in holder.flags:
        (holder.writer.closeWait(), holder.writer.tsource)
      else:
        (nil, holder.writer.tsource)

  let pending =
    block:
      var res: seq[Future[void]]
      if not(isNil(future)):
        res.add(future)
      if not(isNil(transp)):
        if StreamHolderFlag.Transport in holder.flags:
          res.add(transp.closeWait())
      res

  if len(pending) > 0:
    await allFutures(pending)

proc closeProcessStreams(pipes: AsyncProcessPipes): Future[void] =
  allFutures(pipes.stdinHolder.closeWait(),
             pipes.stdoutHolder.closeWait(),
             pipes.stderrHolder.closeWait())

proc closeWait*(p: AsyncProcessRef) {.async.} =
  # Here we ignore all possible errrors, because we do not want to raise
  # exceptions.
  discard closeProcessHandles(p.pipes, p.options, OSErrorCode(0))
  await p.pipes.closeProcessStreams()
  discard p.closeThreadAndProcessHandle()
  untrackAsyncProcess(p)

proc stdinStream*(p: AsyncProcessRef): AsyncStreamWriter =
  doAssert(p.pipes.stdinHolder.kind == StreamKind.Writer)
  p.pipes.stdinHolder.writer

proc stdoutStream*(p: AsyncProcessRef): AsyncStreamReader =
  doAssert(p.pipes.stdoutHolder.kind == StreamKind.Reader)
  p.pipes.stdoutHolder.reader

proc stderrStream*(p: AsyncProcessRef): AsyncStreamReader =
  doAssert(p.pipes.stderrHolder.kind == StreamKind.Reader)
  p.pipes.stderrHolder.reader

proc execCommand*(command: string,
                  options = {AsyncProcessOption.EvalCommand}
                 ): Future[int] {.async.} =
  let poptions = options + {AsyncProcessOption.EvalCommand}
  let process = await startProcess(command, options = poptions)
  let res =
    try:
      await process.waitForExit(InfiniteDuration)
    finally:
      await process.closeWait()
  return res

proc execCommandEx*(command: string,
                    options = {AsyncProcessOption.EvalCommand}
                   ): Future[CommandExResponse] {.async.} =
  let
    process = await startProcess(command, options = options)
    outputReader = process.stdoutStream.read()
    errorReader = process.stderrStream.read()
    res =
      try:
        await allFutures(outputReader, errorReader)
        let status = await process.waitForExit(InfiniteDuration)
        let output =
          try:
            string.fromBytes(outputReader.read())
          except AsyncStreamError as exc:
            raiseAsyncProcessError("Unable to read process' stdout channel",
                                   exc)
        let error =
          try:
            string.fromBytes(errorReader.read())
          except AsyncStreamError as exc:
            raiseAsyncProcessError("Unable to read process' stderr channel",
                                   exc)
        CommandExResponse(status: status, stdOutput: output, stdError: error)
      finally:
        await process.closeWait()

  return res
