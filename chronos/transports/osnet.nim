#
#                  Chronos OS utilities
#              (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This module implements cross-platform network interfaces list.
## Currently supported OSes are Windows, Linux, MacOS, BSD(not tested).

{.push raises: [Defect].}

import std/algorithm
from std/strutils import toHex
import ./ipnet
export ipnet

const
  MaxAdapterAddressLength* = 8

type
  InterfaceType* = enum
    IfError = 0, # This is workaround element for ProveInit warnings.
    IfOther = 1,
    IfRegular1822 = 2,
    IfHdh1822 = 3,
    IfDdnX25 = 4,
    IfRfc877X25 = 5,
    IfEthernetCsmacd = 6,
    IfIso88023Csmacd = 7,
    IfIso88024TokenBus = 8,
    IfIso88025TokenRing = 9,
    IfIso88026MAN = 10,
    IfStarlan = 11,
    IfProteon10Mbit = 12,
    IfProteon80Mbit = 13,
    IfHyperChannel = 14,
    IfFddi = 15,
    IfLapB = 16,
    IfSdlc = 17,
    IfDs1 = 18,
    IfE1 = 19,
    IfBasicIsdn = 20,
    IfPrimaryIsdn = 21,
    IfPropPoint2PointSerial = 22,
    IfPpp = 23,
    IfSoftwareLoopback = 24,
    IfEon = 25,
    IfEthernet3Mbit = 26,
    IfNsip = 27,
    IfSlip = 28,
    IfUltra = 29,
    IfDs3 = 30,
    IfSip = 31,
    IfFrameRelay = 32,
    IfRs232 = 33,
    IfPara = 34,
    IfArcNet = 35,
    IfArcNetPlus = 36,
    IfAtm = 37,
    IfMioX25 = 38,
    IfSonet = 39,
    IfX25Ple = 40,
    IfIso88022Llc = 41,
    IfLocalTalk = 42,
    IfSmdsDxi = 43,
    IfFrameRelayService = 44,
    IfV35 = 45,
    IfHssi = 46,
    IfHippi = 47,
    IfModem = 48,
    IfAal5 = 49,
    IfSonetPath = 50,
    IfSonetVt = 51,
    IfSmdsIcip = 52,
    IfPropVirtual = 53,
    IfPropMultiplexor = 54,
    IfIeee80212 = 55,
    IfFibreChannel = 56,
    IfHippiInterface = 57,
    IfFrameRelayInterconnect = 58,
    IfAflane8023 = 59,
    IfAflane8025 = 60,
    IfCctemul = 61,
    IfFastEther = 62,
    IfIsdn = 63,
    IfV11 = 64,
    IfV36 = 65,
    IfG70364K = 66,
    IfG7032MB = 67,
    IfQllc = 68,
    IfFastEtherFx = 69,
    IfChannel = 70,
    IfIeee80211 = 71,
    IfIbm370Parchan = 72,
    IfEscon = 73,
    IfDlsw = 74,
    IfIsdnS = 75,
    IfIsdnU = 76,
    IfLapD = 77,
    IfIpSwitch = 78,
    IfRsrb = 79,
    IfAtmLogical = 80,
    IfDs0 = 81,
    IfDs0Bundle = 82,
    IfBsc = 83,
    IfAsync = 84,
    IfCnr = 85,
    IfIso88025rDtr = 86,
    IfEplrs = 87,
    IfArap = 88,
    IfPropCnls = 89,
    IfHostPad = 90,
    IfTermPad = 91,
    IfFrameRelayMpi = 92,
    IfX213 = 93,
    IfAdsl = 94,
    IfRadsl = 95,
    IfSdsl = 96,
    IfVdsl = 97,
    IfIso88025Crfprint = 98,
    IfMyrInet = 99,
    IfVoiceEm = 100,
    IfVoiceFxo = 101,
    IfVoiceFxs = 102,
    IfVoiceEncap = 103,
    IfVoiceOverip = 104,
    IfAtmDxi = 105,
    IfAtmFuni = 106,
    IfAtmIma = 107,
    IfPppMultilinkBundle = 108,
    IfIpoverCdlc = 109,
    IfIpoverClaw = 110,
    IfStackToStack = 111,
    IfVirtualIpAddress = 112,
    IfMpc = 113,
    IfIpoverAtm = 114,
    IfIso88025Fiber = 115,
    IfTdlc = 116,
    IfGigabitEthernet = 117,
    IfHdlc = 118,
    IfLapF = 119,
    IfV37 = 120,
    IfX25Mlp = 121,
    IfX25HuntGroup = 122,
    IfTransPhdlc = 123,
    IfInterleave = 124,
    IfFast = 125,
    IfIp = 126,
    IfDocScableMaclayer = 127,
    IfDocScableDownstream = 128,
    IfDocScableUpstream = 129,
    IfA12MppSwitch = 130,
    IfTunnel = 131,
    IfCoffee = 132,
    IfCes = 133,
    IfAtmSubInterface = 134,
    IfL2Vlan = 135,
    IfL3IpVlan = 136,
    IfL3IpxVlan = 137,
    IfDigitalPowerline = 138,
    IfMediaMailOverIp = 139,
    IfDtm = 140,
    IfDcn = 141,
    IfIpForward = 142,
    IfMsdsl = 143,
    IfIeee1394 = 144,
    IfIfGsn = 145,
    IfDvbrccMaclayer = 146,
    IfDvbrccDownstream = 147,
    IfDvbrccUpstream = 148,
    IfAtmVirtual = 149,
    IfMplsTunnel = 150,
    IfSrp = 151,
    IfVoiceOverAtm = 152,
    IfVoiceOverFrameRelay = 153,
    IfIdsl = 154,
    IfCompositeLink = 155,
    IfSs7SigLink = 156,
    IfPropWirelessP2p = 157,
    IfFrForward = 158,
    IfRfc1483 = 159,
    IfUsb = 160,
    IfIeee8023AdLag = 161,
    IfBgpPolicyAccounting = 162,
    IfFrf16MfrBundle = 163,
    IfH323Gatekeeper = 164,
    IfH323Proxy = 165,
    IfMpls = 166,
    IfMfSigLink = 167,
    IfHdsl2 = 168,
    IfShdsl = 169,
    IfDs1Fdl = 170,
    IfPos = 171,
    IfDvbAsiIn = 172,
    IfDvbAsiOut = 173,
    IfPlc = 174,
    IfNfas = 175,
    IfTr008 = 176,
    IfGr303Rdt = 177,
    IfGr303Idt = 178,
    IfIsup = 179,
    IfPropDocsWirelessMaclayer = 180,
    IfPropDocsWirelessDownstream = 181,
    IfPropDocsWirelessUpstream = 182,
    IfHiperLan2 = 183,
    IfPropBwaP2mp = 184,
    IfSonetOverheadChannel = 185,
    IfDigitalWrapperOverheadChannel = 186,
    IfAal2 = 187,
    IfRadioMac = 188,
    IfAtmRadio = 189,
    IfImt = 190,
    IfMvl = 191,
    IfReachDsl = 192,
    IfFrDlciEndpt = 193,
    IfAtmVciEndpt = 194,
    IfOpticalChannel = 195,
    IfOpticalTransport = 196,
    IfIeee80216Wman = 237,
    IfWwanPp = 243,
    IfWwanPp2 = 244,
    IfIeee802154 = 259,
    IfXboxWireless = 281

  InterfaceState* = enum
    StatusError = 0,  # This is workaround element for ProoveInit warnings.
    StatusUp,
    StatusDown,
    StatusTesting,
    StatusUnknown,
    StatusDormant,
    StatusNotPresent,
    StatusLowerLayerDown

  InterfaceAddress* = object
    host*: TransportAddress
    net*: IpNet

  NetworkInterface* = object
    ifIndex*: int
    ifType*: InterfaceType
    name*: string
    desc*: string
    mtu*: int
    flags*: uint64
    state*: InterfaceState
    mac*: array[MaxAdapterAddressLength, byte]
    maclen*: int
    addresses*: seq[InterfaceAddress]

  Route* = object
    ifIndex*: int
    dest*: TransportAddress
    source*: TransportAddress
    gateway*: TransportAddress
    metric*: int

