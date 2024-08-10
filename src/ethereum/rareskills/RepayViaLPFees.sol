// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {CometMainInterface} from "./interfaces/CometMainInterface.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {FixedPoint96} from "./libraries/FixedPoint96.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IWrappedTokenGatewayV3} from "@aave/v3-periphery/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol"; 
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IVariableDebtToken} from "@aave/v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IPoolDataProvider} from "@aave/v3-core/contracts/interfaces/IPoolDataProvider.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DataTypes} from "@aave/v3-core/contracts/protocol/libraries/types/DataTypes.sol";

contract RepayViaLPFees {
    using SafeTransferLib for address;

    error OnChainLeverage__AssetTransferFailed();
    error OnChainLeverage__InsufficientAssetProvided();
    error OnChainLeverage__NotEnoughCollateralDeposited();

    struct NetworkConfig {
        address usdcAddress;
        address wethAddress;
        address aavePoolAddress;
        address wrappedTokenGatewayAddress;
        address creditDelegationToken;
        address aavePriceOracleAddress;
        address quoterAddress;
        address swapRouterAddress;
        address cometAddress;
        address positionManagerAddress;
    } 

    uint24 private constant UNISWAP_FEE = 3000;
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // Jeffrey: Not a recommended practice

    ERC20 private usdc;
    ERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    ICreditDelegationToken private creditDelegationToken;
    CometMainInterface private comet;
    INonfungiblePositionManager public immutable positionManager;

    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Swap(address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);

    constructor(NetworkConfig memory activeNetwork) {
        usdc = ERC20(activeNetwork.usdcAddress);
        weth = ERC20(activeNetwork.wethAddress);
        aavePool = IPool(activeNetwork.aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(activeNetwork.wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(activeNetwork.aavePriceOracleAddress);
        quoter = IQuoter(activeNetwork.quoterAddress);
        swapRouter = ISwapRouter(activeNetwork.swapRouterAddress);
        // comet = CometMainInterface(activeNetwork.cometAddress);
        positionManager = INonfungiblePositionManager(activeNetwork.positionManagerAddress);
    } 

    function depositEthOnAave() external payable {
        ERC20(weth).approve(address(wrappedTokenGateway), msg.value);
        wrappedTokenGateway.depositETH{value: msg.value}(address(aavePool), msg.sender, 0);
        emit Deposit(msg.sender, ETH_ADDRESS, msg.value);
    }

    // function to borrow eth from aave
    // function to swap ausdc back to usdc
    // put eth and usdc as lp position in uniswap
    // pay the debt as LP positions make profit

    function getATokenAddress(address assetAddress) public view returns (address aTokenAddress) {
        DataTypes.ReserveData memory reserveData = aavePool.getReserveData(assetAddress);
        aTokenAddress = reserveData.aTokenAddress;
    }

    // 1. Deposit USDC into Aave
    function depositAssetOnAave(address asset, uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        ERC20(asset).approve(address(aavePool), amount);
        aavePool.supply(asset, amount, msg.sender, 0);
        emit Deposit(msg.sender, asset, amount);
    }

    function borrowEthFromAave(uint256 amount, address onBehalfOf) external {
        // Check for sufficient deposited asset balance of the user in the aave pool
        (,,uint256 availableBorrowsBase,,,) = aavePool.getUserAccountData(onBehalfOf);

        uint256 decimals = weth.decimals();
        console.log("Available borrows base: ", availableBorrowsBase);

        // Get the amount to borrow in the eth equivalent
        uint256 wethPrice = priceOracle.getAssetPrice(address(weth));
        console.log("Deposited asset price: ", wethPrice);
        uint256 borrowableAmount = (availableBorrowsBase * (10**decimals)) / wethPrice;
        console.log("Borrowable amount: ", borrowableAmount);
        if (borrowableAmount < amount) {
            revert OnChainLeverage__NotEnoughCollateralDeposited();
        }
        console.log("Original contract's balance before borrowing: ", address(this).balance);
        // This will require the user to approve the approveDelegation to borrow weth
        aavePool.borrow(address(weth), amount, 2, 0, onBehalfOf);
        emit Borrow(msg.sender, ETH_ADDRESS, amount);
        console.log("Value of eth being withdrawn: ", amount);
        IWETH9(address(weth)).withdraw(amount);
        console.log("Original contract's balance after borrowing: ", address(this).balance);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert("Failed to send eth to the user");
        }
    }

    function swapAssetsOnUniswap(address assetIn, uint256 amountIn, address assetOut, uint256 amountOut, uint256 deadline) external returns (uint256 exactAmountOut) {
        assetIn.safeTransferFrom(msg.sender, address(this), amountIn);
        ERC20(assetIn).approve(address(swapRouter), amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetIn,
            tokenOut: assetOut,
            fee: UNISWAP_FEE,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOut,
            sqrtPriceLimitX96: 0
        });
        exactAmountOut = swapRouter.exactInputSingle(params);
        emit Swap(msg.sender, assetIn, assetOut, amountIn, amountOut);
    }

    // Add liquidity to the ETH/USDC pool
    function addLiquidity(
        uint256 amountUSDC,
        uint256 amountUSDCMin,
        uint256 amountWETH,
        uint256 amountWETHMin,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (msg.value != amountWETH) {
            revert OnChainLeverage__InsufficientAssetProvided();
        }
        // Transfer USDC and WETH to this contract
        address(usdc).safeTransferFrom(msg.sender, address(this), amountUSDC);
        // address(weth).safeTransferFrom(msg.sender, address(this), amountWETH);

        // Approve the position manager to spend the tokens
        usdc.approve(address(positionManager), amountUSDC);
        // weth.approve(address(positionManager), amountWETH);

        
        // Parameters for minting the position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdc),
            token1: address(weth),
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amountUSDC,
            amount1Desired: amountWETH,
            amount0Min: amountUSDCMin,
            amount1Min: amountWETHMin,
            recipient: recipient,
            deadline: deadline
        });

        // Mint the liquidity position
        (tokenId, liquidity, amount0, amount1) = positionManager.mint{value: amountWETH}(params);

        // Refund any unused tokens
        if (amountWETH > amount1) {
            (bool success,) = payable(msg.sender).call{value: amountWETH - amount1}("");
            if (!success) {
                revert OnChainLeverage__AssetTransferFailed();
            }
        }
        if (amountUSDC > amount0) {
            uint256 remainingUSDC = amountUSDC - amount0;
            address(usdc).safeTransfer(msg.sender, remainingUSDC);
        }
    }

    function addLiquidityToUniswap() external returns (uint256) {
        // Add liquidity to uniswap by providing eth and usdc
        // Get the amount of eth and usdc to be provided
    }

    // Function to pay the amount coming from LP to repay the debt position on aave based on the profits from Uniswap LP positions
    function repayAssetOnAave(address asset, uint256 amount) external {
        // asset.safeTransferFrom(msg.sender, address(this), amount);
        // ERC20(asset).approve(address(aavePool), amount);
        // aavePool.repay(asset, amount, 2, msg.sender);
        // emit Withdraw(msg.sender, asset, amount);
    }

    function getLowerAndUpperTicks(uint256 minPrice, uint256 maxPrice, uint8 token0Decimal, uint8 token1Decimal, int24 tickSpacing) public pure returns (int24, int24) {
        require(minPrice < maxPrice, "Min price must be less than max price");
        
        uint256 token0Multiplier = 10**token0Decimal;
        uint256 token1Multiplier = 10**token1Decimal;

        // For USDC/WETH pair, we need to use the prices directly (not inverted)
        // because USDC (token0) is the quote currency
        uint160 sqrtPriceX96Min = encodePriceToSqrtPriceX96(minPrice, token0Multiplier, token1Multiplier);
        uint160 sqrtPriceX96Max = encodePriceToSqrtPriceX96(maxPrice, token0Multiplier, token1Multiplier);

        // Calculate ticks
        int24 tickLower = TickMath.getTickAtSqrtRatio(sqrtPriceX96Min);
        int24 tickUpper = TickMath.getTickAtSqrtRatio(sqrtPriceX96Max);

        // Ensure ticks are on multiples of tickSpacing
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        // Ensure lower tick is less than upper tick
        assert(tickLower < tickUpper);

        // Ensure ticks are within allowed range
        assert(tickLower >= TickMath.MIN_TICK);
        assert(tickUpper <= TickMath.MAX_TICK);

        return (tickLower, tickUpper);
    }

    function encodePriceToSqrtPriceX96(uint256 price, uint256 baseTokenDecimals, uint256 quoteTokenDecimals) internal pure returns (uint160) {
        require(price > 0, "Price must be greater than zero");
        uint256 priceQ96 = (price * quoteTokenDecimals * (1 << 96)) / baseTokenDecimals;
        uint256 sqrtPriceQ96 = sqrt(priceQ96);
        return uint160(sqrtPriceQ96);
    }

    // Copied from Uniswap as the interface was on different version
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // Required because of IWETH9.withdraw() function
    fallback() external payable {}

    receive() external payable {}
}