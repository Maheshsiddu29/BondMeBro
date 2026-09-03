// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title DemoToken
/// @notice A plain testnet ERC-20 for the BondMeBro demo pool. Not for production use.
/// @dev Deliberately the most boring ERC-20 possible. BondMeBro supports standard tokens
/// only: no fee on transfer, no rebasing, no transfer callbacks, no blocklist, no pausing
/// and no upgrade path. Anything more exotic would test the demo harness rather than the
/// hook.
///
/// The whole supply is minted once, to the deployer, inside the constructor. There is no
/// owner, no minter role and no post-deployment mint, so the supply is fixed the moment the
/// contract exists and no key can dilute it. Funding extra rehearsal wallets is an ordinary
/// `transfer` from the deployer.
///
/// `decimals` is a constructor argument rather than a hardcoded 18 on purpose: the demo pool
/// pairs a 6-decimal token with an 18-decimal one so that the BMB-01 variable-leg minimums
/// are exercised in two different unit scales, which is where an 18-decimal assumption
/// would show up as a many-orders-of-magnitude error.
contract DemoToken is ERC20 {
    /// @param name_ Human-readable token name.
    /// @param symbol_ Ticker symbol.
    /// @param decimals_ Raw-unit exponent for this token.
    /// @param initialSupply Amount minted to `recipient`, in raw units.
    /// @param recipient Address receiving the entire supply.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 initialSupply, address recipient)
        ERC20(name_, symbol_, decimals_)
    {
        _mint(recipient, initialSupply);
    }
}
