FROM statusteam/nim-base
RUN nimble install -y https://github.com/status-im/nim-asyncdispatch2
WORKDIR /server
COPY server.nim server.nim
RUN nim c -d:release server.nim
CMD ["./server"]
