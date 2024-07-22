// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TestConfigEthereum, NetworkConfig} from "./TestConfigEthereum.t.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IWrappedTokenGatewayV3} from "@aave/v3-periphery/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IVariableDebtToken} from "@aave/v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {CometMainInterface} from "./interfaces/CometMainInterface.sol";

contract DefiEthereumTest is Test {
    uint256 private constant ORACLE_PRECISION = 1e8;
    uint256 private constant ETH_PRECISION = 1e18;

    NetworkConfig private activeNetworkConfig;
    IERC20 private usdc;
    IERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    ICreditDelegationToken private creditDelegationToken;
    CometMainInterface private comet;

    // Create user accounts
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    // Test task 1
    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/<ALCHEMY_API_KEY>", 20346809); // Using a specific block for consistency
        TestConfigEthereum testConfig = new TestConfigEthereum();

        // Set up the ETHEREUM_RPC_URL to fork the ethereum mainnet
        activeNetworkConfig = testConfig.getEthMainnetConfig();
        usdc = IERC20(activeNetworkConfig.usdcAddress);
        weth = IERC20(activeNetworkConfig.wethAddress);

        // Set up the aavePool, tokenGateway, aaveOracle, uniswap quoter, uniswap router, and comet addresses
        aavePool = IPool(activeNetworkConfig.aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(activeNetworkConfig.wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(activeNetworkConfig.aavePriceOracleAddress);
        quoter = IQuoter(activeNetworkConfig.quoterAddress);
        swapRouter = ISwapRouter(activeNetworkConfig.swapRouterAddress);
        creditDelegationToken = ICreditDelegationToken(activeNetworkConfig.creditDelegationToken);
        comet = CometMainInterface(activeNetworkConfig.cometAddress);

        // Fund the accounts with 1m usdc
        deal(address(usdc), alice, 1e6 * 1e6, true);
        deal(address(usdc), bob, 1e6 * 1e6, true);

        // Fund the accounts with 100 eth
        deal(alice, 100 * 1e18);
        deal(bob, 100 * 1e18);
    }

    // Deposit $1000 USDC to Aave on Ethereum
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
        // Also check for and validate if the user's collateral has increased in the protocol, to ensure the correct decimal values are being used
    }

    // Borrow $500 worth of ETH from Aave on Ethereum
    function testBorrowFromAaveOnEthereum() public {
        // Initial balance
        uint256 initialUSDCBalance = usdc.balanceOf(alice);
        uint256 initialETHBalance = alice.balance;

        // Deposit to AAVE
        uint256 amountToDeposit = 1000 * 1e6; // 1000 USDC
        vm.startPrank(alice);
        // Approve AAVE to spend our USDC
        usdc.approve(address(aavePool), type(uint256).max);

        // Deposit to AAVE
        aavePool.supply(address(usdc), amountToDeposit, alice, 0);
        vm.stopPrank();

        // Get user account data
        (uint256 totalCollateralETH, uint256 totalDebtETH, uint256 availableBorrowsETH,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total Collateral (ETH):", totalCollateralETH);
        console.log("Total Debt (ETH):", totalDebtETH);
        console.log("availableBorrowsETH:", availableBorrowsETH);

        uint256 amountToBorrow = 500; // 500 USDC
        // Get eth price from aave
        uint256 usdcPriceInEth = priceOracle.getAssetPrice(address(weth));
        console.log("usdcPriceInEth: ", usdcPriceInEth);
        uint256 ethEquivalentInWei = amountToBorrow * ETH_PRECISION * ORACLE_PRECISION / usdcPriceInEth;
        console.log("ethEquivalentInWei: ", ethEquivalentInWei);

        // Check if borrow amount is within limits
        // require(ethEquivalentInWei <= totalCollateralETH, "Borrow amount exceeds available borrows");

        vm.startPrank(alice);
        // Borrow from AAVE
        creditDelegationToken.approveDelegation(address(wrappedTokenGateway), ethEquivalentInWei);
        wrappedTokenGateway.borrowETH(address(aavePool), ethEquivalentInWei, 2, 0);
        vm.stopPrank();

        // Final balance
        uint256 finalUSDCBalance = usdc.balanceOf(alice);
        uint256 finalETHBalance = alice.balance;

        // Check that our USDC balance increased by the borrow amount
        assertTrue(finalETHBalance > initialETHBalance, "ETH balance did not increase");
        console.log("initialETHBalance: ", initialETHBalance);
        console.log("finalETHBalance: ", finalETHBalance);
        // Check that our ETH balance increased by the borrow amount
        // assertEq(finalETHBalance - initialETHBalance, ethEquivalentInWei);
    }

    // Swap $500 worth of ETH to USDC on Uniswap V3
    function testEthToUsdcSwapOnEthereum() public {
        // Initial balance of USDC and ETH
        uint256 initialUsdcBalance = usdc.balanceOf(alice);
        uint256 initialEthBalance = alice.balance;

        // Get the price of 500 usdc in eth
        uint256 usdcAmount = 500 * 1e6; // 500 USDC with 6 decimal places
        uint256 ethAmount = quoter.quoteExactInputSingle(
            address(usdc),
            address(weth),
            3000, // 0.3% fee pool
            usdcAmount * 1010 / 1000, // We need to add 1% buffer
            0 // We don't need a price limit for a quote
        );

        // Set up the params for the swap
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(weth), // We use WETH address, but send ETH
            tokenOut: address(usdc),
            fee: 3000, // 0.3% fee tier
            recipient: alice,
            deadline: block.timestamp + 10 minutes,
            amountOut: usdcAmount,
            amountInMaximum: ethAmount,
            sqrtPriceLimitX96: 0
        });

        vm.startPrank(alice);
        // Execute the swap
        uint256 ethAmountIn = swapRouter.exactOutputSingle{value: ethAmount}(params);
        // Refund excess ETH to the msg.sender, Alice here
        if (ethAmountIn < ethAmount) {
            payable(msg.sender).transfer(ethAmount - ethAmountIn);
        }
        vm.stopPrank();

        // Final balance of USDC and ETH
        uint256 finalUsdcBalance = usdc.balanceOf(alice);
        uint256 finalEthBalance = alice.balance;
        // Check that our USDC balance decreased by the swap amount
        assertEq(finalUsdcBalance - initialUsdcBalance, usdcAmount);
        assertGe(initialEthBalance - ethAmountIn, finalEthBalance); // Greater because some eth would be used as gas
    }

    // Deposit $500 USDC on Compound V3
    function testDepositOnEthereum() external {
        // Supply $500 usdc in Compound
        uint256 supplyAmount = 500 * 1e6;
        // Get user's USDC balance before supply
        uint256 aliceUsdcBalanceBefore = usdc.balanceOf(alice);

        // Approve the contract to spend WETH
        vm.startPrank(alice);
        usdc.approve(address(comet), supplyAmount);
        // Supply the WETH in Compound
        comet.supply(address(usdc), supplyAmount);
        vm.stopPrank();

        // Get user's WETH balance after supply
        uint256 aliceUsdcBalanceAfter = usdc.balanceOf(alice);

        // Check if the user's USDC balance has decreased by 500
        assertEq(aliceUsdcBalanceBefore - aliceUsdcBalanceAfter, supplyAmount);
    }
}
