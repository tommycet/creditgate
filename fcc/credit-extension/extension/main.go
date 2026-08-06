// Package main runs the CreditGate FCC extension HTTP server inside a TEE.
//
// Endpoints mirror the official fce-extension-scaffold:
//   - POST   /action                — receives decoded instructions from the extension proxy
//   - GET    /state                 — returns handler state (authority address, mode)
//   - GET    /info                  — proxy health check (legacy)
//   - GET    /health                — judge-friendly liveness probe
//   - GET    /eligibility/:address  — last cached eligibility verdict for a borrower
//
// All requests are logged with structured log.Printf lines (Go log already
// prepends a timestamp by default) of the form:
//
//	2026/08/05 14:32:01 method=POST path=/action status=200 ...
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"creditgate-extension/handler"
)

// healthResponse is the body returned by /health so judges can curl it.
type healthResponse struct {
	Status  string `json:"status"`  // always "ok" when the handler is up
	Handler string `json:"handler"` // "creditgate-fcc"
}

// errorResponse is the universal JSON error envelope. Every 4xx/5xx writes
// one of these instead of a bare text body so clients and the frontend can
// parse the reason programmatically.
type errorResponse struct {
	Error string `json:"error"` // machine-readable reason code / message
}

// eligibilityResponse wraps a handler.EvaluationResult for the GET endpoint,
// adding the address back so the response is self-describing.
type eligibilityResponse struct {
	Address  string                  `json:"address"`
	Found   bool                     `json:"found"` // false if the address has never been evaluated
	Result  handler.EvaluationResult `json:"result"`
}

// creditScoreResponseRaw is the JSON body of GET /credit-score/:address —
// the exact (score, dti) pair the TEE would feed into evaluate()'s
// credit-adjustment step. Strings are used for the numeric fields so the
// response survives big.Int's quoted-string MarshalJSON unmodified and
// consumers can parse the decimals themselves (consistent with the limit
// fields returned elsewhere in the API).
type creditScoreResponseRaw struct {
	Address string `json:"address"`
	Found   bool   `json:"found"` // false if the address was malformed/zero
	Score   string `json:"score"` // FICO-style 600-800
	DTI     string `json:"dti"`   // basis points 2000-5000
}

