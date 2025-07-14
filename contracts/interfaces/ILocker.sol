pragma solidity ^0.8.20;

interface ILocker {
    function lockWithDefaultDuration(
        uint256 nftId,
        address owner
    ) external returns (uint256);
}
