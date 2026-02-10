// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    INonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {
    IUniswapV3Factory
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    TransferHelper
} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

contract ManageLiquidity is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error ManageLiquidity__ZeroLiquidity();
    error ManageLiquidity__InvalidTicks();
    error ManageLiquidity__PoolNotInitialized();
    error ManageLiquidity__NotYourTokenId();
    error ManageLiquidity__NoLiquidityAdded();
    error ManageLiquidity__InvalidPosition();
    error ManageLiquidity__ExcessLiquidityRemoval();
    error ManageLiquidity__NoLiquidityRemoved();
    error ManageLiquidity__NothingToCollect();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event LiquidityMinted(
        address indexed user,
        uint256 indexed tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Used,
        uint256 amount1Used
    );
    event LiquidityIncreased(
        address indexed user,
        uint256 indexed tokenId,
        uint128 liquidityDelta,
        uint256 amount0Used,
        uint256 amount1Used
    );
    event LiquidityDecreased(
        address indexed user,
        uint256 indexed tokenId,
        uint128 liquidityRemoved,
        uint256 amount0Owed,
        uint256 amount1Owed
    );
    event LiquidityCollected(
        address indexed user,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount0Collected,
        uint256 amount1Collected
    );

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/
    INonfungiblePositionManager public immutable manager;
    IUniswapV3Factory public immutable factory;

    IERC20 public immutable weth;
    IERC20 public immutable dai;

    uint24 public immutable poolFee;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _manager,
        address _factory,
        address _dai,
        address _weth,
        uint24 _poolFee
    ) {
        manager = INonfungiblePositionManager(_manager);
        factory = IUniswapV3Factory(_factory);
        weth = IERC20(_weth);
        dai = IERC20(_dai);
        poolFee = _poolFee;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Add liquidity to the pool (when user does not have a tokenId yet)
    function mint(
        int24 tickLowerInput,
        int24 tickUpperInput,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (uint256 tokenId, uint128 liquidity) {
        if (amount0Desired == 0 && amount1Desired == 0)
            revert ManageLiquidity__ZeroLiquidity();

        if (tickLowerInput >= tickUpperInput)
            revert ManageLiquidity__InvalidTicks();

        // Ensure pool exists & initialized
        address pool = factory.getPool(address(dai), address(weth), poolFee);
        if (pool == address(0)) revert ManageLiquidity__PoolNotInitialized();

        // Get tick spacing from pool (DO NOT HARDCODE)
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        int24 tickLower = _floorTick(tickLowerInput, tickSpacing);
        int24 tickUpper = _ceilTick(tickUpperInput, tickSpacing);

        if (
            tickLower < MIN_TICK ||
            tickUpper > MAX_TICK ||
            tickLower >= tickUpper
        ) revert ManageLiquidity__InvalidTicks();

        // Pull tokens from user
        TransferHelper.safeTransferFrom(
            address(dai),
            msg.sender,
            address(this),
            amount0Desired
        );
        TransferHelper.safeTransferFrom(
            address(weth),
            msg.sender,
            address(this),
            amount1Desired
        );

        // Approve exact amounts
        TransferHelper.safeApprove(
            address(dai),
            address(manager),
            amount0Desired
        );
        TransferHelper.safeApprove(
            address(weth),
            address(manager),
            amount1Desired
        );

        uint256 amount0Used;
        uint256 amount1Used;

        (tokenId, liquidity, amount0Used, amount1Used) = manager.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(dai),
                token1: address(weth),
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: msg.sender,
                deadline: deadline
            })
        );

        // Refund unused tokens
        if (amount0Desired > amount0Used) {
            TransferHelper.safeTransfer(
                address(dai),
                msg.sender,
                amount0Desired - amount0Used
            );
        }

        if (amount1Desired > amount1Used) {
            TransferHelper.safeTransfer(
                address(weth),
                msg.sender,
                amount1Desired - amount1Used
            );
        }

        // Reset approvals
        TransferHelper.safeApprove(address(weth), address(manager), 0);
        TransferHelper.safeApprove(address(dai), address(manager), 0);

        emit LiquidityMinted(
            msg.sender,
            tokenId,
            tickLower,
            tickUpper,
            liquidity,
            amount0Used,
            amount1Used
        );
    }

    /// @notice get user's positions from the pool using his tokenId
    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }
    function getPosition(
        uint256 tokenId
    ) external view returns (Position memory) {
        if (manager.ownerOf(tokenId) != msg.sender)
            revert ManageLiquidity__NotYourTokenId();

        (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = manager.positions(tokenId);

        Position memory position = Position({
            nonce: nonce,
            operator: operator,
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1
        });

        return position;
    }
    /// @notice increase liquidity
    /// @dev ownership validation (ownerOf(tokenId) should be msg.sender)
    /// @dev pool consistency checks (tokens being added should match pool's)
    /// @dev refund unused tokens
    /// @dev guard against zero-liquidity mints (revert if liquidityDelta is zero)
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (uint128 liquidityDelta) {
        if (amount0Desired == 0 && amount1Desired == 0)
            revert ManageLiquidity__ZeroLiquidity();

        if (manager.ownerOf(tokenId) != msg.sender)
            revert ManageLiquidity__NotYourTokenId();

        (, , address token0, address token1, uint24 fee, , , , , , , ) = manager
            .positions(tokenId);

        if (token0 != address(dai) || token1 != address(weth) || fee != poolFee)
            revert ManageLiquidity__InvalidPosition();

        // Pull tokens from user
        TransferHelper.safeTransferFrom(
            address(dai),
            msg.sender,
            address(this),
            amount0Desired
        );
        TransferHelper.safeTransferFrom(
            address(weth),
            msg.sender,
            address(this),
            amount1Desired
        );

        // Approve exact amounts
        TransferHelper.safeApprove(
            address(dai),
            address(manager),
            amount0Desired
        );
        TransferHelper.safeApprove(
            address(weth),
            address(manager),
            amount1Desired
        );

        uint256 amount0Used;
        uint256 amount1Used;

        (liquidityDelta, amount0Used, amount1Used) = manager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        if (liquidityDelta == 0) revert ManageLiquidity__NoLiquidityAdded();

        // Refund unused tokens
        if (amount0Desired > amount0Used) {
            TransferHelper.safeTransfer(
                address(dai),
                msg.sender,
                amount0Desired - amount0Used
            );
        }

        if (amount1Desired > amount1Used) {
            TransferHelper.safeTransfer(
                address(weth),
                msg.sender,
                amount1Desired - amount1Used
            );
        }

        // Reset approvals
        TransferHelper.safeApprove(address(weth), address(manager), 0);
        TransferHelper.safeApprove(address(dai), address(manager), 0);

        emit LiquidityIncreased(
            msg.sender,
            tokenId,
            liquidityDelta,
            amount0Used,
            amount1Used
        );
    }

    /// @notice Decreases liquidity for an existing Uniswap V3 position
    /// @dev Tokens are not transferred to the user here. They become owed and must be collected via collect().
    /// @dev liquidityToRemove is calculated on the frontend based on the percentage that user decides (percent of position.liquidity).
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidityToRemove,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant {
        if (liquidityToRemove == 0) revert ManageLiquidity__ZeroLiquidity();

        // Ownership check
        if (manager.ownerOf(tokenId) != msg.sender)
            revert ManageLiquidity__NotYourTokenId();

        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            ,
            ,
            uint128 currentLiquidity,
            ,
            ,
            ,

        ) = manager.positions(tokenId);

        // Pool consistency check
        if (token0 != address(dai) || token1 != address(weth) || fee != poolFee)
            revert ManageLiquidity__InvalidPosition();

        // Prevent over-removal
        if (liquidityToRemove > currentLiquidity)
            revert ManageLiquidity__ExcessLiquidityRemoval();

        (uint256 amount0, uint256 amount1) = manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        if (amount0 == 0 && amount1 == 0)
            revert ManageLiquidity__NoLiquidityRemoved();

        emit LiquidityDecreased(
            msg.sender,
            tokenId,
            liquidityToRemove,
            amount0,
            amount1
        );
    }

    /// @notice Collects accrued fees and/or withdrawn principal for a position
    /// @dev Can collect fees, principal, or both. Amounts collected are capped by amount{0,1}Max.
    function collect(
        uint256 tokenId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    )
        external
        nonReentrant
        returns (uint256 amount0Collected, uint256 amount1Collected)
    {
        // Ownership check
        if (manager.ownerOf(tokenId) != msg.sender)
            revert ManageLiquidity__NotYourTokenId();

        // Pool consistency check
        (, , address token0, address token1, uint24 fee, , , , , , , ) = manager
            .positions(tokenId);

        if (token0 != address(dai) || token1 != address(weth) || fee != poolFee)
            revert ManageLiquidity__InvalidPosition();

        // Collect tokens owed (fees + withdrawn liquidity)
        (amount0Collected, amount1Collected) = manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );

        if (amount0Collected == 0 && amount1Collected == 0)
            revert ManageLiquidity__NothingToCollect();

        emit LiquidityCollected(
            msg.sender,
            tokenId,
            recipient,
            amount0Collected,
            amount1Collected
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _floorTick(
        int24 tick,
        int24 spacing
    ) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder < 0) remainder += spacing;
        return tick - remainder;
    }

    function _ceilTick(
        int24 tick,
        int24 spacing
    ) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder > 0) remainder -= spacing;
        return tick - remainder;
    }
}
