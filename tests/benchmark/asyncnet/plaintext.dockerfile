FROM statusteam/nim-base
WORKDIR /server
COPY server.nim server.nim
RUN nim c -d:release server.nim
CMD ["./server"]
