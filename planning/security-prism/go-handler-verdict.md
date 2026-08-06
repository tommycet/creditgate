# Go Handler Full-Prism Security Audit

**Scope:** `handler/handler.go` + `main.go` — CreditGate FCC Extension  
**Date:** 2026-08-06  
**Auditor:** Hermes Subagent (Full-Prism Mode)  
**Verdict:** 14 findings across 3 severity tiers

---

## Executive Summary

The Go handler is well-structured for a hackathon demo: inputs are validated with explicit error codes, the EIP-191 signing path correctly mirrors Solidity's `abi.encode`, and the collateral-coverage math avoids floats by design. However, the codebase has **no concurrency protection** on shared mutable maps, a **silent `big.Int.SetString` failure** in config parsing, **logging that leaks internal state**, and several **missing HTTP security hardening** measures. None of these are trivially exploitable in a single-TEE demo, but they would be real vulnerabilities in production.

---

## Findings

### G1 — CRITICAL: No mutex on shared handler maps (concurrency / data race)

**Severity:** Critical  
**Location:** `Handler` struct (fields `limits`, `revoked`, `lastResult`); `storeResult()`, `GetEligibility()`, `evaluate()`, `FetchCreditScore()`, `registerXRPL()`  
**Description:**  
`limits`, `revoked`, and `lastResult` are plain `map[string]...` fields. Multiple concurrent HTTP requests (via `net/http` goroutine-per-request model) call `storeResult()` (write), `GetEligibility()` (read), and `evaluate()` (read on `limits`/`revoked`) simultaneously. Go maps are not safe for concurrent read/write. This is a **data race** that can cause:
- Runtime panics (`concurrent map read and map write`)
- Corrupted map state / lost entries
- Undefined behavior under the Go race detector

In production with the TEE extension proxy, requests arrive concurrently from the Flare FDC relay and from borrower polling.  
**Recommended Fix:**  
Wrap all map accesses in `sync.RWMutex` (or use `sync.Map`):
```go
type Handler struct {
    mu     sync.RWMutex
    // ...
}

func (h *Handler) storeResult(...) {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.lastResult[...] = ...
}

func (h *Handler) GetEligibility(...) {
    h.mu.RLock()
    defer h.mu.RUnlock()
    r, ok := h.lastResult[...]
    return r, ok
}
```

---

### G2 — HIGH: Silent `big.Int.SetString` failure on env config parsing

**Severity:** High  
**Location:** `NewHandler()` — lines 119, 123  
**Description:**  
```go
ratio.SetString(r, 10)   // line 119
xrpPrice.SetString(p, 10) // line 123
```
`SetString` returns `(value, ok)` — if the env var contains an invalid number (e.g. `COLLATERAL_RATIO_BPS=abc` or `XRP_USD_PRICE_18DP=-1`), the `ok` return is `false` and the value is set to zero. The code **discards the `ok` value**, leaving `ratio` or `xrpPrice` at 0. Consequences:
- `collateralRatioBps = 0` → the collateral check becomes trivially satisfiable (any tiny collateral covers any loan), completely disabling the credit guard.
- `xrpUsd18dp = 0` → `collateralUsd` is always 0, so every request is rejected as INSUFFICIENT_COLLATERAL even with adequate collateral.

An operator typo in env vars silently disables the core security invariant.  
**Recommended Fix:**  
Check the `ok` return and abort:
```go
v, ok := new(big.Int).SetString(r, 10)
if !ok || v.Sign() <= 0 {
    return nil, fmt.Errorf("invalid COLLATERAL_RATIO_BPS: %q", r)
}
ratio = v
```

---

### G3 — HIGH: Unbounded request body size (denial of service)

**Severity:** High  
**Location:** `main.go` — POST `/action` handler (line 79)  
**Description:**  
`json.NewDecoder(r.Body).Decode(&raw)` reads the entire request body into memory with no size limit. An attacker can send a multi-gigabyte JSON body and exhaust server memory. The Go `json.Decoder` uses a growing buffer with no cap.  
**Recommended Fix:**  
Wrap the body with `http.MaxBytesReader` before decoding:
```go
r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB limit
```

---

