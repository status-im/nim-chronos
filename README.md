# Chronos - An efficient library for asynchronous programming

[![Github action](https://github.com/status-im/nim-chronos/workflows/CI/badge.svg)](https://github.com/status-im/nim-chronos/actions/workflows/ci.yml)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

## Introduction

Chronos is an efficient [async/await](https://en.wikipedia.org/wiki/Async/await) framework for Nim. Features include:

* Asynchronous socket and process I/O
* HTTP server with SSL/TLS support out of the box (no OpenSSL needed)
* Synchronization primitivies like queues, events and locks
* Cancellation
* Efficient dispatch pipeline with excellent multi-platform support
* Exceptional error handling features, including `raises` tracking

## Getting started

Install `chronos` using `nimble`:

```text
nimble install chronos
```

or add a dependency to your `.nimble` file:

```text
requires "chronos"
```

and start using it:

```nim
import chronos/apps/http/httpclient

proc retrievePage(uri: string): Future[string] {.async.} =
  # Create a new HTTP session
  let httpSession = HttpSessionRef.new()
  try:
    # Fetch page contents
    let resp = await httpSession.fetch(parseUri(uri))
    # Convert response to a string, assuming its encoding matches the terminal!
    bytesToString(resp.data)
  finally: # Close the session
    await noCancel(httpSession.closeWait())

echo waitFor retrievePage(
  "https://raw.githubusercontent.com/status-im/nim-chronos/master/README.md")
```

## Documentation

See the [user guide](https://status-im.github.io/nim-chronos/).

## Projects using `chronos`

* [libp2p](https://github.com/status-im/nim-libp2p) - Peer-to-Peer networking stack implemented in many languages
* [presto](https://github.com/status-im/nim-presto) - REST API framework
* [Scorper](https://github.com/bung87/scorper) - Web framework
* [2DeFi](https://github.com/gogolxdong/2DeFi) - Decentralised file system
* [websock](https://github.com/status-im/nim-websock/) - WebSocket library with lots of features

`chronos` is available in the [Nim Playground](https://play.nim-lang.org/#ix=2TpS)

Submit a PR to add yours!

## TODO
  * Multithreading Stream/Datagram servers

## Contributing

When submitting pull requests, please add test cases for any new features or fixes and make sure `nimble test` is still able to execute the entire test suite successfully.

`chronos` follows the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
