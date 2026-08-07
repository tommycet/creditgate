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

/// @title CreditGateVault.Reputation — borrower reputation tracking tests
/// @dev discovery-81 quick win #2 (subagent #94). On-chain credit history in the
///      Aave wallet scoring / TrueFi credit history / ARCx credit scoring pattern.
///      Covers the four required scenarios:
///        (1) draw  → totalBorrowed bumps
///        (2) repay → loansCompleted + totalRepaid bump
///        (3) liquidate (deadline default) → loansDefaulted bumps
///        (4) getBorrowerReputation view returns all four fields coherently
contract CreditGateVaultReputationTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    // Test accounts
    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");

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

    /// kind discriminator emitted by `BorrowerReputationUpdated`:
    /// 0 = BORROWED, 1 = REPAID, 2 = DEFAULTED.
    uint8 constant KIND_BORROWED = 0;
    uint8 constant KIND_REPAID = 1;
    uint8 constant KIND_DEFAULTED = 2;

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

    // ═══════════════════ REPUTATION TESTS ═══════════════════

    /// @notice Reputation for a fresh wallet must read all-zeros. Anchors the
    ///         delta assertions in every other test in this suite.
    function test_reputation_initialAllZero() public view {
        (
            uint256 totalBorrowed,
            uint256 totalRepaid,
            uint256 loansCompleted,
            uint256 loansDefaulted
        ) = vault.getBorrowerReputation(borrower1);

        assertEq(totalBorrowed, 0, "totalBorrowed should start at 0");
        assertEq(totalRepaid, 0, "totalRepaid should start at 0");
        assertEq(loansCompleted, 0, "loansCompleted should start at 0");
        assertEq(loansDefaulted, 0, "loansDefaulted should start at 0");
    }

    /// @notice Drawing a USDT0 loan bumps `totalBorrowed` exactly by the drawn
    ///         amount (and nothing else — loansCompleted/Repaid/Defaulted stay 0).
    ///         Required test #1 for discovery-81 quick win #2.
    function test_reputation_tracksBorrowing() public {
        uint256 loanId = _setupLoanToEligible();

        (
            uint256 borrowedBefore,
            uint256 repaidBefore,
            uint256 completedBefore,
            uint256 defaultedBefore
        ) = vault.getBorrowerReputation(borrower1);
        assertEq(borrowedBefore, 0, "pre-draw totalBorrowed must be 0");

        // Draw the loan — emit a BORROWED reputation event with the loanAmount.
        vm.prank(borrower1);
        vm.expectEmit(true, false, false, true);
        emit BorrowerReputationUpdated(borrower1, KIND_BORROWED, LOAN_100_USDT);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        (
            uint256 borrowedAfter,
            uint256 repaidAfter,
            uint256 completedAfter,
            uint256 defaultedAfter
        ) = vault.getBorrowerReputation(borrower1);

        assertEq(borrowedAfter, LOAN_100_USDT, "totalBorrowed must equal draw amount");
        // Only borrowed changed.
        assertEq(repaidAfter, repaidBefore, "totalRepaid must be unchanged");
        assertEq(completedAfter, completedBefore, "loansCompleted must be unchanged");
        assertEq(defaultedAfter, defaultedBefore, "loansDefaulted must be unchanged");
    }

    /// @notice Closing a loan via a verified FDC repayment proof bumps both
    ///         `loansCompleted` (by 1) and `totalRepaid` (by the loan principal).
    ///         Required test #2 for discovery-81 quick win #2.
    function test_reputation_tracksRepayment() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);

        bytes32 memoHash = loan.expectedCommitment;
        bytes32 receiverHash = keccak256("rCreditGateBorrower1");
        uint256 requiredDrops = loan.requiredRepaymentDrops;
        IXRPPayment.Proof memory proof = _buildProof(requiredDrops, memoHash, receiverHash);

        fdc.setResult(true);

        // Replay-anticipating snapshot before close: only loansCompleted and
        // totalRepaid should move.
        (, , uint256 completedBefore, uint256 defaultedBefore) =
            vault.getBorrowerReputation(borrower1);

        // Repayment emits the REPAID event carrying the loan principal.
        vm.prank(borrower1);
        vm.expectEmit(true, false, false, true);
        emit BorrowerReputationUpdated(borrower1, KIND_REPAID, loan.loanAmount);
        vault.submitRepaymentProof(loanId, proof);

        (
            uint256 borrowedAfter,
            uint256 repaidAfter,
            uint256 completedAfter,
            uint256 defaultedAfter
        ) = vault.getBorrowerReputation(borrower1);

        // loansCompleted bumped by exactly 1.
        assertEq(completedAfter, completedBefore + 1, "loansCompleted must bump by 1");
        // totalRepaid bumps by the loan principal (interest is verified on XRPL,
        // so on-chain reputation tracks principal only — see subagent #94 design).
        assertEq(repaidAfter, loan.loanAmount, "totalRepaid must equal loan principal");
        // totalBorrowed and loansDefaulted are unchanged by close.
        assertEq(borrowedAfter, LOAN_100_USDT, "totalBorrowed must be unchanged by close");
        assertEq(defaultedAfter, defaultedBefore, "loansDefaulted must be unchanged by close");
    }

    /// @notice A funded loan that hits its repayment deadline and gets liquidated
    ///         bumps `loansDefaulted` by 1 (via the `liquidate()` path). The other
    ///         reputation fields are left alone — the borrower neither completed
    ///         nor repaid this loan.
    ///         Required test #3 for discovery-81 quick win #2.
    function test_reputation_tracksDefault() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);

        // Advance past the deadline so `liquidate()` is callable.
        vm.warp(loan.deadline + 1);

        (, uint256 repaidBefore, uint256 completedBefore, uint256 defaultedBefore) =
            vault.getBorrowerReputation(borrower1);

        // Liquidating emits a DEFAULTED reputation event. We pass `true` for the
        // indexed borrower arg so the topic-0 filter matches. (vm.expectEmit's
        // first bool is the indexed-topic check for an indexed addr.)
        vm.expectEmit(true, false, false, false);
        emit BorrowerReputationUpdated(borrower1, KIND_DEFAULTED, loan.collateralAmount);
        vault.liquidate(loanId);

        (
            uint256 borrowedAfter,
            uint256 repaidAfter,
            uint256 completedAfter,
            uint256 defaultedAfter
        ) = vault.getBorrowerReputation(borrower1);

        assertEq(defaultedAfter, defaultedBefore + 1, "loansDefaulted must bump by 1");
        // Borrowed principal stays (the loan was drawn — that fact is real).
        assertEq(borrowedAfter, LOAN_100_USDT, "totalBorrowed must be unchanged by default");
        assertEq(repaidAfter, repaidBefore, "totalRepaid must be unchanged by default");
        assertEq(completedAfter, completedBefore, "loansCompleted must be unchanged by default");
    }

    /// @notice `getBorrowerReputation` returns the four-tuple coherently across two
    ///         full loan lifecycles (one repaid, one defaulted), proving the
    ///         counters accumulate across loans — the whole point of persisting
    ///         reputation on-chain. Required test #4 for discovery-81 quick win #2.
    function test_reputation_viewFunction() public {
        // ── Lifecycle A: borrowed then repaid ──
        uint256 loanA = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanA, LOAN_100_USDT);
        CreditGateTypes.Loan memory loanAStored = vault.getLoan(loanA);
        bytes32 memoA = loanAStored.expectedCommitment;
        bytes32 receiver = keccak256("rCreditGateBorrower1");
        fdc.setResult(true);
        IXRPPayment.Proof memory proofA =
            _buildProof(loanAStored.requiredRepaymentDrops, memoA, receiver);
        vm.prank(borrower1);
        vault.submitRepaymentProof(loanA, proofA);

        // Mid-checkpoint: 100 borrowed, 100 repaid, 1 completed, 0 defaulted.
        (
            uint256 borrowed1,
            uint256 repaid1,
            uint256 completed1,
            uint256 defaulted1
        ) = vault.getBorrowerReputation(borrower1);
        assertEq(borrowed1, LOAN_100_USDT, "after loan A: totalBorrowed");
        assertEq(repaid1, LOAN_100_USDT, "after loan A: totalRepaid");
        assertEq(completed1, 1, "after loan A: loansCompleted");
        assertEq(defaulted1, 0, "after loan A: loansDefaulted");

        // ── Lifecycle B: borrowed then defaulted via deadline liquidation ──
        uint256 loanB = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanB, LOAN_100_USDT);
        CreditGateTypes.Loan memory loanBStored = vault.getLoan(loanB);
        vm.warp(loanBStored.deadline + 1);
        vault.liquidate(loanB);

        // Final checkpoint — the view returns all four fields, accumulated across
        // the two lifecycles (this is what the FCC credit bureau handler reads).
        (
            uint256 borrowed2,
            uint256 repaid2,
            uint256 completed2,
            uint256 defaulted2
        ) = vault.getBorrowerReputation(borrower1);
        assertEq(borrowed2, 2 * LOAN_100_USDT, "after loan B: totalBorrowed accumulates");
        assertEq(repaid2, LOAN_100_USDT, "after loan B: totalRepaid (only loan A repaid)");
        assertEq(completed2, 1, "after loan B: loansCompleted (only loan A)");
        assertEq(defaulted2, 1, "after loan B: loansDefaulted (loan B)");

        // Cross-check: the public mapping auto-getter returns the same struct
        // fields the view surface returns — proves the two read paths agree.
        // (For a `mapping(address => Struct)`, Solidity's autogenerated getter
        // exposes the struct as a tuple of its four fields in declared order.)
        (
            uint256 mTotalBorrowed,
            uint256 mTotalRepaid,
            uint256 mLoansCompleted,
            uint256 mLoansDefaulted
        ) = vault.borrowerReputation(borrower1);
        assertEq(mTotalBorrowed, borrowed2, "mapping vs view: totalBorrowed");
        assertEq(mTotalRepaid, repaid2, "mapping vs view: totalRepaid");
        assertEq(mLoansCompleted, completed2, "mapping vs view: loansCompleted");
        assertEq(mLoansDefaulted, defaulted2, "mapping vs view: loansDefaulted");
    }
}
