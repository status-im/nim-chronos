#
#         Chronos' asynchronous process management
#
#  (c) Copyright 2022-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
import std/[options, strtabs]
import "."/[asyncloop, handles, osdefs], streams/asyncstream
export options, strtabs

type
  AsyncProcessError* = object of CatchableError

  AsyncProcessOption* {.pure.} = enum
    UsePath,
    EvalCommand,
    EchoCommand,
    StdErrToStdOut,
    ParentStreams

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

proc init*(t: typedesc[AsyncFD], handle: ProcessStreamHandle): AsyncFD {.
     raises: [Defect].} =
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
          ): Result[AsyncStreamHolder, OSErrorCode] {.
     raises: [Defect].} =
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

proc init*(t: typedesc[ProcessStreamHandle]): ProcessStreamHandle {.
     raises: [Defect].} =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.None)

proc init*(t: typedesc[ProcessStreamHandle],
           handle: AsyncFD): ProcessStreamHandle {.
     raises: [Defect].} =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.Handle, handle: handle)

proc init*(t: typedesc[ProcessStreamHandle],
           transp: StreamTransport): ProcessStreamHandle {.
     raises: [Defect].} =
  doAssert(transp.kind == TransportKind.Pipe,
           "Only pipe transports can be used as process streams")
  ProcessStreamHandle(kind: ProcessStreamHandleKind.Handle, transp: transp)

proc init*(t: typedesc[ProcessStreamHandle],
           reader: AsyncStreamReader): ProcessStreamHandle {.
     raises: [Defect].} =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.StreamReader,
                      reader: reader)

proc init*(t: typedesc[ProcessStreamHandle],
           writer: AsyncStreamWriter): ProcessStreamHandle {.
     raises: [Defect].} =
  ProcessStreamHandle(kind: ProcessStreamHandleKind.StreamWriter,
                      writer: writer)

proc isEmpty*(handle: ProcessStreamHandle): bool =
  handle.kind == ProcessStreamHandleKind.None

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

