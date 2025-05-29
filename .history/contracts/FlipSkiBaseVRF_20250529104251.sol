// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

contract FlipSkiBaseVRF is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    // VRF Variables
    IVRFCoordinatorV2Plus private immutable VRF_COORDINATOR;
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash; // Gas lane for Base Sepolia (e.g., 30 gwei key hash)
    uint32 private s_callbackGasLimit = 300000; // Default callback gas limit, configurable by owner
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // Minimum number of confirmations for VRF request
    uint32 private constant NUM_WORDS = 1; // Requesting one random word for heads/tails

    // Game Variables
    address payable public feeWallet;
    uint256 public feePercentage; // Basis points, e.g., 1000 for 10%
    uint256 public maxWager;
    uint256 public minWager;

    enum CoinSide { Heads, Tails }

    struct Game {
        address player;
        CoinSide choice;
        uint256 wagerAmount;
        uint256 feeAmount; // Calculated at settlement
        uint256 payoutAmount; // Calculated at settlement
        CoinSide result; // Set by VRF in fulfillRandomWords
        bool requested; // True when VRF request is made, false after fulfillment starts
        bool settled;   // True when VRF callback is processed and game is fully settled
        uint256 vrfRequestId; // To link VRF request to the game
    }

    uint256 public gameIdCounter;
    mapping(uint256 => Game) public games; // gameId => Game details
    mapping(uint256 => uint256) public vrfRequestToGameId; // vrfRequestId => gameId

    // Events
    event GameRequested(uint256 indexed gameId, address indexed player, CoinSide choice, uint256 wagerAmount, uint256 indexed vrfRequestId);
    event GameSettled(uint256 indexed gameId, address indexed player, CoinSide result, uint256 payoutAmount, uint256 feeAmount, uint256 indexed vrfRequestId, bool playerWon);
    event FeeWalletUpdated(address indexed newFeeWallet);
    event FeePercentageUpdated(uint256 newFeePercentage);
    event MaxWagerUpdated(uint256 newMaxWager);
    event MinWagerUpdated(uint256 newMinWager);
    event VRFParametersUpdated(uint256 newSubscriptionId, bytes32 newKeyHash, uint32 newCallbackGasLimit);
    event RandomWordReceived(uint256 indexed gameId, uint256 indexed vrfRequestId, uint256 randomWord); // <-- NEW DEBUG EVENT

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
        require(_initialFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points (100%)");
        require(_initialMinWager > 0, "Min wager must be greater than 0");
        require(_initialMaxWager >= _initialMinWager, "Max wager must be greater than or equal to min wager");
        require(_vrfCoordinator != address(0), "VRF Coordinator address cannot be zero");
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

        // Emit the raw random word for debugging
        emit RandomWordReceived(gameId, _requestId, _randomWords[0]); // <-- EMIT NEW DEBUG EVENT

        require(gameToSettle.requested, "Game not in requested state");
        require(!gameToSettle.settled, "Game already settled");

        gameToSettle.requested = false; 

        gameToSettle.result = (_randomWords[0] % 2 == 0) ? CoinSide.Heads : CoinSide.Tails;

        uint256 wagerAmount = gameToSettle.wagerAmount;
        bool playerWon = (gameToSettle.result == gameToSettle.choice);

        if (playerWon) { 
            // Only take fees on wins
            uint256 fee = (wagerAmount * feePercentage) / 10000;
            gameToSettle.feeAmount = fee;
            
            uint256 grossPayout = wagerAmount * 2;
            uint256 playerReceives = grossPayout - fee;
            gameToSettle.payoutAmount = playerReceives;

            require(address(this).balance >= playerReceives + fee, "Contract has insufficient balance for win payout and fee");

            if (playerReceives > 0) {
                (bool success, ) = gameToSettle.player.call{value: playerReceives}("");
                require(success, "Player payout transfer failed");
            }
            
            // Only send fee to fee wallet when player wins
            if (fee > 0) {
                (bool feeSuccess, ) = feeWallet.call{value: fee}("");
                require(feeSuccess, "Fee transfer to feeWallet failed");
            }
        } else { 
            // Player lost - NO FEES taken
            gameToSettle.payoutAmount = 0;
            gameToSettle.feeAmount = 0; 
            // No transfers on loss - wager stays in contract
        }

        gameToSettle.settled = true;

        emit GameSettled(gameId, gameToSettle.player, gameToSettle.result, gameToSettle.payoutAmount, gameToSettle.feeAmount, _requestId, playerWon);
    }

    // --- Owner Administrative Functions ---
    function setFeeWallet(address payable _newFeeWallet) external onlyOwner {
        require(_newFeeWallet != address(0), "New fee wallet cannot be zero address");
        feeWallet = _newFeeWallet;
        emit FeeWalletUpdated(_newFeeWallet);
    }

    function setFeePercentage(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points (100%)");
        feePercentage = _newFeePercentage;
        emit FeePercentageUpdated(_newFeePercentage);
    }

    function setMaxWager(uint256 _newMaxWager) external onlyOwner {
        require(_newMaxWager >= minWager, "Max wager must be greater than or equal to min wager");
        maxWager = _newMaxWager;
        emit MaxWagerUpdated(_newMaxWager);
    }

    function setMinWager(uint256 _newMinWager) external onlyOwner {
        require(_newMinWager > 0, "Min wager must be greater than 0");
        require(maxWager >= _newMinWager, "Max wager must be greater than or equal to new min wager");
        minWager = _newMinWager;
        emit MinWagerUpdated(_newMinWager);
    }

    function setVRFParameters(uint256 _newSubscriptionId, bytes32 _newKeyHash, uint32 _newCallbackGasLimit) external onlyOwner {
        require(_newSubscriptionId != 0, "Subscription ID cannot be zero");
        require(_newCallbackGasLimit > 0, "Callback gas limit must be greater than 0");
        s_subscriptionId = _newSubscriptionId;
        s_keyHash = _newKeyHash;
        s_callbackGasLimit = _newCallbackGasLimit;
        emit VRFParametersUpdated(s_subscriptionId, s_keyHash, s_callbackGasLimit);
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    function withdrawStuckTokens(address _tokenAddress, uint256 _amount) external onlyOwner {
        require(_tokenAddress != address(0), "Token address cannot be zero");
        IERC20Minimal token = IERC20Minimal(_tokenAddress);
        bool success = token.transfer(owner(), _amount);
        require(success, "ERC20 token withdrawal failed");
    }

    function withdrawContractBalance() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "Contract ETH balance withdrawal failed");
    }
    
    receive() external payable {}
    fallback() external payable {}
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}
