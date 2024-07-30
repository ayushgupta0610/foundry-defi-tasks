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
        // deal(address(weth), address(this), 100 * 1e18, false);

        // Fund the accounts with 100 eth
        deal(alice, 1 * 1e18);
        // deal(bob, 1 * 1e18);
    }

    // (TODO: IMPORTANT) Check if reetrancy needs to be put due to arbitrary ERC20 tokens
    // (TODO: IMPORTANT) Check if the function is following CEI pattern
    // (TODO: IMPORTANT) Check for the specific assets that can be deposited in the pool | Handle cases which can't be deposited
    function testLeveragedLong() external returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // Check if assetLong or asset is ETH address (TODO: IMPORTANT)
        // Put checks if the asset addresses are valid or check if the pool exists for these assets
        address assetLong = address(weth);
        address asset = address(usdc);
        uint256 amount = 1 * 1e18;

        // TODO: Has to be done outside the contract (approving this contract to spend the user's asset)
        vm.prank(alice);
        IERC20(assetLong).approve(address(this), amount);
        IERC20(assetLong).safeTransferFrom(alice, address(this), amount);

        // 1. Deposit the assetLong in the pool
        IERC20(assetLong).approve(address(aavePool), amount);
        aavePool.supply(assetLong, amount, alice, 0);

        // Get user balance of asset in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);

        // 2. Borrow the asset 75% of the user's collateral
        uint8 assetDecimal = ERC20(asset).decimals();
        // Get the amount to borrow in the asset equivalent
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**assetDecimal) / (100 * priceOracle.getAssetPrice(asset));
        console.log("Amount to borrow: ", amountToBorrow);

        // TODO: How to get the creditDelegationToken address? (from IPoolAddressesProvider[0x2f39d218133afab8f2b819b1066c7e434ad94e9e])
        vm.prank(alice);
        ICreditDelegationToken(0x72E95b8931767C79bA4EeE721354d6E99a61D004).approveDelegation(address(this), amountToBorrow);
        aavePool.borrow(asset, amountToBorrow, 2, 0, alice); // The 'amountToBorrow' amount of asset is with this contract
        console.log("Amount could be borrowed successfully.");

        // 3. Swap the borrowed asset to assetLong
        IERC20(asset).approve(address(swapRouter), amountToBorrow);
        uint256 amountOutMinimum = 0; // TODO: Set the minimum amountOut
        uint160 sqrtPriceLimitX96 = 0; // TODO: Set the sqrtPriceLimitX96
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: asset,
            tokenOut: assetLong,
            fee: 3000,
            recipient: alice,
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        uint256 amountOut = swapRouter.exactInputSingle(params);

        // 4. Deposit the assetLong in the pool (would require permitV, permitR, permitS)
        vm.prank(alice);
        IERC20(assetLong).approve(address(this), amountOut);

        IERC20(assetLong).safeTransferFrom(alice, address(this), amountOut);
        IERC20(assetLong).approve(address(aavePool), amountOut);
        aavePool.supply(assetLong, amountOut, alice, 0);

        // 5. Check the users total collateral and total debt in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) = aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);
    }

    function testLeveragedLongETH() external payable returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase) {
        // Put checks if the asset addresses are valid or check if the pool exists for these assets
        address asset = address(usdc);
        uint256 amount = 1 * 1e18;

        // vm.prank(alice);
        // IERC20(assetLong).approve(address(this), amount);
        // IERC20(assetLong).safeTransferFrom(alice, address(this), amount);

        // 1. Deposit the assetLong in the pool
        vm.deal(address(this), amount);
        wrappedTokenGateway.depositETH{value: amount}(address(aavePool), alice, 0);


        // Get user balance of asset in the pool
        (totalCollateralBase, totalDebtBase, availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total collateral: ", totalCollateralBase);
        console.log("Total debt: ", totalDebtBase);
        console.log("Available borrows: ", availableBorrowsBase);

        // 2. Borrow the asset 75% of the user's collateral
        uint8 assetDecimal = ERC20(asset).decimals();
        // Get the amount to borrow in the asset equivalent
        uint256 amountToBorrow = (totalCollateralBase * 75 * 10**assetDecimal) / (100 * priceOracle.getAssetPrice(asset));
        console.log("Amount to borrow: ", amountToBorrow);

        
        vm.prank(alice);
        ICreditDelegationToken(0x72E95b8931767C79bA4EeE721354d6E99a61D004).approveDelegation(address(this), amountToBorrow);
        aavePool.borrow(asset, amountToBorrow, 2, 0, alice); // The 'amountToBorrow' amount of asset is with this contract
        console.log("Amount could be borrowed successfully.");

        // 3. Swap the borrowed asset to assetLong
        IERC20(asset).approve(address(swapRouter), amountToBorrow);
        uint256 amountOutMinimum = 0;
        uint160 sqrtPriceLimitX96 = 0;
        address assetLong = address(weth);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: asset,
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
    
    function testLeveragedShort(address assetShort, address asset, uint256 amount) external {
        // Implement the leveraged short strategy
        // Check if assetLong or asset is ETH address
        // Put checks if the asset addresses are valid or check if the pool exists for these assets
    }

    fallback() external payable {}

}