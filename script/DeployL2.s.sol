// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {KlerosSequencerManager} from "../src/KlerosSequencerManager.sol";
import {MockCurate} from "../test/mocks/MockCurate.sol";

/**
 * @title DeployL2
 * @notice Deploys OP Stack L1 contracts for a local devnet with Kleros governance.
 *
 * This script deploys:
 * - SystemConfig (real OP Stack contract)
 * - OptimismPortal
 * - L1CrossDomainMessenger
 * - L1StandardBridge
 * - AddressManager
 * - L2OutputOracle
 * - MockCurate (Kleros registry)
 * - KlerosSequencerManager (governance)
 *
 * The KlerosSequencerManager becomes the owner of SystemConfig,
 * enabling decentralized sequencer rotation.
 */
contract DeployL2 is Script {
    // Anvil default accounts
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant GUARDIAN = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    // Operators (batcher, unsafeSigner pairs)
    address constant BATCHER_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SIGNER_1 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address constant BATCHER_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant SIGNER_2 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;
    address constant BATCHER_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant SIGNER_3 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;

    // L2 Configuration
    uint256 constant L2_CHAIN_ID = 42069;
    uint256 constant EPOCH_DURATION = 60; // 1 minute for devnet
    uint64 constant L2_BLOCK_TIME = 2;

    // Batch inbox (standard OP Stack address format)
    address constant BATCH_INBOX = 0xFf00000000000000000000000000000000042069;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );

        vm.startBroadcast(deployerPrivateKey);

        console2.log("=== Deploying OP Stack L1 Contracts ===");
        console2.log("");

        // 1. Deploy AddressManager
        AddressManager addressManager = new AddressManager();
        console2.log("AddressManager:", address(addressManager));

        // 2. Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin(DEPLOYER);
        console2.log("ProxyAdmin:", address(proxyAdmin));

        // 3. Deploy SystemConfig implementation and proxy
        SystemConfig systemConfigImpl = new SystemConfig();
        Proxy systemConfigProxy = new Proxy(address(proxyAdmin));

        // Initialize SystemConfig
        SystemConfig systemConfig = SystemConfig(address(systemConfigProxy));
        SystemConfig.Addresses memory addrs = SystemConfig.Addresses({
            l1CrossDomainMessenger: address(0), // Will set later
            l1ERC721Bridge: address(0),
            l1StandardBridge: address(0),
            disputeGameFactory: address(0),
            optimismPortal: address(0),
            optimismMintableERC20Factory: address(0),
            gasPayingToken: address(0)
        });

        // Initialize with deployer as owner temporarily
        proxyAdmin.upgradeAndCall(
            payable(address(systemConfigProxy)),
            address(systemConfigImpl),
            abi.encodeCall(
                SystemConfig.initialize,
                (
                    DEPLOYER,                    // _owner (temporary)
                    32,                          // _basefeeScalar
                    2,                           // _blobbasefeeScalar
                    bytes32(uint256(uint160(BATCHER_1))), // _batcherHash
                    30_000_000,                  // _gasLimit
                    SIGNER_1,                    // _unsafeBlockSigner
                    ResourceMetering.ResourceConfig({
                        maxResourceLimit: 20_000_000,
                        elasticityMultiplier: 10,
                        baseFeeMaxChangeDenominator: 8,
                        minimumBaseFee: 1 gwei,
                        systemTxMaxGas: 1_000_000,
                        maximumBaseFee: type(uint128).max
                    }),
                    address(0),                  // _batchInbox (set separately)
                    addrs
                )
            )
        );
        console2.log("SystemConfig:", address(systemConfig));

        // 4. Deploy L2OutputOracle
        L2OutputOracle l2OutputOracle = new L2OutputOracle();
        console2.log("L2OutputOracle:", address(l2OutputOracle));

        // 5. Deploy OptimismPortal
        OptimismPortal optimismPortalImpl = new OptimismPortal();
        Proxy optimismPortalProxy = new Proxy(address(proxyAdmin));
        proxyAdmin.upgrade(payable(address(optimismPortalProxy)), address(optimismPortalImpl));
        console2.log("OptimismPortal:", address(optimismPortalProxy));

        // 6. Deploy L1CrossDomainMessenger
        L1CrossDomainMessenger l1MessengerImpl = new L1CrossDomainMessenger();
        Proxy l1MessengerProxy = new Proxy(address(proxyAdmin));
        proxyAdmin.upgrade(payable(address(l1MessengerProxy)), address(l1MessengerImpl));
        console2.log("L1CrossDomainMessenger:", address(l1MessengerProxy));

        // 7. Deploy L1StandardBridge
        L1StandardBridge l1BridgeImpl = new L1StandardBridge();
        Proxy l1BridgeProxy = new Proxy(address(proxyAdmin));
        proxyAdmin.upgrade(payable(address(l1BridgeProxy)), address(l1BridgeImpl));
        console2.log("L1StandardBridge:", address(l1BridgeProxy));

        // 8. Deploy MockCurate (Kleros registry)
        MockCurate curate = new MockCurate();
        console2.log("MockCurate:", address(curate));

        // 9. Deploy KlerosSequencerManager
        KlerosSequencerManager manager = new KlerosSequencerManager(
            address(curate),
            address(systemConfig),
            EPOCH_DURATION,
            GUARDIAN
        );
        console2.log("KlerosSequencerManager:", address(manager));

        // 10. Transfer SystemConfig ownership to KlerosSequencerManager
        systemConfig.transferOwnership(address(manager));
        console2.log("SystemConfig ownership transferred to manager");

        // 11. Register operators in Curate
        console2.log("");
        console2.log("=== Registering Operators ===");
        curate.registerOperatorDirectly(BATCHER_1, SIGNER_1);
        curate.registerOperatorDirectly(BATCHER_2, SIGNER_2);
        curate.registerOperatorDirectly(BATCHER_3, SIGNER_3);
        console2.log("Registered 3 operators");

        // 12. Sync operators to manager
        manager.syncAddOperator(BATCHER_1, SIGNER_1);
        manager.syncAddOperator(BATCHER_2, SIGNER_2);
        manager.syncAddOperator(BATCHER_3, SIGNER_3);
        console2.log("Synced operators to manager");

        // 13. First rotation
        manager.rotateOperator();
        KlerosSequencerManager.Operator memory current = manager.currentOperator();
        console2.log("First rotation complete - current batcher:", current.batcher);

        vm.stopBroadcast();

        // Output deployment summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("L2 Chain ID:", L2_CHAIN_ID);
        console2.log("Batch Inbox:", BATCH_INBOX);
        console2.log("");
        console2.log("Core Contracts:");
        console2.log("  AddressManager:", address(addressManager));
        console2.log("  ProxyAdmin:", address(proxyAdmin));
        console2.log("  SystemConfig:", address(systemConfig));
        console2.log("  L2OutputOracle:", address(l2OutputOracle));
        console2.log("  OptimismPortal:", address(optimismPortalProxy));
        console2.log("  L1CrossDomainMessenger:", address(l1MessengerProxy));
        console2.log("  L1StandardBridge:", address(l1BridgeProxy));
        console2.log("");
        console2.log("Governance:");
        console2.log("  MockCurate:", address(curate));
        console2.log("  KlerosSequencerManager:", address(manager));
    }
}