### G4 — HIGH: Private key material could leak via error messages in logging

**Severity:** High  
**Location:** `main.go` — POST `/action` handler (line 85–86); `NewHandler()`  
**Description:**  
When `h.Action(raw)` fails, the error is returned to the client via `writeJSONError` (line 86). Some internal Go errors (e.g., from `crypto.HexToECDSA` during key parse) can contain hex key fragments. More critically, the startup log at `main.go:67` (`log.Fatalf`) will print the full error from `NewHandler()` which could include env parsing details. Additionally, the `requestLogger` logs `r.RemoteAddr` which in a TEE context may reveal the extension proxy IP.

The signing key itself is never logged directly (good), but error propagation paths are unguarded.  
**Recommended Fix:**  
Sanitize internal errors before returning to clients:
```go
// Never leak crypto internals to HTTP responses
log.Printf("level=error msg=%q", err)
writeJSONError(w, http.StatusInternalServerError, "internal error")
```
Never return raw `err.Error()` from crypto operations to HTTP clients.

---

### G5 — MEDIUM: `appendWord` silently truncates oversized words (potential ABI mismatch)

**Severity:** Medium  
**Location:** `appendWord()` — lines 419–426  
**Description:**  
```go
if len(word) > 32 {
    word = word[len(word)-32:]
}
```
If a `big.Int` produces a byte slice > 32 bytes (possible for values ≥ 2^256), `appendWord` silently **truncates the high bytes**. For `domainSeparator`, `borrower`, and `revVersion` this is impossible (bounded sizes). But `limit`, `expiry`, and `nonce` are user-controlled decimal strings parsed via `big.Int.SetString` — a malicious input like `limit = 2^256` would produce a 33-byte slice. The truncation would produce a silently wrong hash, meaning the on-chain `ecrecover` would fail to match, rejecting the attestation. This is a **silent correctness bug** rather than a security exploit (it can't inflate limits, only cause rejections), but it masks the real error.  
**Recommended Fix:**  
Validate or explicitly reject values > 2^256 before signing:
```go
maxUint256 := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
if limit.Cmp(maxUint256) > 0 {
    return nil, fmt.Errorf("limit exceeds uint256 max")
}
```

---

### G6 — MEDIUM: RevocationVersion is hardcoded to 0 — stale attestation risk

**Severity:** Medium  
**Location:** `signAttestation()` — line 371  
**Description:**  
```go
revVersion := big.NewInt(0)
```
The `RevocationVersion` in every signed attestation is always `0`, regardless of what the vault's current revocation version is. If a borrower is revoked (version incremented on-chain), old signed attestations with `revVersion=0` remain valid until expiry unless the vault's `submitEligibility` also checks the version matches. This is a design-level coupling issue: the off-chain handler signs a fixed version and trusts the on-chain contract to reject mismatches. If the vault contract does not check this field, revoked borrowers could replay pre-revocation attestations.  
**Recommended Fix:**  
Fetch the current revocation version from the vault contract (or pass it in the instruction payload) and include it in the attestation. At minimum, document the assumption that the vault enforces version matching.

---

### G7 — MEDIUM: Error responses returned with 400 status for internal errors

**Severity:** Medium  
**Location:** `main.go` — POST `/action` handler (line 86)  
**Description:**  
```go
writeJSONError(w, http.StatusBadRequest, err.Error())
```
When `h.Action(raw)` returns an error from internal operations (e.g., `signAttestation` fails), the HTTP status is `400 Bad Request` — indistinguishable from client input errors. This misleads monitoring and clients. A signing failure is a server-side issue and should be `500`. Additionally, `err.Error()` could leak internal details (see G4).  
**Recommended Fix:**  
Distinguish client errors (bad input) from server errors (signing failure):
```go
if err != nil {
    log.Printf("level=error msg=\"action failed\" err=%q", err)
    writeJSONError(w, http.StatusInternalServerError, "evaluation failed")
    return
}
```

---

### G8 — MEDIUM: No rate limiting on POST `/action`

**Severity:** Medium  
**Location:** `main.go` — POST `/action` handler  
**Description:**  
The `/action` endpoint performs expensive cryptographic operations (EIP-191 signing, `big.Int` arithmetic, mock credit score derivation). Without rate limiting, an attacker can flood the endpoint to exhaust CPU or, combined with G3, memory. In a TEE context this is partially mitigated by the extension proxy, but the proxy itself may not rate-limit.  
**Recommended Fix:**  
Add a simple per-IP token bucket or semaphore:
```go
var actionLimiter = make(chan struct{}, 10) // max 10 concurrent evaluations
```
Or use `golang.org/x/time/rate` for a proper rate limiter.

---

### G9 — MEDIUM: `/state` endpoint leaks `SIMULATED_TEE` env var value

**Severity:** Medium  
**Location:** `main.go` — GET `/state` handler (line 99)  
**Description:**  
```go
"mode": os.Getenv("SIMULATED_TEE"),
```
The raw environment variable value is returned in the HTTP response. If this var contains anything beyond a boolean flag (e.g. accidentally set to a secret or config string), it leaks to any caller. This is a minor information disclosure in demo mode but violates the principle of least privilege.  
**Recommended Fix:**  
Whitelist known values:
```go
mode := "production"
if os.Getenv("SIMULATED_TEE") != "" {
    mode = "simulated_tee"
}
```

---

### G10 — MEDIUM: Signature malleability not explicitly checked

**Severity:** Medium  
**Location:** `signAttestation()` — lines 392–403  
**Description:**  
The `v` value is computed as `sig[64] + 27`. The `crypto.Sign` function from go-ethereum already normalizes `v` to `0/1`, so `v + 27` produces `27/28` — this is correct. However, the `S` value is **not validated against the curve's half-order**. ECDSA signature malleability (EIP-2) allows a second valid `(r, s')` for the same message where `s' = secp256k1.N - s`. While this does not affect the off-chain signing (the vault would accept either form), it means an attacker who observes a valid attestation can compute an alternate `s` and submit it as a different-looking but still valid attestation. The vault's `ecrecover` would still recover the authority address.  
**Recommended Fix:**  
After signing, check `s > secp256k1HalfOrder` and negate if so:
```go
secp256k1N := crypto.S256().Params().N
halfOrder := new(big.Int).Rsh(secp256k1N, 1)
S := new(big.Int).SetBytes(sig[32:64])
if S.Cmp(halfOrder) > 0 {
    S.Sub(secp256k1N, S)
    copy(sig[32:64], S.Bytes())
}
```

