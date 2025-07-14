// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenERC20 is ERC20, Ownable {
    bool public isBonding;
    address public bondingCurve;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        _mint(msg.sender, _totalSupply);
    }

    function startBonding(address _bondingCurve) external onlyOwner {
        bondingCurve = _bondingCurve;
        transferOwnership(_bondingCurve);
        isBonding = true;
    }

    function launch() external onlyOwner {
        require(isBonding, "ERC20: Not bonding");
        isBonding = false;
        bondingCurve = address(0);
        renounceOwnership();
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        if (isBonding) {
            require(
                from == bondingCurve || to == bondingCurve,
                "ERC20: Transfers not allowed before launch"
            );
        }

        super._update(from, to, amount);
    }
}
