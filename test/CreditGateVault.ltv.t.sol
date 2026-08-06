// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVaultLTVTest — per-collateral LTV ratio config (subagent #55)
/// @dev Mirrors the harness in CreditGateVault.views.t.sol so the proven
///      deposit→eligibility→draw flow can be reused. Covers:
///        §1  LTV defaults (FXRP=7500, USDT0=8500)
///        §2  collateralDecimals defaults (FXRP=6, USDT0=18)
///        §3  registerCollateral (FLR onboarding, owner-only, validation)
///        §4  updateLTV (owner-only, emits LTVUpdated, validation)
///        §5  getMaxLoanAmount — ratio-bound vs LTV-bound vs zero
///        §6  drawLoan respects a tightened LTV cap (new branch reverting)
///      Math (FXRP 6dp, USDT0 18dp, price $2.50):
///        collateralUsd18 = 100e6 * 1e12 * 2.5e18 / 1e18 = 250e18
///        ratioBound (150% floor) = 250e18 * 10000 / 15000 = 166.666…e18
///        ltvBound   (75% LTV)    = 250e18 * 7500        / 10000 = 187.5e18
///        When FXRP LTV is tightened to 6000 (60%): ltvBound = 150e18 < 166.66e18,
///        so the LTV cap becomes the binding constraint.
contract CreditGateVaultLTVTest is Test, CreditGateTypes {
    CreditGateVault public vault;
    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockERC20 public flr; // registered post-deploy via registerCollateral
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");

    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // ── Config ──
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150% global floor
    uint64 constant FTSO_STALENESS_LIMIT = 300;
    uint256 constant LOAN_DURATION = 7 days;
    uint256 constant XRP_PRICE_2_50 = 2.5e18;
    uint256 constant DEPOSIT_100_FXRP = 100e6;
    // USDT0 on Coston2 is 18 decimals (verified 2026-08-05, per task context).
    // NOTE: older test files use a 6dp MockERC20 for USDT0; here we use the real
    // 18dp config so the LTV / decimals-factor path is exercised truthfully.
    uint8 constant USDT0_DECIMALS_TEST = 18;
    uint256 constant LOAN_150_USDT = 150e18;
    uint256 constant LOAN_160_USDT = 160e18;
    uint256 constant LOAN_500_USDT = 500e18; // large attestation limit so it never binds first

    // Expected max-loan math:
    //   collateralUsd18 = 100e6 * 1e12 * 2.5e18 / 1e18 = 250e18
    //   ratioBound      = 250e18 * 10000 / 15000 = 166.666666666666666666 e18
    //   (250e18 * 10000 = 2.5e21; 2.5e21 / 15000 = 166666666666666666666 wei)
    uint256 constant EXPECTED_RATIO_BOUND = 166_666_666_666_666_666_666; // floor(250e18 * 10000 / 15000)
    //   ltvBound(7500) = 250e18 * 7500 / 10000 = 187_500_000_000_000_000_000  (187.5e18)
    uint256 constant EXPECTED_LTV_BOUND_7500 = 187.5e18;
    //   ltvBound(6000) = 250e18 * 6000 / 10000 = 150e18
    uint256 constant EXPECTED_LTV_BOUND_6000 = 150e18;

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);

        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", USDT0_DECIMALS_TEST);
        flr = new MockERC20("Flare", "FLR", 18);
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
        vault.registerXRPLAddress(keccak256("rCreditGateBorrowerLTV"));

        // Onboard FLR as a collateral type via the owner-only initializer (FLR is
        // NOT a constructor param). 80% LTV, 18 decimals.
        vault.registerCollateral(address(flr), 8000, 18);
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

    /// @dev Deposits 100 FXRP, requests eligibility, submits a valid TEE
    ///      attestation with a HIGH limit (500e18) so the limit never binds
    ///      first — lets drawLoan tests isolate the ratio vs LTV branches.
    function _setupToEligible() internal returns (uint256 loanId) {
        vm.prank(borrower1);
        loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        vm.prank(borrower1);
        vault.requestEligibility(loanId);

        uint64 expiry = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) =
            _signAttestation(borrower1, LOAN_500_USDT, expiry, 0, 0);

        vm.prank(borrower1);
        vault.submitEligibility(loanId, CreditGateTypes.EligibilityAttestation({
            borrower: borrower1,
            limit: LOAN_500_USDT,
            expiry: expiry,
            nonce: 0,
            revocationVersion: 0,
            v: v, r: r, s: s
        }));
    }

    // ═══════════════════ §1 getLTV defaults ═══════════════════

    function test_getLTV_defaultsAfterConstruction() public {
        assertEq(vault.getLTV(address(fxrp)), 7500, "FXRP default LTV must be 7500 bps (75%)");
        assertEq(vault.getLTV(address(usdt0)), 8500, "USDT0 default LTV must be 8500 bps (85%)");
        // FLR was registered via registerCollateral in setUp.
        assertEq(vault.getLTV(address(flr)), 8000, "FLR onboarding LTV must be 8000 bps (80%)");
        // Unregistered token → 0.
        assertEq(vault.getLTV(makeAddr("randomToken")), 0, "unknown collateral must report LTV 0");
    }

    // ═══════════════════ §2 collateralDecimals defaults ═══════════════════

    function test_collateralDecimals_defaultsAfterConstruction() public view {
        assertEq(vault.collateralDecimals(address(fxrp)), 6, "FXRP must report 6 decimals");
        assertEq(vault.collateralDecimals(address(usdt0)), 18, "USDT0 must report 18 decimals");
        assertEq(vault.collateralDecimals(address(flr)), 18, "FLR must report 18 decimals post-register");
    }

    // ═══════════════════ §3 registerCollateral ═══════════════════

    function test_registerCollateral_onboardsNewCollateralAndEmits() public {
        address newTok = makeAddr("newCollateral");
        vm.expectEmit(true, false, false, true);
        emit LTVUpdated(newTok, 0, 7000);
        vault.registerCollateral(newTok, 7000, 18);

        assertEq(vault.getLTV(newTok), 7000, "new collateral LTV must be set");
        assertEq(vault.collateralDecimals(newTok), 18, "new collateral decimals must be set");
    }

    function test_registerCollateral_revertsIfNotOwner() public {
        vm.prank(borrower1);
        vm.expectRevert("NotOwner");
        vault.registerCollateral(makeAddr("t"), 7000, 18);
    }

    function test_registerCollateral_revertsOnInvalidLTVOrZeroAddress() public {
        // LTV == 0 → InvalidLTV
        vm.expectRevert(abi.encodeWithSelector(InvalidLTV.selector, uint256(0)));
        vault.registerCollateral(makeAddr("t"), 0, 18);
        // LTV > 10000 → InvalidLTV
        vm.expectRevert(abi.encodeWithSelector(InvalidLTV.selector, uint256(10001)));
        vault.registerCollateral(makeAddr("t"), 10001, 18);
        // Zero token address → ZeroAmount
        vm.expectRevert(ZeroAmount.selector);
        vault.registerCollateral(address(0), 7000, 18);
        // Zero decimals → InvalidLTV (re-uses the selector)
        vm.expectRevert(abi.encodeWithSelector(InvalidLTV.selector, uint256(7000)));
        vault.registerCollateral(makeAddr("t"), 7000, 0);
    }

    // ═══════════════════ §4 updateLTV ═══════════════════

    function test_updateLTV_ownerUpdatesAndEmits() public {
        // FXRP starts at 7500. Lower to 6000 → emit LTVUpdated(fxrp, 7500, 6000).
        vm.expectEmit(true, false, false, true);
        emit LTVUpdated(address(fxrp), 7500, 6000);
        vault.updateLTV(address(fxrp), 6000);

        assertEq(vault.getLTV(address(fxrp)), 6000, "FXRP LTV must be updated to 6000");
    }

    function test_updateLTV_revertsOnOwnershiAndUnknownCollateral() public {
        // Non-owner → NotOwner
        vm.prank(borrower1);
        vm.expectRevert("NotOwner");
        vault.updateLTV(address(fxrp), 6000);

        // LTV == 0 → InvalidLTV
        vm.expectRevert(abi.encodeWithSelector(InvalidLTV.selector, uint256(0)));
        vault.updateLTV(address(fxrp), 0);

        // LTV > 10000 → InvalidLTV
        vm.expectRevert(abi.encodeWithSelector(InvalidLTV.selector, uint256(10001)));
        vault.updateLTV(address(fxrp), 10001);

        // Unknown collateral → UnknownCollateral
        address unknown = makeAddr("unknownCollateral");
        vm.expectRevert(abi.encodeWithSelector(UnknownCollateral.selector, unknown));
        vault.updateLTV(unknown, 6000);
    }

    // ═══════════════════ §5 getMaxLoanAmount ═══════════════════

    function test_getMaxLoanAmount_ratioBoundIsBindingAtDefaultLTV() public {
        // With FXRP LTV = 7500 (75%), ltvBound (187.5e18) > ratioBound (166.66e18),
        // so the 150% collateralisation floor is the binding constraint. This
        // pins backward-compat with the existing 15000-ratio draw tests.
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        uint256 max = vault.getMaxLoanAmount{value: 0}(loanId);
        assertEq(max, EXPECTED_RATIO_BOUND, "ratio bound (150% floor) must bind at default LTV");
        // Sanity: it's strictly less than the LTV-only bound.
        assertLt(max, EXPECTED_LTV_BOUND_7500, "ratio bound must be < LTV bound when floor binds");
    }

    function test_getMaxLoanAmount_ltvBoundBecomesBindingWhenTightened() public {
        // Lower FXRP LTV to 6000 (60%) → ltvBound = 150e18 < ratioBound = 166.66e18,
        // so the LTV cap is now the binding constraint.
        vault.updateLTV(address(fxrp), 6000);

        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);

        uint256 max = vault.getMaxLoanAmount{value: 0}(loanId);
        assertEq(max, EXPECTED_LTV_BOUND_6000, "LTV bound must bind when tightened to 60%");
        assertLt(max, EXPECTED_RATIO_BOUND, "LTV-bound must be < ratio-bound when LTV is tighter");
    }

    function test_getMaxLoanAmount_zeroForNoCollateralAndZeroFeed() public {
        // Non-existent loan id (no collateral) → 0.
        assertEq(vault.getMaxLoanAmount{value: 0}(999), 0, "non-existent loan must yield 0");

        // A loan with collateral but a dead FTSO feed → 0.
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        ftso.setValueInWei(0, uint64(block.timestamp));
        assertEq(vault.getMaxLoanAmount{value: 0}(loanId), 0, "dead feed must yield 0");
    }

    // ═══════════════════ §6 drawLoan respects the LTV cap ═══════════════════

    function test_drawLoan_respectsTightenedLTVCap() public {
        // Tighten FXRP LTV to 6000 (60%): ltvBound = 150e18, ratioBound = 166.66e18.
        vault.updateLTV(address(fxrp), 6000);

        uint256 loanId = _setupToEligible();

        // Borrowing 160e18 — passes the 150% ratio floor (since 2.5e24 >= 2.4e24)
        // but EXCEEDS the new 60% LTV cap (150e18 < 160e18). Must revert via the
        // LTV branch of InsufficientCollateral (subagent #55's new check).
        // LTV branch check: `collateralUsd18 * ltv < loanUsd18 * 10000`
        //   → (250e18 * 6000) < (160e18 * 10000)
        //   → 1_500_000e18 < 1_600_000e18   → TRUE → revert.
        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientCollateral.selector,
                uint256(250e18) * 6000,           // collateralUsd18 * ltv
                uint256(LOAN_160_USDT) * 10000     // loanUsd18 * 10000
            )
        );
        vault.drawLoan{value: 0}(loanId, LOAN_160_USDT);

        // Borrowing exactly at the cap (150e18) must succeed — boundary check.
        // Re-setup a fresh eligible loan (the previous draw reverted, so the loan
        // is still ELIGIBLE; but drawLoan reverts atomically so state is intact —
        // reusing the same loanId saves us re-running the full harness).
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanId, LOAN_150_USDT); // 150e18 <= ltvBound 150e18 → OK

        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.FUNDED), "loan at the LTV boundary must fund");
        assertEq(loan.loanAmount, LOAN_150_USDT, "loan principal must equal the drawn amount");
    }
}
