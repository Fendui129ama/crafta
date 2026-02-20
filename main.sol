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
            platformFeeBps: platformFeeBps,
            maxMintPerWallet: maxMintPerWallet,
            createdAtBlock: block.number,
            paused: false,
            finalized: false
        });
        creatorProfiles[cid].totalDrops++;
        dropIdsByCreator[cid].push(dropId);
        _allDropIds.push(dropId);
        emit DropScheduled(dropId, cid, contentHash, maxSupply, pricePerMintWei, block.number);
        if (maxMintPerWallet > 0) emit MaxMintPerWalletSet(dropId, maxMintPerWallet, block.number);
        return dropId;
    }

    function addPhase(
        uint256 dropId,
        uint32 startBlock,
        uint32 endBlock,
        bool allowlistOnly,
        bytes32 merkleRoot
    ) external whenLaunchpadNotPaused nonReentrant {
        DropConfig storage dc = dropConfigs[dropId];
        if (dc.creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dc.creatorId].creator != msg.sender) revert CFA_NotCreator();
        if (dc.finalized) revert CFA_DropAlreadyFinalized();
        if (startBlock >= endBlock) revert CFA_InvalidPhaseBounds();

        uint8 slot = 0;
        while (slot < CFA_MAX_PHASES_PER_DROP && phasesByDrop[dropId][slot].configured) slot++;
        if (slot >= CFA_MAX_PHASES_PER_DROP) revert CFA_TooManyPhases();

        phasesByDrop[dropId][slot] = MintPhaseConfig({
            startBlock: startBlock,
            endBlock: endBlock,
            allowlistOnly: allowlistOnly,
            merkleRoot: merkleRoot,
            phaseMintCap: 0,
            phaseMintedCount: 0,
            configured: true
        });
        emit PhaseAdded(dropId, slot, startBlock, endBlock, allowlistOnly, merkleRoot, block.number);
    }

    function setPhaseCap(uint256 dropId, uint8 phaseIndex, uint256 cap) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        if (!phasesByDrop[dropId][phaseIndex].configured) revert CFA_PhaseNotFound();
        phasesByDrop[dropId][phaseIndex].phaseMintCap = cap;
        emit PhaseCapSet(dropId, phaseIndex, cap, block.number);
    }

    function setDropLabel(uint256 dropId, bytes32 labelHash) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        if (dropConfigs[dropId].finalized) revert CFA_DropAlreadyFinalized();
        dropConfigs[dropId].labelHash = labelHash;
        emit DropLabelSet(dropId, labelHash, block.number);
    }

    function updateDropContentHash(uint256 dropId, bytes32 newContentHash) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        if (dropConfigs[dropId].finalized) revert CFA_DropAlreadyFinalized();
        bytes32 prev = dropConfigs[dropId].contentHash;
        dropConfigs[dropId].contentHash = newContentHash;
        emit DropContentHashUpdated(dropId, prev, newContentHash, block.number);
    }

    function deactivateCreator(uint256 creatorId_) external onlyOwner {
        if (creatorProfiles[creatorId_].creator == address(0)) revert CFA_CreatorNotFound();
        creatorProfiles[creatorId_].active = false;
        emit CreatorDeactivated(creatorId_, msg.sender, block.number);
    }

    function keeperPauseDrop(uint256 dropId, bool paused) external {
        if (msg.sender != launchpadKeeper) revert CFA_NotKeeper();
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        dropConfigs[dropId].paused = paused;
        emit KeeperDropPauseToggled(dropId, paused, block.number);
    }

    function batchWithdrawTreasuryProceeds(uint256[] calldata dropIds) external nonReentrant {
        if (msg.sender != treasury) revert CFA_NotTreasury();
        if (dropIds.length == 0) revert CFA_EmptyBatch();
        uint256 totalWei = 0;
        for (uint256 i = 0; i < dropIds.length; i++) {
            uint256 amt = dropProceeds[dropIds[i]].treasuryPendingWei;
            if (amt > 0) {
                dropProceeds[dropIds[i]].treasuryPendingWei = 0;
                totalWei += amt;
            }
        }
        if (totalWei == 0) revert CFA_ZeroAmount();
        (bool sent,) = treasury.call{value: totalWei}("");
        if (!sent) revert CFA_TransferFailed();
        emit BatchTreasurySweep(dropIds, totalWei, block.number);
    }

    function batchWithdrawFeeProceeds(uint256[] calldata dropIds) external nonReentrant {
        if (msg.sender != feeRecipient) revert CFA_NotFeeRecipient();
        if (dropIds.length == 0) revert CFA_EmptyBatch();
        uint256 totalWei = 0;
        for (uint256 i = 0; i < dropIds.length; i++) {
            uint256 amt = dropProceeds[dropIds[i]].feePendingWei;
            if (amt > 0) {
                dropProceeds[dropIds[i]].feePendingWei = 0;
                totalWei += amt;
            }
        }
        if (totalWei == 0) revert CFA_ZeroAmount();
        (bool sent,) = feeRecipient.call{value: totalWei}("");
        if (!sent) revert CFA_TransferFailed();
        emit BatchFeeSweep(dropIds, totalWei, block.number);
    }

    function updatePhaseBounds(uint256 dropId, uint8 phaseIndex, uint32 startBlock, uint32 endBlock) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        if (!phasesByDrop[dropId][phaseIndex].configured) revert CFA_PhaseNotFound();
        if (startBlock >= endBlock) revert CFA_InvalidPhaseBounds();

        phasesByDrop[dropId][phaseIndex].startBlock = startBlock;
        phasesByDrop[dropId][phaseIndex].endBlock = endBlock;
        emit PhaseUpdated(dropId, phaseIndex, startBlock, endBlock, block.number);
    }

    function setAllowlistProof(uint256 dropId, uint8 phaseIndex, bytes32 merkleRoot) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        if (!phasesByDrop[dropId][phaseIndex].configured) revert CFA_PhaseNotFound();

        phasesByDrop[dropId][phaseIndex].merkleRoot = merkleRoot;
        emit AllowlistProofSet(dropId, phaseIndex, merkleRoot, block.number);
    }

    function setDropPaused(uint256 dropId, bool paused) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        dropConfigs[dropId].paused = paused;
        emit DropPauseToggled(dropId, paused);
    }

    function mint(
        uint256 dropId,
        uint8 phaseIndex,
        uint256 quantity,
        bytes32[] calldata proof
    ) external payable whenLaunchpadNotPaused dropNotPaused(dropId) nonReentrant {
        DropConfig storage dc = dropConfigs[dropId];
        if (dc.creatorId == 0) revert CFA_DropNotFound();
        if (dc.finalized) revert CFA_DropAlreadyFinalized();
        if (!phasesByDrop[dropId][phaseIndex].configured) revert CFA_PhaseNotFound();

        MintPhaseConfig storage ph = phasesByDrop[dropId][phaseIndex];
        if (block.number < ph.startBlock) revert CFA_PhaseNotStarted();
        if (block.number > ph.endBlock) revert CFA_PhaseEnded();

        if (ph.allowlistOnly) {
            if (proof.length == 0) revert CFA_AllowlistRequired();
            if (!_verifyAllowlist(dropId, phaseIndex, msg.sender, proof)) revert CFA_InvalidProof();
        }

        if (dc.mintedSupply + quantity > dc.maxSupply) revert CFA_MaxSupplyReached();
        if (dc.maxMintPerWallet > 0 && mintCountByDropAndWallet[dropId][msg.sender] + quantity > dc.maxMintPerWallet) revert CFA_MaxPerWalletExceeded();
        if (ph.phaseMintCap > 0 && ph.phaseMintedCount + quantity > ph.phaseMintCap) revert CFA_PhaseCapReached();
        if (!creatorProfiles[dc.creatorId].active) revert CFA_CreatorInactive();

        uint256 totalCost = dc.pricePerMintWei * quantity;
        if (msg.value < totalCost) revert CFA_InsufficientPayment();

        dc.mintedSupply += quantity;
        mintCountByDropAndWallet[dropId][msg.sender] += quantity;
        creatorProfiles[dc.creatorId].totalMintsFromDrops += quantity;
        phasesByDrop[dropId][phaseIndex].phaseMintedCount += quantity;

        uint256 feeWei = (totalCost * dc.platformFeeBps) / CFA_BPS_BASE;
        uint256 toCreator = totalCost - feeWei;
        uint256 halfFee = feeWei / 2;
        dropProceeds[dropId].creatorPendingWei += toCreator;
        dropProceeds[dropId].treasuryPendingWei += halfFee;
        dropProceeds[dropId].feePendingWei += (feeWei - halfFee);

        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenIndex = dc.mintedSupply - quantity + i;
            mintOwnerByDropAndIndex[dropId][tokenIndex] = msg.sender;
            mintedDropIdsByWallet[msg.sender].push(dropId);
            emit MintExecuted(dropId, tokenIndex, msg.sender, phaseIndex, dc.pricePerMintWei, block.number);
        }

        if (msg.value > totalCost) {
            (bool refundOk,) = msg.sender.call{value: msg.value - totalCost}("");
            if (!refundOk) revert CFA_TransferFailed();
        }
    }

    function _verifyAllowlist(uint256 dropId, uint8 phaseIndex, address account, bytes32[] calldata proof) internal view returns (bool) {
        bytes32 root = phasesByDrop[dropId][phaseIndex].merkleRoot;
        if (root == bytes32(0)) return false;
        bytes32 leaf = keccak256(abi.encodePacked(chainDomain, dropId, phaseIndex, account));
        for (uint256 i = 0; i < proof.length; i++) {
            leaf = leaf < proof[i] ? keccak256(abi.encodePacked(leaf, proof[i])) : keccak256(abi.encodePacked(proof[i], leaf));
        }
        return leaf == root;
    }

    function withdrawCreatorProceeds(uint256 dropId) external nonReentrant {
        DropConfig storage dc = dropConfigs[dropId];
        if (dc.creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dc.creatorId].creator != msg.sender) revert CFA_NotCreator();
        uint256 amount = dropProceeds[dropId].creatorPendingWei;
        if (amount == 0) revert CFA_ZeroAmount();
        dropProceeds[dropId].creatorPendingWei = 0;
        (bool sent,) = msg.sender.call{value: amount}("");
        if (!sent) revert CFA_TransferFailed();
        emit ProceedsSwept(msg.sender, amount, CFA_RECIPIENT_CREATOR, block.number);
    }

    function withdrawTreasuryProceeds(uint256 dropId) external nonReentrant {
        if (msg.sender != treasury) revert CFA_NotCreator();
        uint256 amount = dropProceeds[dropId].treasuryPendingWei;
        if (amount == 0) revert CFA_ZeroAmount();
        dropProceeds[dropId].treasuryPendingWei = 0;
        (bool sent,) = treasury.call{value: amount}("");
        if (!sent) revert CFA_TransferFailed();
        emit ProceedsSwept(treasury, amount, CFA_RECIPIENT_TREASURY, block.number);
    }

    function withdrawFeeProceeds(uint256 dropId) external nonReentrant {
        if (msg.sender != feeRecipient) revert CFA_NotCreator();
        uint256 amount = dropProceeds[dropId].feePendingWei;
        if (amount == 0) revert CFA_ZeroAmount();
        dropProceeds[dropId].feePendingWei = 0;
        (bool sent,) = feeRecipient.call{value: amount}("");
        if (!sent) revert CFA_TransferFailed();
        emit ProceedsSwept(feeRecipient, amount, CFA_RECIPIENT_FEE, block.number);
    }

    function finalizeDrop(uint256 dropId) external {
        if (dropConfigs[dropId].creatorId == 0) revert CFA_DropNotFound();
        if (creatorProfiles[dropConfigs[dropId].creatorId].creator != msg.sender) revert CFA_NotCreator();
        dropConfigs[dropId].finalized = true;
    }

    function getCreatorProfile(uint256 creatorId_) external view returns (
        address creator,
        bytes32 handleHash,
        uint256 totalDrops,
        uint256 totalMintsFromDrops,
        uint256 registeredAtBlock,
        bool active
    ) {
        CreatorProfile storage cp = creatorProfiles[creatorId_];
        return (cp.creator, cp.handleHash, cp.totalDrops, cp.totalMintsFromDrops, cp.registeredAtBlock, cp.active);
    }

    function getDropConfig(uint256 dropId) external view returns (
        uint256 creatorId,
        bytes32 contentHash,
        bytes32 labelHash,
        uint256 maxSupply,
        uint256 mintedSupply,
        uint256 pricePerMintWei,
        uint256 platformFeeBps,
        uint256 maxMintPerWallet,
        uint256 createdAtBlock,
        bool paused,
