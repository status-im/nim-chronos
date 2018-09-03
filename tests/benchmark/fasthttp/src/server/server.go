package main

import (
	"flag"
	"log"
	"github.com/valyala/fasthttp"
	"common"
  "runtime"
)

func main() {
  runtime.GOMAXPROCS(1)
	flag.Parse()

	var err error

	s := &fasthttp.Server{
		Handler: mainHandler,
		Name:    "go",
	}
	ln := common.GetListener()
	if err = s.Serve(ln); err != nil {
		log.Fatalf("Error when serving incoming connections: %s", err)
	}
}

func mainHandler(ctx *fasthttp.RequestCtx) {
	path := ctx.Path()
	switch string(path) {
	case "/plaintext":
		common.PlaintextHandler(ctx)
	case "/json":
		common.JSONHandler(ctx)
	default:
		ctx.Error("unexpected path", fasthttp.StatusBadRequest)
	}
}