proc broadcast*(ifa: InterfaceAddress): TransportAddress =
  ## Return broadcast address for ``ifa``.
  ifa.net.broadcast()

proc network*(ifa: InterfaceAddress): TransportAddress =
  ## Return network address for ``ifa``.
  ifa.net.network()

proc netmask*(ifa: InterfaceAddress): TransportAddress =
  ## Return network mask for ``ifa``.
  ifa.net.subnetMask()

proc init*(ift: typedesc[InterfaceAddress], address: TransportAddress,
           prefix: int): InterfaceAddress =
  ## Initialize ``InterfaceAddress`` using ``address`` and prefix length
  ## ``prefix``.
  InterfaceAddress(host: address, net: IpNet.init(address, prefix))

proc `$`*(ifa: InterfaceAddress): string =
  ## Return string representation of ``ifa``.
  if ifa.host.family == AddressFamily.IPv4:
    $ifa.net
  elif ifa.host.family == AddressFamily.IPv6:
    $ifa.net
  else:
    "Unknown"

proc `$`*(iface: NetworkInterface): string =
  ## Return string representation of network interface ``iface``.
  var res = $iface.ifIndex
  if len(res) == 1:
    res.add(".  ")
  else:
    res.add(". ")
  res.add(iface.name)
  when defined(windows):
    res.add(" [")
    res.add(iface.desc)
    res.add("]")
  res.add(": flags = ")
  res.add($iface.flags)
  res.add(" mtu ")
  res.add($iface.mtu)
  res.add(" state ")
  res.add($iface.state)
  res.add("\n    ")
  res.add($iface.ifType)
  res.add(" ")
  if iface.maclen > 0:
    for i in 0..<iface.maclen:
      res.add(toHex(iface.mac[i]))
      if i < iface.maclen - 1:
        res.add(":")
  for item in iface.addresses:
    res.add("\n    ")
    if item.host.family == AddressFamily.IPv4:
      res.add("inet ")
    elif item.host.family == AddressFamily.IPv6:
      res.add("inet6 ")
    res.add($item)
    res.add(" netmask ")
    res.add(try: $(item.netmask().address()) except ValueError as exc: exc.msg)
    res.add(" brd ")
    res.add(
      try: $(item.broadcast().address()) except ValueError as exc: exc.msg)
  res

proc `$`*(route: Route): string =
  var res = try: $route.dest.address() except ValueError as exc: exc.msg
  res.add(" via ")
  if route.gateway.family != AddressFamily.None:
    res.add("gateway ")
    res.add(try: $route.gateway.address() except ValueError as exc: exc.msg)
  else:
    res.add("link")
  res.add(" src ")
  res.add(try: $route.source.address() except ValueError as exc: exc.msg)
  res

proc cmp*(a, b: NetworkInterface): int =
  cmp(a.ifIndex, b.ifIndex)

