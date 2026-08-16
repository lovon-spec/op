#!/usr/bin/env python3
"""
Unit tests for the Self-Activation Agent with Active Handoff Protocol.

These tests verify:
1. State machine transitions (INACTIVE -> ACTIVE -> HANDOFF_PENDING -> INACTIVE)
2. Grace period calculations
3. Handoff sequence execution
4. Configuration loading
5. OPStackController behavior

Run with: pytest test_self_activation_agent.py -v
"""

import pytest
from unittest.mock import Mock, MagicMock, patch
from dataclasses import dataclass
from enum import Enum, auto

# Import the module under test
from self_activation_agent import (
    AgentState,
    Config,
    OPStackController,
    SelfActivationAgent,
)


class TestAgentState:
    """Test the AgentState enum."""

    def test_state_values(self):
        """Verify all expected states exist."""
        assert AgentState.INACTIVE is not None
        assert AgentState.ACTIVE is not None
        assert AgentState.HANDOFF_PENDING is not None

    def test_states_are_distinct(self):
        """Verify states are distinct."""
        assert AgentState.INACTIVE != AgentState.ACTIVE
        assert AgentState.ACTIVE != AgentState.HANDOFF_PENDING
        assert AgentState.INACTIVE != AgentState.HANDOFF_PENDING


class TestConfig:
    """Test configuration loading and defaults."""

    def test_config_defaults(self):
        """Verify default configuration values."""
        config = Config(
            l1_rpc="http://localhost:8545",
            manager_address="0x1234",
            batcher_address="0x5678",
            unsafe_signer_address="0x9abc",
        )
        assert config.poll_interval == 12
        assert config.op_node_admin_url == "http://localhost:7545"
        assert config.op_batcher_admin_url == "http://localhost:7546"
        assert config.handoff_lead_time == 60
        assert config.flush_timeout == 300
        assert config.private_key == ""

    def test_config_custom_values(self):
        """Verify custom configuration values are preserved."""
        config = Config(
            l1_rpc="http://mainnet:8545",
            manager_address="0xmanager",
            batcher_address="0xbatcher",
            unsafe_signer_address="0xsigner",
            private_key="0xprivkey",
            poll_interval=6,
            op_node_admin_url="http://node:7545",
            op_batcher_admin_url="http://batcher:7546",
            handoff_lead_time=120,
            flush_timeout=600,
        )
        assert config.l1_rpc == "http://mainnet:8545"
        assert config.private_key == "0xprivkey"
        assert config.poll_interval == 6
        assert config.handoff_lead_time == 120
        assert config.flush_timeout == 600

    def test_config_from_yaml(self, tmp_path):
        """Test loading configuration from YAML file."""
        config_file = tmp_path / "config.yaml"
        config_file.write_text("""
l1_rpc: "http://test:8545"
manager_address: "0xmanager"
batcher_address: "0xbatcher"
unsafe_signer_address: "0xsigner"
private_key: "0xkey"
poll_interval: 10
handoff_lead_time: 90
flush_timeout: 400
""")
        config = Config.from_yaml(str(config_file))
        assert config.l1_rpc == "http://test:8545"
        assert config.manager_address == "0xmanager"
        assert config.poll_interval == 10
        assert config.handoff_lead_time == 90
        assert config.flush_timeout == 400


