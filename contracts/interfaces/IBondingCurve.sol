pragma solidity ^0.8.20;

interface IBondingCurve {
    function initialize(
        address _token,
        address _baseToken,
        address _adminVerifyAddress,
        address _owner,
        uint256 _bondingSupply,
        uint256 _liquiditySupply,
        uint256 _finalBaseAmount,
        address _stakingAddress,
        bool _isAutoAddLiquidity,
        uint24 _feeTier
    ) external;

    function getCurrentPrice() external view returns (uint256);

    function getTokensForBNB(uint256 bnbAmount) external view returns (uint256);

    function getBNBForTokens(
        uint256 tokenAmount
    ) external view returns (uint256);

    function buy() external payable;

    function sell(uint256 tokenAmount) external;

    function bondingComplete() external view returns (bool);

    function bondingCompleteAt() external view returns (uint256);

    function startBonding() external;
}
