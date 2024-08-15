// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TestConfigEthereum} from "./TestConfigEthereum.t.sol";
import {RepayViaLPFees} from "../src/ethereum/rareskills/RepayViaLPFees.sol";
import {INonfungiblePositionManager} from "../src/ethereum/rareskills/interfaces/INonfungiblePositionManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol"; 
import {TickMath} from "../src/ethereum/rareskills/libraries/TickMath.sol";
import {FullMath} from "../src/ethereum/rareskills/libraries/FullMath.sol";
import {NetworkConfig} from "../src/ethereum/NetworkConfig.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";


contract RepayViaLPFeesTest is Test {
    using SafeTransferLib for address;
    
    uint256 constant AAVE_ORACLE_PRECISION = 1e8;
    uint24 constant UNISWAP_FEE = 3000;
    uint24 constant LP_INTEREST_RATE = 3000;
    address immutable alice = makeAddr("Alice");
    address constant AUSDC_VARIABLE_DEBT_TOKEN = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    address constant AWETH_VARIABLE_DEBT_TOKEN = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;
    address constant AUSDC_TOKEN = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    ERC20 private usdc;
    ERC20 private weth;
    IPriceOracleGetter private priceOracle;
    RepayViaLPFees private repayViaLPFees;
    TestConfigEthereum private testConfigEthereum;
    IPool private aavePool;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    INonfungiblePositionManager private positionManager;

    function setUp() public {
        uint256 blockNumber = vm.envUint("BLOCK_NUMBER");
        string memory rpcUrl = vm.envString("ACTIVE_RPC_URL");
        vm.createSelectFork(rpcUrl, blockNumber);
         // Deploy the contract
        testConfigEthereum = new TestConfigEthereum();
        (address usdcAddress, address wethAddress, address aavePoolAddress, address wrappedTokenGatewayAddress, address creditDelegationToken, address aavePriceOracleAddress, address quoterAddress, address swapRouterAddress, address cometAddress, address positionManagerAddress) = testConfigEthereum.activeNetworkConfig();
        
        usdc = ERC20(usdcAddress);
        weth = ERC20(wethAddress);
        priceOracle = IPriceOracleGetter(aavePriceOracleAddress);

        // Deploy RepayViaLPFees contract
        NetworkConfig memory activeNetwork = NetworkConfig({
            usdcAddress: usdcAddress,
            wethAddress: wethAddress,
            aavePoolAddress: aavePoolAddress,
            wrappedTokenGatewayAddress: wrappedTokenGatewayAddress,
            creditDelegationToken: creditDelegationToken,
            aavePriceOracleAddress: aavePriceOracleAddress,
            quoterAddress: quoterAddress,
            swapRouterAddress: swapRouterAddress,
            cometAddress: cometAddress,
            positionManagerAddress: positionManagerAddress
        });
        repayViaLPFees = new RepayViaLPFees(activeNetwork);
        aavePool = IPool(aavePoolAddress);
        quoter = IQuoter(quoterAddress);
        swapRouter = ISwapRouter(swapRouterAddress);
        positionManager = INonfungiblePositionManager(positionManagerAddress);
    }

    // function to test deposit usdc into aave
    function testDepositUsdcOnAave() public {
        uint256 usdcAmount = 1000 * 1e6;
        deal(address(usdc), alice, usdcAmount, true);
        vm.startPrank(alice);
        usdc.approve(address(repayViaLPFees), usdcAmount);
        repayViaLPFees.depositAssetOnAave(address(usdc), usdcAmount);
        vm.stopPrank();
        (uint256 totalCollateralBase,,,,,) =
            aavePool.getUserAccountData(alice);
        console.log("Total collateral base: ", totalCollateralBase);
        assertGe(totalCollateralBase, usdcAmount, "User should have deposited usdc");
    }

    // function to test borrow eth from aave
    function testBorrowEthFromAave() public {
        uint256 usdcAmount = 1000 * 1e6;
        deal(address(usdc), alice, usdcAmount, true);
        vm.startPrank(alice);
        usdc.approve(address(repayViaLPFees), usdcAmount);
        repayViaLPFees.depositAssetOnAave(address(usdc), usdcAmount);

        (uint256 totalCollateralBase,, uint256 availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        // calculate the amount of eth that can be borrowed
        uint256 ethPrice = priceOracle.getAssetPrice(address(weth));
        uint256 amountToBorrow = (availableBorrowsBase * 1e18) / ethPrice;
        console.log("Amount to borrow: ", amountToBorrow);
        // approveDelegation the repayViaLPFees contract to borrow on behalf of alice
        ICreditDelegationToken(AWETH_VARIABLE_DEBT_TOKEN).approveDelegation(address(repayViaLPFees), type(uint256).max);
        repayViaLPFees.borrowEthFromAave(amountToBorrow, alice);
        vm.stopPrank();
        console.log("Alice balance: ", alice.balance);
        assertGt(alice.balance, 0, "Alice should have borrowed eth");
    }

    function testSwapAssetsOnUniswap() public {
        deal(address(weth), alice, 1e18, false);
        uint256 userBalanceBefore = usdc.balanceOf(alice);
        uint256 wethBalance = weth.balanceOf(alice);
        console.log("Balance of msg.sender: ", wethBalance);
        vm.startPrank(alice);
        weth.approve(address(repayViaLPFees), wethBalance);
        // Get the amount of assetOut that will be received outside of the contract
        uint256 amountOut = quoter.quoteExactInputSingle(
            address(weth),
            address(usdc),
            UNISWAP_FEE,
            wethBalance,
            0
        );
        console.log("Amount out: ", amountOut);
        uint256 exactUsdcOut = repayViaLPFees.swapAssetsOnUniswap(address(weth), wethBalance, address(usdc), amountOut, block.timestamp);
        vm.stopPrank();
        uint256 userBalanceAfter = usdc.balanceOf(alice);
        assertEq(userBalanceAfter, userBalanceBefore + exactUsdcOut, "User should have more usdc after the swap");
    }

    // function to test swap ausdc back to usdc
    function testDepositBorrowAddLiquidity() public {
        uint256 usdcAmount = 1000 * 1e6;
        deal(address(usdc), alice, usdcAmount, true);
        vm.startPrank(alice);
        usdc.approve(address(repayViaLPFees), usdcAmount);
        repayViaLPFees.depositAssetOnAave(address(usdc), usdcAmount);
        // approveDelegation the repayViaLPFees contract to borrow on behalf of alice
        ICreditDelegationToken(AWETH_VARIABLE_DEBT_TOKEN).approveDelegation(address(repayViaLPFees), type(uint256).max);
        uint256 ausdcBalance = ERC20(AUSDC_TOKEN).balanceOf(alice);
        ERC20(AUSDC_TOKEN).transfer(address(this), ausdcBalance/100); // TODO: Modify it to max ausdc balance that can be transferred keeping ltv in mind
        vm.stopPrank();
        (,, uint256 availableBorrowsBase,,,) =
            aavePool.getUserAccountData(alice);
        // calculate the amount of eth that can be borrowed
        uint256 ethPrice = priceOracle.getAssetPrice(address(weth));
        uint256 amountToBorrow = (availableBorrowsBase * 1e18) / ethPrice;
        console.log("amountToBorrow: ", amountToBorrow);
        repayViaLPFees.borrowEthFromAave(amountToBorrow, alice);
        console.log("Contract's eth balance: ", address(this).balance);
        uint256 contractAusdcbalance = ERC20(AUSDC_TOKEN).balanceOf(address(this));
        console.log("Contract's ausdc balance: ", contractAusdcbalance);
        aavePool.withdraw(address(usdc), contractAusdcbalance, address(this)); // converts the ausc to usdc
        console.log("Contract's usdc balance: ", usdc.balanceOf(address(this)));
        uint256 amountUSDC = usdc.balanceOf(address(this));
        console.log("Amount of USDC: ", amountUSDC);
        uint256 amountWETH = amountToBorrow;
        console.log("Amount of ETH: ", amountWETH);
        usdc.approve(address(repayViaLPFees), amountUSDC);
        uint256 minPrice = 3000;
        uint256 maxPrice = 4000;
        uint8 token0Decimal = 6;
        uint8 token1Decimal = 18;
        int24 tickSpacing = 60; // Common tick spacing, adjust as needed
        (int24 tickLower, int24 tickUpper) = repayViaLPFees.getLowerAndUpperTicks(minPrice, maxPrice, token0Decimal, token1Decimal, tickSpacing);
        console.log("tickLower: ", tickLower);
        console.log("tickUpper: ", tickUpper);
        (,, uint256 actualUsdcAdded, uint256 actualWethAdded) = 
            repayViaLPFees.addLiquidity{value: amountWETH}(amountUSDC, 0, amountWETH, 0, tickLower, tickUpper, LP_INTEREST_RATE, address(this), block.timestamp + 300);
        // Get liquidity position of this contract
        // (
        //     uint128 liquidity,
        //     uint256 feeGrowthInside0LastX128,
        //     uint256 feeGrowthInside1LastX128,
        //     uint128 tokensOwed0,
        //     uint128 tokensOwed1
        // ) = uniswapUsdcWethPool.positions(keccak256(abi.encodePacked(address(this), tickLower, tickUpper))); // Get this address from uniswap factory

    }

    function testAddLiquidity() public {
        uint256 amountUSDC = 1000 * 1e6;
        uint256 amountETH = 1e18;
        // Add liquidity
        deal(address(usdc), address(this), amountUSDC, true);
        deal(address(this), amountETH);

        // Approve repayViaLPFees to spend USDC
        usdc.approve(address(repayViaLPFees), amountUSDC);

        uint256 minPrice = 2000;
        uint256 maxPrice = 4000;
        uint8 token0Decimal = 6;
        uint8 token1Decimal = 18;
        int24 tickSpacing = 60; // Common tick spacing, adjust as needed
        (int24 tickLower, int24 tickUpper) = repayViaLPFees.getLowerAndUpperTicks(minPrice, maxPrice, token0Decimal, token1Decimal, tickSpacing);

        (uint256 tokenId,, uint256 actualUsdcAdded, uint256 actualWethAdded) = 
            repayViaLPFees.addLiquidity{value: amountETH}(amountUSDC, 0, amountETH, 0, tickLower, tickUpper, LP_INTEREST_RATE, address(this), block.timestamp + 300);
        console.log("tokenId: ", tokenId);
        console.log("actualUsdcAdded: ", actualUsdcAdded);
        console.log("actualWethAdded: ", actualWethAdded);
        // Mock a couple of weth and usdc swaps to increase the liquidity
        vm.roll(block.number + 100000);
        vm.warp(block.timestamp + 10000);
        // Swap 1
        uint256 wethAmount = 100 * 1e18;
        weth.approve(address(repayViaLPFees), wethAmount);
        deal(address(weth), address(this), wethAmount, false);
        uint256 amountOut = quoter.quoteExactInputSingle(
            address(weth),
            address(usdc),
            UNISWAP_FEE,
            wethAmount,
            0
        );
        uint256 exactUsdcOut = repayViaLPFees.swapAssetsOnUniswap(address(weth), wethAmount, address(usdc), amountOut, block.timestamp);
        console.log("exactUsdcOut: ", exactUsdcOut);
        // Swap 2
        uint256 usdcAmount = 100000000 * 1e6;
        usdc.approve(address(repayViaLPFees), usdcAmount);
        deal(address(usdc), address(this), usdcAmount, true);
        amountOut = quoter.quoteExactInputSingle(
            address(usdc),
            address(weth),
            UNISWAP_FEE,
            usdcAmount,
            0
        );
        uint256 exactWethOut = repayViaLPFees.swapAssetsOnUniswap(address(usdc), usdcAmount, address(weth), amountOut, block.timestamp);
        console.log("exactWethOut: ", exactWethOut);
        // Collect LP fees
        vm.roll(block.number + 100000);
        vm.warp(block.timestamp + 10000);
        // Approve repayViaLPFees to transferFrom NFT token with tokenId
        positionManager.approve(address(repayViaLPFees), tokenId);
        repayViaLPFees.collectLPFees(tokenId, address(this));
        console.log("USDC balance: ", usdc.balanceOf(address(this)));
        console.log("WETH balance: ", weth.balanceOf(address(this)));
    }

    

    function testDealAUsdcAndTransfer() public {

    }
    
    // put eth and usdc as lp position in uniswap
    // pay the debt as LP positions make profit - automate this (via Gelato or Chainlink)

    receive() external payable {}
}  