when defined(windows):

  proc getSecurityAttributes(inheritHandle: bool = false): SECURITY_ATTRIBUTES =
    SECURITY_ATTRIBUTES(
      nLength: DWORD(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil,
      bInheritHandle: if inheritHandle: TRUE else: FALSE
    )

  proc getStdTransport(htype: DWORD): Result[StreamTransport, OSErrorCode] {.
       raises: [Defect].} =
    # Its impossible to use handles returned by GetStdHandle() because this
    # handles created without flag `FILE_FLAG_OVERLAPPED` being set.
    var sa = getSecurityAttributes(false)
    let (fileName, desiredAccess, shareMode) =
      case htype
      of STD_INPUT_HANDLE:
        (newWideCString("CONIN$"), GENERIC_WRITE, FILE_SHARE_WRITE)
      of STD_OUTPUT_HANDLE:
        (newWideCString("CONOUT$"), GENERIC_READ, FILE_SHARE_READ)
      of STD_ERROR_HANDLE:
        # There is no such thing like CONERR$ so we create new handle to CONOUT$
        (newWideCString("CONOUT$"), GENERIC_READ, FILE_SHARE_READ)
      else:
        raiseAssert("Incorrect handle type")
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

  proc getParentStdin(): Result[AsyncStreamHolder, OSErrorCode] {.
       raises: [Defect].} =
    let
      transp = ? getStdTransport(STD_INPUT_HANDLE)
      flags = {StreamHolderFlag.Transport, StreamHolderFlag.Stream}
      holder = AsyncStreamHolder.init(newAsyncStreamWriter(transp), flags)
    ok(holder)

  proc getParentStdout(): Result[AsyncStreamHolder, OSErrorCode] {.
       raises: [Defect].} =
    let
      transp = ? getStdTransport(STD_OUTPUT_HANDLE)
      flags = {StreamHolderFlag.Transport, StreamHolderFlag.Stream}
      holder = AsyncStreamHolder.init(newAsyncStreamReader(transp), flags)

    ok(holder)

  proc getParentStderr(): Result[AsyncStreamHolder, OSErrorCode] {.
       raises: [Defect].} =
    let
      transp = ? getStdTransport(STD_ERROR_HANDLE)
      flags = {StreamHolderFlag.Transport, StreamHolderFlag.Stream}
      holder = AsyncStreamHolder.init(newAsyncStreamReader(transp), flags)
    ok(holder)

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

  proc preparePipes(options: set[AsyncProcessOption],
                    stdinHandle, stdoutHandle,
                    stderrHandle: ProcessStreamHandle
                   ): Result[AsyncProcessPipes, OSErrorCode] {.
       raises: [Defect].} =
    if AsyncProcessOption.ParentStreams notin options:
      let
        (stdinFlags, localStdin, stdinHandle) =
          if stdinHandle.isEmpty():
            let (pipeIn, pipeOut) = createAsyncPipe(false)
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
            let (pipeIn, pipeOut) = createAsyncPipe(false)
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
            let (pipeIn, pipeOut) = createAsyncPipe(false)
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

  proc closeThreadAndProcessHandle(p: AsyncProcessRef
                                  ): Result[void, OSErrorCode] {.
       raises: [Defect].} =
    if p.threadHandle != HANDLE(0):
      if closeHandle(p.threadHandle) == FALSE:
        discard closeHandle(p.processHandle)
        return err(osLastError())
      p.threadHandle = HANDLE(0)

    if p.processHandle != HANDLE(0):
      if closeHandle(p.processHandle) == FALSE:
        return err(osLastError())
      p.processHandle = HANDLE(0)

  proc closeProcessHandles(pipes: AsyncProcessPipes,
                           options: set[AsyncProcessOption],
                           lastError: OSErrorCode): OSErrorCode {.
       raises: [Defect].} =
    var currentError = lastError
    if AsyncProcessOption.ParentStreams notin options:
      if ProcessFlag.UserStdin notin pipes.flags:
        if closeHandle(HANDLE(pipes.stdinHandle)) == FALSE:
          currentError = osLastError()
          discard closeHandle(HANDLE(pipes.stdoutHandle))
          discard closeHandle(HANDLE(pipes.stderrHandle))
      if ProcessFlag.UserStdout notin pipes.flags:
        if currentError == ERROR_SUCCESS:
          if closeHandle(HANDLE(pipes.stdoutHandle)) == FALSE:
            currentError = osLastError()
            discard closeHandle(HANDLE(pipes.stderrHandle))
      if ProcessFlag.UserStderr notin pipes.flags:
        if currentError == ERROR_SUCCESS:
          if closeHandle(HANDLE(pipes.stderrHandle)) == FALSE:
            currentError = osLastError()
    currentError

  proc closeProcessStreams(pipes: AsyncProcessPipes): Future[void] {.
       raises: [Defect].} =
    allFutures(pipes.stdinHolder.closeWait(),
               pipes.stdoutHolder.closeWait(),
               pipes.stderrHolder.closeWait())

  proc startProcess(command: string, workingDir: string = "",
                    arguments: seq[string] = @[],
                    environment: StringTableRef = nil,
                    options: set[AsyncProcessOption] = {
                      AsyncProcessOption.StdErrToStdOut},
                    stdinHandle = ProcessStreamHandle(),
                    stdoutHandle = ProcessStreamHandle(),
                    stderrHandle = ProcessStreamHandle(),
                   ): Future[AsyncProcessRef] {.async.} =
    let
      pipes =
        block:
          let res = preparePipes(options, stdinHandle, stdoutHandle,
                                 stderrHandle)
          if res.isErr():
            raise newException(AsyncProcessError, osErrorMsg(res.error()))
          res.get()
      commandLine =
        if AsyncProcessOption.EvalCommand in options:
          newWideCString(command)
        else:
          newWideCString(buildCommandLine(command, arguments))
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

    var res = createProcess(nil, commandLine, addr psa, addr tsa, FALSE,
                            flags, environment, workingDirectory, startupInfo,
                            procInfo)
    var currentError = osLastError()
    if res == FALSE:
      await pipes.closeProcessStreams()

    currentError = closeProcessHandles(pipes, options, currentError)

    if res == FALSE:
      raise newException(AsyncProcessError, osErrorMsg(currentError))

    return AsyncProcessRef(
      processHandle: procInfo.hProcess,
      threadHandle: procInfo.hThread,
      processId: procInfo.dwProcessId,
      pipes: pipes,
      options: options,
      flags: pipes.flags
    )

  proc suspend(p: AsyncProcessRef) =
    discard suspendThread(p.threadHandle)

  proc resume(p: AsyncProcessRef) =
    discard resumeThread(p.threadHandle)

  proc running(p: AsyncProcessRef): bool =
    if p.exitStatus.isSome():
      false
    else:
      let res = waitForSingleObject(p.processHandle, DWORD(0))
      res == WAIT_TIMEOUT

  proc terminate(p: AsyncProcessRef) =
    if running(p):
      discard terminateProcess(p.processHandle, 0)

  proc waitForExit(p: AsyncProcessRef,
                   timeout = InfiniteDuration): Future[int] {.async.} =
    if p.exitStatus.isSome():
      return p.exitStatus.get()

    let res = await waitForSingleObject(p.processHandle, timeout)
    if res == WaitableResult.Timeout:
      terminate(p)

    var status: DWORD
    discard getExitCodeProcess(p.processHandle, status)
    if status != STILL_ACTIVE:
      let integerStatus = cast[int](status)
      p.exitStatus = some(integerStatus)
      discard p.closeThreadAndProcessHandle()
      return integerStatus
    else:
      return -1

  proc peekExitCode(p: AsyncProcessRef): int =
    if p.exitStatus.isSome():
      return p.exitStatus.get()

    let res = waitForSingleObject(p.processHandle, DWORD(0))
    if res != WAIT_TIMEOUT:
      var status: DWORD = 0

      discard getExitCodeProcess(p.processHandle, status)
      let integerStatus = cast[int](status)
      p.exitStatus = some(integerStatus)
      discard p.closeThreadAndProcessHandle()
      integerStatus
    else:
      -1

  proc closeWait(p: AsyncProcessRef) {.async.} =
    # Here we ignore all possible errrors, because we do not want to raise
    # exceptions.
    discard closeProcessHandles(p.pipes, p.options, OSErrorCode(ERROR_SUCCESS))
    await p.pipes.closeProcessStreams()
    discard p.closeThreadAndProcessHandle()

  proc stdinStream(p: AsyncProcessRef): AsyncStreamWriter =
    doAssert(p.pipes.stdinHolder.kind == StreamKind.Writer)
    p.pipes.stdinHolder.writer

  proc stdoutStream(p: AsyncProcessRef): AsyncStreamReader =
    doAssert(p.pipes.stdoutHolder.kind == StreamKind.Reader)
    p.pipes.stdoutHolder.reader

  proc stderrStream(p: AsyncProcessRef): AsyncStreamReader =
    doAssert(p.pipes.stderrHolder.kind == StreamKind.Reader)
    p.pipes.stderrHolder.reader

  proc execCommand(command: string): Future[int] {.async.} =
    let process = await startProcess(command)
    let res =
      try:
        await process.waitForExit(InfiniteDuration)
      finally:
        await process.closeWait()
    return res

proc test() {.async.} =
  var hEvent = createEvent(nil, 0, 0, nil)
  if hEvent == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError())

  echo await waitForSingleObject(hEvent, 2.seconds)

  var fut = waitForSingleObject(hEvent, InfiniteDuration)
  await sleepAsync(2.seconds)
  echo "fut.state = ", fut.state
  discard setEvent(hEvent)
  echo await fut

when isMainModule:
  echo "here"
  echo waitFor execCommand("cmd.exe")
  # echo cast[uint32](-10)
  # echo cast[uint32](-11)
  # echo cast[uint32](-12)

  # waitFor test()
