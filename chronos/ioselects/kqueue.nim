#
#
#  Cross-platform kqueue constants, types and helpers.
#     for Nim Language <https://www.nim-lang.org>
#       (c) Copyright 2016-2023 Eugene Kabanov
#

## This module provides ``kqueue`` constants, types and helpers for MacOS,
## FreeBSD, OpenBSD, NetBSD and DragonflyBSD.

from ".."/osdefs import Time, Timespec
export Time, Timespec

when defined(macos) or defined(macosx):
  const
    EVFILT_READ* = -1
    EVFILT_WRITE* = -2
    EVFILT_AIO* = -3
      ## attached to aio requests
    EVFILT_VNODE* = -4
      ## attached to vnodes
    EVFILT_PROC* = -5
      ## attached to struct proc
    EVFILT_SIGNAL* = -6
      ## attached to struct proc
    EVFILT_TIMER* = -7
      ## timers
    EVFILT_MACHPORT* = -8
      ## Mach portsets
    EVFILT_FS* = -9
      ## Filesystem events
    EVFILT_USER* = -10
      ## User events
    EVFILT_VM* = -12
      ## Virtual memory events
    EVFILT_EXCEPT* = -15
      ## Exception events

    KEVENT_FLAG_NONE* = 0x000000
      ## no flag value
    KEVENT_FLAG_IMMEDIATE* = 0x000001
      ## immediate timeout
    KEVENT_FLAG_ERROR_EVENTS* = 0x000002
      ## output events only include change errors

    EV_ADD* = 0x0001
      ## add event to kq (implies enable)
    EV_DELETE* = 0x0002
      ## delete event from kq
    EV_ENABLE* = 0x0004
      ## enable event
    EV_DISABLE* = 0x0008
      ## disable event (not reported)

    EV_ONESHOT* = 0x0010
      ## only report one occurrence
    EV_CLEAR* = 0x0020
      ## clear event state after reporting
    EV_RECEIPT* = 0x0040
      ## force immediate event output ... with or without EV_ERROR ... use
      ## KEVENT_FLAG_ERROR_EVENTS on syscalls supporting flags
    EV_DISPATCH* = 0x0080
      ## disable event after reporting
    EV_UDATA_SPECIFIC* = 0x0100
      ## unique kevent per udata value
    EV_DISPATCH2* = EV_DISPATCH or EV_UDATA_SPECIFIC
      ## ... in combination with EV_DELETE will defer delete until
      ## udata-specific event enabled. EINPROGRESS will be returned to indicate
      ## the deferral
    EV_VANISHED* = 0x0200
      ## report that source has vanished ... only valid with EV_DISPATCH2
    EV_SYSFLAGS* = 0xF000
      ## reserved by system
    EV_FLAG0* = 0x1000
      ## filter-specific flag
    EV_FLAG1* = 0x2000
      ## filter-specific flag

    EV_EOF* = 0x8000
      ## EOF detected
    EV_ERROR* = 0x4000
      ## error, data contains errno

    EV_POLL* = EV_FLAG0
    EV_OOBAND* = EV_FLAG1

    NOTE_TRIGGER* = 0x01000000'u32
    NOTE_FFNOP* = 0x00000000'u32
      ## ignore input fflags
    NOTE_FFAND* = 0x40000000'u32
      ## and fflags
    NOTE_FFOR* = 0x80000000'u32
      ## or fflags
    NOTE_FFCOPY* = 0xc0000000'u32
      ## copy fflags
    NOTE_FFCTRLMASK* = 0xc0000000'u32
      ## mask for operations
    NOTE_FFLAGSMASK* = 0x00ffffff'u32

    NOTE_LOWAT* = 0x00000001'u32
      ## low water mark

    NOTE_OOB* = 0x00000002'u32
      ## OOB data

    NOTE_DELETE* = 0x00000001'u32
      ## vnode was removed
    NOTE_WRITE* = 0x00000002'u32
      ## data contents changed
    NOTE_EXTEND* = 0x00000004'u32
      ## size increased
    NOTE_ATTRIB* = 0x00000008'u32
      ## attributes changed
    NOTE_LINK* = 0x00000010'u32
      ## link count changed
    NOTE_RENAME* = 0x00000020'u32
      ## vnode was renamed
    NOTE_REVOKE* = 0x00000040'u32
      ## vnode access was revoked
    NOTE_NONE* = 0x00000080'u32
      ## No specific vnode event: to test for EVFILT_READ activation
    NOTE_FUNLOCK* = 0x00000100'u32
      ## vnode was unlocked by flock(2)
    NOTE_LEASE_DOWNGRADE* = 0x00000200'u32
      ## lease downgrade requested
    NOTE_LEASE_RELEASE* = 0x00000400'u32
      ## lease release requested

    NOTE_EXIT* = 0x80000000'u32
      ## process exited
    NOTE_FORK* = 0x40000000'u32
      ## process forked
    NOTE_EXEC* = 0x20000000'u32
      ## process exec'd
    NOTE_SIGNAL* = 0x08000000'u32
      ## shared with EVFILT_SIGNAL
    NOTE_EXITSTATUS* = 0x04000000'u32
      ## exit status to be returned, valid for child process or when allowed to
      ## signal target pid
    NOTE_EXIT_DETAIL* = 0x02000000'u32
      ## provide details on reasons for exit
    NOTE_PDATAMASK* = 0x000fffff'u32
      ## mask for signal & exit status
    NOTE_PCTRLMASK* = not(NOTE_PDATAMASK)
    NOTE_EXIT_DETAIL_MASK* = 0x00070000'u32
    NOTE_EXIT_DECRYPTFAIL* = 0x00010000'u32
    NOTE_EXIT_MEMORY* = 0x00020000'u32
    NOTE_EXIT_CSERROR* = 0x00040000'u32

    NOTE_VM_PRESSURE* = 0x80000000'u32
      ## will react on memory pressure
    NOTE_VM_PRESSURE_TERMINATE* = 0x40000000'u32
      ## will quit on memory pressure, possibly after cleaning up dirty state
    NOTE_VM_PRESSURE_SUDDEN_TERMINATE* = 0x20000000'u32
      ## will quit immediately on memory pressure
    NOTE_VM_ERROR* = 0x10000000'u32
      ## there was an error

    NOTE_SECONDS* = 0x00000001'u32
      ## data is seconds
    NOTE_USECONDS* = 0x00000002'u32
      ## data is microseconds
    NOTE_NSECONDS* = 0x00000004'u32
      ## data is nanoseconds
    NOTE_ABSOLUTE* = 0x00000008'u32
      ## absolute timeout
    NOTE_LEEWAY* = 0x00000010'u32
      ## ext[1] holds leeway for power aware timers
    NOTE_CRITICAL* = 0x00000020'u32
      ## system does minimal timer coalescing
    NOTE_BACKGROUND* = 0x00000040'u32
      ## system does maximum timer coalescing
    NOTE_MACH_CONTINUOUS_TIME* = 0x00000080'u32
    NOTE_MACHTIME* = 0x00000100'u32
      ## data is mach absolute time units

  type
    KEvent* {.importc: "struct kevent",
              header: """#include <sys/types.h>
                         #include <sys/event.h>
                         #include <sys/time.h>""", pure, final.} = object
      ident*: uint          ## identifier for this event  (uintptr_t)
      filter*: cshort       ## filter for event
      flags*: cushort       ## general flags
      fflags*: cuint        ## filter-specific flags
      data*: int            ## filter-specific data  (intptr_t)
      udata*: pointer       ## opaque user data identifier

    KEvent64* {.importc: "struct kevent64_s",
                header: """#include <sys/types.h>
                           #include <sys/event.h>
                           #include <sys/time.h>""", pure, final.} = object
      ident*: uint64        ## identifier for this event
      filter*: int16        ## filter for event
      flags: uint16         ## general flags
      fflags*: uint32       ## filter-specific flags
      data*: int64          ## filter-specific data
      udata: uint64         ## opaque user data identifier
      ext: array[2, uint64] ## filter-specific extensions

  proc kqueue*(): cint {.
       importc: "kqueue", header: "<sys/event.h>".}
    ## Creates new queue and returns its descriptor.

  proc kevent*(kqFD: cint,
               changelist: ptr KEvent, nchanges: cint,
               eventlist: ptr KEvent, nevents: cint,
               timeout: ptr Timespec): cint {.
       importc: "kevent", header: "<sys/event.h>".}
    ## Manipulates queue for given `kqFD` descriptor.

  proc kevent64*(kqFD: cint,
                 changelist: ptr KEvent64, nchanges: cint,
                 eventlist: ptr KEvent64, nevents: cint,
                 flags: cuint, timeout: ptr Timespec): cint {.
       importc: "kevent64", header: "<sys/event.h>".}
    ## Manipulates queue for given `kqFD` descriptor.

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: uint): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: cast[pointer](udata))

  func init*(t: typedesc[KEvent64], ident: uint64, filter: int16, flags: uint16,
             fflags: uint32, data: int64, udata: uint64,
             ext: array[2, uint64]): KEvent {.noinit.} =
    KEvent64(ident: ident, filter: filter, flags: flags, fflags: fflags,
             data: data, udata: udata, ext: ext)

  func init*(t: typedesc[KEvent64], ident: uint64, filter: int16, flags: uint16,
             fflags: uint32, data: int64, udata: uint64): KEvent {.noinit.} =
    KEvent64(ident: ident, filter: filter, flags: flags, fflags: fflags,
             data: data, udata: udata)

  func init*(t: typedesc[KEvent64], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: uint): KEvent {.noinit.} =
    KEvent64(ident: uint64(ident), filter: int16(filter), flags: uint16(flags),
             fflags: uint32(fflags), data: int64(data), udata: uint64(udata))

