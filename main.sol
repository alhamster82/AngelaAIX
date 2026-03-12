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
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].maxValue;
    }
    function clawOperator(uint256 clawId) external view returns (address) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].operator;
    }
    function clawSubmittedAtBlock(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].submittedAtBlock;
    }
    function clawExecutedAtBlock(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].executedAtBlock;
    }
    function clawActualValue(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].actualValue;
    }

    function getCooldownBlocks() external view returns (uint256) { return cooldownBlocks; }
    function getRateLimitWindow() external view returns (uint256) { return rateLimitWindowBlocks; }
    function getRateLimitMax() external view returns (uint256) { return rateLimitMaxClaws; }
    function getGlobalMinValue() external view returns (uint256) { return globalMinValue; }
    function getGlobalMaxValue() external view returns (uint256) { return globalMaxValue; }
    function getOperator() external view returns (address) { return operator; }
    function getGuardian() external view returns (address) { return guardian; }
    function getTreasury() external view returns (address) { return treasury; }
    function getGuardianHub() external view returns (address) { return guardianHub; }
    function getPaused() external view returns (bool) { return paused; }
    function getEmergencyHalt() external view returns (bool) { return emergencyHalt; }

    function countExecutedClaws() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _claws.length; i++) if (_claws[i].executed) c++;
        return c;
    }
    function countRevertedClaws() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _claws.length; i++) if (_claws[i].reverted) c++;
        return c;
    }
    function countPendingClaws() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _claws.length; i++) if (!_claws[i].executed && !_claws[i].reverted) c++;
        return c;
    }
    function countClawsByKind(uint8 kind) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _claws.length; i++) if (_claws[i].clawKind == kind) c++;
        return c;
    }
    function countClawsByOperator(address op) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _claws.length; i++) if (_claws[i].operator == op) c++;
        return c;
    }

    function getClawIdsByKind(uint8 kind, uint256 maxReturn) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_claws.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _claws.length && count < maxReturn; i++) {
            if (_claws[i].clawKind == kind) { temp[count] = i; count++; }
        }
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) out[i] = temp[i];
        return out;
    }
    function getClawIdsByOperator(address op, uint256 maxReturn) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_claws.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _claws.length && count < maxReturn; i++) {
            if (_claws[i].operator == op) { temp[count] = i; count++; }
        }
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) out[i] = temp[i];
        return out;
    }
    function getPendingClawIds(uint256 maxReturn) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_claws.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _claws.length && count < maxReturn; i++) {
            if (!_claws[i].executed && !_claws[i].reverted) { temp[count] = i; count++; }
        }
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) out[i] = temp[i];
        return out;
    }

    function sumActualValues() external view returns (uint256 sum) {
        for (uint256 i = 0; i < _claws.length; i++)
            if (_claws[i].executed) sum += _claws[i].actualValue;
    }
    function sumMaxValuesPending() external view returns (uint256 sum) {
        for (uint256 i = 0; i < _claws.length; i++)
            if (!_claws[i].executed && !_claws[i].reverted) sum += _claws[i].maxValue;
    }

    function minU256(uint256 a, uint256 b) external pure returns (uint256) { return a < b ? a : b; }
    function maxU256(uint256 a, uint256 b) external pure returns (uint256) { return a > b ? a : b; }
    function clampValue(uint256 v, uint256 lo, uint256 hi) external pure returns (uint256) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    function isOperator(address account) external view returns (bool) { return account == operator; }
    function isGuardian(address account) external view returns (bool) { return account == guardian; }
    function isTreasury(address account) external view returns (bool) { return account == treasury; }

    function getCurrentWindowStart() external view returns (uint256) {
        return block.number - (block.number % rateLimitWindowBlocks);
    }
    function getClawsInWindowAt(uint256 windowStart) external view returns (uint256) {
        return _clawsInWindow[windowStart];
    }

    function getClawSummary(uint256 clawId) external view returns (
        uint8 kind,
        uint256 minVal,
        uint256 maxVal,
        bool executed,
        bool reverted,
        uint256 actualVal
    ) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        ClawRecord storage c = _claws[clawId];
        return (c.clawKind, c.minValue, c.maxValue, c.executed, c.reverted, c.actualValue);
    }

    function getClawSummariesBatch(uint256[] calldata clawIds) external view returns (
        uint8[] memory kinds,
        uint256[] memory minVals,
        uint256[] memory maxVals,
        bool[] memory executedFlags,
        bool[] memory revertedFlags,
        uint256[] memory actualVals
    ) {
        uint256 n = clawIds.length;
        kinds = new uint8[](n);
        minVals = new uint256[](n);
        maxVals = new uint256[](n);
        executedFlags = new bool[](n);
        revertedFlags = new bool[](n);
        actualVals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            ClawRecord storage c = _claws[clawIds[i]];
            kinds[i] = c.clawKind;
            minVals[i] = c.minValue;
            maxVals[i] = c.maxValue;
            executedFlags[i] = c.executed;
            revertedFlags[i] = c.reverted;
            actualVals[i] = c.actualValue;
        }
    }

    function getClawsRange(uint256 fromId, uint256 toId) external view returns (
        uint256[] memory ids,
        uint8[] memory kinds,
        bytes32[] memory payloadHashes,
        uint256[] memory minVals,
        uint256[] memory maxVals,
        bool[] memory executedFlags,
        bool[] memory revertedFlags
    ) {
        if (toId > _claws.length) toId = _claws.length;
        if (fromId >= toId) {
            return (
                new uint256[](0),
                new uint8[](0),
                new bytes32[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0),
                new bool[](0)
            );
        }
        uint256 n = toId - fromId;
        ids = new uint256[](n);
        kinds = new uint8[](n);
        payloadHashes = new bytes32[](n);
        minVals = new uint256[](n);
        maxVals = new uint256[](n);
        executedFlags = new bool[](n);
        revertedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = fromId + i;
            ClawRecord storage c = _claws[id];
            ids[i] = id;
            kinds[i] = c.clawKind;
            payloadHashes[i] = c.payloadHash;
            minVals[i] = c.minValue;
            maxVals[i] = c.maxValue;
            executedFlags[i] = c.executed;
            revertedFlags[i] = c.reverted;
        }
    }

    function getStateSnapshot() external view returns (
        uint256 totalClaws,
        uint256 executedCount,
        uint256 revertedCount,
        uint256 pendingCount,
        uint256 lastClawBlockNum,
        uint256 balanceWei,
        bool pausedState,
        bool haltedState
    ) {
        uint256 ex = 0;
        uint256 rv = 0;
        for (uint256 i = 0; i < _claws.length; i++) {
            if (_claws[i].executed) ex++;
            else if (_claws[i].reverted) rv++;
        }
        return (
            _claws.length,
            ex,
            rv,
            _claws.length - ex - rv,
            _lastClawBlock,
            address(this).balance,
            paused,
            emergencyHalt
        );
    }

    function getConstants() external pure returns (
        uint256 version,
        uint256 maxClawKind,
        uint256 maxClawsPerBatch,
        uint256 minCooldownBlocks,
        uint256 maxCooldownBlocks,
        uint256 minWindowBlocks,
        uint256 maxWindowBlocks
    ) {
        return (
            AAIX_VERSION,
            MAX_CLAW_KIND,
            MAX_CLAWS_PER_BATCH,
            MIN_COOLDOWN_BLOCKS,
            MAX_COOLDOWN_BLOCKS,
            MIN_WINDOW_BLOCKS,
            MAX_WINDOW_BLOCKS
        );
    }

    function clawIdAt(uint256 index) external view returns (uint256) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return index;
    }

    function totalClawRecords() external view returns (uint256) {
        return _claws.length;
    }

    function payloadHashAt(uint256 clawId) external view returns (bytes32) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].payloadHash;
    }

    function submittedBlockAt(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].submittedAtBlock;
    }

    function executedBlockAt(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].executedAtBlock;
    }

    function actualValueAt(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].actualValue;
    }

    function executedAt(uint256 clawId) external view returns (bool) {
        if (clawId >= _claws.length) return false;
        return _claws[clawId].executed;
    }

    function revertedAt(uint256 clawId) external view returns (bool) {
        if (clawId >= _claws.length) return false;
        return _claws[clawId].reverted;
    }

    function operatorAt(uint256 clawId) external view returns (address) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].operator;
    }

    function kindAt(uint256 clawId) external view returns (uint8) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].clawKind;
    }

    function minValueAt(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].minValue;
    }

    function maxValueAt(uint256 clawId) external view returns (uint256) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId].maxValue;
    }

    function cooldownBlocksRemaining() external view returns (uint256) {
        if (_lastClawBlock + cooldownBlocks <= block.number) return 0;
        return _lastClawBlock + cooldownBlocks - block.number;
    }

    function clawsRemainingInWindow() external view returns (uint256) {
        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        uint256 used = _clawsInWindow[windowStart];
        if (used >= rateLimitMaxClaws) return 0;
        return rateLimitMaxClaws - used;
    }

    function isSubmitAllowed() external view returns (bool) {
        if (paused || emergencyHalt) return false;
        if (block.number < _lastClawBlock + cooldownBlocks) return false;
        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        return _clawsInWindow[windowStart] < rateLimitMaxClaws;
    }

    function proportional(uint256 part, uint256 total, uint256 whole) external pure returns (uint256) {
        if (total == 0) return 0;
        return (part * whole) / total;
    }

    function saturatingSub(uint256 a, uint256 b) external pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function domainSeed() external pure returns (bytes32) {
        return AAIX_DOMAIN;
    }

    function version() external pure returns (uint256) {
        return AAIX_VERSION;
    }

    function maxClawKind() external pure returns (uint8) {
        return uint8(MAX_CLAW_KIND);
    }

    function maxBatchSize() external pure returns (uint256) {
        return MAX_CLAWS_PER_BATCH;
    }

    function getKindsBatch(uint256[] calldata clawIds) external view returns (uint8[] memory) {
        uint256 n = clawIds.length;
        uint8[] memory out = new uint8[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            out[i] = _claws[clawIds[i]].clawKind;
        }
        return out;
    }
    function getPayloadHashesBatch(uint256[] calldata clawIds) external view returns (bytes32[] memory) {
        uint256 n = clawIds.length;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            out[i] = _claws[clawIds[i]].payloadHash;
        }
        return out;
    }
    function getMinValuesBatch(uint256[] calldata clawIds) external view returns (uint256[] memory) {
        uint256 n = clawIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            out[i] = _claws[clawIds[i]].minValue;
        }
        return out;
    }
    function getMaxValuesBatch(uint256[] calldata clawIds) external view returns (uint256[] memory) {
        uint256 n = clawIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            out[i] = _claws[clawIds[i]].maxValue;
        }
        return out;
    }
    function getOperatorsBatch(uint256[] calldata clawIds) external view returns (address[] memory) {
        uint256 n = clawIds.length;
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            out[i] = _claws[clawIds[i]].operator;
        }
        return out;
    }
    function getExecutedFlagsBatch(uint256[] calldata clawIds) external view returns (bool[] memory) {
        uint256 n = clawIds.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] < _claws.length) out[i] = _claws[clawIds[i]].executed;
        }
        return out;
    }
    function getRevertedFlagsBatch(uint256[] calldata clawIds) external view returns (bool[] memory) {
        uint256 n = clawIds.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] < _claws.length) out[i] = _claws[clawIds[i]].reverted;
        }
        return out;
    }
    function getActualValuesBatch(uint256[] calldata clawIds) external view returns (uint256[] memory) {
        uint256 n = clawIds.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] < _claws.length) out[i] = _claws[clawIds[i]].actualValue;
        }
        return out;
    }

    function firstClawId() external view returns (uint256) {
        if (_claws.length == 0) revert Angela_ClawNotFound();
        return 0;
    }
    function lastClawId() external view returns (uint256) {
        if (_claws.length == 0) revert Angela_ClawNotFound();
        return _claws.length - 1;
    }

    function getTreasuryAddress() external view returns (address) { return treasury; }
    function getGuardianHubAddress() external view returns (address) { return guardianHub; }
    function getOperatorAddress() external view returns (address) { return operator; }
    function getGuardianAddress() external view returns (address) { return guardian; }
    function getPausedStatus() external view returns (bool) { return paused; }
    function getHaltStatus() external view returns (bool) { return emergencyHalt; }
    function getCooldown() external view returns (uint256) { return cooldownBlocks; }
    function getRateWindow() external view returns (uint256) { return rateLimitWindowBlocks; }
    function getRateMax() external view returns (uint256) { return rateLimitMaxClaws; }
    function getGlobalMin() external view returns (uint256) { return globalMinValue; }
    function getGlobalMax() external view returns (uint256) { return globalMaxValue; }

    function balance() external view returns (uint256) { return address(this).balance; }
    function totalClaws() external view returns (uint256) { return _claws.length; }
    function lastClawBlockNumber() external view returns (uint256) { return _lastClawBlock; }

    function kindName(uint8 k) external pure returns (string memory) { return getClawKindName(k); }
    function domainHash() external pure returns (bytes32) { return AAIX_DOMAIN; }
    function revision() external pure returns (uint256) { return AAIX_VERSION; }

    function checkCooldown() external view returns (bool ok, uint256 blocksLeft) {
        if (_lastClawBlock + cooldownBlocks <= block.number) return (true, 0);
        return (false, _lastClawBlock + cooldownBlocks - block.number);
    }
    function checkRateLimit() external view returns (bool ok, uint256 used, uint256 allowed) {
        uint256 windowStart = block.number - (block.number % rateLimitWindowBlocks);
        used = _clawsInWindow[windowStart];
        allowed = rateLimitMaxClaws;
        return (used < allowed, used, allowed);
    }

    function isWithinBounds(uint256 value) external view returns (bool) {
        return value >= globalMinValue && value <= globalMaxValue;
    }
    function isClawPending(uint256 clawId) external view returns (bool) {
        if (clawId >= _claws.length) return false;
        return !_claws[clawId].executed && !_claws[clawId].reverted;
    }

    function computeWindowStart(uint256 blockNum) external view returns (uint256) {
        return blockNum - (blockNum % rateLimitWindowBlocks);
    }
    function computeCooldownEnd(uint256 lastBlock) external view returns (uint256) {
        return lastBlock + cooldownBlocks;
    }

    function getClawFull(uint256 clawId) external view returns (
        uint8 kind,
        bytes32 payloadHashVal,
        uint256 minVal,
        uint256 maxVal,
        address operatorAddr,
        uint256 submittedBlock,
        bool executedFlag,
        bool revertedFlag,
        uint256 executedBlock,
        uint256 actualVal
    ) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        ClawRecord storage c = _claws[clawId];
        kind = c.clawKind;
        payloadHashVal = c.payloadHash;
        minVal = c.minValue;
        maxVal = c.maxValue;
        operatorAddr = c.operator;
        submittedBlock = c.submittedAtBlock;
        executedFlag = c.executed;
        revertedFlag = c.reverted;
        executedBlock = c.executedAtBlock;
        actualVal = c.actualValue;
    }

    function getMultipleClawFull(uint256[] calldata clawIds) external view returns (
        uint8[] memory kinds,
        bytes32[] memory payloadHashesOut,
        uint256[] memory minValsOut,
        uint256[] memory maxValsOut,
        address[] memory operatorsOut,
        uint256[] memory submittedBlocksOut,
        bool[] memory executedOut,
        bool[] memory revertedOut,
        uint256[] memory executedBlocksOut,
        uint256[] memory actualValsOut
    ) {
        uint256 n = clawIds.length;
        kinds = new uint8[](n);
        payloadHashesOut = new bytes32[](n);
        minValsOut = new uint256[](n);
        maxValsOut = new uint256[](n);
        operatorsOut = new address[](n);
        submittedBlocksOut = new uint256[](n);
        executedOut = new bool[](n);
        revertedOut = new bool[](n);
        executedBlocksOut = new uint256[](n);
        actualValsOut = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            ClawRecord storage c = _claws[clawIds[i]];
            kinds[i] = c.clawKind;
            payloadHashesOut[i] = c.payloadHash;
            minValsOut[i] = c.minValue;
            maxValsOut[i] = c.maxValue;
            operatorsOut[i] = c.operator;
            submittedBlocksOut[i] = c.submittedAtBlock;
            executedOut[i] = c.executed;
            revertedOut[i] = c.reverted;
            executedBlocksOut[i] = c.executedAtBlock;
            actualValsOut[i] = c.actualValue;
        }
    }

    function listClawIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return getClawIdsPaginated(offset, limit);
    }
    function getClawCount() external view returns (uint256) { return _claws.length; }
    function getLastClawBlock() external view returns (uint256) { return _lastClawBlock; }
    function getBalance() external view returns (uint256) { return address(this).balance; }
    function getContractBalance() external view returns (uint256) { return address(this).balance; }
    function treasuryAddress() external view returns (address) { return treasury; }
    function guardianHubAddress() external view returns (address) { return guardianHub; }
    function operatorAddress() external view returns (address) { return operator; }
    function guardianAddress() external view returns (address) { return guardian; }
    function isPaused() external view returns (bool) { return paused; }
    function isHalted() external view returns (bool) { return emergencyHalt; }
    function cooldown() external view returns (uint256) { return cooldownBlocks; }
    function rateWindow() external view returns (uint256) { return rateLimitWindowBlocks; }
    function rateMax() external view returns (uint256) { return rateLimitMaxClaws; }
    function globalMin() external view returns (uint256) { return globalMinValue; }
    function globalMax() external view returns (uint256) { return globalMaxValue; }
    function numClaws() external view returns (uint256) { return _claws.length; }
    function protocolVersion() external pure returns (uint256) { return AAIX_VERSION; }
    function maxKind() external pure returns (uint256) { return MAX_CLAW_KIND; }
    function batchLimit() external pure returns (uint256) { return MAX_CLAWS_PER_BATCH; }
    function minCooldown() external pure returns (uint256) { return MIN_COOLDOWN_BLOCKS; }
    function maxCooldown() external pure returns (uint256) { return MAX_COOLDOWN_BLOCKS; }
    function minWindow() external pure returns (uint256) { return MIN_WINDOW_BLOCKS; }
    function maxWindow() external pure returns (uint256) { return MAX_WINDOW_BLOCKS; }
    function domain() external pure returns (bytes32) { return AAIX_DOMAIN; }
    function clawKindName(uint8 k) external pure returns (string memory) { return getClawKindName(k); }
    function executedCount() external view returns (uint256) { return countExecutedClaws(); }
    function revertedCount() external view returns (uint256) { return countRevertedClaws(); }
    function pendingCount() external view returns (uint256) { return countPendingClaws(); }
    function canSubmit() external view returns (bool) { return canSubmitNow(); }
    function blocksUntilNextClaw() external view returns (uint256) { return blocksUntilNextClawAllowed(); }
    function currentWindowClawCount() external view returns (uint256) { return clawsInCurrentWindow(); }
    function submitAllowed() external view returns (bool) { return isSubmitAllowed(); }
    function cooldownRemaining() external view returns (uint256) { return cooldownBlocksRemaining(); }
    function clawsLeftInWindow() external view returns (uint256) { return clawsRemainingInWindow(); }
    function withinBounds(uint256 v) external view returns (bool) { return isWithinBounds(v); }
    function pending(uint256 clawId) external view returns (bool) { return isClawPending(clawId); }
    function windowStart(uint256 blockNum) external view returns (uint256) { return computeWindowStart(blockNum); }
    function cooldownEnd(uint256 lastBlock) external view returns (uint256) { return computeCooldownEnd(lastBlock); }

    function getRoleAddresses() external view returns (
        address op,
        address guard,
        address treas,
        address hub
    ) {
        return (operator, guardian, treasury, guardianHub);
    }
    function getLimitConfig() external view returns (
        uint256 cooldownBlks,
        uint256 windowBlks,
        uint256 maxPerWindow,
        uint256 gMin,
        uint256 gMax
    ) {
        return (cooldownBlocks, rateLimitWindowBlocks, rateLimitMaxClaws, globalMinValue, globalMaxValue);
    }
    function getStatus() external view returns (
        bool pausedStatus,
        bool haltStatus,
        uint256 totalClawCount,
        uint256 balanceWei
    ) {
        return (paused, emergencyHalt, _claws.length, address(this).balance);
    }

    function exists(uint256 clawId) external view returns (bool) {
        return clawId < _claws.length;
    }
    function validClawId(uint256 clawId) external view returns (bool) {
        return clawId < _claws.length;
    }
    function hasClaws() external view returns (bool) {
        return _claws.length > 0;
    }
    function empty() external view returns (bool) {
        return _claws.length == 0;
    }

    function addU256(uint256 a, uint256 b) external pure returns (uint256) { return a + b; }
    function subU256(uint256 a, uint256 b) external pure returns (uint256) { return a - b; }
    function mulU256(uint256 a, uint256 b) external pure returns (uint256) { return a * b; }
    function divU256(uint256 a, uint256 b) external pure returns (uint256) { return a / b; }
    function modU256(uint256 a, uint256 b) external pure returns (uint256) { return a % b; }
    function eqU256(uint256 a, uint256 b) external pure returns (bool) { return a == b; }
    function ltU256(uint256 a, uint256 b) external pure returns (bool) { return a < b; }
    function leU256(uint256 a, uint256 b) external pure returns (bool) { return a <= b; }
    function gtU256(uint256 a, uint256 b) external pure returns (bool) { return a > b; }
    function geU256(uint256 a, uint256 b) external pure returns (bool) { return a >= b; }

    function getClawIdsSlice(uint256 start, uint256 length) external view returns (uint256[] memory) {
        if (start >= _claws.length) return new uint256[](0);
        uint256 end = start + length;
        if (end > _claws.length) end = _claws.length;
        uint256 n = end - start;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = start + i;
        return out;
    }
    function getClawIdsFromTo(uint256 fromId, uint256 toId) external view returns (uint256[] memory) {
        if (toId > _claws.length) toId = _claws.length;
        if (fromId >= toId) return new uint256[](0);
        uint256 n = toId - fromId;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = fromId + i;
        return out;
    }
    function getExecutedClawIds(uint256 maxReturn) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_claws.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _claws.length && count < maxReturn; i++) {
            if (_claws[i].executed) { temp[count] = i; count++; }
        }
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) out[i] = temp[i];
        return out;
    }
    function getRevertedClawIds(uint256 maxReturn) external view returns (uint256[] memory) {
        uint256[] memory temp = new uint256[](_claws.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _claws.length && count < maxReturn; i++) {
            if (_claws[i].reverted) { temp[count] = i; count++; }
        }
        uint256[] memory out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) out[i] = temp[i];
        return out;
    }
    function sumMinValuesExecuted() external view returns (uint256 sum) {
        for (uint256 i = 0; i < _claws.length; i++)
            if (_claws[i].executed) sum += _claws[i].minValue;
    }
    function sumMaxValuesExecuted() external view returns (uint256 sum) {
        for (uint256 i = 0; i < _claws.length; i++)
            if (_claws[i].executed) sum += _claws[i].maxValue;
    }
    function sumActualValuesExecuted() external view returns (uint256) {
        return sumActualValues();
    }
    function averageActualValue() external view returns (uint256) {
        uint256 ex = 0;
        uint256 sum = 0;
        for (uint256 i = 0; i < _claws.length; i++) {
            if (_claws[i].executed) { ex++; sum += _claws[i].actualValue; }
        }
        return ex == 0 ? 0 : sum / ex;
    }
    function countByKindRange(uint8 kindLow, uint8 kindHigh) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _claws.length; i++) {
            if (_claws[i].clawKind >= kindLow && _claws[i].clawKind <= kindHigh) c++;
        }
        return c;
    }
    function getKindNames() external pure returns (string[] memory) {
        string[] memory names = new string[](12);
        names[0] = "swap";
        names[1] = "batch";
        names[2] = "signal";
        names[3] = "harvest";
        names[4] = "rebalance";
        names[5] = "exit";
        names[6] = "enter";
        names[7] = "custom_a";
        names[8] = "custom_b";
        names[9] = "custom_c";
        names[10] = "emergency";
        names[11] = "passthrough";
        return names;
    }
    function kindFromName(string calldata name) external pure returns (int256) {
        if (keccak256(bytes(name)) == keccak256("swap")) return 1;
        if (keccak256(bytes(name)) == keccak256("batch")) return 2;
        if (keccak256(bytes(name)) == keccak256("signal")) return 3;
        if (keccak256(bytes(name)) == keccak256("harvest")) return 4;
        if (keccak256(bytes(name)) == keccak256("rebalance")) return 5;
        if (keccak256(bytes(name)) == keccak256("exit")) return 6;
        if (keccak256(bytes(name)) == keccak256("enter")) return 7;
        if (keccak256(bytes(name)) == keccak256("custom_a")) return 8;
        if (keccak256(bytes(name)) == keccak256("custom_b")) return 9;
        if (keccak256(bytes(name)) == keccak256("custom_c")) return 10;
        if (keccak256(bytes(name)) == keccak256("emergency")) return 11;
        if (keccak256(bytes(name)) == keccak256("passthrough")) return 12;
        return -1;
    }
    function supportedKinds() external pure returns (uint8[] memory) {
        uint8[] memory k = new uint8[](12);
        k[0] = 1; k[1] = 2; k[2] = 3; k[3] = 4; k[4] = 5; k[5] = 6;
        k[6] = 7; k[7] = 8; k[8] = 9; k[9] = 10; k[10] = 11; k[11] = 12;
        return k;
    }
    function isSupportedKind(uint8 k) external pure returns (bool) {
        return k >= 1 && k <= MAX_CLAW_KIND;
    }
    function clampKind(uint8 k) external pure returns (uint8) {
        if (k == 0) return 1;
        if (k > MAX_CLAW_KIND) return uint8(MAX_CLAW_KIND);
        return k;
    }
    function checkValueInRange(uint256 value, uint256 minVal, uint256 maxVal) external pure returns (bool) {
        return value >= minVal && value <= maxVal;
    }
    function checkGlobalRange(uint256 value) external view returns (bool) {
        return value >= globalMinValue && value <= globalMaxValue;
    }
    function getClawRecord(uint256 clawId) external view returns (ClawRecord memory) {
        if (clawId >= _claws.length) revert Angela_InvalidClawId();
        return _claws[clawId];
    }
    function getClawRecordsBatch(uint256[] calldata clawIds) external view returns (ClawRecord[] memory) {
        uint256 n = clawIds.length;
        ClawRecord[] memory out = new ClawRecord[](n);
        for (uint256 i = 0; i < n; i++) {
            if (clawIds[i] >= _claws.length) revert Angela_InvalidClawId();
            out[i] = _claws[clawIds[i]];
        }
        return out;
    }
    function recordLength() external view returns (uint256) { return _claws.length; }
    function at(uint256 index) external view returns (ClawRecord memory) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index];
    }
    function atKind(uint256 index) external view returns (uint8) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].clawKind;
    }
    function atPayload(uint256 index) external view returns (bytes32) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].payloadHash;
    }
    function atMin(uint256 index) external view returns (uint256) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].minValue;
    }
    function atMax(uint256 index) external view returns (uint256) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].maxValue;
    }
    function atOperator(uint256 index) external view returns (address) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].operator;
    }
    function atSubmittedBlock(uint256 index) external view returns (uint256) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].submittedAtBlock;
    }
    function atExecuted(uint256 index) external view returns (bool) {
        if (index >= _claws.length) return false;
        return _claws[index].executed;
    }
    function atReverted(uint256 index) external view returns (bool) {
        if (index >= _claws.length) return false;
        return _claws[index].reverted;
    }
    function atExecutedBlock(uint256 index) external view returns (uint256) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].executedAtBlock;
    }
    function atActualValue(uint256 index) external view returns (uint256) {
        if (index >= _claws.length) revert Angela_IndexOutOfRange();
        return _claws[index].actualValue;
    }

    function getPaginatedClawIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return getClawIdsPaginated(offset, limit);
    }
    function fetchClaw(uint256 id) external view returns (ClawRecord memory) {
        if (id >= _claws.length) revert Angela_InvalidClawId();
        return _claws[id];
    }
    function fetchClaws(uint256[] calldata ids) external view returns (ClawRecord[] memory) {
        return getClawRecordsBatch(ids);
    }
    function totalRecords() external view returns (uint256) { return _claws.length; }
    function length() external view returns (uint256) { return _claws.length; }
    function size() external view returns (uint256) { return _claws.length; }
    function getStats() external view returns (
        uint256 total,
        uint256 executed,
        uint256 reverted,
        uint256 pending,
        uint256 balance
    ) {
        uint256 ex = 0;
        uint256 rv = 0;
        for (uint256 i = 0; i < _claws.length; i++) {
            if (_claws[i].executed) ex++;
            else if (_claws[i].reverted) rv++;
        }
        return (_claws.length, ex, rv, _claws.length - ex - rv, address(this).balance);
    }
    function getConfigSnapshot() external view returns (
        address op,
        address guard,
