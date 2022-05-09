#
#                Chronos' OS declarations
#
#  (c) Copyright 2022-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)
when defined(windows):
  import std/os
  export os

  from winlean import SocketHandle, SockLen, SockAddr, InAddr,
                      In6_addr, Sockaddr_in, Sockaddr_in6, Sockaddr_storage,
                      AddrInfo
  export SocketHandle, SockLen, SockAddr, InAddr,
         In6_addr, Sockaddr_in, Sockaddr_in6, Sockaddr_storage, AddrInfo

  const
    WSADESCRIPTION_LEN* = 256
    WSASYS_STATUS_LEN* = 128
    MAX_ADAPTER_DESCRIPTION_LENGTH* = 128
    MAX_ADAPTER_NAME_LENGTH* = 256
    MAX_ADAPTER_ADDRESS_LENGTH* = 8

  type
    HANDLE* = distinct uint
    LONG* = int32
    ULONG* = uint32
    PULONG* = ptr uint32
    WINBOOL* = uint32
    DWORD* = uint32
    WORD* = uint16
    UINT* = uint32
    PDWORD* = ptr DWORD
    LPINT* = ptr int32
    LPSTR* = cstring
    ULONG_PTR* = uint
    PULONG_PTR* = ptr uint
    WCHAR* = distinct uint16
    GROUP* = uint32

    WSAData* {.importc: "WSADATA", header: "winsock2.h".} = object
      wVersion, wHighVersion: WORD
      szDescription: array[0..WSADESCRIPTION_LEN, char]
      szSystemStatus: array[0..WSASYS_STATUS_LEN, char]
      iMaxSockets, iMaxUdpDg: WORD
      lpVendorInfo: cstring

    SECURITY_ATTRIBUTES* {.final, pure.} = object
      nLength*: DWORD
      lpSecurityDescriptor*: pointer
      bInheritHandle*: WINBOOL

    OVERLAPPED* {.pure, inheritable.} = object
      internal*: PULONG
      internalHigh*: PULONG
      offset*: DWORD
      offsetHigh*: DWORD
      hEvent*: HANDLE

    WSABUF* {.final, pure.} = object
      len*: ULONG
      buf*: cstring

    POVERLAPPED* = ptr OVERLAPPED

    POVERLAPPED_COMPLETION_ROUTINE* = proc (para1: DWORD, para2: DWORD,
                                            para3: POVERLAPPED) {.
                                      stdcall, gcsafe, raises: [].}

    OSVERSIONINFO* {.final, pure.} = object
      dwOSVersionInfoSize*: DWORD
      dwMajorVersion*: DWORD
      dwMinorVersion*: DWORD
      dwBuildNumber*: DWORD
      dwPlatformId*: DWORD
      szCSDVersion*: array[0..127, WORD]

    STARTUPINFO* {.final, pure.} = object
      cb*: DWORD
      lpReserved*: LPSTR
      lpDesktop*: LPSTR
      lpTitle*: LPSTR
      dwX*: DWORD
      dwY*: DWORD
      dwXSize*: DWORD
      dwYSize*: DWORD
      dwXCountChars*: DWORD
      dwYCountChars*: DWORD
      dwFillAttribute*: DWORD
      dwFlags*: DWORD
      wShowWindow*: WORD
      cbReserved2*: WORD
      lpReserved2*: pointer
      hStdInput*: HANDLE
      hStdOutput*: HANDLE
      hStdError*: HANDLE

    PROCESS_INFORMATION* {.final, pure.} = object
      hProcess*: HANDLE
      hThread*: HANDLE
      dwProcessId*: DWORD
      dwThreadId*: DWORD

    FILETIME* {.final, pure.} = object
      dwLowDateTime*: DWORD
      dwHighDateTime*: DWORD

    GUID* {.final, pure.} = object
      D1*: ULONG
      D2*: WORD
      D3*: WORD
      D4*: array[0..7, byte]

    SocketAddress* {.final, pure.} = object
      lpSockaddr*: ptr SockAddr
      iSockaddrLength*: cint

    IpAdapterUnicastAddressXpLh* {.final, pure.} = object
      length*: uint32
      flags*: uint32
      next*: ptr IpAdapterUnicastAddressXpLh
      address*: SocketAddress
      prefixOrigin*: cint
      suffixOrigin*: cint
      dadState*: cint
      validLifetime*: uint32
      preferredLifetime*: uint32
      leaseLifetime*: uint32
      onLinkPrefixLength*: byte # This field is available only from Vista

    IpAdapterAnycastAddressXp* {.final, pure.} = object
      length*: uint32
      flags*: uint32
      next*: ptr IpAdapterAnycastAddressXp
      address*: SocketAddress

    IpAdapterMulticastAddressXp* {.final, pure.} = object
      length*: uint32
      flags*: uint32
      next*: ptr IpAdapterMulticastAddressXp
      address*: SocketAddress

    IpAdapterDnsServerAddressXp* {.final, pure.} = object
      length*: uint32
      flags*: uint32
      next*: ptr IpAdapterDnsServerAddressXp
      address*: SocketAddress

    IpAdapterPrefixXp* {.final, pure.} = object
      length*: uint32
      flags*: uint32
      next*: ptr IpAdapterPrefixXp
      address*: SocketAddress
      prefixLength*: uint32

    IpAdapterAddressesXp* {.final, pure.} = object
      length*: uint32
      ifIndex*: uint32
      next*: ptr IpAdapterAddressesXp
      adapterName*: cstring
      unicastAddress*: ptr IpAdapterUnicastAddressXpLh
      anycastAddress*: ptr IpAdapterAnycastAddressXp
      multicastAddress*: ptr IpAdapterMulticastAddressXp
      dnsServerAddress*: ptr IpAdapterDnsServerAddressXp
      dnsSuffix*: ptr WCHAR
      description*: ptr WCHAR
      friendlyName*: ptr WCHAR
      physicalAddress*: array[MAX_ADAPTER_ADDRESS_LENGTH, byte]
      physicalAddressLength*: uint32
      flags*: uint32
      mtu*: uint32
      ifType*: uint32
      operStatus*: cint
      ipv6IfIndex*: uint32
      zoneIndices*: array[16, uint32]
      firstPrefix*: ptr IpAdapterPrefixXp

    MibIpForwardRow* {.final, pure.} = object
      dwForwardDest*: uint32
      dwForwardMask*: uint32
      dwForwardPolicy*: uint32
      dwForwardNextHop*: uint32
      dwForwardIfIndex*: uint32
      dwForwardType*: uint32
      dwForwardProto*: uint32
      dwForwardAge*: uint32
      dwForwardNextHopAS*: uint32
      dwForwardMetric1*: uint32
      dwForwardMetric2*: uint32
      dwForwardMetric3*: uint32
      dwForwardMetric4*: uint32
      dwForwardMetric5*: uint32

    SOCKADDR_INET* {.union.} = object
      ipv4*: Sockaddr_in
      ipv6*: Sockaddr_in6
      si_family*: uint16

    IPADDRESS_PREFIX* {.final, pure.} = object
      prefix*: SOCKADDR_INET
      prefixLength*: uint8

    MibIpForwardRow2* {.final, pure.} = object
      interfaceLuid*: uint64
      interfaceIndex*: uint32
      destinationPrefix*: IPADDRESS_PREFIX
      nextHop*: SOCKADDR_INET
      sitePrefixLength*: byte
      validLifetime*: uint32
      preferredLifetime*: uint32
      metric*: uint32
      protocol*: uint32
      loopback*: bool
      autoconfigureAddress*: bool
      publish*: bool
      immortal*: bool
      age*: uint32
      origin*: uint32

    GETBESTROUTE2* = proc(interfaceLuid: ptr uint64, interfaceIndex: uint32,
                          sourceAddress: ptr SOCKADDR_INET,
                          destinationAddress: ptr SOCKADDR_INET,
                          addressSortOptions: uint32,
                          bestRoute: ptr MibIpForwardRow2,
                          bestSourceAddress: ptr SOCKADDR_INET): DWORD {.
                     gcsafe, stdcall, raises: [].}

    WAITORTIMERCALLBACK* = proc(p1: pointer, p2: DWORD): void {.
                           gcsafe, stdcall, raises: [].}

    WSAPROC_ACCEPTEX* = proc (sListenSocket: SocketHandle,
                              sAcceptSocket: SocketHandle,
                              lpOutputBuffer: pointer,
                              dwReceiveDataLength: DWORD,
                              dwLocalAddressLength: DWORD,
                              dwRemoteAddressLength: DWORD,
                              lpdwBytesReceived: ptr DWORD,
                              lpOverlapped: POVERLAPPED): WINBOOL {.
                        stdcall, gcsafe, raises: [].}

    WSAPROC_CONNECTEX* = proc (s: SocketHandle, name: ptr SockAddr,
                               namelen: cint, lpSendBuffer: pointer,
                               dwSendDataLength: DWORD,
                               lpdwBytesSent: ptr DWORD,
                               lpOverlapped: POVERLAPPED): WINBOOL {.
                         stdcall, gcsafe, raises: [].}

    WSAPROC_GETACCEPTEXSOCKADDRS* = proc(lpOutputBuffer: pointer,
                                         dwReceiveDataLength: DWORD,
                                         dwLocalAddressLength: DWORD,
                                         dwRemoteAddressLength: DWORD,
                                         localSockaddr: ptr ptr SockAddr,
                                         localSockaddrLength: LPINT,
                                         remoteSockaddr: ptr ptr SockAddr,
                                         remoteSockaddrLength: LPINT) {.
                                    stdcall, gcsafe, raises: [].}

    WSAPROC_TRANSMITFILE* = proc(hSocket: SocketHandle, hFile: HANDLE,
                                 nNumberOfBytesToWrite: DWORD,
                                 nNumberOfBytesPerSend: DWORD,
                                 lpOverlapped: POVERLAPPED,
                                 lpTransmitBuffers: pointer,
                                 dwReserved: DWORD): WINBOOL {.
                            stdcall, gcsafe, raises: [].}

  proc getVersionEx*(lpVersionInfo: ptr OSVERSIONINFO): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "GetVersionExW", sideEffect.}

  proc createProcess*(lpApplicationName, lpCommandLine: WideCString,
                      lpProcessAttributes: ptr SECURITY_ATTRIBUTES,
                      lpThreadAttributes: ptr SECURITY_ATTRIBUTES,
                      bInheritHandles: WINBOOL, dwCreationFlags: DWORD,
                      lpEnvironment, lpCurrentDirectory: WideCString,
                      lpStartupInfo: var STARTUPINFO,
                      lpProcessInformation: var PROCESS_INFORMATION): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "CreateProcessW", sideEffect.}

  proc terminateProcess*(hProcess: HANDLE, uExitCode: UINT): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "TerminateProcess", sideEffect.}

  proc getExitCodeProcess*(hProcess: HANDLE, lpExitCode: var DWORD): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "GetExitCodeProcess", sideEffect.}

  proc getStdHandle*(nStdHandle: DWORD): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "GetStdHandle", sideEffect.}

  proc setStdHandle*(nStdHandle: DWORD, hHandle: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "SetStdHandle", sideEffect.}

  proc suspendThread*(hThread: HANDLE): DWORD {.
      stdcall, dynlib: "kernel32", importc: "SuspendThread", sideEffect.}

  proc resumeThread*(hThread: HANDLE): DWORD {.
       stdcall, dynlib: "kernel32", importc: "ResumeThread", sideEffect.}

  proc closeHandle*(hObject: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "CloseHandle", sideEffect.}

  proc flushFileBuffers*(hFile: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "FlushFileBuffers", sideEffect.}

  proc getCurrentDirectory*(nBufferLength: DWORD,
                            lpBuffer: WideCString): DWORD {.
       stdcall, dynlib: "kernel32", importc: "GetCurrentDirectoryW",
       sideEffect.}

  proc setCurrentDirectory*(lpPathName: WideCString): DWORD {.
       stdcall, dynlib: "kernel32", importc: "SetCurrentDirectoryW",
       sideEffect.}

  proc setEnvironmentVariable*(lpName, lpValue: WideCString): DWORD {.
       stdcall, dynlib: "kernel32", importc: "SetEnvironmentVariableW",
       sideEffect.}

  proc getModuleFileName*(handle: HANDLE, buf: WideCString,
                          size: DWORD): DWORD {.
       stdcall, dynlib: "kernel32", importc: "GetModuleFileNameW", sideEffect.}

  proc postQueuedCompletionStatus*(completionPort: HANDLE,
                                   dwNumberOfBytesTransferred: DWORD,
                                   dwCompletionKey: ULONG_PTR,
                                   lpOverlapped: pointer): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "PostQueuedCompletionStatus",
       sideEffect.}

  proc registerWaitForSingleObject*(phNewWaitObject: ptr HANDLE,
                                    hObject: HANDLE,
                                    callback: WAITORTIMERCALLBACK,
                                    context: pointer,
                                    dwMilliseconds: ULONG,
                                    dwFlags: ULONG): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "RegisterWaitForSingleObject",
       sideEffect.}

  proc waitForSingleObject*(hHandle: HANDLE, dwMilliseconds: DWORD): DWORD {.
       stdcall, dynlib: "kernel32", importc: "WaitForSingleObject",
       sideEffect.}

  proc unregisterWait*(waitHandle: HANDLE): DWORD {.
       stdcall, dynlib: "kernel32", importc: "UnregisterWait", sideEffect.}

  proc openProcess*(dwDesiredAccess: DWORD, bInheritHandle: WINBOOL,
                    dwProcessId: DWORD): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "OpenProcess", sideEffect.}

  proc duplicateHandle*(hSourceProcessHandle: HANDLE, hSourceHandle: HANDLE,
                        hTargetProcessHandle: HANDLE,
                        lpTargetHandle: ptr HANDLE,
                        dwDesiredAccess: DWORD, bInheritHandle: WINBOOL,
                        dwOptions: DWORD): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "DuplicateHandle", sideEffect.}

  proc setHandleInformation*(hObject: HANDLE, dwMask: DWORD,
                             dwFlags: DWORD): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "SetHandleInformation",
       sideEffect.}

  proc getHandleInformation*(hObject: HANDLE, lpdwFlags: var DWORD): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "GetHandleInformation",
       sideEffect.}

  proc getCurrentProcess*(): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "GetCurrentProcess", sideEffect.}

  proc getSystemTimeAsFileTime*(lpSystemTimeAsFileTime: var FILETIME) {.
       stdcall, dynlib: "kernel32", importc: "GetSystemTimeAsFileTime",
       sideEffect.}

  proc connectNamedPipe*(hNamedPipe: HANDLE, lpOverlapped: pointer): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "ConnectNamedPipe", sideEffect.}

  proc wsaIoctl*(s: SocketHandle, dwIoControlCode: DWORD, lpvInBuffer: pointer,
                 cbInBuffer: DWORD, lpvOutBuffer: pointer, cbOutBuffer: DWORD,
                 lpcbBytesReturned: PDWORD, lpOverlapped: POVERLAPPED,
                 lpCompletionRoutine: POVERLAPPED_COMPLETION_ROUTINE): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSAIoctl", sideEffect.}

  proc wsaStartup*(wVersionRequired: WORD, WSData: ptr WSAData): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSAStartup", sideEffect.}

  proc wsaRecv*(s: SocketHandle, buf: ptr WSABUF, bufCount: DWORD,
                bytesReceived, flags: PDWORD, lpOverlapped: POVERLAPPED,
                completionProc: POVERLAPPED_COMPLETION_ROUTINE): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSARecv", sideEffect.}

  proc wsaRecvFrom*(s: SocketHandle, buf: ptr WSABUF, bufCount: DWORD,
                    bytesReceived: PDWORD, flags: PDWORD, name: ptr SockAddr,
                    namelen: ptr cint, lpOverlapped: POVERLAPPED,
                    completionProc: POVERLAPPED_COMPLETION_ROUTINE): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSARecvFrom", sideEffect.}

  proc wsaSend*(s: SocketHandle, buf: ptr WSABUF, bufCount: DWORD,
                bytesSent: PDWORD, flags: DWORD, lpOverlapped: POVERLAPPED,
                completionProc: POVERLAPPED_COMPLETION_ROUTINE): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSASend", sideEffect.}

  proc wsaSendTo*(s: SocketHandle, buf: ptr WSABUF, bufCount: DWORD,
                  bytesSent: PDWORD, flags: DWORD, name: ptr SockAddr,
                  namelen: cint, lpOverlapped: POVERLAPPED,
                  completionProc: POVERLAPPED_COMPLETION_ROUTINE): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSASendTo", sideEffect.}

  proc wsaGetLastError*(): cint {.
       stdcall, dynlib: "ws2_32", importc: "WSAGetLastError", sideEffect.}

  proc wsaSocket*(af: cint, stype: cint, protocol: cint,
                  lpProtocolInfo: pointer, g: GROUP,
                  dwFlags: DWORD): SocketHandle {.
       stdcall, dynlib: "ws2_32", importc: "WSASocketW", sideEffect.}

  proc socket*(af, typ, protocol: cint): SocketHandle {.
       stdcall, dynlib: "ws2_32", importc: "socket", sideEffect.}

  proc closesocket*(s: SocketHandle): cint {.
       stdcall, dynlib: "ws2_32", importc: "closesocket", sideEffect.}

  proc shutdown*(s: SocketHandle, how: cint): cint {.
       stdcall, dynlib: "ws2_32", importc: "shutdown", sideEffect.}

  proc getsockopt*(s: SocketHandle, level, optname: cint, optval: pointer,
                   optlen: ptr SockLen): cint {.
       stdcall, dynlib: "ws2_32", importc: "getsockopt", sideEffect.}

  proc setsockopt*(s: SocketHandle, level, optname: cint, optval: pointer,
                   optlen: SockLen): cint {.
       stdcall, dynlib: "ws2_32", importc: "setsockopt", sideEffect.}

  proc getsockname*(s: SocketHandle, name: ptr SockAddr,
                    namelen: ptr SockLen): cint {.
       stdcall, dynlib: "ws2_32", importc: "getsockname", sideEffect.}

  proc getpeername*(s: SocketHandle, name: ptr SockAddr,
                    namelen: ptr SockLen): cint {.
       stdcall, dynlib: "ws2_32", importc: "getpeername", sideEffect.}

  proc ioctlsocket*(s: SocketHandle, cmd: clong, argp: ptr clong): cint {.
       stdcall, dynlib: "ws2_32", importc: "ioctlsocket", sideEffect.}

  proc getaddrinfo*(nodename, servname: cstring, hints: ptr AddrInfo,
                    res: var ptr AddrInfo): cint {.
       stdcall, dynlib: "ws2_32", importc: "getaddrinfo", sideEffect.}

  proc freeaddrinfo*(ai: ptr AddrInfo) {.
       stdcall, dynlib: "ws2_32", importc: "freeaddrinfo", sideEffect.}

  proc createIoCompletionPort*(fileHandle: HANDLE,
                               existingCompletionPort: HANDLE,
                               completionKey: ULONG_PTR,
                               numberOfConcurrentThreads: DWORD): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "CreateIoCompletionPort",
       sideEffect.}

  proc getQueuedCompletionStatus*(completionPort: HANDLE,
                                  lpNumberOfBytesTransferred: PDWORD,
                                  lpCompletionKey: PULONG_PTR,
                                  lpOverlapped: ptr POVERLAPPED,
                                  dwMilliseconds: DWORD): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "GetQueuedCompletionStatus",
       sideEffect.}

  proc getOverlappedResult*(hFile: HANDLE, lpOverlapped: POVERLAPPED,
                            lpNumberOfBytesTransferred: var DWORD,
                            bWait: WINBOOL): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "GetOverlappedResult", sideEffect.}

  proc createEvent*(lpEventAttributes: ptr SECURITY_ATTRIBUTES,
                    bManualReset: DWORD, bInitialState: DWORD,
                    lpName: WideCString): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "CreateEventW", sideEffect.}

  proc setEvent*(hEvent: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "SetEvent", sideEffect.}

  proc createNamedPipe*(lpName: WideCString,
                        dwOpenMode, dwPipeMode, nMaxInstances, nOutBufferSize,
                        nInBufferSize, nDefaultTimeOut: DWORD,
                        lpSecurityAttributes: ptr SECURITY_ATTRIBUTES
                       ): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "CreateNamedPipeW", sideEffect.}

  proc createFile*(lpFileName: WideCString, dwDesiredAccess, dwShareMode: DWORD,
                   lpSecurityAttributes: pointer,
                   dwCreationDisposition, dwFlagsAndAttributes: DWORD,
                   hTemplateFile: HANDLE): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "CreateFileW", sideEffect.}

  proc reOpenFile*(hOriginalFile: HANDLE, dwDesiredAccess, dwShareMode,
                   dwFlagsAndAttributes: DWORD): HANDLE {.
       stdcall, dynlib: "kernel32", importc: "ReOpenFile", sideEffect.}

  proc writeFile*(hFile: HANDLE, buffer: pointer, nNumberOfBytesToWrite: DWORD,
                lpNumberOfBytesWritten: ptr DWORD,
                lpOverlapped: pointer): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "WriteFile", sideEffect.}

  proc readFile*(hFile: HANDLE, buffer: pointer, nNumberOfBytesToRead: DWORD,
                 lpNumberOfBytesRead: ptr DWORD,
                 lpOverlapped: pointer): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "ReadFile", sideEffect.}

  proc cancelIo*(hFile: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "CancelIo", sideEffect.}

  proc connectNamedPipe*(hPipe: HANDLE,
                         lpOverlapped: ptr OVERLAPPED): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "ConnectNamedPipe", sideEffect.}

  proc disconnectNamedPipe*(hPipe: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "DisconnectNamedPipe", sideEffect.}

  proc setNamedPipeHandleState*(hPipe: HANDLE, lpMode, lpMaxCollectionCount,
                                lpCollectDataTimeout: ptr DWORD): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "SetNamedPipeHandleState",
       sideEffect.}

  proc resetEvent*(hEvent: HANDLE): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "ResetEvent", sideEffect.}

  proc getAdaptersAddresses*(family: uint32, flags: uint32, reserved: pointer,
                             addresses: ptr IpAdapterAddressesXp,
                             sizeptr: ptr uint32): uint32 {.
       stdcall, dynlib: "iphlpapi", importc: "GetAdaptersAddresses",
       sideEffect.}

  proc wideCharToMultiByte*(codePage: uint32, dwFlags: uint32,
                            lpWideCharStr: WideCString, cchWideChar: cint,
                            lpMultiByteStr: ptr char, cbMultiByte: cint,
                            lpDefaultChar: ptr char,
                            lpUsedDefaultChar: ptr uint32): cint {.
       stdcall, dynlib: "kernel32", importc: "WideCharToMultiByte", sideEffect.}

  proc getBestRouteXp*(dwDestAddr: uint32, dwSourceAddr: uint32,
                       pBestRoute: ptr MibIpForwardRow): uint32 {.
       stdcall, dynlib: "iphlpapi", importc: "GetBestRoute", sideEffect.}

  proc queryPerformanceCounter*(res: var uint64) {.
       stdcall, dynlib: "kernel32", importc: "QueryPerformanceCounter",
       sideEffect.}

  proc queryPerformanceFrequency*(res: var uint64) {.
       stdcall, dynlib: "kernel32", importc: "QueryPerformanceFrequency",
       sideEffect.}

  proc getEnvironmentStringsW*(): WideCString {.
       stdcall, dynlib: "kernel32", importc: "GetEnvironmentStringsW",
       sideEffect.}

  proc freeEnvironmentStringsW*(penv: WideCString): WINBOOL {.
       stdcall, dynlib: "kernel32", importc: "FreeEnvironmentStringsW",
       sideEffect.}

  proc wcschr*(ws: WideCString, wc: Utf16Char): WideCString {.
       stdcall, dynlib: "ntdll", importc: "wcschr", sideEffect.}

  template WSAIORW*(x, y): untyped = (IOC_INOUT or x or y)
  template WSAIOW*(x, y): untyped =
    cast[clong](IOC_IN) or
      ((clong(sizeof(int32)) and clong(IOCPARM_MASK)) shl 16) or
      (x shl 8) or y

  proc `==`*(x, y: SocketHandle): bool {.borrow.}

  const
    WAIT_ABANDONED* = 0x80'u32
    WAIT_OBJECT_0* = 0x00'u32
    WAIT_TIMEOUT* = 0x102'u32
    WAIT_FAILED* = 0xFFFF_FFFF'u32
    TRUE* = WINBOOL(1)
    FALSE* = WINBOOL(0)
    INFINITE* = 0xFFFF_FFFF'u32

    WT_EXECUTEDEFAULT* = 0x00000000'u32
    WT_EXECUTEINIOTHREAD* = 0x00000001'u32
    WT_EXECUTEINUITHREAD* = 0x00000002'u32
    WT_EXECUTEINWAITTHREAD* = 0x00000004'u32
    WT_EXECUTEONLYONCE* = 0x00000008'u32
    WT_EXECUTELONGFUNCTION* = 0x00000010'u32
    WT_EXECUTEINTIMERTHREAD* = 0x00000020'u32
    WT_EXECUTEINPERSISTENTIOTHREAD* = 0x00000040'u32
    WT_EXECUTEINPERSISTENTTHREAD* = 0x00000080'u32
    WT_TRANSFER_IMPERSONATION* = 0x00000100'u32

    GENERIC_READ* = 0x80000000'u32
    GENERIC_WRITE* = 0x40000000'u32
    GENERIC_ALL* = 0x10000000'u32
    FILE_SHARE_READ* = 1'u32
    FILE_SHARE_DELETE* = 4'u32
    FILE_SHARE_WRITE* = 2'u32

    OPEN_EXISTING* = 3'u32

    FILE_READ_DATA* = 0x00000001'u32
    FILE_WRITE_DATA* = 0x00000002'u32

    IPPROTO_TCP* = 6
    PIPE_TYPE_BYTE* = 0x00000000'u32
    PIPE_READMODE_BYTE* = 0x00000000'u32
    PIPE_WAIT* = 0x00000000'u32
    PIPE_TYPE_MESSAGE* = 0x4'u32
    PIPE_READMODE_MESSAGE* = 0x2'u32
    PIPE_UNLIMITED_INSTANCES* = 255'u32
    DEFAULT_PIPE_SIZE* = 65536'u32

    ERROR_SUCCESS* = 0
    ERROR_FILE_NOT_FOUND* = 2
    ERROR_TOO_MANY_OPEN_FILES* = 4
    ERROR_ACCESS_DENIED* = 5
    ERROR_BROKEN_PIPE* = 109
    ERROR_BUFFER_OVERFLOW* = 111
    ERROR_PIPE_BUSY* = 231
    ERROR_NO_DATA* = 232
    ERROR_PIPE_NOT_CONNECTED* = 233
    ERROR_PIPE_CONNECTED* = 535
    ERROR_OPERATION_ABORTED* = 995
    ERROR_IO_PENDING* = 997
    ERROR_CONNECTION_REFUSED* = 1225
    ERROR_CONNECTION_ABORTED* = 1236

    WSAEMFILE* = 10024
    WSAENETDOWN* = 10050
    WSAENETRESET* = 10052
    WSAECONNABORTED* = 10053
    WSAECONNRESET* = 10054
    WSAENOBUFS* = 10055
    WSAETIMEDOUT* = 10060
    WSAEADDRINUSE* = 10048
    WSAEDISCON* = 10101
    WSANOTINITIALISED* = 10093
    WSAENOTSOCK* = 10038
    WSAEINPROGRESS* = 10036
    WSAEINTR* = 10004
    WSAEWOULDBLOCK* = 10035
    ERROR_NETNAME_DELETED* = 64
    STATUS_PENDING* = 0x103

    AF_UNSPEC* = 0
    AF_UNIX* = 1
    AF_INET* = 2
    AF_APPLETALK* = 16
    AF_NETBIOS* = 17
    AF_INET6* = 23
    AF_IRDA* = 26
    AF_BTH* = 32
    AF_MAX* = 33

    IOCPARM_MASK* = 0x7f'u32
    IOC_OUT* = 0x40000000'u32
    IOC_IN*  = 0x80000000'u32
    IOC_WS2* = 0x08000000'u32
    IOC_INOUT* = IOC_IN or IOC_OUT

    INVALID_SOCKET* = SocketHandle(-1)
    INVALID_HANDLE_VALUE* = HANDLE(uint(not(0'u)))

    SIO_GET_EXTENSION_FUNCTION_POINTER* = WSAIORW(IOC_WS2, 6).DWORD
    SO_UPDATE_ACCEPT_CONTEXT* = 0x700B
    SO_CONNECT_TIME* = 0x700C
    SO_UPDATE_CONNECT_CONTEXT* = 0x7010

    FILE_FLAG_FIRST_PIPE_INSTANCE* = 0x00080000'u32
    FILE_FLAG_OPEN_NO_RECALL* = 0x00100000'u32
    FILE_FLAG_OPEN_REPARSE_POINT* = 0x00200000'u32
    FILE_FLAG_POSIX_SEMANTICS* = 0x01000000'u32
    FILE_FLAG_BACKUP_SEMANTICS* = 0x02000000'u32
    FILE_FLAG_DELETE_ON_CLOSE* = 0x04000000'u32
    FILE_FLAG_SEQUENTIAL_SCAN* = 0x08000000'u32
    FILE_FLAG_RANDOM_ACCESS* = 0x10000000'u32
    FILE_FLAG_NO_BUFFERING* = 0x20000000'u32
    FILE_FLAG_OVERLAPPED* = 0x40000000'u32
    FILE_FLAG_WRITE_THROUGH* = 0x80000000'u32

    PIPE_ACCESS_DUPLEX* = 0x00000003'u32
    PIPE_ACCESS_INBOUND* = 1'u32
    PIPE_ACCESS_OUTBOUND* = 2'u32
    PIPE_NOWAIT* = 0x00000001'u32

    IOC_VENDOR* = 0x18000000'u32
    SIO_UDP_CONNRESET* = DWORD(IOC_IN) or IOC_VENDOR or 12'u32
    IPPROTO_IP* = 0
    IP_TTL* = 4
    SOMAXCONN* = 2147483647
    SOL_SOCKET* = 0xFFFF

    SO_DEBUG* = 0x0001
    SO_ACCEPTCONN* = 0x0002
    SO_REUSEADDR* = 0x0004
    SO_REUSEPORT* = SO_REUSEADDR
    SO_KEEPALIVE* = 0x0008
    SO_DONTROUTE* = 0x0010
    SO_BROADCAST* = 0x0020
    SO_USELOOPBACK* = 0x0040
    SO_LINGER* = 0x0080
    SO_OOBINLINE* = 0x0100
    SO_DONTLINGER* = not(SO_LINGER)
    SO_EXCLUSIVEADDRUSE* = not(SO_REUSEADDR)
    SO_SNDBUF* = 0x1001
    SO_RCVBUF* = 0x1002
    SO_SNDLOWAT* = 0x1003
    SO_RCVLOWAT* = 0x1004
    SO_SNDTIMEO* = 0x1005
    SO_RCVTIMEO* = 0x1006
    SO_ERROR* = 0x1007
    SO_TYPE* = 0x1008
    TCP_NODELAY* = 1

    STD_INPUT_HANDLE* = 0xFFFF_FFF6'u32
    STD_OUTPUT_HANDLE* = 0xFFFF_FFF5'u32
    STD_ERROR_HANDLE* = 0xFFFF_FFF4'u32

    STARTF_USESHOWWINDOW* = 0x00000001'u32
    STARTF_USESIZE* = 0x00000002'u32
    STARTF_USEPOSITION* = 0x00000004'u32
    STARTF_USECOUNTCHARS* = 0x00000008'u32
    STARTF_USEFILLATTRIBUTE* = 0x00000010'u32
    STARTF_RUNFULLSCREEN* = 0x00000020'u32
    STARTF_FORCEONFEEDBACK* = 0x00000040'u32
    STARTF_FORCEOFFFEEDBACK* = 0x00000080'u32
    STARTF_USESTDHANDLES* = 0x00000100'u32
    STARTF_USEHOTKEY* = 0x00000200'u32
    STARTF_TITLEISLINKNAME* = 0x00000800'u32
    STARTF_TITLEISAPPID* = 0x00001000'u32
    STARTF_PREVENTPINNING* = 0x00002000'u32
    STARTF_UNTRUSTEDSOURCE* = 0x00008000'u32

    DEBUG_PROCESS* = 0x1'u32
    DEBUG_ONLY_THIS_PROCESS* = 0x2'u32
    CREATE_SUSPENDED* = 0x4'u32
    DETACHED_PROCESS* = 0x8'u32
    CREATE_NEW_CONSOLE* = 0x10'u32
    NORMAL_PRIORITY_CLASS* = 0x20'u32
    IDLE_PRIORITY_CLASS* = 0x40'u32
    HIGH_PRIORITY_CLASS* = 0x80'u32
    REALTIME_PRIORITY_CLASS* = 0x100'u32
    CREATE_NEW_PROCESS_GROUP* = 0x200'u32
    CREATE_UNICODE_ENVIRONMENT* = 0x400'u32
    CREATE_SEPARATE_WOW_VDM* = 0x800'u32
    CREATE_SHARED_WOW_VDM* = 0x1000'u32
    CREATE_FORCEDOS* = 0x2000'u32
    BELOW_NORMAL_PRIORITY_CLASS* = 0x4000'u32
    ABOVE_NORMAL_PRIORITY_CLASS* = 0x8000'u32
    INHERIT_PARENT_AFFINITY* = 0x10000'u32
    INHERIT_CALLER_PRIORITY* = 0x20000'u32
    CREATE_PROTECTED_PROCESS* = 0x40000'u32
    EXTENDED_STARTUPINFO_PRESENT* = 0x80000'u32
    PROCESS_MODE_BACKGROUND_BEGIN* = 0x100000'u32
    PROCESS_MODE_BACKGROUND_END* = 0x200000'u32
    CREATE_SECURE_PROCESS* = 0x400000'u32
    CREATE_BREAKAWAY_FROM_JOB* = 0x1000000'u32
    CREATE_PRESERVE_CODE_AUTHZ_LEVEL* = 0x2000000'u32
    CREATE_DEFAULT_ERROR_MODE* = 0x4000000'u32
    CREATE_NO_WINDOW* = 0x8000000'u32
    PROFILE_USER* = 0x10000000'u32
    PROFILE_KERNEL* = 0x20000000'u32
    PROFILE_SERVER* = 0x40000000'u32
    CREATE_IGNORE_SYSTEM_DEFAULT* = 0x80000000'u32

    STILL_ACTIVE* = 0x00000103'u32

    WSAID_CONNECTEX* =
      GUID(D1: 0x25a207b9'u32, D2: 0xddf3'u16, D3: 0x4660'u16,
           D4: [0x8e'u8, 0xe9'u8, 0x76'u8, 0xe5'u8,
                0x8c'u8, 0x74'u8, 0x06'u8, 0x3e'u8])
    WSAID_ACCEPTEX* =
      GUID(D1: 0xb5367df1'u32, D2: 0xcbac'u16, D3: 0x11cf'u16,
           D4: [0x95'u8, 0xca'u8, 0x00'u8, 0x80'u8,
                0x5f'u8, 0x48'u8, 0xa1'u8, 0x92'u8])
    WSAID_GETACCEPTEXSOCKADDRS* =
      GUID(D1: 0xb5367df2'u32, D2: 0xcbac'u16, D3: 0x11cf'u16,
           D4: [0x95'u8, 0xca'u8, 0x00'u8, 0x80'u8,
                0x5f'u8, 0x48'u8, 0xa1'u8, 0x92'u8])
    WSAID_TRANSMITFILE* =
      GUID(D1: 0xb5367df0'u32, D2: 0xcbac'u16, D3: 0x11cf'u16,
           D4: [0x95'u8, 0xca'u8, 0x00'u8, 0x80'u8,
                0x5f'u8, 0x48'u8, 0xa1'u8, 0x92'u8])

    GAA_FLAG_INCLUDE_PREFIX* = 0x0010'u32

    DELETE* = 0x00010000'u32
    READ_CONTROL* = 0x00020000'u32
    WRITE_DAC* = 0x00040000'u32
    WRITE_OWNER* = 0x00080000'u32
    SYNCHRONIZE* = 0x00100000'u32

    CP_UTF8* = 65001'u32

    WSA_FLAG_OVERLAPPED* = 0x01'u32
    WSA_FLAG_NO_HANDLE_INHERIT* = 0x80'u32

    FIONBIO* = WSAIOW(102, 126)

    HANDLE_FLAG_INHERIT* = 1'u32

  proc `==`*(x, y: HANDLE): bool {.borrow.}

  proc getSecurityAttributes*(inheritHandle = false): SECURITY_ATTRIBUTES =
    SECURITY_ATTRIBUTES(
      nLength: DWORD(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil,
      bInheritHandle: if inheritHandle: TRUE else: FALSE
    )

elif defined(macos) or defined(macosx):
  import std/[posix, os]
  export posix, os

  type
    MachTimebaseInfo* {.importc: "struct mach_timebase_info",
                        header: "<mach/mach_time.h>", pure, final.} = object
      numer*: uint32
      denom*: uint32

  proc posix_gettimeofday*(tp: var Timeval, unused: pointer = nil) {.
       importc: "gettimeofday", header: "<sys/time.h>".}

  proc mach_timebase_info*(info: var MachTimebaseInfo) {.
       importc, header: "<mach/mach_time.h>".}

  proc mach_absolute_time*(): uint64 {.
       importc, header: "<mach/mach_time.h>".}

  var IP_MULTICAST_TTL* {.importc: "IP_MULTICAST_TTL",
                          header: "<netinet/in.h>".}: cint

elif defined(linux):
  import std/[posix, os]
  export posix, os

  when not defined(android) and defined(amd64):
    const IP_MULTICAST_TTL*: cint = 33
  else:
    var IP_MULTICAST_TTL* {.importc: "IP_MULTICAST_TTL",
                            header: "<netinet/in.h>".}: cint
else:
  import std/[posix, os]
  export posix, os

  var IP_MULTICAST_TTL* {.importc: "IP_MULTICAST_TTL",
                          header: "<netinet/in.h>".}: cint

when not(defined(windows)):
  const
    TCP_NODELAY* = 1
    IPPROTO_TCP* = 6

when defined(linux) or defined(freebsd) or defined(openbsd) or
     defined(netbsd) or defined(dragonfly):

  proc pipe2*(a: array[0..1, cint], flags: cint): cint {.
       importc, header: "<unistd.h>".}

when defined(linux):
  const
    SOCK_NONBLOCK* = 0x800
    SOCK_CLOEXEC* = 0x80000
elif defined(freebsd) or defined(netbsd) or defined(dragonfly):
  const
    SOCK_NONBLOCK* = 0x20000000
    SOCK_CLOEXEC* = 0x10000000
elif defined(openbsd):
  const
    SOCK_CLOEXEC* = 0x8000
    SOCK_NONBLOCK* = 0x4000

when defined(linux):
  const O_CLOEXEC* = 0x02000000
elif defined(freebsd):
  const O_CLOEXEC* = 0x00100000
elif defined(openbsd):
  const O_CLOEXEC* = 0x10000
elif defined(netbsd):
  const O_CLOEXEC* = 0x00400000
elif defined(dragonfly):
  const O_CLOEXEC* = 0x00020000

when defined(linux) or defined(macos) or defined(macosx) or defined(freebsd) or
     defined(openbsd) or defined(netbsd) or defined(dragonfly):
  const
    POSIX_SPAWN_RESETIDS* = 0x01
    POSIX_SPAWN_SETPGROUP* = 0x02
    POSIX_SPAWN_SETSCHEDPARAM* = 0x04
    POSIX_SPAWN_SETSCHEDULER* = 0x08
    POSIX_SPAWN_SETSIGDEF* = 0x10
    POSIX_SPAWN_SETSIGMASK* = 0x20

  type
    SchedParam* {.importc: "struct sched_param", header: "<sched.h>",
                  final, pure.} = object ## struct sched_param
      sched_priority*: cint
      sched_ss_low_priority*: cint     ## Low scheduling priority for
                                       ## sporadic server.
      sched_ss_repl_period*: Timespec  ## Replenishment period for
                                       ## sporadic server.
      sched_ss_init_budget*: Timespec  ## Initial budget for sporadic server.
      sched_ss_max_repl*: cint         ## Maximum pending replenishments for
                                       ## sporadic server.

    PosixSpawnAttr* {.importc: "posix_spawnattr_t",
                      header: "<spawn.h>", final, pure.} = object
      flags*: cshort
      pgrp*: Pid
      sd*: Sigset
      ss*: Sigset
      sp*: SchedParam
      policy*: cint
      pad*: array[16, cint]

    PosixSpawnFileActions* {.importc: "posix_spawn_file_actions_t",
                             header: "<spawn.h>", final, pure.} = object
      allocated*: cint
      used*: cint
      actions*: pointer
      pad*: array[16, cint]

  proc posixSpawn*(a1: var Pid, a2: cstring, a3: var PosixSpawnFileActions,
                   a4: var PosixSpawnAttr, a5, a6: cstringArray): cint {.
       importc: "posix_spawn", header: "<spawn.h>", sideEffect.}
  proc posixSpawnp*(a1: var Pid, a2: cstring, a3: var PosixSpawnFileActions,
                    a4: var PosixSpawnAttr, a5, a6: cstringArray): cint {.
       importc: "posix_spawnp", header: "<spawn.h>", sideEffect.}

  proc posixSpawnFileActionsInit*(a1: var PosixSpawnFileActions): cint {.
       importc: "posix_spawn_file_actions_init", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnFileActionsDestroy*(a1: var PosixSpawnFileActions): cint {.
       importc: "posix_spawn_file_actions_destroy", header: "<spawn.h>",
       sideEffect.}

  proc posixSpawnFileActionsAddClose*(a1: var PosixSpawnFileActions,
                                      a2: cint): cint {.
       importc: "posix_spawn_file_actions_addclose", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnFileActionsAddDup2*(a1: var PosixSpawnFileActions,
                                     a2, a3: cint): cint {.
       importc: "posix_spawn_file_actions_adddup2", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnFileActionsAddOpen*(a1: var PosixSpawnFileActions,
                                     a2: cint, a3: cstring, a4: cint,
                                     a5: Mode): cint {.
       importc: "posix_spawn_file_actions_addopen", header: "<spawn.h>",
       sideEffect.}

  proc posixSpawnAttrInit*(a1: var PosixSpawnAttr): cint {.
       importc: "posix_spawnattr_init", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrDestroy*(a1: var PosixSpawnAttr): cint {.
       importc: "posix_spawnattr_destroy", header: "<spawn.h>",
       sideEffect.}

  proc posixSpawnAttrGetSigDefault*(a1: var PosixSpawnAttr,
                                    a2: var Sigset): cint {.
       importc: "posix_spawnattr_getsigdefault", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrSetSigDefault*(a1: var PosixSpawnAttr,
                                    a2: var Sigset): cint {.
       importc: "posix_spawnattr_setsigdefault", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrGetFlags*(a1: var PosixSpawnAttr,
                               a2: var cshort): cint {.
       importc: "posix_spawnattr_getflags", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrSetFlags*(a1: var PosixSpawnAttr, a2: cint): cint {.
       importc: "posix_spawnattr_setflags", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrGetPgroup*(a1: var PosixSpawnAttr,
                                a2: var Pid): cint {.
       importc: "posix_spawnattr_getpgroup", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrSetPgroup*(a1: var PosixSpawnAttr, a2: Pid): cint {.
       importc: "posix_spawnattr_setpgroup", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrGetSchedParam*(a1: var PosixSpawnAttr,
                                    a2: var SchedParam): cint {.
       importc: "posix_spawnattr_getschedparam", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrSetSchedParam*(a1: var PosixSpawnAttr,
                                    a2: var SchedParam): cint {.
       importc: "posix_spawnattr_setschedparam", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrGetSchedPolicy*(a1: var PosixSpawnAttr,
                                     a2: var cint): cint {.
       importc: "posix_spawnattr_getschedpolicy", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrSetSchedPolicy*(a1: var PosixSpawnAttr,
                                     a2: cint): cint {.
       importc: "posix_spawnattr_setschedpolicy", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrGetSigMask*(a1: var PosixSpawnAttr,
                                 a2: var Sigset): cint {.
       importc: "posix_spawnattr_getsigmask", header: "<spawn.h>",
       sideEffect.}
  proc posixSpawnAttrSetSigMask*(a1: var PosixSpawnAttr,
                                 a2: var Sigset): cint {.
       importc: "posix_spawnattr_setsigmask", header: "<spawn.h>",
       sideEffect.}

when defined(posix):
  when defined(linux):
    const WNOHANG* = 1
    template WSTATUS(s: cint): cint =
      s and 0x7F
    template WAITEXITSTATUS*(s: cint): cint =
      (s and 0xFF00) shr 8
    template WAITTERMSIG*(s: cint): cint =
      WSTATUS(s)
    template WAITSTOPSIG*(s: cint): cint =
      WAITEXITSTATUS(s)
    template WAITIFEXITED*(s: cint): bool =
      WSTATUS(s) == 0
    template WAITIFSIGNALED*(s: cint): bool =
      (cast[int8](WSTATUS(s) + 1) shr 1) > 0
    template WAITIFSTOPPED*(s: cint): bool =
      (s and 0xFF) == 0x7F
    template WAITIFCONTINUED*(s: cint): bool =
      s == 0xFFFF
  elif defined(openbsd):
    const WNOHANG* = 1
    template WSTATUS(s: cint): cint =
      s and 0x7F
    template WAITEXITSTATUS*(s: cint): cint =
      (s shr 8) and 0xFF
    template WAITTERMSIG*(s: cint): cint =
      WSTATUS(s)
    template WAITSTOPSIG*(s: cint): cint =
      WAITEXITSTATUS(s)
    template WAITIFEXITED*(s: cint): bool =
      WSTATUS(s) == 0
    template WAITIFSIGNALED*(s: cint): bool =
      (WAITTERMSIG(s) != 0x7F) and (WSTATUS(s) != 0)
    template WAITIFSTOPPED*(s: cint): bool =
      WSTATUS(s) == 0x7F
    template WAITIFCONTINUED*(s: cint): bool =
      s == 0xFFFF
  elif defined(dragonfly):
    const WNOHANG* = 1
    template WSTATUS(s: cint): cint =
      s and 0x7F
    template WAITEXITSTATUS*(s: cint): cint =
      (s shr 8)
    template WAITTERMSIG*(s: cint): cint =
      WSTATUS(s)
    template WAITSTOPSIG*(s: cint): cint =
      WAITEXITSTATUS(s)
    template WAITIFEXITED*(s: cint): bool =
      WSTATUS(s) == 0
    template WAITIFSIGNALED*(s: cint): bool =
      (WAITTERMSIG(s) != 0x7F) and (WSTATUS(s) != 0)
    template WAITIFSTOPPED*(s: cint): bool =
      WSTATUS(s) == 0x7F
    template WAITIFCONTINUED*(s: cint): bool =
      s == 19
  elif defined(netbsd):
    const WNOHANG* = 1
    template WSTATUS(s: cint): cint =
      s and 0x7F
    template WAITEXITSTATUS*(s: cint): cint =
      (s shr 8) and 0xFF
    template WAITTERMSIG*(s: cint): cint =
      WSTATUS(s)
    template WAITSTOPSIG*(s: cint): cint =
      WAITEXITSTATUS(s)
    template WAITIFEXITED*(s: cint): bool =
      WSTATUS(s) == 0
    template WAITIFSIGNALED*(s: cint): bool =
      not(WAITIFSTOPPED(s)) and not(WAITIFCONTINUED(s)) and not(WAITIFEXITED(s))
    template WAITIFSTOPPED*(s: cint): bool =
      (WSTATUS(s) == 0x7F) and not(WAITIFCONTINUED(s))
    template WAITIFCONTINUED*(s: cint): bool =
      s == 0xFFFF
  elif defined(freebsd):
    const WNOHANG* = 1
    template WSTATUS(s: cint): cint =
      s and 0x7F
    template WAITEXITSTATUS*(s: cint): cint =
      s shr 8
    template WAITTERMSIG*(s: cint): cint =
      WSTATUS(s)
    template WAITSTOPSIG*(s: cint): cint =
      s shr 8
    template WAITIFEXITED*(s: cint): bool =
      WSTATUS(s) == 0
    template WAITIFSIGNALED*(s: cint): bool =
      let wstatus = WSTATUS(s)
      (wstatus != 0x7F) and (wstatus != 0) and (s != 0x13)
    template WAITIFSTOPPED*(s: cint): bool =
      WSTATUS(s) == 0x7F
    template WAITIFCONTINUED*(s: cint): bool =
      x == 0x13
  elif defined(macos) or defined(macosx):
    const WNOHANG* = 1
    template WSTATUS(s: cint): cint =
      s and 0x7F
    template WAITEXITSTATUS*(s: cint): cint =
      (s shr 8) and 0xFF
    template WAITTERMSIG*(s: cint): cint =
      WSTATUS(s)
    template WAITSTOPSIG*(s: cint): cint =
      s shr 8
    template WAITIFEXITED*(s: cint): bool =
      WSTATUS(s) == 0
    template WAITIFSIGNALED*(s: cint): bool =
      let wstatus = WSTATUS(s)
      (wstatus != 0x7F) and (wstatus != 0)
    template WAITIFSTOPPED*(s: cint): bool =
      (WSTATUS(s) == 0x7F) and (WAITSTOPSIG(s) != 0x13)
    template WAITIFCONTINUED*(s: cint): bool =
      (WSTATUS(s) == 0x7F) and (WAITSTOPSIG(s) == 0x13)
  else:
    proc WAITEXITSTATUS*(s: cint): cint {.
         importc: "WEXITSTATUS", header: "<sys/wait.h>".}
      ## Exit code, iff WIFEXITED(s)
    proc WAITTERMSIG*(s: cint): cint {.
         importc: "WTERMSIG", header: "<sys/wait.h>".}
      ## Termination signal, iff WIFSIGNALED(s)
    proc WAITSTOPSIG*(s: cint): cint {.
         importc: "WSTOPSIG", header: "<sys/wait.h>".}
      ## Stop signal, iff WIFSTOPPED(s)
    proc WAITIFEXITED*(s: cint): bool {.
         importc: "WIFEXITED", header: "<sys/wait.h>".}
      ## True if child exited normally.
    proc WAITIFSIGNALED*(s: cint): bool {.
         importc: "WIFSIGNALED", header: "<sys/wait.h>".}
      ## True if child exited due to uncaught signal.
    proc WAITIFSTOPPED*(s: cint): bool {.
         importc: "WIFSTOPPED", header: "<sys/wait.h>".}
      ## True if child is currently stopped.
    proc WAITIFCONTINUED*(s: cint): bool {.
         importc: "WIFCONTINUED", header: "<sys/wait.h>".}
      ## True if child has been continued.

when defined(posix):
  const
    INVALID_SOCKET* = SocketHandle(-1)
    INVALID_HANDLE_VALUE* = cint(-1)

proc `==`*(x: OSErrorCode, y: int): bool =
  x == OSErrorCode(y)
proc `==`*(x: SocketHandle, y: int): bool =
  x == SocketHandle(y)