elif defined(freebsd):
  const
    EVFILT_READ* = -1
    EVFILT_WRITE* = -2
    EVFILT_AIO* = -3
      ## attached to aio requests
    EVFILT_VNODE* = -4
      ## attached to vnodes
    EVFILT_PROC* = -5
      ## attached to struct proc
    EVFILT_SIGNAL* = -6
      ## attached to struct proc
    EVFILT_TIMER* = -7
      ## timers
    EVFILT_PROCDESC* = -8
      ## attached to process descriptors
    EVFILT_FS* = -9
      ## filesystem events
    EVFILT_LIO* = -10
      ## attached to lio requests
    EVFILT_USER* = -11
      ## User events
    EVFILT_SENDFILE* = -12
      ## attached to sendfile requests
    EVFILT_EMPTY* = -13
      ## empty send socket buf

    EV_ADD* = 0x0001
      ## add event to kq (implies enable)
    EV_DELETE* = 0x0002
      ## delete event from kq
    EV_ENABLE* = 0x0004
      ## enable event
    EV_DISABLE* = 0x0008
      ## disable event (not reported)
    EV_FORCEONESHOT* = 0x0100
      ## enable _ONESHOT and force trigger
    EV_KEEPUDATA* = 0x0200
      ## do not update the udata field

    EV_ONESHOT* = 0x0010
      ## only report one occurrence
    EV_CLEAR* = 0x0020
      ## clear event state after reporting
    EV_RECEIPT* = 0x0040
      ## force EV_ERROR on success, data=0
    EV_DISPATCH* = 0x0080
      ## disable event after reporting

    EV_SYSFLAGS* = 0xF000
      ## reserved by system
    EV_DROP* = 0x1000
      ## note should be dropped
    EV_FLAG1* = 0x2000
      ## filter-specific flag
    EV_FLAG2* = 0x4000
      ## filter-specific flag

    EV_EOF* = 0x8000
      ## EOF detected
    EV_ERROR* = 0x4000
      ## error, data contains errno

    NOTE_FFNOP* = 0x00000000'u32
      ## ignore input fflags
    NOTE_FFAND* = 0x40000000'u32
      ## AND fflags
    NOTE_FFOR* = 0x80000000'u32
      ## OR fflags
    NOTE_FFCOPY* = 0xc0000000'u32
      ## copy fflags
    NOTE_FFCTRLMASK* = 0xc0000000'u32
      ## masks for operations
    NOTE_FFLAGSMASK* = 0x00ffffff'u32

    NOTE_TRIGGER* = 0x01000000'u32
      ## Cause the event to be triggered for output.

    NOTE_LOWAT* = 0x0001'u32
      ## low water mark
    NOTE_FILE_POLL* = 0x0002'u32
      ## behave like poll()

    NOTE_DELETE* = 0x0001'u32
      ## vnode was removed
    NOTE_WRITE* = 0x0002'u32
      ## data contents changed
    NOTE_EXTEND* = 0x0004'u32
      ## size increased
    NOTE_ATTRIB* = 0x0008'u32
      ## attributes changed
    NOTE_LINK* = 0x0010'u32
      ## link count changed
    NOTE_RENAME* = 0x0020'u32
      ## vnode was renamed
    NOTE_REVOKE* = 0x0040'u32
      ## vnode access was revoked
    NOTE_OPEN* = 0x0080'u32
      ## vnode was opened
    NOTE_CLOSE* = 0x0100'u32
      ## file closed, fd did not allowed write
    NOTE_CLOSE_WRITE* = 0x0200'u32
      ## file closed, fd did allowed write
    NOTE_READ* = 0x0400'u32
      ## file was read

    NOTE_EXIT* = 0x80000000'u32
      ## process exited
    NOTE_FORK* = 0x40000000'u32
      ## process forked
    NOTE_EXEC* = 0x20000000'u32
      ## process exec'd
    NOTE_PCTRLMASK* = 0xf0000000'u32
      ## mask for hint bits
    NOTE_PDATAMASK* = 0x000fffff'u32
      ## mask for pid

    NOTE_TRACK* = 0x00000001'u32
      ## follow across forks
    NOTE_TRACKERR* = 0x00000002'u32
      ## could not track child
    NOTE_CHILD* = 0x00000004'u32
      ## am a child process

    NOTE_SECONDS* = 0x00000001'u32
      ## data is seconds
    NOTE_MSECONDS* = 0x00000002'u32
      ## data is milliseconds
    NOTE_USECONDS* = 0x00000004'u32
      ## data is microseconds
    NOTE_NSECONDS* = 0x00000008'u32
      ## data is nanoseconds
    NOTE_ABSTIME* = 0x00000010'u32
      ## timeout is absolute

    KQUEUE_CLOEXEC* = 0x00000001
      ## close on exec

  type
    KEvent* {.importc: "struct kevent",
              header: """#include <sys/types.h>
                         #include <sys/event.h>
                         #include <sys/time.h>""", pure, final.} = object
      ident*: uint           ## identifier for this event  (uintptr_t)
      filter*: cshort        ## filter for event
      flags*: cushort        ## general flags
      fflags*: cuint         ## filter-specific flags
      data*: int64           ## filter-specific data  (intptr_t)
      udata*: pointer        ## opaque user data identifier
      ext*: array[4, uint64] ## extensions

  proc kqueue*(): cint {.
       importc: "kqueue", header: "<sys/event.h>".}
    ## Creates new queue and returns its descriptor.

  proc kqueuex*(flags: cuint): cint {.
       importc: "kqueuex", header: "<sys/event.h>".}
    ## Creates new queue using flags ``flags`` and returns its descriptor.

  proc kqueue1*(flags: cuint): cint {.
       importc: "kqueue1", header: "<sys/event.h>".}
    ## Creates new queue using flags ``flags`` and returns its descriptor.

  proc kevent*(kqFD: cint,
               changelist: ptr KEvent, nchanges: cint,
               eventlist: ptr KEvent, nevents: cint,
               timeout: ptr Timespec): cint {.
       importc: "kevent", header: "<sys/event.h>".}
    ## Manipulates queue for given `kqFD` descriptor.

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int64, udata: pointer,
             ext: array[4, uint64]): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata, ext: ext)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int64, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: int64(data), udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: uint): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: int64(data), udata: cast[pointer](udata))

