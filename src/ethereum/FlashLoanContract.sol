// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";
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
    address private constant ATOKEN_USDC_ADDRESS = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    IERC20 private usdc;
    IERC20 private weth;
    IPool private aavePool;
    IWrappedTokenGatewayV3 private wrappedTokenGateway;
    IPriceOracleGetter private priceOracle;
    IQuoter private quoter;
    ISwapRouter private swapRouter;
    ICreditDelegationToken private creditDelegationToken;
    address private immutable alice;

    // Test task 1
    constructor(NetworkConfig memory activeNetworkConfig, address aliceAddress) {
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
        alice = aliceAddress;
        // comet = CometMainInterface(activeNetworkConfig.cometAddress);
    }

    // Initiate a flash loan on Aave contract
    function initiateFlashLoan(address asset, uint256 amount, bytes calldata params, uint16 referralCode) external {
        aavePool.flashLoanSimple(address(this), asset, amount, params, referralCode);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == address(aavePool), "CALLER_NOT_AAVE_POOL"); // To save on gas, this can be if Revert statement
        require(asset == address(usdc), "ASSET_NOT_USDC"); // CHECK if the asset needs to be USDC or ETH
        require(initiator == address(this), "CALLER_NOT_THIS_CONTRACT"); // CHECK if the initiator is this contract

        // - repay debt of $500 weth which was borrowed from aave earlier
        (, uint256 totalDebtBase,,,,) = aavePool.getUserAccountData(alice);
        console.log("Total debt base: ", totalDebtBase);
        console.log("This contract's usdc balance before repay: ", usdc.balanceOf(address(this)));
        uint256 amountBorrowed = 142 * 1e15;
        weth.transferFrom(alice, address(this), amountBorrowed);
        weth.approve(address(aavePool), amountBorrowed);
        uint256 finalAmountRepaid = aavePool.repay(
            address(weth),
            amountBorrowed, // amountToBorrow + interest ~ amount
            2,
            alice
        );
        console.log("Final amount repaid: %d", finalAmountRepaid);
        (uint256 totalCollateralBase,,,,,) = aavePool.getUserAccountData(alice);
        console.log("Total collateral after: %d", totalCollateralBase);

        // - withdraw $1000 usdc which was put as collateral initially
        uint256 aliceATokenBalance = IERC20(ATOKEN_USDC_ADDRESS).balanceOf(alice);
        IERC20(ATOKEN_USDC_ADDRESS).transferFrom(alice, address(this), aliceATokenBalance);
        uint256 withdrawnAmount = aavePool.withdraw(address(usdc), totalCollateralBase / 10 ** 2, alice);
        console.log("Withdrawn collateral amount:", withdrawnAmount);
        console.log("Alice's usdc balance after withdrawal: ", usdc.balanceOf(alice));

        // - repay flashloan $500 usdc + flashloanFee to aave
        uint256 totalAmountToRepay = amount + premium;
        usdc.transferFrom(alice, address(this), premium);
        usdc.approve(address(aavePool), totalAmountToRepay);

        return true;
    }

    function ADDRESSES_PROVIDER() external pure override returns (IPoolAddressesProvider) {
        // Hardhcoded here since we aren't making use of it
        return IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);
    }

    function POOL() external view override returns (IPool) {
        return aavePool;
    }

}
