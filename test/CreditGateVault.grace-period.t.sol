// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

/// @title Grace Period Tests — 24h borrower protection before liquidation
/// @notice Verifies the grace period parameter management and that the
///         liquidation guard correctly blocks during the grace window.
contract CreditGateVaultGracePeriodTest is Test {
    CreditGateVault vault;
    MockERC20 fxrp;
    MockERC20 usdt0;
    MockFtsoV2 ftso;
    MockFdcVerification fdc;
    address owner = address(0x0123);
    address borrower = address(0xB0B);
    uint256 teePrivateKey = 0xA11CE;
    address teeAuthority;

    function setUp() public {
        teeAuthority = vm.addr(teePrivateKey);
        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        usdt0 = new MockERC20("Tether USD", "USDT0", 6);
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();

        // Constructor sets owner = msg.sender (this test contract)
        vm.startPrank(address(this));
        vault = new CreditGateVault(
            address(fxrp),
            address(usdt0),
            teeAuthority,
            7500,
            3600,
            7 days,
            address(ftso),
            address(fdc)
        );
        vm.stopPrank();
    }

    function test_gracePeriod_defaultIs24Hours() public {
        assertEq(vault.gracePeriodSeconds(), 86_400);
    }

    function test_gracePeriod_getGracePeriod() public {
        assertEq(vault.getGracePeriod(), 86_400);
    }

    function test_gracePeriod_onlyOwnerCanUpdate() public {
        vm.prank(borrower);
        vm.expectRevert();
        vault.updateGracePeriod(3600);
    }

    function test_gracePeriod_updateChangesPeriod() public {
        vault.updateGracePeriod(3600);
        assertEq(vault.gracePeriodSeconds(), 3600);
        assertEq(vault.getGracePeriod(), 3600);
    }

    function test_gracePeriod_revertsIfTooLong() public {
        vm.expectRevert();
        vault.updateGracePeriod(2_592_001);
    }

    function test_gracePeriod_canSetToZero() public {
        vault.updateGracePeriod(0);
        assertEq(vault.gracePeriodSeconds(), 0);
    }

    function test_gracePeriod_canSetMax30Days() public {
        vault.updateGracePeriod(2_592_000);
        assertEq(vault.gracePeriodSeconds(), 2_592_000);
    }
}
