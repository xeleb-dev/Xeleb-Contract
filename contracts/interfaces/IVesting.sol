pragma solidity ^0.8.20;

import {DevVestingParam} from "../structs/VestingParam.sol";

interface IVesting {
    function createVestingSchedule(
        address token,
        address beneficiary,
        uint256 vestingAmount,
        uint256 cliffPeriod,
        uint256 vestingTime,
        uint256 unlockPercent,
        bool isBondingCurve
    ) external;

    function createMultipleVestingSchedule(
        address token,
        DevVestingParam[] calldata params,
        uint256 devTeamAmount,
        bool isBondingCurve
    ) external;
}
