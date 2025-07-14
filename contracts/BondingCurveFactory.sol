// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BondingCurve.sol";

contract BondingCurveFactory {
    function deploy(
        address owner,
        address controller
    ) external returns (address) {
        BondingCurve curve = new BondingCurve(owner, controller);

        return address(curve);
    }
}