elif defined(openbsd):
  const
    EVFILT_READ* = -1
    EVFILT_WRITE* = -2
    EVFILT_AIO* = -3
      ## attached to aio requests
    EVFILT_VNODE* = -4
      ## attached to vnodes
    EVFILT_PROC* = -5
      ## attached to struct process
    EVFILT_SIGNAL* = -6
      ## attached to struct process
    EVFILT_TIMER* = -7
      ## timers
    EVFILT_DEVICE* = -8
      ## devices
    EVFILT_EXCEPT* = -9
      ## exceptional conditions

    EV_ADD* = 0x0001
      ## add event to kq (implies enable)
    EV_DELETE* = 0x0002
      ## delete event from kq
    EV_ENABLE* = 0x0004
      ## enable event
    EV_DISABLE* = 0x0008
      ## disable event (not reported)

    EV_ONESHOT* = 0x0010
      ## only report one occurrence
    EV_CLEAR* = 0x0020
      ## clear event state after reporting
    EV_RECEIPT* = 0x0040
      ## force EV_ERROR on success, data=0
    EV_DISPATCH* = 0x0080
      ## disable event after reporting

    EV_SYSFLAGS* = 0xf800
      ## reserved by system
    EV_FLAG1* = 0x2000
      ## filter-specific flag

    EV_EOF* = 0x8000
      ## EOF detected
    EV_ERROR* = 0x4000
      ## error, data contains errno

    NOTE_LOWAT* = 0x0001'u32
      ## low water mark
    NOTE_EOF* = 0x0002'u32
      ## return on EOF

    NOTE_OOB* = 0x0004'u32
      ## OOB data on a socket

    NOTE_DELETE* = 0x0001'u32
      ## vnode was removed
    NOTE_WRITE* = 0x0002'u32
      ## data contents changed
    NOTE_EXTEND* = 0x0004'u32
      ## size increased
    NOTE_ATTRIB* = 0x0008'u32
      ## attributes changed
    NOTE_LINK* = 0x0010'u32
      ## link count changed
    NOTE_RENAME* = 0x0020'u32
      ## vnode was renamed
    NOTE_REVOKE* = 0x0040'u32
      ## vnode access was revoked
    NOTE_TRUNCATE* = 0x0080'u32
      ## vnode was truncated

    NOTE_EXIT* = 0x80000000'u32
      ## process exited
    NOTE_FORK* = 0x40000000'u32
      ## process forked
    NOTE_EXEC* = 0x20000000'u32
      ## process exec'd
    NOTE_PCTRLMASK* = 0xf0000000'u32
      ## mask for hint bits
    NOTE_PDATAMASK* = 0x000fffff'u32
      ## mask for pid

    NOTE_TRACK* = 0x00000001'u32
      ## follow across forks
    NOTE_TRACKERR* = 0x00000002'u32
      ## could not track child
    NOTE_CHILD* = 0x00000004'u32
      ## am a child process

    NOTE_CHANGE* = 0x00000001'u32
      ## device change event

  type
    KEvent* {.importc: "struct kevent",
              header: """#include <sys/types.h>
                         #include <sys/event.h>
                         #include <sys/time.h>""", pure, final.} = object
      ident*: uint      ## identifier for this event  (uintptr_t)
      filter*: cshort   ## filter for event
      flags*: cushort   ## general flags
      fflags*: cuint    ## filter-specific flags
      data*: int64      ## filter-specific data  (intptr_t)
      udata*: pointer   ## opaque user data identifier

  proc kqueue*(): cint {.
       importc: "kqueue", header: "<sys/event.h>".}
    ## Creates new queue and returns its descriptor.

  proc kevent*(kqFD: cint,
               changelist: ptr KEvent, nchanges: cint,
               eventlist: ptr KEvent, nevents: cint,
               timeout: ptr Timespec): cint {.
       importc: "kevent", header: "<sys/event.h>".}
    ## Manipulates queue for given `kqFD` descriptor.

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int64, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: int64(data), udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: uint): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: int64(data), udata: cast[pointer](udata))

