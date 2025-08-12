// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IPriceOracle {
    function getLatestPrice() external view returns (int256);
}

contract DynamicNFT is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;
    
    struct TokenData {
        uint256 evolutionLevel;
        uint256 lastPriceCheck;
        string currentStage;
    }
    
    mapping(uint256 => TokenData) public tokenData;
    uint256 private _tokenIdCounter;
    
    IPriceOracle public priceOracle;
    int256 public priceThresholdLow = 30000 * 1e8; // $30,000 (assuming 8 decimals)
    int256 public priceThresholdHigh = 50000 * 1e8; // $50,000 (assuming 8 decimals)
    uint256 public evolutionCooldown = 1 hours;
    
    // Constants for evolution levels
    uint256 public constant MIN_EVOLUTION_LEVEL = 1;
    uint256 public constant MAX_EVOLUTION_LEVEL = 5;
    
    string private _baseTokenURI;
    
    event NFTEvolved(uint256 indexed tokenId, uint256 newLevel, string newStage);
    event PriceThresholdsUpdated(int256 newLow, int256 newHigh);
    event OracleUpdated(address newOracle);
    
    constructor(
        string memory name,
        string memory symbol,
        address _priceOracle,
        string memory _baseURI
    ) ERC721(name, symbol) Ownable(msg.sender) {
        require(_priceOracle != address(0), "Oracle address cannot be zero");
        require(bytes(_baseURI).length > 0, "Base URI cannot be empty");
        
        priceOracle = IPriceOracle(_priceOracle);
        _baseTokenURI = _baseURI;
    }
    
    /**
     * @dev Mint a new dynamic NFT
     */
    function mint(address to) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot mint to zero address");
        
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        
        _safeMint(to, tokenId);
        
        // Initialize token with base state
        tokenData[tokenId] = TokenData({
            evolutionLevel: MIN_EVOLUTION_LEVEL,
            lastPriceCheck: block.timestamp,
            currentStage: _getStageByLevel(MIN_EVOLUTION_LEVEL)
        });
        
        emit NFTEvolved(tokenId, MIN_EVOLUTION_LEVEL, tokenData[tokenId].currentStage);
    }
    
    /**
     * @dev Update NFT based on current external price data
     */
    function evolveNFT(uint256 tokenId) external nonReentrant {
        // FIX: Use ownerOf() instead of _ownerOf() for proper existence check
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        require(
            block.timestamp >= tokenData[tokenId].lastPriceCheck + evolutionCooldown,
            "Evolution cooldown not met"
        );
        
        int256 currentPrice;
        try priceOracle.getLatestPrice() returns (int256 price) {
            require(price > 0, "Invalid price from oracle");
            currentPrice = price;
        } catch {
            revert("Failed to get price from oracle");
        }
        
        TokenData storage token = tokenData[tokenId];
        bool evolutionOccurred = false;
        
        // Evolution logic based on price with proper boundary checks
        if (currentPrice >= priceThresholdHigh && token.evolutionLevel < MAX_EVOLUTION_LEVEL) {
            token.evolutionLevel++;
            evolutionOccurred = true;
        } else if (currentPrice <= priceThresholdLow && token.evolutionLevel > MIN_EVOLUTION_LEVEL) {
            token.evolutionLevel--;
            evolutionOccurred = true;
        }
        
        // Always update timestamp to prevent spam
        token.lastPriceCheck = block.timestamp;
        
        // Update stage and emit event only if evolution occurred
        if (evolutionOccurred) {
            token.currentStage = _getStageByLevel(token.evolutionLevel);
            emit NFTEvolved(tokenId, token.evolutionLevel, token.currentStage);
        }
    }
    
    /**
     * @dev Get the current metadata URI for a token
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // FIX: Use _requireOwned() for proper ERC721 compliance in newer OpenZeppelin versions
        _requireOwned(tokenId);
        
        TokenData memory token = tokenData[tokenId];
        return string(abi.encodePacked(
            _baseTokenURI,
            token.evolutionLevel.toString(),
            ".json"
        ));
    }
    
    /**
     * @dev Update price thresholds (only owner)
     */
    function updatePriceThresholds(int256 _low, int256 _high) external onlyOwner {
        require(_low > 0 && _high > 0, "Thresholds must be positive");
        require(_low < _high, "Low threshold must be less than high threshold");
        
        priceThresholdLow = _low;
        priceThresholdHigh = _high;
        
        emit PriceThresholdsUpdated(_low, _high);
    }
    
    /**
     * @dev Update oracle address (only owner)
     */
    function updateOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "Oracle address cannot be zero");
        priceOracle = IPriceOracle(_newOracle);
        emit OracleUpdated(_newOracle);
    }
    
    /**
     * @dev Update evolution cooldown period (only owner)
     */
    function updateEvolutionCooldown(uint256 _newCooldown) external onlyOwner {
        require(_newCooldown >= 10 minutes, "Cooldown too short");
        require(_newCooldown <= 7 days, "Cooldown too long");
        evolutionCooldown = _newCooldown;
    }
    
    /**
     * @dev Update base URI (only owner)
     */
    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        require(bytes(_newBaseURI).length > 0, "Base URI cannot be empty");
        _baseTokenURI = _newBaseURI;
    }
    
    /**
     * @dev Emergency pause evolution (only owner)
     */
    function emergencySetTokenData(
        uint256 tokenId, 
        uint256 level, 
        string memory stage
    ) external onlyOwner {
        // FIX: Use ownerOf() for proper existence check
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        require(level >= MIN_EVOLUTION_LEVEL && level <= MAX_EVOLUTION_LEVEL, "Invalid level");
        
        tokenData[tokenId].evolutionLevel = level;
        tokenData[tokenId].currentStage = stage;
        tokenData[tokenId].lastPriceCheck = block.timestamp;
        
        emit NFTEvolved(tokenId, level, stage);
    }
    
    /**
     * @dev Get current evolution data for a token
     */
    function getTokenEvolutionData(uint256 tokenId) external view returns (
        uint256 level,
        string memory stage,
        uint256 lastCheck,
        int256 currentPrice,
        uint256 timeUntilNextEvolution
    ) {
        // FIX: Use ownerOf() for proper existence check
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        
        TokenData memory token = tokenData[tokenId];
        int256 price = 0;
        
        try priceOracle.getLatestPrice() returns (int256 oraclePrice) {
            price = oraclePrice;
        } catch {
            // If oracle fails, return 0 for price
        }
        
        uint256 timeRemaining = 0;
        if (block.timestamp < token.lastPriceCheck + evolutionCooldown) {
            timeRemaining = (token.lastPriceCheck + evolutionCooldown) - block.timestamp;
        }
        
        return (
            token.evolutionLevel,
            token.currentStage,
            token.lastPriceCheck,
            price,
            timeRemaining
        );
    }
    
    /**
     * @dev Get total number of minted tokens
     */
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }
    
    /**
     * @dev Check if a token can evolve (public view function)
     */
    function canEvolve(uint256 tokenId) external view returns (bool) {
        // FIX: Add try-catch for ownerOf() to handle non-existent tokens gracefully
        try this.ownerOf(tokenId) returns (address) {
            return block.timestamp >= tokenData[tokenId].lastPriceCheck + evolutionCooldown;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Get evolution requirements for a specific token
     */
    function getEvolutionRequirements(uint256 tokenId) external view returns (
        bool canEvolveUp,
        bool canEvolveDown,
        int256 priceNeededUp,
        int256 priceNeededDown
    ) {
        // FIX: Use ownerOf() for proper existence check
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        
        TokenData memory token = tokenData[tokenId];
        
        canEvolveUp = token.evolutionLevel < MAX_EVOLUTION_LEVEL;
        canEvolveDown = token.evolutionLevel > MIN_EVOLUTION_LEVEL;
        priceNeededUp = canEvolveUp ? priceThresholdHigh : int256(0);
        priceNeededDown = canEvolveDown ? priceThresholdLow : int256(0);
    }
    
    // Internal helper function with better error handling
    function _getStageByLevel(uint256 level) internal pure returns (string memory) {
        require(level >= MIN_EVOLUTION_LEVEL && level <= MAX_EVOLUTION_LEVEL, "Invalid evolution level");
        
        if (level == 1) return "Seedling";
        if (level == 2) return "Sprout";
        if (level == 3) return "Sapling";
        if (level == 4) return "Tree";
        if (level == 5) return "Ancient Tree";
        
        revert("Unexpected evolution level");
    }
}
