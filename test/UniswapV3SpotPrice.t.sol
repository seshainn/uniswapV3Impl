// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswapCore/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswapPeriphery/contracts/libraries/FullMath.sol";
import "../src/constants.sol";

contract UniswapV3SpotPrice is Test {
    uint256 private constant USDC_DECIMALS = 1e6;
    uint256 private constant WETH_DECIMALS = 1e18;
    uint256 private constant Q96 = 1 << 96;

    IUniswapV3Pool private immutable pool = IUniswapV3Pool(constants.UNISWAP_V3_PAIR_USDC_WETH);

    function test_spot_price_from_sqrtPriceX96() public {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        uint256 price = FullMath.mulDiv(
        uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
        USDC_DECIMALS,
        Q96 * Q96
        );

        assertGt(price, 0, "");
        console2.log("price is %e", price);
    }
}
