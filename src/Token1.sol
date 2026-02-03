// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token1 is ERC20 {
    constructor(uint256 _initSupply) ERC20("TOKEN1", "TK1") {
        _mint(msg.sender, _initSupply);
    }
}