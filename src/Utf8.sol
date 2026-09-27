// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Exact UTF-8 input validation
/// @notice Reject invalid Unicode and enforce limits matching JavaScript/Oracle UTF-16 string lengths.
/// @dev Does not normalize, trim or rewrite text; its original bytes remain the hash preimage.
library Utf8 {
    /// @notice Input contains a truncated, overlong, surrogate, out-of-range or otherwise invalid sequence.
    error InvalidUtf8();
    /// @notice Decoded text exceeds the permitted UTF-16 code-unit count.
    error TextTooLong();

    /// @notice Check that text is valid UTF-8 and fits the specified UTF-16 length.
    /// @dev Supplementary Unicode characters count as two units; empty text is allowed here.
    /// @param text Exact bytes to validate without altering their content.
    /// @param maxUnits Maximum decoded UTF-16 code units, not a byte limit.
    function validate(string memory text, uint256 maxUnits) internal pure {
        bytes memory data = bytes(text);
        uint256 units;
        uint256 i;
        while (i < data.length) {
            // A full word with no high bits is 32 ASCII / UTF-16 units. Keep the
            // scalar validator below for mixed and Unicode words, including its
            // exact error ordering. Only read complete words inside the string.
            if (data.length - i >= 32) {
                uint256 word;
                assembly ("memory-safe") {
                    word := mload(add(add(data, 32), i))
                }
                if (word & 0x8080808080808080808080808080808080808080808080808080808080808080 == 0) {
                    units += 32;
                    if (units > maxUnits) revert TextTooLong();
                    i += 32;
                    continue;
                }
            }
            uint8 c = uint8(data[i]);
            uint256 width;
            if (c < 0x80) width = 1;
            else if (c >= 0xc2 && c <= 0xdf) width = 2;
            else if (c >= 0xe0 && c <= 0xef) width = 3;
            else if (c >= 0xf0 && c <= 0xf4) width = 4;
            else revert InvalidUtf8();
            if (i + width > data.length) revert InvalidUtf8();
            for (uint256 j = 1; j < width; ++j) {
                uint8 continuation = uint8(data[i + j]);
                if (continuation < 0x80 || continuation > 0xbf) revert InvalidUtf8();
            }
            if (width >= 3) {
                uint8 second = uint8(data[i + 1]);
                if ((c == 0xe0 && second < 0xa0) || (c == 0xed && second > 0x9f)) revert InvalidUtf8();
                if ((c == 0xf0 && second < 0x90) || (c == 0xf4 && second > 0x8f)) revert InvalidUtf8();
            }
            units += width == 4 ? 2 : 1;
            if (units > maxUnits) revert TextTooLong();
            i += width;
        }
    }
}
