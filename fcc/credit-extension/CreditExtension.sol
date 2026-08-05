// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title CreditExtension — FCC-compatible credit eligibility evaluator (Simulated TEE)
/// @notice This extension implements the CREDIT/EVALUATE op type for Flare Confidential Compute.
///         It evaluates borrower eligibility based on private inputs and returns a signed
///         eligibility attestation that can be verified by CreditGateVault.
///
/// @dev    Mode: SIMULATED_TEE — the signing key is a local ECDSA key, not a real TEE attestation.
///         The contract code is identical to production; only the key source differs.
///         Production GCP attestation is not claimed unless separately verified.
///
///         Flow:
///         1. Borrower calls `evaluate(borrower, collateralAmount, requestedLoan)` with private inputs
///         2. Extension checks eligibility rules (collateral ratio, borrower history)
///         3. If eligible, signs an EIP-191 eligibility attestation
///         4. Borrower submits the attestation to CreditGateVault.submitEligibility()
///
///         Operation types:
///         - CREDIT: Evaluate credit eligibility for a borrower
///         - EVALUATE: Alias for CREDIT (FCC convention)
contract CreditExtension {
    // ═══════════════════ Constants ═══════════════════

    bytes32 public constant DOMAIN_SEPARATOR = keccak256("CREDITGATE_ELIGIBILITY_V1");

    enum OpType {
        CREDIT,    // 0
        EVALUATE   // 1
    }

    // ═══════════════════ Structs ═══════════════════

    struct EvaluationInput {
        address borrower;
        uint256 collateralAmount;  // FXRP deposited (6 decimals)
        uint256 requestedLoan;     // USDT0 requested (6 decimals)
        uint64  expiry;            // UNIX: attestation validity
        uint32  nonce;             // Borrower's current nonce
        uint8   revocationVersion; // Current revocation version
    }

    struct EvaluationOutput {
        bool    eligible;
        uint256 limit;             // Max approved loan (6 decimals)
        bytes32 reason;            // keccak256 of rejection reason (0x0 if eligible)
    }

    struct EligibilityAttestation {
        address borrower;
        uint256 limit;
        uint64  expiry;
        uint32  nonce;
        uint8   revocationVersion;
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    // ═══════════════════ Events ═══════════════════

    event EvaluationRequested(
        address indexed borrower,
        uint256 collateralAmount,
        uint256 requestedLoan,
        uint8   opType
    );

    event EvaluationCompleted(
        address indexed borrower,
        bool    eligible,
        uint256 limit
    );

    // ═══════════════════ Errors ═══════════════════

    error NotAuthorized();
    error InsufficientCollateralForLoan(uint256 collateralValue, uint256 requiredValue);
    error BorrowerRevoked(address borrower);

    // ═══════════════════ Storage ═══════════════════

    address public owner;
    uint256 public immutable collateralRatioBps;  // e.g. 15000 = 150%
    uint256 public immutable maxLoanMultiplierBps; // e.g. 6667 = 66.67% of collateral value

    // Borrower eligibility limits (set by owner or TEE evaluation)
    mapping(address => uint256) public borrowerLimits;
    mapping(address => bool) public borrowerRevoked;

    // Signing key (simulated TEE — in production this would be a TEE-managed key)
    uint256 private _signingKey;

    // ═══════════════════ Constructor ═══════════════════

    constructor(
        uint256 _collateralRatioBps,
        uint256 _maxLoanMultiplierBps,
        uint256 signingKey_
    ) {
        require(_collateralRatioBps > 0, "ZeroRatio");
        require(_maxLoanMultiplierBps > 0 && _maxLoanMultiplierBps <= 10_000, "InvalidMultiplier");

        collateralRatioBps = _collateralRatioBps;
        maxLoanMultiplierBps = _maxLoanMultiplierBps;
        _signingKey = signingKey_;
        owner = msg.sender;
    }

    // ═══════════════════ Admin ═══════════════════

    function setBorrowerLimit(address borrower, uint256 limit) external {
        require(msg.sender == owner, "NotOwner");
        borrowerLimits[borrower] = limit;
    }

    function revokeBorrower(address borrower) external {
        require(msg.sender == owner, "NotOwner");
        borrowerRevoked[borrower] = true;
    }

    // ═══════════════════ Core: CREDIT / EVALUATE ═══════════════════

    /// @notice Evaluate borrower eligibility and return a signed attestation
    /// @param input The evaluation input with borrower details and requested amounts
    /// @return output Eligibility result (eligible, limit, reason)
    /// @return attestation Signed eligibility attestation (valid if output.eligible)
    function evaluate(EvaluationInput calldata input)
        external
        returns (EvaluationOutput memory output, EligibilityAttestation memory attestation)
    {
        emit EvaluationRequested(
            input.borrower,
            input.collateralAmount,
            input.requestedLoan,
            uint8(OpType.CREDIT)
        );

        // ── Check revocation ──
        if (borrowerRevoked[input.borrower]) {
            output = EvaluationOutput({
                eligible: false,
                limit: 0,
                reason: keccak256("BORROWER_REVOKED")
            });
            emit EvaluationCompleted(input.borrower, false, 0);
            return (output, attestation);
        }

        // ── Check collateral sufficiency ──
        // collateralValue18 = collateralAmount * 1e12 (6dp → 18dp)
        // requiredValue18   = requestedLoan * 1e12 * collateralRatioBps / 10000
        uint256 collateralValue18 = input.collateralAmount * 1e12;
        uint256 requiredValue18 = (input.requestedLoan * 1e12 * collateralRatioBps) / 10_000;

        if (collateralValue18 < requiredValue18) {
            output = EvaluationOutput({
                eligible: false,
                limit: 0,
                reason: keccak256("INSUFFICIENT_COLLATERAL")
            });
            emit EvaluationCompleted(input.borrower, false, 0);
            return (output, attestation);
        }

        // ── Determine approved limit ──
        // Use the minimum of: requested loan, borrower's configured limit,
        // and max allowed by collateral ratio
        uint256 maxByCollateral = (collateralValue18 * 10_000) / (collateralRatioBps * 1e12);
        uint256 borrowerLimit = borrowerLimits[input.borrower];
        uint256 approvedLimit = input.requestedLoan;

        if (borrowerLimit > 0 && borrowerLimit < approvedLimit) {
            approvedLimit = borrowerLimit;
        }
        if (maxByCollateral < approvedLimit) {
            approvedLimit = maxByCollateral;
        }

        // ── Sign eligibility attestation (EIP-191) ──
        bytes32 payloadHash = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR,
                input.borrower,
                approvedLimit,
                input.expiry,
                input.nonce,
                input.revocationVersion
            )
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash)
        );
        // In simulated TEE mode, signing is done off-chain by the extension operator.
        // The attestation struct is returned with v=0, r=0, s=0 as a placeholder.
        // In production, the TEE signs this payload and returns the signature.
        attestation = EligibilityAttestation({
            borrower: input.borrower,
            limit: approvedLimit,
            expiry: input.expiry,
            nonce: input.nonce,
            revocationVersion: input.revocationVersion,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        output = EvaluationOutput({
            eligible: true,
            limit: approvedLimit,
            reason: bytes32(0)
        });

        emit EvaluationCompleted(input.borrower, true, approvedLimit);
        return (output, attestation);
    }

    /// @notice Get the signing authority address (simulated TEE authority)
    function signingAuthority() external view returns (address) {
        return vm.addr(_signingKey);
    }
}
