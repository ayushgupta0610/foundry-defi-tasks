// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {TestConfigEthereum, NetworkConfig} from "./TestConfigEthereum.t.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IWrappedTokenGatewayV3} from "@aave/v3-periphery/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";


contract DefiEthereumTest is Test {

    uint256 constant private ORACLE_PRECISION = 1e8;
    uint256 constant private ETH_PRECISION = 1e18;

    NetworkConfig private activeNetworkConfig;
    IERC20 private usdc;
    IERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;

    // Create user accounts
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    // Test task 1
    function setUp() public {
        TestConfigEthereum testConfig = new TestConfigEthereum();

        // Set up the ETHEREUM_RPC_URL to fork the ethereum mainnet
        activeNetworkConfig = testConfig.getEthMainnetConfig();
        usdc = IERC20(activeNetworkConfig.usdcAddress);
        weth = IERC20(activeNetworkConfig.wethAddress);

        // Set up the aavePool, tokenGateway, aaveOracle, uniswap quoter, uniswap router,  addresses
        aavePool = IPool(activeNetworkConfig.aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(activeNetworkConfig.wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(activeNetworkConfig.aavePriceOracleAddress);
        quoter = IQuoter(activeNetworkConfig.quoterAddress);
        swapRouter = ISwapRouter(activeNetworkConfig.swapRouterAddress);

        // Fund the accounts with 1m usdc
        deal(address(usdc), alice, 1e6*1e6, true);
        deal(address(usdc), bob, 1e6*1e6, true);

        // Fund the accounts with 100 eth
        deal(alice, 100*1e18);
        deal(bob, 100*1e18);
    }

    
    function testDepositToAave() public {
        uint256 amountToDeposit = 1000 * 1e6; // 1000 USDC

        // Initial balance
        uint256 initialBalance = usdc.balanceOf(alice);

        vm.startPrank(alice);
        // Approve AAVE to spend our USDC
        usdc.approve(address(aavePool), amountToDeposit);
        // Deposit to AAVE
        aavePool.supply(address(usdc), amountToDeposit, alice, 0);

        // Final balance
        uint256 finalBalance = usdc.balanceOf(alice);

        // Check that our USDC balance decreased by the deposit amount
        assertEq(initialBalance - finalBalance, amountToDeposit);
        // Also check for and validate if the user's collateral has increased in the protocol, to ensure the correct decimal values

    }

    function testBorrowFromAave() public {
        // Initial balance
        uint256 initialUSDCBalance = weth.balanceOf(alice);
        uint256 initialETHBalance = alice.balance;
        
        // Deposit to AAVE
        uint256 amountToDeposit = 5000 * 1e6; // 5000 USDC
        vm.startPrank(alice);
        // Approve AAVE to spend our USDC
        usdc.approve(address(aavePool), amountToDeposit);
        // Deposit to AAVE
        aavePool.supply(address(usdc), amountToDeposit, alice, 0);

        // Get user account data
        (uint256 totalCollateralETH, uint256 totalDebtETH, uint256 availableBorrowsETH, , , ) = aavePool.getUserAccountData(alice);
        console.log("Total Collateral (ETH):", totalCollateralETH);
        console.log("Total Debt (ETH):", totalDebtETH);
        console.log("Available Borrows (ETH):", availableBorrowsETH);

        uint256 amountToBorrow = 500; // 500 USDC
        // Get eth price from aave
        uint256 usdcPriceInEth = priceOracle.getAssetPrice(address(weth));
        uint256 ethEquivalentInWei = amountToBorrow * ETH_PRECISION * ORACLE_PRECISION / usdcPriceInEth;
        console.log("ethEquivalentInWei: ", ethEquivalentInWei);

        // Check if borrow amount is within limits
        require(ethEquivalentInWei <= availableBorrowsETH, "Borrow amount exceeds available borrows");

        // Borrow from AAVE
        wrappedTokenGateway.borrowETH(address(aavePool), 1e6, 2, 0);
        vm.stopPrank();

        // Final balance
        uint256 finalUSDCBalance = usdc.balanceOf(alice);
        uint256 finalETHBalance = alice.balance;

        // Check that our USDC balance increased by the borrow amount
        assertEq(initialUSDCBalance - amountToDeposit, finalUSDCBalance);
        console.log("initialETHBalance: ", initialETHBalance);
        console.log("finalETHBalance: ", finalETHBalance);
        // Check that our ETH balance increased by the borrow amount
        // assertEq(finalETHBalance - initialETHBalance, ethEquivalentInWei);
    }

    // Swap 
    function testUniswapSwapOnEthereum() public {
        // Initial balance
        uint256 initialBalance = usdc.balanceOf(alice);

        // Get the price of 1000 usdc in eth
        uint256 usdcAmount = 1000 * 1e6; // 1000 USDC with 6 decimal places

        uint256 ethAmount = quoter.quoteExactInputSingle(
            address(usdc),
            address(weth),
            3000, // 0.3% fee pool
            1200 * 1e6,
            0 // We don't need a price limit for a quote
        );
        console.log("ethAmount: ", ethAmount);
        // uint256 ethAmount = 1 ether;

        // Set up the params for the swap
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(weth), // We use WETH address, but send ETH
            tokenOut: address(usdc),
            fee: 3000, // 0.3% fee tier
            recipient: alice,
            deadline: block.timestamp + 10 minutes,
            amountOut: 1000 * 1e6, // 1000 USDC
            amountInMaximum: ethAmount,
            sqrtPriceLimitX96: 0
        });

        vm.startPrank(alice);
        // Execute the swap
        uint256 ethAmountIn = swapRouter.exactOutputSingle{value: ethAmount}(params);

        // Refund excess ETH to the contract
        if (ethAmountIn < ethAmount) {
            payable(msg.sender).transfer(ethAmount - ethAmountIn);
        }
        vm.stopPrank();

        // Final balance
        uint256 finalBalance = usdc.balanceOf(alice);
        // Check that our USDC balance decreased by the swap amount
        console.log("finalBalance: ", finalBalance);
        console.log("initialBalance: ", initialBalance);
    }

}