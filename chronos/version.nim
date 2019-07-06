#
#                  Chronos Version
#             (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)
import strutils

const
  ChronosName* = "Chronos"
    ## Project name string

  ChronosMajor* {.intdefine.}: int = 2
    ## Major number of Chronos' version.

  ChronosMinor* {.intdefine.}: int = 2
    ## Minor number of Chronos' version.

  ChronosPatch* {.intdefine.}: int = 7
    ## Patch number of Chronos' version.

  ChronosVersion* = $ChronosMajor & "." & $ChronosMinor & "." & $ChronosPatch
    ## Version of Chronos as a string.

  ChronosIdent* = "$1/$2 ($3/$4)" % [ChronosName, ChronosVersion, hostCPU,
                                     hostOS]
    ## Project ident name for networking services
