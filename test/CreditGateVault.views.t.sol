// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVaultViewsTest — health factor + loan/portfolio summary views (subagent #48)
/// @dev Mirrors the harness in CreditGateVault.t.sol so we can reuse the proven
///      deposit→eligibility→draw flow that produces a real FUNDED loan.
contract CreditGateVaultViewsTest is Test, CreditGateTypes {
    CreditGateVault public vault;
    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public borrower2 = makeAddr("borrower2");

    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // ── Config ──
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

    // ═══════════════════ Helpers (mini-copies of the t.sol harness) ═══════════════════

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

    function _setupBorrower1ToEligible() internal returns (uint256 loanId) {
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

    function _fundBorrower1Loan() internal returns (uint256 loanId) {
        loanId = _setupBorrower1ToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    // ═══════════════════ getHealthFactor ═══════════════════

    function test_getHealthFactor_nonFundedReturnsMaxUint() public {
        // Loan is only COLLATERAL_DEPOSITED → healthy by default.
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, type(uint256).max, "non-funded must return type(uint256).max");
    }

    function test_getHealthFactor_nonExistentLoanReturnsMaxUint() public {
        // loan id #999 was never created → loan.state == IDLE → healthy by default.
        uint256 hf = vault.getHealthFactor{value: 0}(999);
        assertEq(hf, type(uint256).max, "idle loan must return type(uint256).max");
    }

    function test_getHealthFactor_fundedIs250pct() public {
        uint256 loanId = _fundBorrower1Loan();
        // collateralUsd18 = 100e6 * 1e12 * 2.5e18 / 1e18 = 250e18
        // loanValueUsd18   = 100e18  (no interest module)
        // healthFactor     = 250e18 * 1e18 / 100e18 = 2.5e18  (250% collateralised)
        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, 2.5e18, "funded loan at $2.50 XRP with 100 FXRP / 100 USDT must be 2.5e18");
    }

    function test_getHealthFactor_undercollateralizedWhenPriceFalls() public {
        uint256 loanId = _fundBorrower1Loan();

        // Drop XRP price to $0.90 → collateralUsd18 = 90e18 < 100e18 loan ⇒ HF = 0.9e18.
        ftso.setValueInWei(0.9e18, uint64(block.timestamp));

        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, 0.9e18, "at $0.90 XRP the loan must be undercollateralized (HF < 1e18)");
        assertLt(hf, 1e18, "HF < 1e18 must be flagged liquidatable");
    }

    function test_getHealthFactor_healthierWhenPriceRises() public {
        uint256 loanId = _fundBorrower1Loan();
        // Bump XRP to $5.00 → collateralUsd18 = 500e18, HF = 500e18 * 1e18 / 100e18 = 5e18.
        ftso.setValueInWei(5e18, uint64(block.timestamp));
        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, 5e18, "rising price must increase health factor");
        assertGt(hf, 1e18, "healthier HF must remain > 1e18");
    }

    function test_getHealthFactor_zeroFeedReportsHealthy() public {
        // A loan that is FUNDED reads the live feed — but if the oracle momentarily
        // returns 0 the view must not flag it as liquidatable (defensive).
        uint256 loanId = _fundBorrower1Loan();
        ftso.setValueInWei(0, uint64(block.timestamp));
        uint256 hf = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf, type(uint256).max, "zero feed must report healthy (avoid false-positive liquidation)");
    }

    // ═══════════════════ getLoanSummary ═══════════════════

    function test_getLoanSummary_fundedLoan() public {
        uint256 loanId = _fundBorrower1Loan();
        uint256 expectedDeadline = block.timestamp + LOAN_DURATION;

        (
            LoanState state,
            uint256 collateralAmount,
            uint256 loanAmount,
            uint256 interestOwed,
            uint256 totalRepayment,
            uint256 deadline,
            uint256 healthFactor
        ) = vault.getLoanSummary{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.FUNDED));
        assertEq(collateralAmount, DEPOSIT_100_FXRP, "collateral");
        assertEq(loanAmount, LOAN_100_USDT, "loan principal");
        assertEq(interestOwed, 0, "no interest module yet");
        assertEq(totalRepayment, LOAN_100_USDT, "totalRepayment = principal + 0 interest");
        assertEq(deadline, expectedDeadline, "deadline");
        // Same math as the dedicated HF test:
        assertEq(healthFactor, 2.5e18, "summary HF must match getHealthFactor");
    }

    function test_getLoanSummary_nonFundedLoanHasMaxUintHF() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        (LoanState state,, uint256 loanAmount,,, uint256 deadline, uint256 healthFactor) =
            vault.getLoanSummary{value: 0}(loanId);

        assertEq(uint8(state), uint8(LoanState.COLLATERAL_DEPOSITED));
        assertEq(loanAmount, 0, "no loan drawn yet");
        assertEq(deadline, 0, "deadline unset");
        assertEq(healthFactor, type(uint256).max, "non-funded must report healthy");
    }

    function test_getLoanSummary_reflectsPriceChange() public {
        uint256 loanId = _fundBorrower1Loan();
        ftso.setValueInWei(1e18, uint64(block.timestamp)); // XRP → $1.00

        (,,,,,, uint256 healthFactor) = vault.getLoanSummary{value: 0}(loanId);
        // collateralUsd18 = 100e6 * 1e12 * 1e18 / 1e18 = 100e18 == loan ⇒ HF = 1e18.
        assertEq(healthFactor, 1e18, "at breakeven price HF = 1e18 exactly");
    }

    // ═══════════════════ getPortfolioSummary ═══════════════════

    function test_getPortfolioSummary_emptyBorrower() public {
        (uint256 totalCollateral, uint256 totalBorrowed, uint256 activeLoans, uint256 interestOwed) =
            vault.getPortfolioSummary(borrower2);

        assertEq(totalCollateral, 0);
        assertEq(totalBorrowed, 0);
        assertEq(activeLoans, 0);
        assertEq(interestOwed, 0, "no interest module yet");
    }

    function test_getPortfolioSummary_singleFundedLoan() public {
        uint256 loanId = _fundBorrower1Loan();

        (uint256 totalCollateral, uint256 totalBorrowed, uint256 activeLoans, uint256 interestOwed) =
            vault.getPortfolioSummary(borrower1);

        assertEq(totalCollateral, DEPOSIT_100_FXRP, "collateral across portfolio");
        assertEq(totalBorrowed, LOAN_100_USDT, "borrowed across portfolio");
        assertEq(activeLoans, 1, "exactly one FUNDED loan");
        assertEq(interestOwed, 0, "no interest module yet");

        // Sanity: the active loan must actually be FUNDED.
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED));
    }

    function test_getPortfolioSummary_mixOfStatesAndMultipleLoans() public {
        // Loan A: funded for 100 USDT.
        uint256 loanA = _fundBorrower1Loan();

        // Loan B: only COLLATERAL_DEPOSITED — should NOT count as active.
        vm.prank(borrower1);
        vault.depositCollateral(50e6);

        (uint256 totalCollateral, uint256 totalBorrowed, uint256 activeLoans,) =
            vault.getPortfolioSummary(borrower1);

        assertEq(totalCollateral, DEPOSIT_100_FXRP + 50e6, "collateral sums both loans");
        assertEq(totalBorrowed, LOAN_100_USDT, "only loan A has principal");
        assertEq(activeLoans, 1, "loan B is not FUNDED so must not be active");

        // Now liquidate loan A → [] of "active" must drop to 0 even though loanAmount stays.
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        vault.liquidate(loanA);

        (uint256 totalCollateral2, uint256 totalBorrowed2, uint256 activeLoans2,) =
            vault.getPortfolioSummary(borrower1);

        // After liquidation the collateral is moved off the loan (seizedCollateral mapping),
        // so totalCollateral only counts loan B's deposit (50e6).
        assertEq(totalCollateral2, 50e6, "liquidated loan's collateral is seized (removed)");
        // loanAmount stays on the Loan struct even after liquidation (DEFAULTED), and we
        // summed totalBorrowed across ALL loan states — so it should still be 100e18.
        assertEq(totalBorrowed2, LOAN_100_USDT, "defaulted loan principal still owed");
        assertEq(activeLoans2, 0, "FUNDED count must drop to zero after liquidation");
    }

    // ═══════════════════ Interest-aware views (subagent #47 hooked in) ═══════════════════
    //
    // Math helpers for interest expectations:
    //   INTEREST_RATE_BPS = 500  (5% APY), SECONDS_PER_YEAR = 365 days.
    //   startTime = deadline - loanDuration = now (draw time). elapsed = warp - now.
    //   interest = loanAmount * 500 * elapsed / (10000 * 365 days).
    //   Bug 1 fix: interest is capped at `loanDuration`. Warping past the deadline
    //   yields the SAME interest as warping to exactly the deadline — the cap stops
    //   the linear accrual at one loan period. We warp to exactly LOAN_DURATION.
    //   At LOAN_DURATION = 7 days ⇒ interest = 100e18 * 500 * 7 days /
    //     (10000 * 365 days) ≈ 0.09589e18 (one full loan period's interest).

    function test_getLoanSummary_interestAccrues() public {
        uint256 loanId = _fundBorrower1Loan();
        // Warp exactly one loan period. Bug 1 fix: interest is capped at
        // LOAN_DURATION — warping further would not increase the accrued amount.
        vm.warp(block.timestamp + LOAN_DURATION);

        (, uint256 collateral, uint256 loanAmount, uint256 interestOwed,
            uint256 totalRepayment,,) = vault.getLoanSummary{value: 0}(loanId);

        assertEq(collateral, DEPOSIT_100_FXRP, "collateral unchanged");
        assertEq(loanAmount, LOAN_100_USDT, "principal unaffected by interest");
        uint256 expectedInterest = (LOAN_100_USDT * 500 * LOAN_DURATION) /
            (10000 * 365 days);
        assertEq(interestOwed, expectedInterest, "interest = one full loan period's accrual (capped)");
        assertEq(totalRepayment, LOAN_100_USDT + expectedInterest, "principal + interest");
    }

    function test_getHealthFactor_dropsAsInterestAccrues() public {
        uint256 loanId = _fundBorrower1Loan();
        uint256 hf0 = vault.getHealthFactor{value: 0}(loanId);
        assertEq(hf0, 2.5e18, "HF at draw must be 2.5e18 (no interest)");

        vm.warp(block.timestamp + LOAN_DURATION);
        uint256 hf1 = vault.getHealthFactor{value: 0}(loanId);

        // loanValueUsd18 = 100e18 + interestCapped; collateralUsd18 = 250e18 ($2.50).
        // HF = 250e18 * 1e18 / loanValueUsd18. Floor the division exactly.
        uint256 interestCapped = (LOAN_100_USDT * 500 * LOAN_DURATION) /
            (10000 * 365 days);
        uint256 expectedHF = uint256(250e18) * 1e18 / uint256(LOAN_100_USDT + interestCapped);
        assertEq(hf1, expectedHF, "HF must drop toward 1e18 as interest accrues");
        assertLt(hf1, hf0, "accrued interest must lower the health factor");
        assertGt(hf1, 1e18, "still well collateralised at the deadline");
    }

    function test_getPortfolioSummary_aggregatesInterest() public {
        // Two FUNDED loans for borrower1. We can only fund the first with this mock
        // harness (one eligibility per borrower at a time), so simulate a second
        // FUNDED loan by depositing more collateral and drawing again — but the
        // harness attestation is single-shot per nonce. Easiest robust path: fund
        // one loan, warp, and confirm portfolio interest == per-loan interest.
        uint256 loanId = _fundBorrower1Loan();
        // Warp exactly one loan period (Bug 1 fix: interest is capped beyond this).
        vm.warp(block.timestamp + LOAN_DURATION);

        (uint256 totalCollateral, uint256 totalBorrowed, uint256 activeLoans, uint256 totalInterestOwed) =
            vault.getPortfolioSummary(borrower1);

        uint256 expectedInterest = (LOAN_100_USDT * 500 * LOAN_DURATION) /
            (10000 * 365 days);

        assertEq(totalCollateral, DEPOSIT_100_FXRP);
        assertEq(totalBorrowed, LOAN_100_USDT);
        assertEq(activeLoans, 1);
        assertEq(totalInterestOwed, expectedInterest, "portfolio interest == per-loan interest (single loan)");

        // Cross-check against getInterestOwed directly.
        assertEq(totalInterestOwed, vault.getInterestOwed(loanId),
            "aggregated interest must equal per-loan getInterestOwed");
    }
}
