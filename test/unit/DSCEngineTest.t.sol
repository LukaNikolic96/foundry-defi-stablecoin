// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    // ubacujemo DSC skriptu i kreiramo novu instancu u setup
    DeployDSC deployer;
    // takodje ubacujemo dsc i dscEngine
    DecentralizedStableCoin public dsc;
    DSCEngine public dscEngine;
    HelperConfig public helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    // there we will store token and price feed addresses
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function setUp() public {
        deployer = new DeployDSC();
        // because our deploy script returns dsc & engine values, we extract them from deployer and put those values in these new instances
        // dsc & dscEngine in our case and helperConfig also
        (dsc, dscEngine, helperConfig) = deployer.run();
        // then we extract ethprice feed and weth fom helperconfig
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = helperConfig.activeNetworkConfig();

        // we are giving our user some starting balance
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    // test to see if reverts if token length doesn't match price feeds
    function testRevertsIfTokenLengthDoesntMatchPriceFeds() public {
        // add our token and price feed addreses to the array
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        // we are expecting correct error on the last line
        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    // test to see if we get value in usd
    function testGetUsdValue() public {
        // we give amount of eth we want to test
        uint256 ethAmount = 15e18;
        // we setup in helper that eth is 2000 USD
        uint256 expectedUsd = 30000e18;
        // getting actual USD value from our getUsdValue function that takes 2 parametres
        // token(weth in this case) & (amount - ethAmount in this case)
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        // they expected and actual value needs to be equal for this test to pass
        assertEq(expectedUsd, actualUsd);
    }

    // test to see if we get value from token to usd
    function testGetTokenAmountFromUsd() public {
        uint256 amount = 100 ether;
        uint256 expectedValue = 0.05 ether;

        uint256 actualValue = dscEngine.getTokenAmountFromUsd(weth, amount);
        assertEq(expectedValue, actualValue);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    // test if collateral is zero
    function testIfRevertsIfCollateralIsZero() public {
        // we start prank with our fake user
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL); // - not sure why we need this line
        // we say what error we expected to revert
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        // we simulate if someone deposit 0 weth
        dscEngine.depositCollateral(weth, 0);
        // end test
        vm.stopPrank();
    }

    // test reverts if collateral type is not approved (if collateral is not weth or wbtc)
    function testRevertsWithUnapprovadCollateral() public {
        // we create some random token and give amount collateral to the user
        ERC20Mock randomToken = new ERC20Mock("RAND", "RAND", USER, AMOUNT_COLLATERAL);
        // starting prank with that user
        vm.startPrank(USER);
        // we expect certain error to come
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        // line that will throw error on purpose
        dscEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // modifier for depositing collateral so we don't write it everytime
    modifier depositedCollateral() {
        // starting prank
        vm.startPrank(USER);
        // creating mock version of weth
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }
    // test to see if we can deposit collateral and get depositor account info

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        // throught modifier we deposited collateral from address USER
        // then through getAccountInformation we extract USER account information
        (uint256 totalDscMinted, uint256 collateralAmount) = dscEngine.getAccountInformation(USER);

        // we don't expect DSC to be minted in our modifier so we expect it to be 0
        uint256 expectedDscMinted = 0;
        // we then getting token amount from our collateralAmount from USER
        uint256 actualCollateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralAmount);
        // we make sure that everything is equal in order tests to pass
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(actualCollateralAmount, AMOUNT_COLLATERAL);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (amountCollateral * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }
}
