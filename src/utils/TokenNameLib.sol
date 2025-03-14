// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {MetadataReaderLib} from "solady/src/utils/MetadataReaderLib.sol";
import {DateTimeLib} from "solady/src/utils/DateTimeLib.sol";
import {LibString} from "solady/src/utils/LibString.sol";

/// @dev Inputs `expiry` that exceed maximum timestamp results in undefined behavior.
library TokenNameLib {
    using LibString for uint256;

    string constant PY_NAME_PREFIX = "NapierV2-";

    function principalTokenName(address target, uint256 expiry) internal view returns (string memory) {
        string memory underlyingName = MetadataReaderLib.readName(target);
        return string.concat(PY_NAME_PREFIX, "PT-", underlyingName, "@", expiryToDate(expiry));
    }

    function principalTokenSymbol(address target, uint256 expiry) internal view returns (string memory) {
        string memory underlyingSymbol = MetadataReaderLib.readSymbol(target);
        return string.concat("PT-", underlyingSymbol, "@", expiryToDate(expiry));
    }

    function yieldTokenName(address target, uint256 expiry) internal view returns (string memory) {
        string memory underlyingName = MetadataReaderLib.readName(target);
        return string.concat(PY_NAME_PREFIX, "YT-", underlyingName, "@", expiryToDate(expiry));
    }

    function yieldTokenSymbol(address target, uint256 expiry) internal view returns (string memory) {
        string memory underlyingSymbol = MetadataReaderLib.readSymbol(target);
        return string.concat("YT-", underlyingSymbol, "@", expiryToDate(expiry));
    }

    function lpTokenName(address target, uint256 expiry) internal view returns (string memory) {
        string memory underlyingName = MetadataReaderLib.readName(target);
        return string.concat("NapierV2-PT/", underlyingName, "@", expiryToDate(expiry));
    }

    function lpTokenSymbol(address target, uint256 expiry) internal view returns (string memory) {
        string memory underlyingSymbol = MetadataReaderLib.readSymbol(target);
        return string.concat("NPR-PT/", underlyingSymbol, "@", expiryToDate(expiry));
    }

    function expiryToDate(uint256 expiry) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = DateTimeLib.timestampToDate(expiry);
        return string.concat(day.toString(), "/", month.toString(), "/", year.toString());
    }
}
