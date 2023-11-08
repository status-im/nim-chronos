## Compile-time configuration options for chronos that control the availability
## of various strictness and debuggability options. In general, debug helpers
## are enabled when `debug` is defined while strictness options are introduced
## in transition periods leading up to a breaking release that starts enforcing
## them and removes the option.
##
## `chronosPreviewV4` is a preview flag to enable v4 semantics - in particular,
## it enables strict exception checking and disables parts of the deprecated
## API and other changes being prepared for the upcoming release
##
## `chronosDebug` can be defined to enable several debugging helpers that come
## with a runtime cost - it is recommeneded to not enable these in production
## code.
when (NimMajor, NimMinor) >= (1, 4):
  const
    chronosStrictException* {.booldefine.}: bool = defined(chronosPreviewV4)
      ## Require that `async` code raises only derivatives of `CatchableError`
      ## and not `Exception` - forward declarations, methods and `proc` types
      ## used from within `async` code may need to be be explicitly annotated
      ## with `raises: [CatchableError]` when this mode is enabled.

    chronosStrictFutureAccess* {.booldefine.}: bool = defined(chronosPreviewV4)

    chronosStackTrace* {.booldefine.}: bool = defined(chronosDebug)
      ## Include stack traces in futures for creation and completion points

    chronosFutureId* {.booldefine.}: bool = defined(chronosDebug)
      ## Generate a unique `id` for every future - when disabled, the address of
      ## the future will be used instead

    chronosFutureTracking* {.booldefine.}: bool = defined(chronosDebug)
      ## Keep track of all pending futures and allow iterating over them -
      ## useful for detecting hung tasks

    chronosDumpAsync* {.booldefine.}: bool = defined(nimDumpAsync)
      ## Print code generated by {.async.} transformation

    chronosProcShell* {.strdefine.}: string =
      when defined(windows):
        "cmd.exe"
      else:
        when defined(android):
          "/system/bin/sh"
        else:
          "/bin/sh"
      ## Default shell binary path.
      ##
      ## The shell is used as command for command line when process started
      ## using `AsyncProcessOption.EvalCommand` and API calls such as
      ## ``execCommand(command)`` and ``execCommandEx(command)``.

    chronosEventsCount* {.intdefine.} = 64
      ## Number of OS poll events retrieved by syscall (epoll, kqueue, poll).

    chronosInitialSize* {.intdefine.} = 64
      ## Initial size of Selector[T]'s array of file descriptors.

    chronosEventEngine* {.strdefine.}: string =
      when defined(nimdoc):
        ""
      elif defined(linux) and not(defined(android) or defined(emscripten)):
        "epoll"
      elif defined(macosx) or defined(macos) or defined(ios) or
           defined(freebsd) or defined(netbsd) or defined(openbsd) or
           defined(dragonfly):
        "kqueue"
      elif defined(android) or defined(emscripten):
        "poll"
      elif defined(posix):
        "poll"
      else:
        ""
      ## OS polling engine type which is going to be used by chronos.

else:
  # 1.2 doesn't support `booldefine` in `when` properly
  const
    chronosStrictException*: bool =
      defined(chronosPreviewV4) or defined(chronosStrictException)
    chronosStrictFutureAccess*: bool =
      defined(chronosPreviewV4) or defined(chronosStrictFutureAccess)
    chronosStackTrace*: bool = defined(chronosDebug) or defined(chronosStackTrace)
    chronosFutureId*: bool = defined(chronosDebug) or defined(chronosFutureId)
    chronosFutureTracking*: bool =
      defined(chronosDebug) or defined(chronosFutureTracking)
    chronosDumpAsync*: bool = defined(nimDumpAsync)
    chronosProcShell* {.strdefine.}: string =
      when defined(windows):
        "cmd.exe"
      else:
        when defined(android):
          "/system/bin/sh"
        else:
          "/bin/sh"
    chronosEventsCount*: int = 64
    chronosInitialSize*: int = 64
    chronosEventEngine* {.strdefine.}: string =
      when defined(linux) and not(defined(android) or defined(emscripten)):
        "epoll"
      elif defined(macosx) or defined(macos) or defined(ios) or
           defined(freebsd) or defined(netbsd) or defined(openbsd) or
           defined(dragonfly):
        "kqueue"
      elif defined(android) or defined(emscripten):
        "poll"
      elif defined(posix):
        "poll"
      else:
        ""

when defined(debug) or defined(chronosConfig):
  import std/macros

  static:
    hint("Chronos configuration:")
    template printOption(name: string, value: untyped) =
      hint(name & ": " & $value)
    printOption("chronosStrictException", chronosStrictException)
    printOption("chronosStackTrace", chronosStackTrace)
    printOption("chronosFutureId", chronosFutureId)
    printOption("chronosFutureTracking", chronosFutureTracking)
    printOption("chronosDumpAsync", chronosDumpAsync)
    printOption("chronosProcShell", chronosProcShell)
    printOption("chronosEventEngine", chronosEventEngine)
    printOption("chronosEventsCount", chronosEventsCount)
    printOption("chronosInitialSize", chronosInitialSize)