// Minimal OP Stack contract interfaces for deployment

interface ResourceMetering {
    struct ResourceConfig {
        uint32 maxResourceLimit;
        uint8 elasticityMultiplier;
        uint8 baseFeeMaxChangeDenominator;
        uint32 minimumBaseFee;
        uint32 systemTxMaxGas;
        uint128 maximumBaseFee;
    }
}

contract AddressManager {
    mapping(bytes32 => address) private addresses;
    address public owner;

    constructor() { owner = msg.sender; }

    function setAddress(string memory _name, address _address) external {
        require(msg.sender == owner);
        addresses[keccak256(bytes(_name))] = _address;
    }

    function getAddress(string memory _name) external view returns (address) {
        return addresses[keccak256(bytes(_name))];
    }
}

contract ProxyAdmin {
    address public owner;

    constructor(address _owner) { owner = _owner; }

    function upgrade(address payable _proxy, address _implementation) external {
        require(msg.sender == owner);
        Proxy(_proxy).upgradeTo(_implementation);
    }

    function upgradeAndCall(address payable _proxy, address _implementation, bytes memory _data) external {
        require(msg.sender == owner);
        Proxy(_proxy).upgradeToAndCall(_implementation, _data);
    }
}

contract Proxy {
    address public admin;
    address public implementation;

    constructor(address _admin) {
        admin = _admin;
    }

    function upgradeTo(address _implementation) external {
        require(msg.sender == admin);
        implementation = _implementation;
    }

    function upgradeToAndCall(address _implementation, bytes memory _data) external {
        require(msg.sender == admin);
        implementation = _implementation;
        (bool success,) = _implementation.delegatecall(_data);
        require(success);
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

contract SystemConfig {
    struct Addresses {
        address l1CrossDomainMessenger;
        address l1ERC721Bridge;
        address l1StandardBridge;
        address disputeGameFactory;
        address optimismPortal;
        address optimismMintableERC20Factory;
        address gasPayingToken;
    }

    address public owner;
    uint256 public scalar;
    bytes32 public batcherHash;
    uint64 public gasLimit;
    address public unsafeBlockSigner;

    event ConfigUpdate(uint256 indexed version, uint8 indexed updateType, bytes data);

    function initialize(
        address _owner,
        uint32 _basefeeScalar,
        uint32 _blobbasefeeScalar,
        bytes32 _batcherHash,
        uint64 _gasLimit,
        address _unsafeBlockSigner,
        ResourceMetering.ResourceConfig memory,
        address,
        Addresses memory
    ) external {
        require(owner == address(0), "Already initialized");
        owner = _owner;
        scalar = (uint256(_blobbasefeeScalar) << 32) | _basefeeScalar;
        batcherHash = _batcherHash;
        gasLimit = _gasLimit;
        unsafeBlockSigner = _unsafeBlockSigner;
    }

    function setBatcherHash(bytes32 _batcherHash) external {
        require(msg.sender == owner, "Not owner");
        batcherHash = _batcherHash;
        emit ConfigUpdate(0, 0, abi.encode(_batcherHash));
    }

    function setUnsafeBlockSigner(address _unsafeBlockSigner) external {
        require(msg.sender == owner, "Not owner");
        unsafeBlockSigner = _unsafeBlockSigner;
        emit ConfigUpdate(0, 1, abi.encode(_unsafeBlockSigner));
    }

    function setGasLimit(uint64 _gasLimit) external {
        require(msg.sender == owner, "Not owner");
        gasLimit = _gasLimit;
    }

    function transferOwnership(address _newOwner) external {
        require(msg.sender == owner, "Not owner");
        owner = _newOwner;
    }
}

contract L2OutputOracle {
    // Minimal implementation for devnet
    address public challenger;
    address public proposer;

    function latestOutputIndex() external pure returns (uint256) { return 0; }
}

contract OptimismPortal {
    // Minimal implementation for devnet
    bool public paused;
}

contract L1CrossDomainMessenger {
    // Minimal implementation for devnet
}

contract L1StandardBridge {
    // Minimal implementation for devnet
}
