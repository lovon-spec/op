// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OpStackAdapterV1} from "../../src/adapters/OpStackAdapterV1.sol";

/**
 * @title MockAdapterV2
 * @notice A V2 adapter stub used by the demo to exercise the adapter upgrade path.
 * @dev Inherits all logic from V1, but bumps the version so the manager's ratchet
 *      check (newVersion > currentVersion) passes.
 */
contract MockAdapterV2 is OpStackAdapterV1 {
    uint256 public constant VERSION_V2 = 2_000_000;

    function version() external pure override returns (uint256) {
        return VERSION_V2;
    }

    function adapterInfo() external pure override returns (string memory name, string memory description) {
        return ("OpStackAdapterV2", "Mock V2 adapter for demo/testing (same logic as V1)");
    }
}
