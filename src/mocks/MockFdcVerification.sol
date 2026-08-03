// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IXRPPayment} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title MockFdcVerification — Test double for Flare FdcVerification
/// @dev Only implements verifyXRPPayment(IXRPPayment.Proof calldata) which returns
///      a configurable bool. The vault calls this via IXRPPaymentVerification.
contract MockFdcVerification {
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
