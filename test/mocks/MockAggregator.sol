// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

contract MockAggregator is IAggregatorV3 {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
