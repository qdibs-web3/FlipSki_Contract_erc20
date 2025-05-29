// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

contract FlipSkiBaseVRF is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    IVRFCoordinatorV2Plus private immutable VRF_COORDINATOR;
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash;
    uint32 private s_callbackGasLimit = 300000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    address payable public feeWallet;
    uint256 public feePercentage;
    uint256 public maxWager;
    uint256 public minWager;
    uint256 public vrfTimeout = 30 minutes;

    enum CoinSide { Heads, Tails }

    struct Game {
        address player;
        CoinSide choice;
        uint256 wagerAmount;
        uint256 feeAmount;
        uint256 payoutAmount;
        CoinSide result;
        bool requested;
        bool settled;
        uint256 vrfRequestId;
        uint256 requestTimestamp;
    }

    uint256 public gameIdCounter;
    mapping(uint256 => Game) public games;
    mapping(uint256 => uint256) public vrfRequestToGameId;

    event GameRequested(uint256 indexed gameId, address indexed player, CoinSide choice, uint256 wagerAmount, uint256 indexed vrfRequestId);
    event GameSettled(uint256 indexed gameId, address indexed player, CoinSide result, uint256 payoutAmount, uint256 feeAmount, uint256 indexed vrfRequestId, bool playerWon);
    event FeeWalletUpdated(address indexed newFeeWallet);
    event FeePercentageUpdated(uint256 newFeePercentage);
    event MaxWagerUpdated(uint256 newMaxWager);
    event MinWagerUpdated(uint256 newMinWager);
    event VRFParametersUpdated(uint256 newSubscriptionId, bytes32 newKeyHash, uint32 newCallbackGasLimit);
    event RandomWordReceived(uint256 indexed gameId, uint256 indexed vrfRequestId, uint256 randomWord);
    event EmergencyRefundIssued(uint256 indexed gameId, address indexed player, uint256 amount);

    modifier validWager() {
        require(msg.value >= minWager, "Wager is below minimum limit");
        require(msg.value <= maxWager, "Wager is above maximum limit");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == feeWallet, "Only fee wallet can perform this action");
        _;
    }

    constructor(
        address payable _initialFeeWallet,
        uint256 _initialFeePercentage,
        uint256 _initialMaxWager,
        uint256 _initialMinWager,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    )
        VRFConsumerBaseV2Plus(_vrfCoordinator)
    {
        require(_initialFeeWallet != address(0), "Fee wallet cannot be zero address");
        require(_initialFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points (100%)");
        require(_initialMinWager > 0, "Min wager must be greater than 0");
        require(_initialMaxWager >= _initialMinWager, "Max wager must be >= min wager");

        feeWallet = _initialFeeWallet;
        feePercentage = _initialFeePercentage;
        maxWager = _initialMaxWager;
        minWager = _initialMinWager;

        VRF_COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
    }

    function flip(CoinSide _choice)
        external
        payable
        whenNotPaused
        nonReentrant
        validWager
    {
        uint256 wagerAmount = msg.value;
        uint256 gameId = gameIdCounter++;

        Game storage newGame = games[gameId];
        newGame.player = msg.sender;
        newGame.choice = _choice;
        newGame.wagerAmount = wagerAmount;
        newGame.requested = true;
        newGame.requestTimestamp = block.timestamp;

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: s_keyHash,
            subId: s_subscriptionId,
            requestConfirmations: REQUEST_CONFIRMATIONS,
            callbackGasLimit: s_callbackGasLimit,
            numWords: NUM_WORDS,
            extraArgs: bytes("")
        });

        uint256 vrfRequestId = VRF_COORDINATOR.requestRandomWords(req);

        newGame.vrfRequestId = vrfRequestId;
        vrfRequestToGameId[vrfRequestId] = gameId;

        emit GameRequested(gameId, msg.sender, _choice, wagerAmount, vrfRequestId);
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        uint256 gameId = vrfRequestToGameId[_requestId];
        Game storage gameToSettle = games[gameId];

        emit RandomWordReceived(gameId, _requestId, _randomWords[0]);

        require(gameToSettle.requested, "Game not in requested state");
        require(!gameToSettle.settled, "Game already settled");

        gameToSettle.settled = true;
        gameToSettle.requested = false;
        gameToSettle.result = (_randomWords[0] % 2 == 0) ? CoinSide.Heads : CoinSide.Tails;

        uint256 wagerAmount = gameToSettle.wagerAmount;
        bool playerWon = (gameToSettle.result == gameToSettle.choice);

        if (playerWon) {
            uint256 fee = (wagerAmount * feePercentage) / 10000;
            gameToSettle.feeAmount = fee;

            uint256 grossPayout = wagerAmount * 2;
            uint256 playerReceives = grossPayout - fee;
            gameToSettle.payoutAmount = playerReceives;

            require(address(this).balance >= playerReceives + fee, "Insufficient balance");

            if (playerReceives > 0) {
                (bool success, ) = gameToSettle.player.call{value: playerReceives}("");
                require(success, "Player payout failed");
            }

            if (fee > 0) {
                (bool feeSuccess, ) = feeWallet.call{value: fee}("");
                require(feeSuccess, "Fee transfer failed");
            }
        } else {
            gameToSettle.payoutAmount = 0;
            gameToSettle.feeAmount = 0;
        }

        emit GameSettled(gameId, gameToSettle.player, gameToSettle.result, gameToSettle.payoutAmount, gameToSettle.feeAmount, _requestId, playerWon);
    }

    function emergencyRefund(uint256 _gameId) external nonReentrant {
        Game storage game = games[_gameId];
        require(game.requested, "Game not in a request state");
        require(!game.settled, "Game already settled");
        require(block.timestamp > game.requestTimestamp + vrfTimeout, "Timeout not reached");

        uint256 refundAmount = game.wagerAmount;
        game.settled = true;
        game.requested = false;

        (bool success, ) = game.player.call{value: refundAmount}("");
        require(success, "Refund failed");

        emit EmergencyRefundIssued(_gameId, game.player, refundAmount);
    }

    // --- Owner Functions ---

    function setFeeWallet(address payable _newFeeWallet) external onlyOwner {
        require(_newFeeWallet != address(0), "Invalid wallet");
        feeWallet = _newFeeWallet;
        emit FeeWalletUpdated(_newFeeWallet);
    }

    function setFeePercentage(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= 10000, "Too high");
        feePercentage = _newFeePercentage;
        emit FeePercentageUpdated(_newFeePercentage);
    }

    function setMaxWager(uint256 _newMaxWager) external onlyOwner {
        require(_newMaxWager >= minWager, "Below min wager");
        maxWager = _newMaxWager;
        emit MaxWagerUpdated(_newMaxWager);
    }

    function setMinWager(uint256 _newMinWager) external onlyOwner {
        require(_newMinWager > 0 && _newMinWager <= maxWager, "Invalid min wager");
        minWager = _newMinWager;
        emit MinWagerUpdated(_newMinWager);
    }

    function setVRFParameters(uint256 _newSubId, bytes32 _newKeyHash, uint32 _newCallbackGasLimit) external onlyOwner {
        require(_newSubId != 0, "Invalid subId");
        require(_newKeyHash != bytes32(0), "Invalid keyHash");
        require(_newCallbackGasLimit > 0, "Gas limit required");

        s_subscriptionId = _newSubId;
        s_keyHash = _newKeyHash;
        s_callbackGasLimit = _newCallbackGasLimit;

        emit VRFParametersUpdated(_newSubId, _newKeyHash, _newCallbackGasLimit);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw() external onlyOwner {
        require(address(this).balance > 0, "Nothing to withdraw");
        (bool success, ) = feeWallet.call{value: address(this).balance}("");
        require(success, "Withdraw failed");
    }

    receive() external payable {}
}
