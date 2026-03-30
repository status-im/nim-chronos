# Bonus Track - Performance and Benchmarking

**Goal:** Understand how Chronos performs under load and learn how to benchmark your server. 

**Source code:** [chapter4/src/dashboard.nim](https://github.com/status-im/nim-chronos/blob/master/docs/examples/http_server/chapter4/src/dashboard.nim)

One of the main reasons to use Chronos is its performance. Thanks to its asynchronous architecture, a single-threaded Chronos server can handle thousands of concurrent connections with minimal overhead.

In this chapter, we'll see check how our app performs under load.

## Benchmarking with ApacheBench (ab)

[ApacheBench](https://httpd.apache.org/docs/2.4/programs/ab.html) (`ab`) is a popular tool for benchmarking HTTP servers. It's pre-installed on many systems or can be easily installed (e.g., `brew install httpd` on macOS or `sudo apt-get install apache2-utils` on Linux). For Windows, it can be obtained through various Apache distributions.

### Running the Benchmark

First, run your server in release mode:

```shell
$ nimble run -d:release
```

```admonish info
There are no code changes in this chapter. We're using the code from the previous chapter, just compiling it in the release mode to squeeze maximum performance from our server.
```

Now, in a separate terminal window, run the benchmark against the root path:

```shell
$ ab -n 10000 -c 100 http://127.0.0.1:8080/
```

Here's what these flags mean:

- `-n 10000`: Perform 10,000 requests.
- `-c 100`: Keep 100 requests concurrent.

### Understanding the Results

When the benchmark finishes, you'll see a report, which looks similar to this:

```shell
Server Software:
Server Hostname:        127.0.0.1
Server Port:            8080

Document Path:          /
Document Length:        32 bytes

Concurrency Level:      100
Time taken for tests:   15.445 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      1670000 bytes
HTML transferred:       320000 bytes
Requests per second:    647.47 [#/sec] (mean)
Time per request:       154.448 [ms] (mean)
Time per request:       1.544 [ms] (mean, across all concurrent requests)
Transfer rate:          105.59 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.3      0       7
Processing:     4  153  19.3    154     209
Waiting:        1  145  18.5    146     199
Total:          5  154  19.3    154     210
ERROR: The median and mean for the initial connection time are more than twice the standard
       deviation apart. These results are NOT reliable.

Percentage of the requests served within a certain time (ms)
  50%    154
  66%    166
  75%    169
  80%    170
  90%    175
  95%    180
  98%    186
  99%    189
 100%    210 (longest request)
```


Pay attention to these metrics:

- **Requests per second (RPS):** How many requests your server processed per second. Even with the overhead of JSON parsing and logging, Chronos should achieve hundreds of RPS even on a common laptop.
- **Time per request:** The average time it took to complete a single reques. You'll see two numbers, one roughly 100 times larger than the other. This is due to the concurrency factor of 100. The smaller number represents the actuall processing time per request. This should be close to 1 ms. 
- **Failed requests:** How many requests were not successful. With Chronos, this should be zero even under high load.
