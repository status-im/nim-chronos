# Performance and Benchmarking

**Goal:** Understand how Chronos performs under load and learn how to benchmark your server.

**Source code:** [chapter5.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter5.nim)

One of the main reasons to use Chronos is its performance. Thanks to its asynchronous architecture, a single-threaded Chronos server can handle thousands of concurrent connections with minimal overhead.

In this chapter, we'll benchmark the "Status Dashboard" app we've built to see how it performs under load.

## The Benchmark Server

We'll use the complete code from the previous chapter, which includes routing, JSON processing, and middleware:

```nim
{{#shiftinclude auto:../../../examples/http_server/chapter5.nim:all}}
```

## Benchmarking with ApacheBench (ab)

[ApacheBench](https://httpd.apache.org/docs/2.4/programs/ab.html) (`ab`) is a popular tool for benchmarking HTTP servers. It's pre-installed on many systems or can be easily installed (e.g., `brew install httpd` on macOS or `sudo apt-get install apache2-utils` on Linux). For Windows, it can be obtained through various Apache distributions.

### Running the Benchmark

First, compile and run your server in release mode:

```shell
$ nim c -d:release docs/examples/http_server/chapter5.nim
$ ./docs/examples/http_server/chapter5
```

Now, in a separate terminal window, run the benchmark against the root path:

```shell
$ ab -n 10000 -c 100 http://127.0.0.1:8080/
```

Here's what these flags mean:

- `-n 10000`: Perform 10,000 requests.
- `-c 100`: Keep 100 requests concurrent.

### Understanding the Results

When the benchmark finishes, you'll see a report. Pay attention to these metrics:

- **Requests per second (RPS):** How many requests your server processed per second. Even with the overhead of JSON parsing and logging, Chronos should achieve very high numbers.
- **Time per request:** The average time it took to complete a single request.
- **Failed requests:** How many requests were not successful. With Chronos, this should be zero even under high load.

## Why Chronos is Efficient

- **Non-blocking I/O:** Chronos never blocks a thread while waiting for a response from the network. Instead, it uses the OS's event notification system (like epoll on Linux or kqueue on macOS) to handle thousands of connections simultaneously.
- **Zero-overhead concurrency:** Unlike threads or processes, which have significant memory and context-switching overhead, Chronos's tasks are lightweight and managed entirely in user space.
- **Memory Efficiency:** Chronos is designed to be very careful with memory allocations, making it suitable for high-throughput applications.

By using Chronos, you can build servers that are both fast and stable, even on modest hardware, without the complexity of managing thread pools or multi-process architectures.
