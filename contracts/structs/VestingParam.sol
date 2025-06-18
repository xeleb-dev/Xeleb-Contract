// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct DevVestingParam {
    address devAddress;
    uint256 devPercent;
    uint256 cliffPeriod;
    uint256 vestingTime;
    uint256 unlockPercent;
} 