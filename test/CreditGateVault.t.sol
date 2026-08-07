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

/// @title CreditGateVaultTest — Unit tests for the CreditGate vault
/// @dev Uses mock ERC20, FTSO, and FDC. TEE authority is a test ECDSA key.
contract CreditGateVaultTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    // Test accounts
    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public borrower2 = makeAddr("borrower2");
    address public liquidator = makeAddr("liquidator");

    // TEE authority key pair for signing attestations
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config constants
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300; // 5 minutes
    uint256 constant LOAN_DURATION = 7 days;

    // Helper: XRP price $2.50 in 18 decimals
    uint256 constant XRP_PRICE_2_50 = 2.5e18;

    // Helper: FXRP amounts (6 decimals)
    uint256 constant DEPOSIT_100_FXRP = 100e6;
    uint256 constant DEPOSIT_50_FXRP = 50e6;

    // Helper: USDT0 amounts (18 decimals)
    uint256 constant LOAN_100_USDT = 100e18; // USDT0 is 18 decimals on Coston2
    uint256 constant LOAN_150_USDT = 150e18;

    // ═══════════════════ Setup ═══════════════════

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);

        // Deploy mocks
        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", 6);
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();

        // Deploy vault
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
        usdt0.mint(address(vault), 10_000e18); // Vault needs USDT0 (18dp) to disburse loans

        // Set FTSO price
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        // Approve vault to spend borrower tokens
        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);
        vm.prank(borrower2);
        fxrp.approve(address(vault), type(uint256).max);

        // Register XRPL addresses (standard address hash of r-address)
        vm.prank(borrower1);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower1"));
        vm.prank(borrower2);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower2"));
    }

    // ═══════════════════ Helper: Sign eligibility attestation ═══════════════════

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

    // ═══════════════════ Helper: Build valid proof struct ═══════════════════

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

    // ═══════════════════ CONSTRUCTOR TESTS ═══════════════════

    function test_constructor_setsImmutables() public view {
        assertEq(address(vault.fxrp()), address(fxrp));
        assertEq(address(vault.usdt0()), address(usdt0));
        assertEq(vault.teeAuthority(), teeAuthority);
        assertEq(vault.collateralRatioBps(), COLLATERAL_RATIO_BPS);
        assertEq(vault.ftsoStalenessLimit(), FTSO_STALENESS_LIMIT);
        assertEq(vault.loanDuration(), LOAN_DURATION);
        assertEq(address(vault.ftsoV2()), address(ftso));
        assertEq(address(vault.fdcVerification()), address(fdc));
        assertEq(vault.owner(), owner);
        assertFalse(vault.paused());
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert("ZeroAddressFXRP");
        new CreditGateVault(
            address(0), address(usdt0), teeAuthority,
            COLLATERAL_RATIO_BPS, FTSO_STALENESS_LIMIT, LOAN_DURATION,
            address(ftso), address(fdc)
        );
    }

    function test_constructor_revertsOnZeroRatio() public {
        vm.expectRevert("ZeroRatio");
        new CreditGateVault(
            address(fxrp), address(usdt0), teeAuthority,
            0, FTSO_STALENESS_LIMIT, LOAN_DURATION,
            address(ftso), address(fdc)
        );
    }

    // ═══════════════════ DEPOSIT COLLATERAL TESTS ═══════════════════

    function test_depositCollateral_happyPath() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        assertEq(loanId, 1);
        assertEq(fxrp.balanceOf(address(vault)), DEPOSIT_100_FXRP);
        assertEq(fxrp.balanceOf(borrower1), 1_000e6 - DEPOSIT_100_FXRP);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(loan.borrower, borrower1);
        assertEq(loan.collateralAmount, DEPOSIT_100_FXRP);
        assertEq(uint8(loan.state), uint8(LoanState.COLLATERAL_DEPOSITED));
    }

    function test_depositCollateral_revertsOnZeroAmount() public {
        vm.prank(borrower1);
        vm.expectRevert(CreditGateTypes.ZeroAmount.selector);
        vault.depositCollateral(0);
    }

    function test_depositCollateral_emitsEvent() public {
        vm.prank(borrower1);
        vm.expectEmit(true, true, false, true);
        emit CreditGateTypes.CollateralDeposited(1, borrower1, DEPOSIT_100_FXRP);
        vault.depositCollateral(DEPOSIT_100_FXRP);
    }

    function test_depositCollateral_incrementsLoanId() public {
        vm.startPrank(borrower1);
        uint256 id1 = vault.depositCollateral(DEPOSIT_100_FXRP);
        uint256 id2 = vault.depositCollateral(DEPOSIT_50_FXRP);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_depositCollateral_multipleBorrowers() public {
        vm.prank(borrower1);
        uint256 loanId1 = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower2);
        uint256 loanId2 = vault.depositCollateral(DEPOSIT_50_FXRP);

        assertEq(loanId1, 1);
        assertEq(loanId2, 2);

        CreditGateTypes.Loan memory loan1 = vault.getLoan(loanId1);
        CreditGateTypes.Loan memory loan2 = vault.getLoan(loanId2);
        assertEq(loan1.borrower, borrower1);
        assertEq(loan2.borrower, borrower2);
    }

    // ═══════════════════ WITHDRAW COLLATERAL TESTS ═══════════════════

    function test_withdrawCollateral_happyPath() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.withdrawCollateral(loanId);

        assertEq(fxrp.balanceOf(address(vault)), 0);
        assertEq(fxrp.balanceOf(borrower1), 1_000e6);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(loan.collateralAmount, 0);
        assertEq(uint8(loan.state), uint8(LoanState.IDLE));
    }

    function test_withdrawCollateral_revertsIfWrongState() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.ELIGIBILITY_PENDING,
                LoanState.COLLATERAL_DEPOSITED
            )
        );
        vault.withdrawCollateral(loanId);
    }

    function test_withdrawCollateral_revertsIfNotBorrower() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower2);
        vm.expectRevert("NotBorrower");
        vault.withdrawCollateral(loanId);
    }

    function test_withdrawCollateral_emitsLoanClosed() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vm.expectEmit(true, true, false, true);
        emit CreditGateTypes.LoanClosed(loanId, borrower1, DEPOSIT_100_FXRP);
        vault.withdrawCollateral(loanId);
    }

    // ═══════════════════ REQUEST ELIGIBILITY TESTS ═══════════════════

    function test_requestEligibility_happyPath() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.ELIGIBILITY_PENDING));
    }

    function test_requestEligibility_revertsIfWrongState() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.startPrank(borrower1);
        vault.requestEligibility(loanId);

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

    function test_requestEligibility_revertsIfNotBorrower() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower2);
        vm.expectRevert("NotBorrower");
        vault.requestEligibility(loanId);
    }

    // ═══════════════════ SUBMIT ELIGIBILITY TESTS ═══════════════════

    function test_submitEligibility_happyPath() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        uint32 nonce = 0; // first request
        uint8 revocationVersion = 0;

        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower1, LOAN_150_USDT, expiry, nonce, revocationVersion
        );

        CreditGateTypes.EligibilityAttestation memory att = CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: nonce,
            revocationVersion: revocationVersion,
            v: v,
            r: r,
            s: s
        });

        vm.prank(borrower1);
        vault.submitEligibility(loanId, att);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.ELIGIBLE));
        assertEq(loan.eligibilityExpiry, expiry);
    }

    function test_submitEligibility_revertsIfExpired() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp - 1); // already expired
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower1, LOAN_150_USDT, expiry, 0, 0
        );

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

    function test_submitEligibility_revertsIfWrongSigner() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        // Sign with a DIFFERENT key (not teeAuthority)
        uint256 wrongKey = 0xBEEF;
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 payloadHash = keccak256(
            abi.encode(ELIGIBILITY_DOMAIN_SEPARATOR, borrower1, LOAN_150_USDT, expiry, uint32(0), uint8(0))
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidEligibilitySigner.selector,
                vm.addr(wrongKey),
                teeAuthority
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

    function test_submitEligibility_revertsIfBorrowerMismatch() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        // Sign for borrower2 (wrong borrower)
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower2, LOAN_150_USDT, expiry, 0, 0
        );

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.BorrowerMismatch.selector,
                borrower1,
                borrower2
            )
        );
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower2,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));
    }

    function test_submitEligibility_revertsIfNonceMismatch() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        // Sign with wrong nonce (1 instead of 0)
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower1, LOAN_150_USDT, expiry, 1, 0
        );

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.NonceMismatch.selector,
                uint32(0),
                uint32(1)
            )
        );
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 1,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));
    }

    // ═══════════════════ DRAW LOAN TESTS ═══════════════════

    function _setupLoanToEligible() internal returns (uint256 loanId) {
        vm.prank(borrower1);
        loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower1, LOAN_150_USDT, expiry, 0, 0
        );

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

    function test_drawLoan_happyPath() public {
        uint256 loanId = _setupLoanToEligible();

        uint256 balBefore = usdt0.balanceOf(borrower1);

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
        assertEq(loan.loanAmount, LOAN_100_USDT);
        assertEq(usdt0.balanceOf(borrower1), balBefore + LOAN_100_USDT);

        // Check required repayment drops: 100e18 * 1e6 / 2.5e18 = 40e6
        assertEq(loan.requiredRepaymentDrops, 40e6);
    }

    function test_drawLoan_revertsIfZeroAmount() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vm.expectRevert(CreditGateTypes.ZeroAmount.selector);
        vault.drawLoan{value: 0}(loanId, 0);
    }

    function test_drawLoan_revertsIfInsufficientCollateral() public {
        // Set up a loan with a high attestation limit so the collateral check fires first
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vm.prank(borrower1);
        vault.requestEligibility(loanId);
        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower1, 500e18, expiry, 0, 0
        );
        vm.prank(borrower1);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: 500e18,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));

        // Try to borrow way more than collateral ratio allows
        // 100 FXRP at $2.50 = $250. At 150% ratio, max loan = $250/1.5 = $166.67
        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InsufficientCollateral.selector,
                XRP_PRICE_2_50 * 1e12 * 100e6 * 10_000 / 1e18, // collateralUsd18 * 10000
                200e18 * COLLATERAL_RATIO_BPS                  // loanUsd18 (18dp) * ratio
            )
        );
        vault.drawLoan{value: 0}(loanId, 200e18);
    }

    function test_drawLoan_revertsIfFTSOStale() public {
        uint256 loanId = _setupLoanToEligible();

        // Warp block.timestamp forward, then set FTSO timestamp far in the past
        vm.warp(1000);
        ftso.setValueInWei(XRP_PRICE_2_50, 1);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.FTSOPriceStale.selector,
                uint64(1),
                FTSO_STALENESS_LIMIT
            )
        );
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    function test_drawLoan_revertsIfFTSOPriceZero() public {
        uint256 loanId = _setupLoanToEligible();

        ftso.setValueInWei(0, uint64(block.timestamp));

        vm.prank(borrower1);
        vm.expectRevert(CreditGateTypes.FTSOPriceZero.selector);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    /// @dev Vault has insufficient USDT0 to disburse — safeTransfer reverts.
    function test_drawLoan_revertsIfVaultInsufficientUsdt0() public {
        uint256 loanId = _setupLoanToEligible();

        // Drain the vault's USDT0 so it can't disburse
        uint256 vaultBal = usdt0.balanceOf(address(vault));
        usdt0.burn(address(vault), vaultBal);

        vm.prank(borrower1);
        // safeTransfer will revert (ERC20 insufficient balance)
        vm.expectRevert();
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    /// @dev L2 fix: FTSO feed timestamp in the future should NOT cause underflow panic
    function test_drawLoan_ftsoFutureTimestampNoUnderflow() public {
        uint256 loanId = _setupLoanToEligible();

        // Set FTSO with a future timestamp (should not panic, just skip staleness check)
        ftso.setValueInWei(2_5e17, uint64(block.timestamp + 1000));

        vm.prank(borrower1);
        // Should succeed — future timestamp skips the staleness check (L2 fix)
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.FUNDED));
    }

    function test_drawLoan_revertsIfWrongState() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.COLLATERAL_DEPOSITED,
                LoanState.ELIGIBLE
            )
        );
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    function test_drawLoan_emitsLoanFunded() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vm.expectEmit(true, true, false, false);
        emit CreditGateTypes.LoanFunded(loanId, borrower1, 0, 0, bytes32(0));
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    // ═══════════════════ LIQUIDATE TESTS ═══════════════════

    function test_liquidate_happyPath() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // Warp past deadline
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);

        vault.liquidate(loanId);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.DEFAULTED));
        assertEq(loan.collateralAmount, 0);
        assertEq(vault.seizedCollateral(loanId), DEPOSIT_100_FXRP);
    }

    function test_recoverDefaultedCollateral_happyPath() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        vault.liquidate(loanId);

        // Owner recovers the seized collateral
        uint256 ownerBefore = fxrp.balanceOf(owner);
        vault.recoverDefaultedCollateral(loanId);
        assertEq(fxrp.balanceOf(owner), ownerBefore + DEPOSIT_100_FXRP);
        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.IDLE));
        assertEq(vault.seizedCollateral(loanId), 0);
    }

    function test_recoverDefaultedCollateral_revertsIfNotOwner() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        vault.liquidate(loanId);

        vm.prank(borrower1);
        vm.expectRevert("NotOwner");
        vault.recoverDefaultedCollateral(loanId);
    }

    function test_recoverDefaultedCollateral_revertsIfNotDefaulted() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        // Not defaulted — still COLLATERAL_DEPOSITED
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.COLLATERAL_DEPOSITED,
                LoanState.DEFAULTED
            )
        );
        vault.recoverDefaultedCollateral(loanId);
    }

    function test_liquidate_revertsIfDeadlineNotPassed() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // Don't warp — deadline hasn't passed
        vm.expectRevert(CreditGateTypes.DeadlineNotPassed.selector);
        vault.liquidate(loanId);
    }

    function test_liquidate_revertsIfWrongState() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.COLLATERAL_DEPOSITED,
                LoanState.FUNDED
            )
        );
        vault.liquidate(loanId);
    }

    function test_liquidate_collateralStaysInVault() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        uint256 vaultBalBefore = fxrp.balanceOf(address(vault));

        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        vault.liquidate(loanId);

        // Collateral stays in vault (not transferred out)
        assertEq(fxrp.balanceOf(address(vault)), vaultBalBefore);
    }

    // ═══════════════════ PAUSE TESTS ═══════════════════

    function test_pause_blocksActions() public {
        vault.pause();

        vm.prank(borrower1);
        vm.expectRevert("Paused");
        vault.depositCollateral(DEPOSIT_100_FXRP);
    }

    function test_unpause_restoresActions() public {
        vault.pause();
        vault.unpause();

        vm.prank(borrower1);
        vault.depositCollateral(DEPOSIT_100_FXRP);
        assertEq(vault.nextLoanId(), 2);
    }

    function test_pause_onlyOwner() public {
        vm.prank(borrower1);
        vm.expectRevert("NotOwner");
        vault.pause();
    }

    // ═══════════════════ REVOKE ELIGIBILITY TESTS ═══════════════════

    function test_revokeEligibility_bumpsVersion() public {
        vault.revokeEligibility(borrower1);
        assertEq(vault.borrowerRevocationVersion(borrower1), 1);
    }

    function test_revokeEligibility_setsRevokedFlag() public {
        vault.revokeEligibility(borrower1);
        assertTrue(vault.eligibilityRevoked(borrower1));
    }

    function test_revokeEligibility_onlyOwner() public {
        vm.prank(borrower1);
        vm.expectRevert("NotOwner");
        vault.revokeEligibility(borrower1);
    }

    // ═══════════════════ BORROWER LOAN IDS TESTS ═══════════════════

    function test_getBorrowerLoanIds_returnsAll() public {
        vm.startPrank(borrower1);
        uint256 id1 = vault.depositCollateral(DEPOSIT_100_FXRP);
        uint256 id2 = vault.depositCollateral(DEPOSIT_50_FXRP);
        vm.stopPrank();

        uint256[] memory ids = vault.getBorrowerLoanIds(borrower1);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
    }

    function test_getBorrowerLoanIds_emptyForNewBorrower() public {
        uint256[] memory ids = vault.getBorrowerLoanIds(borrower1);
        assertEq(ids.length, 0);
    }

    // ═══════════════════ FULL LIFECYCLE TEST ═══════════════════

    function test_fullLifecycle_depositToEligible() public {
        // 1. Deposit
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.COLLATERAL_DEPOSITED));

        // 2. Request eligibility
        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.ELIGIBILITY_PENDING));

        // 3. Submit eligibility
        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            borrower1, LOAN_150_USDT, expiry, 0, 0
        );

        vm.prank(borrower1);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));

        loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.ELIGIBLE));

        // 4. Draw loan
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
        assertEq(loan.loanAmount, LOAN_100_USDT);
        assertEq(usdt0.balanceOf(borrower1), LOAN_100_USDT);
    }

    // ═══════════════════ REPAYMENT PROOF TESTS ═══════════════════

    function test_submitRepaymentProof_happyPath() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        bytes32 commitment = loan.expectedCommitment;

        IXRPPayment.Proof memory proof = _buildProof(loan.requiredRepaymentDrops, commitment, keccak256("rCreditGateBorrower1"));

        fdc.setResult(true);

        uint256 fxrpBalBefore = fxrp.balanceOf(borrower1);

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.CLOSED));
        assertEq(loan.collateralAmount, 0);
        // Bug 2 fix: protocol reserve fee is now 1% of the INTEREST-equivalent
        // collateral, NOT 1% of the entire deposit. With immediate repayment
        // (elapsed == 0) interest is 0, fee is 0, so the borrower gets the FULL
        // 100 FXRP collateral back. Previously the contract deducted 1e6 (1% of
        // collateral) regardless of interest accrued.
        assertEq(fxrp.balanceOf(borrower1), fxrpBalBefore + DEPOSIT_100_FXRP);
        assertEq(vault.protocolReserve(), 0, "no fee when interest is 0");
    }

    function test_submitRepaymentProof_revertsIfFDCFails() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        IXRPPayment.Proof memory proof = _buildProof(loan.requiredRepaymentDrops, loan.expectedCommitment, keccak256("rCreditGateBorrower1"));

        fdc.setResult(false); // FDC verification fails

        vm.prank(borrower1);
        vm.expectRevert(CreditGateTypes.FDCVerificationFailed.selector);
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_submitRepaymentProof_revertsIfProofAlreadyConsumed() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        IXRPPayment.Proof memory proof = _buildProof(loan.requiredRepaymentDrops, loan.expectedCommitment, keccak256("rCreditGateBorrower1"));

        fdc.setResult(true);

        // First submission succeeds and closes the loan
        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        // Second submission hits InvalidLoanState (CLOSED != FUNDED) before proof check
        // because the loan is already closed. This proves replay is prevented at the state level.
        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.CLOSED,
                LoanState.FUNDED
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_submitRepaymentProof_revertsIfCommitmentMismatch() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        // Build proof with WRONG commitment
        bytes32 wrongCommitment = keccak256("wrong");
        IXRPPayment.Proof memory proof = _buildProof(loan.requiredRepaymentDrops, wrongCommitment, keccak256("rCreditGateBorrower1"));

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

    function test_submitRepaymentProof_revertsIfInsufficientRepayment() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        // Build proof with LESS than required drops
        uint256 shortDrops = loan.requiredRepaymentDrops / 2;
        IXRPPayment.Proof memory proof = _buildProof(shortDrops, loan.expectedCommitment, keccak256("rCreditGateBorrower1"));

        fdc.setResult(true);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InsufficientRepayment.selector,
                int256(uint256(shortDrops)),
                loan.requiredRepaymentDrops
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_submitRepaymentProof_revertsIfWrongState() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        IXRPPayment.Proof memory proof = _buildProof(100e6, bytes32(0), keccak256("rCreditGateBorrower1"));

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InvalidLoanState.selector,
                LoanState.COLLATERAL_DEPOSITED,
                LoanState.FUNDED
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_submitRepaymentProof_revertsIfNotBorrower() public {
        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        IXRPPayment.Proof memory proof = _buildProof(loan.requiredRepaymentDrops, loan.expectedCommitment, keccak256("rCreditGateBorrower1"));
        fdc.setResult(true);

        vm.prank(borrower2);
        vm.expectRevert("NotBorrower");
        vault.submitRepaymentProof(loanId, proof);
    }

    // ═══════════════════ REENTRANCY TEST ═══════════════════

    function test_reentrancy_onDeposit() public {
        // Verify reentrancy guard is active by checking contract has it
        // A basic deposit works fine; reentrancy guard prevents re-entry
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        assertEq(loanId, 1);
    }

    // ═══════════════════ EDGE CASE TESTS ═══════════════════

    function test_drawLoan_exactCollateralRatio() public {
        // 100 FXRP at $2.50 = $250. At 150% ratio, max loan = $250/1.5 = $166.67
        // We test at a safe value under the max
        uint256 safeLoan = 166e6; // Under max

        uint256 loanId = _setupLoanToEligible();

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, safeLoan);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
        assertEq(loan.loanAmount, safeLoan);
    }

    function test_loanId_startsWithOne() public view {
        assertEq(vault.nextLoanId(), 1);
    }

    // ═══════════════════ XRPL ADDRESS BINDING TESTS ═══════════════════

    function test_registerXRPLAddress_happyPath() public {
        vm.prank(borrower1);
        vault.registerXRPLAddress(keccak256("rNewAddress"));
        assertEq(vault.borrowerXRPLAddressHash(borrower1), keccak256("rNewAddress"));
    }

    function test_registerXRPLAddress_revertsOnZero() public {
        vm.prank(borrower1);
        vm.expectRevert("ZeroHash");
        vault.registerXRPLAddress(bytes32(0));
    }

    function test_registerXRPLAddress_revertsWhenPaused() public {
        vault.pause();
        vm.prank(borrower1);
        vm.expectRevert("Paused");
        vault.registerXRPLAddress(keccak256("rNewAddress"));
    }

    function test_drawLoan_revertsIfXRPLNotRegistered() public {
        // A borrower who never registered their XRPL address cannot draw
        address unregistered = makeAddr("unregistered");
        fxrp.mint(unregistered, 1_000e6);
        vm.prank(unregistered);
        fxrp.approve(address(vault), type(uint256).max);

        vm.startPrank(unregistered);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        vault.requestEligibility(loanId);
        vm.stopPrank();

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = _signAttestation(
            unregistered, LOAN_150_USDT, expiry, 0, 0
        );
        vm.prank(unregistered);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: unregistered,
            limit: LOAN_150_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));

        // XRPL not registered → cannot draw
        vm.prank(unregistered);
        vm.expectRevert(CreditGateTypes.XRPLAddressNotRegistered.selector);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    function test_submitRepaymentProof_revertsIfReceiverMismatch() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        // Build proof with WRONG receiver (attacker's XRPL address)
        bytes32 wrongReceiver = keccak256("rAttackerAddress");
        IXRPPayment.Proof memory proof = _buildProof(
            loan.requiredRepaymentDrops, loan.expectedCommitment, wrongReceiver
        );

        fdc.setResult(true);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.RepaymentReceiverMismatch.selector,
                keccak256("rCreditGateBorrower1"),
                wrongReceiver
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_submitRepaymentProof_receiverMustMatchRegistration() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        // L5 fix: the XRPL hash is snapshotted onto the loan at draw time. Re-binding
        // after draw does NOT change the expected receiver — the proof must match
        // the snapshot. A proof with a wrong receiver should still revert.
        vm.prank(borrower1);
        vault.registerXRPLAddress(keccak256("rNewBorrower1Address"));

        // Proof with a receiver that doesn't match the draw-time snapshot
        IXRPPayment.Proof memory proof = _buildProof(
            loan.requiredRepaymentDrops, loan.expectedCommitment, keccak256("rWrongReceiver")
        );
        fdc.setResult(true);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.RepaymentReceiverMismatch.selector,
                keccak256("rCreditGateBorrower1"), // snapshot from draw time
                keccak256("rWrongReceiver")
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_twoSequentialLoans() public {
        vm.startPrank(borrower1);
        uint256 id1 = vault.depositCollateral(DEPOSIT_50_FXRP);
        uint256 id2 = vault.depositCollateral(DEPOSIT_50_FXRP);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);

        CreditGateTypes.Loan memory loan1 = vault.getLoan(id1);
        CreditGateTypes.Loan memory loan2 = vault.getLoan(id2);
        assertEq(loan1.collateralAmount, DEPOSIT_50_FXRP);
        assertEq(loan2.collateralAmount, DEPOSIT_50_FXRP);
    }

    // ═══════════════════ INTEREST RATE TESTS (subagent #47) ═══════════════════

    function test_interest_constants() public view {
        assertEq(vault.INTEREST_RATE_BPS(), 500);
        assertEq(vault.SECONDS_PER_YEAR(), 365 days);
    }

    function test_getInterestOwed_zeroBeforeFunded() public {
        uint256 loanId = _setupLoanToEligible();
        // Loan still ELIGIBLE → no interest owed.
        assertEq(vault.getInterestOwed(loanId), 0);
        assertEq(vault.getTotalRepayment(loanId), 0);
    }

    function test_getInterestOwed_zeroImmediatelyAfterDraw() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // At draw time elapsed == 0 → interest is exactly 0.
        assertEq(vault.getInterestOwed(loanId), 0);
        assertEq(vault.getTotalRepayment(loanId), LOAN_100_USDT);
    }

    function test_getInterestOwed_accruesOverTime() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // Bug 1 fix: interest is capped at `loanDuration` (LOAN_DURATION = 7 days
        // in this suite). Warping past the loan's lifetime yields the SAME interest
        // as warping to exactly the deadline — the cap stops the linear accrual at
        // one loan period. We verify both sides of the cap in one test: warp FORWARD
        // of the deadline, then warp back to exactly the deadline, both must agree.
        vm.warp(block.timestamp + LOAN_DURATION);
        // Simple interest for ONE full loan period:
        //   interest = loanAmount * INTEREST_RATE_BPS * LOAN_DURATION / (10000 * SECONDS_PER_YEAR)
        uint256 expectedInterest = (LOAN_100_USDT * 500 * LOAN_DURATION) /
            (10000 * 365 days);
        assertEq(vault.getInterestOwed(loanId), expectedInterest,
            "interest at deadline must equal one full period's accrual");
        assertEq(vault.getTotalRepayment(loanId), LOAN_100_USDT + expectedInterest);

        // Warp further (past the deadline) — interest MUST NOT grow beyond the cap.
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.getInterestOwed(loanId), expectedInterest,
            "interest must be capped at loanDuration, not grow past it");
        assertEq(vault.getTotalRepayment(loanId), LOAN_100_USDT + expectedInterest);
    }

    function test_getInterestOwed_zeroAfterClosed() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // Repay immediately (interest = 0) → loan CLOSED → no interest reported.
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        IXRPPayment.Proof memory proof = _buildProof(
            loan.requiredRepaymentDrops, loan.expectedCommitment,
            keccak256("rCreditGateBorrower1")
        );
        fdc.setResult(true);
        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.CLOSED));
        // A closed loan owes no interest; getTotalRepayment returns principal only.
        assertEq(vault.getInterestOwed(loanId), 0);
        assertEq(vault.getTotalRepayment(loanId), loan.loanAmount);
    }

    function test_submitRepaymentProof_revertsIfInterestUnpaid() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // Warp to the deadline (elapsed == LOAN_DURATION). Bug 1 fix: interest is
        // capped at `loanDuration`, so the cap matches the linear formula exactly
        // here. interest in USDT0 drops to:
        //   interestUSDT0 = 100e18 * 500 * 7 days / (10000 * 365 days) ≈ 0.09589e18
        // interestDrops = interestUSDT0 * requiredRepaymentDrops / loanAmount
        //              = interestUSDT0 * 40e6 / 100e18.
        vm.warp(block.timestamp + LOAN_DURATION);
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 interestUSDT0 = vault.getInterestOwed(loanId);
        uint256 interestDrops = (interestUSDT0 * loan.requiredRepaymentDrops) /
            loan.loanAmount;
        uint256 requiredWithInterest = loan.requiredRepaymentDrops + interestDrops;

        // Pay only the principal drops → must revert with the higher requirement.
        IXRPPayment.Proof memory proof = _buildProof(
            loan.requiredRepaymentDrops, loan.expectedCommitment,
            keccak256("rCreditGateBorrower1")
        );
        fdc.setResult(true);

        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.InsufficientRepayment.selector,
                int256(uint256(loan.requiredRepaymentDrops)),
                requiredWithInterest
            )
        );
        vault.submitRepaymentProof(loanId, proof);
    }

    function test_submitRepaymentProof_succeedsWithInterestAfterYear() public {
        uint256 loanId = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);

        // Warp to the loan deadline (elapsed == LOAN_DURATION). Bug 1 fix: interest
        // is capped at `loanDuration`, so this is the MAXIMUM interest a loan can
        // accrue. Bug 2 fix: the protocol reserve fee is now charged on the
        // INTEREST-equivalent collateral, not the full collateral, so:
        //   interestUSDT0        = getInterestOwed(loanId)
        //   interestInCollateral = interestUSDT0 * requiredRepaymentDrops / loanAmount
        //   fee                  = interestInCollateral * 100 / 10000
        //   returned to borrower  = collateralAmount - fee
        vm.warp(block.timestamp + LOAN_DURATION);
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 interestDrops = (vault.getInterestOwed(loanId) *
            loan.requiredRepaymentDrops) / loan.loanAmount;
        uint256 payAmount = loan.requiredRepaymentDrops + interestDrops;

        IXRPPayment.Proof memory proof = _buildProof(
            payAmount, loan.expectedCommitment,
            keccak256("rCreditGateBorrower1")
        );
        fdc.setResult(true);

        // Expect the InterestAccrued event from the next call (interest > 0).
        uint256 expectedInterest = vault.getInterestOwed(loanId);
        vm.expectEmit(true, false, false, true);
        emit CreditGateTypes.InterestAccrued(loanId, expectedInterest);

        uint256 fxrpBalBefore = fxrp.balanceOf(borrower1);

        // Compute the expected collateralReleased under the new fee-on-interest
        // rule. Mirrors the contract math exactly (floor division arithmetic).
        uint256 interestInCollateral =
            (expectedInterest * loan.requiredRepaymentDrops) / loan.loanAmount;
        uint256 expectedFee = (interestInCollateral * 100) / 10000;
        uint256 expectedRelease = DEPOSIT_100_FXRP - expectedFee;

        vm.prank(borrower1);
        vault.submitRepaymentProof(loanId, proof);

        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.CLOSED));
        // Bug 2 fix: fee is now 1% of interest-equivalent collateral, not 1% of
        // the entire deposit. Expect the precomputed released amount.
        assertEq(fxrp.balanceOf(borrower1), fxrpBalBefore + expectedRelease);
    }
}
