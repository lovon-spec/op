// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockHub
 * @notice Mock SharedSequencerHub for testing bundle and builder contracts.
 */
contract MockHub {
    address public currentProposer;

    function setCurrentProposer(address _proposer) external {
        currentProposer = _proposer;
    }
}
