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

