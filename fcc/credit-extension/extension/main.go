// Package main runs the CreditGate FCC extension HTTP server inside a TEE.
//
// Endpoints mirror the official fce-extension-scaffold:
//   - POST /action  — receives decoded instructions from the extension proxy
//   - GET  /state   — returns handler state (authority address, mode)
//   - GET  /info    — proxy health check
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"

	"creditgate-extension/handler"
)

func main() {
	h, err := handler.NewHandler()
	if err != nil {
		log.Fatalf("init handler: %v", err)
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/action", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var raw json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
			http.Error(w, "invalid json", http.StatusBadRequest)
			return
		}
		out, err := h.Action(raw)
		if err != nil {
			log.Printf("action error: %v", err)
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
	})

	mux.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"opType":    handler.OpTypeCredit,
			"authority": h.Authority().Hex(),
			"mode":      os.Getenv("SIMULATED_TEE"),
		})
	})

	mux.HandleFunc("/info", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("CreditGate FCC extension listening on :%s", port)
	log.Printf("Authority: %s", h.Authority().Hex())
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
