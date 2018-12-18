init = function(args)
  local r = {}
  local depth = tonumber(args[1]) or 1
  for i=1,depth do
    r[i] = wrk.format()
  end
  req = table.concat(r)
end

request = function()
  return req
end

done = function(summary, latency, requests)
  io.write("{")
  io.write('"duration":', summary.duration, ',')
  io.write('"requests":', summary.requests, ',')
  io.write('"bytes":', summary.bytes)
  io.write("}")
end
