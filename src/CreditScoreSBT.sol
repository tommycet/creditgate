// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CreditScoreSBT — Soulbound Credit Score Token
/// @notice Non-transferable ERC721 that represents a borrower's on-chain credit
///         score in the CreditGate protocol. Minted (or updated) by the
///         {CreditGateVault} whenever a borrower closes a loan via a verified FDC
///         repayment proof — the "credit passport" that is portable across Flare
///         dApps but locked to the borrower's address forever.
/// @dev    Soulbound pattern: the OZ ERC721 `_update` hook is overridden so that
///         every transfer where BOTH `from` and `to` are non-zero reverts. Only
///         minting (`from == address(0)`) and burning (`to == address(0)`) are
///         permitted. The vault (msg.sender at construction time) is the sole
///         minter/updater — see `mintOrUpdate`. Added by subagent #98.
contract CreditScoreSBT is ERC721 {
    // ═══════════════════ Structs ═══════════════════

    /// @notice Snapshot of a borrower's credit history at the time the SBT was
    ///         last updated. Mirrors the per-borrower reputation tracked by the
    ///         vault, plus a derived 0-100 score and a last-updated timestamp.
    struct ScoreData {
        uint256 score;           // 0-100 credit score
        uint256 loansCompleted;  // count of loans closed via repayment
        uint256 loansDefaulted;  // count of loans liquidated/auctioned
        uint256 totalBorrowed;   // cumulative USDT0 drawn (18dp)
        uint256 totalRepaid;     // cumulative USDT0 repaid (principal, 18dp)
        uint256 lastUpdated;     // block.timestamp of last update
    }

    // ═══════════════════ Storage ═══════════════════

    /// @notice reverse-lookup: a borrower's single soulbound token id (0 = none).
    ///         One borrower → at most one SBT (mint-on-first-repayment, update thereafter).
    mapping(address => uint256) public addressToTokenId;

    /// @notice per-token score data, keyed by token id.
    mapping(uint256 => ScoreData) public tokenScores;

    uint256 private _nextTokenId = 1;

    /// @notice The only address allowed to call `mintOrUpdate`. Set at construction
    ///         to msg.sender, i.e. the {CreditGateVault} that deploys this SBT.
    ///         Non-updatable: the vault linkage is immutable by design (the score
    ///         is only ever written by the protocol that earned it).
    address public vault;

    // ═══════════════════ Custom Errors ═══════════════════

    /// @dev Reverts when a non-vault caller attempts `mintOrUpdate`. SBTs must
    ///      only be written by the protocol's own vault — no third-party minting.
    error NotVault(address caller, address vault);
    /// @dev Reverts on attempted transfer of a soulbound token. Only mint
    ///      (from == 0) and burn (to == 0) are permitted; every other movement
    ///      is a regular transfer that this contract deliberately blocks.
    error SoulboundTransferBlocked(address from, address to);

    // ═══════════════════ Constructor ═══════════════════

    /// @notice Deploy the SBT contract. The deployer (a {CreditGateVault}) becomes
    ///         the sole authorized minter/updater.
    constructor() ERC721("CreditGate Credit Score", "CGSCORE") {
        vault = msg.sender;
    }

    // ═══════════════════ Mint / Update ═══════════════════

    /// @notice Mint a fresh credit-score SBT for `borrower`, or update the score
    ///         data on their existing one. Idempotent: subsequent calls refresh
    ///         the score fields in place without minting a second token.
    /// @dev   Vault-only. Reverts if called by any other address. Score fields are
    ///        stored verbatim (the vault computes the derived score so the SBT
    ///        stays a dumb ledger — no business logic duplication).
    /// @param borrower     The wallet owning the SBT (and the loan history).
    /// @param score        0-100 credit score (computed by the vault).
    /// @param completed    Number of loans the borrower completed via repayment.
    /// @param defaulted    Number of loans the borrower had liquidated.
    /// @param borrowed     Cumulative USDT0 borrowed across all loans (18dp).
    /// @param repaid       Cumulative USDT0 repaid (principal, 18dp).
    function mintOrUpdate(
        address borrower,
        uint256 score,
        uint256 completed,
        uint256 defaulted,
        uint256 borrowed,
        uint256 repaid
    ) external {
        if (msg.sender != vault) revert NotVault(msg.sender, vault);

        uint256 tokenId = addressToTokenId[borrower];
        if (tokenId == 0) {
            // First repayment → mint the soulbound passport.
            tokenId = _nextTokenId++;
            addressToTokenId[borrower] = tokenId;
            _mint(borrower, tokenId);
        }

        tokenScores[tokenId] = ScoreData({
            score: score,
            loansCompleted: completed,
            loansDefaulted: defaulted,
            totalBorrowed: borrowed,
            totalRepaid: repaid,
            lastUpdated: block.timestamp
        });
    }

    // ═══════════════════ Soulbound Lock ═══════════════════

    /// @dev ERC721 `_update` override — the soulbound mechanism. Minting
    ///      (`from == address(0)`) and burning (`to == address(0)`) are allowed;
    ///      every move between two live addresses (`from != 0 && to != 0`) reverts
    ///      with {SoulboundTransferBlocked}. This blocks `transferFrom`,
    ///      `safeTransferFrom`, and any other path that reaches `_update`.
    ///      The OZ parent performs the actual owner/approval/balance bookkeeping
    ///      via the `super._update` call, so we let it run after the guard passes.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        // Soulbound: block any move that is NOT a mint and NOT a burn.
        if (from != address(0) && to != address(0)) {
            revert SoulboundTransferBlocked(from, to);
        }
        return super._update(to, tokenId, auth);
    }

    // ═══════════════════ Views ═══════════════════

    /// @notice Read a borrower's credit score data in one call. Returns
    ///         all-zero fields if the borrower has no SBT yet.
    /// @return score        0-100 credit score.
    /// @return completed   loans closed via repayment.
    /// @return defaulted    loans liquidated/auctioned.
    /// @return borrowed    cumulative USDT0 borrowed (18dp).
    /// @return repaid       cumulative USDT0 repaid (principal, 18dp).
    /// @return lastUpdated  block.timestamp of the most recent update.
    function getScore(address borrower)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        uint256 tokenId = addressToTokenId[borrower];
        if (tokenId == 0) {
            return (0, 0, 0, 0, 0, 0);
        }
        ScoreData memory s = tokenScores[tokenId];
        return (s.score, s.loansCompleted, s.loansDefaulted, s.totalBorrowed, s.totalRepaid, s.lastUpdated);
    }

    /// @notice Returns the per-token credit score (convenience accessor).
    function scoreOf(uint256 tokenId) external view returns (uint256) {
        return tokenScores[tokenId].score;
    }

    /// @notice ERC721 metadata — returns a `data:` URI with a JSON payload
    ///         describing the credit score data for `tokenId`. Lets marketplaces
    ///         and explorers render the SBT as an on-chain credit badge without
    ///         any off-chain metadata service.
    /// @dev    Base64 is intentionally avoided to keep the contract dependency-free;
    ///        the JSON is emitted as a `data:application/json;utf8,<json>` URI, which
    ///        most explorers (OpenSea, Etherscan) accept for raw-text metadata.
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(_ownerOf(tokenId) != address(0), "NonexistentToken");
        ScoreData memory s = tokenScores[tokenId];

        // Build the JSON in stages with string.concat (avoids the EVM stack-too-deep
        // error that an oversized abi.encodePacked argument list would trigger).
        string memory header = string.concat(
            "data:application/json;utf8,{",
            "\"name\":\"CreditGate Credit Score #",
            Strings.toString(tokenId),
            "\",\"description\":\"Non-transferable on-chain credit badge earned through verified repayment history.\",\"attributes\":["
        );

        string memory attrs = string.concat(
            _trait("score", s.score),
            _trait("loansCompleted", s.loansCompleted),
            _trait("loansDefaulted", s.loansDefaulted),
            _trait("totalBorrowed", s.totalBorrowed),
            _trait("totalRepaid", s.totalRepaid)
        );

        // lastUpdated handled separately — last array element: no trailing comma.
        string memory tail = string.concat(
            "{\"trait_type\":\"lastUpdated\",\"value\":",
            Strings.toString(s.lastUpdated),
            "}]}"
        );

        return string.concat(header, attrs, tail);
    }

    /// @dev Helper for `tokenURI` — emits a single JSON attribute object with a
    ///      trailing comma. Not used for the LAST attribute of the array.
    function _trait(string memory traitType, uint256 value)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "{\"trait_type\":\"",
            traitType,
            "\",\"value\":",
            Strings.toString(value),
            "},"
        );
    }
}
