// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * @title FlipSki on Base
 * @dev A contract for a Base ETH coin flip game with Chainlink VRF V2.5 integrated.
 *  _____                                                        _____ 
 * ( ___ )                                                      ( ___ )
 *  |   |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|   | 
 *  |   |   ___   ____  ___  ____  ____     _____  _____  _   _  |   | 
 *  |   |  / _ \ |  _ \|_ _|| __ )/ ___|   | ____||_   _|| | | | |   | 
 *  |   | | | | || | | || | |  _ \\___ \   |  _|    | |  | |_| | |   | 
 *  |   | | |_| || |_| || | | |_) |___) |_ | |___   | |  |  _  | |   | 
 *  |   |  \__\_\|____/|___||____/|____/(_)|_____|  |_|  |_| |_| |   | 
 *  |___|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|___| 
 * (_____)                                                      (_____)
 */
contract FlipSkiBaseVRF is Ownable, Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    IVRFCoordinatorV2Plus private immutable VRF_COORDINATOR;
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash;
    uint32 private s_callbackGasLimit = 300000; // ✅ Monitor this for underestimation risk
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private constant REFUND_TIMEOUT = 1 hours; // ⏱ Timeout period for refunds

    address payable public feeWallet;
    uint256 public feePercentage;
    uint256 public maxWager;
    uint256 public minWager;

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
        uint256 requestTimestamp; // ⏱ New: used for refund timeout
    }

    uint256 public gameIdCounter;
    mapping(uint256 => Game) public games;
    mapping(uint256 => uint256) public vrfRequestToGameId;

    event GameRequested(uint256 indexed gameId, address indexed player, CoinSide choice, uint256 wagerAmount, uint256 indexed vrfRequestId);
    event GameSettled(uint256 indexed gameId, address indexed player, CoinSide result, uint256 payoutAmount, uint256 feeAmount, uint256 indexed vrfRequestId, bool playerWon);
    event GameRefunded(uint256 indexed gameId, address indexed player, uint256 wagerAmount);
    event FeeWalletUpdated(address indexed newFeeWallet);
    event FeePercentageUpdated(uint256 newFeePercentage);
    event MaxWagerUpdated(uint256 newMaxWager);
    event MinWagerUpdated(uint256 newMinWager);
    event VRFParametersUpdated(uint256 newSubscriptionId, bytes32 newKeyHash, uint32 newCallbackGasLimit);
    event RandomWordReceived(uint256 indexed gameId, uint256 indexed vrfRequestId, uint256 randomWord);

    modifier validWager() {
        require(msg.value >= minWager, "Wager is below minimum limit");
        require(msg.value <= maxWager, "Wager is above maximum limit");
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
        require(_initialFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points");
        require(_initialMinWager > 0, "Min wager must be > 0");
        require(_initialMaxWager >= _initialMinWager, "Max wager must >= min wager");
        require(_vrfCoordinator != address(0), "VRF Coordinator cannot be zero");
        require(_subscriptionId != 0, "Subscription ID cannot be zero");

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

        require(gameToSettle.requested, "Game not requested");
        require(!gameToSettle.settled, "Game already settled");

        // ✅ Prevent reentry: settle first
        gameToSettle.settled = true;
        gameToSettle.requested = false;
        gameToSettle.result = (_randomWords[0] % 2 == 0) ? CoinSide.Heads : CoinSide.Tails;

        uint256 wagerAmount = gameToSettle.wagerAmount;
        bool playerWon = (gameToSettle.result == gameToSettle.choice);

        if (playerWon) {
            uint256 fee = (wagerAmount * feePercentage) / 10000;
            uint256 grossPayout = wagerAmount * 2;
            uint256 playerReceives = grossPayout - fee;
            gameToSettle.feeAmount = fee;
            gameToSettle.payoutAmount = playerReceives;

            require(address(this).balance >= playerReceives + fee, "Insufficient contract balance");

            if (playerReceives > 0) {
                (bool success, ) = gameToSettle.player.call{value: playerReceives}("");
                require(success, "Player payout failed");
            }

            if (fee > 0) {
                (bool feeSuccess, ) = feeWallet.call{value: fee}("");
                require(feeSuccess, "Fee transfer failed");
            }
        }

        emit GameSettled(gameId, gameToSettle.player, gameToSettle.result, gameToSettle.payoutAmount, gameToSettle.feeAmount, _requestId, playerWon);
    }

    /// @notice Emergency refund in case Chainlink fails to respond
    function refundGame(uint256 gameId) external nonReentrant {
        Game storage game = games[gameId];
        require(game.player == msg.sender, "Only player can refund");
        require(game.requested, "Game not pending");
        require(!game.settled, "Game already settled");
        require(block.timestamp >= game.requestTimestamp + REFUND_TIMEOUT, "Refund timeout not reached");

        game.requested = false;
        game.settled = true;

        uint256 refundAmount = game.wagerAmount;
        (bool success, ) = game.player.call{value: refundAmount}("");
        require(success, "Refund transfer failed");

        emit GameRefunded(gameId, game.player, refundAmount);
    }

    // --- Owner Functions ---
    function setFeeWallet(address payable _newFeeWallet) external onlyOwner {
        require(_newFeeWallet != address(0), "Fee wallet cannot be zero");
        feeWallet = _newFeeWallet;
        emit FeeWalletUpdated(_newFeeWallet);
    }

    function setFeePercentage(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= 10000, "Fee percentage too high");
        feePercentage = _newFeePercentage;
        emit FeePercentageUpdated(_newFeePercentage);
    }

    function setMaxWager(uint256 _newMaxWager) external onlyOwner {
        require(_newMaxWager >= minWager, "Max wager < min wager");
        maxWager = _newMaxWager;
        emit MaxWagerUpdated(_newMaxWager);
    }

    function setMinWager(uint256 _newMinWager) external onlyOwner {
        require(_newMinWager > 0, "Min wager must > 0");
        require(maxWager >= _newMinWager, "Min wager > max wager");
        minWager = _newMinWager;
        emit MinWagerUpdated(_newMinWager);
    }

    function setVRFParameters(uint256 _newSubscriptionId, bytes32 _newKeyHash, uint32 _newCallbackGasLimit) external onlyOwner {
        require(_newSubscriptionId != 0, "Subscription ID cannot be zero");
        s_subscriptionId = _newSubscriptionId;
        s_keyHash = _newKeyHash;
        s_callbackGasLimit = _newCallbackGasLimit;
        emit VRFParametersUpdated(_newSubscriptionId, _newKeyHash, _newCallbackGasLimit);
    }
}
