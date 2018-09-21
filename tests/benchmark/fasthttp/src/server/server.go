package main

import (
	"os"
  "flag"
	"log"
	"github.com/valyala/fasthttp"
  "runtime"
  "net"
)

func main() {
  if os.Getenv("USE_THREADS") == "" {
    runtime.GOMAXPROCS(1)
  }

	flag.Parse()

	var err error

	s := &fasthttp.Server{
		Handler: mainHandler,
		Name:    "go",
	}
	ln := GetListener()
	if err = s.Serve(ln); err != nil {
		log.Fatalf("Error when serving incoming connections: %s", err)
	}
}

func mainHandler(ctx *fasthttp.RequestCtx) {
	path := ctx.Path()
	switch string(path) {
	case "/plaintext":
		PlaintextHandler(ctx)
	default:
		ctx.Error("unexpected path", fasthttp.StatusBadRequest)
	}
}

var listenAddr = flag.String("listenAddr", ":8080", "Address to listen to")

func PlaintextHandler(ctx *fasthttp.RequestCtx) {
	ctx.SetContentType("text/plain")
	ctx.WriteString("Hello, World!")
}

func GetListener() net.Listener {
	ln, err := net.Listen("tcp4", *listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	return ln
}
