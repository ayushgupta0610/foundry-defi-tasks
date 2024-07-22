// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TestConfig, NetworkConfig} from "./TestConfigOnPolygon.t.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DefiAdapter} from "../src/polygon/DefiAdapter.sol";
import {ILendingPool} from "../src/polygon/interfaces/ILendingPool.sol";
import {IUniswapV2Router02} from "../src/polygon/interfaces/IUniswapV2Router02.sol";
import {ICometMain} from "../src/polygon/interfaces/ICometMain.sol";
import {IPriceOracleGetter} from "../src/polygon/interfaces/IPriceOracleGetter.sol";

contract DefiAdapterTest is Test {
    using SafeERC20 for IERC20;

    NetworkConfig private activeNetworkConfig;
    IERC20 private usdc;
    IERC20 private weth;
    ILendingPool private lendingPool;
    IUniswapV2Router02 private routerV2;
    ICometMain private comet;
    IPriceOracleGetter private priceOracle;

    // Create user accounts
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    // Test task 1
    function setUp() public {
        TestConfig testConfig = new TestConfig();

        // Set up the POLYGON_RPC_URL to fork the mainnet
        activeNetworkConfig = testConfig.getPolygonMainnetConfig();
        usdc = IERC20(activeNetworkConfig.usdcAddress);
        weth = IERC20(activeNetworkConfig.wethAddress);

        // Set up the lendingPool, routerV2 and comet addresses
        lendingPool = ILendingPool(activeNetworkConfig.aavePoolAddress);
        routerV2 = IUniswapV2Router02(activeNetworkConfig.routerV2Address);
        comet = ICometMain(activeNetworkConfig.cometAddress);
        priceOracle = IPriceOracleGetter(activeNetworkConfig.priceOracleAddress);

        // Fund the accounts with 1m usdc
        deal(address(usdc), alice, 1e6 * 1e6, true);
        deal(address(usdc), bob, 1e6 * 1e6, true);

        // Fund the accounts with 100 weth
        deal(address(weth), alice, 100 * 1e18, true);
        deal(address(weth), bob, 100 * 1e18, true);
    }

    function testAaveDeposit() external {
        // Deposit 1000 USDC in Aave
        // Get user's USDC balance before deposit
        uint256 aliceUsdcBalanceBefore = usdc.balanceOf(alice);
        uint256 amount = 1000 * 1e6;
        (uint256 totalCollateralETHBefore,,,,,) = lendingPool.getUserAccountData(alice);
        console.log("totalCollateralETHBefore: ", totalCollateralETHBefore);

        // Approve the contract to spend USDC
        vm.startPrank(alice);
        usdc.approve(address(lendingPool), amount);

        // Deposit the USDC in Aave
        lendingPool.deposit(address(usdc), amount, alice, 0);

        // Get user's USDC balance after deposit
        uint256 aliceUsdcBalanceAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        // Check if the user's USDC balance has decreased by 1000
        assertEq(aliceUsdcBalanceBefore - aliceUsdcBalanceAfter, amount);
        // Check if user's deposit on Aave has increased by 1000
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = lendingPool.getUserAccountData(alice);
        console.log("totalCollateralETH: ", totalCollateralETH);
        console.log("totalDebtETH: ", totalDebtETH);
        console.log("availableBorrowsETH: ", availableBorrowsETH);
        console.log("currentLiquidationThreshold: ", currentLiquidationThreshold);
        console.log("ltv: ", ltv);
        console.log("healthFactor: ", healthFactor);
    }

    function testAaveBorrow() external {
        // First deposit 1000 USDC in Aave
        uint256 depositAmount = 1000 * 1e6;
        // Approve the contract to spend USDC
        vm.startPrank(alice);
        usdc.approve(address(lendingPool), depositAmount);
        // Get user's USDC balance before borrow
        uint256 aliceUsdcBalanceBefore = usdc.balanceOf(alice);
        // Deposit the USDC in Aave
        lendingPool.deposit(address(usdc), depositAmount, alice, 0);
        vm.stopPrank();

        // Borrow $500 worth of eth from Aave
        uint256 borrowAmount = 500;
        // Get eth price from Aave
        uint256 usdcPriceInEth = priceOracle.getAssetPrice(address(usdc));
        console.log("usdcPriceInEth: ", usdcPriceInEth);
        uint256 ethEquivalentInWei = borrowAmount * usdcPriceInEth;

        // Get user's WETH balance before borrow
        uint256 aliceWethBalanceBefore = weth.balanceOf(alice);

        vm.prank(alice);
        lendingPool.borrow(address(weth), ethEquivalentInWei, 2, 0, alice);

        // Get user's USDC balance after borrow
        uint256 aliceUsdcBalanceAfter = usdc.balanceOf(alice);
        // Get user's WETH balance after borrow
        uint256 aliceWethBalanceAfter = weth.balanceOf(alice);

        // Check if the user's USDC balance has decreased by 500
        assertEq(aliceUsdcBalanceBefore - aliceUsdcBalanceAfter, depositAmount);
        // Check if user's WETH balance has increased by 500/ethPrice
        assertEq(aliceWethBalanceAfter - aliceWethBalanceBefore, ethEquivalentInWei);
    }

    function testUniswapSwap() external {
        // Swap $500 worth of ETH to USDC
        uint256 swapAmount = 500;
        // Get eth price from Aave
        uint256 usdcPriceInEth = priceOracle.getAssetPrice(address(usdc)); // Price fetched from Aave, which is fetching from Chainlink
        console.log("usdcPriceInEth: ", usdcPriceInEth);
        uint256 ethEquivalentInWei = swapAmount * usdcPriceInEth;

        // Get user's WETH balance before swap
        uint256 aliceWethBalanceBefore = weth.balanceOf(alice);
        // Get user's USDC balance before swap
        uint256 aliceUsdcBalanceBefore = usdc.balanceOf(alice);

        // Swap the WETH to USDC
        vm.startPrank(alice);
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);
        uint256 amountOutMin = swapAmount * 1e6 * 995 / 1000; // 0.5% slippage
        weth.approve(address(routerV2), ethEquivalentInWei);
        routerV2.swapExactTokensForTokens(ethEquivalentInWei, amountOutMin, path, alice, block.timestamp);
        vm.stopPrank();

        // Get user's WETH balance after swap
        uint256 aliceWethBalanceAfter = weth.balanceOf(alice);
        // Get user's USDC balance after swap
        uint256 aliceUsdcBalanceAfter = usdc.balanceOf(alice);

        // Check if the user's WETH balance has decreased by 500/ethPrice
        assertEq(aliceWethBalanceBefore - aliceWethBalanceAfter, ethEquivalentInWei);
        // Check if user's USDC balance has increased by 500
        assertGe(aliceUsdcBalanceAfter - aliceUsdcBalanceBefore, amountOutMin);
    }

    function testCompoundDeposit() external {
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
