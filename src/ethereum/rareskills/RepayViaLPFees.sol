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
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DataTypes} from "@aave/v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NetworkConfig} from "../NetworkConfig.sol";

contract RepayViaLPFees is IERC721Receiver {
    using SafeTransferLib for address;

    error RepayViaLPFees__AssetTransferFailed();
    error RepayViaLPFees__InsufficientAssetProvided();
    error RepayViaLPFees__NotEnoughCollateralDeposited();

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
            revert RepayViaLPFees__NotEnoughCollateralDeposited();
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
            revert RepayViaLPFees__InsufficientAssetProvided();
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

        if (amountUSDC > amount0) {
            uint256 remainingUSDC = amountUSDC - amount0;
            address(usdc).safeTransfer(msg.sender, remainingUSDC);
        }
        // Refund any unused tokens
        // if (amountWETH > amount1) {
        //     (bool success,) = payable(msg.sender).call{value: amountWETH - amount1}("");
        //     if (!success) {
        //         revert RepayViaLPFees__AssetTransferFailed();
        //     }
        // }
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


    // Helper function to encode price as sqrtPriceX96 (TODO: check this function)
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

    function calculateTick(uint256 price, uint8 decimal0, uint8 decimal1) public pure returns (int24) {
        require(decimal0 <= 18 && decimal1 <= 18, "Decimals must be <= 18");
        
        uint256 adjustedPrice = (price * (10**decimal0)) / (10**decimal1);
        uint160 sqrtPriceX96 = uint160(sqrt((adjustedPrice << 192) / 1 ether));
        
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function calculatePriceFromTick(int24 tick, uint8 decimal0, uint8 decimal1) public pure returns (uint256) {
        require(decimal0 <= 18 && decimal1 <= 18, "Decimals must be <= 18");
        
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 price = FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 10**decimal1, 1 << 192);
        
        return price / (10**decimal0);
    }

    function getTickRange(uint256 lowerPrice, uint256 upperPrice, uint8 decimal0, uint8 decimal1) public pure returns (int24, int24) {
        int24 lowerTick = calculateTick(lowerPrice, decimal0, decimal1);
        int24 upperTick = calculateTick(upperPrice, decimal0, decimal1);
        
        return (lowerTick, upperTick);
    }

    function collectLPFees(uint256 tokenId, address recipient) external {
        // Transfer the LP position to this contract
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);

        // 1. Approve the position manager to spend the LP position
        positionManager.approve(address(positionManager), tokenId);

        // Collect fees
        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        console.log("Collected USDC:", amount0);
        console.log("Collected WETH:", amount1);

        // Optionally, swap WETH to USDC
        // if (amount1 > 0) {
        //     WETH.approve(address(swapRouter), amount1);
        //     ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
        //         tokenIn: address(WETH),
        //         tokenOut: address(USDC),
        //         fee: 3000, // Assuming 0.3% fee pool, adjust if necessary
        //         recipient: msg.sender,
        //         deadline: block.timestamp + 300,
        //         amountIn: amount1,
        //         amountOutMinimum: 0, // Be careful with this in production!
        //         sqrtPriceLimitX96: 0
        //     });
        //     uint256 amountOut = swapRouter.exactInputSingle(params);
        //     console.log("Swapped WETH to USDC:", amountOut);
        // }

        // // Transfer remaining USDC to the owner
        // if (amount0 > 0) {
        //     USDC.transfer(msg.sender, amount0);
        // }
    }

    // Required because of IWETH9.withdraw() function
    fallback() external payable {}

    receive() external payable {}

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}