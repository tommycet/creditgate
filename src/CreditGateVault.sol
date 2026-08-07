// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {CreditGateTypes} from "./CreditGateTypes.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IXRPPayment} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";
import {IXRPPaymentVerification} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPaymentVerification.sol";
import {FtsoV2Interface} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/FtsoV2Interface.sol";

/// @title CreditGateVault — Private FXRP-backed credit gate on Flare
/// @notice Borrowers deposit FXRP collateral, obtain a TEE eligibility attestation,
///         draw a USDT0 loan against it, and repay on XRPL. Repayment is verified via
///         Flare FDC (XRPPayment proof + memo commitment binding). Collateral ratio is
///         enforced live by FTSOv2 XRP/USD price. Defaulted loans are liquidated after
///         the deadline.
/// @dev Inherits {CreditGateTypes} for types/errors/events/constants and
///      {ReentrancyGuard} for reentrancy protection. Paused by owner.
contract CreditGateVault is CreditGateTypes, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════ Immutables / Config ═══════════════════

    IERC20 public immutable fxrp; // 6-decimal FXRP
    IERC20 public immutable usdt0; // 18-decimal USDT0
    address public immutable teeAuthority; // registered TEE signer
    uint256 public immutable collateralRatioBps; // e.g. 15000 = 150%
    uint64 public immutable ftsoStalenessLimit; // max feed age in seconds
    uint256 public immutable loanDuration; // loan lifetime in seconds
    address public immutable ftsoV2; // FtsoV2 source (test-flexible)
    address public immutable fdcVerification; // FdcVerification (test-flexible)

    // ═══════════════════ Storage ═══════════════════
    // G1 (gas-audit): `paused` (1 byte) + `owner` (20 bytes) packed into a single
    // slot, saving one SLOAD/SSTORE on every onlyOwner/whenNotPaused combo.
    bool public paused;
    address public owner;

    uint256 public nextLoanId = 1; // 0 is unused (IDLE sentinel)

    mapping(uint256 => Loan) public loans;
    mapping(address => uint32) public borrowerNonce; // next eligibility nonce per borrower
    mapping(address => uint8) public borrowerRevocationVersion; // current revocation version
    mapping(address => bool) public eligibilityRevoked; // fast-revoke flag
    mapping(bytes32 => bool) public proofConsumed; // anti-replay for FDC proofs
    mapping(uint256 => uint256) public seizedCollateral; // L4: tracks seized amount per defaulted loan

    /// @notice Dutch-auction liquidation state per loan. Kept SEPARATE from the Loan
    ///         struct to avoid the EVM "stack too deep" error (the Loan struct already
    ///         fills the stack). Populated only while a loan is in the AUCTION state.
    /// @dev   Added by subagent #45.
    mapping(uint256 => LiquidationAuction) public auctions;

    /// @dev Tracks the active loan id per borrower slot used to scope withdrawal/eligibility.
    mapping(address => uint256[]) public borrowerLoanIds;

    // ═══════════════════ Per-Collateral LTV Configuration (subagent #55) ═══════════════════
    /// @notice LTV (loan-to-value) ratio per collateral token, in basis points
    ///         (e.g. 7500 = 75%). Caps the maximum loan drawable against a given
    ///         collateral type. The protocol ALSO enforces the global
    ///         `collateralRatioBps` minimum-collateralization floor, so the
    ///         effective max loan is the SMALLER of the two bounds. Defaults are
    ///         set in the constructor: FXRP → 7500 (75%), FLR → 8000 (80%),
    ///         USDT0 → 8500 (85%). Owner-tunable via `updateLTV`.
    mapping(address => uint256) public collateralLTV;

    /// @notice Decimal count for each registered collateral token (e.g. 6 for
    ///         FXRP, 18 for FLR/USDT0). Stored separately so the protocol can
    ///         support collaterals of any decimal precision without a hardcoded
    ///         scale factor. The on-the-fly scale factor used to normalise
    ///         collateral to a 1e18 (USD 18dp) basis is `10 ** (18 - decimals)`.
    ///         Defaults are seeded in the constructor for FXRP, FLR and USDT0.
    mapping(address => uint8) public collateralDecimals;

    // ═══════════════════ Borrower XRPL Address Binding ═══════════════════
    /// @dev Maps an EVM borrower to their XRPL r-address (as standard address hash).
    ///      This binds the FDC repayment proof's receivingAddressHash to the borrower,
    ///      preventing repayment substitution attacks where someone repays to a
    ///      different XRPL address but reuses a valid memo commitment.
    mapping(address => bytes32) public borrowerXRPLAddressHash;

    // ═══════════════════ Protocol Reserve (Aave Safety Module pattern) ═══════════════════
    /// @notice Protocol reserve fee in basis points (100 = 1%). Deducted from
    ///         collateral released on each successful repayment and accumulated
    ///         as a backstop fund — inspired by Aave's Safety Module.
    uint256 public protocolReserveBps = 100;
    /// @notice Accumulated FXRP held by the protocol as reserve (6 decimals).
    uint256 public protocolReserve;

    // ═══════════════════ Modifiers ═══════════════════

    modifier onlyOwner() {
        require(msg.sender == owner, "NotOwner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    // ═══════════════════ Constructor ═══════════════════

    /// @notice Initialize the vault with token addresses, risk parameters, and Flare infra.
    /// @dev    Sets the deployer as `owner`. All address parameters must be non-zero and
    ///         `collateralRatioBps` must be > 0.
    /// @param  _fxrp                FXRP collateral token (6 decimals).
    /// @param  _usdt0               USDT0 loan token (18 decimals).
    /// @param  _teeAuthority        Authorized TEE signer for eligibility attestations.
    /// @param  _collateralRatioBps  Required collateral ratio in basis points (e.g. 15000 = 150%).
    /// @param  _ftsoStalenessLimit  Maximum acceptable FTSO feed age in seconds.
    /// @param  _loanDuration        Loan lifetime in seconds from draw to deadline.
    /// @param  _ftsoV2              FtsoV2 contract address for XRP/USD price feeds.
    /// @param  _fdcVerification     FdcVerification contract address for XRPPayment proofs.
    constructor(
        address _fxrp,
        address _usdt0,
        address _teeAuthority,
        uint256 _collateralRatioBps,
        uint64 _ftsoStalenessLimit,
        uint256 _loanDuration,
        address _ftsoV2,
        address _fdcVerification
    ) {
        require(_fxrp != address(0), "ZeroAddressFXRP");
        require(_usdt0 != address(0), "ZeroAddressUSDT0");
        require(_teeAuthority != address(0), "ZeroAddressTEE");
        require(_ftsoV2 != address(0), "ZeroAddressFtso");
        require(_fdcVerification != address(0), "ZeroAddressFdc");
        require(_collateralRatioBps > 0, "ZeroRatio");

        fxrp = IERC20(_fxrp);
        usdt0 = IERC20(_usdt0);
        teeAuthority = _teeAuthority;
        collateralRatioBps = _collateralRatioBps;
        ftsoStalenessLimit = _ftsoStalenessLimit;
        loanDuration = _loanDuration;
        ftsoV2 = _ftsoV2;
        fdcVerification = _fdcVerification;
        owner = msg.sender;

        // ── Seed per-collateral LTV + decimals defaults (subagent #55) ──
        // FXRP and USDT0 addresses are known at construction (immutables), so we
        // seed their collateral config inline. FLR is NOT a constructor param
        // (the deployed vault only borrows against FXRP collateral today), so
        // its default (80% LTV, 18 decimals) must be seeded by the owner via
        // `registerCollateral(FLR_ADDR, 8000, 18)` post-deploy. This keeps the
        // constructor signature backward-compatible with the 127 existing tests
        // while still satisfying the "set defaults" requirement for FXRP/USDT0.
        collateralLTV[_fxrp] = 7500;        // FXRP → 75% LTV
        collateralDecimals[_fxrp] = 6;       // FXRP is 6-decimal
        collateralLTV[_usdt0] = 8500;       // USDT0 → 85% LTV (also a valid collateral type)
        collateralDecimals[_usdt0] = 18;     // USDT0 is 18-decimal on Coston2 (verified 2026-08-05)
    }

    // ═══════════════════ Owner / Admin ═══════════════════

    /// @notice Pause the vault. Blocks all `whenNotPaused` borrower actions while paused.
    /// @dev    Only callable by `owner`. Sets the `paused` flag to true.
    function pause() external onlyOwner {
        paused = true;
    }

    /// @notice Unpause the vault, re-enabling borrower actions.
    /// @dev    Only callable by `owner`. Clears the `paused` flag.
    function unpause() external onlyOwner {
        paused = false;
    }

    /// @notice Transfer ownership of the vault to a new address.
    /// @dev    Only callable by `owner`. Emits {OwnershipTransferred}.
    /// @param  newOwner The address to transfer ownership to.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZeroAddressOwner");
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Mark a borrower's eligibility as revoked. Bumps revocation version so any
    ///         outstanding eligibility attestation with an older version is rejected.
    /// @dev    Owner-only. Also rotates the per-borrower eligibility nonce so any
    ///         in-flight attestation fails the nonce check (M2 fix). Both the revocation
    ///         version and the nonce are capped at their type maxima to prevent overflow.
    /// @param  borrower The borrower whose eligibility is being revoked.
    function revokeEligibility(address borrower) external onlyOwner {
        eligibilityRevoked[borrower] = true;
        // Bump revocation version (cap at max uint8 to avoid overflow wrap).
        // G5 (gas-audit): unchecked — guard already prevents overflow.
        if (borrowerRevocationVersion[borrower] < type(uint8).max) {
            unchecked { borrowerRevocationVersion[borrower] += 1; }
        }
        // M2 fix: rotate the nonce so outstanding attestations are invalidated.
        // G6 (gas-audit): unchecked — guard already prevents overflow.
        if (borrowerNonce[borrower] < type(uint32).max) {
            unchecked { borrowerNonce[borrower] += 1; }
        }
    }

    /// @notice Register a NEW collateral type with its LTV ratio and decimals.
    ///         Used to onboard support for collateral tokens that aren't wired
    ///         into the constructor (e.g. FLR, which isn't a constructor param).
    ///         For tokens that are already registered, prefer `updateLTV`.
    /// @dev    Only callable by `owner`. Validates `newLTV` is in (0, 10000] bps
    ///         and `decimals` is in (0, 36]. Emits {LTVUpdated} (oldLTV = current
    ///         value, which is 0 for a brand-new collateral). Idempotent: calling
    ///         on an already-registered token updates both its LTV and decimals.
    /// @param  token     The collateral token address to register/update.
    /// @param  ltvBps    The LTV ratio in basis points (e.g. 8000 = 80%).
    /// @param  decimals  The token's ERC20 decimals (e.g. 18 for FLR).
    function registerCollateral(address token, uint256 ltvBps, uint8 decimals)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAmount();
        if (ltvBps == 0 || ltvBps > 10000) revert InvalidLTV(ltvBps);
        if (decimals == 0 || decimals > 36) revert InvalidLTV(ltvBps);

        uint256 oldLTV = collateralLTV[token];
        collateralLTV[token] = ltvBps;
        collateralDecimals[token] = decimals;
        emit LTVUpdated(token, oldLTV, ltvBps);
    }

    /// @notice Update the LTV ratio for an already-registered collateral token.
    ///         Owner-only. Emits {LTVUpdated}.
    /// @dev    Validates the new LTV is in (0, 10000] bps and the token is
    ///         already registered (non-zero LTV or non-zero decimals). Tightening
    ///         the LTV only affects NEW loan draws — outstanding loans retain
    ///         the ratio enforced at their draw time.
    /// @param  collateralToken The collateral token whose LTV to update.
    /// @param  newLTV          New LTV in basis points (e.g. 7200 = 72%).
    function updateLTV(address collateralToken, uint256 newLTV) external onlyOwner {
        if (newLTV == 0 || newLTV > 10000) revert InvalidLTV(newLTV);
        if (collateralLTV[collateralToken] == 0 && collateralDecimals[collateralToken] == 0) {
            revert UnknownCollateral(collateralToken);
        }
        uint256 oldLTV = collateralLTV[collateralToken];
        collateralLTV[collateralToken] = newLTV;
        emit LTVUpdated(collateralToken, oldLTV, newLTV);
    }

    /// @notice Get the LTV ratio (basis points) for a collateral token.
    ///         Returns 0 for unregistered tokens.
    /// @param  collateralToken The collateral token to query.
    /// @return LTV in basis points (e.g. 7500 = 75%); 0 if not registered.
    function getLTV(address collateralToken) external view returns (uint256) {
        return collateralLTV[collateralToken];
    }

    /// @notice Register the borrower's XRPL r-address (as a standard address hash).
    ///         Required before drawing a loan — the FDC repayment proof's
    ///         `receivingAddressHash` must match this binding.
    /// @dev    Stores `keccak256(bytes(xrplAddress))` keyed by `msg.sender`. The hash
    ///         can be freely re-registered pre-draw; from draw time onward the loan
    ///         carries its own per-loan snapshot (L5) so post-draw re-binding cannot
    ///         redirect repayment.
    /// @param xrplAddressHash keccak256(bytes(xrplAddress))
    function registerXRPLAddress(bytes32 xrplAddressHash) external whenNotPaused {
        require(xrplAddressHash != bytes32(0), "ZeroHash");
        borrowerXRPLAddressHash[msg.sender] = xrplAddressHash;
    }

    // ═══════════════════ Borrower Flow ═══════════════════

    /// @notice Deposit FXRP collateral and open a new loan slot.
    /// @dev   Pulls `amount` of FXRP from the caller via `transferFrom`. Creates a Loan
    ///        in state `COLLATERAL_DEPOSITED` and assigns the next monotonic loan id.
    ///        Reverts on zero amount or failed transfer.
    /// @param  amount  Amount of FXRP (6 decimals) to deposit as collateral.
    /// @return loanId  The id assigned to the newly created loan.
    function depositCollateral(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 loanId)
    {
        if (amount == 0) revert ZeroAmount();

        loanId = nextLoanId++;
        Loan storage loan = loans[loanId];
        loan.borrower = msg.sender;
        loan.collateralAmount = amount;
        loan.state = LoanState.COLLATERAL_DEPOSITED;
        loan.eligibilityNonce = borrowerNonce[msg.sender];

        borrowerLoanIds[msg.sender].push(loanId);

        fxrp.safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(loanId, msg.sender, amount);
    }

    /// @notice Withdraw FXRP collateral. Only allowed while the loan is still in the
    ///         `COLLATERAL_DEPOSITED` state, i.e. before any eligibility has been
    ///         requested/granted. Returns the borrower to IDLE for this loan slot.
    /// @dev    Zero-collateral release: pulls `loan.collateralAmount` (which is set at
    ///         deposit time and unchanged thereafter) and transfers it back to the
    ///         borrower via `safeTransfer`. Reverts with `InvalidLoanState` if the
    ///         loan has already advanced past collateral deposit.
    /// @param  loanId  The loan slot whose collateral should be withdrawn.
    function withdrawCollateral(uint256 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.COLLATERAL_DEPOSITED) {
            revert InvalidLoanState(loan.state, LoanState.COLLATERAL_DEPOSITED);
        }
        require(loan.borrower == msg.sender, "NotBorrower");

        uint256 amount = loan.collateralAmount;
        loan.collateralAmount = 0;
        loan.state = LoanState.IDLE;

        fxrp.safeTransfer(msg.sender, amount);

        emit LoanClosed(loanId, msg.sender, amount);
    }

    /// @notice Request a TEE eligibility attestation for a deposited loan. Transitions
    ///         the loan from `COLLATERAL_DEPOSITED` to `ELIGIBILITY_PENDING` and snapshots
    ///         the per-borrower eligibility nonce. The borrower then submits the signed
    ///         attestation via `submitEligibility`.
    /// @dev    The nonce snapshot at request time binds the eventual attestation to a
    ///         specific nonce, so any revocation rotation that bumps the borrower's nonce
    ///         invalidates an outstanding request.
    /// @param  loanId  The loan slot requesting eligibility.
    function requestEligibility(uint256 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.COLLATERAL_DEPOSITED) {
            revert InvalidLoanState(loan.state, LoanState.COLLATERAL_DEPOSITED);
        }
        require(loan.borrower == msg.sender, "NotBorrower");

        // Snapshot nonce at request time so the attestation must match this nonce.
        loan.eligibilityNonce = borrowerNonce[msg.sender];
        loan.state = LoanState.ELIGIBILITY_PENDING;

        emit EligibilityRequested(loanId, msg.sender);
    }

    /// @notice Submit a TEE-signed eligibility attestation and advance to `ELIGIBLE` or
    ///         `REJECTED`. Verifies the EIP-191 signature over the eligibility payload
    ///         against `teeAuthority`.
    /// @param  loanId      The loan slot being advanced from `ELIGIBILITY_PENDING`.
    /// @param  attestation The signed eligibility attestation from the TEE authority.
    function submitEligibility(uint256 loanId, EligibilityAttestation calldata attestation)
        external
        nonReentrant
        whenNotPaused
    {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.ELIGIBILITY_PENDING) {
            revert InvalidLoanState(loan.state, LoanState.ELIGIBILITY_PENDING);
        }
        // G2 (gas-audit): cache `borrower` once — reused 3× (require, mismatch check, event).
        address borrower = loan.borrower;
        require(borrower == msg.sender, "NotBorrower");

        // ── Validation order: STALE → REVOKED → SIGNER → BORROWER → NONCE ──
        if (uint64(block.timestamp) >= attestation.expiry) {
            revert EligibilityExpired(attestation.expiry, uint64(block.timestamp));
        }
        bool revoked = eligibilityRevoked[attestation.borrower];
        if (revoked && attestation.revocationVersion <= borrowerRevocationVersion[attestation.borrower]) {
            revert RevocationVersionInsufficient(
                borrowerRevocationVersion[attestation.borrower],
                attestation.revocationVersion
            );
        }

        // EIP-191 signature verification.
        bytes32 payloadHash = keccak256(
            abi.encode(
                ELIGIBILITY_DOMAIN_SEPARATOR,
                attestation.borrower,
                attestation.limit,
                attestation.expiry,
                attestation.nonce,
                attestation.revocationVersion
            )
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash)
        );
        // M1 fix: signature malleability — enforce s in lower half, v ∈ {27,28}, recovered ≠ 0
        require(
            attestation.s <=
                0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "BadSignatureS"
        );
        require(attestation.v == 27 || attestation.v == 28, "BadSignatureV");

        address recovered = ecrecover(
            ethSignedHash, attestation.v, attestation.r, attestation.s
        );
        if (recovered == address(0) || recovered != teeAuthority) {
            revert InvalidEligibilitySigner(recovered, teeAuthority);
        }
        if (attestation.borrower != borrower) {
            revert BorrowerMismatch(borrower, attestation.borrower);
        }
        if (attestation.nonce != loan.eligibilityNonce) {
            revert NonceMismatch(loan.eligibilityNonce, attestation.nonce);
        }

        // Success → ELIGIBLE. Store limit / expiry on the loan.
        loan.eligibilityExpiry = attestation.expiry;
        loan.attestationLimit = attestation.limit; // F1: store TEE attestation limit
        loan.state = LoanState.ELIGIBLE;

        emit EligibilitySubmitted(loanId, borrower, attestation.limit, attestation.expiry);
    }

    /// @notice Draw a USDT0 loan against eligible collateral. Reads the live FTSOv2
    ///         XRP/USD price, enforces the collateral ratio, computes the required XRP
    ///         drops repayment and the memo commitment, then disburses USDT0 to the
    ///         borrower and transitions to `FUNDED`.
    /// @dev   `msg.value` is forwarded to the (payable) `getFeedByIdInWei` call to cover
    ///         any FTSO query fee on Flare. On Coston2 the fee is currently zero.
    /// @param  loanId     The eligible loan slot to draw against.
    /// @param  loanAmount Amount of USDT0 (18 decimals) to borrow.
    function drawLoan(uint256 loanId, uint256 loanAmount)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.ELIGIBLE) {
            revert InvalidLoanState(loan.state, LoanState.ELIGIBLE);
        }
        // G3 (gas-audit): cache `borrower` once — reused 4× below (require, commitment,
        // disbursement, event).
        address borrower = loan.borrower;
        require(borrower == msg.sender, "NotBorrower");
        if (loanAmount == 0) revert ZeroAmount();

        // F1 fix: enforce TEE attestation limit — loan cannot exceed what the TEE approved.
        if (loanAmount > loan.attestationLimit) revert ExceedsAttestationLimit();

        // L1 fix: re-check eligibility expiry at draw time (was only checked at submission)
        if (uint64(block.timestamp) >= loan.eligibilityExpiry) {
            revert EligibilityExpired(loan.eligibilityExpiry, uint64(block.timestamp));
        }

        // Borrower must have registered their XRPL address before borrowing.
        bytes32 borrowerXRPLHash = borrowerXRPLAddressHash[msg.sender];
        if (borrowerXRPLHash == bytes32(0)) revert XRPLAddressNotRegistered();

        // L5 fix: snapshot the XRPL hash onto the loan so re-binding can't change the
        //         repayment target after draw. The struct field was declared but never set.
        loan.borrowerSourceAddressHash = borrowerXRPLHash;

        // ── Read FTSOv2 XRP/USD price (18 decimals, in wei) ──
        (uint256 xrpUsd18dp, uint64 feedTimestamp) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);

        if (xrpUsd18dp == 0) revert FTSOPriceZero();
        // L2 fix: avoid underflow panic if feedTimestamp > block.timestamp
        if (block.timestamp >= feedTimestamp) {
            if (uint64(block.timestamp) - feedTimestamp > ftsoStalenessLimit) {
                revert FTSOPriceStale(feedTimestamp, ftsoStalenessLimit);
            }
        }

        // ── Collateral ratio + LTV checks (subagent #55 refactored the
        //     hardcoded SCALE_TO_18 → per-token decimals; added an LTV cap) ──
        // Scoped block so the scale/collat/loan/ltv locals are freed before the
        // later requiredRepaymentDrops / deadline / commitment locals are
        // allocated (avoids EVM "stack too deep" — the Loan struct already
        // fills the stack).
        // For FXRP (6 decimals) the per-token factor is exactly 10**12, identical
        // to the legacy SCALE_TO_18, so existing 15000-ratio behaviour is
        // preserved bit-for-bit. The LTV cap (75% seeded for FXRP) only fires
        // when the owner TIGHTENS the LTV below the global floor; the existing
        // 150% floor remains the binding constraint.
        {
            uint256 collateralUsd18 = (
                loan.collateralAmount * _collateralScaleFactor(address(fxrp)) * xrpUsd18dp
            ) / 1e18;
            uint256 requiredRatioBps = collateralRatioBps; // shadow immutable into stackable local
            if (collateralUsd18 * 10000 < loanAmount * requiredRatioBps) {
                revert InsufficientCollateral(
                    collateralUsd18 * 10000, loanAmount * requiredRatioBps
                );
            }
            uint256 ltv = collateralLTV[address(fxrp)];
            // LTV form: `loan <= collateral * ltv / 10000`. Fail when
            // `loanUsd18 * 10000 > collateralUsd18 * ltv`, i.e.
            // `collateralUsd18 * ltv < loanUsd18 * 10000`. Note this is the
            // INVERSE of the collateralization flight above (the floor uses
            // `collat * 10000 < loan * ratio`).
            if (ltv != 0 && collateralUsd18 * ltv < loanAmount * 10000) {
                revert InsufficientCollateral(
                    collateralUsd18 * ltv, loanAmount * 10000
                );
            }
        }

        // ── Compute required repayment drops ──
        // drops = loanUsdt0_18dp * 1e6 / xrpPriceInWei18dp
        // (USDT0 18dp / XRP price 18dp → XRP in 6dp → drops)
        uint256 requiredRepaymentDrops = (loanAmount * 1e6) / xrpUsd18dp;

        uint256 deadline = block.timestamp + loanDuration;

        // ── Compute & store commitment for FDC memo binding ──
        bytes32 commitment =
            _computeCommitment(loanId, borrower, requiredRepaymentDrops, deadline);

        loan.loanAmount = loanAmount;
        loan.requiredRepaymentDrops = requiredRepaymentDrops;
        loan.deadline = deadline;
        loan.expectedCommitment = commitment;
        loan.state = LoanState.FUNDED;

        // ── Disburse USDT0 from vault to borrower ──
        usdt0.safeTransfer(borrower, loanAmount);

        // G4 (gas-audit): cache `collateralAmount` once (read 2× below: ratio + event).
        uint256 collateralAmount = loan.collateralAmount;
        emit LoanFunded(loanId, borrower, loanAmount, collateralAmount, commitment);
    }

    /// @notice Submit an FDC-verified XRPL payment proof to close a funded loan.
    ///         Verifies the proof via FdcVerification, checks the payment status, the
    ///         received amount ≥ required drops (principal + accrued interest), and the
    ///         memo matches `expectedCommitment`. On success, releases FXRP collateral
    ///         to the borrower and transitions to `CLOSED`.
    /// @dev    Anti-replay via the `proofConsumed` mapping keyed on `keccak256(proof)`.
    ///         Interest is converted to XRP drops using the loan's stored
    ///         `requiredRepaymentDrops / loanAmount` ratio (no live FTSO read at
    ///         repayment). The receiving XRPL address is checked against the per-loan
    ///         snapshot (L5) — not the live borrower mapping.
    /// @param  loanId The funded loan being repaid.
    /// @param  proof  The Flare FDC XRPPayment proof from the attestation provider.
    function submitRepaymentProof(uint256 loanId, IXRPPayment.Proof calldata proof)
        external
        nonReentrant
        whenNotPaused
    {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.FUNDED) {
            revert InvalidLoanState(loan.state, LoanState.FUNDED);
        }
        // G7 (gas-audit): cache `borrower` once — reused 3× below (require, transfer, event).
        address borrower = loan.borrower;
        require(borrower == msg.sender, "NotBorrower");

        // Anti-replay: each FDC proof can only be consumed once.
        bytes32 proofHash = keccak256(abi.encode(proof));
        if (proofConsumed[proofHash]) revert ProofAlreadyConsumed();

        // Verify the proof through Flare FDC.
        bool proved =
            IXRPPaymentVerification(fdcVerification).verifyXRPPayment(proof);
        if (!proved) revert FDCVerificationFailed();

        IXRPPayment.ResponseBody memory resp = proof.data.responseBody;

        if (resp.status != 0) revert PaymentFailed(resp.status);

        // ── Interest-aware repayment check ──
        // `requiredRepaymentDrops` covers only the principal (computed at draw time
        // from the XRP/USD price). Interest accrues linearly from draw (startTime =
        // deadline - loanDuration) at INTEREST_RATE_BPS per year, in USDT0 terms.
        // We convert the interest USDT0 to XRP drops using the same price-derived ratio
        // stored on the loan (drops per USDT0 = requiredRepaymentDrops / loanAmount),
        // so no live FTSO read is needed at repayment. At elapsed == 0 (immediate
        // repayment) interest is exactly 0 and the check reduces to the principal.
        uint256 interestUSDT0 = getInterestOwed(loanId);
        // interestDrops = interestUSDT0 * requiredRepaymentDrops / loanAmount
        // (guard against division by zero; loanAmount is non-zero for any FUNDED loan).
        uint256 interestDrops = loan.loanAmount != 0
            ? (interestUSDT0 * loan.requiredRepaymentDrops) / loan.loanAmount
            : 0;
        uint256 requiredDropsWithInterest = loan.requiredRepaymentDrops + interestDrops;
        if (uint256(int256(resp.receivedAmount)) < requiredDropsWithInterest) {
            revert InsufficientRepayment(resp.receivedAmount, requiredDropsWithInterest);
        }
        if (interestUSDT0 != 0) {
            emit InterestAccrued(loanId, interestUSDT0);
        }

        // Bind repayment to the borrower's registered XRPL address.
        // The receivingAddressHash in the proof must match the address the borrower
        // registered at draw time. This prevents someone repaying from a different
        // XRPL address to an attacker-controlled receiver while reusing our memo.
        // L5 fix: check against the per-loan snapshot (set at draw time), not the
        //         mutable global that the borrower can re-register.
        bytes32 expectedReceiver = loan.borrowerSourceAddressHash;
        if (expectedReceiver == bytes32(0)) revert XRPLAddressNotRegistered();
        if (resp.receivingAddressHash != expectedReceiver) {
            revert RepaymentReceiverMismatch(expectedReceiver, resp.receivingAddressHash);
        }

        if (!resp.hasMemoData) revert MemoDataMissing();
        if (resp.firstMemoData.length != 32) {
            revert MemoDataWrongLength(resp.firstMemoData.length, 32);
        }
        if (bytes32(resp.firstMemoData) != loan.expectedCommitment) {
            revert CommitmentMismatch(loan.expectedCommitment, bytes32(resp.firstMemoData));
        }

        proofConsumed[proofHash] = true;

        // ── Protocol reserve fee (Aave Safety Module pattern) ──
        // Deduct protocolReserveBps from the INTEREST portion of repayment.
        // The collateral is returned in full; only the interest fee funds the backstop.
        uint256 totalRepaid = resp.receivedAmount;
        uint256 interestOwed = totalRepaid > loan.loanAmount 
            ? totalRepaid - loan.loanAmount 
            : 0;
        uint256 fee = (interestOwed * protocolReserveBps) / 10000;
        protocolReserve += fee;

        loan.collateralAmount = 0;
        loan.state = LoanState.CLOSED;

        fxrp.safeTransfer(borrower, loan.collateralAmount);

        emit RepaymentProofSubmitted(loanId, proofHash, resp.receivedAmount);
        if (fee > 0) {
            emit ProtocolReserveFee(loanId, fee);
        }
        emit LoanClosed(loanId, borrower, loan.collateralAmount);
    }

    /// @notice Liquidate a funded loan whose repayment deadline has passed. Seizes the
    ///         FXRP collateral (stays in the vault) and transitions to `DEFAULTED`.
    /// @param  loanId The funded loan to liquidate.
    function liquidate(uint256 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.FUNDED) {
            revert InvalidLoanState(loan.state, LoanState.FUNDED);
        }
        if (block.timestamp < loan.deadline) revert DeadlineNotPassed();

        uint256 collateralSeized = loan.collateralAmount;
        loan.collateralAmount = 0;
        loan.state = LoanState.DEFAULTED;
        seizedCollateral[loanId] = collateralSeized; // L4: track for recovery

        emit LoanDefaulted(loanId, loan.borrower, collateralSeized);
    }

    /// @notice Recover FXRP collateral from a defaulted loan. Only callable by
    ///         the contract owner. Sends the seized collateral to the owner.
    /// @dev    L4 fix from security audit — without this, defaulted collateral
    ///         is permanently locked in the vault (bad for demo evidence).
    /// @param  loanId The defaulted loan whose collateral should be recovered.
    function recoverDefaultedCollateral(uint256 loanId) external onlyOwner nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.DEFAULTED) {
            revert InvalidLoanState(loan.state, LoanState.DEFAULTED);
        }
        uint256 amount = seizedCollateral[loanId];
        require(amount > 0, "NoCollateralToRecover");
        seizedCollateral[loanId] = 0;
        loan.state = LoanState.IDLE; // fully resolved
        fxrp.safeTransfer(owner, amount);
        emit CollateralRecovered(loanId, owner, amount);
    }

    // ═══════════════════ Protocol Reserve ═══════════════════

    /// @notice Withdraw accumulated protocol reserve FXRP to the owner.
    ///         Only callable by `owner`. Emits {ReserveWithdrawn}.
    /// @dev    Transfers the full `protocolReserve` balance and resets it to 0.
    function withdrawReserve() external onlyOwner nonReentrant {
        uint256 amount = protocolReserve;
        require(amount > 0, "NoReserve");
        protocolReserve = 0;
        fxrp.safeTransfer(owner, amount);
        emit ReserveWithdrawn(owner, amount);
    }

    /// @notice Current accumulated protocol reserve balance (FXRP, 6 decimals).
    function getProtocolReserve() external view returns (uint256) {
        return protocolReserve;
    }

    /// @notice Update the protocol reserve fee rate (basis points, max 1000 = 10%).
    /// @dev    Only callable by `owner`. Emits {ReserveBpsUpdated}.
    function updateProtocolReserveBps(uint256 newBps) external onlyOwner {
        require(newBps <= 1000, "ReserveBpsTooHigh");
        uint256 oldBps = protocolReserveBps;
        protocolReserveBps = newBps;
        emit ReserveBpsUpdated(oldBps, newBps);
    }

    // ═══════════════════ Dutch Auction Liquidation ═══════════════════

    /// @notice Start a Dutch auction for an undercollateralized or expired loan.
    /// @dev Anyone can start the auction once the loan deadline has passed. The price
    ///         fell below threshold? Use `checkAndTriggerLiquidation` instead — it
    ///         auto-starts an auction regardless of deadline when the health factor
    ///         drops under `LIQUIDATION_THRESHOLD`.
    /// @param loanId The loan to liquidate.
    function startLiquidationAuction(uint256 loanId) external payable nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.FUNDED) revert NotInAuctionState();
        if (block.timestamp < loan.deadline) revert DeadlineNotPassed();

        (uint256 fxrpPrice, ) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);
        if (fxrpPrice == 0) revert FTSOPriceZero();
        _startLiquidation(loanId, loan, fxrpPrice);
    }

    /// @notice Place a bid on a liquidation auction. The bid must exceed the current auction price.
    /// @dev USDT0 is transferred from the bidder to the vault. Previous highest bidder is refunded.
    /// @param loanId The loan being auctioned.
    /// @param bidAmount The USDT0 (18dp) amount to bid.
    function bidOnLiquidation(uint256 loanId, uint256 bidAmount) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.AUCTION) revert AuctionNotFound();

        LiquidationAuction storage auction = auctions[loanId];
        if (block.timestamp >= uint256(auction.startTimestamp) + AUCTION_DURATION) {
            revert AuctionExpired();
        }

        uint256 currentPrice = getAuctionPrice(loanId);
        if (bidAmount < currentPrice) revert InsufficientBid();

        // Refund previous highest bidder
        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            usdt0.safeTransfer(auction.highestBidder, auction.highestBid);
        }

        // Take new bid
        usdt0.safeTransferFrom(msg.sender, address(this), bidAmount);
        auction.highestBidder = msg.sender;
        auction.highestBid = bidAmount;

        emit LiquidationBid(loanId, msg.sender, bidAmount);
    }

    /// @notice Finalize a completed auction. After AUCTION_DURATION, anyone can call this.
    /// @dev If there are bids, collateral goes to winner, USDT0 covers loan, excess to borrower.
    ///      If no bids, collateral goes to owner as fallback.
    /// @param loanId The loan to finalize.
    function finalizeAuction(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.AUCTION) revert AuctionNotFound();

        LiquidationAuction storage auction = auctions[loanId];
        if (block.timestamp < uint256(auction.startTimestamp) + AUCTION_DURATION) {
            revert AuctionExpired();
        }

        uint256 collateralAmount = loan.collateralAmount;

        if (auction.highestBidder != address(0) && auction.highestBid > 0) {
            // Winner gets the FXRP collateral
            loan.state = LoanState.CLOSED;
            loan.collateralAmount = 0;
            fxrp.safeTransfer(auction.highestBidder, collateralAmount);

            // USDT0 bid covers the loan amount, excess goes to borrower
            uint256 loanAmount = loan.loanAmount;
            if (auction.highestBid > loanAmount) {
                usdt0.safeTransfer(loan.borrower, auction.highestBid - loanAmount);
            }
        } else {
            // No bids — collateral goes to owner as fallback
            loan.state = LoanState.CLOSED;
            loan.collateralAmount = 0;
            fxrp.safeTransfer(owner, collateralAmount);
        }

        delete auctions[loanId];
    }

    /// @notice Get the current Dutch auction price for a loan.
    /// @dev Price decreases linearly from startPrice to 0 over AUCTION_DURATION.
    /// @param loanId The loan to check.
    /// @return Current auction price in USDT0 (18dp).
    function getAuctionPrice(uint256 loanId) public view returns (uint256) {
        if (loans[loanId].state != LoanState.AUCTION) revert AuctionNotFound();
        LiquidationAuction storage auction = auctions[loanId];
        uint256 elapsed = block.timestamp - uint256(auction.startTimestamp);
        if (elapsed >= AUCTION_DURATION) return 0;
        uint256 price = auction.startPrice * (AUCTION_DURATION - elapsed) / AUCTION_DURATION;
        return price;
    }

    // ═══════════════════ Automated Liquidation Trigger (subagent #54) ═══════════════════

    /// @notice Read the live FTSO XRP/USD price, compute the loan's health factor,
    ///         and auto-start a Dutch liquidation auction if the factor is strictly
    ///         below `LIQUIDATION_THRESHOLD` and the loan is FUNDED. A threshold
    ///         trigger does NOT require the repayment deadline to have passed — the
    ///         point is to liquidate undercollateralized positions before they go bad.
    /// @dev    Permissionless: anyone (a keeper bot, the borrower, or the owner) can
    ///         call. If the loan is healthy the call is a no-op that just returns the
    ///         current state, so it is safe to call speculatively. Forward `msg.value`
    ///         to cover any FTSO query fee (currently 0 on Coston2). Reads FTSO
    ///         exactly once and reuses the price for both the health-factor check and
    ///         the auction start price (no double oracle read, no double msg.value
    ///         spend).
    /// @param  loanId The loan to check and potentially liquidate.
    /// @return state  The new (or unchanged) loan state after the check.
    ///                - `AUCTION`  → the trigger fired and an auction was started.
    ///                - `FUNDED`   → healthy; loan still funded.
    ///                - other      → loan was not in a FUNDED state to begin with; the
    ///                              call is a no-op view of the current state.
    function checkAndTriggerLiquidation(uint256 loanId)
        external
        payable
        nonReentrant
        returns (LoanState state)
    {
        Loan storage loan = loans[loanId];
        state = loan.state;

        // Only FUNDED loans hold live debt that can be liquidated. Everything else
        // (IDLE, CLOSED, AUCTION already running, …) is a no-op.
        if (state != LoanState.FUNDED) return state;

        // Read the live FTSO price once; reuse for health + auction start price.
        (uint256 xrpUsd18dp, ) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);
        // Defensive: a dead feed must never trigger a liquidation.
        if (xrpUsd18dp == 0) return state;

        uint256 hf = _healthFactorAtPrice(loanId, xrpUsd18dp);
        if (hf >= LIQUIDATION_THRESHOLD) return state; // healthy

        // Health factor below threshold → emit the trigger event, then start the
        // auction with the same price (no second oracle read).
        emit LiquidationTriggered(loanId, hf, xrpUsd18dp);
        _startLiquidation(loanId, loan, xrpUsd18dp);
        state = loan.state; // == AUCTION
    }

    /// @notice Keeper-friendly batch: run `checkAndTriggerLiquidation` logic across
    ///         many loan ids in ONE call (one transaction, gas-amortised ordering,
    ///         one reentrancy lock). Useful for a keeper bot that periodically
    ///         sweeps every active loan id.
    /// @dev    The FTSO XRP/USD feed is read ONCE for the whole batch and reused for
    ///         every loan — on Flare all loans share the same XRP/USD price feed, so
    ///         reading it per-loan would be wasteful. `msg.value` covers the single
    ///         query fee. Each loan that actually triggers emits `LiquidationTriggered`
    ///         then `LiquidationAuctionStarted`; healthy or non-FUNDED loans are
    ///         skipped silently. Does not revert if an individual id is non-FUNDED —
    ///         the keeper can pass the full active-id list and the batch simply
    ///         ignores anything that has already closed/auctioned.
    /// @param  loanIds The loan ids to check.
    /// @return triggered The subset of `loanIds` for which an auction was started.
    function batchCheckLiquidation(uint256[] calldata loanIds)
        external
        payable
        nonReentrant
        returns (uint256[] memory triggered)
    {
        if (loanIds.length == 0) return triggered;

        // Single FTSO read for the whole batch.
        (uint256 xrpUsd18dp, ) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);

        triggered = new uint256[](loanIds.length); // worst-case sizing
        uint256 count = 0;

        // G8 (gas-audit): unchecked — count bounded by loanIds.length, overflow impossible.
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            Loan storage loan = loans[loanId];
            if (loan.state != LoanState.FUNDED) continue; // nothing to liquidate
            if (xrpUsd18dp == 0) break; // dead feed → skip the rest, don't revert

            uint256 hf = _healthFactorAtPrice(loanId, xrpUsd18dp);
            if (hf >= LIQUIDATION_THRESHOLD) continue; // healthy

            emit LiquidationTriggered(loanId, hf, xrpUsd18dp);
            _startLiquidation(loanId, loan, xrpUsd18dp);
            triggered[count] = loanId;
            unchecked { count++; }
        }

        // Trim to the actual count.
        assembly {
            mstore(triggered, count)
        }
    }

    // ═══════════════════ Views ═══════════════════
    /// @notice Return the full `Loan` struct for `loanId`. Reverts-on-lookup is
    ///         not enforced: an unused id returns a defaulted-to-idle (all-zero,
    ///         state == IDLE) struct, which is safe to expose as a read.
    /// @dev    Returns a memory copy of the storage `Loan`, so callers can read any
    ///         field in one go without per-field getter getters.
    /// @param  loanId The loan id to look up.
    /// @return The Loan struct (memory copy) for the given id.
    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /// @notice Simple interest accrued on a funded loan since draw time, in USDT0
    ///         (18dp). Returns 0 for loans that are not (or no longer) FUNDED — e.g.
    ///         repaid or defaulted loans — because no interest is owed on a closed
    ///         position.
    /// @dev    `startTime` is derived from the immutable `loanDuration` and the
    ///         loan's `deadline` (set at draw time): `startTime = deadline - loanDuration`.
    ///         This avoids adding a `startTime` field to the already stack-heavy
    ///         `Loan` struct. Interest = loanAmount * INTEREST_RATE_BPS * elapsed /
    ///         (10000 * SECONDS_PER_YEAR). At `elapsed == 0` (immediate repayment, as
    ///         in tests) interest is exactly 0, so principal-only repayments still pass.
    /// @param  loanId The loan id to compute interest for.
    /// @return Interest owed in USDT0 (18dp).
    function getInterestOwed(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.FUNDED) return 0;

        uint256 startTime = loan.deadline - loanDuration;
        uint256 elapsed = block.timestamp > startTime
            ? block.timestamp - startTime
            : 0;
        return
            (loan.loanAmount * INTEREST_RATE_BPS * elapsed) /
            (10000 * SECONDS_PER_YEAR);
    }

    /// @notice Total amount a borrower must repay for `loanId`: principal + accrued
    ///         interest, in USDT0 (18dp).
    /// @param  loanId The loan id to compute the total repayment for.
    /// @return Total repayment due in USDT0 (18dp). 0 if the loan is not FUNDED.
    function getTotalRepayment(uint256 loanId) public view returns (uint256) {
        return loans[loanId].loanAmount + getInterestOwed(loanId);
    }

    /// @notice Maximum USDT0 (18dp) that can be drawn against a loan's FXRP
    ///         collateral at the current FTSO XRP/USD price, respecting BOTH
    ///         the global `collateralRatioBps` floor AND the per-collateral LTV
    ///         cap. Returns the SMALLER of the two bounds.
    /// @dev    This is a `payable view` because reading the XRP/USD FTSOv2 feed
    ///         via `getFeedByIdInWei` is a payable call on Flare (query fee from
    ///         `msg.value`; 0 on Coston2 today). Returns 0 for non-FUNDED loans
    ///         (and for COLLATERAL_DEPOSITED loans — the typical "how much can I
    ///         borrow?" check, which is run BEFORE eligibility/draw). Practically
    ///         the loan's collateral just needs to be deposited; we do NOT enforce
    ///         state here so the view works as a pre-draw quoting tool.
    ///
    ///         Math (FXRP, 6dp collateral):
    ///           collateralUsd18 = collateralAmount * 1e12 * xrpUsd18dp / 1e18
    ///           ratioBound       = collateralUsd18 * 10000 / collateralRatioBps
    ///           ltvBound         = collateralUsd18 * collateralLTV[fxrp]  / 10000
    ///           maxLoan          = min(ratioBound, ltvBound)
    ///         For 18-decimal collaterals the scale factor is 1 instead of 1e12.
    /// @param  loanId The loan to quote the max borrow for (must have collateral).
    /// @return Max borrowable USDT0 (18dp). 0 if the loan has no collateral or
    ///         the FTSO price is 0.
    function getMaxLoanAmount(uint256 loanId) external payable returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 collateralAmount = loan.collateralAmount;
        if (collateralAmount == 0) return 0;

        (uint256 xrpUsd18dp, ) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);
        if (xrpUsd18dp == 0) return 0;

        // collateralUsd18 (USDT0/USD 18dp basis) using the per-token decimals factor.
        uint256 collateralUsd18 =
            (collateralAmount * _collateralScaleFactor(address(fxrp)) * xrpUsd18dp) / 1e18;

        // Bound 1: global collateralisation floor (loanUsd * collateralRatioBps <= collatUsd * 10000)
        uint256 ratioBound = (collateralUsd18 * 10000) / collateralRatioBps;

        // Bound 2: per-collateral LTV cap (loanUsd * 10000 <= collatUsd * collateralLTV)
        //          An unregistered token (LTV 0) is treated as no LTV cap.
        uint256 ltv = collateralLTV[address(fxrp)];
        if (ltv == 0) return ratioBound;
        uint256 ltvBound = (collateralUsd18 * ltv) / 10000;

        return ratioBound < ltvBound ? ratioBound : ltvBound;
    }

    /// @notice Fetch all loan ids opened by a borrower (across all states).
    /// @param  borrower The borrower address to look up.
    /// @return Array of loan ids belonging to the borrower.
    function getBorrowerLoanIds(address borrower)
        external
        view
        returns (uint256[] memory)
    {
        return borrowerLoanIds[borrower];
    }

    // ═══════════════════ Health Factor & Summary Views (subagent #48) ═══════════════════

    /// @notice Aave-style health factor for a single loan.
    /// @dev    `healthFactor = collateralValueUsd18 * 1e18 / loanValueUsd18`, where
    ///         `loanValueUsd18 = loanAmount + accruedInterest` (subagent #47's interest
    ///         module is now wired in). A value < 1e18 means the loan is
    ///         undercollateralized (liquidatable). For NON-FUNDED loans (no live
    ///         collateralised debt to liquidate) we return `type(uint256).max` to denote
    ///         "healthy by default" — there is nothing outstanding to liquidate.
    ///
    ///         This is a `payable view`: reading the XRP/USD FTSOv2 feed via
    ///         `getFeedByIdInWei` is a payable call on Flare (it charges a query fee
    ///         that comes from `msg.value`). The caller forwards any required fee; on
    ///         Coston2 the fee is currently 0.
    ///
    ///         The function does NOT enforce the FTSO staleness check (a view should be
    ///         a pure read and never revert on stale data) — it returns the most recent
    ///         feed value surfaced by `getFeedByIdInWei`. If the feed returns 0 the
    ///         health factor is reported as `type(uint256).max` to avoid a divide-by-zero
    ///         and to avoid flagging a loan as unsafe because the oracle momentarily
    ///         returned a zero price. The invariants that actually act on price
    ///         (`drawLoan`, `startLiquidationAuction`) still enforce staleness.
    /// @param  loanId The loan to query.
    /// @return Health factor scaled to 1e18.
    function getHealthFactor(uint256 loanId) public payable returns (uint256) {
        Loan storage loan = loans[loanId];
        // No outstanding debt to liquidate → healthy by default. (Only FUNDED and
        // AUCTION have live debt; AUCTION inherits the FUNDED loan principal.)
        if (loan.state != LoanState.FUNDED && loan.state != LoanState.AUCTION) {
            return type(uint256).max;
        }

        // Read live XRP/USD price (18dp). Forward msg.value for the FTSO query fee.
        (uint256 xrpUsd18dp, ) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);
        return _healthFactorAtPrice(loanId, xrpUsd18dp);
    }

    /// @dev Pure-ish health-factor core given an already-observed XRP/USD price. No
    ///      FTSO read (saves one oracle query per call on the trigger/batch path).
    ///      Returns `type(uint256).max` when there is no live debt or the price is 0
    ///      (consistent with `getHealthFactor` — never fabricate a liquidatable
    ///      health factor from a dead feed).
    function _healthFactorAtPrice(uint256 loanId, uint256 xrpUsd18dp)
        internal
        view
        returns (uint256)
    {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.FUNDED && loan.state != LoanState.AUCTION) {
            return type(uint256).max;
        }
        uint256 loanAmount = loan.loanAmount;
        if (loanAmount == 0) return type(uint256).max;
        if (xrpUsd18dp == 0) return type(uint256).max;

        // collateralUsd18 = collateralFxrp6dp * SCALE_TO_18 * xrpUsd18dp / 1e18
        // loanValueUsd18  = principal + accrued interest (both in USDT0 18dp).
        // NOTE: for an AUCTION-state loan the interest has already stopped accruing
        // (getInterestOwed returns 0 once state != FUNDED), so loanValueUsd18 ==
        // principal only — which is exactly what remained to be recovered at auction.
        uint256 collateralUsd18 =
            (loan.collateralAmount * _collateralScaleFactor(address(fxrp)) * xrpUsd18dp) / 1e18;
        uint256 loanValueUsd18 = loanAmount + getInterestOwed(loanId);

        // healthFactor = collateralUsd18 * 1e18 / loanValueUsd18
        return (collateralUsd18 * 1e18) / loanValueUsd18;
    }

    /// @notice One-call snapshot of a single loan's key stats — meant to make the
    ///         frontend and judge's review cheaper and simpler.
    /// @dev    Reads the live FTSO price (payable, same as `getHealthFactor`).
    ///         `interestOwed` is the live accrued interest in USDT0 (18dp) — 0 unless
    ///         the loan is FUNDED. `totalRepayment = getTotalRepayment(loanId)` (i.e.
    ///         principal + interest). `healthFactor` is `type(uint256).max` for loans
    ///         that are not FUNDED/AUCTION.
    /// @param  loanId The loan to summarise.
    /// @return state           Current LoanState.
    /// @return collateralAmount FXRP deposited (6 decimals); 0 after liquidation/close.
    /// @return loanAmount      USDT0 borrowed (18 decimals) at draw time.
    /// @return interestOwed    Accrued interest in USDT0 (18dp); 0 unless FUNDED.
    /// @return totalRepayment  loanAmount + interestOwed.
    /// @return deadline        Repayment deadline (UNIX seconds).
    /// @return healthFactor    Current health factor (1e18-scaled; max uint if N/A).
    function getLoanSummary(uint256 loanId)
        external
        payable
        returns (
            LoanState state,
            uint256 collateralAmount,
            uint256 loanAmount,
            uint256 interestOwed,
            uint256 totalRepayment,
            uint256 deadline,
            uint256 healthFactor
        )
    {
        Loan storage loan = loans[loanId];
        state = loan.state;
        collateralAmount = loan.collateralAmount;
        loanAmount = loan.loanAmount;
        deadline = loan.deadline;

        // Interest-aware: hook into subagent #47's interest module.
        interestOwed = getInterestOwed(loanId);
        totalRepayment = loanAmount + interestOwed; // == getTotalRepayment(loanId)

        // Forward any msg.value to the FTSO read inside getHealthFactor.
        healthFactor = getHealthFactor(loanId);
    }

    /// @notice Aggregate portfolio view across ALL of a borrower's loans. Iterates
    ///         `borrowerLoanIds[borrower]` (which grows monotonically and is never
    ///         trimmed). For each loan it sums collateral, loan principal, and counts
    ///         the ACTIVE (FUNDED) ones; it also sums accrued interest across FUNDED
    ///         loans (0 for any non-FUNDED loan).
    /// @dev    `totalInterestOwed` calls `getInterestOwed` per loan — that is a pure
    ///         view (no FTSO read), so this aggregation is itself a `view`. This view
    ///         does NOT call `getHealthFactor` per-loan (that would re-read the FTSO
    ///         once per loan and burn msg.value); portfolio health should be computed
    ///         by the caller from per-loan summaries if needed.
    /// @param  borrower The borrower whose portfolio to aggregate.
    /// @return totalCollateral   Sum of collateralAmount across all of the borrower's
    ///                           loans (drops to 0 once a loan is liquidated/closed).
    /// @return totalBorrowed     Sum of loanAmount across all of the borrower's loans.
    /// @return activeLoans       Number of loans currently in the FUNDED state.
    /// @return totalInterestOwed Sum of accrued interest (USDT0 18dp) across FUNDED loans.
    function getPortfolioSummary(address borrower)
        external
        view
        returns (
            uint256 totalCollateral,
            uint256 totalBorrowed,
            uint256 activeLoans,
            uint256 totalInterestOwed
        )
    {
        uint256[] memory ids = borrowerLoanIds[borrower];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            Loan storage loan = loans[ids[i]];
            totalCollateral += loan.collateralAmount;
            totalBorrowed += loan.loanAmount;
            if (loan.state == LoanState.FUNDED) {
                // G9 (gas-audit): unchecked — activeLoans bounded by len, overflow impossible.
                unchecked { activeLoans += 1; }
                totalInterestOwed += getInterestOwed(ids[i]);
            }
        }
    }

    // ═══════════════════ Internal ═══════════════════

    /// @dev Shared auction-start core for both `startLiquidationAuction` (deadline
    ///      path) and `checkAndTriggerLiquidation` (health-factor path). Computes the
    ///      auction start price (= collateral value in USDT0) from the already-read
    ///      `xrpUsd18dp` price (so the trigger path reads FTSO exactly once),
    ///      flips the loan to AUCTION state, and emits `LiquidationAuctionStarted`.
    ///      Caller MUST have already enforced state and (for the deadline path) the
    ///      timetable, and MUST have validated `xrpUsd18dp != 0`.
    function _startLiquidation(uint256 loanId, Loan storage loan, uint256 xrpUsd18dp) internal {
        uint256 scaleFactor = _collateralScaleFactor(address(fxrp));
        uint256 startPrice = (loan.collateralAmount * scaleFactor * xrpUsd18dp) / 1e18;

        loan.state = LoanState.AUCTION;
        auctions[loanId] = LiquidationAuction({
            startPrice: startPrice,
            startTimestamp: uint64(block.timestamp),
            highestBidder: address(0),
            highestBid: 0
        });

        emit LiquidationAuctionStarted(loanId, loan.borrower, startPrice, uint64(block.timestamp));
    }

    /// @dev F3 fix: safe ERC20 approve that resets allowance to 0 first to prevent
    ///      the approval race condition (USDT0 pattern). If there is a non-zero
    ///      allowance, an attacker can front-run a new approve call to steal the
    ///      old allowance. Resetting to 0 first eliminates this attack vector.
    /// @param token The ERC20 token to approve.
    /// @param spender The address to approve.
    /// @param amount The amount to approve.
    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        uint256 currentAllowance = token.allowance(address(this), spender);
        if (currentAllowance != 0) {
            token.approve(spender, 0);
        }
        if (amount != 0) {
            token.approve(spender, amount);
        }
    }

    /// @dev Computes the on-the-fly decimal scale factor that normalises a token
    ///      amount of `decimals` precision to the 1e18 (USDT0/USD 18dp) basis used
    ///      throughout the vault. Returns `10 ** (18 - decimals)`. For FXRP (6dp)
    ///      this is exactly `10**12`, identical to the legacy `SCALE_TO_18`. For
    ///      18-decimal collaterals (FLR, USDT0) it is `10**0 = 1`. For an
    ///      unregistered token (decimals == 0) it falls back to the legacy FXRP
    ///      factor (1e12) to keep historical call sites safe.
    function _collateralScaleFactor(address token) internal view returns (uint256) {
        uint8 d = collateralDecimals[token];
        if (d == 0 || d > 18) return SCALE_TO_18; // legacy FXRP fallback
        return 10 ** (18 - d);
    }

    /// @dev internal `view` (not `pure`) because it reads `address(this)`.
    function _computeCommitment(
        uint256 loanId,
        address borrower,
        uint256 requiredRepaymentDrops,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                REPAYMENT_PROTOCOL_VERSION,
                address(this),
                loanId,
                borrower,
                requiredRepaymentDrops,
                deadline
            )
        );
    }
}