when defined(linux):
  import posix

  const
    AF_NETLINK = cint(16)
    AF_PACKET = cint(17)
    NETLINK_ROUTE = cint(0)
    NLMSG_ALIGNTO = 4'u
    RTA_ALIGNTO = 4'u
    # RTA_UNSPEC = 0'u16
    RTA_DST = 1'u16
    # RTA_SRC = 2'u16
    # RTA_IIF = 3'u16
    RTA_OIF = 4'u16
    RTA_GATEWAY = 5'u16
    # RTA_PRIORITY = 6'u16
    RTA_PREFSRC = 7'u16
    # RTA_METRICS = 8'u16

    RTM_F_LOOKUP_TABLE = 0x1000

    RTM_GETLINK = 18
    RTM_GETADDR = 22
    RTM_GETROUTE = 26
    NLM_F_REQUEST = 1
    NLM_F_ROOT = 0x100
    NLM_F_MATCH = 0x200
    NLM_F_DUMP = NLM_F_ROOT or NLM_F_MATCH
    IFLIST_REPLY_BUFFER = 8192
    InvalidSocketHandle = SocketHandle(-1)
    NLMSG_DONE = 0x03
    # NLMSG_MIN_TYPE = 0x10
    NLMSG_ERROR = 0x02
    # MSG_TRUNC = 0x20

    IFLA_ADDRESS = 1
    IFLA_IFNAME = 3
    IFLA_MTU = 4
    IFLA_OPERSTATE = 16

    IFA_ADDRESS = 1
    IFA_LOCAL = 2
    # IFA_BROADCAST = 4

    # ARPHRD_NETROM = 0
    ARPHRD_ETHER = 1
    ARPHRD_EETHER = 2
    # ARPHRD_AX25 = 3
    # ARPHRD_PRONET = 4
    # ARPHRD_CHAOS = 5
    # ARPHRD_IEEE802 = 6
    ARPHRD_ARCNET = 7
    # ARPHRD_APPLETLK = 8
    # ARPHRD_DLCI = 15
    ARPHRD_ATM = 19
    # ARPHRD_METRICOM = 23
    ARPHRD_IEEE1394 = 24
    # ARPHRD_EUI64 = 27
    # ARPHRD_INFINIBAND = 32
    ARPHRD_SLIP = 256
    ARPHRD_CSLIP = 257
    ARPHRD_SLIP6 = 258
    ARPHRD_CSLIP6 = 259
    # ARPHRD_RSRVD = 260
    # ARPHRD_ADAPT = 264
    # ARPHRD_ROSE = 270
    # ARPHRD_X25 = 271
    # ARPHRD_HWX25 = 272
    # ARPHRD_CAN = 280
    ARPHRD_PPP = 512
    ARPHRD_CISCO = 513
    ARPHRD_HDLC = ARPHRD_CISCO
    ARPHRD_LAPB = 516
    # ARPHRD_DDCMP = 517
    # ARPHRD_RAWHDLC = 518
    # ARPHRD_TUNNEL = 768
    # ARPHRD_TUNNEL6 = 769
    ARPHRD_FRAD = 770
    # ARPHRD_SKIP = 771
    ARPHRD_LOOPBACK = 772
    # ARPHRD_LOCALTLK = 773
    # ARPHRD_FDDI = 774
    # ARPHRD_BIF = 775
    # ARPHRD_SIT = 776
    # ARPHRD_IPDDP = 777
    # ARPHRD_IPGRE = 778
    # ARPHRD_PIMREG = 779
    ARPHRD_HIPPI = 780
    # ARPHRD_ASH = 781
    # ARPHRD_ECONET = 782
    # ARPHRD_IRDA = 783
    # ARPHRD_FCPP = 784
    # ARPHRD_FCAL = 785
    # ARPHRD_FCPL = 786
    # ARPHRD_FCFABRIC = 787
    # ARPHRD_IEEE802_TR = 800
    ARPHRD_IEEE80211 = 801
    ARPHRD_IEEE80211_PRISM = 802
    ARPHRD_IEEE80211_RADIOTAP = 803
    # ARPHRD_IEEE802154 = 804
    # ARPHRD_IEEE802154_MONITOR = 805
    # ARPHRD_PHONET = 820
    # ARPHRD_PHONET_PIPE = 821
    # ARPHRD_CAIF = 822
    # ARPHRD_IP6GRE = 823
    # ARPHRD_NETLINK = 824
    # ARPHRD_6LOWPAN = 825
    # ARPHRD_VOID = 0xFFFF
    # ARPHRD_NONE = 0xFFFE

  type
    Sockaddr_nl = object
      family: cushort
      pad: cushort
      pid: uint32
      groups: uint32

    NlMsgHeader = object
      nlmsg_len: uint32
      nlmsg_type: uint16
      nlmsg_flags: uint16
      nlmsg_seq: uint32
      nlmsg_pid: uint32

    IfInfoMessage = object
      ifi_family: cuchar
      ifi_pad: cuchar
      ifi_type: cushort
      ifi_index: cint
      ifi_flags: cuint
      ifi_change: cuint

    IfAddrMessage = object
      ifa_family: cuchar
      ifa_prefixlen: cuchar
      ifa_flags: cuchar
      ifa_scope: cuchar
      ifa_index: uint32

    RtMessage = object
      rtm_family: byte
      rtm_dst_len: byte
      rtm_src_len: byte
      rtm_tos: byte
      rtm_table: byte
      rtm_protocol: byte
      rtm_scope: byte
      rtm_type: byte
      rtm_flags: cuint

    RtAttr = object
      rta_len: cushort
      rta_type: cushort

    RtGenMsg = object
      rtgen_family: byte

    NLReq = object
      hdr: NlMsgHeader
      msg: RtGenMsg

    NLRouteReq = object
      hdr: NlMsgHeader
      msg: RtMessage

  template NLMSG_ALIGN(length: uint): uint =
    (length + NLMSG_ALIGNTO - 1) and not(NLMSG_ALIGNTO - 1)

  template NLMSG_HDRLEN(): int =
    int(NLMSG_ALIGN(uint(sizeof(NlMsgHeader))))

  template NLMSG_LENGTH(length: int): uint32 =
    uint32(NLMSG_HDRLEN() + length)

  proc NLMSG_OK(nlh: ptr NlMsgHeader, length: int): bool =
    (length >= int(sizeof(NlMsgHeader))) and
      (nlh.nlmsg_len >= uint32(sizeof(NlMsgHeader))) and
      (nlh.nlmsg_len <= uint32(length))

  proc NLMSG_NEXT(nlh: ptr NlMsgHeader,
                  length: var int): ptr NlMsgHeader =
    length = length - int(NLMSG_ALIGN(uint(nlh.nlmsg_len)))
    cast[ptr NlMsgHeader](cast[uint](nlh) +
                          cast[uint](NLMSG_ALIGN(uint(nlh.nlmsg_len))))

  proc NLMSG_DATA(nlh: ptr NlMsgHeader): ptr byte =
    cast[ptr byte](cast[uint](nlh) + NLMSG_LENGTH(0))

  proc NLMSG_TAIL(nlh: ptr NlMsgHeader): ptr byte {.inline.} =
    cast[ptr byte](cast[uint](nlh) + NLMSG_ALIGN(uint(nlh.nlmsg_len)))

  template RTA_ALIGN*(length: uint): uint =
    (length + RTA_ALIGNTO - 1) and not(RTA_ALIGNTO - 1)

  template RTA_HDRLEN(): int =
    int(RTA_ALIGN(uint(sizeof(RtAttr))))

  template RTA_LENGTH(length: int): uint =
    uint(RTA_HDRLEN()) + uint(length)

  template RTA_PAYLOAD*(length: uint): uint =
    length - RTA_LENGTH(0)

  proc IFLA_RTA(r: ptr byte): ptr RtAttr =
    cast[ptr RtAttr](cast[uint](r) + NLMSG_ALIGN(uint(sizeof(IfInfoMessage))))

  proc IFA_RTA(r: ptr byte): ptr RtAttr =
    cast[ptr RtAttr](cast[uint](r) + NLMSG_ALIGN(uint(sizeof(IfAddrMessage))))

  proc RT_RTA(r: ptr byte): ptr RtAttr =
    cast[ptr RtAttr](cast[uint](r) + NLMSG_ALIGN(uint(sizeof(RtMessage))))

  proc RTA_OK(rta: ptr RtAttr, length: int): bool =
    length >= sizeof(RtAttr) and
      rta.rta_len >= cushort(sizeof(RtAttr)) and
      rta.rta_len <= cushort(length)

  proc RTA_NEXT(rta: ptr RtAttr, length: var int): ptr RtAttr =
    length = length - int(RTA_ALIGN(uint(rta.rta_len)))
    cast[ptr RtAttr](cast[uint](rta) +
                     cast[uint](RTA_ALIGN(uint(rta.rta_len))))

  proc RTA_DATA(rta: ptr RtAttr): ptr byte =
    cast[ptr byte](cast[uint](rta) + RTA_LENGTH(0))

  proc toInterfaceState(it: cint, flags: cuint): InterfaceState =
    case it
    of 1:
      StatusNotPresent
    of 2:
      StatusDown
    of 3:
      StatusLowerLayerDown
    of 4:
      StatusTesting
    of 5:
      StatusDormant
    of 6:
      StatusUp
    else:
      StatusUnknown

  proc toInterfaceType(ft: uint32): InterfaceType =
    case ft
    of ARPHRD_ETHER, ARPHRD_EETHER:
      IfEthernetCsmacd
    of ARPHRD_LOOPBACK:
      IfSoftwareLoopback
    of 787..799:
      IfFibreChannel
    of ARPHRD_PPP:
      IfPpp
    of ARPHRD_SLIP, ARPHRD_CSLIP, ARPHRD_SLIP6, ARPHRD_CSLIP6:
      IfSlip
    of ARPHRD_IEEE1394:
      IfIeee1394
    of ARPHRD_IEEE80211, ARPHRD_IEEE80211_PRISM, ARPHRD_IEEE80211_RADIOTAP:
      IfIeee80211
    of ARPHRD_ATM:
      IfAtm
    of ARPHRD_HDLC:
      IfHdlc
    of ARPHRD_HIPPI:
      IfHippiInterface
    of ARPHRD_ARCNET:
      IfArcNet
    of ARPHRD_LAPB:
      IfLapB
    of ARPHRD_FRAD:
      IfFrameRelay
    else:
      IfOther

  proc createNetlinkSocket(pid: Pid): SocketHandle =
    var address: Sockaddr_nl
    address.family = cushort(AF_NETLINK)
    address.groups = 0
    address.pid = cast[uint32](pid)
    var res = posix.socket(AF_NETLINK, posix.SOCK_DGRAM, NETLINK_ROUTE)
    if res != SocketHandle(-1):
      if posix.bindSocket(res, cast[ptr SockAddr](addr address),
                          SockLen(sizeof(Sockaddr_nl))) != 0:
        discard posix.close(res)
        res = SocketHandle(-1)
    res

  proc sendLinkMessage(fd: SocketHandle, pid: Pid, seqno: uint32,
                          ntype: uint16, nflags: uint16): bool =
    var
      rmsg: Tmsghdr
      iov: IOVec
      req: NLReq
      address: Sockaddr_nl

    type TIovLen = type iov.iov_len

    address.family = cushort(AF_NETLINK)
    req.hdr.nlmsg_len = NLMSG_LENGTH(sizeof(RtGenMsg))
    req.hdr.nlmsg_type = ntype
    req.hdr.nlmsg_flags = nflags
    req.hdr.nlmsg_seq = seqno
    req.hdr.nlmsg_pid = cast[uint32](pid)
    req.msg.rtgen_family = byte(AF_PACKET)
    iov.iov_base = cast[pointer](addr req)
    iov.iov_len = cast[TIovLen](req.hdr.nlmsg_len)
    rmsg.msg_iov = addr iov
    rmsg.msg_iovlen = 1
    rmsg.msg_name = cast[pointer](addr address)
    rmsg.msg_namelen = SockLen(sizeof(Sockaddr_nl))
    let res = posix.sendmsg(fd, addr rmsg, 0).TIovLen
    (res == iov.iov_len)

  proc sendRouteMessage(fd: SocketHandle, pid: Pid, seqno: uint32,
                        ntype: uint16, nflags: uint16,
                        dest: TransportAddress): bool =
    var
      rmsg: Tmsghdr
      iov: IOVec
      address: Sockaddr_nl
      buffer: array[64, byte]

    type TIovLen = type iov.iov_len

    var req = cast[ptr NLRouteReq](addr buffer[0])

    address.family = cushort(AF_NETLINK)
    req.hdr.nlmsg_len = NLMSG_LENGTH(sizeof(RtMessage))
    req.hdr.nlmsg_type = ntype
    req.hdr.nlmsg_flags = nflags
    req.hdr.nlmsg_seq = seqno
    req.hdr.nlmsg_pid = cast[uint32](pid)

    var attr = cast[ptr RtAttr](NLMSG_TAIL(addr req.hdr))

    req.msg.rtm_flags = RTM_F_LOOKUP_TABLE
    attr.rta_type = RTA_DST
    if dest.family == AddressFamily.IPv4:
      req.msg.rtm_family = byte(posix.AF_INET)
      attr.rta_len = cast[cushort](RTA_LENGTH(4))
      copyMem(RTA_DATA(attr), cast[ptr byte](unsafeAddr dest.address_v4[0]), 4)
      req.hdr.nlmsg_len = uint32(NLMSG_ALIGN(uint(req.hdr.nlmsg_len)) +
                                 RTA_ALIGN(uint(attr.rta_len)))
      req.msg.rtm_dst_len = 4 * 8
    elif dest.family == AddressFamily.IPv6:
      req.msg.rtm_family = byte(posix.AF_INET6)
      attr.rta_len = cast[cushort](RTA_LENGTH(16))
      copyMem(RTA_DATA(attr), cast[ptr byte](unsafeAddr dest.address_v6[0]), 16)
      req.hdr.nlmsg_len = uint32(NLMSG_ALIGN(uint(req.hdr.nlmsg_len)) +
                                 RTA_ALIGN(uint(attr.rta_len)))
      req.msg.rtm_dst_len = 16 * 8

    iov.iov_base = cast[pointer](addr buffer[0])
    iov.iov_len = cast[TIovLen](req.hdr.nlmsg_len)
    rmsg.msg_iov = addr iov
    rmsg.msg_iovlen = 1
    rmsg.msg_name = cast[pointer](addr address)
    rmsg.msg_namelen = SockLen(sizeof(Sockaddr_nl))
    let res = posix.sendmsg(fd, addr rmsg, 0).TIovLen
    (res == iov.iov_len)

  proc readNetlinkMessage(fd: SocketHandle, data: var seq[byte]): bool =
    var
      rmsg: Tmsghdr
      iov: IOVec
      address: Sockaddr_nl
    data.setLen(IFLIST_REPLY_BUFFER)
    iov.iov_base = cast[pointer](addr data[0])
    iov.iov_len = IFLIST_REPLY_BUFFER
    rmsg.msg_iov = addr iov
    rmsg.msg_iovlen = 1
    rmsg.msg_name = cast[pointer](addr address)
    rmsg.msg_namelen = SockLen(sizeof(Sockaddr_nl))
    var length = posix.recvmsg(fd, addr rmsg, 0)
    if length >= 0:
      data.setLen(length)
      true
    else:
      data.setLen(0)
      false

  proc processLink(msg: ptr NlMsgHeader): NetworkInterface =
    var iface: ptr IfInfoMessage
    var attr: ptr RtAttr
    var length: int

    iface = cast[ptr IfInfoMessage](NLMSG_DATA(msg))
    length = int(msg.nlmsg_len) - int(NLMSG_LENGTH(sizeof(IfInfoMessage)))

    attr = IFLA_RTA(cast[ptr byte](iface))
    var res = NetworkInterface(
      ifType: toInterfaceType(iface.ifi_type),
      ifIndex: iface.ifi_index,
      flags: cast[uint64](iface.ifi_flags)
    )

    while RTA_OK(attr, length):
      if attr.rta_type == IFLA_IFNAME:
        var p = cast[cstring](RTA_DATA(attr))
        res.name = $p
      elif attr.rta_type == IFLA_ADDRESS:
        var p = cast[ptr byte](RTA_DATA(attr))
        var plen = min(int(RTA_PAYLOAD(uint(attr.rta_len))), len(res.mac))
        copyMem(addr res.mac[0], p, plen)
        res.maclen = plen
      elif attr.rta_type == IFLA_MTU:
        var p = cast[ptr uint32](RTA_DATA(attr))
        res.mtu = cast[int](p[])
      elif attr.rta_type == IFLA_OPERSTATE:
        var p = cast[ptr byte](RTA_DATA(attr))
        res.state = toInterfaceState(cast[cint](p[]), iface.ifi_flags)
      attr = RTA_NEXT(attr, length)
    res

  proc getAddress(f: int, p: pointer): TransportAddress =
    if f == posix.AF_INET:
      var res = TransportAddress(family: AddressFamily.IPv4)
      copyMem(addr res.address_v4[0], p, len(res.address_v4))
      res
    elif f == posix.AF_INET6:
      var res = TransportAddress(family: AddressFamily.IPv6)
      copyMem(addr res.address_v6[0], p, len(res.address_v6))
      res
    else:
      TransportAddress(family: AddressFamily.None)

  proc processAddress(msg: ptr NlMsgHeader): NetworkInterface =
    var iaddr: ptr IfAddrMessage
    var attr: ptr RtAttr
    var length: int

    iaddr = cast[ptr IfAddrMessage](NLMSG_DATA(msg))
    length = int(msg.nlmsg_len) - int(NLMSG_LENGTH(sizeof(IfAddrMessage)))

    attr = IFA_RTA(cast[ptr byte](iaddr))

    let family = cast[int](iaddr.ifa_family)
    var res = NetworkInterface(ifIndex: cast[int](iaddr.ifa_index))

    var address, local: TransportAddress

    while RTA_OK(attr, length):
      if attr.rta_type == IFA_LOCAL:
        local = getAddress(family, cast[pointer](RTA_DATA(attr)))
      elif attr.rta_type == IFA_ADDRESS:
        address = getAddress(family, cast[pointer](RTA_DATA(attr)))
      attr = RTA_NEXT(attr, length)

    if local.family != AddressFamily.None:
      address = local

    let prefixLength = cast[int](iaddr.ifa_prefixlen)
    let ifaddr = InterfaceAddress.init(address, prefixLength)
    res.addresses.add(ifaddr)
    res

  proc processRoute(msg: ptr NlMsgHeader): Route =
    var rtmsg = cast[ptr RtMessage](NLMSG_DATA(msg))
    var length = int(msg.nlmsg_len) - int(NLMSG_LENGTH(sizeof(RtMessage)))
    var attr = RT_RTA(cast[ptr byte](rtmsg))
    var res = Route()
    while RTA_OK(attr, length):
      if attr.rta_type == RTA_DST:
        res.dest = getAddress(int(rtmsg.rtm_family),
                                 cast[pointer](RTA_DATA(attr)))
      elif attr.rta_type == RTA_GATEWAY:
        res.gateway = getAddress(int(rtmsg.rtm_family),
                                    cast[pointer](RTA_DATA(attr)))
      elif attr.rta_type == RTA_OIF:
        var oid: uint32
        copyMem(addr oid, RTA_DATA(attr), sizeof(uint32))
        res.ifIndex = int(oid)
      elif attr.rta_type == RTA_PREFSRC:
        res.source = getAddress(int(rtmsg.rtm_family),
                                   cast[pointer](RTA_DATA(attr)))
      attr = RTA_NEXT(attr, length)
    res

  proc getRoute(netfd: SocketHandle, pid: Pid,
                 address: TransportAddress): Route =
    if not sendRouteMessage(netfd, pid, 1, RTM_GETROUTE,
                            NLM_F_REQUEST, address):
      return Route()
    var data = newSeq[byte]()
    var res = Route()
    while true:
      if not readNetlinkMessage(netfd, data):
        break
      var length = len(data)
      var msg = cast[ptr NlMsgHeader](addr data[0])
      var endflag = false
      while NLMSG_OK(msg, length):
        if msg.nlmsg_type == NLMSG_ERROR:
          endflag = true
          break
        else:
          res = processRoute(msg)
          endflag = true
          break
        msg = NLMSG_NEXT(msg, length)
      if endflag:
        break
    res

  proc getLinks(netfd: SocketHandle, pid: Pid): seq[NetworkInterface] =
    var res: seq[NetworkInterface]
    if not sendLinkMessage(netfd, pid, 1, RTM_GETLINK,
                           NLM_F_REQUEST or NLM_F_DUMP):
      return res
    var data = newSeq[byte]()
    res = newSeq[NetworkInterface]()
    while true:
      if not readNetlinkMessage(netfd, data):
        break
      var length = len(data)
      if length == 0:
        break
      var msg = cast[ptr NlMsgHeader](addr data[0])
      var endflag = false
      while NLMSG_OK(msg, length):
        if msg.nlmsg_type == NLMSG_DONE:
          endflag = true
          break
        elif msg.nlmsg_type == NLMSG_ERROR:
          endflag = true
          break
        else:
          var iface = processLink(msg)
          res.add(iface)
        msg = NLMSG_NEXT(msg, length)
      if endflag:
        break
    res

  proc getAddresses(netfd: SocketHandle, pid: Pid,
                    ifaces: var seq[NetworkInterface]) =
    if not sendLinkMessage(netfd, pid, 2, RTM_GETADDR,
                           NLM_F_REQUEST or NLM_F_DUMP):
      return
    var data = newSeq[byte]()
    while true:
      if not readNetlinkMessage(netfd, data):
        break
      var length = len(data)
      if length == 0:
        break
      var msg = cast[ptr NlMsgHeader](addr data[0])
      var endflag = false
      while NLMSG_OK(msg, length):
        if msg.nlmsg_type == NLMSG_DONE:
          endflag = true
          break
        elif msg.nlmsg_type == NLMSG_ERROR:
          endflag = true
          break
        else:
          var iface = processAddress(msg)
          for i in 0..<len(ifaces):
            if ifaces[i].ifIndex == iface.ifIndex:
              for item in iface.addresses:
                ifaces[i].addresses.add(item)
        msg = NLMSG_NEXT(msg, length)
      if endflag:
        break

  proc getInterfaces*(): seq[NetworkInterface] {.raises: [Defect].} =
    ## Return list of available interfaces.
    var res: seq[NetworkInterface]
    var pid = posix.getpid()
    var sock = createNetlinkSocket(pid)
    if sock == InvalidSocketHandle:
      return res
    else:
      res = getLinks(sock, pid)
      getAddresses(sock, pid, res)
      sort(res, cmp)
      discard posix.close(sock)
      res

  proc getBestRoute*(address: TransportAddress): Route {.raises: [Defect].} =
    ## Return best applicable OS route, which will be used for connecting to
    ## address ``address``.
    var pid = posix.getpid()
    var res = Route()
    var sock = createNetlinkSocket(pid)
    if sock == InvalidSocketHandle:
      res
    else:
      res = getRoute(sock, pid, address)
      discard posix.close(sock)
      res

