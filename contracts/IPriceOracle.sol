// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;    

interface IPriceOracle {
  /**
   * @dev Return stablePerCollateralX18:
   * stable amount (in stable token smallest units) per 1 full collateral token (10**collateralDecimals),
   * multiplied by 1e18.
   */
  function getPrice(address collateralToken) external view returns (uint256);
}