// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISequencerInbox} from "../../src/poc/arbitrum/interfaces/IArbitrumRollup.sol";

/**
 * @title MockSequencerInbox
 * @notice Mock Arbitrum SequencerInbox for testing ArbitrumAdapterV1.
 */
contract MockSequencerInbox is ISequencerInbox {
    mapping(address => bool) public batchPosters;
    mapping(address => bool) public sequencers;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function setIsBatchPoster(address addr, bool isBatchPoster_) external override {
        batchPosters[addr] = isBatchPoster_;
    }

    function isBatchPoster(address addr) external view override returns (bool) {
        return batchPosters[addr];
    }

    function setIsSequencer(address addr, bool isSequencer_) external override {
        sequencers[addr] = isSequencer_;
    }

    function transferOwnership(address _newOwner) external {
        owner = _newOwner;
    }
}
