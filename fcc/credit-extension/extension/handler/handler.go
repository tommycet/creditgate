// Package handler implements the CreditGate Flare Compute Extension (FCE).
//
// This is the offchain half of the CreditGate confidential credit pipeline.
// Per the FCC architecture (https://dev.flare.network/fcc/overview), a Flare
// Compute Extension is a Go HTTP server running inside a TEE machine:
//
//   - The TEE node delivers instructions from the extension proxy to our
//     POST /action handler.
//   - We evaluate private credit inputs (borrower, collateral, requested loan)
//     against eligibility rules, then sign an EIP-191 eligibility attestation.
//   - The signature is returned through the proxy; the borrower submits it to
//     CreditGateVault.submitEligibility(), which verifies it against the
//     registered TEE authority address.
//
// Mode: SIMULATED_TEE — in the hackathon demo the signing key is a test ECDSA
// key matching the vault's TEE_AUTHORITY. In production the key is generated
// and held inside the TEE (see FCC Private Key Extension pattern).
package handler

import (
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// OPType / OPCommand constants — must match the Solidity InstructionSender.
const (
	OpTypeCredit       = "CREDIT"
	OpCommandEvaluate  = "EVALUATE"
	OpCommandRegister  = "REGISTER_XRPL"
)

// EvaluationInput is the ABI-decoded instruction payload from the
// CreditGateInstructionSender contract.
type EvaluationInput struct {
	OpCommand        string `json:"opCommand"`
	Borrower         string `json:"borrower"`         // EVM address (hex)
	CollateralAmount string `json:"collateralAmount"` // FXRP 6dp as decimal string
	RequestedLoan    string `json:"requestedLoan"`    // USDT0 6dp as decimal string
	Expiry           string `json:"expiry"`           // UNIX seconds
	Nonce            string `json:"nonce"`            // eligibility nonce
	RevocationVersion string `json:"revocationVersion"` // current revocation version
	XrplAddress      string `json:"xrplAddress"`      // optional, for REGISTER_XRPL
}

// EvaluationResult is returned to the proxy; the borrower polls it.
type EvaluationResult struct {
	Eligible    bool   `json:"eligible"`
	Limit       string `json:"limit"` // approved USDT0 6dp
	Reason      string `json:"reason"`
	Attestation *Attestation `json:"attestation,omitempty"`
}

// Attestation matches CreditGateTypes.EligibilityAttestation (EIP-191).
type Attestation struct {
	Borrower          string `json:"borrower"`
	Limit             string `json:"limit"`
	Expiry            string `json:"expiry"`
	Nonce             string `json:"nonce"`
	RevocationVersion string `json:"revocationVersion"`
	V                 uint8  `json:"v"`
	R                 string `json:"r"`
	S                 string `json:"s"`
}

// domainSeparator must equal CreditGateTypes.ELIGIBILITY_DOMAIN_SEPARATOR.
var domainSeparator = crypto.Keccak256Hash([]byte("CREDITGATE_ELIGIBILITY_V1"))

// Handler evaluates credit instructions.
type Handler struct {
	signingKey    *ecdsa.PrivateKey
	authorityAddr common.Address
	collateralRatioBps *big.Int // e.g. 15000
	xrpUsd18dp    *big.Int // XRP/USD in 18 decimals (e.g. 2.5e18)
	// Simulated borrower limits; in production the TEE holds private data.
	limits map[string]*big.Int
	revoked map[string]bool
	// lastAttestation stores the most recent EvaluationResult per borrower
	// (lowercase address) so /eligibility/:address can serve it without
	// re-running the full evaluation. In production this lives in TEE storage;
	// here it is in-memory and reset on restart.
	lastResult map[string]EvaluationResult
}

// NewHandler loads the signing key from env (SIMULATED_TEE) and builds the handler.
func NewHandler() (*Handler, error) {
	keyHex := os.Getenv("CREDITGATE_SIGNING_KEY")
	if keyHex == "" {
		return nil, fmt.Errorf("CREDITGATE_SIGNING_KEY not set")
	}
	key, err := crypto.HexToECDSA(strings.TrimPrefix(keyHex, "0x"))
	if err != nil {
		return nil, fmt.Errorf("parse signing key: %w", err)
	}
	ratio := big.NewInt(15000)
	if r := os.Getenv("COLLATERAL_RATIO_BPS"); r != "" {
		ratio.SetString(r, 10)
	}
	xrpPrice := new(big.Int).SetUint64(2500000000000000000) // default 2.50 USD
	if p := os.Getenv("XRP_USD_PRICE_18DP"); p != "" {
		xrpPrice.SetString(p, 10)
	}
	return &Handler{
		signingKey:        key,
		authorityAddr:     crypto.PubkeyToAddress(key.PublicKey),
		collateralRatioBps: ratio,
		xrpUsd18dp:        xrpPrice,
		limits:            map[string]*big.Int{},
		revoked:           map[string]bool{},
		lastResult:        map[string]EvaluationResult{},
	}, nil
}

// Action handles POST /action instructions from the TEE node.
func (h *Handler) Action(raw json.RawMessage) (json.RawMessage, error) {
	var in EvaluationInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, fmt.Errorf("decode instruction: %w", err)
	}

	switch in.OpCommand {
	case OpCommandEvaluate:
		return h.evaluate(in)
	case OpCommandRegister:
		return h.registerXRPL(in)
	default:
		return nil, fmt.Errorf("unsupported op command: %s", in.OpCommand)
	}
}

