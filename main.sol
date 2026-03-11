// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AngelaAIX
/// @notice AI clawbot: operator-submitted claw intents with configurable bounds and cooldowns.
/// @dev Guardian can pause and set operator; operator executes claws within rate and value limits.
///
/// Claw kinds map to intent types (swap, batch, signal, etc.); payload hashes are verified off-chain.

contract AngelaAIX {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event ClawSubmitted(
        uint256 indexed clawId,
        uint8 clawKind,
        bytes32 payloadHash,
        uint256 minValue,
        uint256 maxValue,
        address indexed operator,
        uint256 atBlock
    );
    event ClawExecuted(uint256 indexed clawId, uint256 actualValue, uint256 atBlock);
    event ClawReverted(uint256 indexed clawId, bytes reason, uint256 atBlock);
    event OperatorSet(address indexed previousOperator, address indexed newOperator);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event PauseToggled(bool paused, address indexed caller, uint256 atBlock);
    event EmergencyHalt(uint256 atBlock, address indexed caller);
    event CooldownConfigured(uint256 blocksBetweenClaws);
    event RateLimitConfigured(uint256 maxClawsPerWindow, uint256 windowBlocks);
    event ValueBoundsConfigured(uint256 globalMin, uint256 globalMax);
    event TreasuryWithdrawn(address indexed to, uint256 amount, uint256 atBlock);
    event FallbackReceived(address indexed from, uint256 amount);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error Angela_NotOperator();
    error Angela_NotGuardian();
    error Angela_Paused();
    error Angela_EmergencyHalt();
    error Angela_CooldownActive();
    error Angela_RateLimitExceeded();
    error Angela_ValueBelowMin();
    error Angela_ValueAboveMax();
    error Angela_ZeroAddress();
    error Angela_ZeroClawKind();
    error Angela_InvalidClawKind();
    error Angela_Reentrancy();
    error Angela_TransferFailed();
    error Angela_ClawNotFound();
    error Angela_ClawAlreadyExecuted();
    error Angela_ClawAlreadyReverted();
    error Angela_InvalidWindow();
    error Angela_InvalidCooldown();
    error Angela_ArrayLengthMismatch();
    error Angela_BatchTooLarge();
    error Angela_InvalidClawId();
    error Angela_IndexOutOfRange();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant AAIX_VERSION = 3;
    uint8 public constant CLAW_KIND_SWAP = 1;
    uint8 public constant CLAW_KIND_BATCH = 2;
    uint8 public constant CLAW_KIND_SIGNAL = 3;
    uint8 public constant CLAW_KIND_HARVEST = 4;
    uint8 public constant CLAW_KIND_REBALANCE = 5;
    uint8 public constant CLAW_KIND_EXIT = 6;
    uint8 public constant CLAW_KIND_ENTER = 7;
    uint8 public constant CLAW_KIND_CUSTOM_A = 8;
    uint8 public constant CLAW_KIND_CUSTOM_B = 9;
    uint8 public constant CLAW_KIND_CUSTOM_C = 10;
    uint8 public constant CLAW_KIND_EMERGENCY = 11;
    uint8 public constant CLAW_KIND_PASSTHROUGH = 12;
    uint256 public constant MAX_CLAW_KIND = 12;
    uint256 public constant MAX_CLAWS_PER_BATCH = 32;
    uint256 public constant MIN_COOLDOWN_BLOCKS = 2;
    uint256 public constant MAX_COOLDOWN_BLOCKS = 1000;
    uint256 public constant MIN_WINDOW_BLOCKS = 10;
    uint256 public constant MAX_WINDOW_BLOCKS = 500;
    uint256 public constant DEFAULT_RATE_WINDOW = 100;
    uint256 public constant DEFAULT_MAX_PER_WINDOW = 20;
    bytes32 public constant AAIX_DOMAIN = keccak256("AngelaAIX.Claw.v3");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable treasury;
    address public immutable guardianHub;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct ClawRecord {
        uint8 clawKind;
        bytes32 payloadHash;
        uint256 minValue;
        uint256 maxValue;
        address operator;
        uint256 submittedAtBlock;
        bool executed;
        bool reverted;
        uint256 executedAtBlock;
        uint256 actualValue;
    }

    address public operator;
    address public guardian;
    bool public paused;
    bool public emergencyHalt;
    uint256 private _lock;

    uint256 public cooldownBlocks;
    uint256 public rateLimitWindowBlocks;
    uint256 public rateLimitMaxClaws;
    uint256 public globalMinValue;
    uint256 public globalMaxValue;

    ClawRecord[] private _claws;
    uint256 private _lastClawBlock;
    mapping(uint256 => uint256) private _clawsInWindow;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        treasury = 0x4f7a2e9c1b8d3f6a0e5c2d9b7f4a1e8c3b6d0;
        guardianHub = 0x5a3e8f1c9d2b7e4a0f6c3d8b1e9a5c2f7d4b0;
        guardian = 0x6b2d9e4f1a8c3b7e0d5f2a9c6e1b4d8f3a7c0;
        operator = 0x4f7a2e9c1b8d3f6a0e5c2d9b7f4a1e8c3b6d0;
        cooldownBlocks = 5;
        rateLimitWindowBlocks = DEFAULT_RATE_WINDOW;
        rateLimitMaxClaws = DEFAULT_MAX_PER_WINDOW;
        globalMinValue = 0;
        globalMaxValue = 1000 ether;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyOperator() {
        if (msg.sender != operator) revert Angela_NotOperator();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert Angela_NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Angela_Paused();
        _;
    }

    modifier whenNotHalted() {
        if (emergencyHalt) revert Angela_EmergencyHalt();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 0) revert Angela_Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    // -------------------------------------------------------------------------
    // OPERATOR: SUBMIT CLAW
    // -------------------------------------------------------------------------

    function submitClaw(
        uint8 clawKind,
        bytes32 payloadHash,
        uint256 minValue,
        uint256 maxValue
    ) external onlyOperator whenNotPaused whenNotHalted nonReentrant returns (uint256 clawId) {
        if (clawKind == 0) revert Angela_ZeroClawKind();
        if (clawKind > MAX_CLAW_KIND) revert Angela_InvalidClawKind();
        if (block.number < _lastClawBlock + cooldownBlocks) revert Angela_CooldownActive();

        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        uint256 count = _clawsInWindow[windowStart] + 1;
        if (count > rateLimitMaxClaws) revert Angela_RateLimitExceeded();
        _clawsInWindow[windowStart] = count;

        if (minValue < globalMinValue) revert Angela_ValueBelowMin();
        if (maxValue > globalMaxValue) revert Angela_ValueAboveMax();
        if (minValue > maxValue) revert Angela_ValueBelowMin();

        _claws.push(ClawRecord({
            clawKind: clawKind,
            payloadHash: payloadHash,
            minValue: minValue,
            maxValue: maxValue,
            operator: msg.sender,
            submittedAtBlock: block.number,
            executed: false,
            reverted: false,
            executedAtBlock: 0,
            actualValue: 0
        }));
        clawId = _claws.length - 1;
        _lastClawBlock = block.number;

        emit ClawSubmitted(clawId, clawKind, payloadHash, minValue, maxValue, msg.sender, block.number);
    }

    function submitClawBatch(
        uint8[] calldata clawKinds,
        bytes32[] calldata payloadHashes,
        uint256[] calldata minValues,
        uint256[] calldata maxValues
    ) external onlyOperator whenNotPaused whenNotHalted nonReentrant returns (uint256[] memory clawIds) {
        uint256 n = clawKinds.length;
        if (n != payloadHashes.length || n != minValues.length || n != maxValues.length) revert Angela_ArrayLengthMismatch();
        if (n > MAX_CLAWS_PER_BATCH) revert Angela_BatchTooLarge();

        clawIds = new uint256[](n);
        uint256 lastBlock = _lastClawBlock;
        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        uint256 windowCount = _clawsInWindow[windowStart];

        for (uint256 i = 0; i < n; i++) {
            if (clawKinds[i] == 0) revert Angela_ZeroClawKind();
            if (clawKinds[i] > MAX_CLAW_KIND) revert Angela_InvalidClawKind();
            if (block.number < lastBlock + cooldownBlocks && i > 0) revert Angela_CooldownActive();
            windowCount++;
            if (windowCount > rateLimitMaxClaws) revert Angela_RateLimitExceeded();

            if (minValues[i] < globalMinValue) revert Angela_ValueBelowMin();
            if (maxValues[i] > globalMaxValue) revert Angela_ValueAboveMax();
            if (minValues[i] > maxValues[i]) revert Angela_ValueBelowMin();

            _claws.push(ClawRecord({
                clawKind: clawKinds[i],
                payloadHash: payloadHashes[i],
                minValue: minValues[i],
                maxValue: maxValues[i],
                operator: msg.sender,
                submittedAtBlock: block.number,
                executed: false,
                reverted: false,
                executedAtBlock: 0,
                actualValue: 0
            }));
            clawIds[i] = _claws.length - 1;
            lastBlock = block.number;
        }
        _lastClawBlock = lastBlock;
        _clawsInWindow[windowStart] = windowCount;

        for (uint256 i = 0; i < n; i++) {
            emit ClawSubmitted(clawIds[i], clawKinds[i], payloadHashes[i], minValues[i], maxValues[i], msg.sender, block.number);
        }
    }

    function markClawExecuted(uint256 clawId, uint256 actualValue) external onlyOperator whenNotPaused whenNotHalted {
        if (clawId >= _claws.length) revert Angela_ClawNotFound();
        ClawRecord storage c = _claws[clawId];
        if (c.executed) revert Angela_ClawAlreadyExecuted();
        if (c.reverted) revert Angela_ClawAlreadyReverted();
        if (actualValue < c.minValue) revert Angela_ValueBelowMin();
        if (actualValue > c.maxValue) revert Angela_ValueAboveMax();

        c.executed = true;
        c.executedAtBlock = block.number;
        c.actualValue = actualValue;
        emit ClawExecuted(clawId, actualValue, block.number);
    }

    function markClawReverted(uint256 clawId, bytes calldata reason) external onlyOperator whenNotPaused {
        if (clawId >= _claws.length) revert Angela_ClawNotFound();
        ClawRecord storage c = _claws[clawId];
        if (c.executed) revert Angela_ClawAlreadyExecuted();
        if (c.reverted) revert Angela_ClawAlreadyReverted();

        c.reverted = true;
        c.executedAtBlock = block.number;
        emit ClawReverted(clawId, reason, block.number);
    }

    // -------------------------------------------------------------------------
    // GUARDIAN
    // -------------------------------------------------------------------------

    function setOperator(address newOperator) external onlyGuardian {
        if (newOperator == address(0)) revert Angela_ZeroAddress();
        address prev = operator;
        operator = newOperator;
        emit OperatorSet(prev, newOperator);
    }

    function setGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert Angela_ZeroAddress();
        address prev = guardian;
        guardian = newGuardian;
        emit GuardianSet(prev, newGuardian);
    }

    function setPaused(bool paused_) external onlyGuardian {
        paused = paused_;
        emit PauseToggled(paused, msg.sender, block.number);
    }

    function setEmergencyHalt() external onlyGuardian {
        emergencyHalt = true;
        emit EmergencyHalt(block.number, msg.sender);
    }

    function clearEmergencyHalt() external onlyGuardian {
        emergencyHalt = false;
    }

    function setCooldownBlocks(uint256 blocks) external onlyGuardian {
        if (blocks < MIN_COOLDOWN_BLOCKS || blocks > MAX_COOLDOWN_BLOCKS) revert Angela_InvalidCooldown();
        cooldownBlocks = blocks;
        emit CooldownConfigured(blocks);
    }

    function setRateLimit(uint256 maxClawsPerWindow, uint256 windowBlocks) external onlyGuardian {
        if (windowBlocks < MIN_WINDOW_BLOCKS || windowBlocks > MAX_WINDOW_BLOCKS) revert Angela_InvalidWindow();
        rateLimitMaxClaws = maxClawsPerWindow;
        rateLimitWindowBlocks = windowBlocks;
        emit RateLimitConfigured(maxClawsPerWindow, windowBlocks);
    }

    function setValueBounds(uint256 globalMin, uint256 globalMax) external onlyGuardian {
        globalMinValue = globalMin;
        globalMaxValue = globalMax;
        emit ValueBoundsConfigured(globalMin, globalMax);
    }

    function withdrawToTreasury(uint256 amount) external onlyGuardian nonReentrant {
        if (amount == 0) return;
        (bool ok,) = payable(treasury).call{value: amount}("");
        if (!ok) revert Angela_TransferFailed();
        emit TreasuryWithdrawn(treasury, amount, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEWS
    // -------------------------------------------------------------------------

    function getClaw(uint256 clawId) external view returns (
        uint8 clawKind,
        bytes32 payloadHash,
        uint256 minValue,
        uint256 maxValue,
        address operatorAddr,
        uint256 submittedAtBlock,
        bool executed,
        bool reverted,
        uint256 executedAtBlock,
        uint256 actualValue
    ) {
        if (clawId >= _claws.length) revert Angela_ClawNotFound();
        ClawRecord storage c = _claws[clawId];
        return (
            c.clawKind,
            c.payloadHash,
            c.minValue,
            c.maxValue,
            c.operator,
            c.submittedAtBlock,
            c.executed,
            c.reverted,
            c.executedAtBlock,
            c.actualValue
        );
    }

    function clawCount() external view returns (uint256) {
        return _claws.length;
    }

    function lastClawBlock() external view returns (uint256) {
        return _lastClawBlock;
    }

    function canSubmitNow() external view returns (bool) {
        if (paused || emergencyHalt) return false;
        if (block.number < _lastClawBlock + cooldownBlocks) return false;
        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        return _clawsInWindow[windowStart] < rateLimitMaxClaws;
    }

    function blocksUntilNextClawAllowed() external view returns (uint256) {
        if (_lastClawBlock + cooldownBlocks <= block.number) return 0;
        return _lastClawBlock + cooldownBlocks - block.number;
    }

    function clawsInCurrentWindow() external view returns (uint256) {
        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        return _clawsInWindow[windowStart];
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getClawKindName(uint8 kind) external pure returns (string memory) {
        if (kind == 1) return "swap";
        if (kind == 2) return "batch";
        if (kind == 3) return "signal";
        if (kind == 4) return "harvest";
        if (kind == 5) return "rebalance";
        if (kind == 6) return "exit";
        if (kind == 7) return "enter";
        if (kind == 8) return "custom_a";
        if (kind == 9) return "custom_b";
        if (kind == 10) return "custom_c";
        if (kind == 11) return "emergency";
        if (kind == 12) return "passthrough";
        return "unknown";
    }

    function getClawsBatch(uint256[] calldata clawIds) external view returns (
        uint8[] memory kinds,
        bytes32[] memory payloadHashes,
        uint256[] memory minVals,
        uint256[] memory maxVals,
        address[] memory operators,
        uint256[] memory submittedBlocks,
        bool[] memory executedFlags,
        bool[] memory revertedFlags,
        uint256[] memory executedBlocks,
        uint256[] memory actualVals
    ) {
        uint256 n = clawIds.length;
        kinds = new uint8[](n);
        payloadHashes = new bytes32[](n);
        minVals = new uint256[](n);
        maxVals = new uint256[](n);
        operators = new address[](n);
        submittedBlocks = new uint256[](n);
        executedFlags = new bool[](n);
        revertedFlags = new bool[](n);
        executedBlocks = new uint256[](n);
        actualVals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            ClawRecord storage c = _claws[clawIds[i]];
            kinds[i] = c.clawKind;
            payloadHashes[i] = c.payloadHash;
            minVals[i] = c.minValue;
            maxVals[i] = c.maxValue;
            operators[i] = c.operator;
            submittedBlocks[i] = c.submittedAtBlock;
            executedFlags[i] = c.executed;
            revertedFlags[i] = c.reverted;
            executedBlocks[i] = c.executedAtBlock;
            actualVals[i] = c.actualValue;
        }
    }

    function getClawIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 total = _claws.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) ids[i] = offset + i;
    }

    function isClawExecuted(uint256 clawId) external view returns (bool) {
        if (clawId >= _claws.length) return false;
        return _claws[clawId].executed;
    }

    function isClawReverted(uint256 clawId) external view returns (bool) {
        if (clawId >= _claws.length) return false;
        return _claws[clawId].reverted;
    }

    function getConfig() external view returns (
        address operatorAddr,
        address guardianAddr,
        bool pausedFlag,
        bool haltedFlag,
        uint256 cooldownBlks,
        uint256 rateWindowBlks,
        uint256 rateMaxClaws,
        uint256 globalMin,
        uint256 globalMax
    ) {
        return (
            operator,
            guardian,
            paused,
            emergencyHalt,
            cooldownBlocks,
            rateLimitWindowBlocks,
            rateLimitMaxClaws,
            globalMinValue,
            globalMaxValue
        );
    }

    function getImmutables() external view returns (address treasuryAddr, address guardianHubAddr) {
        return (treasury, guardianHub);
    }

    function getVersion() external pure returns (uint256) { return AAIX_VERSION; }
    function getMaxClawKind() external pure returns (uint256) { return MAX_CLAW_KIND; }
    function getMaxClawsPerBatch() external pure returns (uint256) { return MAX_CLAWS_PER_BATCH; }
    function getDomain() external pure returns (bytes32) { return AAIX_DOMAIN; }

    function clawKind(uint256 clawId) external view returns (uint8) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].clawKind;
    }
    function clawPayloadHash(uint256 clawId) external view returns (bytes32) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].payloadHash;
    }
    function clawMinValue(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].minValue;
    }
    function clawMaxValue(uint256 clawId) external view returns (uint256) {
