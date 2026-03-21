// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

contract MockUniswapV2Router {
    using SafeERC20 for IERC20;

    // priceX18[tokenIn][tokenOut] = 1 tokenIn 能换多少 tokenOut（按 1e18 精度表示）
    mapping(address => mapping(address => uint256)) public priceX18;

    function setPrice(
        address tokenIn,
        address tokenOut,
        uint256 _priceX18
    ) external {
        require(tokenIn != address(0) && tokenOut != address(0), "ZERO_ADDR");
        require(_priceX18 > 0, "PRICE_0");
        priceX18[tokenIn][tokenOut] = _priceX18;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "EXPIRED");
        require(path.length >= 2, "PATH");

        address tokenInAddr = path[0];
        address tokenOutAddr = path[path.length - 1];

        IERC20 tokenIn = IERC20(tokenInAddr);
        IERC20 tokenOut = IERC20(tokenOutAddr);

        uint256 px = priceX18[tokenInAddr][tokenOutAddr];
        require(px > 0, "PRICE_NOT_SET");

        uint8 inDecimals = IERC20Metadata(tokenInAddr).decimals();
        uint8 outDecimals = IERC20Metadata(tokenOutAddr).decimals();

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);

        // 公式：
        // amountOut = amountIn * px / 1e18 * 10^outDecimals / 10^inDecimals
        uint256 amountOut = amountIn;
        amountOut = amountOut * px / 1e18;

        if (outDecimals >= inDecimals) {
            amountOut = amountOut * (10 ** (outDecimals - inDecimals));
        } else {
            amountOut = amountOut / (10 ** (inDecimals - outDecimals));
        }

        console.log("amountIn", amountIn);
        console.log("amountOut", amountOut);
        console.log("amountOutMin", amountOutMin);
        console.log("to", to);
        console.log("deadline", deadline);

        require(amountOut >= amountOutMin, "SLIP");

        tokenOut.safeTransfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }
}