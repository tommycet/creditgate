// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {CreditScoreSBT} from "../src/CreditScoreSBT.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";
import {IXRPPayment} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title CreditScoreSBT.t.sol — Soulbound credit score token tests
/// @dev subagent #98. Non-transferable ERC721 minted by the vault on first
///      repayment proof and updated on each subsequent close. Seven scenarios
///      covering mint, update, soulbound-lock, score math, vault-only minting,
///      the `getScore` view, and the `tokenURI` data URI.
contract CreditScoreSBTTest is Test, CreditGateTypes {
    CreditGateVault public vault;
    CreditScoreSBT public sbt;

    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    // Test accounts
    address public owner = address(this);
    address public borrower1 = makeAddr("borrower1");
    address public other = makeAddr("other");

    // TEE authority key pair
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Config constants (mirrors the reputation suite)
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
        sbt = vault.creditScoreSBT();

        fxrp.mint(borrower1, 1_000e6);
        usdt0.mint(address(vault), 10_000e18);

        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        vm.prank(borrower1);
        fxrp.approve(address(vault), type(uint256).max);

        vm.prank(borrower1);
        vault.registerXRPLAddress(keccak256("rCreditGateBorrower1"));
    }

    // ═══════════════════ Helpers ═══════════════════

    /// @notice Sign an eligibility attestation as the TEE authority. Mirrors the
    ///         exact payload-hash computation done on-chain by `submitEligibility`.
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

    /// @notice Drive a loan slot from deposit to ELIGIBLE so it's ready to draw.
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

    /// @notice Build a passing FDC XRPPayment proof matching the loan's commitment,
    ///         receiver hash and required drops. Mirrors `_buildProof` in the
    ///         reputation suite.
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

    /// @notice Full lifecycle: draw a loan then repay it. Returns the loanId.
    function _drawAndRepay() internal returns (uint256 loanId) {
        loanId = _setupLoanToEligible();

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
    }

    // ═══════════════════ CREDIT SCORE SBT TESTS ═══════════════════

    /// @notice Closing the first loan mints a soulbound credit-score SBT to the
    ///         borrower with token id 1 and the right score/history fields.
    function test_sbt_mintsOnFirstRepayment() public {
        // Pre-condition: borrower has no SBT.
        assertEq(sbt.addressToTokenId(borrower1), 0, "no SBT before first repayment");

        uint256 loanId = _drawAndRepay();

        // First mint → token id 1, owned by the borrower.
        assertEq(sbt.balanceOf(borrower1), 1, "borrower must own 1 SBT after first repay");
        assertEq(sbt.ownerOf(1), borrower1, "SBT token id must be 1");
        assertEq(sbt.addressToTokenId(borrower1), 1, "addressToTokenId must point to 1");

        // Score fields. After one loan: completed=1, defaulted=0, borrowed=100e18,
        // repaid=100e18. Score = 50 + 1*10 - 0*25 + (100e18*20/100e18) = 50+10+20 = 80.
        (
            uint256 score,
            uint256 completed,
            uint256 defaulted,
            uint256 borrowed,
            uint256 repaid,
            uint256 lastUpdated
        ) = sbt.getScore(borrower1);
        assertEq(score, 80, "score after single repay (50+10+20)");
        assertEq(completed, 1, "loansCompleted after single repay");
        assertEq(defaulted, 0, "loansDefaulted after single repay");
        assertEq(borrowed, LOAN_100_USDT, "totalBorrowed after single repay");
        assertEq(repaid, LOAN_100_USDT, "totalRepaid after single repay");
        assertEq(lastUpdated, block.timestamp, "lastUpdated == block.timestamp");
        assertGt(lastUpdated, 0, "lastUpdated is non-zero");
    }

    /// @notice A second repayment updates the existing SBT in place (no new mint)
    ///         and improves the score: more completed loans → higher score.
    function test_sbt_updatesOnSecondRepayment() public {
        // First lifecycle: mint + score 80.
        _drawAndRepay();

        assertEq(sbt.balanceOf(borrower1), 1, "still one SBT after first repay");
        (uint256 scoreAfter1,,,,,) = sbt.getScore(borrower1);
        assertEq(scoreAfter1, 80, "score after first repay must be 80");

        // Second lifecycle: draw + repay another loan — must UPDATE, not mint.
        uint256 secondLoanId = _drawAndRepay();

        assertEq(sbt.balanceOf(borrower1), 1, "still one SBT after second repay (no dup mint)");
        assertEq(sbt.addressToTokenId(borrower1), 1, "tokenId unchanged on update");

        // completed=2, defaults=0, borrowed=200e18, repaid=200e18.
        // score = 50 + 2*10 + (200e18*20/200e18) = 50+20+20 = 90.
        (uint256 score, uint256 completed, uint256 defaulted, uint256 borrowed, uint256 repaid,) =
            sbt.getScore(borrower1);
        assertEq(completed, 2, "loansCompleted after two repays");
        assertEq(defaulted, 0, "no defaults after two clean repays");
        assertEq(borrowed, 2 * LOAN_100_USDT, "totalBorrowed accumulates across loans");
        assertEq(repaid, 2 * LOAN_100_USDT, "totalRepaid accumulates across loans");
        assertEq(score, 90, "score after two repays must improve to 90");
        assertGt(score, scoreAfter1, "score must strictly increase after second clean repay");
    }

    /// @notice The SBT cannot be transferred — every move from a real owner to a
    ///         real address reverts with `SoulboundTransferBlocked`. Verifies the
    ///         `_update` override's soulbound guard on ERC721 transfers.
    function test_sbt_cannotBeTransferred() public {
        uint256 loanId = _drawAndRepay();

        assertEq(sbt.ownerOf(1), borrower1, "borrower owns SBT pre-transfer");

        // Owner-approved transferFrom attempt: blocked.
        vm.prank(borrower1);
        sbt.approve(other, 1);
        assertEq(sbt.getApproved(1), other, "other is approved pre-transfer");

        // Attempt transferFrom → revert (soulbound).
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditScoreSBT.SoulboundTransferBlocked.selector,
                borrower1,
                other
            )
        );
        sbt.transferFrom(borrower1, other, 1);

        // Attempt safeTransferFrom → also blocked.
        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditScoreSBT.SoulboundTransferBlocked.selector,
                borrower1,
                other
            )
        );
        sbt.safeTransferFrom(borrower1, other, 1);

        // Owner is unchanged after failed transfers.
        assertEq(sbt.ownerOf(1), borrower1, "ownership unchanged after failed transfers");
    }

    /// @notice The on-chain score reflects the reputation math exactly:
    ///         50 base + completed*10 - defaulted*25 + (repaid*20/borrowed),
    ///         clamped to [0, 100]. After 1 repayment the score is exactly 80.
    ///         Drives an additional default case to exercise the -25 + clamp path.
    function test_sbt_scoreReflectsHistory() public {
        // ── Clean repay: score = 80 (50 + 1*10 + 20) ──
        uint256 loanA = _drawAndRepay();
        (uint256 score1,,,,,) = sbt.getScore(borrower1);
        assertEq(score1, 80, "score after 1 clean repay (50+10+20)");

        // ── Second loan: drawn, then defaulted via deadline liquidation ──
        uint256 loanB = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanB, LOAN_100_USDT);
        CreditGateTypes.Loan memory loanBStored = vault.getLoan(loanB);
        vm.warp(loanBStored.deadline + 86_401);
        vault.liquidate(loanB);

        // ── The default does NOT call the SBT path (only `_startLiquidation` does not
        //    update an SBT — design: SBT only updates on close/repayment). So we
        //    need another REPAYMENT to trigger a score refresh that incorporates
        //    the new defaulted count.

        // Refresh the FTSO feed to the current warped timestamp — `vm.warp` above
        // moved forward past the loan deadline (7 days), which would make any FTSO
        // read fail the staleness check (feed timestamp is 7+ days old). Re-tick the
        // mock feed so the upcoming drawLoan call succeeds.
        ftso.setValueInWei(XRP_PRICE_2_50, uint64(block.timestamp));

        uint256 loanC = _setupLoanToEligible();
        vm.prank(borrower1);
        vault.drawLoan{value: 0}(loanC, LOAN_100_USDT);
        CreditGateTypes.Loan memory loanCStored = vault.getLoan(loanC);
        bytes32 memoC = loanCStored.expectedCommitment;
        bytes32 receiverC = keccak256("rCreditGateBorrower1");
        fdc.setResult(true);
        IXRPPayment.Proof memory proofC =
            _buildProof(loanCStored.requiredRepaymentDrops, memoC, receiverC);
        vm.prank(borrower1);
        vault.submitRepaymentProof(loanC, proofC);

        // After repay: completed=2, defaulted=1, borrowed=300e18, repaid=200e18.
        // score = 50 + 2*10 - 1*25 + (200e18*20 / 300e18) = 50+20-25 + (13.33→13) = 45+13 = 58.
        // Float division floors: 200e18*20 = 4000e18; /300e18 = 13 (in integer math).
        (uint256 score2, uint256 completed, uint256 defaulted, uint256 borrowed, uint256 repaid,) =
            sbt.getScore(borrower1);
        assertEq(completed, 2, "completed=2 after second close");
        assertEq(defaulted, 1, "defaulted=1 after liquidation");
        assertEq(borrowed, 3 * LOAN_100_USDT, "totalBorrowed accumulates across draws");
        assertEq(repaid, 2 * LOAN_100_USDT, "totalRepaid only counts principal of repaid loans");
        // Expected score: 50 + 20 - 25 + (4000e18/300e18) = 45 + 13 = 58.
        assertEq(score2, 58, "score with 2 completed + 1 defaulted (50+20-25+13)");
    }

    /// @notice Only the vault (msg.sender at SBT deployment) can mint or update.
    ///         Any other caller — even the borrower themselves — reverts with
    ///         `NotVault`. Proves the protocol-link coupling is enforced on-chain.
    function test_sbt_onlyVaultCanMint() public {
        // Borrower directly attempting to mint their own SBT.
        vm.prank(borrower1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditScoreSBT.NotVault.selector,
                borrower1,
                address(vault)
            )
        );
        sbt.mintOrUpdate(borrower1, 99, 5, 0, 1000e18, 1000e18);

        // Random third party minting.
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                CreditScoreSBT.NotVault.selector,
                other,
                address(vault)
            )
        );
        sbt.mintOrUpdate(other, 99, 5, 0, 1000e18, 1000e18);

        // Sanity: the vault address recorded in the SBT IS the vault.
        assertEq(sbt.vault(), address(vault), "SBT vault address matches the vault");
    }

    /// @notice `getScore(address)` returns all six fields coherently, including
    ///         the last-updated timestamp. For a wallet with no SBT yet, returns
    ///         all-zeros (no revert). After a repayment, matches the on-chain state.
    function test_sbt_getScore() public {
        // Pre-mint: returns all zeros (graceful — no revert).
        (
            uint256 score0,
            uint256 completed0,
            uint256 defaulted0,
            uint256 borrowed0,
            uint256 repaid0,
            uint256 lastUpdated0
        ) = sbt.getScore(borrower1);
        assertEq(score0, 0, "no SBT: score=0");
        assertEq(completed0, 0, "no SBT: completed=0");
        assertEq(defaulted0, 0, "no SBT: defaulted=0");
        assertEq(borrowed0, 0, "no SBT: borrowed=0");
        assertEq(repaid0, 0, "no SBT: repaid=0");
        assertEq(lastUpdated0, 0, "no SBT: lastUpdated=0");

        // Drive one repayment.
        _drawAndRepay();

        // Post-mint: all six fields reflect the close.
        (
            uint256 score,
            uint256 completed,
            uint256 defaulted,
            uint256 borrowed,
            uint256 repaid,
            uint256 lastUpdated
        ) = sbt.getScore(borrower1);
        assertEq(score, 80, "score=80 (50+10+20)");
        assertEq(completed, 1, "completed=1");
        assertEq(defaulted, 0, "defaulted=0");
        assertEq(borrowed, LOAN_100_USDT, "borrowed=1*LOAN_100_USDT");
        assertEq(repaid, LOAN_100_USDT, "repaid=1*LOAN_100_USDT");
        assertEq(lastUpdated, block.timestamp, "lastUpdated=block.timestamp");

        // Cross-check against the public mapping getter.
        (
            uint256 mScore,
            uint256 mCompleted,
            uint256 mDefaulted,
            uint256 mBorrowed,
            uint256 mRepaid,
            uint256 mLastUpdated
        ) = sbt.tokenScores(1);
        assertEq(mScore, score, "mapping == view: score");
        assertEq(mCompleted, completed, "mapping == view: completed");
        assertEq(mDefaulted, defaulted, "mapping == view: defaulted");
        assertEq(mBorrowed, borrowed, "mapping == view: borrowed");
        assertEq(mRepaid, repaid, "mapping == view: repaid");
        assertEq(mLastUpdated, lastUpdated, "mapping == view: lastUpdated");
    }

    /// @notice `tokenURI(tokenId)` returns a `data:application/json;utf8,...`
    ///         URI containing valid JSON with all credit-score attributes. Must
    ///         revert for non-existent tokens. Verifies the ERC721 metadata hook
    ///         exposes the SBT to explorers/marketplaces without off-chain services.
    function test_sbt_tokenURI() public {
        uint256 loanId = _drawAndRepay();

        // Token URI for an existing token returns a valid data URI with JSON payload.
        string memory uri = sbt.tokenURI(1);

        // Header check: must start with a `data:application/json;utf8,` URI scheme.
        // Slicing 27 chars gives exactly that prefix (verified length).
        assertEq(
            sliceStr(uri, 0, 27),
            "data:application/json;utf8,",
            "URI must start with data:application/json;utf8,"
        );

        // The name attribute is embedded; verify it's present.
        assertContains(uri, "\"name\":\"CreditGate Credit Score #1\"", "name attribute present");
        // The score value (80) must appear as a quoted value in the JSON.
        assertContains(uri, "\"value\":80", "score value=80 present in JSON");
        // The loansCompleted trait must use the canonical trait_type key.
        assertContains(uri, "\"trait_type\":\"loansCompleted\"", "canonical trait_type key");
        // The completed attribute value (1) appears as a JSON numeric token.
        assertContains(uri, "\"value\":1", "completed count=1 present");
        // The description string is the protocol's official credit-badge copy.
        assertContains(
            uri,
            "Non-transferable on-chain credit badge",
            "description copy is present in the JSON"
        );

        // tokenURI for a non-existent token must revert.
        vm.expectRevert("NonexistentToken");
        sbt.tokenURI(999);
    }

    /// @notice tokenURI must also revert for tokens that were never minted at all
    ///         (defensive: `_ownerOf` returns 0 → revert). Anchors the edge case.
    function test_sbt_tokenURI_revertsForUnminted() public {
        vm.expectRevert("NonexistentToken");
        sbt.tokenURI(1);
    }

    /// @notice The SBT's ERC-721 metadata interface (name, symbol) reflects the
    ///         protocol identity. Sanity bedrock for any explorer integration.
    function test_sbt_metadata() public {
        assertEq(sbt.name(), "CreditGate Credit Score", "SBT name");
        assertEq(sbt.symbol(), "CGSCORE", "SBT symbol");
    }

    // ═══════════════════ String helpers ═══════════════════
    // (Tiny inline helpers — Foundry/Vm doesn't ship a substring primitive.)

    /// @dev Returns the first `len` bytes of `s` (Forge strings are bytes).
    function sliceStr(string memory s, uint256 start, uint256 end)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(s);
        require(end <= b.length && start <= end, "sliceStr: OOB");
        // tiny slip: ensure `end - start` fits the slice buffer we allocate
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = b[i];
        }
        return string(out);
    }

    /// @dev Asserts that `haystack` contains `needle` as a substring.
    function assertContains(string memory haystack, string memory needle, string memory err)
        internal
    {
        bytes memory hb = bytes(haystack);
        bytes memory nb = bytes(needle);
        require(nb.length <= hb.length, "assertContains: needle longer than haystack");
        bool found = false;
        for (uint256 i = 0; i + nb.length <= hb.length && !found; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < nb.length; j++) {
                if (hb[i + j] != nb[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) found = true;
        }
        if (!found) {
            emit log_named_string("assertContains FAILED", err);
            emit log_named_string("   haystack", haystack);
            emit log_named_string("   needle", needle);
            fail(err);
        }
    }

    /// @dev Local alias for Strings.toString — kept as a test-helper to avoid
    ///      pulling the OZ Strings module's full type via the test's import list.
    function Strings_toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
