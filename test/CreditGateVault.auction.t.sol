// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVaultAuctionTest — Dutch auction liquidation tests
/// @dev 5 tests for startLiquidationAuction / bidOnLiquidation / finalizeAuction /
///      getAuctionPrice. Follows the setUp + fund-a-loan pattern from
///      CreditGateVault.t.sol and CreditGateVault.edge-cases.t.sol.
contract CreditGateVaultAuctionTest is Test, CreditGateTypes {
    CreditGateVault public vault;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public bidder = makeAddr("bidder");

    // TEE authority key pair for signing attestations
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config constants — match main suite
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300; // 5 minutes
    uint256 constant LOAN_DURATION = 7 days;

    // XRP price $2.50 (18dp)
    uint256 constant XRP_PRICE_2_50 = 2.5e18;

    // FXRP (6dp) / USDT0 (18dp on Coston2) amounts
    uint256 constant DEPOSIT_100_FXRP = 100e6;
    uint256 constant LOAN_100_USDT = 100e18;
    uint256 constant LOAN_150_USDT = 150e18;

    // Expected auction start price for 100 FXRP @ $2.50:
    //   (100e6 * 1e12 * 2.5e18) / 1e18 = 2.5e20 = 250e18 USDT0
    uint256 constant EXPECTED_START_PRICE = 250e18;

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
        usdt0.mint(address(vault), 10_000e18); // vault disburses loans in USDT0
        usdt0.mint(bidder, 1_000e18); // bidder needs USDT0 to bid

        // Set FTSO price
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        // Approve vault to spend borrower FXRP
        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);
        // Approve vault to spend bidder USDT0 (for bidOnLiquidation transferFrom)
        vm.prank(bidder);
        usdt0.approve(address(vault), type(uint256).max);

        // Register XRPL address for borrower1
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

    /// @dev Drive a loan all the way to FUNDED so the auction can be started.
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
    ///      doesn't trip after a vm.warp. startLiquidationAuction reads the feed.
    function _refreshFtso() internal {
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));
    }

    // ═══════════════════ TEST 1: startLiquidationAuction succeeds when loan expired ═══════════════════

    function test_startLiquidationAuction_succeedsWhenLoanExpired() public {
        uint256 loanId = _setupLoanToFunded();

        // Warp past the loan deadline (LOAN_DURATION after draw).
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        // FTSO feed timestamp is now stale; refresh it so the auction starter
        // doesn't hit FTSOPriceStale.
        _refreshFtso();

        uint64 auctionStart = uint64(block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit LiquidationAuctionStarted(loanId, borrower1, EXPECTED_START_PRICE, auctionStart);

        // Anyone can start the auction. The function is payable (FTSO read).
        vm.prank(bidder);
        vault.startLiquidationAuction{value: 0}(loanId);

        // Loan state must transition to AUCTION.
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.AUCTION));

        // Auction struct must be initialized correctly.
        (
            uint256 aucStartPrice,
            uint64 aucStartTimestamp,
            address aucHighestBidder,
            uint256 aucHighestBid
        ) = vault.auctions(loanId);
        assertEq(aucStartPrice, EXPECTED_START_PRICE);
        assertEq(aucStartTimestamp, auctionStart);
        assertEq(aucHighestBidder, address(0));
        assertEq(aucHighestBid, 0);

        // getAuctionPrice at t=0 (elapsed 0) must equal the full start price.
        assertEq(vault.getAuctionPrice(loanId), EXPECTED_START_PRICE);
    }

    // ═══════════════════ TEST 2: startLiquidationAuction reverts if loan not FUNDED ═══════════════════
    //
    // The contract guard is `if (loan.state != LoanState.FUNDED) revert NotInAuctionState()`.
    // We deposit collateral only (state == COLLATERAL_DEPOSITED) and try to start an
    // auction — must revert. (A never-funded loan also has deadline == 0, but the
    // state check fires first.)

    function test_startLiquidationAuction_revertsIfLoanNotFunded() public {
        vm.prank(borrower1);
        uint256 loanId = vault.depositCollateral(DEPOSIT_100_FXRP);
        // state is now COLLATERAL_DEPOSITED, never funded.

        vm.expectRevert(CreditGateTypes.NotInAuctionState.selector);
        vault.startLiquidationAuction{value: 0}(loanId);
    }

    // ═══════════════════ TEST 3: bidOnLiquidation succeeds ═══════════════════
    //
    // Start an auction, then place a bid at the current price (full startPrice at
    // t=0). Verify the bidder is recorded as highestBidder and USDT0 is pulled in.

    function test_bidOnLiquidation_succeeds() public {
        uint256 loanId = _setupLoanToFunded();
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        _refreshFtso();

        vm.prank(bidder);
        vault.startLiquidationAuction{value: 0}(loanId);

        // Bid exactly the current price (startPrice at t=0, elapsed == 0).
        uint256 bidAmount = vault.getAuctionPrice(loanId);
        assertEq(bidAmount, EXPECTED_START_PRICE); // sanity: no decay yet

        uint256 bidderBalBefore = usdt0.balanceOf(bidder);
        uint256 vaultBalBefore = usdt0.balanceOf(address(vault));

        vm.expectEmit(true, true, false, true);
        emit LiquidationBid(loanId, bidder, bidAmount);

        vm.prank(bidder);
        vault.bidOnLiquidation(loanId, bidAmount);

        // Bidder's USDT0 decreased by the bid; vault's increased by the same.
        assertEq(usdt0.balanceOf(bidder), bidderBalBefore - bidAmount);
        assertEq(usdt0.balanceOf(address(vault)), vaultBalBefore + bidAmount);

        // Auction struct now records the bidder as highest.
        (
            uint256 _startPriceB,
            uint64 _startTsB,
            address _highestBidderB,
            uint256 _highestBidB
        ) = vault.auctions(loanId);
        assertEq(_highestBidderB, bidder);
        assertEq(_highestBidB, bidAmount);
        // startPrice / startTimestamp unchanged — sanity.
        assertEq(_startPriceB, EXPECTED_START_PRICE);
        assertEq(_startTsB, uint64(block.timestamp));

        // Loan is still in AUCTION state (not finalized).
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.AUCTION));
    }

    // ═══════════════════ TEST 4: finalizeAuction with bids ═══════════════════
    //
    // Start auction, place a bid, warp past AUCTION_DURATION, finalize.
    // Winner receives the FXRP collateral; borrower receives the bid excess over
    // the loan amount (bid 250e18 − loan 100e18 = 150e18 USDT0 to borrower).

    function test_finalizeAuction_withBids() public {
        uint256 loanId = _setupLoanToFunded();
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        _refreshFtso();

        vm.prank(bidder);
        vault.startLiquidationAuction{value: 0}(loanId);

        // Bid at full start price.
        uint256 bidAmount = vault.getAuctionPrice(loanId);
        vm.prank(bidder);
        vault.bidOnLiquidation(loanId, bidAmount);

        // Warp past the auction window so finalizeAuction can run.
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        uint256 bidderFxrpBefore = fxrp.balanceOf(bidder);
        uint256 borrowerUsdtBefore = usdt0.balanceOf(borrower1);

        // Anyone can finalize.
        vault.finalizeAuction(loanId);

        // Winner got the FXRP collateral (100e6).
        assertEq(fxrp.balanceOf(bidder), bidderFxrpBefore + DEPOSIT_100_FXRP);

        // Borrower got the bid excess over the loan amount (250e18 − 100e18 = 150e18).
        assertEq(usdt0.balanceOf(borrower1), borrowerUsdtBefore + (bidAmount - LOAN_100_USDT));

        // Loan is CLOSED and collateral cleared.
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.CLOSED));
        assertEq(loan.collateralAmount, 0);

        // Vault no longer holds the FXRP collateral.
        assertEq(fxrp.balanceOf(address(vault)), 0);

        // Auction struct was deleted.
        (
            uint256 _startPriceD1,
            uint64 _startTsD1,
            address _highestBidderD1,
            uint256 _highestBidD1
        ) = vault.auctions(loanId);
        assertEq(_startPriceD1, 0);
        assertEq(_highestBidderD1, address(0));
        assertEq(_highestBidD1, 0);
        assertEq(_startTsD1, 0);
    }

    // ═══════════════════ TEST 5: finalizeAuction with no bids ═══════════════════
    //
    // Start auction, place NO bids, warp past AUCTION_DURATION, finalize.
    // With no bids the collateral falls back to the vault owner.

    function test_finalizeAuction_noBids() public {
        uint256 loanId = _setupLoanToFunded();
        vm.warp(block.timestamp + LOAN_DURATION + 86_401);
        _refreshFtso();

        vm.prank(bidder);
        vault.startLiquidationAuction{value: 0}(loanId);

        // Intentionally place no bids.

        uint256 ownerFxrpBefore = fxrp.balanceOf(owner);

        // Warp past the auction window.
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // getAuctionPrice now returns 0 (elapsed >= AUCTION_DURATION), but we
        // also need auction state to still be AUCTION — bidding is closed, so
        // just finalize.
        assertEq(vault.getAuctionPrice(loanId), 0);

        vault.finalizeAuction(loanId);

        // Owner received the FXRP collateral as fallback.
        assertEq(fxrp.balanceOf(owner), ownerFxrpBefore + DEPOSIT_100_FXRP);

        // Loan is CLOSED and collateral cleared.
        CreditGateTypes.Loan memory loan = vault.getLoan(loanId);
        assertEq(uint8(loan.state), uint8(LoanState.CLOSED));
        assertEq(loan.collateralAmount, 0);

        // Vault no longer holds the FXRP collateral.
        assertEq(fxrp.balanceOf(address(vault)), 0);

        // Auction struct was deleted.
        (
            uint256 _startPriceD2,
            uint64 _startTsD2,
            address _highestBidderD2,
            uint256 _highestBidD2
        ) = vault.auctions(loanId);
        assertEq(_startPriceD2, 0);
        assertEq(_highestBidderD2, address(0));
        assertEq(_highestBidD2, 0);
        assertEq(_startTsD2, 0);
    }
}
