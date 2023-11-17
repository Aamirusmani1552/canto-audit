// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >=0.8.0;

import {Turnstile} from "../interface/Turnstile.sol";
import {IasDFactory} from "../interface/IasDFactory.sol";
import {CTokenInterface, CErc20Interface} from "../interface/clm/CTokenInterfaces.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract asD is ERC20, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/
    address public immutable cNote; // Reference to the cNOTE token

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CarryWithdrawal(uint256 amount);

    /// @notice Initiates CSR on main- and testnet
    /// @param _name Name of the token
    /// @param _symbol Symbol of the token
    /// @param _owner Initial owner of the vault/token
    /// @param _cNote Address of the cNOTE token
    /// @param _csrRecipient Address that should receive CSR rewards
    constructor(string memory _name, string memory _symbol, address _owner, address _cNote, address _csrRecipient)
        ERC20(_name, _symbol)
    {
        _transferOwnership(_owner);
        cNote = _cNote;
        if (block.chainid == 7700 || block.chainid == 7701) {
            // Register CSR on Canto main- and testnet
            Turnstile turnstile = Turnstile(0xEcf044C5B4b867CFda001101c617eCd347095B44);
            turnstile.register(_csrRecipient);
        }
    }

    /// @notice Mint amount of asD tokens by providing NOTE. The NOTE:asD exchange rate is always 1:1
    /// @param _amount Amount of tokens to mint
    /// @dev User needs to approve the asD contract for _amount of NOTE

    // @audit-info: flow diagram
    // -> User approve asD contract to spend _amount of NOTE
    // -> User call mint function with _amount of NOTE
    // -> asD contract transfer _amount of NOTE from user to itself
    // -> asD contract approve cNote contract to spend _amount of NOTE
    // -> asD contract mint _amount of cNote
    // -> asD contract mint _amount of asD
    function mint(uint256 _amount) external {
        CErc20Interface cNoteToken = CErc20Interface(cNote);
        IERC20 note = IERC20(cNoteToken.underlying());
        // transferring note token to this contract
        SafeERC20.safeTransferFrom(note, msg.sender, address(this), _amount);

        // appoving cNote token to spend note token
        // @audit-info deprecated approve function. use safeIncreaseAllowance instead: known issue
        SafeERC20.safeApprove(note, cNote, _amount);

        // minting cNote token
        // @audit is it really possible to mint arbitrary amount of tokens
        uint256 returnCode = cNoteToken.mint(_amount);
        // Mint returns 0 on success: https://docs.compound.finance/v2/ctokens/#mint
        require(returnCode == 0, "Error when minting");

        // minting asD token
        // @audit does the amount of asD token minted is equal to the amount of cNote token minted?
        // or will be related to asD token price?
        _mint(msg.sender, _amount);
    }

    /// @notice Burn amount of asD tokens to get back NOTE. Like when minting, the NOTE:asD exchange rate is always 1:1
    /// @param _amount Amount of tokens to burn
    function burn(uint256 _amount) external {
        CErc20Interface cNoteToken = CErc20Interface(cNote);
        IERC20 note = IERC20(cNoteToken.underlying());

        // redeeming cNote token
        // @audit does redeeming cNote with `_amount` gives correct amount
        uint256 returnCode = cNoteToken.redeemUnderlying(_amount); // Request _amount of NOTE (the underlying of cNOTE)
        require(returnCode == 0, "Error when redeeming"); // 0 on success: https://docs.compound.finance/v2/ctokens/#redeem-underlying

        // burning asD token
        // @audit little bit less tokens of the sender will be burnt
        _burn(msg.sender, _amount);

        // transferring note token to user
        SafeERC20.safeTransfer(note, msg.sender, _amount);
    }

    /// @notice Withdraw the interest that accrued, only callable by the owner.
    /// @param _amount Amount of NOTE to withdraw. 0 for withdrawing the maximum possible amount
    /// @dev The function checks that the owner does not withdraw too much NOTE, i.e. that a 1:1 NOTE:asD exchange rate can be maintained after the withdrawal
    function withdrawCarry(uint256 _amount) external onlyOwner {
        // @audit although the exchange rate is calculated manually but the denominator in the below calculation is still using 1e28 hardcoded. can this affect the calculation?
        uint256 exchangeRate = CTokenInterface(cNote).exchangeRateCurrent(); // Scaled by 1 * 10^(18 - 8 + Underlying Token Decimals), i.e. 10^(28) in our case
        // The amount of cNOTE the contract has to hold (based on the current exchange rate which is always increasing) such that it is always possible to receive 1 NOTE when burning 1 asD
        uint256 maximumWithdrawable =
            (CTokenInterface(cNote).balanceOf(address(this)) * exchangeRate) / 1e28 - totalSupply();
        if (_amount == 0) {
            _amount = maximumWithdrawable;
        } else {
            require(_amount <= maximumWithdrawable, "Too many tokens requested");
        }
        // Technically, _amount can still be 0 at this point, which would make the following two calls unnecessary.
        // But we do not handle this case specifically, as the only consequence is that the owner wastes a bit of gas when there is nothing to withdraw
        uint256 returnCode = CErc20Interface(cNote).redeemUnderlying(_amount);
        require(returnCode == 0, "Error when redeeming"); // 0 on success: https://docs.compound.finance/v2/ctokens/#redeem
        IERC20 note = IERC20(CErc20Interface(cNote).underlying());
        SafeERC20.safeTransfer(note, msg.sender, _amount);
        emit CarryWithdrawal(_amount);
    }
}