elif defined(macosx) or defined(bsd):
  import posix

  const
    AF_LINK = 18
    IFF_UP = 0x01
    IFF_RUNNING = 0x40

    PF_ROUTE = cint(17)
    RTM_GET = 0x04'u8
    RTF_UP = 0x01
    RTF_GATEWAY = 0x02
    RTM_VERSION = 5'u8

    RTA_DST = 0x01
    RTA_GATEWAY = 0x02

  type
    IfAddrs {.importc: "struct ifaddrs", header: "<ifaddrs.h>",
              pure, final.} = object
      ifa_next {.importc: "ifa_next".}: ptr IfAddrs
      ifa_name {.importc: "ifa_name".}: ptr cchar
      ifa_flags {.importc: "ifa_flags".}: cuint
      ifa_addr {.importc: "ifa_addr".}: ptr SockAddr
      ifa_netmask {.importc: "ifa_netmask".}: ptr SockAddr
      ifa_dstaddr {.importc: "ifa_dstaddr".}: ptr SockAddr
      ifa_data {.importc: "ifa_data".}: pointer

    PIfAddrs = ptr IfAddrs

    IfData {.importc: "struct if_data", header: "<net/if.h>",
             pure, final.} = object
      ifi_type {.importc: "ifi_type".}: byte
      ifi_typelen {.importc: "ifi_typelen".}: byte
      ifi_physical {.importc: "ifi_physical".}: byte
      ifi_addrlen {.importc: "ifi_addrlen".}: byte
      ifi_hdrlen {.importc: "ifi_hdrlen".}: byte
      ifi_recvquota {.importc: "ifi_recvquota".}: byte
      ifi_xmitquota {.importc: "ifi_xmitquota".}: byte
      ifi_unused1 {.importc: "ifi_unused1".}: byte
      ifi_mtu {.importc: "ifi_mtu".}: uint32
      ifi_metric {.importc: "ifi_metric".}: uint32
      ifi_baudrate {.importc: "ifi_baudrate".}: uint32
      ifi_ipackets {.importc: "ifi_ipackets".}: uint32
      ifi_ierrors {.importc: "ifi_ierrors".}: uint32
      ifi_opackets {.importc: "ifi_opackets".}: uint32
      ifi_oerrors {.importc: "ifi_oerrors".}: uint32
      ifi_collisions {.importc: "ifi_collisions".}: uint32
      ifi_ibytes {.importc: "ifi_ibytes".}: uint32
      ifi_obytes {.importc: "ifi_obytes".}: uint32
      ifi_imcasts {.importc: "ifi_imcasts".}: uint32
      ifi_omcasts {.importc: "ifi_omcasts".}: uint32
      ifi_iqdrops {.importc: "ifi_iqdrops".}: uint32
      ifi_noproto {.importc: "ifi_noproto".}: uint32
      ifi_recvtiming {.importc: "ifi_recvtiming".}: uint32
      ifi_xmittiming {.importc: "ifi_xmittiming".}: uint32
      ifi_lastchange {.importc: "ifi_lastchange".}: Timeval
      ifi_unused2 {.importc: "ifi_unused2".}: uint32
      ifi_hwassist {.importc: "ifi_hwassist".}: uint32
      ifi_reserved1 {.importc: "ifi_reserved1".}: uint32
      ifi_reserved2 {.importc: "ifi_reserved2".}: uint32

    Sockaddr_dl = object
      sdl_len: byte
      sdl_family: byte
      sdl_index: uint16
      sdl_type: byte
      sdl_nlen: byte
      sdl_alen: byte
      sdl_slen: byte
      sdl_data: array[12, byte]

    RtMetrics = object
      rmx_locks: uint32
      rmx_mtu: uint32
      rmx_hopcount: uint32
      rmx_expire: int32
      rmx_recvpipe: uint32
      rmx_sendpipe: uint32
      rmx_ssthresh: uint32
      rmx_rtt: uint32
      rmx_rttvar: uint32
      rmx_pksent: uint32
      rmx_state: uint32
      rmx_filler: array[3, uint32]

    RtMsgHeader = object
      rtm_msglen: uint16
      rtm_version: byte
      rtm_type: byte
      rtm_index: uint16
      rtm_flags: cint
      rtm_addrs: cint
      rtm_pid: Pid
      rtm_seq: cint
      rtm_errno: cint
      rtm_use: cint
      rtm_inits: uint32
      rtm_rmx: RtMetrics

    RtMessage = object
      rtm: RtMsgHeader
      space: array[512, byte]

  proc getIfAddrs(ifap: ptr PIfAddrs): cint {.importc: "getifaddrs",
       header: """#include <sys/types.h>
                  #include <sys/socket.h>
                  #include <ifaddrs.h>""".}
  proc freeIfAddrs(ifap: ptr IfAddrs) {.importc: "freeifaddrs",
       header: """#include <sys/types.h>
                  #include <sys/socket.h>
                  #include <ifaddrs.h>""".}

  proc toInterfaceType(f: byte): InterfaceType =
    var ft = cast[int](f)
    if (ft >= 1 and ft <= 196) or (ft == 237) or (ft == 243) or (ft == 244):
      cast[InterfaceType](ft)
    else:
      IfOther

  proc toInterfaceState(f: cuint): InterfaceState =
    if (f and IFF_RUNNING) != 0 and (f and IFF_UP) != 0:
      StatusUp
    else:
      StatusDown

  proc getInterfaces*(): seq[NetworkInterface] {.raises: [Defect].} =
    ## Return list of available interfaces.
    var res: seq[NetworkInterface]
    var ifap: ptr IfAddrs
    let gres = getIfAddrs(addr ifap)
    if gres == 0:
      while not isNil(ifap):
        var iface: NetworkInterface
        var ifaddress: InterfaceAddress

        iface.name = $ifap.ifa_name
        iface.flags = cast[uint64](ifap.ifa_flags)
        var i = 0
        while i < len(res):
          if res[i].name == iface.name:
            break
          inc(i)
        if i == len(res):
          res.add(iface)

        if not isNil(ifap.ifa_addr):
          let family = cast[int](ifap.ifa_addr.sa_family)
          if family == AF_LINK:
            var data = cast[ptr IfData](ifap.ifa_data)
            var link = cast[ptr Sockaddr_dl](ifap.ifa_addr)
            res[i].ifIndex = cast[int](link.sdl_index)
            let nlen = cast[int](link.sdl_nlen)
            if nlen < len(link.sdl_data):
              let minsize = min(cast[int](link.sdl_alen), len(res[i].mac))
              copyMem(addr res[i].mac[0], addr link.sdl_data[nlen], minsize)
            res[i].maclen = cast[int](link.sdl_alen)
            res[i].ifType = toInterfaceType(data.ifi_type)
            res[i].state = toInterfaceState(ifap.ifa_flags)
            res[i].mtu = cast[int](data.ifi_mtu)
          elif family == posix.AF_INET:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_addr),
                      SockLen(sizeof(Sockaddr_in)), ifaddress.host)
          elif family == posix.AF_INET6:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_addr),
                      SockLen(sizeof(Sockaddr_in6)), ifaddress.host)
        if not isNil(ifap.ifa_netmask):
          var na: TransportAddress
          var family = cast[cint](ifap.ifa_netmask.sa_family)
          if family == posix.AF_INET:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_netmask),
                      SockLen(sizeof(Sockaddr_in)), na)
          elif family == posix.AF_INET6:
            fromSAddr(cast[ptr Sockaddr_storage](ifap.ifa_netmask),
                      SockLen(sizeof(Sockaddr_in6)), na)
          ifaddress.net = IpNet.init(ifaddress.host, na)

        if ifaddress.host.family != AddressFamily.None:
          if len(res[i].addresses) == 0:
            res[i].addresses = newSeq[InterfaceAddress]()
          res[i].addresses.add(ifaddress)
        ifap = ifap.ifa_next

      sort(res, cmp)
      freeIfAddrs(ifap)
    res

  proc sasize(data: openArray[byte]): int =
    # SA_SIZE() template. Taken from FreeBSD net/route.h:1.63
    if len(data) > 0:
      if data[0] == 0x00'u8:
        sizeof(uint32)
      else:
        1 + (int(data[0] - 1) or (sizeof(uint32) - 1))
    else:
      0

  proc getBestRoute*(address: TransportAddress): Route {.raises: [Defect].} =
    ## Return best applicable OS route, which will be used for connecting to
    ## address ``address``.
    var sock: cint
    var msg: RtMessage
    var res = Route()
    var pid = posix.getpid()

    if address.family notin {AddressFamily.IPv4, AddressFamily.IPv6}:
      return

    if address.family == AddressFamily.IPv4:
      sock = cint(posix.socket(PF_ROUTE, posix.SOCK_RAW, posix.AF_INET))
    elif address.family == AddressFamily.IPv6:
      sock = cint(posix.socket(PF_ROUTE, posix.SOCK_RAW, posix.AF_INET6))

    if sock != -1:
      var sastore: Sockaddr_storage
      var salen: SockLen
      address.toSAddr(sastore, salen)
      # We doing this trick because Nim's posix declaration of Sockaddr_storage
      # is not compatible with BSD version. First byte in BSD version is length
      # of Sockaddr structure, and second byte is family code.
      copyMem(addr msg.space[0], addr sastore, int(salen))
      msg.rtm.rtm_type = RTM_GET
      msg.rtm.rtm_flags = RTF_UP or RTF_GATEWAY
      msg.rtm.rtm_version = RTM_VERSION
      msg.rtm.rtm_seq = 0xCAFE
      msg.rtm.rtm_addrs = RTA_DST
      msg.space[0] = cast[byte](salen)
      msg.rtm.rtm_msglen = uint16(sizeof(RtMessage))
      let wres = posix.write(sock, addr msg, sizeof(RtMessage))
      if wres >= 0:
        let rres =
          block:
            var pres = 0
            while true:
              pres = posix.read(sock, addr msg, sizeof(RtMessage))
              if ((pres >= 0) and (msg.rtm.rtm_pid == pid) and
                 (msg.rtm.rtm_seq == 0xCAFE)) or (pres < 0):
                break
            pres
        if (rres >= 0) and (msg.rtm.rtm_version == RTM_VERSION) and
           (msg.rtm.rtm_errno == 0):
          res.ifIndex = int(msg.rtm.rtm_index)
          var so = 0
          var eo = len(msg.space) - 1
          for i in 0..<2:
            let mask = 1 shl i
            if (msg.rtm.rtm_addrs and mask) != 0:
              var saddr = cast[ptr Sockaddr_storage](addr msg.space[so])
              let size = sasize(msg.space.toOpenArray(so, eo))
              if mask == RTA_DST:
                fromSAddr(saddr, SockLen(size), res.dest)
              elif mask == RTA_GATEWAY:
                fromSAddr(saddr, SockLen(size), res.gateway)
              so += size

          if res.dest.isZero():
            res.dest = address
          var interfaces = getInterfaces()
          for item in interfaces:
            if res.ifIndex == item.ifIndex:
              for a in item.addresses:
                if a.host.family == address.family:
                  res.source = a.host
              break
      discard posix.close(sock)
    res

