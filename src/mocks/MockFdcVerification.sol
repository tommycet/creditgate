// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IXRPPayment} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";
import {IXRPPaymentVerification} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPaymentVerification.sol";

/// @title MockFdcVerification — Test double for Flare FdcVerification
/// @dev Implements IXRPPaymentVerification.verifyXRPPayment. Returns configurable result.
///      Label: FIXTURE - no live FDC verification.
contract MockFdcVerification is IXRPPaymentVerification {
    bool private _result;

    function setResult(bool result_) external {
        _result = result_;
    }

    function verifyXRPPayment(IXRPPayment.Proof calldata /*_proof*/)
        external
        view
        returns (bool _proved)
    {
        return _result;
    }
}
