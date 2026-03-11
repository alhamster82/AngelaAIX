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
