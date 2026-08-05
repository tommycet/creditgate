// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title CreditGateTypes — Shared types, errors, events, constants for CreditGate
/// @dev Source of truth: planning/agent_02/verdict.md (API), planning/agent_03/verdict.md (impl)
contract CreditGateTypes {
    // ═══════════════════ Constants ═══════════════════

    uint8 public constant FXRP_DECIMALS = 6;
    uint8 public constant USDT0_DECIMALS = 6;
    uint256 public constant FXRP_DECIMALS_FACTOR = 1e6;
    uint256 public constant USDT0_DECIMALS_FACTOR = 1e6;
    uint256 public constant SCALE_TO_18 = 1e12; // 1e18 / 1e6

    /// XRP/USD FTSOv2 feed ID on Coston2
    bytes21 public constant XRP_USD_FEED_ID =
        0x015852502f55534400000000000000000000000000;

    bytes32 public constant ELIGIBILITY_DOMAIN_SEPARATOR =
        keccak256("CREDITGATE_ELIGIBILITY_V1");

    bytes32 public constant REPAYMENT_PROTOCOL_VERSION =
        keccak256("CreditGateRepayment/v1");

    // ═══════════════════ Enums ═══════════════════

    enum LoanState {
        IDLE,                   // 0 — no collateral deposited
        COLLATERAL_DEPOSITED,   // 1 — FXRP deposited, awaiting eligibility
        ELIGIBILITY_PENDING,    // 2 — FCC instruction emitted, awaiting attestation
        ELIGIBLE,               // 3 — valid TEE attestation received
        FUNDED,                 // 4 — USDT0 drawn against collateral
        REPAYMENT_PENDING,      // 5 — repayment expected
        CLOSED,                 // 6 — FDC proof verified, collateral released
        REJECTED,               // 7 — eligibility rejected (terminal)
        DEFAULTED               // 8 — repayment deadline expired (terminal)
    }

    // ═══════════════════ Structs ═══════════════════

    struct Loan {
        address borrower;
        uint256 collateralAmount;          // FXRP deposited (6 decimals)
        uint256 loanAmount;                // USDT0 borrowed (6 decimals)
        uint256 requiredRepaymentDrops;    // XRP drops to repay on XRPL
        uint256 deadline;                  // UNIX timestamp: liquidation allowed after
        uint64  eligibilityExpiry;         // UNIX: attestation must be fresh
        uint32  eligibilityNonce;          // Monotonic nonce per borrower
        bytes32 expectedCommitment;        // keccak256 commitment for FDC memo binding
        LoanState state;
        bytes32 borrowerSourceAddressHash; // keccak256(bytes(borrowerXRPLAddress))
    }

    struct EligibilityAttestation {
        address borrower;          // Target borrower
        uint256 limit;             // Max USDT0 loan (6 decimals)
        uint64  expiry;            // UNIX: attestation expires after this
        uint32  nonce;             // Must match loan's eligibilityNonce
        uint8   revocationVersion; // Must be > borrowerRevocationVersion[borrower]
        uint8   v;                 // ECDSA recovery id
        bytes32 r;                 // ECDSA r
        bytes32 s;                 // ECDSA s
    }

    // ═══════════════════ Events ═══════════════════

    event CollateralDeposited(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount
    );

    event EligibilityRequested(
        uint256 indexed loanId,
        address indexed borrower
    );

    event EligibilitySubmitted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 limit,
        uint64  expiry
    );

    event EligibilityRejected(
        uint256 indexed loanId,
        address indexed borrower,
        uint8 reason  // 0=STALE, 1=REVOKED, 2=INVALID_SIGNER,
                      // 3=WRONG_BORROWER, 4=NONCE_MISMATCH
    );

    event LoanFunded(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 loanAmount,
        uint256 collateralAmount,
        bytes32 expectedCommitment
    );

    event RepaymentProofSubmitted(
        uint256 indexed loanId,
        bytes32 indexed proofHash,
        int256  receivedDrops
    );

    event LoanClosed(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 collateralReleased
    );

    event LoanDefaulted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 collateralSeized
    );

    event CollateralRecovered(
        uint256 indexed loanId,
        address indexed owner,
        uint256 amount
    );

    // ═══════════════════ Custom Errors ═══════════════════

    error ZeroAmount();
    error InvalidLoanState(LoanState current, LoanState expected);
    error InsufficientCollateral(uint256 collateralValueBps, uint256 requiredBps);
    error FTSOPriceStale(uint64 feedTimestamp, uint64 stalenessLimit);
    error FTSOPriceZero();
    error EligibilityExpired(uint64 expiry, uint64 now_);
    error EligibilityNotYetValid(uint64 notBefore, uint64 now_);
    error NonceMismatch(uint32 expected, uint32 provided);
    error RevocationVersionInsufficient(uint8 current, uint8 provided);
    error InvalidEligibilitySigner(address recovered, address expected);
    error BorrowerMismatch(address expected, address provided);
    error CommitmentMismatch(bytes32 expected, bytes32 provided);
    error MemoDataMissing();
    error MemoDataWrongLength(uint256 length, uint256 expected);
    error PaymentFailed(uint8 status);
    error InsufficientRepayment(int256 received, uint256 required);
    error ProofAlreadyConsumed();
    error FDCVerificationFailed();
    error DeadlineNotPassed();
    error XRPLAddressNotRegistered();
    error RepaymentReceiverMismatch(bytes32 expected, bytes32 provided);
}
