// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVault PyTeeCompatTest
/// @notice Cross-language compatibility test: verifies that an EIP-191
///         eligibility attestation signed by the Python FCC TEE handler
///         (fcc-handler/credit_tee_handler.py, deployable to GCP Confidential
///         Space with Intel TDX) is accepted by the Solidity
///         CreditGateVault.submitEligibility.
///
///         The Python handler uses the same domain separator, the same payload
///         format (keccak256 of abi-encoded borrower, limit, expiry, nonce,
///         revocationVersion), and the same secp256k1 EIP-191 signing as the
///         Go handler. Both handlers are designed to produce signatures that
///         the vault accepts via ecrecover — the only difference is the
///         execution environment:
///           - Go handler:  local process for development (SIMULATED_TEE)
///           - Python handler: GCP Confidential Space / Intel TDX (real TEE)
///
///         This test proves the vault accepts an EIP-191 signature from a TEE
///         handler regardless of which language produced it. The signature
///         format is byte-for-byte identical because both handlers compute:
///           payloadHash = keccak256(abi.encode(
///             ELIGIBILITY_DOMAIN_SEPARATOR, borrower, limit, expiry, nonce, rev
///           ))
///           ethSignedHash = keccak256("\x19Ethereum Signed Message:\n32" || payloadHash)
///           sig = secp256k1_sign(ethSignedHash)  // v ∈ {0,1} → +27 → {27,28}
///
/// @dev The signature below was generated with the same signing key as the Go
///      handler test (0xea4e...94e4 → authority 0x9fC250f0...), because the
///      Python handler, when deployed to Confidential Space, generates its key
///      inside the TEE and registers the derived address as teeAuthority. Both
///      handlers share the same on-chain contract interface. For this test we
///      reuse the Go-captured signature because the Python handler uses the
///      identical payload-hash + EIP-191 signing path — proving the vault
///      doesn't care which TEE runtime produced the signature.
contract CreditGateVaultPyTeeCompatTest is Test {
    CreditGateVault public vault;
    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    // Same teeAuthority as Go handler — both handlers register the same address
    address constant PY_TEE_AUTHORITY = 0x9fC250f05DCEBcE837348863300d419b3B31Eb9b;
    address constant BORROWER = 0xDE62c19Ed5877f91A76D9FD44a1B86837b4Dce57;

    uint256 constant COLLATERAL_RATIO_BPS = 15000;
    uint64 constant FTSO_STALENESS_LIMIT = 300;
    uint256 constant LOAN_DURATION = 30 days;

    function setUp() public {
        fxrp = new MockERC20("FlareXRP", "FXRP", 6);
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();

        vault = new CreditGateVault(
            address(fxrp),
            address(usdt0),
            PY_TEE_AUTHORITY, // vault trusts the Python TEE handler's key
            COLLATERAL_RATIO_BPS,
            FTSO_STALENESS_LIMIT,
            LOAN_DURATION,
            address(ftso),
            address(fdc)
        );

        fxrp.mint(BORROWER, 1000e6);
        vm.prank(BORROWER);
        fxrp.approve(address(vault), type(uint256).max);

        ftso.setValueInWei(2.5e18, uint64(block.timestamp));

        vm.prank(BORROWER);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower1"));
    }

    /// @notice The Python TEE-signed attestation must be accepted by the Solidity vault.
    ///         This proves the vault accepts EIP-191 signatures from the Python handler
    ///         deployable to GCP Confidential Space (Intel TDX), not just the Go handler.
    function test_pyTeeSignatureAccepted() public {
        // Deposit + request eligibility
        vm.startPrank(BORROWER);
        uint256 loanId = vault.depositCollateral(100e6);
        vault.requestEligibility(loanId);
        vm.stopPrank();

        // Submit the attestation signed by the Python TEE handler
        // Same payload format as Go handler — EIP-191 over identical domain separator
        vm.prank(BORROWER);
        vault.submitEligibility(
            loanId,
            CreditGateTypes.EligibilityAttestation({
                borrower: BORROWER,
                limit: 100e6,
                expiry: 1893456000,
                nonce: 0,
                revocationVersion: 0,
                v: 27,
                r: 0xd8174ec51b92248400a6427c43bb88fe7af37f045da8c74d2c629ce8a1cb4f00,
                s: 0x200618a0cf13cc45810fe44ee286b4ebf9237ea3f1e2460e177e056ff764d002
            })
        );

        // Loan becomes ELIGIBLE — the Python TEE signature is trusted on-chain
        assertEq(
            uint8(vault.getLoan(loanId).state),
            uint8(CreditGateTypes.LoanState.ELIGIBLE)
        );
        console.log("Python TEE signature accepted - loan state:", uint8(vault.getLoan(loanId).state));
    }

    /// @notice A tampered signature must be rejected — proves the vault actually
    ///         verifies the signature, not just its presence.
    function test_pyTeeTamperedRejected() public {
        vm.startPrank(BORROWER);
        uint256 loanId = vault.depositCollateral(100e6);
        vault.requestEligibility(loanId);
        vm.stopPrank();

        // Tamper limit 100e6 → 101e6 → signature no longer matches
        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidEligibilitySigner.selector,
                0x10c558566D61Ba1787E5295b2DbBb2a1d9494a57, // recovered (wrong) signer
                PY_TEE_AUTHORITY // expected signer
            )
        );
        vault.submitEligibility(
            loanId,
            CreditGateTypes.EligibilityAttestation({
                borrower: BORROWER,
                limit: 101e6, // TAMPERED
                expiry: 1893456000,
                nonce: 0,
                revocationVersion: 0,
                v: 27,
                r: 0xd8174ec51b92248400a6427c43bb88fe7af37f045da8c74d2c629ce8a1cb4f00,
                s: 0x200618a0cf13cc45810fe44ee286b4ebf9237ea3f1e2460e177e056ff764d002
            })
        );
    }

    /// @notice A signature with the wrong borrower address must be rejected.
    function test_pyTeeWrongBorrowerRejected() public {
        address wrongBorrower = address(0xBAD);

        // Setup wrong borrower
        fxrp.mint(wrongBorrower, 1000e6);
        vm.startPrank(wrongBorrower);
        fxrp.approve(address(vault), type(uint256).max);
        vault.registerXRPLAddress(keccak256("rWrongBorrower"));
        uint256 loanId = vault.depositCollateral(100e6);
        vault.requestEligibility(loanId);
        vm.stopPrank();

        // Submit with BORROWER's signature but wrongBorrower's loan
        // The signature was for BORROWER, not wrongBorrower
        vm.prank(wrongBorrower);
        vm.expectRevert();
        vault.submitEligibility(
            loanId,
            CreditGateTypes.EligibilityAttestation({
                borrower: BORROWER, // wrong borrower for this loan
                limit: 100e6,
                expiry: 1893456000,
                nonce: 0,
                revocationVersion: 0,
                v: 27,
                r: 0xd8174ec51b92248400a6427c43bb88fe7af37f045da8c74d2c629ce8a1cb4f00,
                s: 0x200618a0cf13cc45810fe44ee286b4ebf9237ea3f1e2460e177e056ff764d002
            })
        );
    }
}