class TestOPStackController:
    """Test the OPStackController class."""

    def setup_method(self):
        """Set up test fixtures."""
        self.controller = OPStackController(
            op_node_url="http://localhost:7545",
            op_batcher_url="http://localhost:7546"
        )

    @patch('self_activation_agent.requests.post')
    def test_start_sequencer_success(self, mock_post):
        """Test successful sequencer start."""
        mock_post.return_value.json.return_value = {"result": True}

        result = self.controller.start_sequencer()

        assert result is True
        assert self.controller._sequencer_active is True
        mock_post.assert_called_once()

    @patch('self_activation_agent.requests.post')
    def test_start_sequencer_already_active(self, mock_post):
        """Test starting sequencer when already active."""
        self.controller._sequencer_active = True

        result = self.controller.start_sequencer()

        assert result is True
        mock_post.assert_not_called()

    @patch('self_activation_agent.requests.post')
    def test_start_sequencer_error(self, mock_post):
        """Test sequencer start with RPC error."""
        mock_post.return_value.json.return_value = {"error": "failed"}

        result = self.controller.start_sequencer()

        assert result is False
        assert self.controller._sequencer_active is False

    @patch('self_activation_agent.requests.post')
    def test_stop_sequencer_success(self, mock_post):
        """Test successful sequencer stop."""
        self.controller._sequencer_active = True
        mock_post.return_value.json.return_value = {"result": True}

        result = self.controller.stop_sequencer()

        assert result is True
        assert self.controller._sequencer_active is False

    @patch('self_activation_agent.requests.post')
    def test_stop_sequencer_already_stopped(self, mock_post):
        """Test stopping sequencer when already stopped."""
        self.controller._sequencer_active = False

        result = self.controller.stop_sequencer()

        assert result is True
        mock_post.assert_not_called()

    @patch('self_activation_agent.requests.post')
    def test_start_batcher_success(self, mock_post):
        """Test successful batcher start."""
        mock_post.return_value.json.return_value = {"result": True}

        result = self.controller.start_batcher()

        assert result is True
        assert self.controller._batcher_active is True

    @patch('self_activation_agent.requests.post')
    def test_stop_batcher_success(self, mock_post):
        """Test successful batcher stop."""
        self.controller._batcher_active = True
        mock_post.return_value.json.return_value = {"result": True}

        result = self.controller.stop_batcher()

        assert result is True
        assert self.controller._batcher_active is False

    @patch('self_activation_agent.requests.post')
    def test_activate_starts_both(self, mock_post):
        """Test activate starts both sequencer and batcher."""
        mock_post.return_value.json.return_value = {"result": True}

        result = self.controller.activate()

        assert result is True
        assert self.controller._sequencer_active is True
        assert self.controller._batcher_active is True
        assert mock_post.call_count == 2

    @patch('self_activation_agent.requests.post')
    def test_deactivate_stops_both(self, mock_post):
        """Test deactivate stops both batcher and sequencer."""
        self.controller._sequencer_active = True
        self.controller._batcher_active = True
        mock_post.return_value.json.return_value = {"result": True}

        result = self.controller.deactivate()

        assert result is True
        assert self.controller._sequencer_active is False
        assert self.controller._batcher_active is False
        assert mock_post.call_count == 2

    @patch('self_activation_agent.requests.post')
    def test_flush_batches_success(self, mock_post):
        """Test successful batch flush."""
        # First call: batcherStatus
        # Second call: flushChannel
        # Third call: batcherStatus (check completion)
        mock_post.return_value.json.side_effect = [
            {"result": {"pendingFrames": 5}},  # Initial status
            {"result": True},                   # Flush triggered
            {"result": {"pendingFrames": 0}},   # Flush complete
        ]

        result = self.controller.flush_batches(timeout=10)

        assert result is True

    @patch('self_activation_agent.requests.post')
    def test_flush_batches_fallback_to_stop(self, mock_post):
        """Test flush falls back to stop_batcher if flushChannel unavailable."""
        mock_post.return_value.json.side_effect = [
            {"result": {}},                     # Initial status
            {"error": "method not found"},      # flushChannel not available
            {"result": True},                   # stopBatcher succeeds
        ]
        self.controller._batcher_active = True

        result = self.controller.flush_batches(timeout=10)

        assert result is True
        assert self.controller._batcher_active is False


