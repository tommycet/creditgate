// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";
import {IXRPPayment} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title CreditGateVault FDCFixtureTest
/// @notice End-to-end fixture test that mirrors the real FDC attestation lifecycle:
///         1. Borrower deposits FXRP on Flare
///         2. TEE signs eligibility attestation (simulated)
///         3. Borrower draws USDT0 against collateral
///         4. Borrower repays on XRPL with a 32-byte memo commitment
///         5. FDC attestation submitted → vault verifies → loan CLOSED
/// @dev This uses the same MockFdcVerification pattern as unit tests but with
///      realistic XRPL-style values (6dp drops, r-address source, memo data).
contract CreditGateVaultFDCFixtureTest is Test {
    CreditGateVault public vault;
    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    uint256 constant TEE_PK = 0xA11CE;
    address constant TEE_AUTHORITY = address(0); // set in setUp via vm.addr
    address public borrower;
    address public lender;

    uint256 constant DEPOSIT_100_FXRP = 100e6;
    uint256 constant LOAN_100_USDT = 100e18; // USDT0 is 18dp on Coston2
    uint256 constant XRP_PRICE_2_50 = 2.5e18;
    uint64 constant FTSO_STALENESS_LIMIT = 300;
    uint256 constant LOAN_DURATION = 30 days;
    uint256 constant COLLATERAL_RATIO_BPS = 15000;

    // XRPL-style constants
    bytes32 constant XRPL_RECEIVER_HASH = keccak256("rCreditGateBorrower1");

    function setUp() public {
        address teeAuthority = vm.addr(TEE_PK);
        fxrp = new MockERC20("FlareXRP", "FXRP", 6);
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();

        vault = new CreditGateVault(
            address(fxrp),
            address(usdt0),
            teeAuthority,
            COLLATERAL_RATIO_BPS,
            FTSO_STALENESS_LIMIT,
            LOAN_DURATION,
            address(ftso),
            address(fdc)
        );

        borrower = makeAddr("borrower");
        lender = makeAddr("lender");

        // Fund borrower with FXRP, lender with USDT0
        fxrp.mint(borrower, 1000e6);
        usdt0.mint(lender, 10_000e18);

        // Set FTSO price
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        // Approvals
        vm.prank(borrower);
        fxrp.approve(address(vault), type(uint256).max);
        vm.prank(lender);
        usdt0.approve(address(vault), type(uint256).max);

        // Fund vault with USDT0 (lender deposits)
        vm.prank(lender);
        usdt0.transfer(address(vault), 10_000e18);

        // Register XRPL address
        vm.prank(borrower);
        vault.registerXRPLAddress(XRPL_RECEIVER_HASH);
    }

    // ═══════════════════ Helpers ═══════════════════

    function _signAttestation(
        address b,
        uint256 limit,
        uint64 expiry,
        uint32 nonce,
        uint8 revVersion
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 payloadHash = keccak256(
            abi.encode(
                keccak256("CREDITGATE_ELIGIBILITY_V1"),
                b, limit, expiry, nonce, revVersion
            )
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash)
        );
        (v, r, s) = vm.sign(TEE_PK, ethSignedHash);
    }

    function _buildRealisticProof(
        uint256 receivedDrops,
        bytes32 memoData,
        bytes32 receiverHash
    ) internal view returns (IXRPPayment.Proof memory) {
        IXRPPayment.ResponseBody memory respBody = IXRPPayment.ResponseBody({
            blockNumber: 41234567,
            blockTimestamp: uint64(block.timestamp),
            sourceAddress: "rUnusedSourceAddress",
            sourceAddressHash: keccak256("rUnusedSourceAddress"),
            receivingAddressHash: receiverHash,
            intendedReceivingAddressHash: receiverHash,
            spentAmount: int256(uint256(receivedDrops)),
            intendedSpentAmount: int256(uint256(receivedDrops)),
            receivedAmount: int256(uint256(receivedDrops)),
            intendedReceivedAmount: int256(uint256(receivedDrops)),
            hasMemoData: true,
            firstMemoData: abi.encodePacked(memoData),
            hasDestinationTag: false,
            destinationTag: 0,
            status: 0
        });

        IXRPPayment.RequestBody memory reqBody = IXRPPayment.RequestBody({
            transactionId: keccak256("fixture-tx"),
            proofOwner: borrower
        });

        IXRPPayment.Response memory resp = IXRPPayment.Response({
            attestationType: bytes32(0),
            sourceId: bytes32(0),
            votingRound: 4021,
            lowestUsedTimestamp: block.timestamp > 100 ? uint64(block.timestamp - 100) : 1,
            requestBody: reqBody,
            responseBody: respBody
        });

        return IXRPPayment.Proof({merkleProof: new bytes32[](1), data: resp});
    }

    function _setupEligibleLoan() internal returns (uint256 loanId) {
        vm.startPrank(borrower);
        loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vault.requestEligibility(loanId);
        vm.stopPrank();

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(borrower, LOAN_100_USDT, expiry, 0, 0);
        vm.prank(borrower);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower,
            limit: LOAN_100_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));
    }

    // ═══════════════════ Tests ═══════════════════

    function test_fixture_fullLifecycle() public {
        uint256 loanId = _setupEligibleLoan();
        assertEq(uint8(vault.getLoan(loanId).state), uint8(CreditGateTypes.LoanState.ELIGIBLE));

        // Draw
        vm.prank(borrower);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(CreditGateTypes.LoanState.FUNDED));
        assertEq(loan.loanAmount, LOAN_100_USDT);

        // Repay on XRPL → FDC attestation
        fdc.setResult(true);
        IXRPPayment.Proof memory proof = _buildRealisticProof(
            loan.requiredRepaymentDrops,
            loan.expectedCommitment,
            XRPL_RECEIVER_HASH
        );

        vm.prank(borrower);
        vault.submitRepaymentProof(loanId, proof);
        assertEq(uint8(vault.getLoan(loanId).state), uint8(CreditGateTypes.LoanState.CLOSED));
        // Collateral was already released on proof submission (vault closes and refunds).
        // The borrower should have received their 100 FXRP back immediately.
        assertEq(fxrp.balanceOf(borrower), 1000e6); // 900e6 initial + 100e6 returned
    }

    function test_fixture_commitmentIsLoanSpecific() public {
        uint256 loanId = _setupEligibleLoan();
        vm.prank(borrower);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);

        // Wrong memo (from a different loan)
        fdc.setResult(true);
        IXRPPayment.Proof memory proof = _buildRealisticProof(
            loan.requiredRepaymentDrops,
            bytes32(uint256(0xDEADBEEF)),
            XRPL_RECEIVER_HASH
        );
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.CommitmentMismatch.selector,
                loan.expectedCommitment,
                bytes32(uint256(0xDEADBEEF))
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }
    function test_fixture_borrowerWithdrawsAfterClose() public {
        uint256 loanId = _setupEligibleLoan();
        vm.prank(borrower);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);

        fdc.setResult(true);
        IXRPPayment.Proof memory proof = _buildRealisticProof(
            loan.requiredRepaymentDrops,
            loan.expectedCommitment,
            XRPL_RECEIVER_HASH
        );
        vm.prank(borrower);
        vault.submitRepaymentProof(loanId, proof);

        // Collateral was released at proof submission. Borrowing a second time
        // reuses the released FXRP: deposit again with the returned balance.
        uint256 balAfterClose = fxrp.balanceOf(borrower);
        assertEq(balAfterClose, 1000e6); // 900e6 initial + 100e6 returned

        // Second loan: deposit 50 of the returned collateral, DON'T request eligibility
        vm.startPrank(borrower);
        uint256 loanId2 = vault.depositCollateral(50e6);
        vm.stopPrank();
        assertEq(uint8(vault.getLoan(loanId2).state), uint8(CreditGateTypes.LoanState.COLLATERAL_DEPOSITED));

        // Withdraw collateral from the never-used second loan (returns the 50e6)
        vm.prank(borrower);
        vault.withdrawCollateral(loanId2);
        assertEq(fxrp.balanceOf(borrower), balAfterClose); // 50e6 back = full balance restored
        assertEq(uint8(vault.getLoan(loanId2).state), uint8(CreditGateTypes.LoanState.IDLE));
    }

    function test_fixture_liquidationAfterDeadline() public {
        uint256 loanId = _setupEligibleLoan();
        vm.prank(borrower);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);

        // Warp past deadline
        vm.warp(loan.deadline + 1);

        // No one submitted proof → liquidate
        vm.prank(lender);
        vault.liquidate(loanId);
        assertEq(uint8(vault.getLoan(loanId).state), uint8(CreditGateTypes.LoanState.DEFAULTED));
        // Liquidation seizes FXRP (stays in vault) — lender's USDT0 was already
        // transferred into the vault at setUp (lender balance now 0).
        assertEq(usdt0.balanceOf(lender), 0);
        assertEq(fxrp.balanceOf(address(vault)), DEPOSIT_100_FXRP);
    }
}
