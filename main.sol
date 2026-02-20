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
