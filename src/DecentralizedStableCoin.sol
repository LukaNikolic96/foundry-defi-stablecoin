// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Luka Nikolic
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 * @notice This contract will be governed(controled) by DSCEngine. This contract is ERC20 implementation of our
 * stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeAboveZero();
    error DecentralizedStableCoin__BalanceMustBeBiggerThanAmount();
    error DecentralizedStableCoin__CantBeAddressZero();

    // erc20burnable is erc20 so we use it in our constructor
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    // funkcija koja ce da burnuje tokene
    function burn(uint256 _amount) public override onlyOwner {
        // dodajemo tokene onog sto oce da burnuje u funkciju
        uint256 balance = balanceOf(msg.sender);
        // ne moze da burnuje 0 tokena (ne moze da kaze burnuj mi 0 tokena nema smisla)
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeAboveZero();
        }
        // ne moze da burnuje ako je balans manji od vrednost (nemoze da burnuje vise nego sto ima)
        // odnosno njegov balans ne moze da bude manji od vrednosti koju oce da burnuje
        if (balance < _amount) {
            revert DecentralizedStableCoin__BalanceMustBeBiggerThanAmount();
        }
        // super oznacava tj kazuje funkciji da koristi burn funkciju iz parent contract
        // u ovom slucaju to je ERC20Burnable, a on koristi burn iz ERC20
        super.burn(_amount);
    }

    // funkcija za mintovanje
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        // ne sme da mintuje na nultu adresu tj adresu samog tokena
        if (_to == address(0)) {
            revert DecentralizedStableCoin__CantBeAddressZero();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeAboveZero();
        }
        // mintuje tokene na adresu _to i salje amount
        _mint(_to, _amount);
        return true;
    }
}
