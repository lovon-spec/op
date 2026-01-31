// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBuilderRegistry} from "./interfaces/IBuilderRegistry.sol";

/**
 * @title BuilderRegistry
 * @notice "The Value Engine" - Registry for builders in the KSSN PBS architecture.
 * @dev Builders are MEV Searchers / Market Makers responsible for transaction content.
 *      They maintain high bonds to cover "Bad Block" damages and must comply with
 *      chain-specific policies through the Sovereignty Matrix.
 *
 *      Key features:
 *      - Policy Tags: Builders accumulate tags (e.g., OFAC, KYC, No-MEV) to qualify for chains
 *      - Sovereignty Matrix: Maps builders to their policy compliance status
 *      - Union Rule: For atomic bundles across chains, builder must have ALL required tags
 *      - High Bonds: Significant stake to cover potential damages
 *
 *      Liability: Strictly liable for Content (Constitution violations) and Data Availability.
 */
contract BuilderRegistry is IBuilderRegistry {
    // ============ Constants ============

    /// @notice Default minimum bond (500 ETH as per spec)
    uint256 public constant DEFAULT_MINIMUM_BOND = 500 ether;

    /// @notice Default slash cooldown period (7 days)
    uint256 public constant DEFAULT_SLASH_COOLDOWN = 7 days;

    /// @notice Maximum slash count before permanent deactivation
    uint256 public constant MAX_SLASH_COUNT = 3;

    // ============ Policy Tag Constants ============

    /// @inheritdoc IBuilderRegistry
    bytes32 public constant override POLICY_OFAC = keccak256("POLICY_OFAC");

    /// @inheritdoc IBuilderRegistry
    bytes32 public constant override POLICY_KYC = keccak256("POLICY_KYC");

    /// @inheritdoc IBuilderRegistry
    bytes32 public constant override POLICY_NO_MEV = keccak256("POLICY_NO_MEV");

    /// @inheritdoc IBuilderRegistry
    bytes32 public constant override POLICY_NO_GAMBLING = keccak256("POLICY_NO_GAMBLING");

    /// @inheritdoc IBuilderRegistry
    bytes32 public constant override POLICY_NEUTRAL = keccak256("POLICY_NEUTRAL");

    // ============ State Variables ============

    /// @notice The minimum bond required to register
    uint256 public override minimumBond;

    /// @notice The cooldown period after slashing
    uint256 public slashCooldown;

    /// @notice The hub contract address
    address public override hub;

    /// @notice The governance address
    address public governance;

    /// @notice Builder information mapping
    mapping(address => BuilderInfo) internal _builders;

    /// @notice Policy tag status mapping: builder -> policyId -> status
    mapping(address => mapping(bytes32 => PolicyTagStatus)) internal _policyTags;

    /// @notice Array of policy tags held by each builder
    mapping(address => bytes32[]) internal _builderPolicyTagList;

    /// @notice Mapping to check if builder has a policy in their list
    mapping(address => mapping(bytes32 => bool)) internal _hasTagInList;

    /// @notice Array of all registered builder addresses
    address[] internal _registeredBuilders;

    /// @notice Mapping from builder to their index in the array (1-indexed)
    mapping(address => uint256) internal _builderIndex;

    /// @notice Array of active builders
    address[] internal _activeBuilders;

    /// @notice Mapping from active builder to index (1-indexed)
    mapping(address => uint256) internal _activeBuilderIndex;

    /// @notice Registered policies
    mapping(bytes32 => bool) internal _registeredPolicies;

    /// @notice Policy metadata
    mapping(bytes32 => string) internal _policyNames;
    mapping(bytes32 => string) internal _policyDescriptions;

    // ============ Modifiers ============

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyHubOrGovernance() {
        if (msg.sender != hub && msg.sender != governance) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the BuilderRegistry.
     * @param _governance The governance address
     * @param _hub The hub contract address
     * @param _minimumBond The minimum bond (0 for default)
     */
    constructor(
        address _governance,
        address _hub,
        uint256 _minimumBond
    ) {
        if (_governance == address(0)) revert Unauthorized();

        governance = _governance;
        hub = _hub;
        minimumBond = _minimumBond == 0 ? DEFAULT_MINIMUM_BOND : _minimumBond;
        slashCooldown = DEFAULT_SLASH_COOLDOWN;

        // Register default policies
        _registerPolicyInternal(POLICY_OFAC, "OFAC Compliance", "Filters OFAC-sanctioned addresses");
        _registerPolicyInternal(POLICY_KYC, "KYC Compliance", "Only includes KYC-verified transactions");
        _registerPolicyInternal(POLICY_NO_MEV, "No MEV", "Commits to fair ordering, no frontrunning");
        _registerPolicyInternal(POLICY_NO_GAMBLING, "No Gambling", "Filters gambling-related transactions");
        _registerPolicyInternal(POLICY_NEUTRAL, "Neutral", "No restrictions, permissionless");
    }

    // ============ View Functions ============

    /// @inheritdoc IBuilderRegistry
    function getBuilderInfo(address _builder) external view override returns (BuilderInfo memory) {
        return _builders[_builder];
    }

    /// @inheritdoc IBuilderRegistry
    function hasPolicyTag(address _builder, bytes32 _policyId) public view override returns (bool) {
        PolicyTagStatus storage status = _policyTags[_builder][_policyId];

        // Must be granted
        if (!status.isGranted) return false;

        // Must not be revoked
        if (status.revokedAt > 0) return false;

        // Must not be expired (0 = never expires)
        if (status.expiresAt > 0 && block.timestamp > status.expiresAt) return false;

        return true;
    }

    /// @inheritdoc IBuilderRegistry
    function getPolicyTagStatus(
        address _builder,
        bytes32 _policyId
    ) external view override returns (PolicyTagStatus memory) {
        return _policyTags[_builder][_policyId];
    }

    /// @inheritdoc IBuilderRegistry
    function getBuilderPolicyTags(address _builder) external view override returns (bytes32[] memory) {
        return _builderPolicyTagList[_builder];
    }

    /// @inheritdoc IBuilderRegistry
    function isBuilderEligible(address _builder, bytes32 _policyId) public view override returns (bool) {
        BuilderInfo storage info = _builders[_builder];

        // Must be active
        if (!info.isActive) return false;

        // Must not be in cooldown
        if (info.lastSlashTime > 0 && block.timestamp < info.lastSlashTime + slashCooldown) {
            return false;
        }

        // POLICY_NEUTRAL matches any active builder
        if (_policyId == POLICY_NEUTRAL) return true;

        // Must have the required policy tag
        return hasPolicyTag(_builder, _policyId);
    }

    /// @inheritdoc IBuilderRegistry
    function isBuilderEligibleForBundle(
        address _builder,
        bytes32[] calldata _policyIds
    ) external view override returns (bool) {
        BuilderInfo storage info = _builders[_builder];

        // Must be active
        if (!info.isActive) return false;

        // Must not be in cooldown
        if (info.lastSlashTime > 0 && block.timestamp < info.lastSlashTime + slashCooldown) {
            return false;
        }

        // Union Rule: must have ALL required policy tags
        for (uint256 i = 0; i < _policyIds.length; i++) {
            bytes32 policyId = _policyIds[i];

            // POLICY_NEUTRAL doesn't require a tag
            if (policyId == POLICY_NEUTRAL) continue;

            if (!hasPolicyTag(_builder, policyId)) {
                return false;
            }
        }

        return true;
    }

    /// @inheritdoc IBuilderRegistry
    function getRegisteredBuilderCount() external view override returns (uint256) {
        return _registeredBuilders.length;
    }

    /// @inheritdoc IBuilderRegistry
    function getActiveBuilderCount() external view override returns (uint256) {
        return _activeBuilders.length;
    }

    /// @inheritdoc IBuilderRegistry
    function getActiveBuilders() external view override returns (address[] memory) {
        return _activeBuilders;
    }

    /// @inheritdoc IBuilderRegistry
    function getBuildersForPolicy(bytes32 _policyId) external view override returns (address[] memory) {
        // Count eligible builders first
        uint256 count = 0;
        for (uint256 i = 0; i < _activeBuilders.length; i++) {
            if (isBuilderEligible(_activeBuilders[i], _policyId)) {
                count++;
            }
        }

        // Build result array
        address[] memory result = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _activeBuilders.length; i++) {
            if (isBuilderEligible(_activeBuilders[i], _policyId)) {
                result[index] = _activeBuilders[i];
                index++;
            }
        }

        return result;
    }

    // ============ Builder Functions ============

    /// @inheritdoc IBuilderRegistry
    function register() external payable override {
        if (_builders[msg.sender].bond > 0) revert BuilderAlreadyRegistered(msg.sender);
        if (msg.value < minimumBond) revert InsufficientBond(msg.value, minimumBond);

        // Create builder info
        _builders[msg.sender] = BuilderInfo({
            bond: msg.value,
            isActive: true,
            registrationTime: block.timestamp,
            slashCount: 0,
            lastSlashTime: 0
        });

        // Add to registered list
        _registeredBuilders.push(msg.sender);
        _builderIndex[msg.sender] = _registeredBuilders.length;

        // Add to active list
        _activeBuilders.push(msg.sender);
        _activeBuilderIndex[msg.sender] = _activeBuilders.length;

        // Grant POLICY_NEUTRAL by default
        _grantPolicyTagInternal(msg.sender, POLICY_NEUTRAL, 0);

        emit BuilderRegistered(msg.sender, msg.value);
    }

    /// @inheritdoc IBuilderRegistry
    function unregister() external override {
        BuilderInfo storage info = _builders[msg.sender];
        if (info.bond == 0) revert BuilderNotRegistered(msg.sender);

        // Cannot unregister during cooldown
        if (info.lastSlashTime > 0 && block.timestamp < info.lastSlashTime + slashCooldown) {
            revert BuilderInCooldown(msg.sender, info.lastSlashTime + slashCooldown);
        }

        uint256 bondToReturn = info.bond;

        // Remove from active list if active
        if (info.isActive) {
            _removeFromActiveList(msg.sender);
        }

        // Remove from registered list
        _removeFromRegisteredList(msg.sender);

        // Clear builder info
        delete _builders[msg.sender];

        // Clear policy tags
        bytes32[] storage tags = _builderPolicyTagList[msg.sender];
        for (uint256 i = 0; i < tags.length; i++) {
            delete _policyTags[msg.sender][tags[i]];
            delete _hasTagInList[msg.sender][tags[i]];
        }
        delete _builderPolicyTagList[msg.sender];

        // Return bond
        if (bondToReturn > 0) {
            (bool success, ) = msg.sender.call{value: bondToReturn}("");
            require(success, "Transfer failed");
        }

        emit BuilderUnregistered(msg.sender, bondToReturn);
    }

    /// @inheritdoc IBuilderRegistry
    function addBond() external payable override {
        BuilderInfo storage info = _builders[msg.sender];
        if (info.bond == 0) revert BuilderNotRegistered(msg.sender);

        info.bond += msg.value;

        emit BondAdded(msg.sender, msg.value, info.bond);
    }

    /// @inheritdoc IBuilderRegistry
    function withdrawBond(uint256 _amount) external override {
        BuilderInfo storage info = _builders[msg.sender];
        if (info.bond == 0) revert BuilderNotRegistered(msg.sender);

        // Cannot withdraw below minimum while registered
        if (info.bond - _amount < minimumBond) {
            revert InsufficientBond(info.bond - _amount, minimumBond);
        }

        if (_amount > info.bond) {
            revert InsufficientBond(_amount, info.bond);
        }

        info.bond -= _amount;

        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "Transfer failed");

        emit BondWithdrawn(msg.sender, _amount, info.bond);
    }

    // ============ Policy Functions ============

    /// @inheritdoc IBuilderRegistry
    function grantPolicyTag(
        address _builder,
        bytes32 _policyId,
        uint256 _expiresAt
    ) external override onlyHubOrGovernance {
        _grantPolicyTagInternal(_builder, _policyId, _expiresAt);
    }

    /// @inheritdoc IBuilderRegistry
    function revokePolicyTag(
        address _builder,
        bytes32 _policyId,
        string calldata _reason
    ) external override onlyHubOrGovernance {
        if (_builders[_builder].bond == 0) revert BuilderNotRegistered(_builder);
        if (!_registeredPolicies[_policyId]) revert InvalidPolicyTag(_policyId);

        PolicyTagStatus storage status = _policyTags[_builder][_policyId];
        if (!status.isGranted) revert MissingPolicyTag(_builder, _policyId);

        status.revokedAt = block.timestamp;

        emit PolicyTagRevoked(_builder, _policyId, _reason);
    }

    /// @inheritdoc IBuilderRegistry
    function slash(
        address _builder,
        uint256 _amount,
        bytes32 _policyId,
        string calldata _reason
    ) external override onlyHubOrGovernance {
        BuilderInfo storage info = _builders[_builder];
        if (info.bond == 0) revert BuilderNotRegistered(_builder);

        if (_amount > info.bond) {
            revert SlashExceedsBond(_amount, info.bond);
        }

        info.bond -= _amount;
        info.slashCount++;
        info.lastSlashTime = block.timestamp;

        emit BuilderSlashed(_builder, _amount, _policyId, _reason);

        // Auto-deactivate if max slash count reached
        if (info.slashCount >= MAX_SLASH_COUNT) {
            _deactivateInternal(_builder, "Maximum slash count reached");
        }

        // Slashed funds go to contract (can be distributed as compensation)
    }

    /// @inheritdoc IBuilderRegistry
    function deactivate(address _builder, string calldata _reason) external override onlyHubOrGovernance {
        _deactivateInternal(_builder, _reason);
    }

    /// @inheritdoc IBuilderRegistry
    function reactivate(address _builder) external override onlyHubOrGovernance {
        BuilderInfo storage info = _builders[_builder];
        if (info.bond == 0) revert BuilderNotRegistered(_builder);

        if (info.isActive) return;

        info.isActive = true;
        _activeBuilders.push(_builder);
        _activeBuilderIndex[_builder] = _activeBuilders.length;

        emit BuilderReactivated(_builder);
    }

    // ============ Governance Functions ============

    /// @inheritdoc IBuilderRegistry
    function registerPolicy(
        bytes32 _policyId,
        string calldata _name,
        string calldata _description
    ) external override onlyGovernance {
        _registerPolicyInternal(_policyId, _name, _description);
    }

    /// @inheritdoc IBuilderRegistry
    function setMinimumBond(uint256 _newMinimum) external override onlyGovernance {
        minimumBond = _newMinimum;
    }

    /// @inheritdoc IBuilderRegistry
    function setHub(address _hub) external override onlyGovernance {
        if (_hub == address(0)) revert InvalidHub();
        hub = _hub;
    }

    /// @inheritdoc IBuilderRegistry
    function setSlashCooldown(uint256 _period) external override onlyGovernance {
        slashCooldown = _period;
    }

    /**
     * @notice Updates the governance address.
     * @param _newGovernance The new governance address
     */
    function setGovernance(address _newGovernance) external onlyGovernance {
        if (_newGovernance == address(0)) revert Unauthorized();
        governance = _newGovernance;
    }

    // ============ Internal Functions ============

    /**
     * @dev Internal function to grant a policy tag.
     */
    function _grantPolicyTagInternal(
        address _builder,
        bytes32 _policyId,
        uint256 _expiresAt
    ) internal {
        if (_builders[_builder].bond == 0) revert BuilderNotRegistered(_builder);
        if (!_registeredPolicies[_policyId]) revert InvalidPolicyTag(_policyId);

        PolicyTagStatus storage status = _policyTags[_builder][_policyId];
        status.isGranted = true;
        status.grantedAt = block.timestamp;
        status.expiresAt = _expiresAt;
        status.revokedAt = 0; // Clear any previous revocation

        // Add to builder's tag list if not already there
        if (!_hasTagInList[_builder][_policyId]) {
            _builderPolicyTagList[_builder].push(_policyId);
            _hasTagInList[_builder][_policyId] = true;
        }

        emit PolicyTagGranted(_builder, _policyId, _expiresAt);
    }

    /**
     * @dev Internal function to register a policy.
     */
    function _registerPolicyInternal(
        bytes32 _policyId,
        string memory _name,
        string memory _description
    ) internal {
        _registeredPolicies[_policyId] = true;
        _policyNames[_policyId] = _name;
        _policyDescriptions[_policyId] = _description;

        emit PolicyRegistered(_policyId, _name, _description);
    }

    /**
     * @dev Internal function to deactivate a builder.
     */
    function _deactivateInternal(address _builder, string memory _reason) internal {
        BuilderInfo storage info = _builders[_builder];
        if (info.bond == 0) revert BuilderNotRegistered(_builder);

        if (!info.isActive) return;

        info.isActive = false;
        _removeFromActiveList(_builder);

        emit BuilderDeactivated(_builder, _reason);
    }

    /**
     * @dev Removes a builder from the active list.
     */
    function _removeFromActiveList(address _builder) internal {
        uint256 index = _activeBuilderIndex[_builder];
        if (index == 0) return;

        uint256 arrayIndex = index - 1;

        if (arrayIndex != _activeBuilders.length - 1) {
            address lastBuilder = _activeBuilders[_activeBuilders.length - 1];
            _activeBuilders[arrayIndex] = lastBuilder;
            _activeBuilderIndex[lastBuilder] = index;
        }

        _activeBuilders.pop();
        delete _activeBuilderIndex[_builder];
    }

    /**
     * @dev Removes a builder from the registered list.
     */
    function _removeFromRegisteredList(address _builder) internal {
        uint256 index = _builderIndex[_builder];
        if (index == 0) return;

        uint256 arrayIndex = index - 1;

        if (arrayIndex != _registeredBuilders.length - 1) {
            address lastBuilder = _registeredBuilders[_registeredBuilders.length - 1];
            _registeredBuilders[arrayIndex] = lastBuilder;
            _builderIndex[lastBuilder] = index;
        }

        _registeredBuilders.pop();
        delete _builderIndex[_builder];
    }

    // ============ Helper Functions ============

    /**
     * @notice Returns all registered builders.
     * @return Array of registered builder addresses
     */
    function getRegisteredBuilders() external view returns (address[] memory) {
        return _registeredBuilders;
    }

    /**
     * @notice Checks if a builder is registered.
     * @param _builder The builder address
     * @return True if registered
     */
    function isRegistered(address _builder) external view returns (bool) {
        return _builders[_builder].bond > 0;
    }

    /**
     * @notice Returns policy metadata.
     * @param _policyId The policy ID
     * @return name The policy name
     * @return description The policy description
     */
    function getPolicyInfo(bytes32 _policyId) external view returns (string memory name, string memory description) {
        return (_policyNames[_policyId], _policyDescriptions[_policyId]);
    }

    /**
     * @notice Checks if a policy is registered.
     * @param _policyId The policy ID
     * @return True if registered
     */
    function isPolicyRegistered(bytes32 _policyId) external view returns (bool) {
        return _registeredPolicies[_policyId];
    }

    /**
     * @notice Checks if a builder is in cooldown.
     * @param _builder The builder address
     * @return True if in cooldown
     */
    function isInCooldown(address _builder) external view returns (bool) {
        BuilderInfo storage info = _builders[_builder];
        return info.lastSlashTime > 0 && block.timestamp < info.lastSlashTime + slashCooldown;
    }

    /**
     * @notice Returns when cooldown ends for a builder.
     * @param _builder The builder address
     * @return The cooldown end timestamp (0 if not in cooldown)
     */
    function getCooldownEnd(address _builder) external view returns (uint256) {
        BuilderInfo storage info = _builders[_builder];
        if (info.lastSlashTime == 0) return 0;
        uint256 cooldownEnd = info.lastSlashTime + slashCooldown;
        if (block.timestamp >= cooldownEnd) return 0;
        return cooldownEnd;
    }

    /**
     * @notice Receive function to accept ETH (for slashed funds).
     */
    receive() external payable {}
}
