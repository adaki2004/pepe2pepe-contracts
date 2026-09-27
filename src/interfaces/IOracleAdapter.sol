// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MarketTypes} from "../MarketTypes.sol";

/// @title Market-bound Oracle result verification
/// @notice Boundary between immutable market custody and an explicitly chosen result-authentication policy.
interface IOracleAdapter {
    /// @notice Identify the adapter's verification policy for immutable market terms.
    /// @dev Implementations intended for fixed-policy markets must not silently change this policy.
    /// @return Nonzero commitment identifying signer/evidence/encoding policy.
    function policyHash() external view returns (bytes32);
    /// @notice Authenticate and interpret one outcome for the supplied canonical market request.
    /// @dev Must revert on wrong context/request/proof and never return Unresolved as a valid result.
    ///      The custody contract supplies trusted context; callers cannot use this view to change state.
    /// @param context Immutable funded terms that the result must answer.
    /// @param request The market's single recorded external request and question commitment.
    /// @param proof Adapter-specific encoded evidence and authentication.
    /// @return A terminal No, Yes or Void outcome; no payout or state mutation is performed here.
    function verify(
        MarketTypes.OracleContext calldata context,
        MarketTypes.OracleRequest calldata request,
        bytes calldata proof
    ) external view returns (MarketTypes.Outcome);
}
