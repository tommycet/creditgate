// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";
import {IXRPPayment} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";
import {IXRPPaymentVerification} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPaymentVerification.sol";

/// @title CreditGateVault.ProtocolReserve — Tests for protocol reserve fund
/// @dev Inspired by Aave's Safety Module. 1% fee on repayment collateral.
contract CreditGateVaultProtocolReserveTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    // Test accounts
    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public nonOwner = makeAddr("nonOwner");

    // TEE authority key pair
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config constants
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300;
    uint256 constant LOAN_DURATION = 7 days;
    uint256 constant XRP_PRICE_2_50 = 2.5e18;
    uint256 constant DEPOSIT_100_FXRP = 100e6;
    uint256 constant LOAN_100_USDT = 100e18;
    uint256 constant LOAN_150_USDT = 150e18;

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);

        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", 6);
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

        fxrp.mint(borrower1, 1_000e6);
        usdt0.mint(address(vault), 10_000e18);

        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);

        vm.prank(borrower1);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower1"));
    }

    // ═══════════════════ Helpers ═══════════════════

    function _signAttestation(
        address borrower,
        uint256 limit,
        uint64 expiry,
        uint32 nonce,
        uint8 revocationVersion
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 payloadHash = keccak256(
            abi.encode(
                ELIGIBILITY_DOMAIN_SEPARATOR,
                borrower,
                limit,
                expiry,
                nonce,
                revocationVersion
            )
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash)
        );
        (v, r, s) = vm.sign(teePrivateKey, ethSignedHash);
    }

    function _setupLoanToEligible() internal returns (uint256 loanId) {
        vm.prank(borrower1);
        loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(borrower1, LOAN_150_USDT, expiry, 0, 0);

        vm.prank(borrower1);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));
    }

    function _buildProof(
        uint256 requiredDrops,
        bytes32 memoData,
        bytes32 receiverHash
    ) internal view returns (IXRPPayment.Proof memory) {
        IXRPPayment.ResponseBody memory respBody = IXRPPayment.ResponseBody({
            blockNumber: 1,
            blockTimestamp: uint64(block.timestamp),
            sourceAddress: "rTestAddress",
            sourceAddressHash: keccak256("source"),
            receivingAddressHash: receiverHash,
            intendedReceivingAddressHash: bytes32(0),
            spentAmount: int256(uint256(requiredDrops)),
            intendedSpentAmount: int256(uint256(requiredDrops)),
            receivedAmount: int256(uint256(requiredDrops)),
            intendedReceivedAmount: int256(uint256(requiredDrops)),
            hasMemoData: true,
            firstMemoData: abi.encodePacked(memoData),
            hasDestinationTag: false,
            destinationTag: 0,
            status: 0
        });
        IXRPPayment.RequestBody memory reqBody = IXRPPayment.RequestBody({
            transactionId: keccak256("test-tx"),
            proofOwner: address(0)
        });
        IXRPPayment.Response memory resp = IXRPPayment.Response({
            attestationType: bytes32(0),
            sourceId: bytes32(0),
            votingRound: 0,
            lowestUsedTimestamp: 0,
            requestBody: reqBody,
            responseBody: respBody
        });
        return IXRPPayment.Proof({merkleProof: new bytes32[](0), data: resp});
    }

    // ═══════════════════ PROTOCOL RESERVE TESTS ═══════════════════

    /// @notice Verify reserve starts at 0, default BPS is 100 (1%).
    function test_protocolReserve_initialState() public view {
        assertEq(vault.protocolReserve(), 0, "initial reserve should be 0");
        assertEq(vault.protocolReserveBps(), 100, "default BPS should be 100 (1%)");
    }

    /// @notice Repay a loan → reserve accumulates 1% of collateral.
    function test_protocolReserve_accumulatesOnRepayment() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 expectedFee = (loan.collateralAmount * 100) / 10000; // 1%

        // Build repayment proof
        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);

        fdc.setResult(true);

        uint256 reserveBefore = vault.protocolReserve();

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertEq(
            vault.protocolReserve(),
            reserveBefore + expectedFee,
            "reserve should accumulate fee"
        );
    }

    /// @notice Borrower receives collateral minus the 1% fee.
    function test_protocolReserve_borrowerReceivesLess() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 expectedFee = (loan.collateralAmount * 100) / 10000;
        uint256 expectedRelease = loan.collateralAmount - expectedFee;

        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);

        fdc.setResult(true);

        uint256 fxrpBalBefore = fxrp.balanceOf(borrower1);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertEq(
            fxrp.balanceOf(borrower1),
            fxrpBalBefore + expectedRelease,
            "borrower gets collateral minus fee"
        );
    }

    /// @notice ProtocolReserveFee event is emitted with correct fee amount.
    function test_protocolReserve_emitsEvent() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 expectedFee = (loan.collateralAmount * 100) / 10000;

        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);

        fdc.setResult(true);

        vm.prank(borrower1);
        vm.expectEmit(false, false, false, true);
        emit ProtocolReserveFee(loanId, expectedFee);
        vault.submitRepaymentProof(loanId, proof);
    }

    /// @notice Non-owner cannot withdraw reserve.
    function test_protocolReserve_onlyOwnerCanWithdraw() public {
        // First, accumulate some reserve
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);
        fdc.setResult(true);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertTrue(vault.protocolReserve() > 0, "reserve should be non-zero");

        // Non-owner tries to withdraw
        vm.prank(nonOwner);
        vm.expectRevert("NotOwner");
        vault.withdrawReserve();
    }

    /// @notice Owner can withdraw reserve and receives correct FXRP amount.
    function test_protocolReserve_withdrawTransfersCorrectly() public {
        // Accumulate reserve
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 expectedFee = (loan.collateralAmount * 100) / 10000;

        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);
        fdc.setResult(true);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertEq(vault.protocolReserve(), expectedFee, "reserve should match fee");

        // Owner withdraws
        uint256 ownerBalBefore = fxrp.balanceOf(owner);
        vault.withdrawReserve();

        assertEq(fxrp.balanceOf(owner), ownerBalBefore + expectedFee, "owner should receive reserve");
        assertEq(vault.protocolReserve(), 0, "reserve should be zeroed after withdraw");
    }

    /// @notice Withdraw reverts when reserve is empty.
    function test_protocolReserve_withdrawRevertsWhenEmpty() public {
        assertEq(vault.protocolReserve(), 0, "reserve should start empty");

        vm.expectRevert("NoReserve");
        vault.withdrawReserve();
    }

    /// @notice Owner can update reserve BPS.
    function test_protocolReserve_updateBps() public {
        assertEq(vault.protocolReserveBps(), 100, "default 1%");

        vault.updateProtocolReserveBps(200); // 2%
        assertEq(vault.protocolReserveBps(), 200, "should be 200");
    }

    /// @notice updateProtocolReserveBps reverts if > 1000 (10%).
    function test_protocolReserve_updateBpsRevertsTooHigh() public {
        vm.expectRevert("ReserveBpsTooHigh");
        vault.updateProtocolReserveBps(1001);
    }

    /// @notice Non-owner cannot update BPS.
    function test_protocolReserve_updateBpsOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert("NotOwner");
        vault.updateProtocolReserveBps(200);
    }

    /// @notice Setting BPS to 0 means no fee on repayment.
    function test_protocolReserve_zeroBpsMeansNoFee() public {
        vault.updateProtocolReserveBps(0);
        assertEq(vault.protocolReserveBps(), 0);

        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);

        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);
        fdc.setResult(true);

        uint256 fxrpBalBefore = fxrp.balanceOf(borrower1);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertEq(vault.protocolReserve(), 0, "no fee collected");
        // Full collateral returned
        assertEq(
            fxrp.balanceOf(borrower1),
            fxrpBalBefore + DEPOSIT_100_FXRP,
            "full collateral returned at 0 BPS"
        );
    }

    /// @notice Multiple repayments accumulate reserve correctly.
    function test_protocolReserve_accumulatesAcrossLoans() public {
        // Loan 1
        uint256 loanId1 = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId1, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan1 = vault.getLoan(loanId1);
        uint256 fee1 = (loan1.collateralAmount * 100) / 10000;

        bytes32 memoHash1 = loan1.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        IXRPPayment.Proof memory proof1 = _buildProof(loan1.requiredRepaymentDrops, memoHash1, receiverHash);
        fdc.setResult(true);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId1, proof1);

        assertEq(vault.protocolReserve(), fee1, "first fee accumulated");

        // Loan 2
        uint256 loanId2 = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId2, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan2 = vault.getLoan(loanId2);
        uint256 fee2 = (loan2.collateralAmount * 100) / 10000;

        bytes32 memoHash2 = loan2.expectedCommitment;
        IXRPPayment.Proof memory proof2 = _buildProof(loan2.requiredRepaymentDrops, memoHash2, receiverHash);
        fdc.setResult(true);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId2, proof2);

        assertEq(vault.protocolReserve(), fee1 + fee2, "fees should accumulate across loans");
    }

    /// @notice getProtocolReserve view returns the same value as the public getter.
    function test_protocolReserve_getProtocolReserveView() public view {
        assertEq(vault.getProtocolReserve(), vault.protocolReserve());
    }
}
