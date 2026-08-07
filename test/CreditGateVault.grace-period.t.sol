// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVaultGracePeriodTest — 5 behavioral grace-period tests
/// @notice Replaces the weak 2-test parameter-management suite with full
///         behavioral coverage of the 24h borrower-protection window that
///         blocks liquidation (and auction start) before the deadline +
///         `gracePeriodSeconds` have elapsed. Covers the success path, the
///         revert path, the inclusive boundary, owner updates changing
///         behavior at runtime, and the zero-grace edge case.
/// @dev    Follows the setUp + `_setupLoanToFunded` + `_signAttestation` +
///         `_refreshFtso` helper pattern from CreditGateVault.auction.t.sol.
contract CreditGateVaultGracePeriodTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    // The test contract IS the vault owner (constructor sets owner = msg.sender).
    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public liquidator = makeAddr("liquidator");

    // TEE authority key pair for signing eligibility attestations
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config constants — match the main suite / auction suite
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300; // 5 minutes
    uint256 constant LOAN_DURATION = 7 days;

    // XRP price $2.50 (18dp)
    uint256 constant XRP_PRICE_2_50 = 2.5e18;

    // FXRP (6dp) / USDT0 (18dp on Coston2) amounts
    uint256 constant DEPOSIT_100_FXRP = 100e6;
    uint256 constant LOAN_100_USDT = 100e18;
    uint256 constant LOAN_150_USDT = 150e18;

    // Default protocol grace period (set in the storage declaration).
    uint256 constant DEFAULT_GRACE = 86_400;

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

        // Sanity: constructor leaves the default 24h grace period in place.
        assertEq(vault.gracePeriodSeconds(), DEFAULT_GRACE);

        // Fund the borrower with FXRP collateral and the vault with USDT0
        // so loans can actually be drawn and disbursed.
        fxrp.mint(borrower1, 1_000e6);
        usdt0.mint(address(vault), 10_000e18);

        // Seed the FTSO feed at the current block timestamp.
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        // Borrower approves the vault to pull FXRP on deposit.
        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);

        // Borrower registers an XRPL address (required before drawLoan).
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

    /// @dev Drive a loan all the way to FUNDED so its deadline is set and
    ///      the grace-period guard on `liquidate` / `startLiquidationAuction`
    ///      becomes reachable. Returns the loan id.
    function _setupLoanToFunded() internal returns (uint256 loanId) {
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

        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_100_USDT);
    }

    /// @dev Refresh the FTSO feed timestamp to the current block so staleness
    ///      (300s limit) doesn't trip after a vm.warp. `startLiquidationAuction`
    ///      reads the feed, and liquidate/speculative callers may too.
    function _refreshFtso() internal {
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));
    }

    // ═══════════════════ TEST 1: liquidate blocks during grace, succeeds after ═══════════════════
    //
    // Loan deadline passes. `liquidate()` reverts with `GracePeriodNotElapsed(remaining)`
    // while inside the 24h grace window. Warp past the grace window and the same
    // call succeeds, flipping the loan to DEFAULTED.

    function test_gracePeriod_blocksLiquidationDuringWindow() public {
        uint256 loanId = _setupLoanToFunded();
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 deadline = loan.deadline;

        // Warp to 1 second past the deadline — inside the 24h grace window.
        vm.warp(deadline + 1);
        assertEq(vault.gracePeriodSeconds(), DEFAULT_GRACE);

        // `liquidate` reverts with the exact remaining grace time.
        uint256 expectedRemaining = (deadline + DEFAULT_GRACE) - (deadline + 1);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.GracePeriodNotElapsed.selector,
                expectedRemaining
            )
        );
        vault.liquidate(loanId);

        // Loan must still be FUNDED (the failed call did not mutate state).
        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.FUNDED));

        // Warp PAST the grace window — liquidation now succeeds.
        vm.warp(deadline + DEFAULT_GRACE + 1);

        vm.prank(liquidator);
        vault.liquidate(loanId);

        // Loan is now DEFAULTED and the seized collateral is tracked.
        CreditGateTypes.Loan memory defaulted = vault.getLoan(loanId);
        assertEq(uint8(defaulted.state), uint8(LoanState.DEFAULTED));
        assertEq(defaulted.collateralAmount, 0);
        assertEq(vault.seizedCollateral(loanId), DEPOSIT_100_FXRP);
    }

    // ═══════════════════ TEST 2: auction start blocks during grace, succeeds after ═══════════════════
    //
    // Mirror of test 1 for `startLiquidationAuction()`. During the grace window
    // the auction starter reverts with `GracePeriodNotElapsed`; after the grace
    // window the same call opens a Dutch auction (loan → AUCTION).

    function test_gracePeriod_blocksAuctionStartDuringWindow() public {
        uint256 loanId = _setupLoanToFunded();
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 deadline = loan.deadline;

        // Warp into the grace window.
        vm.warp(deadline + 1);
        _refreshFtso();

        uint256 expectedRemaining = (deadline + DEFAULT_GRACE) - (deadline + 1);
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditGateTypes.GracePeriodNotElapsed.selector,
                expectedRemaining
            )
        );
        vault.startLiquidationAuction{value: 0}(loanId);

        // Still FUNDED.
        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.FUNDED));

        // Warp past the grace window — the auction can now start.
        vm.warp(deadline + DEFAULT_GRACE + 1);
        _refreshFtso();

        uint64 auctionStart = uint64(block.timestamp);
        // Expected auction start price = collateralUsd18 =
        //   (100e6 * 1e12 * 2.5e18) / 1e18 = 2.5e20 = 250e18 USDT0.
        uint256 expectedStartPrice = 250e18;

        vm.expectEmit(true, true, false, true);
        emit LiquidationAuctionStarted(loanId, borrower1, expectedStartPrice, auctionStart);

        vm.prank(liquidator);
        vault.startLiquidationAuction{value: 0}(loanId);

        // Loan is now AUCTION.
        assertEq(uint8(vault.getLoan(loanId).state), uint8(LoanState.AUCTION));
    }

    // ═══════════════════ TEST 3: boundary — exclusive before, inclusive at ═══════════════════
    //
    // At the exact deadline, deadline+1, and deadline+gracePeriodSeconds-1 the
    // grace guard STILL blocks `liquidate` (the boundary is exclusive on the
    // left). At deadline+gracePeriodSeconds exactly it succeeds (inclusive on
    // the right). The guard is `block.timestamp < deadline + grace`, so the
    // boundary falls exactly on `deadline + grace`.

    function test_gracePeriod_boundary() public {
        uint256 loanId = _setupLoanToFunded();
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 deadline = loan.deadline;
        uint256 grace = vault.gracePeriodSeconds();

        // (a) Exact deadline: still inside the grace window. The deadline check
        //     `block.timestamp < deadline` is false (==), so the guard falls
        //     through to the grace check and reverts.
        vm.warp(deadline);
        {
            uint256 remaining = (deadline + grace) - deadline; // == grace
            vm.prank(liquidator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CreditGateTypes.GracePeriodNotElapsed.selector,
                    remaining
                )
            );
            vault.liquidate(loanId);
        }

        // (b) deadline + 1: still inside the grace window.
        vm.warp(deadline + 1);
        {
            uint256 remaining = (deadline + grace) - (deadline + 1);
            vm.prank(liquidator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CreditGateTypes.GracePeriodNotElapsed.selector,
                    remaining
                )
            );
            vault.liquidate(loanId);
        }

        // (c) deadline + grace - 1: the very last second inside the window.
        vm.warp(deadline + grace - 1);
        {
            uint256 remaining = (deadline + grace) - (deadline + grace - 1); // == 1
            vm.prank(liquidator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CreditGateTypes.GracePeriodNotElapsed.selector,
                    remaining
                )
            );
            vault.liquidate(loanId);
        }

        // (d) deadline + grace: exactly on the boundary. The guard condition
        //     `block.timestamp < deadline + grace` is now FALSE, so liquidation
        //     is allowed and the loan flips to DEFAULTED.
        vm.warp(deadline + grace);
        vm.prank(liquidator);
        vault.liquidate(loanId);

        CreditGateTypes.Loan memory defaulted = vault.getLoan(loanId);
        assertEq(uint8(defaulted.state), uint8(LoanState.DEFAULTED));
        assertEq(vault.seizedCollateral(loanId), DEPOSIT_100_FXRP);
    }

    // ═══════════════════ TEST 4: updating the grace period changes live behavior ═══════════════════
    //
    // Owner shortens the grace period from 86_400 (24h) to 3_600 (1h). A loan
    // whose deadline + 86_400 has NOT elapsed but whose deadline + 3_600 HAS:
    // under the old (24h) grace it would be untouchable, but after the owner's
    // update the shorter (1h) grace has already elapsed and `liquidate` now
    // succeeds. Proves the parameter is live-respected, not snapshotted at draw.

    function test_gracePeriod_updateChangesBehavior() public {
        uint256 loanId = _setupLoanToFunded();
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 deadline = loan.deadline;

        // Warp to deadline + 3_601 — past the 1h grace but still inside the 24h
        // grace window. With the DEFAULT 86_400 grace, liquidation must revert.
        vm.warp(deadline + 3_601);
        assertLt(block.timestamp, deadline + DEFAULT_GRACE);

        {
            uint256 remainingUnder24h = (deadline + DEFAULT_GRACE) - (deadline + 3_601);
            vm.prank(liquidator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CreditGateTypes.GracePeriodNotElapsed.selector,
                    remainingUnder24h
                )
            );
            vault.liquidate(loanId);
        }

        // Owner shortens the grace period 24h → 1h. (test contract is owner)
        vault.updateGracePeriod(3_600);
        assertEq(vault.gracePeriodSeconds(), 3_600);

        // Same timestamp, but the new shorter grace has elapsed: liquidation
        // is now allowed and the loan flips to DEFAULTED.
        assertLt(deadline + 3_600, block.timestamp);

        vm.prank(liquidator);
        vault.liquidate(loanId);

        CreditGateTypes.Loan memory defaulted = vault.getLoan(loanId);
        assertEq(uint8(defaulted.state), uint8(LoanState.DEFAULTED));
        assertEq(vault.seizedCollateral(loanId), DEPOSIT_100_FXRP);
    }

    // ═══════════════════ TEST 5: zero grace means no protection ═══════════════════
    //
    // Owner sets `gracePeriodSeconds = 0`. The grace guard becomes
    // `block.timestamp < deadline + 0` i.e. `block.timestamp < deadline`,
    // which is already covered by the preceding deadline check. So `liquidate`
    // the instant the deadline passes (warp to deadline + 1) succeeds with no
    // grace protection at all.

    function test_gracePeriod_zeroMeansNoGrace() public {
        uint256 loanId = _setupLoanToFunded();
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        uint256 deadline = loan.deadline;

        // Owner disables grace entirely.
        vault.updateGracePeriod(0);
        assertEq(vault.gracePeriodSeconds(), 0);
        assertEq(vault.getGracePeriod(), 0);

        // One second past the deadline — under DEFAULT grace this would be
        // deep inside the 24h window; with grace == 0 there is no window.
        vm.warp(deadline + 1);

        vm.prank(liquidator);
        vault.liquidate(loanId);

        CreditGateTypes.Loan memory defaulted = vault.getLoan(loanId);
        assertEq(uint8(defaulted.state), uint8(LoanState.DEFAULTED));
        assertEq(defaulted.collateralAmount, 0);
        assertEq(vault.seizedCollateral(loanId), DEPOSIT_100_FXRP);
    }
}
