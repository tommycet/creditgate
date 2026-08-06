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
    IERC20 public immutable usdt0; // 6-decimal USDT0
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

    /// @dev Tracks the active loan id per borrower slot used to scope withdrawal/eligibility.
    mapping(address => uint256[]) public borrowerLoanIds;

    // ═══════════════════ Borrower XRPL Address Binding ═══════════════════
    /// @dev Maps an EVM borrower to their XRPL r-address (as standard address hash).
    ///      This binds the FDC repayment proof's receivingAddressHash to the borrower,
    ///      preventing repayment substitution attacks where someone repays to a
    ///      different XRPL address but reuses a valid memo commitment.
    mapping(address => bytes32) public borrowerXRPLAddressHash;

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
    /// @param  _usdt0               USDT0 loan token (6 decimals).
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
    /// @param  borrower The borrower whose eligibility is being revoked.
    function revokeEligibility(address borrower) external onlyOwner {
        eligibilityRevoked[borrower] = true;
        // Bump revocation version (cap at max uint8 to avoid overflow wrap).
        if (borrowerRevocationVersion[borrower] < type(uint8).max) {
            borrowerRevocationVersion[borrower] += 1;
        }
        // M2 fix: rotate the nonce so outstanding attestations are invalidated.
        if (borrowerNonce[borrower] < type(uint32).max) {
            borrowerNonce[borrower] += 1;
        }
    }

    /// @notice Register the borrower's XRPL r-address (as a standard address hash).
    ///         Required before drawing a loan — the FDC repayment proof's
    ///         receivingAddressHash must match this binding.
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
    /// @param  loanAmount Amount of USDT0 (6 decimals) to borrow.
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

        // ── Collateral ratio check ──
        // FXRP collateral: 6dp, USDT0 loan: 18dp, FTSO price: 18dp.
        // collateralUsd18 = collateralFxrp6dp * 1e12 * xrpUsd18dp / 1e18
        // loanUsd18        = loanUsdt0_18dp  (already 18dp, no scaling needed)
        uint256 collateralUsd18 =
            (loan.collateralAmount * SCALE_TO_18 * xrpUsd18dp) / 1e18;
        uint256 loanUsd18 = loanAmount; // USDT0 is 18dp → already in USD 18dp
        if (collateralUsd18 * 10000 < loanUsd18 * collateralRatioBps) {
            revert InsufficientCollateral(
                collateralUsd18 * 10000, loanUsd18 * collateralRatioBps
            );
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
    ///         received amount ≥ required drops, and the memo matches `expectedCommitment`.
    ///         On success, releases FXRP collateral to the borrower and transitions to
    ///         `CLOSED`.
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
        require(loan.borrower == msg.sender, "NotBorrower");

        // Anti-replay: each FDC proof can only be consumed once.
        bytes32 proofHash = keccak256(abi.encode(proof));
        if (proofConsumed[proofHash]) revert ProofAlreadyConsumed();

        // Verify the proof through Flare FDC.
        bool proved =
            IXRPPaymentVerification(fdcVerification).verifyXRPPayment(proof);
        if (!proved) revert FDCVerificationFailed();

        IXRPPayment.ResponseBody memory resp = proof.data.responseBody;

        if (resp.status != 0) revert PaymentFailed(resp.status);
        if (uint256(int256(resp.receivedAmount)) < loan.requiredRepaymentDrops) {
            revert InsufficientRepayment(resp.receivedAmount, loan.requiredRepaymentDrops);
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

        // Release FXRP collateral back to borrower and close.
        uint256 collateralReleased = loan.collateralAmount;
        loan.collateralAmount = 0;
        loan.state = LoanState.CLOSED;

        fxrp.safeTransfer(loan.borrower, collateralReleased);

        emit RepaymentProofSubmitted(loanId, proofHash, resp.receivedAmount);
        emit LoanClosed(loanId, loan.borrower, collateralReleased);
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

    // ═══════════════════ Views ═══════════════════

    /// @notice Fetch the full Loan struct for a given loan id.
    /// @param  loanId The loan id to look up.
    /// @return The Loan struct (memory copy) for the given id.
    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
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

    // ═══════════════════ Internal ═══════════════════

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
