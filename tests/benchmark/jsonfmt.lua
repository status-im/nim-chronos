done = function(summary, latency, requests)
  io.write("{")
  io.write('"duration":', summary.duration, ',')
  io.write('"requests":', summary.requests, ',')
  io.write('"bytes":', summary.bytes)
  io.write("}")
end