// evaluate runs the private credit check and signs the attestation.
//
// ── EVALUATION CRITERIA ──────────────────────────────────────────────
// A borrower is eligible iff ALL of the following hold. Each failure
// short-circuits with a machine-readable reason code that the vault
// frontend can surface and the on-chain submitEligibility() check can
// reject independently (defense in depth).
//
//  1. ADDRESS VALIDATION
//     `borrower` must decode to a non-zero EVM address. Zero-address
//     (0x0...0) and unparseable hex both short-circuit → INVALID_BORROWER.
//     This blocks trivial griefing where a caller submits an empty address
//     to harvest a signed (but unusable) attestation.
//
//  2. REVOCATION CHECK
//     If the borrower's address is in the TEE-held revoked set, the
//     evaluation short-circuits → BORROWER_REVOKED. Survival of the
//     fittest: defaulted or KYC-revoked accounts can never obtain a new
//     signed attestation, regardless of collateral posted.
//
//  3. INPUT SANITY (decimal-string → big.Int)
//     `collateralAmount`, `requestedLoan`, `expiry`, `nonce` must all
//     parse as base-10 integers. Collateral and loan must be strictly
//     positive (> 0). Expiry and nonce only require parseability; the
//     vault enforces the expiry deadline and nonce uniqueness onchain.
//     → INVALID_COLLATERAL / INVALID_LOAN / INVALID_EXPIRY / INVALID_NONCE.
//
//  4. COLLATERAL COVERAGE RATIO (the core credit rule)
//     Mirrors CreditGateVault.drawLoan() exactly so the TEE attestation
//     can never approve something the vault would revert:
//
//       collateralUsd18 = collateral(6dp) * 1e12 * xrpUsd18dp(18dp) / 1e18
//       require collateralUsd18 * 10000 >= loanUsd18 * collateralRatioBps
//
//     With the defaults (xrpUsd=$2.50, ratio=150% i.e. 15000 bps) a
//     borrower asking for 1,000 USDT0 needs ≥ 600 FXRP posted. Falling
//     short → INSUFFICIENT_COLLATERAL. The 10K factor and 1e18 division
//     keep everything in 18dp fixed-point without floats.
//
//  5. AMOUNT CAP (borrower-specific limit)
//     The approved `limit` is min(requestedLoan, borrowerLimit). The
//     borrower limit is a per-account ceiling held privately in the TEE
//     (simulated via the in-memory `limits` map, settable by an operator
//     -- in production this is KYC/AML-driven private data). If no cap is
//     set for the account, the full requested amount is approved. The
//     signed attestation therefore never exceeds either the request or
//     the account cap, so the vault's limit check is always satisfiable.
//
// On success a signed EIP-191 attestation is produced (see signAttestation)
// and returned together with the approved limit. The vault re-verifies
// both the signature and the coverage ratio on-chain, so a malicious or
// compromised TEE cannot inflate limits past the ratio — it can only
// under-sign, which the borrower simply rejects.
// ──────────────────────────────────────────────────────────────────────
func (h *Handler) evaluate(in EvaluationInput) (json.RawMessage, error) {
	borrower := common.HexToAddress(in.Borrower)
	if borrower == (common.Address{}) {
		return h.result(false, "0", "INVALID_BORROWER", nil)
	}
	if h.revoked[strings.ToLower(in.Borrower)] {
		return h.result(false, "0", "BORROWER_REVOKED", nil)
	}

	collateral, ok := new(big.Int).SetString(in.CollateralAmount, 10)
	if !ok || collateral.Sign() <= 0 {
		return h.result(false, "0", "INVALID_COLLATERAL", nil)
	}
	requested, ok := new(big.Int).SetString(in.RequestedLoan, 10)
	if !ok || requested.Sign() <= 0 {
		return h.result(false, "0", "INVALID_LOAN", nil)
	}
	expiry, ok := new(big.Int).SetString(in.Expiry, 10)
	if !ok {
		return h.result(false, "0", "INVALID_EXPIRY", nil)
	}
	nonce, ok := new(big.Int).SetString(in.Nonce, 10)
	if !ok {
		return h.result(false, "0", "INVALID_NONCE", nil)
	}

	// ── Collateral sufficiency (mirrors vault logic) ──
	// Vault (drawLoan):
	//   collateralUsd18 = collateral(6dp) * 1e12 * xrpUsd18dp / 1e18
	//   require collateralUsd18 * 10000 >= loanUsd18(6dp*1e12) * collateralRatioBps
	// Cancelling 1e12: collateral * xrpUsd18dp / 1e18 * 10000 >= requested * ratio
	tenK := big.NewInt(10000)
	oneE18 := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	collateralUsd := new(big.Int).Mul(collateral, h.xrpUsd18dp) // collateral * price
	collateralUsd.Div(collateralUsd, oneE18)
	collateralUsd.Mul(collateralUsd, tenK)
	required := new(big.Int).Mul(requested, h.collateralRatioBps)
	if collateralUsd.Cmp(required) < 0 {
		h.storeResult(in.Borrower, false, "0", "INSUFFICIENT_COLLATERAL", nil)
		return h.result(false, "0", "INSUFFICIENT_COLLATERAL", nil)
	}

	// ── Approved limit: min(requested, borrower limit) ──
	limit := requested
	if lim, ok := h.limits[strings.ToLower(in.Borrower)]; ok && lim.Cmp(limit) < 0 {
		limit = lim
	}

	att, err := h.signAttestation(borrower, limit, expiry, nonce)
	if err != nil {
		return nil, fmt.Errorf("sign attestation: %w", err)
	}
	h.storeResult(in.Borrower, true, limit.String(), "", att)
	return h.result(true, limit.String(), "", att)
}

