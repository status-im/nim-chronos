# Chronos - An Efficient library for asynchronous programming

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nim-chronos/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nim-chronos)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/nimbus/nim-asyncdispatch2/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/nimbus/nim-asyncdispatch2)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

Chronos is an efficient library for asynchronous programming and an alternative to Nim's asyncdispatch.

## Documentation
You can find more documentation, notes and examples in [Wiki](https://github.com/status-im/nim-chronos/wiki).

## Installation
You can use Nim official package manager `nimble` to install `chronos`. The most recent version of the library can be installed via:

```
$ nimble install https://github.com/status-im/nim-chronos.git
```

## TODO
  * Pipe/Subprocess Transports.
  * Multithreading Stream/Datagram servers
  * Future[T] cancelation
  
## Contributing

When submitting pull requests, please add test cases for any new features or fixes and make sure `nimble test` is still able to execute the entire test suite successfully.

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. This file may not be copied, modified, or distributed except according to those terms.