class TestSelfActivationAgent:
    """Test the SelfActivationAgent class."""

    def setup_method(self):
        """Set up test fixtures with mocked web3."""
        self.config = Config(
            l1_rpc="http://localhost:8545",
            manager_address="0x1234567890123456789012345678901234567890",
            batcher_address="0xBatcherBatcherBatcherBatcherBatcherBat",
            unsafe_signer_address="0xSignerSignerSignerSignerSignerSigner",
            private_key="0x" + "a" * 64,
            handoff_lead_time=60,
            flush_timeout=300,
        )

    @patch('self_activation_agent.Web3')
    def test_agent_initialization(self, mock_web3_class):
        """Test agent initializes correctly."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)

        assert agent._state == AgentState.INACTIVE
        assert agent._epoch_duration is None
        assert agent._grace_period is None

    @patch('self_activation_agent.Web3')
    def test_agent_connection_error(self, mock_web3_class):
        """Test agent raises error if cannot connect to L1."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = False
        mock_web3_class.return_value = mock_web3
        mock_web3_class.HTTPProvider = MagicMock()

        with pytest.raises(ConnectionError):
            SelfActivationAgent(self.config)

    @patch('self_activation_agent.Web3')
    def test_check_is_current_operator(self, mock_web3_class):
        """Test checking current operator status."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)

        # Mock the contract call
        agent.manager.functions.isCurrentOperator.return_value.call.return_value = True

        result = agent.check_is_current_operator()

        assert result is True

    @patch('self_activation_agent.Web3')
    def test_is_in_grace_period(self, mock_web3_class):
        """Test grace period detection."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)
        agent._epoch_duration = 3600  # 1 hour
        agent._grace_period = 600     # 10 minutes

        # Mock: last rotation was 3700 seconds ago (in grace period)
        agent.manager.functions.lastRotationTimestamp.return_value.call.return_value = 0
        mock_web3.eth.get_block.return_value = {'timestamp': 3700}

        result = agent.is_in_grace_period()

        assert result is True

    @patch('self_activation_agent.Web3')
    def test_is_past_grace_period(self, mock_web3_class):
        """Test dead man's switch detection."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)
        agent._epoch_duration = 3600  # 1 hour
        agent._grace_period = 600     # 10 minutes

        # Mock: last rotation was 4300 seconds ago (past grace period)
        agent.manager.functions.lastRotationTimestamp.return_value.call.return_value = 0
        mock_web3.eth.get_block.return_value = {'timestamp': 4300}

        result = agent.is_past_grace_period()

        assert result is True

    @patch('self_activation_agent.Web3')
    def test_state_transition_inactive_to_active(self, mock_web3_class):
        """Test state transition from INACTIVE to ACTIVE."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)
        agent._state = AgentState.INACTIVE
        agent._epoch_duration = 3600
        agent._grace_period = 600

        # Mock: we are the current operator
        agent.manager.functions.isCurrentOperator.return_value.call.return_value = True
        agent.manager.functions.timeUntilNextRotation.return_value.call.return_value = 3000

        # Mock controller
        agent.controller = MagicMock()
        agent.controller.activate.return_value = True

        agent.run_once()

        assert agent._state == AgentState.ACTIVE
        agent.controller.activate.assert_called_once()

    @patch('self_activation_agent.Web3')
    def test_state_transition_active_to_handoff_pending(self, mock_web3_class):
        """Test state transition from ACTIVE to HANDOFF_PENDING."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)
        agent._state = AgentState.ACTIVE
        agent._epoch_duration = 3600
        agent._grace_period = 600
        agent.config.handoff_lead_time = 60

        # Mock: we are current operator, epoch ending soon
        agent.manager.functions.isCurrentOperator.return_value.call.return_value = True
        agent.manager.functions.timeUntilNextRotation.return_value.call.return_value = 30  # < handoff_lead_time

        agent.run_once()

        assert agent._state == AgentState.HANDOFF_PENDING

    @patch('self_activation_agent.Web3')
    def test_state_transition_handoff_to_inactive(self, mock_web3_class):
        """Test state transition from HANDOFF_PENDING to INACTIVE after handoff."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)
        agent._state = AgentState.HANDOFF_PENDING
        agent._epoch_duration = 3600
        agent._grace_period = 600

        # Mock: in grace period
        agent.manager.functions.lastRotationTimestamp.return_value.call.return_value = 0
        mock_web3.eth.get_block.return_value = {'timestamp': 3700}
        agent.manager.functions.isCurrentOperator.return_value.call.return_value = True
        agent.manager.functions.timeUntilNextRotation.return_value.call.return_value = 0

        # Mock controller and account
        agent.controller = MagicMock()
        agent.controller.stop_sequencer.return_value = True
        agent.controller.flush_batches.return_value = True
        agent.controller.stop_batcher.return_value = True
        agent.account = MagicMock()

        # Mock rotateOperator transaction
        agent.manager.functions.rotateOperator.return_value.build_transaction.return_value = {}
        mock_web3.eth.account.sign_transaction.return_value.raw_transaction = b'raw'
        mock_web3.eth.send_raw_transaction.return_value = b'txhash'
        mock_web3.eth.wait_for_transaction_receipt.return_value = {'status': 1, 'blockNumber': 100}
        mock_web3.eth.get_transaction_count.return_value = 0
        mock_web3.eth.gas_price = 1000000000

        agent.run_once()

        assert agent._state == AgentState.INACTIVE
        agent.controller.stop_sequencer.assert_called()
        agent.controller.flush_batches.assert_called()

    @patch('self_activation_agent.Web3')
    def test_rotated_out_externally(self, mock_web3_class):
        """Test handling when rotated out by external party (Dead Man's Switch)."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        agent = SelfActivationAgent(self.config)
        agent._state = AgentState.ACTIVE
        agent._epoch_duration = 3600
        agent._grace_period = 600

        # Mock: we are NOT the current operator anymore
        agent.manager.functions.isCurrentOperator.return_value.call.return_value = False
        agent.manager.functions.timeUntilNextRotation.return_value.call.return_value = 0

        # Mock controller
        agent.controller = MagicMock()
        agent.controller.deactivate.return_value = True

        agent.run_once()

        assert agent._state == AgentState.INACTIVE
        agent.controller.deactivate.assert_called_once()


class TestExecuteHandoff:
    """Test the handoff execution sequence."""

    @patch('self_activation_agent.Web3')
    def test_execute_handoff_full_sequence(self, mock_web3_class):
        """Test the full handoff sequence executes in order."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        config = Config(
            l1_rpc="http://localhost:8545",
            manager_address="0x1234567890123456789012345678901234567890",
            batcher_address="0xBatcherBatcherBatcherBatcherBatcherBat",
            unsafe_signer_address="0xSignerSignerSignerSignerSignerSigner",
            private_key="0x" + "a" * 64,
            flush_timeout=10,
        )

        agent = SelfActivationAgent(config)

        # Track call order
        call_order = []

        agent.controller = MagicMock()
        agent.controller.stop_sequencer.side_effect = lambda: call_order.append('stop_sequencer') or True
        agent.controller.flush_batches.side_effect = lambda timeout: call_order.append('flush_batches') or True
        agent.controller.stop_batcher.side_effect = lambda: call_order.append('stop_batcher') or True

        agent.account = MagicMock()
        agent.manager.functions.rotateOperator.return_value.build_transaction.return_value = {}
        mock_web3.eth.account.sign_transaction.return_value.raw_transaction = b'raw'
        mock_web3.eth.send_raw_transaction.return_value = b'txhash'
        mock_web3.eth.wait_for_transaction_receipt.return_value = {'status': 1, 'blockNumber': 100}
        mock_web3.eth.get_transaction_count.return_value = 0
        mock_web3.eth.gas_price = 1000000000

        def track_rotate():
            call_order.append('rotateOperator')
            return True

        with patch.object(agent, 'call_rotate_operator', side_effect=track_rotate):
            result = agent.execute_handoff()

        assert result is True
        assert call_order == ['stop_sequencer', 'flush_batches', 'rotateOperator', 'stop_batcher']

    @patch('self_activation_agent.Web3')
    def test_execute_handoff_continues_on_sequencer_stop_failure(self, mock_web3_class):
        """Test handoff continues even if sequencer stop fails."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        config = Config(
            l1_rpc="http://localhost:8545",
            manager_address="0x1234567890123456789012345678901234567890",
            batcher_address="0xBatcherBatcherBatcherBatcherBatcherBat",
            unsafe_signer_address="0xSignerSignerSignerSignerSignerSigner",
            private_key="0x" + "a" * 64,
        )

        agent = SelfActivationAgent(config)
        agent.controller = MagicMock()
        agent.controller.stop_sequencer.return_value = False  # Fails!
        agent.controller.flush_batches.return_value = True
        agent.controller.stop_batcher.return_value = True
        agent.account = MagicMock()

        agent.manager.functions.rotateOperator.return_value.build_transaction.return_value = {}
        mock_web3.eth.account.sign_transaction.return_value.raw_transaction = b'raw'
        mock_web3.eth.send_raw_transaction.return_value = b'txhash'
        mock_web3.eth.wait_for_transaction_receipt.return_value = {'status': 1, 'blockNumber': 100}
        mock_web3.eth.get_transaction_count.return_value = 0
        mock_web3.eth.gas_price = 1000000000

        result = agent.execute_handoff()

        # Should still complete the handoff
        assert result is True
        agent.controller.flush_batches.assert_called()

    @patch('self_activation_agent.Web3')
    def test_execute_handoff_no_private_key(self, mock_web3_class):
        """Test handoff continues even without private key (can't call rotate)."""
        mock_web3 = MagicMock()
        mock_web3.is_connected.return_value = True
        mock_web3_class.return_value = mock_web3
        mock_web3_class.to_checksum_address = lambda x: x
        mock_web3_class.HTTPProvider = MagicMock()

        config = Config(
            l1_rpc="http://localhost:8545",
            manager_address="0x1234567890123456789012345678901234567890",
            batcher_address="0xBatcherBatcherBatcherBatcherBatcherBat",
            unsafe_signer_address="0xSignerSignerSignerSignerSignerSigner",
            private_key="",  # No private key!
        )

        agent = SelfActivationAgent(config)
        agent.controller = MagicMock()
        agent.controller.stop_sequencer.return_value = True
        agent.controller.flush_batches.return_value = True
        agent.controller.stop_batcher.return_value = True

        result = agent.execute_handoff()

        # Should still complete (rotation will fail but handoff continues)
        assert result is True


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
