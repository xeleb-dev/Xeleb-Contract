// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "hardhat/console.sol";
import "./interfaces/IController.sol";
import {DevVestingParam} from "./structs/VestingParam.sol";

contract Vesting is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 startTime;
        uint256 cliffPeriod; // duration in seconds
        uint256 vestPeriod; // duration in seconds
        uint256 lastClaimTime;
        uint256 releasedAmount;
        uint256 unlockAmount; // amount to be claimed separately
        bool unlockClaimed; // track if unlockAmount has been claimed
    }

    IController controller;
    // Mapping from token address to beneficiary address to vesting schedule
    mapping(address => mapping(address => VestingSchedule))
        public vestingSchedules;

    // Events
    event CreateVesting(
        address indexed token,
        address indexed beneficiary,
        uint256 startTime,
        uint256 cliffPeriod,
        uint256 vestPeriod,
        uint256 amount,
        uint256 unlockAmount
    );
    event TriggerVesting(
        address indexed token,
        address indexed beneficiary,
        uint256 startTime
    );
    event VestingTokensClaimed(
        address indexed token,
        address indexed beneficiary,
        uint256 amount
    );
    event VestingCompleted(
        address indexed token,
        address indexed beneficiary,
        uint256 totalAmount
    );

    // Add role constant
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant DEMI = 10000; // 100.00% = 10000, 1% = 100

    constructor(address _controller) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, _controller);
        controller = IController(_controller);
    }

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "caller is not an admin");
        _;
    }

    function _addVestingSchedule(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 cliffPeriod,
        uint256 vestingTime,
        uint256 unlockPercent,
        bool isBondingCurve
    ) private {
        require(token != address(0), "Invalid token address");
        require(beneficiary != address(0), "Invalid beneficiary address");
        require(amount > 0, "Amount must be greater than 0");
        require(vestingTime > 0, "Vesting time must be greater than 0");
        require(unlockPercent <= DEMI, "Unlock percent must be <= 100% (DEMI)");
        VestingSchedule storage existingSchedule = vestingSchedules[token][
            beneficiary
        ];
        if (
            existingSchedule.totalAmount > 0 ||
            existingSchedule.unlockAmount > 0
        ) {
            revert("Vesting already exists");
        }
        uint256 unlockAmount = (amount * unlockPercent) / DEMI;
        uint256 vestedAmount = amount - unlockAmount;
        vestingSchedules[token][beneficiary] = VestingSchedule({
            totalAmount: vestedAmount,
            startTime: isBondingCurve ? 0 : block.timestamp,
            cliffPeriod: cliffPeriod,
            vestPeriod: vestingTime,
            lastClaimTime: 0,
            releasedAmount: 0,
            unlockAmount: unlockAmount,
            unlockClaimed: false
        });
        emit CreateVesting(
            token,
            beneficiary,
            isBondingCurve ? 0 : block.timestamp,
            cliffPeriod,
            vestingTime,
            vestedAmount,
            unlockAmount
        );
    }

    function createVestingSchedule(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 cliffPeriod,
        uint256 vestingTime,
        uint256 unlockPercent,
        bool isBondingCurve
    ) external onlyAdmin whenNotPaused {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _addVestingSchedule(
            token,
            beneficiary,
            amount,
            cliffPeriod,
            vestingTime,
            unlockPercent,
            isBondingCurve
        );
    }

    function createMultipleVestingSchedule(
        address token,
        DevVestingParam[] calldata params,
        uint256 devTeamAmount,
        bool isBondingCurve
    ) external onlyAdmin whenNotPaused {
        uint256 len = params.length;
        uint256 totalDevPercent = 0;
        for (uint256 i = 0; i < len; i++) {
            totalDevPercent += params[i].devPercent;
        }
        require(totalDevPercent == DEMI, "Dev percents must sum to DEMI");
        // Single transfer for all vestings
        IERC20(token).safeTransferFrom(msg.sender, address(this), devTeamAmount);
        for (uint256 i = 0; i < len; i++) {
            uint256 amount = (devTeamAmount * params[i].devPercent) / DEMI;
            _addVestingSchedule(
                token,
                params[i].devAddress,
                amount,
                params[i].cliffPeriod,
                params[i].vestingTime,
                params[i].unlockPercent,
                isBondingCurve
            );
        }
    }

    function _calculateClaimableAmount(
        VestingSchedule memory schedule,
        bool bondingComplete,
        uint256 bondingCompleteAt
    ) internal view returns (uint256) {
        // Fail fast if no vesting schedule exists
        require(schedule.totalAmount > 0, "No vesting schedule exists");
        require(schedule.vestPeriod > 0, "Invalid vesting period");

        // For bonding curve vesting, use bonding complete logic
        uint256 effectiveStartTime = schedule.startTime;
        if (effectiveStartTime == 0) {
            if (bondingComplete) {
                effectiveStartTime = bondingCompleteAt;
            } else {
                return 0;
            }
        }
        uint256 cliffEnd = effectiveStartTime + schedule.cliffPeriod;
        uint256 endTime = cliffEnd + schedule.vestPeriod;

        // No tokens available before cliff period ends
        if (block.timestamp < cliffEnd) return 0;

        // All tokens available after vesting period ends
        if (block.timestamp >= endTime) {
            return schedule.totalAmount - schedule.releasedAmount;
        }

        // Calculate vested amount based on time elapsed
        uint256 timeFromStart = block.timestamp - cliffEnd;
        uint256 vestingDuration = schedule.vestPeriod;

        // Calculate vested amount with precision consideration
        uint256 vestedAmount = (schedule.totalAmount * timeFromStart) /
            vestingDuration;
        if (vestedAmount > schedule.totalAmount) {
            vestedAmount = schedule.totalAmount;
        }

        // Calculate remaining claimable amount
        uint256 remainingClaimable = 0;
        if (vestedAmount > schedule.releasedAmount) {
            remainingClaimable = vestedAmount - schedule.releasedAmount;
        }
        return remainingClaimable;
    }

    function _claimUnlockAmount(
        address token,
        address beneficiary,
        VestingSchedule storage schedule
    ) internal {
        if (!schedule.unlockClaimed) {
            schedule.unlockClaimed = true;
            uint256 amount = schedule.unlockAmount;
            if (amount > 0) {
                IERC20(token).safeTransfer(beneficiary, amount);
            }
            emit TriggerVesting(token, beneficiary, schedule.startTime);
        }
    }

    function claimVestedTokens(
        address token
    ) external nonReentrant whenNotPaused {
        address beneficiary = msg.sender;
        VestingSchedule storage schedule = vestingSchedules[token][beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found");

        bool bondingComplete;
        uint256 bondingCompleteAt;

        if (schedule.startTime == 0) {
            (bondingComplete, bondingCompleteAt) = controller.getBondingStatus(
                token
            );

            require(bondingComplete, "Bonding not complete");
            schedule.startTime = bondingCompleteAt;
        }

        // Claim unlockAmount if available
        _claimUnlockAmount(token, beneficiary, schedule);

        uint256 cliffEnd = schedule.startTime + schedule.cliffPeriod;
        if (block.timestamp < cliffEnd) {
            return;
        }

        uint256 claimableAmount = _calculateClaimableAmount(
            schedule,
            bondingComplete,
            bondingCompleteAt
        );
        require(claimableAmount > 0, "No tokens available to claim");

        schedule.releasedAmount += claimableAmount;
        schedule.lastClaimTime = block.timestamp;

        IERC20(token).safeTransfer(beneficiary, claimableAmount);

        if (schedule.releasedAmount >= schedule.totalAmount) {
            delete vestingSchedules[token][beneficiary];
            emit VestingCompleted(token, beneficiary, schedule.totalAmount);
        }
        emit VestingTokensClaimed(token, beneficiary, claimableAmount);
    }

    function getVestingDetails(
        address token,
        address beneficiary
    )
        external
        view
        returns (
            uint256 totalAmount,
            uint256 releasedAmount,
            uint256 claimableAmount,
            uint256 startTime,
            uint256 cliffPeriod,
            uint256 vestPeriod,
            uint256 unlockAmount,
            bool unlockClaimed
        )
    {
        VestingSchedule memory schedule = vestingSchedules[token][beneficiary];
        bool bondingComplete;
        uint256 bondingCompleteAt;
        if (schedule.startTime == 0) {
            (bondingComplete, bondingCompleteAt) = controller.getBondingStatus(
                token
            );
        }

        return (
            schedule.totalAmount,
            schedule.releasedAmount,
            _calculateClaimableAmount(
                schedule,
                bondingComplete,
                bondingCompleteAt
            ),
            schedule.startTime,
            schedule.cliffPeriod,
            schedule.vestPeriod,
            schedule.unlockAmount,
            schedule.unlockClaimed
        );
    }

    function pause() external onlyAdmin {
        _pause();
    }

    function unpause() external onlyAdmin {
        _unpause();
    }

    function emergencyWithdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin {
        require(to != address(0), "Invalid to address");
        IERC20(token).safeTransfer(to, amount);
    }
}
