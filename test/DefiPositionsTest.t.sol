pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TestConfigEthereum} from "./TestConfigEthereum.t.sol";
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
import {CometMainInterface} from "./interfaces/CometMainInterface.sol";
import {IPoolDataProvider} from "@aave/v3-core/contracts/interfaces/IPoolDataProvider.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

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

contract DefiPositionsTest is Test {
    using SafeERC20 for IERC20;

    IERC20 private usdc;
    IERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    ICreditDelegationToken private creditDelegationToken;
    CometMainInterface private comet;
    address private alice = makeAddr("alice");

    // Test task 1
    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/<ALCHEMY_API_KEY>", 20412144); // Using a specific block for consistency
        TestConfigEthereum testConfig = new TestConfigEthereum();
        
        usdc = IERC20(testConfig.getEthMainnetConfig().usdcAddress);
        weth = IERC20(testConfig.getEthMainnetConfig().wethAddress);

        // Set up the aavePool, tokenGateway, aaveOracle, uniswap quoter, uniswap router, and comet addresses
        aavePool = IPool(testConfig.getEthMainnetConfig().aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(testConfig.getEthMainnetConfig().wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(testConfig.getEthMainnetConfig().aavePriceOracleAddress);
        quoter = IQuoter(testConfig.getEthMainnetConfig().quoterAddress);
        swapRouter = ISwapRouter(testConfig.getEthMainnetConfig().swapRouterAddress);
        comet = CometMainInterface(testConfig.getEthMainnetConfig().cometAddress);

        // Fund the accounts with 1m weth and usdc
        deal(address(weth), alice, 100 * 1e18, false);
        deal(address(usdc), alice, 1_000_000 * 1e6, true);

        // Fund the accounts with 1 eth
        deal(alice, 1 * 1e18);
        // deal(bob, 1 * 1e18);
    }

    // (TODO: IMPORTANT) Put reentrancy guard for arbitrary ERC20 tokens
    // (TODO: IMPORTANT) Check for the specific assets that can be deposited in the pool | Handle cases which can't be deposited
    function testLeveraged() external returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // Check if assetLong or assetShort is ETH address (TODO: IMPORTANT)
        // Put checks if the asset addresses are valid or check if the pool exists for these assets
        address assetLong = address(weth); // To short weth, assetLong would become usdc and assetShort would become weth
        address assetShort = address(usdc);
        uint256 amount = 1 * 1e18;

        // TODO: Has to be done outside the contract (approving this contract to spend the user's asset)
        vm.prank(alice);
        IERC20(assetLong).approve(address(this), amount);
        IERC20(assetLong).safeTransferFrom(alice, address(this), amount);

        // 1. Deposit the assetLong in the pool
        IERC20(assetLong).approve(address(aavePool), amount);
        aavePool.supply(assetLong, amount, alice, 0);

        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);

        // 2. Borrow the asset 75% of the user's collateral
        uint8 assetDecimal = ERC20(assetShort).decimals();
        // Get the amount to borrow in the assetShort equivalent
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**assetDecimal) / (100 * priceOracle.getAssetPrice(assetShort));
        console.log("Amount to borrow: ", amountToBorrow);

        // TODO: How to get the creditDelegationToken address? (from IPoolAddressesProvider[0x2f39d218133afab8f2b819b1066c7e434ad94e9e])
        vm.prank(alice);
        ICreditDelegationToken(0x72E95b8931767C79bA4EeE721354d6E99a61D004).approveDelegation(address(this), amountToBorrow);
        aavePool.borrow(assetShort, amountToBorrow, 2, 0, alice); // The 'amountToBorrow' amount of assetShort is with this contract
        console.log("Amount could be borrowed successfully.");

        // 3. Swap the borrowed assetShort to assetLong
        IERC20(assetShort).approve(address(swapRouter), amountToBorrow);
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, 3000, amountToBorrow, 0);
        console.log("Amount out minimum: ", amountOutMinimum);
        uint160 sqrtPriceLimitX96 = 0; // TODO: Set the sqrtPriceLimitX96
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum, // 1% slippage
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle(params);

        // 4. Deposit the assetLong in the pool (would require permitV, permitR, permitS)
        IERC20(assetLong).approve(address(aavePool), amountOut);
        aavePool.supply(assetLong, amountOut, alice, 0);

        // 5. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);
    }

    function testLeveragedLongETH() external payable returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // Put checks if the assetShort addresses are valid or check if the pool exists for these assets
        address assetShort = address(usdc);
        uint256 amount = 1 * 1e18;

        // vm.prank(alice);
        // IERC20(assetLong).approve(address(this), amount);
        // IERC20(assetLong).safeTransferFrom(alice, address(this), amount);

        // 1. Deposit the assetLong in the pool
        vm.deal(address(this), amount);
        wrappedTokenGateway.depositETH{value: amount}(address(aavePool), alice, 0);


        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);

        // 2. Borrow the assetShort 75% of the user's collateral
        uint8 assetDecimal = ERC20(assetShort).decimals();
        // Get the amount to borrow in the assetShort equivalent
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**assetDecimal) / (100 * priceOracle.getAssetPrice(assetShort));
        console.log("Amount to borrow: ", amountToBorrow);

        
        vm.prank(alice);
        ICreditDelegationToken(0x72E95b8931767C79bA4EeE721354d6E99a61D004).approveDelegation(address(this), amountToBorrow);
        aavePool.borrow(assetShort, amountToBorrow, 2, 0, alice); // The 'amountToBorrow' amount of asset is with this contract
        console.log("Amount could be borrowed successfully.");

        // 3. Swap the borrowed assetShort to assetLong
        IERC20(assetShort).approve(address(swapRouter), amountToBorrow);
        address assetLong = address(weth);
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, 3000, amountToBorrow, 0);
        uint160 sqrtPriceLimitX96 = 0;
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle(params);
        IWETH9(address(weth)).withdraw(amountOut);

        // 4. Deposit the assetLong in the pool (would require permitV, permitR, permitS)
        wrappedTokenGateway.depositETH{value: amountOut}(address(aavePool), alice, 0);

        // 5. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);
    }
    
    function testLeveragedShortETH() external returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // Implement the leveraged short strategy
        // Put checks if the asset addresses are valid or check if the pool exists for these assets
        // Put checks if the assetShort addresses are valid or check if the pool exists for these assets
        address assetLong = address(usdc);
        address assetShort = address(weth);
        uint256 amount = 1000 * 1e6;

        vm.prank(alice);
        IERC20(assetLong).approve(address(this), amount);
        IERC20(assetLong).safeTransferFrom(alice, address(this), amount);

       // 1. Deposit the assetLong in the pool
        IERC20(assetLong).approve(address(aavePool), amount);
        aavePool.supply(assetLong, amount, alice, 0);

        // Get user balance of assetShort in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);

        // 2. Borrow the assetShort 75% of the user's collateral
        // Get the amount to borrow in the assetShort equivalent
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**18) / (100 * priceOracle.getAssetPrice(assetShort));
        console.log("Amount to borrow: ", amountToBorrow);
        
        vm.prank(alice); // Approve the creditDelegationToken(for ETH) to spend the amountToBorrow of assetShort
        ICreditDelegationToken(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE).approveDelegation(address(this), amountToBorrow);
        aavePool.borrow(assetShort, amountToBorrow, 2, 0, alice); // The 'amountToBorrow' amount of asset is with this contract
        console.log("Amount could be borrowed successfully.");

        // 3. Swap the borrowed assetShort to assetLong
        uint256 amountOutMinimum = quoter.quoteExactInputSingle(assetShort, assetLong, 3000, amountToBorrow, 0);
        uint160 sqrtPriceLimitX96 = 0;
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetShort,
            tokenOut: assetLong,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle{value: amountToBorrow}(params);

        // 4. Deposit the assetLong in the pool (would require permitV, permitR, permitS)
        IERC20(assetLong).approve(address(aavePool), amountOut);
        aavePool.supply(assetLong, amountOut, alice, 0);

        // 5. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);
    }

    // Required because of IWETH9.withdraw() function
    fallback() external payable {}

}