elif defined(windows):
  import winlean, dynlib

  const
    WorkBufferSize = 16384'u32
    MaxTries = 3

    AF_UNSPEC = 0x00'u32

    GAA_FLAG_INCLUDE_PREFIX = 0x0010'u32

    CP_UTF8 = 65001'u32

    ERROR_BUFFER_OVERFLOW* = 111'u32
    ERROR_SUCCESS* = 0'u32

  type
    WCHAR = distinct uint16

    SocketAddress = object
      lpSockaddr: ptr SockAddr
      iSockaddrLength: cint

    IpAdapterUnicastAddressXpLh = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterUnicastAddressXpLh
      address: SocketAddress
      prefixOrigin: cint
      suffixOrigin: cint
      dadState: cint
      validLifetime: uint32
      preferredLifetime: uint32
      leaseLifetime: uint32
      onLinkPrefixLength: byte # This field is available only from Vista

    IpAdapterAnycastAddressXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterAnycastAddressXp
      address: SocketAddress

    IpAdapterMulticastAddressXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterMulticastAddressXp
      address: SocketAddress

    IpAdapterDnsServerAddressXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterDnsServerAddressXp
      address: SocketAddress

    IpAdapterPrefixXp = object
      length: uint32
      flags: uint32
      next: ptr IpAdapterPrefixXp
      address: SocketAddress
      prefixLength: uint32

    IpAdapterAddressesXp = object
      length: uint32
      ifIndex: uint32
      next: ptr IpAdapterAddressesXp
      adapterName: cstring
      unicastAddress: ptr IpAdapterUnicastAddressXpLh
      anycastAddress: ptr IpAdapterAnycastAddressXp
      multicastAddress: ptr IpAdapterMulticastAddressXp
      dnsServerAddress: ptr IpAdapterDnsServerAddressXp
      dnsSuffix: ptr WCHAR
      description: ptr WCHAR
      friendlyName: ptr WCHAR
      physicalAddress: array[MaxAdapterAddressLength, byte]
      physicalAddressLength: uint32
      flags: uint32
      mtu: uint32
      ifType: uint32
      operStatus: cint
      ipv6IfIndex: uint32
      zoneIndices: array[16, uint32]
      firstPrefix: ptr IpAdapterPrefixXp

    MibIpForwardRow = object
      dwForwardDest: uint32
      dwForwardMask: uint32
      dwForwardPolicy: uint32
      dwForwardNextHop: uint32
      dwForwardIfIndex: uint32
      dwForwardType: uint32
      dwForwardProto: uint32
      dwForwardAge: uint32
      dwForwardNextHopAS: uint32
      dwForwardMetric1: uint32
      dwForwardMetric2: uint32
      dwForwardMetric3: uint32
      dwForwardMetric4: uint32
      dwForwardMetric5: uint32

    SOCKADDR_INET {.union.} = object
      ipv4: Sockaddr_in
      ipv6: Sockaddr_in6
      si_family: uint16

    IPADDRESS_PREFIX = object
      prefix: SOCKADDR_INET
      prefixLength: uint8

    MibIpForwardRow2 = object
      interfaceLuid: uint64
      interfaceIndex: uint32
      destinationPrefix: IPADDRESS_PREFIX
      nextHop: SOCKADDR_INET
      sitePrefixLength: byte
      validLifetime: uint32
      preferredLifetime: uint32
      metric: uint32
      protocol: uint32
      loopback: bool
      autoconfigureAddress: bool
      publish: bool
      immortal: bool
      age: uint32
      origin: uint32

    GETBESTROUTE2 = proc(InterfaceLuid: ptr uint64, InterfaceIndex: uint32,
                         SourceAddress: ptr SOCKADDR_INET,
                         DestinationAddress: ptr SOCKADDR_INET,
                         AddressSortOptions: uint32,
                         BestRoute: ptr MibIpForwardRow2,
                         BestSourceAddress: ptr SOCKADDR_INET): DWORD {.
                    gcsafe, stdcall, raises: [].}

  proc toInterfaceType(ft: uint32): InterfaceType {.inline.} =
    if (ft >= 1'u32 and ft <= 196'u32) or
       (ft == 237) or (ft == 243) or (ft == 244) or (ft == 259) or (ft == 281):
      cast[InterfaceType](ft)
    else:
      IfOther

  proc toInterfaceState(it: cint): InterfaceState  {.inline.} =
    if it >= 1 and it <= 7:
      cast[InterfaceState](it)
    else:
      StatusUnknown

  proc GetAdaptersAddresses(family: uint32, flags: uint32, reserved: pointer,
                            addresses: ptr IpAdapterAddressesXp,
                            sizeptr: ptr uint32): uint32 {.
       stdcall, dynlib: "iphlpapi", importc: "GetAdaptersAddresses",
       raises: [].}

  proc WideCharToMultiByte(CodePage: uint32, dwFlags: uint32,
                           lpWideCharStr: ptr WCHAR, cchWideChar: cint,
                           lpMultiByteStr: ptr char, cbMultiByte: cint,
                           lpDefaultChar: ptr char,
                           lpUsedDefaultChar: ptr uint32): cint
       {.stdcall, dynlib: "kernel32.dll", importc: "WideCharToMultiByte",
         raises: [].}

  proc getBestRouteXp(dwDestAddr: uint32, dwSourceAddr: uint32,
                      pBestRoute: ptr MibIpForwardRow): uint32 {.
       stdcall, dynlib: "iphlpapi", importc: "GetBestRoute",
       raises: [].}

  proc `$`(bstr: ptr WCHAR): string =
    var buffer: char
    var count = WideCharToMultiByte(CP_UTF8, 0, bstr, -1, addr(buffer), 0,
                                    nil, nil)
    if count > 0:
      var res = newString(count + 8)
      let wres = WideCharToMultiByte(CP_UTF8, 0, bstr, -1, addr(res[0]),
                                     count, nil, nil)
      if wres > 0:
        res.setLen(wres - 1)
      else:
        res.setLen(0)
      res
    else:
      ""

  proc isVista(): bool =
    var ver: OSVERSIONINFO
    ver.dwOSVersionInfoSize = DWORD(sizeof(ver))
    let res = getVersionExW(addr(ver))
    if res == 0:
      false
    else:
      (ver.dwMajorVersion >= 6)

  proc toIPv6(a: TransportAddress): TransportAddress =
    ## IPv4-mapped addresses are formed by:
    ## <80 bits of zeros> + <16 bits of ones> + <32-bit IPv4 address>.
    if a.family == AddressFamily.IPv4:
      var res = TransportAddress(family: AddressFamily.IPv6)
      res.address_v6[10] = 0xFF'u8
      res.address_v6[11] = 0xFF'u8
      copyMem(addr res.address_v6[12], unsafeAddr a.address_v4[0], 4)
      res
    elif a.family == AddressFamily.IPv6:
      a
    else:
      TransportAddress(family: AddressFamily.IPv6)

  proc ipMatchPrefix(number, prefix: TransportAddress, nbits: int): bool =
    var num6, prefix6: TransportAddress
    if number.family == AddressFamily.IPv4:
      num6 = toIPv6(number)
    else:
      num6 = number
    if prefix.family == AddressFamily.IPv4:
      prefix6 = toIPv6(number)
    else:
      prefix6 = prefix
    var bytesCount = nbits div 8
    var bitsCount = nbits mod 8
    for i in 0..<bytesCount:
      if num6.address_v6[i] != prefix6.address_v6[i]:
        return false
    if bitsCount != 0:
      var mask = cast[byte](0xFF'u8 shl (8 - bitsCount))
      let i = bytesCount
      if (num6.address_v6[i] and mask) != (prefix6.address_v6[i] and mask):
        return false
    true

  proc processAddress(ifitem: ptr IpAdapterAddressesXp,
                      ifunic: ptr IpAdapterUnicastAddressXpLh,
                      vista: bool): InterfaceAddress =
    var res = InterfaceAddress()
    var netfamily = ifunic.address.lpSockaddr.sa_family
    fromSAddr(cast[ptr Sockaddr_storage](ifunic.address.lpSockaddr),
              SockLen(ifunic.address.iSockaddrLength), res.host)
    if not vista:
      var prefix = ifitem.firstPrefix
      var prefixLength = -1
      while not isNil(prefix):
        var pa: TransportAddress
        var prefamily = prefix.address.lpSockaddr.sa_family
        fromSAddr(cast[ptr Sockaddr_storage](prefix.address.lpSockaddr),
                  SockLen(prefix.address.iSockaddrLength), pa)
        if netfamily == prefamily:
          if ipMatchPrefix(res.host, pa, cast[int](prefix.prefixLength)):
            prefixLength = max(prefixLength, cast[int](prefix.prefixLength))
        prefix = prefix.next
      if prefixLength >= 0:
        res.net = IpNet.init(res.host, prefixLength)
    else:
      let prefixLength = cast[int](ifunic.onLinkPrefixLength)
      if prefixLength >= 0:
        res.net = IpNet.init(res.host, prefixLength)
    res

  proc getInterfaces*(): seq[NetworkInterface] {.raises: [Defect].} =
    ## Return list of network interfaces.
    var res = newSeq[NetworkInterface]()
    var size = WorkBufferSize
    var tries = 0
    var buffer: seq[byte]
    var gres: uint32
    var vista = isVista()

    while true:
      buffer = newSeq[byte](size)
      var addresses = cast[ptr IpAdapterAddressesXp](addr buffer[0])
      gres = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, nil,
                                  addresses, addr size)
      if gres == ERROR_SUCCESS:
        buffer.setLen(size)
        break
      elif gres == ERROR_BUFFER_OVERFLOW:
        discard
      else:
        break
      inc(tries)
      if tries >= MaxTries:
        break

    if gres == ERROR_SUCCESS:
      var slider = cast[ptr IpAdapterAddressesXp](addr buffer[0])
      while not isNil(slider):
        var iface = NetworkInterface(
          ifIndex: cast[int](slider.ifIndex),
          ifType: toInterfaceType(slider.ifType),
          state: toInterfaceState(slider.operStatus),
          name: $slider.adapterName,
          desc: $slider.description,
          mtu: cast[int](slider.mtu),
          maclen: cast[int](slider.physicalAddressLength),
          flags: cast[uint64](slider.flags)
        )
        copyMem(addr iface.mac[0], addr slider.physicalAddress[0],
                len(iface.mac))
        var unicast = slider.unicastAddress
        while not isNil(unicast):
          var ifaddr = processAddress(slider, unicast, vista)
          iface.addresses.add(ifaddr)
          unicast = unicast.next
        res.add(iface)
        slider = slider.next

      sort(res, cmp)
    res

  proc getBestRoute*(address: TransportAddress): Route {.raises: [Defect].} =
    ## Return best applicable OS route, which will be used for connecting to
    ## address ``address``.
    var res = Route()
    if isVista():
      let iph = loadLib("iphlpapi.dll")
      if iph != nil:
        var bestRoute: MibIpForwardRow2
        var empty: TransportAddress
        var dest, src: Sockaddr_storage
        var luid: uint64
        var destlen: SockLen
        address.toSAddr(dest, destlen)
        var getBestRoute2  = cast[GETBESTROUTE2](symAddr(iph, "GetBestRoute2"))
        var gres = getBestRoute2(addr luid, 0'u32, nil,
                                cast[ptr SOCKADDR_INET](addr dest),
                                0'u32,
                                addr bestRoute,
                                cast[ptr SOCKADDR_INET](addr src))
        if gres == 0:
          if src.ss_family == winlean.AF_INET:
            fromSAddr(addr src, SockLen(sizeof(Sockaddr_in)), res.source)
          elif src.ss_family == winlean.AF_INET6:
            fromSAddr(addr src, SockLen(sizeof(Sockaddr_in6)), res.source)
          if bestRoute.nextHop.si_family == winlean.AF_INET:
            fromSAddr(cast[ptr Sockaddr_storage](addr bestRoute.nextHop),
                      SockLen(sizeof(Sockaddr_in)), res.gateway)
          elif bestRoute.nextHop.si_family == winlean.AF_INET6:
            fromSAddr(cast[ptr Sockaddr_storage](addr bestRoute.nextHop),
                      SockLen(sizeof(Sockaddr_in6)), res.gateway)
          if res.gateway.isZero():
            res.gateway = empty
          res.dest = address
          res.ifIndex = int(bestRoute.interfaceIndex)
          res.metric = int(bestRoute.metric)
    else:
      if address.family == AddressFamily.IPv4:
        var bestRoute: MibIpForwardRow
        var dest: uint32
        copyMem(addr dest, unsafeAddr address.address_v4[0], 4)
        let gres = getBestRouteXp(dest, 0'u32, addr bestRoute)
        if gres == 0:
          var interfaces = getInterfaces()
          res.dest = address
          if bestRoute.dwForwardNextHop != 0'u32:
            res.gateway = TransportAddress(family: AddressFamily.IPv4)
            copyMem(addr res.gateway.address_v4[0],
                    addr bestRoute.dwForwardNextHop, 4)
          res.metric = int(bestRoute.dwForwardMetric1)
          res.ifIndex = int(bestRoute.dwForwardIfIndex)
          for item in interfaces:
            if item.ifIndex == int(bestRoute.dwForwardIfIndex):
              for a in item.addresses:
                if a.host.family == AddressFamily.IPv4:
                  res.source = a.host
              break
    res

else:
  {.fatal: "Sorry, your OS is currently not supported!".}
