// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title CreditGateTypes — Shared types, errors, events, constants for CreditGate
/// @dev Source of truth: planning/agent_02/verdict.md (API), planning/agent_03/verdict.md (impl)
contract CreditGateTypes {
    // ═══════════════════ Constants ═══════════════════

    uint8 public constant FXRP_DECIMALS = 6;
    uint8 public constant USDT0_DECIMALS = 18; // verified on Coston2 2026-08-05
    uint256 public constant FXRP_DECIMALS_FACTOR = 1e6;
    uint256 public constant USDT0_DECIMALS_FACTOR = 1e18;
    uint256 public constant SCALE_TO_18 = 1e12; // 1e18 / 1e6

    /// @notice Annual interest rate in basis points (500 = 5% APR). Simple interest,
    ///         accruing linearly over the loan term.
    uint256 public constant INTEREST_RATE_BPS = 500;

    /// @notice Seconds per year used for the simple-interest proration math.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// XRP/USD FTSOv2 feed ID on Coston2
    bytes21 public constant XRP_USD_FEED_ID =
        0x015852502f55534400000000000000000000000000;

    bytes32 public constant ELIGIBILITY_DOMAIN_SEPARATOR =
        keccak256("CREDITGATE_ELIGIBILITY_V1");

    bytes32 public constant REPAYMENT_PROTOCOL_VERSION =
        keccak256("CreditGateRepayment/v1");

    /// @notice Duration of a Dutch liquidation auction (price decays linearly to zero
    ///         over this window). One hour keeps demo timings tight while leaving
    ///         meaningful decay for bidders.
    uint256 public constant AUCTION_DURATION = 1 hours;

    /// @notice Automated liquidation trigger threshold (Aave-style health factor).
    ///         A FUNDED loan with health factor strictly below this value is
    ///         auto-liquidatable by `checkAndTriggerLiquidation` / the batch keeper.
    ///         `0.9e18` ⇒ undercollateralized below 90% triggers liquidation
    ///         (collateral value < 90% of outstanding debt).
    uint256 public constant LIQUIDATION_THRESHOLD = 0.9e18;

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
        DEFAULTED,              // 8 — repayment deadline expired (terminal)
        AUCTION                 // 9 — Dutch liquidation auction in progress
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
        uint256 attestationLimit;          // F1: max USDT0 from TEE attestation (6 dp)
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

    /// @notice Dutch-auction liquidation state for a defaulted loan.
    /// @dev    Kept in a SEPARATE mapping (`auctions[loanId]`) — never added to the
    ///         already stack-heavy `Loan` struct. This is the fix for the
    ///         "stack too deep" compile error seen in subagent #44.
    struct LiquidationAuction {
        uint256 startPrice;     // USDT0 price at auction start (full collateral value)
        uint64  startTimestamp; // when the auction started
        address highestBidder;  // current highest bidder (address(0) if no bids yet)
        uint256 highestBid;     // current highest bid in USDT0
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

    /// @notice Emitted when interest is computed for a loan (e.g. at repayment).
    /// @dev    `interestAmount` is in the same units as `loanAmount` (USDT0, 18dp).
    event InterestAccrued(uint256 indexed loanId, uint256 interestAmount);

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

    /// @notice Emitted when a Dutch liquidation auction starts for a defaulted loan.
    event LiquidationAuctionStarted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 startPrice,
        uint64  startTimestamp
    );

    /// @notice Emitted on each new highest bid during an active auction.
    event LiquidationBid(
        uint256 indexed loanId,
        address indexed bidder,
        uint256 amount
    );

    /// @notice Emitted when an auction finalizes (with or without a winning bid).
    ///         `winner` is address(0) when no bids were placed; the collateral then
    ///         falls back to the vault owner.
    event AuctionFinalized(
        uint256 indexed loanId,
        address winner,
        uint256 winningBid,
        address borrower
    );

    /// @notice Emitted when the automated liquidation trigger fires for a loan whose
    ///         health factor dropped below `LIQUIDATION_THRESHOLD`. `healthFactor` and
    ///         `price` are both 1e18-scaled (the FTSO feed value at trigger time).
    ///         Emitted BEFORE the `LiquidationAuctionStarted` event for the same loan.
    event LiquidationTriggered(
        uint256 indexed loanId,
        uint256 healthFactor,
        uint256 price
    );

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /// @notice Emitted when an owner updates the LTV (loan-to-value) ratio for a
    ///         collateral token. Both values are in basis points (e.g. 7500 = 75%).
    ///         Added by subagent #55 to support multi-collateral borrowing
    ///         ("borrow stablecoins against XRP" trend, 2026-08-06).
    event LTVUpdated(
        address indexed collateralToken,
        uint256 oldLTV,
        uint256 newLTV
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
    error ExceedsAttestationLimit();

    // ── Auction liquidation errors (added by subagent #45) ──
    error AuctionNotFound();     // no auction has been started for this loan id
    error AuctionExpired();      // the auction window has ended (no further bids)
    error InsufficientBid();      // bid is not higher than the current highest bid
    error NotInAuctionState();   // loan is not currently in the AUCTION state

    // ── LTV configuration errors (added by subagent #55) ──
    error InvalidLTV(uint256 newLTV);          // LTV must be in (0, 10000] bps
    error UnknownCollateral(address token);    // collateral token not registered
}
