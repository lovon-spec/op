// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockRollupConfig
 * @notice Generic rollup configuration mock for testing.
 */
contract MockRollupConfig {
    address private _sequencer;
    address private _owner;

    event SequencerSet(address indexed sequencer);

    constructor() {
        _owner = msg.sender;
    }

    function setSequencer(address _newSequencer) external {
        require(msg.sender == _owner, "RollupConfig: caller is not the owner");
        _sequencer = _newSequencer;
        emit SequencerSet(_newSequencer);
    }

    function sequencer() external view returns (address) {
        return _sequencer;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function transferOwnership(address _newOwner) external {
        require(msg.sender == _owner, "RollupConfig: caller is not the owner");
        _owner = _newOwner;
    }
}
