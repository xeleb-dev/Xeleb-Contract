pragma solidity ^0.8.20;

interface IStaking {
    function initializeToken(
        address token,
        uint256 initialRewardAmount,
        uint256 apy
    ) external;

    function updateTokenConfig(address token, uint256 apy) external;

    function receiveFeeDistribution() external payable;

    function getStakedAmount(
        address token,
        address user
    ) external view returns (uint256);

    function depositRewards(address token, uint256 amount) external;
}
