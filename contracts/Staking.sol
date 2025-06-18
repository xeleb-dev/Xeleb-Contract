// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./Cashier.sol";

contract Staking is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;
    using Cashier for address;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IERC20 public XCX_TOKEN;

    struct TokenInfo {
        uint256 totalStaked;
        uint256 rewardPool;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 apy; // APY in basis points, e.g., 1000 = 10%
    }

    struct UserInfo {
        uint256 stakedAmount;
        uint256 lastClaimTime;
        uint256 lastRewardPerTokenPaid;
        uint256 stakeTime; // Timestamp when user staked their tokens
    }

    // Fixed APY of 10%
    // uint256 public constant APY = 1000; // 10% in basis points (1000 = 10%)
    uint256 public constant BASIS_POINTS = 10000; // 100% in basis points
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant PRECISION = 1e18;
    uint256 public withdrawalLockPeriod = 24 hours; // Default 24 hours lock period

    // token address => TokenInfo
    mapping(address => TokenInfo) public tokenInfo;
    // token address => user address => UserInfo
    mapping(address => mapping(address => UserInfo)) public userInfo;
    // Track initialized tokens
    mapping(address => bool) public isInitialized;

    // BNB fee reward tracking for XCX_TOKEN only
    uint256 public bnbFeeRewardPool;
    uint256 public bnbFeeRewardPerToken;
    mapping(address => uint256) public userLastBnbFeeRewardPerToken;

    bool public distributeFeeToStakers = false;
    uint256 public adminFeeFund;

    event TokenConfigUpdated(address indexed token, uint256 apy);
    event Staked(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 totalStaked
    );
    event Withdrawn(
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 totalStaked
    );
    event RewardClaimed(
        address indexed token,
        address indexed user,
        uint256 timestamp,
        uint256 apyAmount,
        uint256 bnbFeeAmount,
        uint256 rewardPool,
        uint256 bnbFeeRewardPool
    );
    event RewardPoolDeposited(address indexed token, uint256 amount);
    event TokenInitialized(address indexed token, uint256 amount, uint256 apy);

    constructor(address _admin, address _xcxToken) {
        require(_admin != address(0), "Invalid admin address");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, _admin);
        XCX_TOKEN = IERC20(_xcxToken);
    }

    function addAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "Invalid admin address");
        grantRole(ADMIN_ROLE, admin);
    }

    function removeAdmin(address admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "Invalid admin address");
        revokeRole(ADMIN_ROLE, admin);
    }

    function initializeToken(
        address token,
        uint256 initialRewardAmount,
        uint256 apy
    ) external payable onlyRole(ADMIN_ROLE) {
        require(!isInitialized[token], "Token already initialized");
        require(token != address(0), "Invalid token address");

        if (Cashier.isNative(token)) {
            require(
                msg.value == initialRewardAmount,
                "Incorrect BNB amount sent"
            );
            // BNB is already received via msg.value
        } else {
            require(msg.value == 0, "Do not send BNB when using ERC20");
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                initialRewardAmount
            );
        }

        tokenInfo[token] = TokenInfo({
            totalStaked: 0,
            rewardPool: initialRewardAmount,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            apy: apy
        });

        isInitialized[token] = true;
        emit TokenInitialized(token, initialRewardAmount, apy);
    }

    function depositRewards(address token, uint256 amount) external payable {
        require(isInitialized[token], "Token not initialized");
        require(amount > 0, "Amount must be greater than 0");

        if (Cashier.isNative(token)) {
            require(msg.value == amount, "Incorrect BNB amount sent");
            // BNB is already received via msg.value
        } else {
            require(msg.value == 0, "Do not send BNB when using ERC20");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        tokenInfo[token].rewardPool += amount;

        emit RewardPoolDeposited(token, amount);
    }

    function setDistributeFeeToStakers(bool _on) external onlyRole(ADMIN_ROLE) {
        distributeFeeToStakers = _on;
    }

    function withdrawAdminFeeFund(
        address payable to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        require(amount <= adminFeeFund, "Insufficient admin fee fund");
        adminFeeFund -= amount;
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "Withdraw failed");
    }

    function receiveFeeDistribution() external payable {
        if (!distributeFeeToStakers) {
            adminFeeFund += msg.value;
            return;
        }
        require(address(XCX_TOKEN) != address(0), "XCX_TOKEN not set");
        if (msg.value == 0) return;
        TokenInfo storage info = tokenInfo[address(XCX_TOKEN)];
        require(isInitialized[address(XCX_TOKEN)], "XCX_TOKEN not initialized");

        if (info.totalStaked > 0) {
            uint256 rewardPerToken = (msg.value * PRECISION) / info.totalStaked;
            bnbFeeRewardPerToken += rewardPerToken;
            bnbFeeRewardPool += msg.value;
        } else {
            adminFeeFund += msg.value;
        }
    }

    function _updateRewardPerToken(address token) internal {
        TokenInfo storage info = tokenInfo[token];
        if (info.totalStaked == 0) {
            info.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - info.lastUpdateTime;
        if (timeElapsed > 0) {
            // For a fixed APY, each staked token earns APY% per year.
            // This formula calculates the cumulative reward per token for the elapsed time.
            uint256 rewardPerTokenIncrement = (info.apy *
                timeElapsed *
                PRECISION) / (SECONDS_PER_YEAR * BASIS_POINTS);
            info.rewardPerTokenStored += rewardPerTokenIncrement;
            info.lastUpdateTime = block.timestamp;
        }
    }

    function _calculateReward(
        address token,
        address user
    )
        internal
        view
        returns (uint256 actualApyReward, uint256 actualBnbFeeReward)
    {
        UserInfo storage userRecord = userInfo[token][user];
        TokenInfo storage info = tokenInfo[token];

        if (userRecord.stakedAmount == 0) return (0, 0);

        // Calculate current reward per token including any unaccounted time
        uint256 currentRewardPerToken = info.rewardPerTokenStored;
        if (info.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - info.lastUpdateTime;
            if (timeElapsed > 0) {
                uint256 rewardPerTokenIncrement = (info.apy *
                    timeElapsed *
                    PRECISION) / (SECONDS_PER_YEAR * BASIS_POINTS);
                currentRewardPerToken += rewardPerTokenIncrement;
            }
        }

        // Calculate APY rewards based on current reward per token
        uint256 apyReward = (userRecord.stakedAmount *
            (currentRewardPerToken - userRecord.lastRewardPerTokenPaid)) /
            PRECISION;

        // Only XCX_TOKEN stakers get BNB fee rewards
        uint256 bnbFeeReward = 0;
        if (token == address(XCX_TOKEN)) {
            bnbFeeReward =
                (userRecord.stakedAmount *
                    (bnbFeeRewardPerToken -
                        userLastBnbFeeRewardPerToken[user])) /
                PRECISION;
        }

        // Cap rewards to available pools
        actualApyReward = apyReward > info.rewardPool
            ? info.rewardPool
            : apyReward;
        actualBnbFeeReward = 0;
        if (token == address(XCX_TOKEN)) {
            actualBnbFeeReward = bnbFeeReward > bnbFeeRewardPool
                ? bnbFeeRewardPool
                : bnbFeeReward;
        }
    }

    function stake(
        address token,
        uint256 amount
    ) external payable nonReentrant {
        require(isInitialized[token], "Token not initialized");
        require(amount > 0, "Amount must be greater than 0");

        _claimReward(token); // Settle and pay out rewards

        UserInfo storage user = userInfo[token][msg.sender];

        if (Cashier.isNative(token)) {
            require(msg.value == amount, "Incorrect BNB amount sent");
            // BNB is already received via msg.value
        } else {
            require(msg.value == 0, "Do not send BNB when using ERC20");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        user.stakedAmount += amount;
        tokenInfo[token].totalStaked += amount;
        user.stakeTime = block.timestamp; // Set stake time

        emit Staked(token, msg.sender, amount, user.stakedAmount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        require(isInitialized[token], "Token not initialized");
        require(amount > 0, "Amount must be greater than 0");
        UserInfo storage user = userInfo[token][msg.sender];
        require(user.stakedAmount >= amount, "Insufficient staked amount");
        require(
            block.timestamp >= user.stakeTime + withdrawalLockPeriod,
            "Must wait for lock period to end"
        );

        _claimReward(token); // Settle and pay out rewards

        user.stakedAmount -= amount;
        tokenInfo[token].totalStaked -= amount;

        if (Cashier.isNative(token)) {
            (bool sent, ) = msg.sender.call{value: amount}("");
            require(sent, "BNB transfer failed");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdrawn(token, msg.sender, amount, user.stakedAmount);
    }

    function _claimReward(address token) internal {
        require(isInitialized[token], "Token not initialized");
        _updateRewardPerToken(token);

        (
            uint256 actualApyReward,
            uint256 actualBnbFeeReward
        ) = _calculateReward(token, msg.sender);
        UserInfo storage user = userInfo[token][msg.sender];
        TokenInfo storage info = tokenInfo[token];

        user.lastClaimTime = block.timestamp;
        user.lastRewardPerTokenPaid = info.rewardPerTokenStored;
        if (token == address(XCX_TOKEN)) {
            userLastBnbFeeRewardPerToken[msg.sender] = bnbFeeRewardPerToken;
        }

        if (actualApyReward > 0) {
            info.rewardPool -= actualApyReward;
            if (Cashier.isNative(token)) {
                (bool sent, ) = msg.sender.call{value: actualApyReward}("");
                require(sent, "BNB transfer failed");
            } else {
                IERC20(token).safeTransfer(msg.sender, actualApyReward);
            }
        }
        if (actualBnbFeeReward > 0) {
            bnbFeeRewardPool -= actualBnbFeeReward;
            (bool sent, ) = msg.sender.call{value: actualBnbFeeReward}("");
            require(sent, "BNB transfer failed");
        }

        if (actualApyReward > 0 || actualBnbFeeReward > 0) {
            emit RewardClaimed(
                token,
                msg.sender,
                block.timestamp,
                actualApyReward,
                actualBnbFeeReward,
                info.rewardPool,
                bnbFeeRewardPool
            );
        }
    }

    function claimReward(address token) external nonReentrant {
        _claimReward(token);
    }

    function getPendingReward(
        address token,
        address user
    ) external view returns (uint256 apyReward, uint256 bnbFeeReward) {
        require(isInitialized[token], "Token not initialized");
        (apyReward, bnbFeeReward) = _calculateReward(token, user);
    }

    function getStakedAmount(
        address token,
        address user
    ) external view returns (uint256) {
        require(isInitialized[token], "Token not initialized");
        return userInfo[token][user].stakedAmount;
    }

    function updateTokenConfig(
        address token,
        uint256 apy
    ) external onlyRole(ADMIN_ROLE) {
        require(isInitialized[token], "Token not initialized");
        require(apy > 0, "APY must be greater than 0");

        TokenInfo storage info = tokenInfo[token];
        info.apy = apy;

        emit TokenConfigUpdated(token, apy);
    }

    function updateWithdrawalLockPeriod(
        uint256 _newLockPeriod
    ) external onlyRole(ADMIN_ROLE) {
        withdrawalLockPeriod = _newLockPeriod;
    }
}
