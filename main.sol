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
    error CFA_NotCreator();
    error CFA_DropAlreadyFinalized();
    error CFA_ZeroSupply();
    error CFA_PhaseCapReached();
    error CFA_NotKeeper();
    error CFA_NotTreasury();
    error CFA_NotFeeRecipient();
    error CFA_EmptyBatch();
    error CFA_CreatorInactive();

    uint256 public constant CFA_BPS_BASE = 10000;
    uint256 public constant CFA_MAX_FEE_BPS = 1500;
    uint256 public constant CFA_MAX_PHASES_PER_DROP = 12;
    uint256 public constant CFA_MAX_DROPS = 500;
    uint256 public constant CFA_MAX_CREATORS = 2000;
    uint256 public constant CFA_DOMAIN_SALT = 0xC7e2A5d8F1b4E0a3C6d9F2b5E8a1D4c7F0b3E6A9;
    uint8 public constant CFA_RECIPIENT_CREATOR = 1;
    uint8 public constant CFA_RECIPIENT_TREASURY = 2;
    uint8 public constant CFA_RECIPIENT_FEE = 3;

    address public immutable treasury;
    address public immutable feeRecipient;
    address public immutable launchpadKeeper;
    uint256 public immutable deployedBlock;
    bytes32 public immutable chainDomain;

    uint256 public creatorCounter;
    uint256 public dropCounter;
    bool public launchpadPaused;

    struct CreatorProfile {
        address creator;
        bytes32 handleHash;
        uint256 totalDrops;
        uint256 totalMintsFromDrops;
        uint256 registeredAtBlock;
        bool active;
    }

    struct DropConfig {
        uint256 creatorId;
        bytes32 contentHash;
        bytes32 labelHash;
        uint256 maxSupply;
        uint256 mintedSupply;
        uint256 pricePerMintWei;
        uint256 platformFeeBps;
        uint256 maxMintPerWallet;
        uint256 createdAtBlock;
        bool paused;
        bool finalized;
    }

    struct MintPhaseConfig {
        uint32 startBlock;
        uint32 endBlock;
        bool allowlistOnly;
        bytes32 merkleRoot;
        uint256 phaseMintCap;
        uint256 phaseMintedCount;
        bool configured;
    }

    struct DropView {
        uint256 dropId;
        uint256 creatorId;
        bytes32 contentHash;
        bytes32 labelHash;
        uint256 maxSupply;
        uint256 mintedSupply;
        uint256 pricePerMintWei;
        uint256 platformFeeBps;
        uint256 maxMintPerWallet;
        uint256 createdAtBlock;
        bool paused;
        bool finalized;
    }

    struct CreatorView {
        uint256 creatorId;
        address creator;
        bytes32 handleHash;
        uint256 totalDrops;
        uint256 totalMintsFromDrops;
        uint256 registeredAtBlock;
        bool active;
    }

    struct PhaseView {
        uint8 phaseIndex;
        uint32 startBlock;
        uint32 endBlock;
        bool allowlistOnly;
        bytes32 merkleRoot;
        uint256 phaseMintCap;
        uint256 phaseMintedCount;
        bool configured;
    }

    struct DropProceeds {
        uint256 creatorPendingWei;
        uint256 treasuryPendingWei;
        uint256 feePendingWei;
    }

    mapping(uint256 => CreatorProfile) public creatorProfiles;
    mapping(address => uint256) public creatorIdByAddress;
    mapping(uint256 => DropConfig) public dropConfigs;
    mapping(uint256 => MintPhaseConfig[12]) public phasesByDrop;
    mapping(uint256 => DropProceeds) public dropProceeds;
    mapping(uint256 => mapping(address => uint256)) public mintCountByDropAndWallet;
    mapping(uint256 => mapping(uint256 => address)) public mintOwnerByDropAndIndex;
    mapping(uint256 => uint256[]) public dropIdsByCreator;
    mapping(address => uint256[]) public mintedDropIdsByWallet;

    uint256[] private _allCreatorIds;
    uint256[] private _allDropIds;

    modifier whenLaunchpadNotPaused() {
        if (launchpadPaused) revert CFA_LaunchpadPaused();
        _;
    }

    modifier dropNotPaused(uint256 dropId) {
        if (dropConfigs[dropId].paused) revert CFA_DropPaused();
        _;
    }

    constructor() {
        treasury = address(0x8C3e7A1d5F9b2E4c6A0d8F1b3E5a7C9e2B4d6F8);
        feeRecipient = address(0x2E5a8c1D4f7B0e3A6c9d2F5b8E1a4C7e0D3f6B9);
        launchpadKeeper = address(0xA4d7F0b3E6c9D2f5A8e1C4b7D0a3F6c9E2b5D8f1);
        deployedBlock = block.number;
        chainDomain = keccak256(abi.encodePacked("crafta_", block.chainid, block.prevrandao, CFA_DOMAIN_SALT));
    }

    function setLaunchpadPaused(bool paused) external onlyOwner {
        launchpadPaused = paused;
        emit LaunchpadPauseToggled(paused);
    }

    function onboardCreator(bytes32 handleHash) external whenLaunchpadNotPaused nonReentrant returns (uint256 creatorId) {
        if (msg.sender == address(0)) revert CFA_ZeroAddress();
        if (creatorIdByAddress[msg.sender] != 0) revert CFA_CreatorAlreadyOnboarded();
        if (creatorCounter >= CFA_MAX_CREATORS) revert CFA_CreatorNotFound();

        creatorCounter++;
        creatorId = creatorCounter;
        creatorIdByAddress[msg.sender] = creatorId;
        creatorProfiles[creatorId] = CreatorProfile({
            creator: msg.sender,
            handleHash: handleHash,
            totalDrops: 0,
            totalMintsFromDrops: 0,
            registeredAtBlock: block.number,
            active: true
        });
        _allCreatorIds.push(creatorId);
        emit CreatorOnboarded(msg.sender, handleHash, creatorId, block.number);
        return creatorId;
    }

    function updateCreatorHandle(uint256 creatorId_, bytes32 handleHash) external {
        if (creatorProfiles[creatorId_].creator != msg.sender) revert CFA_NotCreator();
        creatorProfiles[creatorId_].handleHash = handleHash;
        emit CreatorHandleUpdated(creatorId_, handleHash, block.number);
    }

    function scheduleDrop(
        bytes32 contentHash,
        uint256 maxSupply,
        uint256 pricePerMintWei,
        uint256 platformFeeBps,
        uint256 maxMintPerWallet
    ) external whenLaunchpadNotPaused nonReentrant returns (uint256 dropId) {
        uint256 cid = creatorIdByAddress[msg.sender];
        if (cid == 0 || !creatorProfiles[cid].active) revert CFA_CreatorNotFound();
        if (maxSupply == 0) revert CFA_ZeroSupply();
        if (platformFeeBps > CFA_MAX_FEE_BPS) revert CFA_InvalidFeeBps();
        if (dropCounter >= CFA_MAX_DROPS) revert CFA_DropNotFound();

        dropCounter++;
        dropId = dropCounter;
        dropConfigs[dropId] = DropConfig({
            creatorId: cid,
            contentHash: contentHash,
            labelHash: bytes32(0),
            maxSupply: maxSupply,
            mintedSupply: 0,
            pricePerMintWei: pricePerMintWei,
