// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library Cashier {
    function nativeToken() internal view returns (address) {
        if (block.chainid == 97) {
            // BSC Testnet
            return 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
        } else if (block.chainid == 56) {
            // BSC Mainnet
            return 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        }
        // Add more chain IDs and their native token addresses as needed
        revert("Unsupported chain");
    }

    function isNative(address token) internal view returns (bool) {
        return token == nativeToken();
    }

    function deposit(address token, address from, uint256 amount) internal {
        if (isNative(token)) {
            require(msg.value == amount, "Incorrect BNB amount sent");
            // BNB is already received via msg.value
        } else {
            require(msg.value == 0, "Do not send BNB when using ERC20");
            if (from != address(this)) {
                require(
                    IERC20(token).transferFrom(from, address(this), amount),
                    "ERC20 transferFrom failed"
                );
            }
        }
    }

    function withdraw(address token, address to, uint256 amount) internal {
        if (isNative(token)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "BNB transfer failed");
        } else {
            require(
                IERC20(token).transfer(to, amount),
                "ERC20 transfer failed"
            );
        }
    }

    function balanceOf(
        address token,
        address account
    ) internal view returns (uint256) {
        if (isNative(token)) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }
}
