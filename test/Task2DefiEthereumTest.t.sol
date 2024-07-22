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
// import {CometMainInterface} from "@comet/contracts/CometMainInterface.sol";

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

    // Create user accounts
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    // Test task 1
    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/zwN585WgUa5zXb2zRxaKLtVZtt20OI0X", 20346809); // Using a specific block for consistency
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
        if (address(flashLoanContract) == address(0)) {
            flashLoanContract = new FlashLoanContract(activeNetworkConfig);
        }
        // comet = CometMainInterface(activeNetworkConfig.cometAddress);

        // Fund the accounts with 1m usdc
        deal(address(usdc), alice, 1e6 * 1e6, true);
        deal(address(usdc), bob, 1e6 * 1e6, true);

        // Fund the accounts with 100 eth
        deal(alice, 100 * 1e18);
        deal(bob, 100 * 1e18);
    }

    function testMigratePosition() external {
        // Borrow $500 USDC from Aave
        address asset = address(usdc);
        uint256 amount = 500 * 1e6; // $500 USDC
        bytes memory params = "";

        // Execute the flash loan of $500 USDC from Aave
        // aavePool.flashLoanSimple(address(flashLoanContract), asset, amount, params, 0);
        // Withdraw the collateral ($1000 USDC) from Aave
        // Repay the loan ($500 USDC) + premium to Aave
        // Deposit the withdrawn amount ($1000) - premium - loan to Compound
    }
}
