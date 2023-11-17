// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.0;

import {asD} from "../asD.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

contract MockERC20 is ERC20 {
    constructor(string memory symbol, string memory name) ERC20(symbol, name) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockCNOTE is MockERC20 {
    address public underlying;
    uint256 public exchangeRateCurrent = 1e28;

    constructor(string memory symbol, string memory name, address _underlying) MockERC20(symbol, name) {
        underlying = _underlying;
    }

    function mint(uint256 amount) public returns (uint256 statusCode) {
        SafeERC20.safeTransferFrom(IERC20(underlying), msg.sender, address(this), amount);
        _mint(msg.sender, (amount * 1e28) / exchangeRateCurrent);
        statusCode = 0;
    }

    function redeemUnderlying(uint256 amount) public returns (uint256 statusCode) {
        console2.log("\tasdToken balance of cNOTE: %s", balanceOf(msg.sender));
        console2.log("\tAmount Redeedming: %s", amount);
        console2.log("\texchangeRateCurrent: %s", exchangeRateCurrent);
        console2.log("\tAmount of cToken to be burn: %s\n", (amount * exchangeRateCurrent) / 1e28);

        SafeERC20.safeTransfer(IERC20(underlying), msg.sender, amount);
        _burn(msg.sender, (amount * exchangeRateCurrent) / 1e28);
        statusCode = 0;
    }

    function redeem(uint256 amount) public returns (uint256 statusCode) {
        SafeERC20.safeTransfer(IERC20(underlying), msg.sender, (amount * exchangeRateCurrent) / 1e28);
        _burn(msg.sender, amount);
        statusCode = 0;
    }

    function setExchangeRate(uint256 _exchangeRate) public {
        exchangeRateCurrent = _exchangeRate;
    }
}

contract asDFactory is Test {
    asD asdToken;
    MockERC20 NOTE;
    MockCNOTE cNOTE;
    string asDName = "Test";
    string asDSymbol = "TST";
    address owner;
    address alice;
    address bob;

    function setUp() public {
        NOTE = new MockERC20("NOTE", "NOTE");
        cNOTE = new MockCNOTE("cNOTE", "cNOTE", address(NOTE));
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        asdToken = new asD(asDName, asDSymbol, owner, address(cNOTE), owner);

        vm.label(address(NOTE), "NOTE");
        vm.label(address(cNOTE), "cNOTE");
        vm.label(address(asdToken), "asD");
    }

    function testMint() public {
        uint256 mintAmount = 10e18;
        NOTE.mint(address(this), mintAmount);
        uint256 initialBalance = NOTE.balanceOf(address(this));
        NOTE.approve(address(asdToken), mintAmount);
        asdToken.mint(mintAmount);
        assertEq(NOTE.balanceOf(address(this)), initialBalance - mintAmount);
        assertEq(asdToken.balanceOf(address(this)), mintAmount);
        assertEq(NOTE.balanceOf(address(cNOTE)), mintAmount);
    }

    function testBurn() public {
        uint256 mintAmount = 10e18;
        testMint();
        uint256 initialBalanceNOTE = NOTE.balanceOf(address(this));
        uint256 initialBalanceASD = asdToken.balanceOf(address(this));
        uint256 initialBalanceNOTEcNOTE = NOTE.balanceOf(address(cNOTE));
        uint256 burnAmount = 6e18;
        asdToken.burn(burnAmount);
        assertEq(NOTE.balanceOf(address(this)), initialBalanceNOTE + burnAmount);
        assertEq(asdToken.balanceOf(address(this)), initialBalanceASD - burnAmount);
        assertEq(NOTE.balanceOf(address(cNOTE)), initialBalanceNOTEcNOTE - burnAmount);
    }

    // @audit testing
    function test_MintingTokenWithBiggerExchangeRateWillMintLessTokensToProtocol() public {
        // updating the exchange rate of cNote
        uint256 newExchangeRate = 1.1e28;
        cNOTE.setExchangeRate(newExchangeRate);

        uint256 mintAmount = 100 ether;

        // minting some NOTE to user for testing
        NOTE.mint(alice, mintAmount);
        NOTE.mint(bob, mintAmount);

        // logging the balances
        console2.log("> Balances before minting asdToken:");
        logBalances(alice, "Alice");
        logBalances(bob, "Bob");

        // minting asD Token
        mintToken(alice, mintAmount);
        mintToken(bob, mintAmount);

        // logging the balances after mintings
        console2.log("> Balances after minting asdToken:");
        logBalances(alice, "Alice");
        logBalances(bob, "Bob");

        // Alice burining mintAmount of asD to get NOTE back
        // alice approve asD contract to spend mintAmount of asD
        console2.log("> Alice Burning asdToken at following terms:");
        uint256 burnAmount = mintAmount;
        vm.startPrank(alice);
        asdToken.approve(address(asdToken), burnAmount);

        // calling this will burn more than the actual token that got minted because of alice's mint due to exchange rate
        // NOTE the burn amount shown is just a simulated value. The actual burn amount will be different. This is just for testing. For implementing this burn function nothing was changed in the asD contract expect some logging
        asdToken.burn(burnAmount);
        vm.stopPrank();

        // logging the balances after burning
        console2.log("> Balances After Alice Burnt asdToken:");
        logBalances(alice, "Alice");

        // bob also decided to burn mintAmount of asD to get NOTE back
        console2.log("> Bob Burning asdToken at following terms: ------------> Will revert");
        vm.startPrank(bob);
        asdToken.approve(address(asdToken), burnAmount);

        // calling this will revert because the amount of token required to burn is more than the amount of cToken asdToken Hold
        vm.expectRevert();
        asdToken.burn(burnAmount);
        vm.stopPrank();
    }

    function mintToken(address user, uint256 amount) public {
        vm.startPrank(user);

        // alice approve asD contract to spend mintAmount of NOTE
        NOTE.approve(address(asdToken), amount);

        // alice mint mintAmount of asD
        asdToken.mint(amount);
        vm.stopPrank();
    }

    function logBalances(address user, string memory name) public {
        console2.log("\t> User: %s", name);
        console2.log("\t\tNOTE Balance of User: %s", NOTE.balanceOf(address(user)));
        console2.log("\t\tasdToken Balance of User: %s", asdToken.balanceOf(address(user)));
        console2.log("\t\tcNote Contract Balance of NOTE: %s", NOTE.balanceOf(address(cNOTE)));
        console2.log("\t\tasdContract Balance of cNOTE: %s\n", cNOTE.balanceOf(address(asdToken)));
    }

    function testWithdrawCarry() public {
        testMint();
        uint256 newExchangeRate = 1.1e28;
        cNOTE.setExchangeRate(newExchangeRate);
        uint256 initialBalance = NOTE.balanceOf(owner);
        uint256 asdSupply = asdToken.totalSupply();
        // Should be able to withdraw 10%
        uint256 withdrawAmount = asdSupply / 10;
        vm.prank(owner);
        asdToken.withdrawCarry(withdrawAmount);
        assertEq(NOTE.balanceOf(owner), initialBalance + withdrawAmount);
    }

    function testWithdrawCarryWithZeroAmount() public {
        testMint();
        uint256 newExchangeRate = 1.1e28;
        cNOTE.setExchangeRate(newExchangeRate);
        uint256 initialBalance = NOTE.balanceOf(owner);
        uint256 asdSupply = asdToken.totalSupply();
        // Should be able to withdraw 10%
        uint256 maxWithdrawAmount = asdSupply / 10;
        vm.prank(owner);
        asdToken.withdrawCarry(0);
        assertEq(NOTE.balanceOf(owner), initialBalance + maxWithdrawAmount);
    }

    function testWithdrawCarryTooMuch() public {
        testMint();
        uint256 newExchangeRate = 1.1e28;
        cNOTE.setExchangeRate(newExchangeRate);
        uint256 asdSupply = asdToken.totalSupply();
        // Should be able to withdraw 10%
        uint256 withdrawAmount = asdSupply / 10 + 1;
        vm.prank(owner);
        vm.expectRevert("Too many tokens requested");
        asdToken.withdrawCarry(withdrawAmount);
    }

    function testWithdrawCarryNonOwner() public {
        uint256 withdrawAmount = 2000;
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        asdToken.withdrawCarry(withdrawAmount);
    }
}
