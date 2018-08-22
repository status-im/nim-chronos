FROM statusteam/nim-base
RUN nimble install -y mofuw packedjson
WORKDIR /mofuwApp
COPY server.nim server.nim
RUN nim c -d:release --threads:on -d:bufSize:512 server.nim
CMD ["./server"]