// storeResult snapshots the most recent evaluation result for a borrower
// so the read-only /eligibility/:address endpoint can replay it without
// re-running the (signed) evaluation.
func (h *Handler) storeResult(borrower string, eligible bool, limit, reason string, att *Attestation) {
	h.lastResult[strings.ToLower(borrower)] = EvaluationResult{
		Eligible:    eligible,
		Limit:       limit,
		Reason:      reason,
		Attestation: att,
	}
}

// GetEligibility returns the last cached evaluation result for an address.
// Returns (result, true) if an evaluation has run for this address, or
// (zero, false) if the address has never been evaluated. Callers should
// surface the "never evaluated" case distinctly from an explicit denial.
func (h *Handler) GetEligibility(borrower string) (EvaluationResult, bool) {
	r, ok := h.lastResult[strings.ToLower(borrower)]
	return r, ok
}

// registerXRPL records the borrower's XRPL address inside the TEE (simulated).
func (h *Handler) registerXRPL(in EvaluationInput) (json.RawMessage, error) {
	if in.XrplAddress == "" {
		return h.result(false, "0", "INVALID_XRPL_ADDRESS", nil)
	}
	// In production, store inside the enclave. For the demo we just acknowledge.
	return json.Marshal(map[string]any{"ok": true, "xrplAddress": in.XrplAddress})
}

// signAttestation produces the EIP-191 signature the vault verifies:
//
//	payloadHash = keccak256(abi.encode(DOMAIN, borrower, limit, expiry, nonce, revocationVersion))
//	ethSigned   = keccak256("\x19Ethereum Signed Message:\n32" || payloadHash)
func (h *Handler) signAttestation(borrower common.Address, limit, expiry, nonce *big.Int) (*Attestation, error) {
	revVersion := big.NewInt(0)

	// abi.encode of (bytes32, address, uint256, uint64, uint32, uint8)
	// — mirror Solidity's abi.encode exactly (32-byte slots).
	payload := make([]byte, 0, 192)
	payload = appendWord(payload, domainSeparator.Bytes())
	payload = appendWord(payload, common.LeftPadBytes(borrower.Bytes(), 32))
	payload = appendWord(payload, common.LeftPadBytes(limit.Bytes(), 32))
	payload = appendWord(payload, common.LeftPadBytes(expiry.Bytes(), 32))
	payload = appendWord(payload, common.LeftPadBytes(nonce.Bytes(), 32))
	payload = appendWord(payload, common.LeftPadBytes(revVersion.Bytes(), 32))

	payloadHash := crypto.Keccak256Hash(payload)
	prefix := []byte("\x19Ethereum Signed Message:\n32")
	ethSigned := crypto.Keccak256Hash(append(prefix, payloadHash.Bytes()...))

	sig, err := crypto.Sign(ethSigned.Bytes(), h.signingKey)
	if err != nil {
		return nil, err
	}
	// crypto.Sign returns [r || s || v] with v already 0/1; EIP-191 wants 27/28.
	v := sig[64] + 27

	return &Attestation{
		Borrower:          borrower.Hex(),
		Limit:             limit.String(),
		Expiry:            expiry.String(),
		Nonce:             nonce.String(),
		RevocationVersion: revVersion.String(),
		V:                 v,
		R:                 hex.EncodeToString(sig[:32]),
		S:                 hex.EncodeToString(sig[32:64]),
	}, nil
}

func (h *Handler) result(eligible bool, limit, reason string, att *Attestation) (json.RawMessage, error) {
	return json.Marshal(EvaluationResult{
		Eligible:    eligible,
		Limit:       limit,
		Reason:      reason,
		Attestation: att,
	})
}

// Authority returns the signing authority address (matches vault.teeAuthority()).
func (h *Handler) Authority() common.Address { return h.authorityAddr }

// appendWord appends a 32-byte big-endian word.
func appendWord(dst, word []byte) []byte {
	if len(word) > 32 {
		word = word[len(word)-32:]
	}
	out := make([]byte, 32)
	copy(out[32-len(word):], word)
	return append(dst, out...)
}
