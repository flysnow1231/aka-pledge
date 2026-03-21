// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;     

/**
 * @dev Interface for the Uniswap V2 Router
 * @notice This interface is used to interact with the Uniswap V2 Router
 * @notice This interface is used to interact with the Uniswap V2 Router
 */
interface IUniswapV2RouterLike {
  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts);
}