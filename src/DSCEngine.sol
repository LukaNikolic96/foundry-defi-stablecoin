// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Luka Nikolic
 *
 * This minimalistic system is designem to maintain a 1 token == $1 peg.
 * This stablecoinproperties are:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * Out system should always be "overcollateralized". The value of all collateral should never be less of equal to all DSC.
 * (all collateral <= the $ backed value of all DSC)
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC.
 * @notice This contracs is the core of DSC System and handles logic for minting and redeeming DSC and despositing & withdrawing collateral.
 * @notice It is loosley based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    // ERRORS //////
    ////////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////
    // TYPE ///////
    ///////////////
    using OracleLib for AggregatorV3Interface;

    //////////////////////
    // State Variables ///
    //////////////////////
    // number to multiple amount to be precise
    uint256 private constant ADDITIONAL_PRICE_PRECISION = 1e10;
    // number to divide result so we don't have massive number as a sresult or multiple if our number have already e18 zeros but needs
    // to be divided with some number that have e18 zeros so we get in the result some number with e18 zeroes
    uint256 private constant PRECISION = 1e18;
    // liquidation threshold
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // it means it is 200% overcolateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    // we give 10% bonus to liquidators
    uint256 private constant LIQUIDATION_BONUS = 10;
    // minimum requirement for health factor (it should not be less than this)
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    // map of tokens that will be allowed
    mapping(address token => address priceFeed) private s_priceFeeds; // token to price feed
    // map to see how much users deposited
    /* we map address of users balances to maping of tokens which is going to map to the amount of each token user have
    in simple words: Certain user deposited (have balance) certain type of tokens (WETH/WBTC) and certain amount of those
    tokens and that will be his collateralDeposit*/
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    // mapping to follow how much every user minted DSC
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    // we can loop throught this and see how much value of collateral users have
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////
    // Events /////
    ///////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    // this will be refactored
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /////////////////
    // Modifiers ////
    /////////////////

    // modifier to make sure amout deposited is always above zero
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    // modifier that allows certain tokens as collateral
    // this modifier ensures that the token passed as an argument is allowed to interact with the function it modifies
    modifier isTokenAllowed(address token) {
        // address(0) represent uninitalized or null address so that is why we revert it if our token address is equal with that
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////
    // Functions ///
    ////////////////

    // in counstructor we stup that address of the token we want must be equal to the pricefeed of that token
    // also we will tell in constructor to use our stable coin contract
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // if they don't match we revert (we must use USD price feeds only)
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPriceFeedAddressMustBeSameLength();
        }
        // we loop through tokenAddresses array and make s_priceFeeds of tokenAddress of i have same value as priceFeedAddress of that i
        // that is how we stup what tokens will be allowed on our platform if they have price feed they will be allowed otherwise won't
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            // add those tokens to as the collateral in our array
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    // External Functions ///
    /////////////////////////

    /**
     *
     * @param tokenCollateralAddress - address of the token to deposit as collateral
     * @param amountCollateral - amount of collateral to deposit
     * @param amountDscToMint - amount of DSC to mint
     * we want people to deposit their ETH or BTC and mint DSC token in one transaction - this is combination function
     * (combines depositCollateral and mintDsc functions)
     */
    //
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        // this deposit token address and the amount user want
        depositCollateral(tokenCollateralAddress, amountCollateral);
        // this mint DSC
        mintDsc(amountDscToMint);
    }

    /**
     * Function for depositing collateral
     * @notice Follows CEI (checks, effects, interactions) pattern
     * @param tokenCollateralAddress - The address of the token to deposit as collateral
     * @param amountCollateral - The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        // these modifiers are all CHECKS
        moreThanZero(amountCollateral)
        isTokenAllowed(tokenCollateralAddress)
        nonReentrant
    {
        // EFFECTS
        // we are updating user collateral with the amount that has been deposited
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        // this event contains user(msg.sender in our function) who sent it, type of token and the amout that has been sent(deposited)
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // INTERACTIONS
        // we are making our collateral as IERC20
        // We make sure to transfer ceratin type of tokens from the user address with the certain amount to this address
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        // revert if it fails
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress - address of collateral to redeem
     * @param amountCollateral - amount of collateral to redeem
     * @param amountDscToBurn - amount dsc to burn
     * This function burns DSC and Redeems underlying collateral in one transaction
     */
    // we want people to redeem their collateral (turn DSC back to ETH or BTC)
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // funkcija for redeem collateral
    // in order to redeem health factor must be over 1 after collateral redeemed
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // we call our private redeem collateral function
        //_redeemCollateral(msg.sender(this is FROM address), msg.sender(this is TO address),tokenCollateralAddress,amountCollateral)
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        // then we call this function to check health status if it is broken
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * Function for minting
     * @notice follows CEI
     * @param amountDscToMint - The amount of decentralized stablecoin to mint
     * @notice They must have more value than the minimum required
     * @notice We need to check if collateral value is bigger than dsc value
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // this line adds amount specific user want to mint
        s_DSCMinted[msg.sender] += amountDscToMint;
        // this line revert if health factor is below required minimum (if dsc minted breaks health factor for user)
        _revertIfHealthFactorIsBroken(msg.sender);
        // check to see if mintins is succesfull (it is if it returns true)
        // we mint from i_dsc which is our link with DSC contract (and we add user and amount he want to mint)
        // our mint function requires address _to (which is our user address (msg.sender)) and how much amount to send to that address
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        // this is revert in case minting is not succesfull
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // we want people to be able to burn DSC (if they beleive they have too much stable coin and not enough collateral or want to redeem)
    // so then they can have enough collateral they are comfortable with
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        // we call our private burn function
        // _burnDsc(amount, msg.sender(onBehalfOf), msg.sender(dscFrom));
        _burnDsc(amount, msg.sender, msg.sender);
        // then we call this function to check health status if it is broken
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * - we want people to be able to liquidate if someone have more DSC than collateral or the value of collateral drops below certain point
     * - this way protocol we will be always secured and functional
     * @param collateral - The ERC20 collateral address to liqudate from the user(address of the token for liquidation)
     * @param user - The address of a user who has broken health factor. Their _healthFactor should be above MIN_HEALTH_FACTOR
     * @param debtToCover - The amount of DSC you want to burn to improve the users health factor.
     * @notice - You can partially liquidate user.
     * @notice - You will get a liquidation bonus for taking the users funds
     * @notice - For this to work protocol needs to be roughly 200% overcollateralized.
     * @notice - If protocol is just 100% or less could not encourage liquidators.
     * (If price plummeted before anyone could be liquidated).
     * Protocol follows CEI.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // we get user health factor
        uint256 startingUserHealthFactor = _healthFactor(user);
        // we make sure it is aboun minimun
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOk();
        }
        // we get value of how much debt is covered
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // we calculate bonus for liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // we add amount of debt that was covered and bonus to total collateral liquidators can redeem
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        // we redeem that collateral with our private function
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // then we burn with our private function
        _burnDsc(debtToCover, user, msg.sender);

        // now we chech health factor after liquidation and if it is less than starting we throw error
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // revert if this process ruined liquidators health factor
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // function to see health of user balances
    function getHealthFactor() external view {}

    ////////////////////////////////////////
    // Private & Internal View Functions ///
    ////////////////////////////////////////

    /**
     * Internal burn function that can burn from anybody
     * @param amountDscToBurn - amount dsc to burn
     * @param onBehalfOf - whos DSC are we burning for, or whose debt are we paying down
     * (this address want to deduct amount from minted dsc storage and transfer it from the different user(user that is liquidated)
     * to this contract and then burn it- its like saying I payed debt for that user and I want his DSC amount to be burned)
     * @param dscFrom - address where we are getting DSC from
     * @dev - Low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        // onbehalfof address is applying that certain amount from minted poll is deducted
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        // if that is possible we transfer that amount of dsc from liquidating user to this contract
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // revert if that failed
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        // then we burn that amount from existence
        i_dsc.burn(amountDscToBurn);
    }

    // function to calculate health factor
    /**
     *
     * @param totalDscMinted - amount of DSC minted
     * @param collateralValueInUsd - Collateral Value in USD
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // if someone have collateral deposited but still did not minted
        // his healthfactor will be divided by 0 and we cannot have something
        // be divided by 0 so thats is why we have if checkec function here
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * Internal function that can redeem colateral from anybody
     * @param tokenCollateralAddress - address of collateral tokem
     * @param amountCollateral - amount of collateral
     * @param from - address from we take collateral
     * @param to - address of liquidator where we send collateral bounty
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        // we deduct collateral from user that was deposited
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        // we emit event that collateral is redeemed and from which address, to whom, type of tokens and amount
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        // we make sure that token transfer is succeed if not revert with error
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    // function to get information about user acc (how much they have DSC minted and their collateral value in USD)

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        // total DSC minted by user
        totalDscMinted = s_DSCMinted[user];
        // collateral value of user
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     *
     * Function to see health factor of a user
     * Returns how close to liquidation user is
     * If they go below 1 they are liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // getting total dsc minted and collateral value from user
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // functiont ot check health of their account (do they have enough collateral) and revert if they don't
    // revert if it is less than 1 (MIN_HEALTH_FACTOR)
    function _revertIfHealthFactorIsBroken(address user) internal view {
        // variable that takes value we het from _healthFactor for specific users
        uint256 userHealthFactor = _healthFactor(user);
        // if state to check if it is below minimum
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////
    // Public & External View Functions ////
    ////////////////////////////////////////

    /**
     *
     * @param token - address (type) of token we want to get amount of
     * @param usdAmountInWei - USD amount converted in we liquidator will pay
     */

    // function that will help us know how much of collateral value that will be liquidated liquidator get
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // first we get price for required token for example ETH (let it be $2000)
        // and then we divide amount we pay for collateral ex $1000 then liquidator will get 0.5 ETH

        // first we get price feed of that token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // we return then calculated amount
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_PRICE_PRECISION);
    }

    //function to get collateral value of a user
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop throught each collateral token, get the amount deposited, map it to the price and get USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            // in token address we put address of collateral(which means in address of token we put type of collateral WETH/WBTC)
            address token = s_collateralTokens[i];
            // we connect amount with user and token type
            uint256 amount = s_collateralDeposited[user][token];
            // we get usd value of that token type with that amount
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    // function to get value of tokens in USD
    // we input token address(to see type of token) and amount and return value in USD
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        // getting value of wanted token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        // we get the price of that token (int256 answer - if you chechk it in the aggregator)
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return ((uint256(price) * ADDITIONAL_PRICE_PRECISION) * amount) / PRECISION;
        /* because the price returns with 8 decimals we multiply it first with additional price precision to get 18 decimals, then we 
        multiply it with amount user have and then divide with PRECISION so we don't have that big of a number */
    }

    // function to get account information (how much DSC and collateral it has)
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    // function to calculate health factor
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_TRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
    // get collateral ballance of a user

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}

/* Kako bi to radilo:
stavicemo da naprimer prag(threshold) bude 150% sto znaci :
za $100 ETH ulozenih kao collateral dobijas $50 DSC tokena.
minimalna vrednost na koju ETH moze da padne da bi bio siguran je $75 ($50 (100%) + $25 (50% of $50) = $75 (%150)).
Ako padne na $74 ljudi mogu da vide da necija vrednost collateral je manje od dozvoljene i moze onda on da otplati
ceo njegov dug od $50 DSC i za uzvrat dobija svih $74 ETH i na taj nacin je on prifitirao $24 ETH a ovaj je ostao bez icega.
Tako teramo korisnike da budu odgovorni za svoju vrednost i na taj nacin odrzavamo sistem funkcionalnim i odrzivim. */
// stavili smo threshold da bude 50 sto bi znacilo da je 200% a ne 150%