---

### G11 — LOW: `storeResult` called inconsistently — skipped for some failure paths

**Severity:** Low  
**Location:** `evaluate()` — lines 210, 213, 219, 222, 226, 230  
**Description:**  
The early-return failure paths (INVALID_BORROWER, BORROWER_REVOKED, etc.) do **not** call `storeResult()`, so `GetEligibility` for those borrowers returns `found=false` (never evaluated) instead of an explicit denial. The `INSUFFICIENT_COLLATERAL` path at line 245 **does** call `storeResult`, creating an inconsistency: some denials are cached and others are not.  
**Recommended Fix:**  
Call `storeResult()` for all denial paths, or document the design decision that only `INSUFFICIENT_COLLATERAL` is cached.

---

### G12 — LOW: No `Content-Security-Policy`, `X-Content-Type-Options`, or `Strict-Transport-Security` headers

**Severity:** Low  
**Location:** `main.go` — all handlers  
**Description:**  
The server does not set any security headers. While this is a TEE-internal service (not browser-facing), the health/state endpoints are accessible to any network client. Missing `X-Content-Type-Options: nosniff` could allow MIME sniffing in browser-adjacent contexts.  
**Recommended Fix:**  
Add a middleware that sets standard security headers:
```go
func securityHeaders(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("X-Content-Type-Options", "nosniff")
        w.Header().Set("X-Frame-Options", "DENY")
        next.ServeHTTP(w, r)
    })
}
```

---

### G13 — LOW: `/info` endpoint returns `Content-Type: application/json` with non-JSON body

