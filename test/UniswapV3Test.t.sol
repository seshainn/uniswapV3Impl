// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
pragma abicoder v2;

import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IV3SwapRouter} from "lib/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {FullMath} from "../lib/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "../src/constants.sol";
import {Token0} from "../src/Token0.sol";
import {Token1} from "../src/Token1.sol";

contract UniswapV3Test is Test {

    uint256 private constant Q96 = 1 << 96;
    uint24 private constant POOL_FEE = 3000;

    IWETH9 private weth = IWETH9(constants.WETH);
    IERC20 private dai = IERC20(constants.DAI);
    IERC20 private wbtc = IERC20(constants.WBTC);

    IUniswapV3Factory private constant factory = IUniswapV3Factory(constants.UNISWAP_V3_FACTORY);
    IV3SwapRouter private constant router = IV3SwapRouter(constants.UNISWAP_V3_SWAP_ROUTER_02);
    IUniswapV3Pool private immutable pool = IUniswapV3Pool(constants.UNISWAP_V3_PAIR_USDC_WETH_500);

    function setUp() public {
        deal(constants.DAI, address(this), 1000 * 1e18);
        dai.approve(address(router), type(uint256).max);
    }

    function test_spot_price_from_sqrtPriceX96() public {
        uint256 price = 0;
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        price = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        price = (1e12 * 1e18 * Q96) / price;

        assertGt(price, 0, "");
        console2.log("price is %e", price);
    }
    function test_get_pool() public view {
        address pool_addr = factory.getPool(constants.USDC, constants.WETH, 500);
        assertEq(pool_addr, constants.UNISWAP_V3_PAIR_USDC_WETH_500);
    }
    function test_create_pool() public {
        Token0 tokenA = new Token0(1e18);
        Token1 tokenB = new Token1(1e18);
        address pool_addr = factory.createPool(address(tokenA), address(tokenB), 500);
        (address token0, address token1) = address(tokenA) <= address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        assertEq(IUniswapV3Pool(pool_addr).token0(), token0);
        assertEq(IUniswapV3Pool(pool_addr).token1(), token1);
        assertEq(IUniswapV3Pool(pool_addr).fee(), 500);
    }

    //exactInputSingle() is for single hop swap; performs swaps within a pool and takes ExactInputSingleParams as argument
    //swap 1000 DAI for WETH here
    function test_exactInputSingle() public {
        uint256 wethBefore = weth.balanceOf(address(this));

        // Call router.exactInputSingle
        uint256 amountOut = router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: constants.DAI,
                tokenOut: constants.WETH,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: 1000 * 1e18,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 wethAfter = weth.balanceOf(address(this));

        console2.log("WETH: %e", amountOut);
        assertGt(amountOut, 0);
        assertEq(wethAfter - wethBefore, amountOut);
    }
    //exactInput() is for multi hop swap
    function test_exactInput() public {
        bytes memory path =
            abi.encodePacked(constants.DAI, uint24(3000), constants.WETH, uint24(3000), constants.WBTC);

        uint256 amountOut = router.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: 1000 * 1e18,
                amountOutMinimum: 1
            })
        );

        console2.log("WBTC amount out %e", amountOut);
        assertGt(amountOut, 0);
        assertEq(wbtc.balanceOf(address(this)), amountOut);
    }
    function test_exactOutputSingle() public {
        uint256 wethBefore = weth.balanceOf(address(this));

        uint256 amountIn = router.exactOutputSingle(
            IV3SwapRouter.ExactOutputSingleParams({
                tokenIn: constants.DAI,
                tokenOut: constants.WETH,
                fee: POOL_FEE,
                recipient: address(this),
                amountOut: 0.1 * 1e18,
                amountInMaximum: 1000 * 1e18,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 wethAfter = weth.balanceOf(address(this));

        console2.log("DAI amount in %e", amountIn);
        assertLe(amountIn, 1000 * 1e18);
        assertEq(wethAfter - wethBefore, 0.1 * 1e18);
    }
    function test_exactOutput() public {
        bytes memory path =
            abi.encodePacked(constants.WBTC, uint24(3000), constants.WETH, uint24(3000), constants.DAI);

        uint256 amountIn = router.exactOutput(
            IV3SwapRouter.ExactOutputParams({
                path: path,
                recipient: address(this),
                amountOut: 0.001 * 1e8, //lower output 
                amountInMaximum: 1000 * 1e18
            })
        );

        console2.log("DAI amount in %e", amountIn);
        assertLe(amountIn, 1000 * 1e18);
        assertEq(wbtc.balanceOf(address(this)), 0.001 * 1e8);
    }
}