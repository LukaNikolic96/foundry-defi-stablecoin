// contract to handle how we make special calls
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";


contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 public MAX_DEPOSIT_SIZE = type(uint96).max; // max uint96 value

    // we are tracking addresses of users who deposited
    address[] public usersWhoDeposited;

    uint256 public timesMintCalled;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        // we want those 2 contract handler to handle when making calls
        dsce = _dscEngine;
        dsc = _dsc;

        // we are getting array of allowed tokens
        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    // function to mint dsc
    /**
     *
     * @param amount - amount of dsc to mint
     */
    function mintDsc(uint256 amount, uint256 addressSeed) public {
        // first we make sure we have users who deposited
        if(usersWhoDeposited.length == 0){
            return;
        }
        // sender is user who deposited
        address sender = usersWhoDeposited[addressSeed % usersWhoDeposited.length];
        // first we make sure there is more collateral than dsc by getting account information about our user(msg.sender)
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        // then we make suer collateral is 2xbigger than dsc minted
        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);

        // return if it is negative
        if (maxDscToMint < 0) {
            return;
        }
        // we make sure our amount goes between 0 and maximum amount allowed for minting
        amount = bound(amount, 0, uint256(maxDscToMint));

        // amount should never be 0
        if (amount == 0) {
             return;
         }

        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintCalled++;

    }

    // function to redeem collateral when there is enough collateral
    /**
     *
     * @param collateralSeed - pick collateral that are allowed
     * @param amountCollateral - amount of that collateral
     */
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // getting allowed collateral type
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // checking how much max collateral user can redeem by checing his balance
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        // making sure he cant redeem 0 or above his max
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    // first we create deposit collateral
    /**
     *
     * @param collateralSeed - pick randomly collateral that are allowed
     * @param amountCollateral - amount of that collateral
     */
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // getting allowed collateral type
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // we put range how big or small amount should be
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        // starting prank so our fake user can mint and approve
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        // deposit amount on that type of collateral address
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // we add that msg.sender to users who deposited
        usersWhoDeposited.push(msg.sender);
    }

    // this breaks our test because our price for eth is $2000 but it set it as low as $3 or less
    // // function to update price of collateral
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // helper function to get right type of collateral
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        // because our weth token is at address 0 is modula of 2 is 0 we return weth
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
