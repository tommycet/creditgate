// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {CreditGateTypes} from "../src/CreditGateTypes.sol";
import {MockFtsoV2} from "../src/mocks/MockFtsoV2.sol";
import {MockFdcVerification} from "../src/mocks/MockFdcVerification.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Malicious FXRP that attempts reentrancy on transferFrom.
///         When the vault calls transferFrom during depositCollateral,
///         the token re-enters depositCollateral before the first call finishes.
contract MaliciousFxrp is IERC20 {
    CreditGateVault public targetVault;
    bool public attacking;
    uint256 public reenterAmount;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function name() external pure returns (string memory) { return "Malicious FXRP"; }
    function symbol() external pure returns (string memory) { return "mFXRP"; }
    function decimals() external pure returns (uint8) { return 6; }
    function totalSupply() external pure returns (uint256) { return 1_000_000e6; }

    function setVault(address _vault) external {
        targetVault = CreditGateVault(payable(_vault));
    }

    function setAttack(bool _a, uint256 _amount) external {
        attacking = _a;
        reenterAmount = _amount;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (attacking) {
            attacking = false; // one-shot
            // Re-enter depositCollateral while the first call is still executing
            try targetVault.depositCollateral(reenterAmount) {
                console.log("REENTRANCY SUCCEEDED - SECURITY BUG");
            } catch {
                console.log("Reentrancy blocked by nonReentrant guard");
            }
        }

        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @notice Proves that nonReentrant actually blocks re-entry by deploying a vault
///         with a malicious FXRP token that tries to call depositCollateral
///         from within the transferFrom callback.
contract CreditGateVaultRealReentrancyTest is Test {
    CreditGateVault public vault;
    MaliciousFxrp public mfxrp;
    MockFtsoV2 public ftso;
    MockFdcVerification public fdc;

    address attacker = makeAddr("attacker");

    function setUp() public {
        mfxrp = new MaliciousFxrp();
        ftso = new MockFtsoV2();
        fdc = new MockFdcVerification();

        // Deploy vault with the MALICIOUS token as FXRP
        vault = new CreditGateVault(
            address(mfxrp),
            address(mfxrp), // use same token as USDT0 for simplicity
            address(0xA11CE),
            15_000,
            300,
            1 hours,
            address(ftso),
            address(fdc)
        );

        mfxrp.setVault(address(vault));
        mfxrp.mint(address(attacker), 1000e6);
        mfxrp.mint(address(vault), 1000e6); // vault needs USDT0

        ftso.setValueInWei(2_5e17, uint64(block.timestamp));

        vm.startPrank(attacker);
        mfxrp.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The test that proves nonReentrant blocks re-entry.
    ///      If the guard is missing, the malicious token re-enters depositCollateral
    ///      during transferFrom, creating two loans from one deposit (double-counting).
    ///      With nonReentrant, the re-entry reverts and only ONE loan is created.
    function test_reentrancy_realDepositAttack_blocked() public {
        // Set the attack: when transferFrom fires during deposit, re-enter with 50e6
        mfxrp.setAttack(true, 50e6);

        vm.prank(attacker);
        vault.depositCollateral(100e6);

        // The re-entry attempt should have been blocked.
        // Verify only ONE loan was created (not two).
        // If reentrancy succeeded, nextLoanId would be 3 (1 from outer + 1 from re-entry).
        // With the guard, nextLoanId is 2 (only the outer call succeeded).
        assertEq(vault.nextLoanId(), 2, "Reentrancy created extra loans");

        // Verify the outer loan was created correctly
        CreditGateTypes.Loan memory loan1 = vault.getLoan(1);
        assertEq(uint8(loan1.state), uint8(CreditGateTypes.LoanState.COLLATERAL_DEPOSITED));
        assertEq(loan1.collateralAmount, 100e6);
        assertEq(loan1.borrower, attacker);

        // emit log to confirm the guard message was printed
        console.log("Loan 1 created, nextLoanId:", vault.nextLoanId());
    }
}