**Severity:** Low  
**Location:** `main.go` — GET `/info` handler (lines 104–107)  
**Description:**  
```go
w.Header().Set("Content-Type", "application/json")
w.Write([]byte("ok"))
```
The body is `"ok"` — a bare string, not valid JSON. Clients parsing as JSON will fail. This is legacy scaffold code but could confuse monitoring tools.  
**Recommended Fix:**  
Return `{"status":"ok"}` or change `Content-Type` to `text/plain`.

---

### G14 — LOW: `r.Body` never explicitly closed

**Severity:** Low  
**Location:** `main.go` — POST `/action` handler (line 79)  
**Description:**  
`json.NewDecoder(r.Body).Decode(&raw)` reads the body but never calls `r.Body.Close()`. In Go's `net/http`, the server closes the body after the handler returns, so this is not a resource leak. However, it is a best-practice violation and could cause issues if the handler is ever refactored to return early or run in a goroutine.  
**Recommended Fix:**  
```go
defer r.Body.Close()
```

---

## Summary Table

| ID | Severity | Finding | Function |
|----|----------|---------|----------|
| G1 | **Critical** | Data race on shared maps (no mutex) | `storeResult`, `GetEligibility`, `evaluate`, `FetchCreditScore` |
| G2 | **High** | Silent `SetString` failure → zero collateral ratio disables credit guard | `NewHandler` |
| G3 | **High** | Unbounded request body → OOM DoS | POST `/action` |
| G4 | **High** | Internal errors leaked to HTTP clients | POST `/action` |
| G5 | Medium | `appendWord` silently truncates >256-bit values | `signAttestation` |
| G6 | Medium | RevocationVersion hardcoded to 0 — stale attestation risk | `signAttestation` |
| G7 | Medium | Internal errors returned as 400 instead of 500 | POST `/action` |
| G8 | Medium | No rate limiting on expensive signing endpoint | POST `/action` |
| G9 | Medium | Raw env var leaked in `/state` response | GET `/state` |
| G10 | Medium | ECDSA signature S-value not normalized (malleable) | `signAttestation` |
| G11 | Low | Inconsistent `storeResult` caching on denial paths | `evaluate` |
| G12 | Low | Missing security response headers | All handlers |
| G13 | Low | `/info` returns non-JSON with JSON content-type | GET `/info` |
| G14 | Low | `r.Body` never explicitly closed | POST `/action` |

---

## Positive Observations

1. **Solidity-mirrored math is correct.** The collateral-coverage calculation (`collateral * xrpUsd / 1e18 * 10000 >= requested * ratio`) is consistent with `CreditGateVault.drawLoan()`, using fixed-point integer arithmetic throughout. No floats.

2. **EIP-191 ABI encoding is correct.** The `abi.encode` of `(bytes32, address, uint256, uint64, uint32, uint8)` uses proper 32-byte big-endian word padding via `appendWord`. The domain separator matches `CREDITGATE_ELIGIBILITY_V1`.

3. **Input validation is thorough.** Every field is checked for parseability and sign before use. The zero-address check prevents trivial griefing. The `looksLikeAddress` helper does proper hex validation.

4. **The credit bureau adjustment is safely bounded.** The `factorBps` is capped at 10000 (1.0x), so the TEE can only *reduce* the approved limit relative to the collateral-backed amount — never inflate it.

5. **Error codes are machine-readable.** The `INVALID_BORROWER`, `INSUFFICIENT_COLLATERAL`, etc. reason codes enable the vault frontend to display specific messages without parsing error strings.

6. **Logging is structured.** The `requestLogger` middleware emits method/path/status/duration/remote for every request, which aids debugging without leaking secrets (except the env var issue in G9).

---

## Risk Assessment

| Scenario | Impact | Likelihood |
|----------|--------|------------|
| Attacker sends concurrent requests → map panic | Service crash | Medium (requires >1 req/s) |
| Operator sets malformed `COLLATERAL_RATIO_BPS` → credit guard disabled | All loans approved with minimal collateral | Low (requires misconfig) |
| Attacker sends multi-GB body → OOM | Service crash | Medium (requires direct access) |
| Revoked borrower replays old attestation | Credit issued to revoked borrower | Low (depends on vault contract) |
| Malleable S-value → duplicate attestation submission | On-chain state corruption | Low (requires vault contract bug) |

---

*End of full-prism audit.*