elif defined(netbsd):
  const
    EVFILT_READ* = 0
    EVFILT_WRITE* = 1
    EVFILT_AIO* = 2
      ## attached to aio requests
    EVFILT_VNODE* = 3
      ## attached to vnodes
    EVFILT_PROC* = 4
      ## attached to struct proc
    EVFILT_SIGNAL* = 5
      ## attached to struct proc
    EVFILT_TIMER* = 6
      ## arbitrary timer (in ms)
    EVFILT_FS* = 7
      ## filesystem events
    EVFILT_USER* = 8
      ## user events
    EVFILT_EMPTY* = 9

    EV_ADD* = 0x0001
      ## add event to kq (implies ENABLE)
    EV_DELETE* = 0x0002
      ## delete event from kq
    EV_ENABLE* = 0x0004
      ## enable event
    EV_DISABLE* = 0x0008
      ## disable event (not reported)

    EV_ONESHOT* = 0x0010
      ## only report one occurrence
    EV_CLEAR* = 0x0020
      ## clear event state after reporting
    EV_RECEIPT* = 0x0040
      ## force EV_ERROR on success, data=0
    EV_DISPATCH* = 0x0080
      ## disable event after reporting

    EV_SYSFLAGS* = 0xF000
      ## reserved by system
    EV_FLAG1* = 0x2000
      ## filter-specific flag

    EV_EOF* = 0x8000
      ## EOF detected
    EV_ERROR* = 0x4000
      ## error, data contains errno

    NOTE_FFNOP* = 0x00000000'u32
      ## ignore input fflags
    NOTE_FFAND* = 0x40000000'u32
      ## AND fflags
    NOTE_FFOR* = 0x80000000'u32
      ## OR fflags
    NOTE_FFCOPY* = 0xc0000000'u32
      ## copy fflags

    NOTE_FFCTRLMASK* = 0xc0000000'u32
      ## masks for operations
    NOTE_FFLAGSMASK* = 0x00ffffff'u32
    NOTE_TRIGGER* = 0x01000000'u32
      ## Cause the event to be triggered for output.

    NOTE_LOWAT* = 0x0001'u32
      ## low water mark */

    NOTE_DELETE* = 0x0001'u32
      ## vnode was removed
    NOTE_WRITE* = 0x0002'u32
      ## data contents changed
    NOTE_EXTEND* = 0x0004'u32
      ## size increased
    NOTE_ATTRIB* = 0x0008'u32
      ## attributes changed
    NOTE_LINK* = 0x0010'u32
      ## link count changed
    NOTE_RENAME* = 0x0020'u32
      ## vnode was renamed
    NOTE_REVOKE* = 0x0040'u32
      ## vnode access was revoked
    NOTE_OPEN* = 0x0080'u32
      ## vnode was opened
    NOTE_CLOSE* = 0x0100'u32
      ## file closed (no FWRITE)
    NOTE_CLOSE_WRITE* = 0x0200'u32
      ## file closed (FWRITE)
    NOTE_READ* = 0x0400'u32
      ## file was read

    NOTE_EXIT* = 0x80000000'u32
      ## process exited
    NOTE_FORK* = 0x40000000'u32
      ## process forked
    NOTE_EXEC* = 0x20000000'u32
      ## process exec'd
    NOTE_PCTRLMASK* = 0xf0000000'u32
      ## mask for hint bits
    NOTE_PDATAMASK* = 0x000fffff'u32
      ## mask for pid

    NOTE_TRACK* = 0x00000001'u32
      ## follow across forks
    NOTE_TRACKERR* = 0x00000002'u32
      ## could not track child
    NOTE_CHILD* = 0x00000004'u32
      ## am a child process

    NOTE_MSECONDS* = 0x00000000'u32
      ## data is milliseconds
    NOTE_SECONDS* = 0x00000001'u32
      ## data is seconds
    NOTE_USECONDS* = 0x00000002'u32
      ## data is microseconds
    NOTE_NSECONDS* = 0x00000003'u32
      ## data is nanoseconds
    NOTE_ABSTIME* = 0x00000010'u32
      ## timeout is absolute

  type
    KEvent* {.importc: "struct kevent",
              header: """#include <sys/types.h>
                         #include <sys/event.h>
                         #include <sys/time.h>""", pure, final.} = object
      ident*: uint          ## identifier for this event  (uintptr_t)
      filter*: uint32       ## filter for event
      flags*: uint32        ## general flags
      fflags*: uint32       ## filter-specific flags
      data*: int64          ## filter data value
      udata*: pointer       ## opaque user data identifier
      ext: array[4, uint64] ## extensions

  proc kqueue*(): cint {.
       importc: "kqueue", header: "<sys/event.h>".}
    ## Creates new queue and returns its descriptor.

  proc kqueue1*(flags: cint): cint {.
       importc: "kqueue1", header: "<sys/event.h>".}
    ## Creates new queue using flags ``flags`` and returns its descriptor.

  proc kevent*(kqFD: cint,
               changelist: ptr KEvent, nchanges: csize_t,
               eventlist: ptr KEvent, nevents: csize_t,
               timeout: ptr Timespec): cint {.
       importc: "kevent", header: "<sys/event.h>".}
    ## Manipulates queue for given `kqFD` descriptor.

  func init*(t: typedesc[KEvent], ident: uint, filter: uint32, flags: uint32,
             fflags: uint32, data: int64, udata: pointer,
             ext: array[4, uint64]): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata, ext: ext)

  func init*(t: typedesc[KEvent], ident: uint, filter: uint32, flags: uint32,
             fflags: uint32, data: int64, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: uint32(filter), flags: uint32(flags),
           fflags: uint32(fflags), data: int64(data), udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: uint): KEvent {.noinit.} =
    KEvent(ident: ident, filter: uint32(filter), flags: uint32(flags),
           fflags: uint32(fflags), data: int64(data),
           udata: cast[pointer](udata))

