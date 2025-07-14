pragma solidity ^0.8.20;

interface IController {
    function getBondingStatus(
        address token
    ) external view returns (bool, uint256);

    function getBaseTokenConfig(
        address baseToken
    )
        external
        view
        returns (
            uint256 finalBaseAmount,
            uint256 maxBuyAmount,
            uint256 maxBuyAmountEachTx,
            uint256 requireBaseStakeA,
            bool isInitialized
        );

    function getFeeAndBurnPercents()
        external
        view
        returns (uint256 feePercent, uint256 burnPercent);

    function getLockerAddress() external view returns (address);
}
