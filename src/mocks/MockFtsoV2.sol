// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title MockFtsoV2 — Test double for Flare FtsoV2 price feed
/// @dev Only implements the read functions used by CreditGateVault:
///      getFeedByIdInWei(bytes21) and getFeedById(bytes21).
contract MockFtsoV2 {
    uint256 private _valueInWei; // 18-decimal USD price
    int8 private _decimals; // reported decimals (for getFeedById)
    uint64 private _feedTimestamp; // feed timestamp

    function setValueInWei(uint256 value_, uint64 timestamp_) external {
        _valueInWei = value_;
        _decimals = 18;
        _feedTimestamp = timestamp_;
    }

    /// @notice payable to match real FtsoV2Interface.getFeedByIdInWei
    function getFeedByIdInWei(bytes21 /*_feedId*/)
        external
        payable
        returns (uint256 _value, uint64 _timestamp)
    {
        return (_valueInWei, _feedTimestamp);
    }

    /// @notice payable to match real FtsoV2Interface.getFeedById
    function getFeedById(bytes21 /*_feedId*/)
        external
        payable
        returns (uint256 _value, int8 _decimals_, uint64 _timestamp_)
    {
        return (_valueInWei, _decimals, _feedTimestamp);
    }
}
