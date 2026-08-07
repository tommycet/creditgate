// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title CreditGateTypes — Shared types, errors, events, constants for CreditGate
/// @dev Source of truth: planning/agent_02/verdict.md (API), planning/agent_03/verdict.md (impl)
contract CreditGateTypes {
    // ═══════════════════ Constants ═══════════════════

    /// @notice Decimal precision of the FXRP collateral token (6 decimals).
    uint8 public constant FXRP_DECIMALS = 6;
    /// @notice Decimal precision of the USDT0 loan token (18 decimals; verified on Coston2 2026-08-05).
    uint8 public constant USDT0_DECIMALS = 18;
    /// @notice 10**FXRP_DECIMALS, used as the 6-decimal collateral unit factor.
    uint256 public constant FXRP_DECIMALS_FACTOR = 1e6;
    /// @notice 10**USDT0_DECIMALS, used as the 18-decimal loan unit factor.
    uint256 public constant USDT0_DECIMALS_FACTOR = 1e18;
    /// @notice Multiplier that normalises a 6-decimal FXRP amount to the 18-decimal
    ///         (USDT0/USD) basis used throughout the vault: `1e18 / 1e6 = 1e12`.
    /// @dev    Kept for legacy compatibility; the runtime scale factor is now derived
    ///         per-token from `collateralDecimals[token]` via `_collateralScaleFactor`.
    uint256 public constant SCALE_TO_18 = 1e12;

    /// @notice Annual interest rate in basis points (500 = 5% APR). Simple interest,
    ///         accruing linearly over the loan term.
    uint256 public constant INTEREST_RATE_BPS = 500;

    /// @notice Seconds per year used for the simple-interest proration math.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice FTSOv2 feed id for the XRP/USD price on Coston2, used for collateral
    ///         valuation and liquidation triggers. The value is the 21-byte FTSOv2
    ///         feed id (ASCII "XRP/USD" zero-padded).
    bytes21 public constant XRP_USD_FEED_ID =
        0x015852502f55534400000000000000000000000000;

    /// @notice EIP-712-style domain separator mixed into the eligibility
    ///         attestation payload hash, binding attestations to this protocol
    ///         version so a signature from another deployment can't be replayed.
    bytes32 public constant ELIGIBILITY_DOMAIN_SEPARATOR =
        keccak256("CREDITGATE_ELIGIBILITY_V1");

    /// @notice Protocol-version tag mixed into the FDC repayment memo commitment
    ///         so a memo commitment from one protocol version can't be replayed
    ///         against another. Bumped on any breaking change to the commitment
    ///         encoding.
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
        uint256 loanAmount;                // USDT0 borrowed (18 decimals)
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
        uint256 limit;             // Max USDT0 loan (18 decimals)
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

    /// @notice Emitted when a borrower deposits FXRP collateral, creating a new
    ///         loan slot in the `COLLATERAL_DEPOSITED` state.
    event CollateralDeposited(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 amount
    );

    /// @notice Emitted when a borrower requests a TEE eligibility attestation for a
    ///         deposited loan, advancing it to `ELIGIBILITY_PENDING`.
    event EligibilityRequested(
        uint256 indexed loanId,
        address indexed borrower
    );

    /// @notice Emitted once a TEE-signed eligibility attestation is verified and the
    ///         loan advances to `ELIGIBLE`. Carries the approved loan limit and expiry.
    event EligibilitySubmitted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 limit,
        uint64  expiry
    );

    /// @notice Emitted when an eligibility submission is rejected. The `reason` code
    ///         identifies the failing check: 0=STALE, 1=REVOKED, 2=INVALID_SIGNER,
    ///         3=WRONG_BORROWER, 4=NONCE_MISMATCH.
    event EligibilityRejected(
        uint256 indexed loanId,
        address indexed borrower,
        uint8 reason
    );

    /// @notice Emitted when a borrower draws a USDT0 loan against eligible collateral,
    ///         moving the loan to `FUNDED`. Includes the memo commitment the borrower
    ///         must echo back on XRPL repayment.
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

    /// @notice Emitted when an FDC-verified XRPL repayment proof is submitted for a
    ///         funded loan. `proofHash` is the keccak256 of the proof (used for
    ///         anti-replay) and `receivedDrops` is the on-XRPL received XRP amount.
    event RepaymentProofSubmitted(
        uint256 indexed loanId,
        bytes32 indexed proofHash,
        int256  receivedDrops
    );

    /// @notice Emitted when a loan is closed — either by repayment proof verification
    ///         or by an early collateral withdrawal — and FXRP is released to the
    ///         borrower. `collateralReleased` is the FXRP amount returned (6 decimals).
    event LoanClosed(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 collateralReleased
    );

    /// @notice Emitted when a funded loan's repayment deadline passes and the FXRP
    ///         collateral is seized by the vault, transitioning the loan to
    ///         `DEFAULTED`. `collateralSeized` is locked until
    ///         `recoverDefaultedCollateral` is called.
    event LoanDefaulted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 collateralSeized
    );

    /// @notice Emitted when the owner recovers FXRP from a defaulted loan via
    ///         `recoverDefaultedCollateral`. The collateral is sent to `owner`.
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

    /// @notice Emitted on ownership transfer (including the initial deploy, where
    ///         `previousOwner` is address(0)). Mirrors Ownable's OwnershipTransferred.
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

    // ── Protocol reserve events (Aave Safety Module pattern) ──
    /// @notice Emitted when a protocol reserve fee is deducted from collateral
    ///         released on a successful repayment. `fee` is in FXRP (6 decimals).
    event ProtocolReserveFee(uint256 indexed loanId, uint256 fee);

    /// @notice Emitted when the owner withdraws accumulated protocol reserve FXRP.
    event ReserveWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when the owner updates the protocol reserve fee rate.
    event ReserveBpsUpdated(uint256 oldBps, uint256 newBps);

    // ═══════════════════ Custom Errors ═══════════════════

    /// @dev Reverts when a zero amount is passed where a positive amount is required
    ///      (e.g. `depositCollateral(0)` or `drawLoan(_, 0)`).
    error ZeroAmount();
    /// @dev Reverts when a loan is not in the `expected` state for the operation.
    ///      `current` is the loan's actual state at call time.
    error InvalidLoanState(LoanState current, LoanState expected);
    /// @dev Reverts when collateral value (or an LTV-capped value) is below the
    ///      required basis-point threshold. `collateralValueBps` /
    ///      `requiredBps` carry the failing comparison operands.
    error InsufficientCollateral(uint256 collateralValueBps, uint256 requiredBps);
    /// @dev Reverts when the FTSOv2 feed timestamp is older than `ftsoStalenessLimit`
    ///      at draw / liquidation time, to avoid acting on a stale price.
    error FTSOPriceStale(uint64 feedTimestamp, uint64 stalenessLimit);
    /// @dev Reverts when FTSOv2 returns a zero XRP/USD price (dead or missing feed).
    error FTSOPriceZero();
    /// @dev Reverts at eligibility submission / draw when the attestation `expiry`
    ///      is already in the past as of `now_` (i.e. `block.timestamp`).
    error EligibilityExpired(uint64 expiry, uint64 now_);
    /// @dev Reverts when an attestation is presented before its `notBefore` window
    ///      has opened (reserved for future use; not currently emitted).
    error EligibilityNotYetValid(uint64 notBefore, uint64 now_);
    /// @dev Reverts when the attestation's `nonce` doesn't match the loan's
    ///      snapshotted `eligibilityNonce`, which would mean the attestation was
    ///      issued against a stale nonce (e.g. after a revocation rotation).
    error NonceMismatch(uint32 expected, uint32 provided);
    /// @dev Reverts when the borrower's eligibility has been revoked and the
    ///      attestation's `revocationVersion` is not strictly greater than the
    ///      last-applied version, i.e. the attestation predates the revocation.
    error RevocationVersionInsufficient(uint8 current, uint8 provided);
    /// @dev Reverts when the EIP-191 `ecrecover` of the attestation signature either
    ///      failed (returned address(0)) or did not match `teeAuthority`.
    error InvalidEligibilitySigner(address recovered, address expected);
    /// @dev Reverts when the attestation's `borrower` field does not match the loan's
    ///      original borrower address, blocking cross-borrower submission.
    error BorrowerMismatch(address expected, address provided);
    /// @dev Reverts when the on-XRPL FDC repayment memo does not match the loan's
    ///      `expectedCommitment`, i.e. the payment isn't bound to this loan.
    error CommitmentMismatch(bytes32 expected, bytes32 provided);
    /// @dev Reverts when the FDC proof's response has no memo data at all.
    error MemoDataMissing();
    /// @dev Reverts when the FDC memo data is not exactly `expected` bytes long
    ///      (the commitment is a bytes32, so `expected` is 32).
    error MemoDataWrongLength(uint256 length, uint256 expected);
    /// @dev Reverts when the XRPL payment returned a non-zero status code; the
    ///      payload carries the raw XRPL payment status byte.
    error PaymentFailed(uint8 status);
    /// @dev Reverts when the on-XRPL received XRP drops are below the required
    ///      principal + interest. `received` is signed (XRPL can return negative
    ///      amounts in pathological cases).
    error InsufficientRepayment(int256 received, uint256 required);
    /// @dev Reverts when the same FDC proof (keccak256 of the proof struct) is
    ///      submitted more than once, blocking memo reuse across loans.
    error ProofAlreadyConsumed();
    /// @dev Reverts when `IXRPPaymentVerification.verifyXRPPayment` returns false
    ///      (the attestation provider didn't corroborate the payment).
    error FDCVerificationFailed();
    /// @dev Reverts in `liquidate` / `startLiquidationAuction` when the loan
    ///      deadline has not yet passed (no early liquidation by deadline).
    error DeadlineNotPassed();
    /// @dev Reverts in `drawLoan` when the borrower has not yet registered an XRPL
    ///      receiving address via `registerXRPLAddress`.
    error XRPLAddressNotRegistered();
    /// @dev Reverts in `submitRepaymentProof` when the proof's
    ///      `receivingAddressHash` does not match the per-loan snapshot captured at
    ///      draw time, blocking repayment-substitution attacks.
    error RepaymentReceiverMismatch(bytes32 expected, bytes32 provided);
    /// @dev Reverts in `drawLoan` when the requested loanAmount exceeds the
    ///      `attestationLimit` the TEE authority approved for this loan.
    error ExceedsAttestationLimit();

    // ── Auction liquidation errors (added by subagent #45) ──
    /// @dev Reverts when no liquidation auction exists for `loanId` yet.
    error AuctionNotFound();
    /// @dev Reverts when `bidOnLiquidation`/`finalizeAuction` is called after the
    ///      `AUCTION_DURATION` window has elapsed (no further bids accepted).
    error AuctionExpired();
    /// @dev Reverts in `bidOnLiquidation` when the new bid doesn't beat the current
    ///      auction price (the decaying Dutch price or the standing highest bid).
    error InsufficientBid();
    /// @dev Reverts when an operation expecting the loan to be in `AUCTION` state
    ///      is invoked against a loan in some other state.
    error NotInAuctionState();

    // ── LTV configuration errors (added by subagent #55) ──
    /// @dev Reverts in `registerCollateral`/`updateLTV` when `newLTV` is outside
    ///      (0, 10000] bps or, for `registerCollateral`, when `decimals` is outside
    ///      (0, 36].
    error InvalidLTV(uint256 newLTV);
    /// @dev Reverts in `updateLTV` when the collateral token was never registered
    ///      (neither an LTV nor a decimal count was ever written for it).
    error UnknownCollateral(address token);
}
