// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import "./interfaces/ICollectionFeesCalculator.sol";
import "./interfaces/ICollectionWhitelistChecker.sol";

contract MarketplaceV2 is Pausable, Ownable, ReentrancyGuard, ERC721Holder {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    bytes4 public constant IID_IERC721 = type(IERC721).interfaceId;
    address public constant ZERO_ADDRESS = address(0);
    uint256 public constant ONE_HUNDRED_PERCENT = 10000; // 100%
    uint256 public constant MAX_CREATOR_FEE_PERCENT = 2000; // 20%
    uint256 public constant MAX_TRADING_FEE_PERCENT = 2000; // 20%

    uint256 public totalAsks;
    uint256 public totalBids;

    enum CollectionStatus {
        Pending,
        Open,
        Close
    }
    struct Collection {
        address collection;
        CollectionStatus status; // status of the collection
        address creator;
        uint256 creatorFeePercent;
        address whitelistChecker; // whitelist checker (if not set --> 0x00)
    }

    struct Ask {
        address collection;
        uint256 tokenId;
        address seller; // address of the seller
        uint256 price; // price of the token
    }

    struct Bid {
        address bidder;
        uint256 price;
    }

    mapping(address => bool) public admins;
    address public immutable busd;

    address public treasury;
    uint256 public tradingFeePercent;
    uint256 public pendingRevenueTradingFee;

    // collection => total CreatorFee
    mapping(address => uint256) public pendingRevenueCreatorFeeOfCollection;

    EnumerableSet.AddressSet private collectionAddressSet;
    // collection => Collection Info
    mapping(address => Collection) public collections;

    // askId => Ask
    EnumerableSet.UintSet private askIds;
    // askId => Ask
    mapping(uint256 => Ask) public asks;

    // collection => listAskId
    mapping(address => EnumerableSet.UintSet) private askIdsOfCollection;
    // seller => listAskId
    mapping(address => EnumerableSet.UintSet) private askIdsOfSeller;

    // askId => bidId
    mapping(uint256 => uint256) public bestBidIdOfAskId;

    // bidId => Bid
    mapping(uint256 => Bid) public bids;

    //  change Treasury address
    event NewTreasuryAddresses(address treasury);

    //  change TradingFeePercent address
    event NewTradingFeePercent(
        uint256 oldTradingFeePercent,
        uint256 newTradingFeePercent
    );

    // update admin market
    event UpdateAdmins(address[] admins, bool isAdd);

    // New collection is added
    event CollectionNew(
        address indexed collection,
        address indexed creator,
        uint256 creatorFeePercent,
        address indexed whitelistChecker
    );

    // Existing collection is updated
    event CollectionUpdate(
        address indexed collection,
        address indexed creator,
        uint256 creatorFeePercent,
        address indexed whitelistChecker
    );

    event CollectionChangeStatus(
        address indexed collection,
        CollectionStatus oldStatus,
        CollectionStatus newStatus
    );

    event CollectionChangeCreator(
        address indexed collection,
        address oldCreator,
        address newCreator
    );

    event CollectionRemove(address indexed collection);

    event RevenueTradingFeeClaim(
        address indexed claimer,
        address indexed treasury,
        uint256 amount
    );

    event RevenueCreatorFeeClaim(
        address indexed claimer,
        address indexed creator,
        address indexed collection,
        uint256 amount
    );

    event AskListing(
        uint256 indexed askId,
        address indexed seller,
        address indexed collection,
        uint256 tokenId,
        uint256 price
    );

    event AskUpdatePrice(
        uint256 indexed askId,
        uint256 oldPrice,
        uint256 newPrice
    );

    event AskSale(
        uint256 indexed askId,
        address indexed seller,
        address indexed buyer,
        uint256 grossPrice,
        uint256 netPrice
    );

    event AskCancelListing(uint256 indexed askId);

    event BidCreated(
        uint256 indexed askId,
        uint256 indexed bidId,
        address indexed bidder
    );

    event BidCanceled(uint256 indexed askId, uint256 indexed bidId);

    event BidAccepted(
        uint256 indexed askId,
        uint256 indexed bidId,
        address seller,
        address bidder,
        uint256 price,
        uint256 priceAccepted
    );

    // Modifier checking Admin role
    modifier onlyAdmin() {
        require(
            msg.sender != ZERO_ADDRESS && admins[msg.sender],
            "Auth: Account not role admin"
        );
        _;
    }
    modifier verifyCollection(address collection) {
        // Verify collection is accepted
        require(
            collectionAddressSet.contains(collection),
            "Operations: Collection not listed"
        );
        // require(
        //     collections[collection].status == CollectionStatus.Open,
        //     "Collection: Not for listing"
        // );
        _;
    }

    modifier verifyTradingFeePercent(uint256 newTradingFeePercent) {
        // Verify collection is accepted
        require(
            newTradingFeePercent >= 0 &&
                newTradingFeePercent <= MAX_TRADING_FEE_PERCENT,
            "Operations: Trading fee percent not within range"
        );
        _;
    }

    modifier verifyCreatorFeePercent(uint256 newCreatorFeePercent) {
        // Verify collection is accepted
        require(
            newCreatorFeePercent >= 0 &&
                newCreatorFeePercent <= MAX_CREATOR_FEE_PERCENT,
            "Operations: Creator fee percent not within range"
        );
        _;
    }

    modifier verifyPrice(uint256 price) {
        // Verify price
        require(price >= 0, "Order: Price not within range");
        _;
    }

    modifier verifyAsk(uint256 askId) {
        require(askIds.contains(askId), "Order: AskId not existed");
        require(
            collections[asks[askId].collection].status == CollectionStatus.Open,
            "Collection: Not for listing"
        );
        _;
    }

    /**
     * @notice Constructor
     * @param _treasury: address of the treasury
     * @param _busd: BUSD address
     */
    constructor(
        address _busd,
        address _treasury,
        uint256 _tradingFeePercent
    ) verifyTradingFeePercent(_tradingFeePercent) {
        require(
            _treasury != address(0),
            "Operations: Treasury address cannot be zero"
        );
        require(_busd != address(0), "Operations: BUSD address cannot be zero");
        treasury = _treasury;
        busd = _busd;
        admins[msg.sender] = true;
        tradingFeePercent = _tradingFeePercent;
        totalAsks = 0;
        totalBids = 0;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function calculatePriceAndFeesForCollection(
        address _collection,
        uint256 _grossPrice
    )
        public
        view
        returns (uint256 netPrice, uint256 tradingFee, uint256 creatorFee)
    {
        tradingFee = (_grossPrice * tradingFeePercent) / ONE_HUNDRED_PERCENT;
        creatorFee =
            (_grossPrice * collections[_collection].creatorFeePercent) /
            ONE_HUNDRED_PERCENT;
        netPrice = _grossPrice - tradingFee - creatorFee;
        return (netPrice, tradingFee, creatorFee);
    }

    function updateAdmins(
        address[] memory _admins,
        bool _isAdd
    ) external nonReentrant onlyOwner {
        for (uint256 i = 0; i < _admins.length; i++) {
            admins[_admins[i]] = _isAdd;
        }
        emit UpdateAdmins(_admins, _isAdd);
    }

    /**
     * @notice Set admin address
     * @dev Only callable by owner
     * @param _treasury: address of the treasury
     */
    function setTreasuryAddresses(address _treasury) external onlyOwner {
        require(
            _treasury != ZERO_ADDRESS,
            "Operations: Treasury address cannot be zero"
        );
        treasury = _treasury;

        emit NewTreasuryAddresses(_treasury);
    }

    /**
     * @notice Set admin address
     * @dev Only callable by owner
     * @param _tradingFeePercent: new _tradingFeePercent
     */
    function setTradingFeePercent(
        uint256 _tradingFeePercent
    ) external onlyOwner verifyTradingFeePercent(_tradingFeePercent) {
        emit NewTradingFeePercent(tradingFeePercent, _tradingFeePercent);
        tradingFeePercent = _tradingFeePercent;
    }

    /**
     * @notice Add a new collection
     * @param _collection: collection address
     * @param _creator: address fee creator
     * @param _creatorFeePercent: creator fee percent
     * @param _whitelistChecker: whitelist checker (for additional restrictions, must be 0x00 if none)
   
     * @dev Callable by owner
     */
    function addCollection(
        address _collection,
        address _creator,
        uint256 _creatorFeePercent,
        address _whitelistChecker
    )
        external
        onlyAdmin
        whenNotPaused
        verifyCreatorFeePercent(_creatorFeePercent)
    {
        require(
            !collectionAddressSet.contains(_collection),
            "Operations: Collection already listed"
        );
        require(
            IERC721(_collection).supportsInterface(IID_IERC721),
            "Operations: Not ERC721"
        );

        require(_creator != ZERO_ADDRESS, "Operations: Creator zero address");

        collectionAddressSet.add(_collection);
        collections[_collection] = Collection({
            collection: _collection,
            status: CollectionStatus.Open,
            creator: _creator,
            creatorFeePercent: _creatorFeePercent,
            whitelistChecker: _whitelistChecker
        });

        emit CollectionNew(
            _collection,
            _creator,
            _creatorFeePercent,
            _whitelistChecker
        );
    }

    /**
     * @notice Modify collection characteristics
     * @param _collection: collection address
     * @param _creator: address fee creator
     * @param _creatorFeePercent: creator fee percent
     * @param _whitelistChecker: whitelist checker (for additional restrictions, must be 0x00 if none)
     * @dev Callable by admin
     */
    function modifyCollection(
        address _collection,
        address _creator,
        uint256 _creatorFeePercent,
        address _whitelistChecker
    )
        external
        onlyAdmin
        whenNotPaused
        verifyCollection(_collection)
        verifyCreatorFeePercent(_creatorFeePercent)
    {
        collections[_collection] = Collection({
            collection: _collection,
            status: collections[_collection].status,
            creator: _creator,
            creatorFeePercent: _creatorFeePercent,
            whitelistChecker: _whitelistChecker
        });
        emit CollectionUpdate(
            _collection,
            _creator,
            _creatorFeePercent,
            _whitelistChecker
        );
    }

    /**
     * @notice Modify collection characteristics
     * @param _collection: collection address
     * @param _status: collectionStatus
     * @dev Callable by admin
     */
    function changeCollectionStatus(
        address _collection,
        CollectionStatus _status
    ) external onlyAdmin whenNotPaused verifyCollection(_collection) {
        // CollectionStatus oldStatus = collections[_collection].status;
        emit CollectionChangeStatus(
            _collection,
            collections[_collection].status,
            _status
        );
        collections[_collection].status = _status;
    }

    /**
     * @notice changeCreatorCollection
     * @param _collection: collection address
     * @param _newCreator: newCreator
     * @dev Callable by admin
     */
    function changeCreatorCollection(
        address _collection,
        address _newCreator
    ) external onlyAdmin whenNotPaused verifyCollection(_collection) {
        require(
            _newCreator != ZERO_ADDRESS,
            "Operations: New creator zero address"
        );
        emit CollectionChangeCreator(
            _collection,
            collections[_collection].creator,
            _newCreator
        );
        collections[_collection].creator = _newCreator;
    }

    /**
     * @notice remove collection to market
     * @param _collection: collection address
     * @dev Callable by admin
     */
    function removeCollection(
        address _collection
    ) external onlyAdmin whenNotPaused verifyCollection(_collection) {
        delete collections[_collection];
        collectionAddressSet.remove(_collection);
        emit CollectionRemove(_collection);
    }

    /**
     * @notice Checks if a token can be listed
     * @param _collection: address of the collection
     * @param _tokenId: tokenId
     */
    function canTokenBeListed(
        address _collection,
        uint256 _tokenId
    ) internal view returns (bool) {
        address whitelistCheckerAddress = collections[_collection]
            .whitelistChecker;
        return
            (whitelistCheckerAddress == ZERO_ADDRESS) ||
            ICollectionWhitelistChecker(whitelistCheckerAddress).canList(
                _tokenId
            );
    }

    /**
     * @notice Checks if an array of tokenIds can be listed
     * @param _collection: address of the collection
     * @param _tokenIds: array of tokenIds
     * @dev if collection is not for trading, it returns array of bool with false
     */
    function canTokensBeListed(
        address _collection,
        uint256[] calldata _tokenIds
    ) external view returns (bool[] memory listingStatuses) {
        listingStatuses = new bool[](_tokenIds.length);

        if (collections[_collection].status != CollectionStatus.Open) {
            return listingStatuses;
        }

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            listingStatuses[i] = canTokenBeListed(_collection, _tokenIds[i]);
        }

        return listingStatuses;
    }

    /**
     * @notice askListing
     * @param _collection: contract address of the NFT
     * @param _tokenId: tokenId of the NFT
     * @param _price: price for listing (in BUSD)
     */
    function askListing(
        address _collection,
        uint256 _tokenId,
        uint256 _price
    )
        external
        whenNotPaused
        nonReentrant
        verifyPrice(_price)
        returns (uint256)
    {
        require(
            canTokenBeListed(_collection, _tokenId),
            "Order: tokenId not eligible"
        );
        // Transfer NFT to this contract
        IERC721(_collection).safeTransferFrom(
            address(msg.sender),
            address(this),
            _tokenId
        );
        uint256 askId = ++totalAsks;
        // add listAskId
        askIds.add(askId);
        // add Ask to askList
        asks[askId] = Ask({
            collection: _collection,
            tokenId: _tokenId,
            seller: msg.sender,
            price: _price
        });
        askIdsOfCollection[_collection].add(askId);
        askIdsOfSeller[msg.sender].add(askId);
        emit AskListing(askId, msg.sender, _collection, _tokenId, _price);
        return askId;
    }

    /**
     * @notice askUpdatePrice
     * @param _askId: askId
     * @param _newPrice: newPrice for listing (in BUSD)
     */
    function askUpdatePrice(
        uint256 _askId,
        uint256 _newPrice
    )
        external
        whenNotPaused
        nonReentrant
        verifyPrice(_newPrice)
        verifyAsk(_askId)
        returns (uint256)
    {
        require(
            askIdsOfSeller[msg.sender].contains(_askId),
            "Order: AskId do not own your ownership"
        );
        emit AskUpdatePrice(_askId, asks[_askId].price, _newPrice);
        asks[_askId].price = _newPrice;
        return _askId;
    }

    /**
     * @notice askCancelListing
     * @param _askId: askId
     */
    function askCancelListing(
        uint256 _askId
    ) external whenNotPaused nonReentrant verifyAsk(_askId) returns (uint256) {
        require(
            askIdsOfSeller[msg.sender].contains(_askId),
            "Order: AskId do not own your ownership"
        );
        uint256 bidId = bestBidIdOfAskId[_askId];
        if (bidId > 0) {
            _bidCancel(_askId, bidId);
        }

        // Transfer NFT to seller
        IERC721(asks[_askId].collection).safeTransferFrom(
            address(this),
            address(msg.sender),
            asks[_askId].tokenId
        );

        askIdsOfSeller[msg.sender].remove(_askId);
        askIdsOfCollection[asks[_askId].collection].remove(_askId);
        askIds.remove(_askId);
        delete asks[_askId];

        emit AskCancelListing(_askId);
        return _askId;
    }

    /**
     * @notice askSale
     * @param _askId: askId
     * @param _price: price buy (in BUSD)
     */
    function askSale(
        uint256 _askId,
        uint256 _price
    ) external whenNotPaused nonReentrant returns (uint256) {
        IERC20(busd).safeTransferFrom(
            address(msg.sender),
            address(this),
            _price
        );
        return _askSale(_askId, _price);
    }

    /**
     * @notice askSale
     * @param _askIds: listAskId
     * @param _prices: list price buy (in BUSD)
     */
    function askSales(
        uint256[] calldata _askIds,
        uint256[] calldata _prices
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory outputAskIds)
    {
        require(
            _askIds.length == _prices.length && _askIds.length > 0,
            "Invalid input "
        );

        uint256 totalPrice = 0;
        outputAskIds = new uint256[](_prices.length);
        for (uint256 index = 0; index < _prices.length; index++) {
            totalPrice += _prices[index];
        }
        IERC20(busd).safeTransferFrom(
            address(msg.sender),
            address(this),
            totalPrice
        );
        for (uint256 index = 0; index < _prices.length; index++) {
            outputAskIds[index] = _askSale(_askIds[index], _prices[index]);
        }
        return outputAskIds;
    }

    function _askSale(
        uint256 _askId,
        uint256 _price
    ) private verifyPrice(_price) verifyAsk(_askId) returns (uint256) {
        Ask memory askOrder = asks[_askId];
        // Front-running protection
        require(_price == askOrder.price, "Buy: Incorrect price");
        require(msg.sender != askOrder.seller, "Buy: Buyer cannot be seller");
        (
            uint256 netPrice,
            uint256 tradingFee,
            uint256 creatorFee
        ) = calculatePriceAndFeesForCollection(askOrder.collection, _price);

        askIdsOfSeller[askOrder.seller].remove(_askId);
        askIdsOfCollection[askOrder.collection].remove(_askId);
        askIds.remove(_askId);
        delete asks[_askId];

        IERC20(busd).safeTransfer(askOrder.seller, netPrice);

        if (tradingFee > 0) {
            pendingRevenueTradingFee += tradingFee;
        }
        if (creatorFee > 0) {
            pendingRevenueCreatorFeeOfCollection[
                askOrder.collection
            ] += creatorFee;
        }
        // Transfer NFT to buyer
        IERC721(askOrder.collection).safeTransferFrom(
            address(this),
            address(msg.sender),
            askOrder.tokenId
        );

        uint256 bidId = bestBidIdOfAskId[_askId];

        if (bidId > 0) {
            _bidCancel(_askId, bidId);
        }

        emit AskSale(
            _askId,
            askOrder.seller,
            address(msg.sender),
            _price,
            netPrice
        );
        return _askId;
    }

    /**
     * @notice bid
     * @param _askId: askId
     * @param _price: newPrice for listing (in BUSD)
     */
    function bid(
        uint256 _askId,
        uint256 _price
    )
        external
        whenNotPaused
        nonReentrant
        verifyPrice(_price)
        verifyAsk(_askId)
        returns (uint256)
    {
        uint256 oldBidId = bestBidIdOfAskId[_askId];
        if (oldBidId > 0) {
            Bid memory oldBid = bids[oldBidId];
            require(_price > oldBid.price, "Bid: New bid invalid price");
            if (oldBid.bidder == msg.sender) {
                IERC20(busd).safeTransferFrom(
                    address(msg.sender),
                    address(this),
                    _price - oldBid.price
                );
            } else {
                IERC20(busd).safeTransfer(oldBid.bidder, oldBid.price);
                IERC20(busd).safeTransferFrom(
                    address(msg.sender),
                    address(this),
                    _price
                );
            }
            delete bids[oldBidId];
            emit BidCanceled(_askId, oldBidId);
            uint256 newBidId = ++totalBids;
            bestBidIdOfAskId[_askId] = newBidId;
            bids[newBidId] = Bid({bidder: msg.sender, price: _price});

            emit BidCreated(_askId, newBidId, msg.sender);
            return newBidId;
        }
        // Deposit amount bidding
        IERC20(busd).safeTransferFrom(
            address(msg.sender),
            address(this),
            _price
        );

        uint256 bidId = ++totalBids;
        bestBidIdOfAskId[_askId] = bidId;
        bids[bidId] = Bid({bidder: msg.sender, price: _price});
        emit BidCreated(_askId, bidId, msg.sender);
        return bidId;
    }

    /**
     * @notice bidCancel
     * @param _askId: askId
     * @param _bidId: bidId
     */
    function bidCancel(
        uint256 _askId,
        uint256 _bidId
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(
            msg.sender == bids[_bidId].bidder,
            "Bid: Account must be bidder"
        );
        return _bidCancel(_askId, _bidId);
    }

    function _bidCancel(
        uint256 _askId,
        uint256 _bidId
    ) private returns (uint256) {
        IERC20(busd).safeTransfer(bids[_bidId].bidder, bids[_bidId].price);
        delete bestBidIdOfAskId[_askId];
        delete bids[_bidId];
        emit BidCanceled(_askId, _bidId);
        return _bidId;
    }

    /**
     * @notice acceptBid
     * @param _askId: askId
     * @param _price: price accept
     */
    function acceptBid(
        uint256 _askId,
        uint256 _price
    )
        external
        whenNotPaused
        nonReentrant
        verifyPrice(_price)
        verifyAsk(_askId)
        returns (uint256)
    {
        uint256 bidId = bestBidIdOfAskId[_askId];

        require(bidId > 0, "Bid: bidId invalid");
        Bid memory bestBid = bids[bidId];
        require(bestBid.price >= _price, "Under price accepted");
        Ask memory askOrder = asks[_askId];
        // Front-running protection
        require(msg.sender == askOrder.seller, "Buy: Your not owner ask");
        (
            uint256 netPrice,
            uint256 tradingFee,
            uint256 creatorFee
        ) = calculatePriceAndFeesForCollection(
                askOrder.collection,
                bestBid.price
            );

        IERC20(busd).safeTransfer(askOrder.seller, netPrice);

        if (tradingFee > 0) {
            pendingRevenueTradingFee += tradingFee;
        }
        if (creatorFee > 0) {
            pendingRevenueCreatorFeeOfCollection[
                askOrder.collection
            ] += creatorFee;
        }
        // Transfer NFT to bidder
        IERC721(askOrder.collection).safeTransferFrom(
            address(this),
            bestBid.bidder,
            askOrder.tokenId
        );

        askIdsOfSeller[askOrder.seller].remove(_askId);
        askIdsOfCollection[askOrder.collection].remove(_askId);
        askIds.remove(_askId);
        delete asks[_askId];

        delete bestBidIdOfAskId[_askId];
        delete bids[bidId];

        emit BidAccepted(
            _askId,
            bidId,
            askOrder.seller,
            bestBid.bidder,
            bestBid.price,
            _price
        );

        return bidId;
    }

    /**
     * @notice Claim pending revenue (treasury or creators)
     */
    function claimPendingTradingFee() external nonReentrant {
        require(pendingRevenueTradingFee > 0, "Claim: Nothing to claim");
        IERC20(busd).safeTransfer(treasury, pendingRevenueTradingFee);

        emit RevenueTradingFeeClaim(
            msg.sender,
            treasury,
            pendingRevenueTradingFee
        );
        pendingRevenueTradingFee = 0;
    }

    /**
     * @notice Claim pending revenue (treasury or creators)
     * @param _collection: collection address
     */
    function claimPendingCreatorFee(address _collection) external nonReentrant {
        uint256 amount = pendingRevenueCreatorFeeOfCollection[_collection];
        require(amount > 0, "Claim: Nothing to claim");
        IERC20(busd).safeTransfer(collections[_collection].creator, amount);
        emit RevenueCreatorFeeClaim(
            msg.sender,
            collections[_collection].creator,
            _collection,
            amount
        );
        pendingRevenueCreatorFeeOfCollection[_collection] = 0;
    }

    function viewAskIds(
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (uint256[] memory data, uint256 total) {
        total = askIds.length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }

        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new uint256[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new uint256[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = askIds.at(i);
        }
        return (data, total);
    }

    function viewAsks(
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (Ask[] memory data, uint256 total) {
        total = askIds.length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }

        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new Ask[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new Ask[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = asks[askIds.at(i)];
        }
        return (data, total);
    }

    function viewCollections(
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (Collection[] memory data, uint256 total) {
        total = collectionAddressSet.length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }
        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new Collection[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new Collection[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = collections[collectionAddressSet.at(i)];
        }
        return (data, total);
    }

    function viewAskIdsByCollection(
        address collection,
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (uint256[] memory data, uint256 total) {
        total = askIdsOfCollection[collection].length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }
        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new uint256[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new uint256[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = askIdsOfCollection[collection].at(i);
        }
        return (data, total);
    }

    function viewAsksByCollection(
        address collection,
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (Ask[] memory data, uint256 total) {
        total = askIdsOfCollection[collection].length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }
        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new Ask[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new Ask[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = asks[askIdsOfCollection[collection].at(i)];
        }
        return (data, total);
    }

    function viewAskIdsBySeller(
        address seller,
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (uint256[] memory data, uint256 total) {
        total = askIdsOfSeller[seller].length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }
        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new uint256[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new uint256[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = askIdsOfSeller[seller].at(i);
        }
        return (data, total);
    }

    function viewAsksBySeller(
        address seller,
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (Ask[] memory data, uint256 total) {
        total = askIdsOfSeller[seller].length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }
        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new Ask[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new Ask[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = asks[askIdsOfSeller[seller].at(i)];
        }
        return (data, total);
    }

    function viewBidIdsBySeller(
        address seller,
        uint256 pageIndex,
        uint256 pageSize
    ) external view returns (uint256[] memory data, uint256 total) {
        total = askIdsOfSeller[seller].length();
        if (pageIndex < 1) {
            pageIndex = 1;
        }
        uint256 startIndex = (pageIndex - 1) * pageSize;
        if (startIndex >= total) {
            return (new uint256[](0), total);
        }

        uint256 endIndex = pageIndex * pageSize > total
            ? total
            : pageIndex * pageSize;
        data = new uint256[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            data[i - startIndex] = bestBidIdOfAskId[
                askIdsOfSeller[seller].at(i)
            ];
        }
        return (data, total);
    }
}
