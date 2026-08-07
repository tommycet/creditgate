// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title CreditGateVaultRegistryTest — ContractRegistry integration (subagent #100)
/// @dev Replaces the vault's hardcoded FtsoV2 / FdcVerification addresses with
///      dynamic lookups against Flare's on-chain ContractRegistry. Demonstrates
///      deeper Flare ecosystem knowledge: when Flare governance-upgrades those
///      contracts, the owner re-resolves them on the live vault without
///      redeploying (future-proof). Covers:
///        §1 test_registry_updatesFdcVerification
///        §2 test_registry_updatesFtsoV2
///        §3 test_registry_revertsForZeroAddress
///        §4 test_registry_onlyOwnerCanCall
contract CreditGateVaultRegistryTest is Test, CreditGateTypes {
    CreditGateVault public vault;
    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;
    MockContractRegistry public registry;

    address public owner = address(this);
    address public nonOwner = makeAddr("nonOwner");

    // ── Config (mirrors CreditGateVault.ltv.t.sol) ──
    uint256 constant COLLATERAL_RATIO_BPS = 15_000; // 150%
    uint64 constant FTSO_STALENESS_LIMIT = 300;
    uint256 constant LOAN_DURATION = 7 days;
    uint8 constant USDT0_DECIMALS_TEST = 18;
    uint256 internal teePrivateKey = 0xA11CE;
    address public teeAuthority;

    // Synthetic upgraded contract addresses the mock registry will resolve to.
    // `makeAddr` returns deterministic, address(0)-free values.
    address public upgradedFdc;
    address public upgradedFtso;

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);

        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", USDT0_DECIMALS_TEST);
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();
        registry = new MockContractRegistry();

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

        upgradedFdc = makeAddr("upgradedFdc");
        upgradedFtso = makeAddr("upgradedFtso");
        registry.setContract("FdcVerification", upgradedFdc);
        registry.setContract("FlareContractsV2", upgradedFtso);
    }

    // ═══════════════════ §1 FDC update ═══════════════════

    /// @notice updateFdcVerificationFromRegistry re-points fdcVerification at the
    ///         address the registry returns for "FdcVerification" and emits.
    function test_registry_updatesFdcVerification() public {
        // Sanity: starts at the constructor-supplied mock FDC.
        assertEq(address(vault.fdcVerification()), address(fdc), "pre: fdcVerification should be ctor mock");

        vm.expectEmit(true, false, false, true);
        emit FdcVerificationUpdated(upgradedFdc);

        vault.updateFdcVerificationFromRegistry(address(registry));

        assertEq(address(vault.fdcVerification()), upgradedFdc, "post: fdcVerification must be registry-resolved address");
    }

    // ═══════════════════ §2 FtsoV2 update ═══════════════════

    /// @notice updateFtsoV2FromRegistry re-points ftsoV2 at the registry-resolved
    ///         "FlareContractsV2" address (with "FtsoV2" fallback) and emits.
    function test_registry_updatesFtsoV2() public {
        // Sanity: starts at the constructor-supplied mock Ftso.
        assertEq(address(vault.ftsoV2()), address(ftso), "pre: ftsoV2 should be ctor mock");

        vm.expectEmit(true, false, false, true);
        emit FtsoV2Updated(upgradedFtso);

        vault.updateFtsoV2FromRegistry(address(registry));

        assertEq(address(vault.ftsoV2()), upgradedFtso, "post: ftsoV2 must be registry-resolved address");
    }

    // ═══════════════════ §3 Zero-address revert ═══════════════════

    /// @notice If the registry returns address(0) for "FdcVerification", the vault
    ///         must revert with "Registry returned zero" rather than silently
    ///         storing a zero verifier (which would brick repayment verification).
    function test_registry_revertsForZeroAddress() public {
        // Clear the FDC entry so the mock registry returns address(0).
        registry.setContract("FdcVerification", address(0));
        assertEq(registry.getContractByName("FdcVerification"), address(0), "fixture: registry must return 0");

        vm.expectRevert("Registry returned zero");
        vault.updateFdcVerificationFromRegistry(address(registry));

        // Same guard for the FtsoV2 path: both names unset → address(0) both times.
        registry.setContract("FlareContractsV2", address(0));
        // "FtsoV2" was never set, so the fallback also resolves to address(0).
        vm.expectRevert("Registry returned zero");
        vault.updateFtsoV2FromRegistry(address(registry));
    }

    // ═══════════════════ §4 onlyOwner guard ═══════════════════

    /// @notice A non-owner calling either registry function must be rejected by the
    ///         onlyOwner modifier ("NotOwner"), preserving the deployer's exclusive
    ///         control over Flare protocol-contract re-resolution.
    function test_registry_onlyOwnerCanCall() public {
        vm.prank(nonOwner);
        vm.expectRevert("NotOwner");
        vault.updateFdcVerificationFromRegistry(address(registry));

        vm.prank(nonOwner);
        vm.expectRevert("NotOwner");
        vault.updateFtsoV2FromRegistry(address(registry));

        // State must be unchanged after the failed calls.
        assertEq(address(vault.fdcVerification()), address(fdc), "fdcVerification unchanged after non-owner call");
        assertEq(address(vault.ftsoV2()), address(ftso), "ftsoV2 unchanged after non-owner call");
    }
}

/// @title MockContractRegistry — minimal stand-in for Flare's ContractRegistry.
/// @dev Mirrors the on-chain
///      `getContractByName(string) → address` view. Tests populate the
///      `contracts` mapping via `setContract`. Returned addresses of
///      address(0) intentionally exercise the vault's zero-address guard.
contract MockContractRegistry {
    mapping(string => address) public contracts;

    function setContract(string memory name, address addr) public {
        contracts[name] = addr;
    }

    function getContractByName(string memory name) public view returns (address) {
        return contracts[name];
    }
}
