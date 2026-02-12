// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title ITeleporterMessenger
 * @notice Interface for Avalanche Teleporter cross chain messaging
 */
interface ITeleporterMessenger {
    function sendCrossChainMessage(
        TeleporterMessageInput calldata messageInput
    ) external returns (uint256 messageID);
}

/**
 * @title TeleporterMessageInput
 * @notice Struct for Teleporter message input
 */
struct TeleporterMessageInput {
    bytes32 destinationBlockchainID;
    address destinationAddress;
    TeleporterFeeInfo feeInfo;
    uint256 requiredGasLimit;
    address[] allowedRelayerAddresses;
    bytes message;
}

/**
 * @title TeleporterFeeInfo
 * @notice Struct for Teleporter fee information
 */
struct TeleporterFeeInfo {
    address feeTokenAddress;
    uint256 amount;
}

/**
 * @title VeriReview
 * @notice Product review system with cross chain trust score broadcasting via Avalanche Teleporter
 * @dev Optimized for Fuji C Chain with Avalanche 9000 features
 */
contract VeriReview is AccessControl, ReentrancyGuard, Pausable {
    
    /// @notice Role for product managers who can add products
    bytes32 public constant PRODUCT_MANAGER_ROLE = keccak256("PRODUCT_MANAGER_ROLE");
    
    /// @notice Role for reviewers
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");
    
    /// @notice Teleporter messenger contract
    ITeleporterMessenger public immutable teleporterMessenger;
    
    /// @notice Structure to store product information
    struct Product {
        address vendor;
        uint32 totalReviews;
        bool isActive;
        bytes32 productId;
        uint128 sumOfRatings;
    }
    
    /// @notice Structure to store review information
    struct Review {
        address reviewer;
        uint32 timestamp;
        uint8 rating;
        bytes32 productId;
        bytes32 transactionId;
    }
    
    /// @notice Structure for trust score data
    struct TrustScore {
        uint32 totalReviews;
        uint32 lastUpdated;
        uint16 averageRating;
        bytes32 productId;
    }
    
    /// @notice Mapping from product ID to Product
    mapping(bytes32 => Product) public products;
    
    /// @notice Mapping from review ID to Review
    mapping(uint256 => Review) public reviews;
    
    /// @notice Mapping from transaction ID to review ID
    mapping(bytes32 => uint256) public transactionToReview;
    
    /// @notice Mapping from transaction ID to usage status
    mapping(bytes32 => bool) public usedTransactions;
    
    /// @notice Mapping from product ID to trust score
    mapping(bytes32 => TrustScore) public trustScores;
    
    /// @notice Counter for review IDs
    uint256 public reviewCounter;
    
    /// @notice Event emitted when a review is posted
    event ReviewPosted(
        uint256 indexed reviewId,
        bytes32 indexed productId,
        address indexed reviewer,
        bytes32 transactionId,
        uint8 rating,
        uint32 timestamp
    );
    
    /// @notice Event emitted when a product is added
    event ProductAdded(
        bytes32 indexed productId,
        address indexed vendor,
        uint32 timestamp
    );
    
    /// @notice Event emitted when trust score is broadcasted
    event TrustScoreBroadcasted(
        bytes32 indexed productId,
        bytes32 indexed destinationChainId,
        uint256 teleporterMessageId,
        uint16 averageRating,
        uint32 totalReviews
    );
    
    /// @notice Event emitted when trust score is updated
    event TrustScoreUpdated(
        bytes32 indexed productId,
        uint16 averageRating,
        uint32 totalReviews
    );
    
    /**
     * @notice Constructor to initialize the contract
     * @param _teleporterMessenger Address of the Teleporter messenger contract
     */
    constructor(address _teleporterMessenger) {
        require(_teleporterMessenger != address(0), "Invalid teleporter address");
        
        teleporterMessenger = ITeleporterMessenger(_teleporterMessenger);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PRODUCT_MANAGER_ROLE, msg.sender);
    }
    
    /**
     * @notice Add a new product
     * @param _productId Unique identifier for the product
     * @param _vendor Address of the vendor
     */
    function addProduct(
        bytes32 _productId,
        address _vendor
    ) external onlyRole(PRODUCT_MANAGER_ROLE) whenNotPaused {
        require(_productId != bytes32(0), "Invalid product ID");
        require(_vendor != address(0), "Invalid vendor address");
        require(products[_productId].productId == bytes32(0), "Product already exists");
        
        products[_productId] = Product({
            vendor: _vendor,
            totalReviews: 0,
            isActive: true,
            productId: _productId,
            sumOfRatings: 0
        });
        
        trustScores[_productId] = TrustScore({
            totalReviews: 0,
            lastUpdated: uint32(block.timestamp),
            averageRating: 0,
            productId: _productId
        });
        
        emit ProductAdded(_productId, _vendor, uint32(block.timestamp));
    }
    
    /**
     * @notice Post a review for a product
     * @param _productId ID of the product being reviewed
     * @param _transactionId Purchase transaction ID as proof of purchase
     * @param _rating Rating from 1 to 100 (allows decimal precision)
     */
    function postReview(
        bytes32 _productId,
        bytes32 _transactionId,
        uint8 _rating
    ) external whenNotPaused nonReentrant {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        require(products[_productId].isActive, "Product not active");
        require(_transactionId != bytes32(0), "Invalid transaction ID");
        require(!usedTransactions[_transactionId], "Transaction already used");
        require(_rating >= 1 && _rating <= 100, "Rating must be 1 to 100");
        require(msg.sender != products[_productId].vendor, "Vendor cannot review own product");
        
        uint256 reviewId = reviewCounter;
        
        reviews[reviewId] = Review({
            reviewer: msg.sender,
            timestamp: uint32(block.timestamp),
            rating: _rating,
            productId: _productId,
            transactionId: _transactionId
        });
        
        transactionToReview[_transactionId] = reviewId;
        usedTransactions[_transactionId] = true;
        
        Product storage product = products[_productId];
        
        unchecked {
            uint128 newSum = product.sumOfRatings + _rating;
            require(newSum >= product.sumOfRatings, "Sum overflow");
            product.sumOfRatings = newSum;
        }
        
        product.totalReviews++;
        
        _updateTrustScore(_productId);
        
        reviewCounter++;
        
        emit ReviewPosted(
            reviewId,
            _productId,
            msg.sender,
            _transactionId,
            _rating,
            uint32(block.timestamp)
        );
    }
    
    /**
     * @notice Internal function to update trust score
     * @param _productId ID of the product
     */
    function _updateTrustScore(bytes32 _productId) internal {
        Product memory product = products[_productId];
        
        require(product.totalReviews > 0, "No reviews to calculate average");
        
        uint256 average = (uint256(product.sumOfRatings) * 100) / uint256(product.totalReviews);
        require(average <= type(uint16).max, "Average rating overflow");
        uint16 averageRating = uint16(average);
        
        trustScores[_productId] = TrustScore({
            totalReviews: product.totalReviews,
            lastUpdated: uint32(block.timestamp),
            averageRating: averageRating,
            productId: _productId
        });
        
        emit TrustScoreUpdated(_productId, averageRating, product.totalReviews);
    }
    
    /**
     * @notice Broadcast trust score to another L1 via Teleporter
     * @param _productId Product ID to broadcast trust score for
     * @param _destinationBlockchainId Destination blockchain ID
     * @param _destinationAddress Recipient contract address on destination chain
     * @param _requiredGasLimit Gas limit for message execution
     * @param _feeTokenAddress Token address for Teleporter fees
     * @param _feeAmount Fee amount for relayers
     */
    function broadcastTrustScore(
        bytes32 _productId,
        bytes32 _destinationBlockchainId,
        address _destinationAddress,
        uint256 _requiredGasLimit,
        address _feeTokenAddress,
        uint256 _feeAmount
    ) external onlyRole(PRODUCT_MANAGER_ROLE) whenNotPaused returns (uint256) {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        require(products[_productId].isActive, "Product not active");
        require(products[_productId].totalReviews > 0, "Product has no reviews");
        require(_destinationBlockchainId != bytes32(0), "Invalid destination chain");
        require(_destinationAddress != address(0), "Invalid destination address");
        
        TrustScore memory score = trustScores[_productId];
        
        bytes memory message = abi.encode(
            score.productId,
            score.averageRating,
            score.totalReviews,
            score.lastUpdated
        );
        
        TeleporterMessageInput memory messageInput = TeleporterMessageInput({
            destinationBlockchainID: _destinationBlockchainId,
            destinationAddress: _destinationAddress,
            feeInfo: TeleporterFeeInfo({
                feeTokenAddress: _feeTokenAddress,
                amount: _feeAmount
            }),
            requiredGasLimit: _requiredGasLimit,
            allowedRelayerAddresses: new address[](0),
            message: message
        });
        
        uint256 messageId = teleporterMessenger.sendCrossChainMessage(messageInput);
        
        emit TrustScoreBroadcasted(
            _productId,
            _destinationBlockchainId,
            messageId,
            score.averageRating,
            score.totalReviews
        );
        
        return messageId;
    }
    
    /**
     * @notice Get product details
     * @param _productId ID of the product
     * @return Product struct
     */
    function getProduct(bytes32 _productId) external view returns (Product memory) {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        return products[_productId];
    }
    
    /**
     * @notice Get review details
     * @param _reviewId ID of the review
     * @return Review struct
     */
    function getReview(uint256 _reviewId) external view returns (Review memory) {
        require(_reviewId < reviewCounter, "Review does not exist");
        return reviews[_reviewId];
    }
    
    /**
     * @notice Get trust score for a product
     * @param _productId ID of the product
     * @return TrustScore struct
     */
    function getTrustScore(bytes32 _productId) external view returns (TrustScore memory) {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        return trustScores[_productId];
    }
    
    /**
     * @notice Verify if a transaction has been used for a review
     * @param _transactionId Transaction ID to check
     * @return bool indicating if transaction was used
     * @return uint256 review ID if used
     */
    function verifyTransaction(bytes32 _transactionId) 
        external 
        view 
        returns (bool, uint256) 
    {
        if (usedTransactions[_transactionId]) {
            return (true, transactionToReview[_transactionId]);
        }
        return (false, 0);
    }
    
    /**
     * @notice Get average rating for a product (in basis points)
     * @param _productId ID of the product
     * @return uint16 average rating (0 to 10000 representing 0.00 to 100.00)
     */
    function getAverageRating(bytes32 _productId) external view returns (uint16) {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        return trustScores[_productId].averageRating;
    }
    
    /**
     * @notice Toggle product active status
     * @param _productId ID of the product
     * @param _isActive New active status
     */
    function setProductStatus(
        bytes32 _productId,
        bool _isActive
    ) external onlyRole(PRODUCT_MANAGER_ROLE) {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        products[_productId].isActive = _isActive;
    }
    
    /**
     * @notice Grant reviewer role to an address
     * @param _reviewer Address to grant role to
     */
    function grantReviewerRole(address _reviewer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(REVIEWER_ROLE, _reviewer);
    }
    
    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Get contract statistics
     * @return uint256 total number of reviews
     */
    function getTotalReviews() external view returns (uint256) {
        return reviewCounter;
    }
    
    /**
     * @notice Batch get trust scores for multiple products
     * @param _productIds Array of product IDs
     * @return TrustScore[] array of trust scores
     */
    function batchGetTrustScores(bytes32[] calldata _productIds) 
        external 
        view 
        returns (TrustScore[] memory) 
    {
        uint256 length = _productIds.length;
        TrustScore[] memory scores = new TrustScore[](length);
        
        for (uint256 i = 0; i < length;) {
            scores[i] = trustScores[_productIds[i]];
            unchecked { ++i; }
        }
        
        return scores;
    }
    
    /**
     * @notice Check if a product exists
     * @param _productId ID of the product
     * @return bool indicating if product exists
     */
    function productExists(bytes32 _productId) external view returns (bool) {
        return products[_productId].productId != bytes32(0);
    }
    
    /**
     * @notice Get product review count
     * @param _productId ID of the product
     * @return uint32 number of reviews
     */
    function getProductReviewCount(bytes32 _productId) external view returns (uint32) {
        require(products[_productId].productId != bytes32(0), "Product does not exist");
        return products[_productId].totalReviews;
    }
}
