// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../IPriceOracle.sol";

contract MockOracle is IPriceOracle {
  mapping(address => uint256) public prices;

  function setPrice(address token, uint256 priceX18) external {
    prices[token] = priceX18;
  }

  function getPrice(address collateralToken) external view returns (uint256) {
    uint256 p = prices[collateralToken];
    require(p > 0, "NO_PRICE");
    return p;
  }
}
