// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TestConfigEthereum} from "./TestConfigEthereum.t.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IWrappedTokenGatewayV3} from "@aave/v3-periphery/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IVariableDebtToken} from "@aave/v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {IFlashLoanSimpleReceiver} from "@aave/v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {FlashLoanContract, NetworkConfig} from "../src/ethereum/FlashLoanContract.sol";
import {CometMainInterface} from "../src/ethereum/rareskills/interfaces/CometMainInterface.sol";
import {DataTypes} from "@aave/v3-core/contracts/protocol/libraries/types/DataTypes.sol";

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
    FlashLoanContract private flashLoanContract;
    CometMainInterface private comet;

    // Create user accounts
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    // Test task 1
    function setUp() public {
        string memory rpcUrl = vm.envString("ACTIVE_RPC_URL");
        vm.createSelectFork(rpcUrl);
        TestConfigEthereum testConfig = new TestConfigEthereum();

        // Set up the ACTIVE_RPC_URL to fork the ethereum mainnet
        activeNetworkConfig = testConfig.getEthMainnetConfig();
        usdc = IERC20(activeNetworkConfig.usdcAddress);
        weth = IERC20(activeNetworkConfig.wethAddress);

        // Set up the aavePool, tokenGateway, aaveOracle, uniswap quoter, uniswap router, and comet addresses
        aavePool = IPool(activeNetworkConfig.aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(activeNetworkConfig.wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(activeNetworkConfig.aavePriceOracleAddress);
        quoter = IQuoter(activeNetworkConfig.quoterAddress);
        swapRouter = ISwapRouter(activeNetworkConfig.swapRouterAddress);
        if (address(flashLoanContract) == address(0)) {
            flashLoanContract = new FlashLoanContract(activeNetworkConfig, alice);
        }
        comet = CometMainInterface(activeNetworkConfig.cometAddress);

        // Fund the accounts with 1m usdc
        deal(address(usdc), alice, 1000 * 1e6, true);
        deal(address(usdc), bob, 1000 * 1e6, true);

        // Fund the accounts with 100 eth
        deal(alice, 1 * 1e18);
        deal(bob, 1 * 1e18);
    }

    function testMigratePosition() external {
        // Borrow $500 USDC from Aave
        address asset = address(usdc);
        uint256 amountToDeposit = 1000 * 1e6; // $1000 USDC
        uint256 amountToBorrow = 142 * 1e15; // $500 worth of ETH (Assuming ETH is for $3500)
        vm.startPrank(alice);
        usdc.approve(address(aavePool), amountToDeposit);
        aavePool.supply(address(usdc), amountToDeposit, alice, 0);
        aavePool.borrow(address(weth), amountToBorrow, 2, 0, alice);

        // Calculate the aToken balance of Alice
        DataTypes.ReserveData memory reserveData = aavePool.getReserveData(asset);
        uint256 aTokenBalance = IERC20(reserveData.aTokenAddress).balanceOf(alice);
        IERC20(reserveData.aTokenAddress).approve(address(flashLoanContract), aTokenBalance);
        console.log("aTokenAddress: ", reserveData.aTokenAddress);
        console.log("Alice aTokenBalance: ", aTokenBalance);

        // Take a flash loan of $500 USDC from Aave
        bytes memory params = "";
        uint256 flashLoanAmount = 500 * 1e6; // $500 USDC
        usdc.approve(address(flashLoanContract), flashLoanAmount * 1009 / 1000); // For flash loan contract to be able to allow alice to repay the flash loan to aavePool (+ .09% premium)
        weth.approve(address(flashLoanContract), amountToBorrow); // For flash loan contract to be able to allow alice to repay the borrowed amount to aavePool (interest + principal)
        flashLoanContract.initiateFlashLoan(address(usdc), flashLoanAmount, params, 0);

        // Console log balances
        console.log("Alice's usdc balance: ", usdc.balanceOf(alice));
        console.log("Alice's weth balance: ", weth.balanceOf(alice));
        console.log("Alice's aToken balance: ", IERC20(reserveData.aTokenAddress).balanceOf(alice));
        console.log("FlashLoanContract usdc balance: ", usdc.balanceOf(address(flashLoanContract)));
        console.log("FlashLoanContract weth balance: ", weth.balanceOf(address(flashLoanContract)));

        assertLe(usdc.balanceOf(alice), amountToDeposit); // A bit of interest fees as well as premium were also deducted
        assertEq(weth.balanceOf(alice), 0); // Alice should have no weth
        assertEq(IERC20(reserveData.aTokenAddress).balanceOf(alice), 0); // Alice should have no aToken

        // - deposit the withdrawn amount ($1000) - premium to compound
        // - close the position on compound
    }
}
