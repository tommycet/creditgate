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

    address public owner;
    bool public paused;

    uint256 public nextLoanId = 1; // 0 is unused (IDLE sentinel)

    mapping(uint256 => Loan) public loans;
    mapping(address => uint32) public borrowerNonce; // next eligibility nonce per borrower
    mapping(address => uint8) public borrowerRevocationVersion; // current revocation version
    mapping(address => bool) public eligibilityRevoked; // fast-revoke flag
    mapping(bytes32 => bool) public proofConsumed; // anti-replay for FDC proofs

    /// @dev Tracks the active loan id per borrower slot used to scope withdrawal/eligibility.
    mapping(address => uint256[]) public borrowerLoanIds;

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

    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    /// @notice Mark a borrower's eligibility as revoked. Bumps revocation version so any
    ///         outstanding eligibility attestation with an older version is rejected.
    function revokeEligibility(address borrower) external onlyOwner {
        eligibilityRevoked[borrower] = true;
        // Bump revocation version (cap at max uint8 to avoid overflow wrap).
        if (borrowerRevocationVersion[borrower] < type(uint8).max) {
            borrowerRevocationVersion[borrower] += 1;
        }
    }

    // ═══════════════════ Borrower Flow ═══════════════════

    /// @notice Deposit FXRP collateral and open a new loan slot.
    /// @dev   Pulls `amount` of FXRP from the caller via `transferFrom`. Creates a Loan
    ///        in state `COLLATERAL_DEPOSITED` and assigns the next monotonic loan id.
    ///        Reverts on zero amount or failed transfer.
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
    function submitEligibility(uint256 loanId, EligibilityAttestation calldata attestation)
        external
        nonReentrant
        whenNotPaused
    {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.ELIGIBILITY_PENDING) {
            revert InvalidLoanState(loan.state, LoanState.ELIGIBILITY_PENDING);
        }
        require(loan.borrower == msg.sender, "NotBorrower");

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
        address recovered = ecrecover(
            ethSignedHash, attestation.v, attestation.r, attestation.s
        );
        if (recovered != teeAuthority) {
            revert InvalidEligibilitySigner(recovered, teeAuthority);
        }
        if (attestation.borrower != loan.borrower) {
            revert BorrowerMismatch(loan.borrower, attestation.borrower);
        }
        if (attestation.nonce != loan.eligibilityNonce) {
            revert NonceMismatch(loan.eligibilityNonce, attestation.nonce);
        }

        // Success → ELIGIBLE. Store limit / expiry on the loan.
        loan.eligibilityExpiry = attestation.expiry;
        loan.state = LoanState.ELIGIBLE;

        emit EligibilitySubmitted(loanId, loan.borrower, attestation.limit, attestation.expiry);
    }

    /// @notice Draw a USDT0 loan against eligible collateral. Reads the live FTSOv2
    ///         XRP/USD price, enforces the collateral ratio, computes the required XRP
    ///         drops repayment and the memo commitment, then disburses USDT0 to the
    ///         borrower and transitions to `FUNDED`.
    /// @dev   `msg.value` is forwarded to the (payable) `getFeedByIdInWei` call to cover
    ///         any FTSO query fee on Flare. On Coston2 the fee is currently zero.
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
        require(loan.borrower == msg.sender, "NotBorrower");
        if (loanAmount == 0) revert ZeroAmount();

        // ── Read FTSOv2 XRP/USD price (18 decimals, in wei) ──
        (uint256 xrpUsd18dp, uint64 feedTimestamp) =
            FtsoV2Interface(ftsoV2).getFeedByIdInWei{value: msg.value}(XRP_USD_FEED_ID);

        if (xrpUsd18dp == 0) revert FTSOPriceZero();
        if (uint64(block.timestamp) - feedTimestamp > ftsoStalenessLimit) {
            revert FTSOPriceStale(feedTimestamp, ftsoStalenessLimit);
        }

        // ── Collateral ratio check ──
        // collateralUsd18 = collateralFxrp6dp * 1e12 * xrpUsd18dp / 1e18 (rounds down)
        // loanUsd18        = loanUsdt0_6dp * 1e12
        // require collateralUsd18 * 10000 >= loanUsd18 * collateralRatioBps
        uint256 collateralUsd18 =
            (loan.collateralAmount * SCALE_TO_18 * xrpUsd18dp) / 1e18;
        uint256 loanUsd18 = loanAmount * SCALE_TO_18;
        if (collateralUsd18 * 10000 < loanUsd18 * collateralRatioBps) {
            revert InsufficientCollateral(
                collateralUsd18 * 10000, loanUsd18 * collateralRatioBps
            );
        }

        // ── Compute required repayment drops ──
        // drops = loanAmount6dp * 1e18 / xrpPriceInWei18dp
        // (USDT0 6dp → USD 18dp via *1e12, then ÷ XRP/USD 18dp = XRP 6dp = drops 6dp)
        uint256 requiredRepaymentDrops = (loanAmount * 1e18) / xrpUsd18dp;

        uint256 deadline = block.timestamp + loanDuration;

        // ── Compute & store commitment for FDC memo binding ──
        bytes32 commitment =
            _computeCommitment(loanId, loan.borrower, requiredRepaymentDrops, deadline);

        loan.loanAmount = loanAmount;
        loan.requiredRepaymentDrops = requiredRepaymentDrops;
        loan.deadline = deadline;
        loan.expectedCommitment = commitment;
        loan.state = LoanState.FUNDED;

        // ── Disburse USDT0 from vault to borrower ──
        usdt0.safeTransfer(loan.borrower, loanAmount);

        emit LoanFunded(
            loanId, loan.borrower, loanAmount, loan.collateralAmount, commitment
        );
    }

    /// @notice Submit an FDC-verified XRPL payment proof to close a funded loan.
    ///         Verifies the proof via FdcVerification, checks the payment status, the
    ///         received amount ≥ required drops, and the memo matches `expectedCommitment`.
    ///         On success, releases FXRP collateral to the borrower and transitions to
    ///         `CLOSED`.
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
    function liquidate(uint256 loanId) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        if (loan.state != LoanState.FUNDED) {
            revert InvalidLoanState(loan.state, LoanState.FUNDED);
        }
        if (block.timestamp < loan.deadline) revert DeadlineNotPassed();

        uint256 collateralSeized = loan.collateralAmount;
        loan.collateralAmount = 0;
        loan.state = LoanState.DEFAULTED;
        // Collateral remains in the vault — owner may recover via a separate function
        // (intentionally not exposed here to keep the scope of this hackathon contract small).

        emit LoanDefaulted(loanId, loan.borrower, collateralSeized);
    }

    // ═══════════════════ Views ═══════════════════

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    function getBorrowerLoanIds(address borrower)
        external
        view
        returns (uint256[] memory)
    {
        return borrowerLoanIds[borrower];
    }

    // ═══════════════════ Internal ═══════════════════

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
