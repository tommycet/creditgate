// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";

contract CreditGateVaultOwnershipTest is Test {
    CreditGateVault public vault;
    MockERC20 public fxrp;
    MockERC20 public usdt0;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address owner = address(this);
    address newOwner = address(0xDEAD);

    function setUp() public {
        fxrp = new MockERC20("FlareXRP", "FXRP", 6);
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();

        vault = new CreditGateVault(
            address(fxrp),
            address(usdt0),
            address(0xBEEF), // teeAuthority
            7500,
            3600,
            7 days,
            address(ftso),
            address(fdc)
        );
    }

    function test_transferOwnership_success() public {
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), newOwner);
        // New owner can call onlyOwner functions
        vm.prank(newOwner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_transferOwnership_revertIfZero() public {
        vm.expectRevert("ZeroAddressOwner");
        vault.transferOwnership(address(0));
    }

    function test_transferOwnership_revertIfNotOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("NotOwner");
        vault.transferOwnership(address(0xCAFE));
    }

    function test_oldOwnerCannotCallAfterTransfer() public {
        vault.transferOwnership(newOwner);
        // Old owner (this) can no longer call onlyOwner functions
        vm.expectRevert("NotOwner");
        vault.pause();
    }
}
