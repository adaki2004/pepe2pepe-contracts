// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Fee arithmetic for fully funded fixed-odds stakes
library FixedOddsMath {
    /// @notice Fee on top of net stake, rounded up once to the asset's atomic unit.
    /// @dev Full-precision multiplication; callers enforce the maximum 500 basis points.
    ///      Maker fees use cumulative matched stake per ticket to avoid rounding per fill.
    /// @param amount Net stake or cumulative unused principal subject to the fee.
    /// @param feeBps Rate in basis points; zero disables the fee.
    /// @return Rounded fee in the same asset's atomic units.
    function fee(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, feeBps, 10_000, Math.Rounding.Ceil);
    }
}
