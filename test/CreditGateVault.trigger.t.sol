// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVaultTriggerTest — automated FTSO-threshold liquidation trigger
/// @dev Tests `checkAndTriggerLiquidation` and `batchCheckLiquidation` added by
///      subagent #54. Mirrors the harness in CreditGateVault.auction.t.sol.
contract CreditGateVaultTriggerTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public borrower2 = makeAddr("borrower2");
    address public keeper = makeAddr("keeper");
    address public bidder = makeAddr("bidder");

    // TEE authority key pair
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config — match main suite
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300;
    uint256 constant LOAN_DURATION = 7 days;

    uint256 constant XRP_PRICE_2_50 = 2.5e18;
    uint256 constant XRP_PRICE_0_85 = 0.85e18; // below LIQUIDATION_THRESHOLD (0.9e18)
    uint256 constant XRP_PRICE_0_90 = 0.9e18;  // exactly at threshold (not <)
    uint256 constant XRP_PRICE_1_00 = 1.0e18;  // above threshold (healthy-ish)

    uint256 constant DEPOSIT_100_FXRP = 100e6;
    uint256 constant DEPOSIT_200_FXRP = 200e6;
    uint256 constant LOAN_100_USDT = 100e18;
    uint256 constant LOAN_150_USDT = 150e18;

    // At $2.50: startPrice = (100e6 * 1e12 * 2.5e18) / 1e18 = 250e18.
    uint256 constant START_PRICE_2_50 = 250e18;
    // At $0.85: startPrice = (100e6 * 1e12 * 0.85e18) / 1e18 = 85e18.
    uint256 constant START_PRICE_0_85 = 85e18;

    // ═══════════════════ Setup ═══════════════════

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);

        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", 18);
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
        usdt0.mint(address(vault), 10_000e18);

        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);
        vm.prank(borrower2);
        fxrp.approve(address(vault), type(uint256).max);

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

    function _setupFundedLoan(address borrower, uint256 nonce)
        internal
        returns (uint256 loanId)
    {
        vm.prank(borrower);
        loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(borrower, LOAN_150_USDT, expiry, uint32(nonce), 0);

        vm.prank(borrower);
        vault.submitEligibility(
            loanId,
            CreditGateTypes.EligibilityAttestation({
                borrower: borrower,
                limit: LOAN_150_USDT,
                expiry: expiry,
                nonce: uint32(nonce),
                revocationVersion: 0,
                v: v,
                r: r,
                s: s
            })
        );

        vm.prank(borrower);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    /// @dev Variant with a LARGER collateral deposit so the loan stays healthy
    ///      even after the XRP price drops to $0.85. 200 FXRP @ $0.85 ⇒
    ///      collateralUsd18 = 170e18, HF = 170e18 * 1e18 / 100e18 = 1.7e18 (healthy).
    function _setupHealthyFundedLoan(address borrower, uint256 nonce)
        internal
        returns (uint256 loanId)
    {
        vm.prank(borrower);
        loanId = vault.depositCollateral(DEPOSIT_200_FXRP);

        vm.prank(borrower);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(borrower, LOAN_150_USDT, expiry, uint32(nonce), 0);

        vm.prank(borrower);
        vault.submitEligibility(
            loanId,
            CreditGateTypes.EligibilityAttestation({
                borrower: borrower,
                limit: LOAN_150_USDT,
                expiry: expiry,
                nonce: uint32(nonce),
                revocationVersion: 0,
                v: v,
                r: r,
                s: s
            })
        );

        vm.prank(borrower);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    /// @dev Drop the XRP price below the liquidation threshold.
    function _dropPriceBelowThreshold() internal {
        ftso.setValueInWei(XRP_PRICE_0_85, uint64(block.timestamp));
    }

    /// @dev Set price exactly at threshold (not below).
    function _setPriceAtThreshold() internal {
        ftso.setValueInWei(XRP_PRICE_0_90, uint64(block.timestamp));
    }

    /// @dev Keep a healthy price (above threshold).
    function _setPriceHealthy() internal {
        ftso.setValueInWei(XRP_PRICE_1_00, uint64(block.timestamp));
    }

    // ═══════════════════ TEST 1: trigger fires when health factor drops below threshold ═══════════════════

    function test_checkAndTriggerLiquidation_firesWhenUndercollateralized() public {
        uint256 loanId = _setupFundedLoan(borrower1, 0);

        // Before the price drop: healthy.
        uint256 hfHealthy = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hfHealthy, 2.5e18, "must start healthy");

        // Price crashes so collateral is worth less than 90% of the loan.
        _dropPriceBelowThreshold();

        // Sanity: HF should now be 0.85e18 < 0.9e18 threshold.
        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, 0.85e18, "HF must be 0.85e18 at $0.85");
        assertLt(hf, LIQUIDATION_THRESHOLD, "HF must be below threshold");

        // Keeper triggers the liquidation.
        vm.expectEmit(true, false, false, true);
        emit LiquidationTriggered(loanId, hf, XRP_PRICE_0_85);

        vm.expectEmit(true, true, false, true);
        emit LiquidationAuctionStarted(
            loanId,
            borrower1,
            START_PRICE_0_85,
            uint64(block.timestamp)
        );

        vm.prank(keeper);
        LoanState state = vault.checkAndTriggerLiquidation{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.AUCTION));

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.AUCTION));
        assertEq(vault.getAuctionPrice(loanId), START_PRICE_0_85);
    }

    // ═══════════════════ TEST 2: trigger is no-op when HF is exactly at threshold ═══════════════════

    function test_checkAndTriggerLiquidation_noOpAtExactThreshold() public {
        uint256 loanId = _setupFundedLoan(borrower1, 0);

        _setPriceAtThreshold();
        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, LIQUIDATION_THRESHOLD, "HF must equal threshold");

        vm.prank(keeper);
        LoanState state = vault.checkAndTriggerLiquidation{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.FUNDED));
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
    }

    // ═══════════════════ TEST 3: trigger is no-op when healthy ═══════════════════

    function test_checkAndTriggerLiquidation_noOpWhenHealthy() public {
        uint256 loanId = _setupFundedLoan(borrower1, 0);

        _setPriceHealthy();
        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertGt(hf, LIQUIDATION_THRESHOLD, "HF must be above threshold");

        vm.prank(keeper);
        LoanState state = vault.checkAndTriggerLiquidation{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.FUNDED));
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
    }

    // ═══════════════════ TEST 4: trigger returns unchanged state for non-funded loan ═══════════════════

    function test_checkAndTriggerLiquidation_noOpForNonFundedLoan() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        _dropPriceBelowThreshold();

        vm.prank(keeper);
        LoanState state = vault.checkAndTriggerLiquidation{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.COLLATERAL_DEPOSITED));
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.COLLATERAL_DEPOSITED));
    }

    // ═══════════════════ TEST 5: trigger is no-op when FTSO returns zero ═══════════════════

    function test_checkAndTriggerLiquidation_noOpWhenPriceZero() public {
        uint256 loanId = _setupFundedLoan(borrower1, 0);

        // Oracle outage: feed returns 0. Even though the loan is undercollateralized
        // at $2.50, a zero feed must never trigger liquidation.
        ftso.setValueInWei(0, uint64(block.timestamp));

        vm.prank(keeper);
        LoanState state = vault.checkAndTriggerLiquidation{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.FUNDED));
    }

    // ═══════════════════ TEST 6: batch liquidation triggers only undercollateralized loans ═══════════════════

    function test_batchCheckLiquidation_triggersOnlyUnhealthyLoans() public {
        // Loan 1: 100 FXRP collateral — will become undercollateralized at $0.85
        //         (HF = 0.85e18 < 0.9e18 threshold).
        uint256 loan1 = _setupFundedLoan(borrower1, 0);
        // Loan 2: 200 FXRP collateral — stays healthy even at $0.85
        //         (HF = 1.7e18 ≥ threshold). The per-borrower eligibility nonce is
        //         only bumped by revokeEligibility, so a second loan from the same
        //         borrower still uses nonce 0.
        uint256 loan2 = _setupHealthyFundedLoan(borrower1, 0);
        // Loan 3: non-funded (collateral deposited only).
        vm.prank(borrower1);
        uint256 loan3 = vault.depositCollateral(DEPOSIT_100_FXRP);

        _dropPriceBelowThreshold();

        uint256[] memory ids = new uint256[](3);
        ids[0] = loan1;
        ids[1] = loan2;
        ids[2] = loan3;

        // Events: only loan1 should emit both LiquidationTriggered and LiquidationAuctionStarted.
        vm.expectEmit(true, false, false, true);
        emit LiquidationTriggered(loan1, 0.85e18, XRP_PRICE_0_85);
        vm.expectEmit(true, true, false, true);
        emit LiquidationAuctionStarted(
            loan1,
            borrower1,
            START_PRICE_0_85,
            uint64(block.timestamp)
        );

        vm.prank(keeper);
        uint256[] memory triggered = vault.batchCheckLiquidation{value: 0}(ids);

        assertEq(triggered.length, 1, "only one loan must have triggered");
        assertEq(triggered[0], loan1, "loan1 must be the triggered one");

        // loan1 is now in AUCTION; loan2 still FUNDED; loan3 still COLLATERAL_DEPOSITED.
        assertEq(uint8(vault.getLoan(loan1).state), uint8(LoanState.AUCTION));
        assertEq(uint8(vault.getLoan(loan2).state), uint8(LoanState.FUNDED));
        assertEq(
            uint8(vault.getLoan(loan3).state),
            uint8(LoanState.COLLATERAL_DEPOSITED)
        );
    }

    // ═══════════════════ TEST 7: batch liquidation with empty array is a no-op ═══════════════════

    function test_batchCheckLiquidation_emptyArrayNoOp() public {
        uint256[] memory ids = new uint256[](0);

        vm.prank(keeper);
        uint256[] memory triggered = vault.batchCheckLiquidation{value: 0}(ids);

        assertEq(triggered.length, 0);
    }

    // ═══════════════════ TEST 8: batch liquidation with all healthy returns empty ═══════════════════

    function test_batchCheckLiquidation_allHealthyReturnsEmpty() public {
        uint256 loan1 = _setupFundedLoan(borrower1, 0);
        uint256 loan2 = _setupFundedLoan(borrower2, 0);

        // Price stays at $2.50; both loans healthy.
        uint256[] memory ids = new uint256[](2);
        ids[0] = loan1;
        ids[1] = loan2;

        vm.prank(keeper);
        uint256[] memory triggered = vault.batchCheckLiquidation{value: 0}(ids);

        assertEq(triggered.length, 0);
        assertEq(uint8(vault.getLoan(loan1).state), uint8(LoanState.FUNDED));
        assertEq(uint8(vault.getLoan(loan2).state), uint8(LoanState.FUNDED));
    }

    // ═══════════════════ TEST 9: a triggered auction can be bid on and finalized ═══════════════════

    function test_triggeredAuctionIsFullyFunctional() public {
        uint256 loanId = _setupFundedLoan(borrower1, 0);
        _dropPriceBelowThreshold();

        usdt0.mint(bidder, 1_000e18);
        vm.prank(bidder);
        usdt0.approve(address(vault), type(uint256).max);

        vm.prank(keeper);
        vault.checkAndTriggerLiquidation{value: 0}(loanId);

        // Bid at the current auction price.
        uint256 bidAmount = vault.getAuctionPrice(loanId);
        assertEq(bidAmount, START_PRICE_0_85);

        vm.prank(bidder);
        vault.bidOnLiquidation(loanId, bidAmount);

        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        vault.finalizeAuction(loanId);

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.CLOSED));
        assertEq(loan.collateralAmount, 0);
    }
}
