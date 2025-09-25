// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, euint64, ebool, eaddress } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateContentShare is SepoliaConfig {

    address public owner;
    uint256 public nextContentId;
    uint256 public nextAccessTokenId;

    struct EncryptedContent {
        address creator;
        euint64 encryptedData;
        euint32 accessPrice;
        uint256 timestamp;
        bool isActive;
        string title;
        string description;
        mapping(address => bool) hasAccess;
        mapping(address => uint256) accessTokens;
    }

    struct AccessToken {
        uint256 contentId;
        address owner;
        uint256 expirationTime;
        bool isValid;
        euint32 encryptedKey;
    }

    mapping(uint256 => EncryptedContent) public contents;
    mapping(uint256 => AccessToken) public accessTokens;
    mapping(address => uint256[]) public userContents;
    mapping(address => uint256[]) public userAccessTokens;

    event ContentCreated(
        uint256 indexed contentId,
        address indexed creator,
        string title,
        uint256 timestamp
    );

    event AccessPurchased(
        uint256 indexed contentId,
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 expirationTime
    );

    event ContentAccessed(
        uint256 indexed contentId,
        address indexed accessor,
        uint256 timestamp
    );

    event AccessRevoked(
        uint256 indexed contentId,
        address indexed user,
        uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    modifier onlyContentCreator(uint256 _contentId) {
        require(contents[_contentId].creator == msg.sender, "Not content creator");
        _;
    }

    modifier contentExists(uint256 _contentId) {
        require(contents[_contentId].creator != address(0), "Content does not exist");
        _;
    }

    modifier hasValidAccess(uint256 _contentId) {
        require(
            contents[_contentId].hasAccess[msg.sender] ||
            contents[_contentId].creator == msg.sender,
            "No access to content"
        );
        _;
    }

    constructor() {
        owner = msg.sender;
        nextContentId = 1;
        nextAccessTokenId = 1;
    }

    function createContent(
        uint64 _encryptedData,
        uint32 _accessPrice,
        string memory _title,
        string memory _description
    ) external returns (uint256) {
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");

        euint64 encryptedContent = FHE.asEuint64(_encryptedData);
        euint32 encryptedPrice = FHE.asEuint32(_accessPrice);

        uint256 contentId = nextContentId++;

        EncryptedContent storage newContent = contents[contentId];
        newContent.creator = msg.sender;
        newContent.encryptedData = encryptedContent;
        newContent.accessPrice = encryptedPrice;
        newContent.timestamp = block.timestamp;
        newContent.isActive = true;
        newContent.title = _title;
        newContent.description = _description;

        userContents[msg.sender].push(contentId);

        FHE.allowThis(encryptedContent);
        FHE.allowThis(encryptedPrice);
        FHE.allow(encryptedContent, msg.sender);
        FHE.allow(encryptedPrice, msg.sender);

        emit ContentCreated(contentId, msg.sender, _title, block.timestamp);

        return contentId;
    }

    function purchaseAccess(
        uint256 _contentId,
        uint256 _duration
    ) external payable contentExists(_contentId) returns (uint256) {
        require(contents[_contentId].isActive, "Content is not active");
        require(_duration > 0, "Duration must be positive");
        require(!contents[_contentId].hasAccess[msg.sender], "Already has access");

        EncryptedContent storage content = contents[_contentId];

        uint256 tokenId = nextAccessTokenId++;
        uint256 expirationTime = block.timestamp + _duration;

        euint32 accessKey = FHE.randEuint32();

        accessTokens[tokenId] = AccessToken({
            contentId: _contentId,
            owner: msg.sender,
            expirationTime: expirationTime,
            isValid: true,
            encryptedKey: accessKey
        });

        content.hasAccess[msg.sender] = true;
        content.accessTokens[msg.sender] = tokenId;
        userAccessTokens[msg.sender].push(tokenId);

        FHE.allowThis(accessKey);
        FHE.allow(accessKey, msg.sender);
        FHE.allow(content.encryptedData, msg.sender);

        emit AccessPurchased(_contentId, msg.sender, tokenId, expirationTime);

        return tokenId;
    }

    function accessContent(
        uint256 _contentId
    ) external contentExists(_contentId) hasValidAccess(_contentId) returns (bytes32) {
        require(contents[_contentId].isActive, "Content is not active");

        uint256 tokenId = contents[_contentId].accessTokens[msg.sender];
        if (tokenId > 0) {
            require(accessTokens[tokenId].isValid, "Access token is invalid");
            require(
                accessTokens[tokenId].expirationTime > block.timestamp,
                "Access token has expired"
            );
        }

        emit ContentAccessed(_contentId, msg.sender, block.timestamp);

        return FHE.toBytes32(contents[_contentId].encryptedData);
    }

    function revokeAccess(
        uint256 _contentId,
        address _user
    ) external onlyContentCreator(_contentId) {
        require(contents[_contentId].hasAccess[_user], "User does not have access");

        contents[_contentId].hasAccess[_user] = false;

        uint256 tokenId = contents[_contentId].accessTokens[_user];
        if (tokenId > 0) {
            accessTokens[tokenId].isValid = false;
        }

        emit AccessRevoked(_contentId, _user, block.timestamp);
    }

    function updateContentStatus(
        uint256 _contentId,
        bool _isActive
    ) external onlyContentCreator(_contentId) {
        contents[_contentId].isActive = _isActive;
    }

    function getContentInfo(uint256 _contentId) external view contentExists(_contentId) returns (
        address creator,
        string memory title,
        string memory description,
        uint256 timestamp,
        bool isActive
    ) {
        EncryptedContent storage content = contents[_contentId];
        return (
            content.creator,
            content.title,
            content.description,
            content.timestamp,
            content.isActive
        );
    }

    function getUserContents(address _user) external view returns (uint256[] memory) {
        return userContents[_user];
    }

    function getUserAccessTokens(address _user) external view returns (uint256[] memory) {
        return userAccessTokens[_user];
    }

    function getAccessTokenInfo(uint256 _tokenId) external view returns (
        uint256 contentId,
        address tokenOwner,
        uint256 expirationTime,
        bool isValid
    ) {
        AccessToken storage token = accessTokens[_tokenId];
        return (
            token.contentId,
            token.owner,
            token.expirationTime,
            token.isValid
        );
    }

    function checkAccess(
        uint256 _contentId,
        address _user
    ) external view contentExists(_contentId) returns (bool) {
        if (contents[_contentId].creator == _user) {
            return true;
        }

        if (!contents[_contentId].hasAccess[_user]) {
            return false;
        }

        uint256 tokenId = contents[_contentId].accessTokens[_user];
        if (tokenId == 0) {
            return false;
        }

        AccessToken storage token = accessTokens[tokenId];
        return token.isValid && token.expirationTime > block.timestamp;
    }

    function requestContentDecryption(
        uint256 _contentId
    ) external hasValidAccess(_contentId) {
        require(contents[_contentId].isActive, "Content is not active");

        bytes32[] memory cts = new bytes32[](1);
        cts[0] = FHE.toBytes32(contents[_contentId].encryptedData);
        FHE.requestDecryption(cts, this.processContentDecryption.selector);
    }

    function processContentDecryption(
        uint256 requestId,
        uint64 decryptedData,
        bytes memory signatures
    ) external {
        bytes memory signedData = abi.encodePacked(requestId, decryptedData);
        FHE.checkSignatures(requestId, signatures, signedData);
        // Handle decrypted content access
    }

    function getTotalContents() external view returns (uint256) {
        return nextContentId - 1;
    }

    function getTotalAccessTokens() external view returns (uint256) {
        return nextAccessTokenId - 1;
    }
}