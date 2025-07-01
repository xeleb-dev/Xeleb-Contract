// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ArnoldAIerc20 is ERC20, ERC20Burnable, Ownable {
    bool public isLaunched;
    address public bondingCurve;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _bonding
    ) ERC20(_name, _symbol) Ownable(_bonding) {
        _mint(msg.sender, _totalSupply);
        bondingCurve = _bonding;
    }

    function launch() external onlyOwner {
        require(!isLaunched, "ERC20: LP already added");
        isLaunched = true;
        renounceOwnership();
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        // If token is not launched, only allow transfers to/from bondingCurve
        if (!isLaunched) {
            require(
                from == bondingCurve || to == bondingCurve,
                "ERC20: Transfers not allowed before launch"
            );
        }

        super._update(from, to, amount);
    }
}
