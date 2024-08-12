// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TestConfigEthereum} from "./TestConfigEthereum.t.sol";
import {OnChainLeverage} from "../src/ethereum/rareskills/OnChainLeverage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICreditDelegationToken} from "@aave/v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IPriceOracleGetter} from "@aave/v3-core/contracts/interfaces/IPriceOracleGetter.sol";

contract OnChainLeverageTest is Test {

    address immutable alice = makeAddr("Alice");
    address constant AUSDC_VARIABLE_DEBT_TOKEN = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    address constant AWETH_VARIABLE_DEBT_TOKEN = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;


    ERC20 private usdc;
    ERC20 private weth;
    IPriceOracleGetter private priceOracle;
    OnChainLeverage private onChainLeverage;
    TestConfigEthereum private testConfigEthereum;

    function setUp() public {
        string memory rpcUrl = vm.envString("ACTIVE_RPC_URL");
        vm.createSelectFork(rpcUrl);
        // Deploy the contract
        testConfigEthereum = new TestConfigEthereum();
        (address usdcAddress, address wethAddress, address aavePoolAddress, address wrappedTokenGatewayAddress, address creditDelegationToken, address aavePriceOracleAddress, address quoterAddress, address swapRouterAddress, address cometAddress, address positionManagerAddress) = testConfigEthereum.activeNetworkConfig();
        
        usdc = ERC20(usdcAddress);
        weth = ERC20(wethAddress);
        priceOracle = IPriceOracleGetter(aavePriceOracleAddress);

        // Deploy OnChainLeverage contract
        OnChainLeverage.NetworkConfig memory activeNetwork = OnChainLeverage.NetworkConfig({
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
        onChainLeverage = new OnChainLeverage(activeNetwork);
    }

    function testLongWethOnAave() public {
        uint256 amount = 1 * 1e18;
        deal(address(weth), alice, amount, false);

        vm.startPrank(alice);
        weth.approve(address(onChainLeverage), amount);
        ICreditDelegationToken(AUSDC_VARIABLE_DEBT_TOKEN).approveDelegation(address(onChainLeverage), type(uint256).max);
        (uint256 totalCollateralBase,,) = onChainLeverage.longOnAave(address(weth), address(usdc), amount);
        vm.stopPrank();
        // Convert the totalCollateralBase amount to weth
        uint8 wethDecimal = weth.decimals();
        uint256 wethPrice = priceOracle.getAssetPrice(address(weth));
        uint256 totalCollateralInWeth = (totalCollateralBase * 10**wethDecimal) / wethPrice;
        assertGt(totalCollateralInWeth, amount);
    }

    function testShortWethOnAave() public {
        uint256 amount = 1 * 1e18;
        deal(address(weth), alice, amount, false);

        vm.startPrank(alice);
        // The below uint256 value should be essentially the 'amount' of usdc after exactInputSingle swap of 'amount' value of eth
        weth.approve(address(onChainLeverage), type(uint256).max);
        ICreditDelegationToken(AWETH_VARIABLE_DEBT_TOKEN).approveDelegation(address(onChainLeverage), type(uint256).max);
        (uint256 totalCollateralBase,,) = onChainLeverage.shortOnAave(address(weth), address(usdc), amount);
        vm.stopPrank();
        uint8 usdcDecimal = usdc.decimals();
        uint256 usdcPrice = priceOracle.getAssetPrice(address(usdc));
        uint256 totalCollateralInUsdc = (totalCollateralBase * 10**usdcDecimal) / usdcPrice;
        // Calculate the initial amount in usdc
        uint256 wethPrice = priceOracle.getAssetPrice(address(weth));
        uint256 baseCurrencyPrecision = 1e8; // Aave returns value in 1e8 precision
        uint256 initialAmountInUsdc = (amount * wethPrice * 1e6) / (1e18 * baseCurrencyPrecision);

        assertGt(totalCollateralInUsdc, initialAmountInUsdc);
    }

    function testLongEthOnAave() public {
        uint256 amount = 1 * 1e18;
        deal(alice, amount);

        vm.startPrank(alice);
        weth.approve(address(onChainLeverage), amount);
        // TODO: Get the ICreditDelegationToken address and ICreditDelegationToken (from IPoolAddressesProvider[0x2f39d218133afab8f2b819b1066c7e434ad94e9e])
        ICreditDelegationToken(AUSDC_VARIABLE_DEBT_TOKEN).approveDelegation(address(onChainLeverage), type(uint256).max);
        (uint256 totalCollateralBase,,) = onChainLeverage.longEthOnAave{value: amount}(address(usdc), amount);
        vm.stopPrank();
        // Convert the totalCollateralBase amount to weth
        uint8 wethDecimal = weth.decimals();
        uint256 wethPrice = priceOracle.getAssetPrice(address(weth));
        uint256 totalCollateralInWeth = (totalCollateralBase * 10**wethDecimal) / wethPrice;
        assertGt(totalCollateralInWeth, amount);
    }

    function testShortEthOnAave() public {
        uint256 amount = 1 * 1e18;
        deal(alice, amount);

        vm.startPrank(alice);
        // This should be essentially the 'amount' of usdc after exactInputSingle swap of 'amount' value of eth
        usdc.approve(address(onChainLeverage), type(uint256).max);
        ICreditDelegationToken(AWETH_VARIABLE_DEBT_TOKEN).approveDelegation(address(onChainLeverage), type(uint256).max);
        (uint256 totalCollateralBase,,) = onChainLeverage.shortEthOnAave{value: amount}(address(usdc), amount);
        vm.stopPrank();
        uint8 usdcDecimal = usdc.decimals();
        uint256 usdcPrice = priceOracle.getAssetPrice(address(usdc));
        uint256 totalCollateralInUsdc = (totalCollateralBase * 10**usdcDecimal) / usdcPrice;
        // Calculate the initial amount in usdc
        uint256 wethPrice = priceOracle.getAssetPrice(address(weth));
        uint256 baseCurrencyPrecision = 1e8; // Aave returns value in 1e8 precision
        uint256 initialAmountInUsdc = (amount * wethPrice * 1e6) / (1e18 * baseCurrencyPrecision);

        assertGt(totalCollateralInUsdc, initialAmountInUsdc);
    }
}

