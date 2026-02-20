// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title crafta
 * @notice Digital art launchpad: creators schedule drops, set mint phases and allowlists; collectors mint from active phases. Proceeds split to creator, treasury, and platform fee recipient. Suited for curated digital art releases with phased access.
 * @dev Deploy-time addresses and domain salt are immutable. ReentrancyGuard and pause for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract crafta is ReentrancyGuard, Ownable {

    event CreatorOnboarded(address indexed creator, bytes32 handleHash, uint256 creatorId, uint256 atBlock);
    event DropScheduled(
        uint256 indexed dropId,
        uint256 indexed creatorId,
        bytes32 contentHash,
        uint256 maxSupply,
        uint256 pricePerMintWei,
        uint256 atBlock
    );
    event PhaseAdded(
        uint256 indexed dropId,
        uint8 phaseIndex,
        uint32 startBlock,
        uint32 endBlock,
        bool allowlistOnly,
        bytes32 merkleRoot,
        uint256 atBlock
    );
    event PhaseUpdated(uint256 indexed dropId, uint8 phaseIndex, uint32 startBlock, uint32 endBlock, uint256 atBlock);
    event MintExecuted(
        uint256 indexed dropId,
        uint256 indexed tokenIndex,
        address indexed minter,
        uint8 phaseIndex,
        uint256 paidWei,
        uint256 atBlock
    );
    event ProceedsSwept(address indexed recipient, uint256 amountWei, uint8 recipientKind, uint256 atBlock);
    event LaunchpadPauseToggled(bool paused);
    event DropPauseToggled(uint256 indexed dropId, bool paused);
    event AllowlistProofSet(uint256 indexed dropId, uint8 phaseIndex, bytes32 merkleRoot, uint256 atBlock);
    event CreatorHandleUpdated(uint256 indexed creatorId, bytes32 handleHash, uint256 atBlock);
    event MaxMintPerWalletSet(uint256 indexed dropId, uint256 maxPerWallet, uint256 atBlock);
    event CreatorDeactivated(uint256 indexed creatorId, address indexed by, uint256 atBlock);
    event DropContentHashUpdated(uint256 indexed dropId, bytes32 previousHash, bytes32 newHash, uint256 atBlock);
    event PhaseCapSet(uint256 indexed dropId, uint8 phaseIndex, uint256 cap, uint256 atBlock);
    event KeeperDropPauseToggled(uint256 indexed dropId, bool paused, uint256 atBlock);
    event BatchTreasurySweep(uint256[] dropIds, uint256 totalWei, uint256 atBlock);
    event BatchFeeSweep(uint256[] dropIds, uint256 totalWei, uint256 atBlock);
    event DropLabelSet(uint256 indexed dropId, bytes32 labelHash, uint256 atBlock);

    error CFA_ZeroAddress();
    error CFA_ZeroAmount();
    error CFA_LaunchpadPaused();
    error CFA_DropPaused();
    error CFA_CreatorNotFound();
    error CFA_CreatorAlreadyOnboarded();
    error CFA_DropNotFound();
    error CFA_PhaseNotFound();
    error CFA_PhaseNotActive();
    error CFA_PhaseNotStarted();
    error CFA_PhaseEnded();
    error CFA_AllowlistRequired();
    error CFA_InvalidProof();
    error CFA_MaxSupplyReached();
    error CFA_MaxPerWalletExceeded();
    error CFA_InsufficientPayment();
    error CFA_TransferFailed();
    error CFA_InvalidPhaseBounds();
    error CFA_InvalidFeeBps();
    error CFA_TooManyPhases();
    error CFA_Reentrancy();