elif defined(dragonflybsd):
  const
    EVFILT_READ* = -1
    EVFILT_WRITE* = -2
    EVFILT_AIO* = -3
      ## attached to aio requests
    EVFILT_VNODE* = -4
      ## attached to vnodes
    EVFILT_PROC* = -5
      ## attached to struct proc
    EVFILT_SIGNAL* = -6
      ## attached to struct proc
    EVFILT_TIMER* = -7
      ## timers
    EVFILT_EXCEPT* = -8
      ## exceptional conditions
    EVFILT_USER* = -9
      ## user events
    EVFILT_FS* = -10
      ## filesystem events

    EV_ADD* = 0x0001
      ## add event to kq (implies enable)
    EV_DELETE* = 0x0002
      ## delete event from kq
    EV_ENABLE* = 0x0004
      ## enable event
    EV_DISABLE* = 0x0008
      ## disable event (not reported)

    EV_ONESHOT* = 0x0010
      ## only report one occurrence
    EV_CLEAR* = 0x0020
      ## clear event state after reporting
    EV_RECEIPT* = 0x0040
      ## force EV_ERROR on success, data=0
    EV_DISPATCH* =0x0080
      ## disable event after reporting

    EV_SYSFLAGS* = 0xF800
      ## reserved by system
    EV_FLAG1* = 0x2000
      ## filter-specific flag

    EV_HUP* = 0x0800
      ## complete peer disconnect
    EV_EOF* = 0x8000
      ## EOF detected
    EV_ERROR* = 0x4000
      ## error, data contains errno
    EV_NODATA* = 0x1000
      ## EOF and no more data

    NOTE_FFNOP* = 0x00000000'u32
      ## ignore input fflags
    NOTE_FFAND* = 0x40000000'u32
      ## AND fflags
    NOTE_FFOR* = 0x80000000'u32
      ## OR fflags
    NOTE_FFCOPY* = 0xc0000000'u32
      ## copy fflags
    NOTE_FFCTRLMASK* = 0xc0000000'u32
      ## masks for operations
    NOTE_FFLAGSMASK* = 0x00ffffff'u32
    NOTE_TRIGGER* = 0x01000000'u32
      ## trigger for output

    NOTE_LOWAT* = 0x0001'u32
      ## low water mark

    NOTE_OOB* = 0x0002'u32
      ## OOB data on a socket

    NOTE_DELETE* = 0x0001'u32
      ## vnode was removed
    NOTE_WRITE* =  0x0002'u32
      ## data contents changed
    NOTE_EXTEND* = 0x0004'u32
      ## size increased
    NOTE_ATTRIB* = 0x0008'u32
      ## attributes changed
    NOTE_LINK* = 0x0010'u32
      ## link count changed
    NOTE_RENAME* = 0x0020'u32
      ## vnode was renamed
    NOTE_REVOKE* = 0x0040'u32
      ## vnode access was revoked

    NOTE_EXIT* = 0x80000000'u32
      ## process exited
    NOTE_FORK* = 0x40000000'u32
      ## process forked
    NOTE_EXEC* = 0x20000000'u32
      ## process exec'd
    NOTE_PCTRLMASK* = 0xf0000000'u32
      ## mask for hint bits
    NOTE_PDATAMASK* = 0x000fffff'u32
      ## mask for pid

    NOTE_TRACK* = 0x00000001'u32
      ## follow across forks
    NOTE_TRACKERR* = 0x00000002'u32
      ## could not track child
    NOTE_CHILD* = 0x00000004'u32
      ## am a child process

  type
    KEvent* {.importc: "struct kevent",
              header: """#include <sys/types.h>
                         #include <sys/event.h>
                         #include <sys/time.h>""", pure, final.} = object
      ident*: uint      ## identifier for this event  (uintptr_t)
      filter*: cshort   ## filter for event
      flags*: cushort   ## general flags
      fflags*: cuint    ## filter-specific flags
      data*: int        ## filter-specific data  (intptr_t)
      udata*: pointer   ## opaque user data identifier

  proc kqueue*(): cint {.
       importc: "kqueue", header: "<sys/event.h>".}
    ## Creates new queue and returns its descriptor.

  proc kevent*(kqFD: cint,
               changelist: ptr KEvent, nchanges: cint,
               eventlist: ptr KEvent, nevents: cint,
               timeout: ptr Timespec): cint {.
       importc: "kevent", header: "<sys/event.h>".}
    ## Manipulates queue for given `kqFD` descriptor.

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: pointer): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: udata)

  func init*(t: typedesc[KEvent], ident: uint, filter: cshort, flags: cushort,
             fflags: cuint, data: int, udata: uint): KEvent {.noinit.} =
    KEvent(ident: ident, filter: filter, flags: flags, fflags: fflags,
           data: data, udata: cast[pointer](udata))
