// A loopback-only, HTTP/2-only origin used to verify the complete relay path.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	port := flag.Int("port", 41080, "loopback port")
	nonce := flag.String("nonce", "ai-tunnel-verification", "response verification marker")
	duration := flag.Duration("duration", 15*time.Minute, "maximum fixture lifetime")
	flag.Parse()
	protocols := new(http.Protocols)
	protocols.SetUnencryptedHTTP2(true)
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(map[string]any{"nonce": *nonce, "backend_protocol": r.Proto, "method": r.Method})
	})
	mux.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-store")
		for i := 0; i < 3; i++ {
			_, _ = fmt.Fprintf(w, "data: %s %s %d\n\n", *nonce, r.Proto, i)
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			select {
			case <-r.Context().Done():
				return
			case <-time.After(300 * time.Millisecond):
			}
		}
	})
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	server := &http.Server{Handler: mux, Protocols: protocols, ReadHeaderTimeout: 10 * time.Second}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go func() {
		select {
		case <-ctx.Done():
		case <-time.After(*duration):
		}
		stopCtx, stop := context.WithTimeout(context.Background(), 3*time.Second)
		defer stop()
		_ = server.Shutdown(stopCtx)
	}()
	fmt.Println("h2c fixture listening at", listener.Addr())
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
