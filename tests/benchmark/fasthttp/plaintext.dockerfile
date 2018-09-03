FROM golang:1.10.1

ADD ./ /fasthttp
WORKDIR /fasthttp

RUN mkdir bin
ENV GOPATH /fasthttp
ENV PATH ${GOPATH}/bin:${PATH}

RUN rm -rf ./pkg/*
RUN go get -d -u github.com/valyala/fasthttp/...

RUN rm -f ./server
RUN go build -gcflags='-l=4' server

CMD GOMAXPROCS=1 ./server
