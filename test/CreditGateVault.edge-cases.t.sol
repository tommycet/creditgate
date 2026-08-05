// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";
import {IXRPPayment} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";
import {IXRPPaymentVerification} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPaymentVerification.sol";

/// @title CreditGateVaultEdgeCaseTest — Border-case tests not in the main suite
/// @dev 10 edge cases: exact/near-threshold ratios, double-request, expired
///      attestation, withdraw-while-funded, premature liquidation/recovery,
///      zero-amount deposit, zero-hash XRPL registration, wrong memo commitment.
contract CreditGateVaultEdgeCaseTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public borrower2 = makeAddr("borrower2");

    // TEE authority key pair for signing attestations
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config constants — match main suite
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300; // 5 minutes
    uint256 constant LOAN_DURATION = 7 days;

    // XRP price $2.50 in 18 decimals
    uint256 constant XRP_PRICE_2_50 = 2.5e18;

    // FXRP is 6 decimals
    uint256 constant DEPOSIT_100_FXRP = 100e6;

    // USDT0 is 18 decimals on Coston2
    uint256 constant LOAN_100_USDT = 100e18;
    uint256 constant LOAN_150_USDT = 150e18;

    // ═══════════════════ Setup ═══════════════════

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);

        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", 18); // 18dp on Coston2
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

        // Mint test tokens
        fxrp.mint(borrower1, 1_000e6);
        fxrp.mint(borrower2, 1_000e6);
        usdt0.mint(address(vault), 10_000e18); // vault needs 18dp USDT0

        // Set FTSO price
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        // Approve vault to spend borrower tokens
        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);
        vm.prank(borrower2);
        fxrp.approve(address(vault), type(uint256).max);

        // Register XRPL addresses
        vm.prank(borrower1);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower1"));
        vm.prank(borrower2);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower2"));
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

    /// @dev Drive a loan all the way through to ELIGIBLE so drawLoan can be called.
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

    /// @dev Drive a loan all the way through to FUNDED so liquidate/repay can run.
    function _setupLoanToFunded() internal returns (uint256 loanId) {
        loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
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

    // ═══════════════════ EDGE CASE 1: drawLoan at exactly 150% ratio (border pass) ═══════════════════
    //
    // collateral check: `collateralUsd18 * 10000 < loanUsd18 * collateralRatioBps` reverts.
    // Equality (==) must NOT revert. We pick loanUsd18 so the two sides are exactly equal.
    // 100 FXRP @ $2.50 → collateralUsd18 = 250e18. Condition reverts iff
    //   250e18 * 10000 < loanUsd18 * 15000  →  loanUsd18 > 250e18 * 10000 / 15000 = 166_666...
    // There is no integer that makes the sides *exactly* equal for this price, so instead
    // we verify the boundary with a price + amount chosen so the products are exactly equal:
    //   collateralUsd18 * 10000 == loanUsd18 * collateralRatioBps
    // Pick XRP price = 1e18 ($1). 100 FXRP → collateralUsd18 = 100e18.
    // loanUsd18 = 100e18 * 10000 / 15000 = 66_666...  — not integer either.
    //
    // Use collateral = 150 FXRP, price = $1, loan = 100 USDT:
    //   collateralUsd18 = 150e18; loanUsd18 = 100e18
    //   150e18 * 10000 == 100e18 * 15000  (both = 1.5e24) ✓ EXACT EQUALITY

    function test_edge_drawLoan_exactCollateralRatioBoundaryPasses() public {
        // Reconfigure feed to a clean $1.00 price for exact-boundary math.
        ftso.setValueInWei(1e18, uint64(block.timestamp));

        // Fresh borrower with 150 FXRP so we don't collide with borrower1's state.
        address eb = makeAddr("exactBoundary");
        fxrp.mint(eb, 1_000e6);
        vm.startPrank(eb);
        fxrp.approve(address(vault), type(uint256).max);
        vault.registerXRPLAddress(keccak256("rExactBoundary"));
        uint256 loanId = vault.depositCollateral(150e6); // 150 FXRP @ $1 = $150
        vault.requestEligibility(loanId);
        vm.stopPrank();

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(eb, LOAN_150_USDT, expiry, 0, 0);
        vm.prank(eb);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: eb,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));

        // Loan of exactly 100 USDT (18dp) at 150% ratio against $150 collateral.
        // collateralUsd18 * 10000 == loanUsd18 * 15000 → equality, NOT <, so it passes.
        vm.prank(eb);
        vault.drawLoan{value: 0}(loanId, 100e18);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
        assertEq(loan.loanAmount, 100e18);
    }

    // ═══════════════════ EDGE CASE 2: drawLoan just under 150% (revert) ═══════════════════
    //
    // Same exact-equality setup as case 1, but bump the loan by 1 wei so the strict
    // `<` becomes true and InsufficientCollateral reverts.

    function test_edge_drawLoan_justUnderCollateralRatioReverts() public {
        ftso.setValueInWei(1e18, uint64(block.timestamp));

        address eb = makeAddr("justUnder");
        fxrp.mint(eb, 1_000e6);
        vm.startPrank(eb);
        fxrp.approve(address(vault), type(uint256).max);
        vault.registerXRPLAddress(keccak256("rJustUnder"));
        uint256 loanId = vault.depositCollateral(150e6);
        vault.requestEligibility(loanId);
        vm.stopPrank();

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(eb, LOAN_150_USDT, expiry, 0, 0);
        vm.prank(eb);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: eb,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));

        // 100e18 + 1 wei breaks the exact equality → reverts.
        uint256 overLoan = 100e18 + 1;
        vm.prank(eb);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InsufficientCollateral.selector,
                150e18 * 10_000, // collateralUsd18 * 10000
                overLoan * COLLATERAL_RATIO_BPS
            )
        );
        vault.drawLoan{value: 0}(loanId, overLoan);
    }

    // ═══════════════════ EDGE CASE 3: double requestEligibility (revert) ═══════════════════

    function test_edge_requestEligibility_doubleRequestReverts() public {
        vm.startPrank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vault.requestEligibility(loanId); // first request: COLLATERAL_DEPOSITED → PENDING

        // Second request while already ELIGIBILITY_PENDING must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.ELIGIBILITY_PENDING,
                LoanState.COLLATERAL_DEPOSITED
            )
        );
        vault.requestEligibility(loanId);
        vm.stopPrank();
    }

    // ═══════════════════ EDGE CASE 4: submitEligibility with expired attestation (revert) ═══════════════════
    //
    //expiry is set to a timestamp already in the past relative to block.timestamp.
    // The contract reverts EligibilityExpired(expiry, block.timestamp).

    function test_edge_submitEligibility_expiredAttestationReverts() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        // Warp forward so any reasonable expiry is in the past, then sign with that expiry.
        vm.warp(10_000);
        uint64 expiry = uint64(block.timestamp - 1); // 1 second ago
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(borrower1, LOAN_150_USDT, expiry, 0, 0);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.EligibilityExpired.selector,
                expiry,
                uint64(block.timestamp)
            )
        );
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));
    }

    // ═══════════════════ EDGE CASE 5: withdrawCollateral on FUNDED loan (revert) ═══════════════════

    function test_edge_withdrawCollateral_onFundedLoanReverts() public {
        uint256 loanId = _setupLoanToFunded(); // state == FUNDED

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.FUNDED,
                LoanState.COLLATERAL_DEPOSITED
            )
        );
        vault.withdrawCollateral(loanId);
    }

    // ═══════════════════ EDGE CASE 6: liquidate before deadline (revert) ═══════════════════

    function test_edge_liquidate_beforeDeadlineReverts() public {
        uint256 loanId = _setupLoanToFunded();

        // Warp forward but stay 1 second short of the deadline.
        vm.warp(block.timestamp + LOAN_DURATION - 1);

        vm.expectRevert(CreditGateTypes.DeadlineNotPassed.selector);
        vault.liquidate(loanId);
    }

    // ═══════════════════ EDGE CASE 7: recoverDefaultedCollateral on non-DEFAULTED loan (revert) ═══════════════════

    function test_edge_recoverDefaultedCollateral_onFuncedLoanReverts() public {
        uint256 loanId = _setupLoanToFunded(); // state == FUNDED, not DEFAULTED

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.FUNDED,
                LoanState.DEFAULTED
            )
        );
        vault.recoverDefaultedCollateral(loanId);
    }

    // ═══════════════════ EDGE CASE 8: depositCollateral with 0 amount (revert ZeroAmount) ═══════════════════

    function test_edge_depositCollateral_zeroAmountReverts() public {
        vm.prank(borrower1);
        vm.expectRevert(CreditGateTypes.ZeroAmount.selector);
        vault.depositCollateral(0);
    }

    // ═══════════════════ EDGE CASE 9: registerXRPLAddress with zero hash (revert "ZeroHash") ═══════════════════
    //
    // The task framing says "should be allowed but tested", but the contract code at
    // line 135 explicitly requires `xrplAddressHash != bytes32(0)` else reverts "ZeroHash".
    // We test the actual contract behavior (revert), which documents the border case.

    function test_edge_registerXRPLAddress_zeroHashReverts() public {
        vm.prank(borrower1);
        vm.expectRevert("ZeroHash");
        vault.registerXRPLAddress(bytes32(0));
    }

    // ═══════════════════ EDGE CASE 10: submitRepaymentProof with wrong memo commitment (revert) ═══════════════════

    function test_edge_submitRepaymentProof_wrongMemoCommitmentReverts() public {
        uint256 loanId = _setupLoanToFunded();

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        bytes32 wrongCommitment = keccak256("wrong-memo-commitment");
        // Sanity: the wrong commitment must differ from the expected one.
        assertNotEq(wrongCommitment, loan.expectedCommitment);

        IXRPPayment.Proof memory proof = _buildProof(
            loan.requiredRepaymentDrops,
            wrongCommitment,
            keccak256("rCreditGateBorrower1")
        );

        fdc.setResult(true);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.CommitmentMismatch.selector,
                loan.expectedCommitment,
                wrongCommitment
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }
}
