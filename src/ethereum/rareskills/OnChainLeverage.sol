pragma solidity ^0.8.24;

import {IWETH9} from "./interfaces/IWETH9.sol";
import {CometMainInterface} from "./interfaces/CometMainInterface.sol";
import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

// TODO: Amount can be removed as a param in the case of eth short and long
contract OnChainLeverage is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnChainLeverage__InvalidAssetAddress();
    error OnChainLeverage__InsufficientAssetProvided();
    error OnChainLeverage__TransferFailed();

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
    } 

    uint24 private constant UNISWAP_FEE = 3000;

    IERC20 private usdc;
    IERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    ICreditDelegationToken private creditDelegationToken;
    CometMainInterface private comet;

    // TODO: Declare some events here and emit them at state changes

    constructor(NetworkConfig memory activeNetwork) {
        usdc = IERC20(activeNetwork.usdcAddress);
        weth = IERC20(activeNetwork.wethAddress);
        aavePool = IPool(activeNetwork.aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(activeNetwork.wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(activeNetwork.aavePriceOracleAddress);
        quoter = IQuoter(activeNetwork.quoterAddress);
        swapRouter = ISwapRouter(activeNetwork.swapRouterAddress);
        comet = CometMainInterface(activeNetwork.cometAddress);
    } 

    // (TODO: IMPORTANT) Check for the specific assets that can be deposited in the pool | Handle cases which can't be deposited
    // TODO: Return assets wherever remaining
    function longOnAave(address assetLong, address assetShort, uint256 amountLong) external nonReentrant returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // Check if assetLong is ETH address (TODO: IMPORTANT) and accordingly switch between the below two functions

        IERC20(assetLong).safeTransferFrom(msg.sender, address(this), amountLong);
        // 1. Deposit the assetLong in the pool
        IERC20(assetLong).approve(address(aavePool), type(uint256).max);
        aavePool.supply(assetLong, amountLong, msg.sender, 0);

        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(msg.sender);

        // 2. Borrow the asset 75% of the user's total collateral
        uint8 assetDecimal = ERC20(assetShort).decimals();
        // Get the amount to borrow in the assetShort equivalent
        uint256 assetShortPrice = priceOracle.getAssetPrice(assetShort);
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**assetDecimal) / (100 * assetShortPrice);

        aavePool.borrow(assetShort, amountToBorrow, 2, 0, msg.sender); // The 'amountToBorrow' amount of assetShort is with this contract

        // 3. Swap the borrowed assetShort to assetLong
        IERC20(assetShort).approve(address(swapRouter), amountToBorrow);
        uint160 sqrtPriceLimitX96 = 0; // TODO: Set the sqrtPriceLimitX96
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, UNISWAP_FEE, amountToBorrow, sqrtPriceLimitX96);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum, // Should I add a scope of slippage here?
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle(params);

        // 4. Deposit the assetLong in the pool
        // IERC20(assetLong).approve(address(aavePool), amountOut);
        aavePool.supply(assetLong, amountOut, msg.sender, 0);

        // 5. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(msg.sender);
    }

    function longEthOnAave(address assetShort, uint256 amountLong) public payable nonReentrant returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        require(msg.value == amountLong, "Amount should be equal to the value sent");
        if (msg.value != amountLong) {
            revert OnChainLeverage__InsufficientAssetProvided();
        }
        // 1. Deposit the assetLong in the pool
        wrappedTokenGateway.depositETH{value: amountLong}(address(aavePool), msg.sender, 0);

        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(msg.sender);

        // 2. Borrow the assetShort 75% of the user's collateral
        uint8 assetDecimal = ERC20(assetShort).decimals();
        // Get the amount to borrow in the assetShort equivalent
        uint256 assetShortPrice = priceOracle.getAssetPrice(assetShort);
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**assetDecimal) / (100 * assetShortPrice);

        aavePool.borrow(assetShort, amountToBorrow, 2, 0, msg.sender); // The 'amountToBorrow' amount of asset is with this contract

        // 3. Swap the borrowed assetShort to weth
        IERC20(assetShort).approve(address(swapRouter), amountToBorrow);
        address assetLong = address(weth);
        uint160 sqrtPriceLimitX96 = 0;
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, UNISWAP_FEE, amountToBorrow, sqrtPriceLimitX96);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum, // Should I add a scope of slippage here?
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle(params);
        IWETH9(assetLong).withdraw(amountOut);

        // 4. Deposit the assetLong in the pool
        wrappedTokenGateway.depositETH{value: amountOut}(address(aavePool), msg.sender, 0);

        // 5. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(msg.sender);
    }

    function shortWethOnAave(address assetLong, uint256 amountShort) public nonReentrant returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // 1. Swap WETH to assetLong
        address assetShort = address(weth);
        IERC20(assetShort).safeTransferFrom(msg.sender, address(this), amountShort);
        IERC20(assetShort).approve(address(swapRouter), type(uint256).max);
        // uint160 firstSqrtPriceLimitX96 = 0;
        uint256 firstAmountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, UNISWAP_FEE, amountShort, 0);
        ISwapRouter.ExactInputSingleParams memory firstParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountShort,
            amountOutMinimum: firstAmountOutMinimum, // Should I add a scope of slippage here?
            sqrtPriceLimitX96: 0
        });
        uint256 amount = swapRouter.exactInputSingle(firstParams);

        // 2. Deposit the assetLong in the pool
        IERC20(assetLong).approve(address(aavePool), type(uint256).max);
        aavePool.supply(assetLong, amount, msg.sender, 0);

        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(msg.sender);

        // 3. Borrow the assetShort 75% of the user's collateral
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**18) / (100 * priceOracle.getAssetPrice(assetShort));
        
        aavePool.borrow(assetShort, amountToBorrow, 2, 0, msg.sender); // The 'amountToBorrow' amount of asset is with this contract

        // 4. Swap the borrowed assetShort to assetLong
        uint160 sqrtPriceLimitX96 = 0;
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, UNISWAP_FEE, amountToBorrow, sqrtPriceLimitX96);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum, // Should I add a scope of slippage here?
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        // IERC20(assetShort).approve(address(swapRouter), amountToBorrow);
        uint256 amountOut = swapRouter.exactInputSingle(params);

        // 5. Deposit the assetLong in the pool
        // IERC20(assetLong).approve(address(aavePool), amountOut);
        aavePool.supply(assetLong, amountOut, msg.sender, 0);

        // 6. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(msg.sender);
    }

    function shortEthOnAave(address assetLong, uint256 amountShort) public payable nonReentrant returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        if (msg.value != amountShort) {
            revert OnChainLeverage__InsufficientAssetProvided();
        }
        // 1. Swap ETH to assetLong
        address assetShort = address(weth);
        // uint160 firstSqrtPriceLimitX96 = 0;
        uint256 firstAmountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, UNISWAP_FEE, amountShort, 0);
        ISwapRouter.ExactInputSingleParams memory firstParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountShort,
            amountOutMinimum: firstAmountOutMinimum, // Should I add a scope of slippage here?
            sqrtPriceLimitX96: 0
        });
        uint256 amount = swapRouter.exactInputSingle{value: amountShort}(firstParams);

        // 2. Deposit the assetLong in the pool
        IERC20(assetLong).approve(address(aavePool), type(uint256).max);
        aavePool.supply(assetLong, amount, msg.sender, 0);

        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(msg.sender);

        // 3. Borrow the assetShort 75% of the user's collateral
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**18) / (100 * priceOracle.getAssetPrice(assetShort));
        
        aavePool.borrow(assetShort, amountToBorrow, 2, 0, msg.sender); // The 'amountToBorrow' amount of asset is with this contract
        IWETH9(assetShort).withdraw(amountToBorrow);

        // 4. Swap the borrowed assetShort to assetLong
        uint160 sqrtPriceLimitX96 = 0;
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, UNISWAP_FEE, amountToBorrow, sqrtPriceLimitX96);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum, // Should I add a scope of slippage here?
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle{value: amountToBorrow}(params);

        // 5. Deposit the assetLong in the pool
        // IERC20(assetLong).approve(address(aavePool), amountOut);
        aavePool.supply(assetLong, amountOut, msg.sender, 0);

        // 6. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(msg.sender);
    }

    // Required because of IWETH9.withdraw() function
    fallback() external payable {}

    receive() external payable {}
}