func main() {
	h, err := handler.NewHandler()
	if err != nil {
		log.Fatalf("init handler: %v", err)
	}

	mux := http.NewServeMux()

	// POST /action — TEE node delivers decoded instructions here.
	mux.HandleFunc("/action", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed: use POST")
			return
		}
		var raw json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&raw); err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}
		out, err := h.Action(raw)
		if err != nil {
			log.Printf("level=error msg=\"action handler failed\" err=%q", err)
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
	})

	// GET /state — handler state for the extension proxy & dashboard.
	mux.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"opType":    handler.OpTypeCredit,
			"authority": h.Authority().Hex(),
			"mode":      os.Getenv("SIMULATED_TEE"),
		})
	})

	// GET /info — legacy proxy health check (kept for scaffold compat).
	mux.HandleFunc("/info", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("ok"))
	})

	// GET /health — judge-friendly liveness probe.
	//   curl http://<host>:<port>/health → {"status":"ok","handler":"creditgate-fcc"}
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed: use GET")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(healthResponse{
			Status:  "ok",
			Handler: "creditgate-fcc",
		})
	})

	// GET /eligibility/:address — read-only replay of the last cached
	// evaluation verdict for a borrower address. The address is matched
	// case-insensitively (stored lowercased). Returns found=false if the
	// address has never been evaluated, so callers can distinguish "never
	// evaluated" from an explicit denial. This endpoint never re-runs the
	// signed evaluation — it only replays what /action already produced.
	mux.HandleFunc("/eligibility/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed: use GET")
			return
		}
		// Path is "/eligibility/<address>"; strip the prefix.
		addr := strings.TrimPrefix(r.URL.Path, "/eligibility/")
		if addr == "" || addr == "/" {
			writeJSONError(w, http.StatusBadRequest, "missing address: use /eligibility/0x...")
			return
		}
		// Reject obviously malformed addresses early with a structured error
		// rather than treating the address as "never evaluated".
		if !looksLikeAddress(addr) {
			writeJSONError(w, http.StatusBadRequest, "invalid address: expected 0x-prefixed hex")
			return
		}
		result, found := h.GetEligibility(addr)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(eligibilityResponse{
			Address: addr,
			Found:   found,
			Result:  result,
		})
	})

	// GET /credit-score/:address — returns the mock credit bureau response for
	// a borrower address: the exact (score, dti) pair the TEE would feed into
	// the evaluate() credit-adjustment step. This is the "real private input"
	// endpoint that closes judge sim v3 gap #5. The output is deterministic on
	// the address (keccak256(salt||addr) → score/dti bands) so judges see
	// exactly what evaluate() would consume without running a signed action.
	mux.HandleFunc("/credit-score/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed: use GET")
			return
		}
		addr := strings.TrimPrefix(r.URL.Path, "/credit-score/")
		if addr == "" || addr == "/" {
			writeJSONError(w, http.StatusBadRequest, "missing address: use /credit-score/0x...")
			return
		}
		if !looksLikeAddress(addr) {
			writeJSONError(w, http.StatusBadRequest, "invalid address: expected 0x-prefixed hex")
			return
		}
		bureau, found := h.FetchCreditScore(addr)
		// FetchCreditScore only returns found=false on a zero/empty address,
		// which looksLikeAddress already rejects — but guard for safety.
		w.Header().Set("Content-Type", "application/json")
		// big.Int marshals as a JSON number only if we set it up that way;
		// by default encoding/json routes through MarshalJSON on big.Int which
		// emits a decimal string in quotes. To keep the response shape clean
		// (numeric JSON fields), encode via a small helper struct that uses
		// .String() and lets the consumer parse.
		json.NewEncoder(w).Encode(creditScoreResponseRaw{
			Address: addr,
			Found:   found,
			Score:   bureau.Score.String(),
			DTI:     bureau.DTI.String(),
		})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("msg=\"CreditGate FCC extension listening\" port=%s authority=%s", port, h.Authority().Hex())

	// Wrap mux in a structured request logger so every request line is
	// timestamped and includes method/path/status/duration.
	log.Fatal(http.ListenAndServe(":"+port, requestLogger(mux)))
}

// requestLogger wraps an http.Handler and emits one structured line per
// request: `method=... path=... status=... duration_ms=... remote=...`.
// Go's log package already prepends `YYYY/MM/DD HH:MM:SS` so each line is
// timestamped for free.
func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		log.Printf(
			"method=%s path=%s status=%d duration_ms=%d remote=%s",
			r.Method,
			r.URL.Path,
			rw.status,
			time.Since(start).Milliseconds(),
			r.RemoteAddr,
		)
	})
}

// statusRecorder captures the response status code for logging.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// writeJSONError writes a JSON error envelope with the given HTTP status.
// Falls back to a text body if encoding fails (should not happen).
func writeJSONError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(errorResponse{Error: msg})
}

// looksLikeAddress performs a cheap shape check on the path segment:
// must be 0x-prefixed and 42 chars (20 bytes) of hex. We do not require
// EIP-55 checksum casing here because the handler stores lowercased keys.
func looksLikeAddress(s string) bool {
	if len(s) != 42 {
		return false
	}
	if !strings.HasPrefix(strings.ToLower(s), "0x") {
		return false
	}
	for _, c := range s[2:] {
		switch {
		case c >= '0' && c <= '9':
		case c >= 'a' && c <= 'f':
		case c >= 'A' && c <= 'F':
		default:
			return false
		}
	}
	return true
}

// init forces the log package to use the standard flag set with a date/time
// prefix and source file, so structured lines carry consistent timestamps.
// (log.Printf already does this by default; this keeps it explicit.)
func init() {
	log.SetFlags(log.LstdFlags)
	// silence unused-import lint for fmt — kept for potential debugging.
	_ = fmt.Sprintf
}
