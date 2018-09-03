# Plaintext Benchmark

## Overview
Basically this is a mini [TechEmpower](https://www.techempower.com/benchmarks/)
web framework test. It uses the same tools, same techniques, only smaller in scale.

## Tools
* [Docker](https://www.docker.com/), a container platform
* [wrk](https://github.com/wg/wrk), Modern HTTP benchmarking tool

## Participants
Participants in this benchmark are:
* __asyncdispatch2__, lang: Nim
* __asyncdispatch__, lang: Nim, from Nim stdlib
* __actix-raw__, lang: Rust, TFB round 16th rank 1
* __fasthttp__, lang: Go, TFB round 16th rank 2
* __ulib-plaintext_fit__, lang: C++, TFB round 16th rank 3

Participants from TFB round 16th are impressive, how asyncdispatch2 compared to them? This is the goals of this benchmark.
The rank of TFB round 16th is based on plaintext category, running on a physical server.

## Benchmark Setup

* Each of the participants will be put into docker container. Each of them will play the role of a server.
* The benchmarking tool __wrk__ will play the role of a client connecting to server(participant).
* There will be a __bench-bot__ coordinating the benchmark process.

When the bench-bot started, it will build images of participants and executing them one by one.
After starting a participant container, bench-bot will run wrk, grab the result,
then move to next participant, run wrk again for the next participant and doing it again until the last participant.
After the last participant benchmarked, bench-bot will write the benchmark result into a file: `benchmark_result.txt`.
Last thing performed by bench-bot is doing some cleanup and remove container images and instances.

## How each test is run?

Each test is executed as follows:
* Start the platform and framework using their start-up mechanisms.
* Run a 5-second __primer__ at 8 client-concurrency to verify that the server is in fact running. These results are not captured.
* Run a 15-second __warmup__ at 256 client-concurrency to allow lazy-initialization to execute and just-in-time compilation to run. These results are not captured.
* Run a 15-second __captured test__ for each of the concurrency levels (or iteration counts) exercised by the test type.
  The high-concurrency plaintext test type is tested at 128, 256, 512, and 1024 client-side concurrency.
* Stop the platform and framework.

## How to replicate this test locally?
* First, you need to have docker installed, [see here how](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-18-04).
* Compile and run the benchmark bot `nim c -r bot all`
* Wait until it finished, and get the result in `tests/benchmark/benchmark_result.txt`
* You can
## How to add more participants?

* Prepare a directory inside `tests/benchmark/`
* inside that directory prepare a `plaintext.dockerfile` and all necessary source code.
* add a entry in `bot.nim` participants constant list with the directory name.

## How to switch to multi thread mode?
You can find a commented line in the source code of each framework to enable/disable multithread
