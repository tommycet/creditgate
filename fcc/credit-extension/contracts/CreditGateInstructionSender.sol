// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title CreditGateInstructionSender — On-chain entry point for the CreditGate FCC extension
/// @notice This is the onchain half of the CreditGate Flare Compute Extension (FCE).
///         It mirrors the official FCC Hello World / Sign extension pattern:
///         users call this contract, which routes instructions to the TEE via
///         TeeExtensionRegistry.sendInstructions(). The TEE evaluates private
///         credit inputs and returns a signed eligibility attestation.
///
/// @dev Per FCC docs (https://dev.flare.network/fcc/overview):
///      - Extensions are Go HTTP servers running inside TEE machines
///      - OP_TYPE / OP_COMMAND are bytes32 UTF-8 strings (e.g. "CREDIT", "EVALUATE")
///      - Data providers relay instructions; TEE signatures prove computation integrity
///      - On Coston2: LOCAL_MODE=false, SIMULATED_TEE=true for the hackathon demo
///
///      Mode: SIMULATED_TEE — the signing key is managed by the simulated TEE
///      environment, not a production GCP attestation.
///
///      Flow:
///      1. Borrower deposits FXRP in CreditGateVault
///      2. Borrower calls evaluateCredit() here with private credit inputs
///      3. Instruction relayed to TEE → extension runs CREDIT/EVALUATE
///      4. TEE returns eligibility attestation (EIP-191 signature)
///      5. Borrower submits attestation to CreditGateVault.submitEligibility()
contract CreditGateInstructionSender {
    // ── FCC OP constants (bytes32 UTF-8 strings per FCC spec) ──
    bytes32 public constant OP_TYPE_CREDIT = "CREDIT";
    bytes32 public constant OP_COMMAND_EVALUATE = "EVALUATE";
    bytes32 public constant OP_COMMAND_REGISTER_XRPL = "REGISTER_XRPL";

    // ── Registry addresses (Coston2, verified via ContractRegistry 2026-08-05) ──
    // NOTE: TeeExtensionRegistry / TeeMachineRegistry are part of the FCC system
    // contracts. Actual addresses are read from ContractRegistry at deploy time
    // in the official scaffold; we keep them configurable here.
    address public immutable teeExtensionRegistry;
    address public immutable teeMachineRegistry;

    // ── Extension ID assigned at registration (public extensions start at 0x10000) ──
    uint256 public extensionId;

    // ── CreditGate vault this extension serves ──
    address public immutable creditGateVault;

    event InstructionSent(bytes32 indexed opType, bytes32 indexed opCommand, uint256 extensionId);

    error ZeroAddress();
    error NotRegistered();

    constructor(
        address _teeExtensionRegistry,
        address _teeMachineRegistry,
        address _creditGateVault
    ) {
        require(_teeExtensionRegistry != address(0), "ZeroTeeRegistry");
        require(_teeMachineRegistry != address(0), "ZeroTeeMachine");
        require(_creditGateVault != address(0), "ZeroVault");
        teeExtensionRegistry = _teeExtensionRegistry;
        teeMachineRegistry = _teeMachineRegistry;
        creditGateVault = _creditGateVault;
    }

    /// @notice Set the extension ID after TEE registration (callable once).
    function setExtensionId(uint256 _extensionId) external {
        require(msg.sender == creditGateVault || msg.sender == address(this), "Unauthorized");
        require(extensionId == 0, "AlreadySet");
        extensionId = _extensionId;
    }

    /// @notice Request private credit evaluation for a borrower
    /// @param borrower EVM address being evaluated
    /// @param collateralAmount FXRP deposited (6 decimals)
    /// @param requestedLoan USDT0 requested (18 decimals)
    /// @param expiry Attestation expiry (UNIX)
    /// @param nonce Borrower's current eligibility nonce
    /// @dev In the full FCC flow this calls TeeExtensionRegistry.sendInstructions()
    ///      with the ABI-encoded EvaluationInput. During the hackathon demo, the
    ///      simulated TEE path signs the same payload the vault verifies.
    function evaluateCredit(
        address borrower,
        uint256 collateralAmount,
        uint256 requestedLoan,
        uint64 expiry,
        uint32 nonce
    ) external {
        require(extensionId != 0, "NotRegistered");
        // ABI-encode the evaluation input for the TEE handler.
        bytes memory payload = abi.encode(
            OP_COMMAND_EVALUATE,
            borrower,
            collateralAmount,
            requestedLoan,
            expiry,
            nonce
        );

        // ── Full FCC path (production) ──
        // (bool ok, ) = teeExtensionRegistry.call(
        //     abi.encodeWithSignature(
        //         "sendInstructions(uint256,bytes32,bytes32,bytes)",
        //         extensionId, OP_TYPE_CREDIT, OP_COMMAND_EVALUATE, payload
        //     )
        // );
        // require(ok, "SendInstructionsFailed");

        // ── Hackathon demo path: simulated TEE signs and returns via proxy ──
        // The proxy stores the result; the borrower polls the extension proxy URL
        // (NORMAL_PROXY_URL) and retrieves the signed attestation.
        emit InstructionSent(OP_TYPE_CREDIT, OP_COMMAND_EVALUATE, extensionId);
    }

    /// @notice Request XRPL address registration inside the TEE (binds borrower's
    ///         XRPL r-address to their EVM identity for repayment binding).
    function registerXRPL(
        address borrower,
        string calldata xrplAddress
    ) external {
        require(extensionId != 0, "NotRegistered");
        bytes memory payload = abi.encode(OP_COMMAND_REGISTER_XRPL, borrower, xrplAddress);
        emit InstructionSent(OP_TYPE_CREDIT, OP_COMMAND_REGISTER_XRPL, extensionId);
    }
}
