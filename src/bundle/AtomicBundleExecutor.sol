// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAtomicBundleExecutor} from "../interfaces/IAtomicBundleExecutor.sol";

/**
 * @title AtomicBundleExecutor
 * @notice Entry point for atomic cross-chain bundle execution on L2 Spoke chains.
 * @dev Deployed on every connected L2 chain to enforce Optimistic State Atomicity.
 *
 *      Architecture:
 *      - Users/searchers sign transactions targeting this executor (not the DApp directly)
 *      - The sequencer routes bundle operations through this contract
 *      - The executor wraps each call: inner reverts are caught and recorded, but the
 *        outer transaction always succeeds
 *      - A `BundleResult` event is emitted with the outcome (success/failure)
 *      - This event is provable on L1 via Merkle inclusion proofs
 *
 *      Fraud Proof Integration:
 *      If a sequencer executes BundleID X on Chain A (success=true) and Chain B
 *      (success=false), a challenger can submit both event proofs to the L1
 *      FraudProofVerifier. The verifier confirms the status mismatch and slashes
 *      the sequencer's bond.
 *
 *      This forces sequencers to simulate bundles off-chain before inclusion.
 *      If any operation would fail, the sequencer must exclude the ENTIRE bundle
 *      from ALL chains — achieving optimistic state atomicity.
 *
 *      Radius-style reference: https://ethresear.ch/t/based-preconfirmations-with-multi-chain-atomicity
 */
contract AtomicBundleExecutor is IAtomicBundleExecutor {
    // ============ Structs ============

    /// @notice Stored result of a bundle execution on this chain.
    struct ExecutionResult {
        bool executed;
        bool success;
        uint256 blockNumber;
    }

    // ============ State Variables ============

    /// @notice The L1 Hub or governance address that authorizes this executor
    address public governance;

    /// @notice The chain ID this executor is deployed on
    uint256 public immutable chainId;

    /// @notice Mapping from bundleId to execution result
    mapping(bytes32 => ExecutionResult) internal _results;

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotSequencer();
        _;
    }

    // ============ Constructor ============

    constructor(address _governance, uint256 _chainId) {
        if (_governance == address(0)) revert ZeroAddress();
        governance = _governance;
        chainId = _chainId;

        emit ExecutorRegistered(_chainId, address(this));
    }

    // ============ External Functions ============

    /// @inheritdoc IAtomicBundleExecutor
    function executeBundle(
        address target,
        bytes calldata data,
        bytes32 bundleId
    ) external payable override {
        if (target == address(0)) revert ZeroAddress();
        if (bundleId == bytes32(0)) revert ZeroBundleId();
        if (data.length == 0) revert EmptyCallData();

        // Execute the inner call — catch reverts
        (bool success, bytes memory returnData) = target.call{value: msg.value}(data);

        // Truncate return data on failure to limit gas costs for event storage
        if (!success && returnData.length > 256) {
            assembly {
                mstore(returnData, 256)
            }
        }

        // Record the result on-chain
        _results[bundleId] = ExecutionResult({
            executed: true,
            success: success,
            blockNumber: block.number
        });

        // Emit the result — this is the critical event for fraud proofs.
        // The outer tx ALWAYS succeeds. The inner success/failure is recorded here.
        emit BundleResult(bundleId, target, success, returnData);
    }

    /// @inheritdoc IAtomicBundleExecutor
    function executeBundleBatch(
        address[] calldata targets,
        bytes[] calldata datas,
        uint256[] calldata values,
        bytes32 bundleId
    ) external payable override {
        if (bundleId == bytes32(0)) revert ZeroBundleId();
        if (targets.length == 0 || targets.length != datas.length || targets.length != values.length) {
            revert EmptyCallData();
        }

        bool allSuccess = true;
        bytes memory lastReturnData;

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert ZeroAddress();

            (bool success, bytes memory returnData) = targets[i].call{value: values[i]}(datas[i]);

            if (!success) {
                allSuccess = false;
                // Store the first failure's return data for diagnostics
                if (lastReturnData.length == 0) {
                    lastReturnData = returnData;
                    if (lastReturnData.length > 256) {
                        assembly {
                            mstore(lastReturnData, 256)
                        }
                    }
                }
                // Stop executing remaining operations on first failure —
                // partial execution within a single chain is undesirable
                break;
            }

            lastReturnData = returnData;
        }

        // Record aggregate result
        _results[bundleId] = ExecutionResult({
            executed: true,
            success: allSuccess,
            blockNumber: block.number
        });

        emit BundleResult(bundleId, targets[0], allSuccess, lastReturnData);
    }

    // ============ View Functions ============

    /// @inheritdoc IAtomicBundleExecutor
    function getBundleResult(bytes32 bundleId)
        external
        view
        override
        returns (bool executed, bool success, uint256 blockNumber)
    {
        ExecutionResult memory result = _results[bundleId];
        return (result.executed, result.success, result.blockNumber);
    }

    // ============ Governance Functions ============

    /// @notice Update governance address
    function setGovernance(address _governance) external onlyGovernance {
        if (_governance == address(0)) revert ZeroAddress();
        governance = _governance;
    }

    /// @notice Allows the contract to receive ETH (for forwarding to targets)
    receive() external payable {}
}
