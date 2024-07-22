// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPool} from "@aave/v3-core/contracts/interfaces/IPool.sol";
import {IWrappedTokenGatewayV3} from "@aave/v3-periphery/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IVariableDebtToken} from "@aave/v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {IFlashLoanSimpleReceiver} from "@aave/v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {IPoolAddressesProvider} from "@aave/v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
// import {CometMainInterface} from "comet/contracts/CometMainInterface.sol";

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

contract FlashLoanContract is IFlashLoanSimpleReceiver {
    uint256 private constant ORACLE_PRECISION = 1e8;
    uint256 private constant ETH_PRECISION = 1e18;

    IERC20 private usdc;
    IERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    ICreditDelegationToken private creditDelegationToken;

    // Test task 1
    constructor(NetworkConfig memory activeNetworkConfig) {
        // Set up the ETHEREUM_RPC_URL to fork the ethereum mainnet
        usdc = IERC20(activeNetworkConfig.usdcAddress);
        weth = IERC20(activeNetworkConfig.wethAddress);

        // Set up the aavePool, tokenGateway, aaveOracle, uniswap quoter, uniswap router, and comet addresses
        aavePool = IPool(activeNetworkConfig.aavePoolAddress);
        wrappedTokenGateway = IWrappedTokenGatewayV3(activeNetworkConfig.wrappedTokenGatewayAddress);
        priceOracle = IPriceOracleGetter(activeNetworkConfig.aavePriceOracleAddress);
        quoter = IQuoter(activeNetworkConfig.quoterAddress);
        swapRouter = ISwapRouter(activeNetworkConfig.swapRouterAddress);
        creditDelegationToken = ICreditDelegationToken(activeNetworkConfig.creditDelegationToken);
        // comet = CometMainInterface(activeNetworkConfig.cometAddress);
    }

    // Initiate a flash loan on Aave contract
    function initiateFlashLoan(address asset, uint256 amount, bytes calldata params) external {
        // Execute the flash loan of $500 USDC from Aave
        aavePool.flashLoanSimple(address(this), asset, amount, params, 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        // TODO: Write code here | Decode what params has to do
        require(msg.sender == address(aavePool), "CALLER_NOT_AAVE_POOL"); // To save on gas, this can be if Revert statement
        require(asset == address(usdc), "ASSET_NOT_USDC"); // CHECK if the asset needs to be USDC or ETH
        require(initiator == address(this), "CALLER_NOT_THIS_CONTRACT"); // CHECK if the initiator is this contract

        // - approve aavePool to transfer amounts + premium
        usdc.approve(address(aavePool), amount + premium);

        // - first take flashloan from aave worth of $500 usdc
        // - repay debt of $500 usdc which is borrowed earlier

        // - withdraw $1000 usdc

        // - repay flashloan $500 usdc + flashloanFee to aave

        // - remaining $500 deposit into compound
        // - now compound has $1000 usdc deposited
    }

    function ADDRESSES_PROVIDER() external pure override returns (IPoolAddressesProvider) {
        // Hardhcoded here since we aren't making use of it
        return IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
    }

    function POOL() external view override returns (IPool) {
        return aavePool;
    }
}
