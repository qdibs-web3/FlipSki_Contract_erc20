// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * @title FlipSkiBaseVRF
 * @dev A coin flip game contract integrated with Chainlink VRF V2.5.
 */
contract FlipSkiBaseVRF is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    // Emergency State Management
    enum EmergencyState { Normal, Paused, EmergencyWithdrawalOnly }
    EmergencyState public emergencyState;

    // VRF Variables
    IVRFCoordinatorV2Plus private immutable VRF_COORDINATOR;
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash; // Gas lane for Base Sepolia (e.g., 30 gwei key hash)
    uint32 private s_callbackGasLimit = 300000; // Default callback gas limit, configurable by owner
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // Minimum number of confirmations for VRF request
    uint32 private constant NUM_WORDS = 1; // Requesting one random word for heads/tails

    // Game Variables
    address payable public feeWallet;
    address private _owner;
    uint256 public feePercentage; // Basis points, e.g., 1000 for 10%
    uint256 public maxWager;
    uint256 public minWager;
    uint256 public maxPendingGames = 100; // Maximum number of pending games allowed
    uint256 public currentPendingGames; // Current number of pending games

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
    mapping(address => uint256) public pendingPayouts; // For failed transfers

    // Events
    event GameRequested(uint256 indexed gameId, address indexed player, CoinSide choice, uint256 wagerAmount, uint256 indexed vrfRequestId);
    event GameSettled(uint256 indexed gameId, address indexed player, CoinSide result, uint256 payoutAmount, uint256 feeAmount, uint256 indexed vrfRequestId, bool playerWon);
    event FeeWalletUpdated(address indexed newFeeWallet);
    event FeePercentageUpdated(uint256 newFeePercentage);
    event MaxWagerUpdated(uint256 newMaxWager);
    event MinWagerUpdated(uint256 newMinWager);
    event VRFParametersUpdated(uint256 newSubscriptionId, bytes32 newKeyHash, uint32 newCallbackGasLimit);
    event RandomWordReceived(uint256 indexed gameId, uint256 indexed vrfRequestId, uint256 randomWord);
    event EmergencyStateChanged(EmergencyState newState);
    event EmergencyWithdrawal(uint256 indexed gameId, address indexed player, uint256 amount);
    event PayoutFailed(uint256 indexed gameId, address indexed player, uint256 amount);
    event PendingPayoutClaimed(address indexed player, uint256 amount);
    event MaxPendingGamesUpdated(uint256 newMaxPendingGames);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier validWager() {
        require(msg.value >= minWager, "Wager is below minimum limit");
        require(msg.value <= maxWager, "Wager is above maximum limit");
        _;
    }

    modifier onlyInState(EmergencyState _state) {
        require(emergencyState == _state, "Function cannot be called in current state");
        _;
    }

    modifier onlyOwner() {
        require(owner() == msg.sender, "Caller is not the owner");
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

        _owner = msg.sender;
        feeWallet = _initialFeeWallet;
        feePercentage = _initialFeePercentage;
        maxWager = _initialMaxWager;
        minWager = _initialMinWager;

        VRF_COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
        
        emergencyState = EmergencyState.Normal;
        
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function flip(CoinSide _choice)
        external
        payable
        nonReentrant
        validWager
        onlyInState(EmergencyState.Normal)
    {
        require(currentPendingGames < maxPendingGames, "Too many pending games, try again later");
        
        uint256 wagerAmount = msg.value;
        
        // Check if contract can cover potential payout
        uint256 potentialPayout = (wagerAmount * 2) - ((wagerAmount * 2 * feePercentage) / 10000);
        require(address(this).balance >= potentialPayout, "Contract has insufficient balance for potential payout");
        
        uint256 gameId = gameIdCounter++;
        currentPendingGames++;

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
        emit RandomWordReceived(gameId, _requestId, _randomWords[0]);

        require(gameToSettle.requested, "Game not in requested state");
        require(!gameToSettle.settled, "Game already settled");

        gameToSettle.requested = false; 
        currentPendingGames--;

        gameToSettle.result = (_randomWords[0] % 2 == 0) ? CoinSide.Heads : CoinSide.Tails;

        uint256 wagerAmount = gameToSettle.wagerAmount;
        uint256 fee = (wagerAmount * feePercentage) / 10000;
        gameToSettle.feeAmount = fee;

        bool playerWon = (gameToSettle.result == gameToSettle.choice);
        uint256 playerReceives = 0;

        if (playerWon) { 
            uint256 grossPayout = wagerAmount * 2;
            playerReceives = grossPayout - fee;
            gameToSettle.payoutAmount = playerReceives;

            require(address(this).balance >= playerReceives + fee, "Contract has insufficient balance for win payout and fee");

            if (playerReceives > 0) {
                bool success = safeTransferETH(payable(gameToSettle.player), playerReceives);
                if (!success) {
                    // Handle failed transfer
                    pendingPayouts[gameToSettle.player] += playerReceives;
                    emit PayoutFailed(gameId, gameToSettle.player, playerReceives);
                }
            }
        } else { 
            gameToSettle.payoutAmount = 0; 
            require(address(this).balance >= fee, "Contract has insufficient balance for fee transfer on loss");
        }

        if (fee > 0) {
            bool feeSuccess = safeTransferETH(feeWallet, fee);
            if (!feeSuccess) {
                // If fee transfer fails, add to contract owner's pending payouts
                pendingPayouts[owner()] += fee;
                emit PayoutFailed(gameId, owner(), fee);
            }
        }

        gameToSettle.settled = true;

        emit GameSettled(gameId, gameToSettle.player, gameToSettle.result, gameToSettle.payoutAmount, fee, _requestId, playerWon);
    }

    // Safe transfer helper function
    function safeTransferETH(address payable _to, uint256 _amount) internal returns (bool) {
        (bool success, ) = _to.call{value: _amount}("");
        return success;
    }

    // Emergency withdrawal function
    function emergencyWithdraw(uint256 _gameId) 
        external 
        nonReentrant 
        onlyInState(EmergencyState.EmergencyWithdrawalOnly) 
    {
        Game storage game = games[_gameId];
        require(game.player == msg.sender, "Not game owner");
        require(game.requested && !game.settled, "Game not in valid state for emergency withdrawal");
        
        game.requested = false;
        game.settled = true;
        
        if (currentPendingGames > 0) {
            currentPendingGames--;
        }
        
        uint256 wagerAmount = game.wagerAmount;
        bool success = safeTransferETH(payable(msg.sender), wagerAmount);
        require(success, "Emergency withdrawal failed");
        
        emit EmergencyWithdrawal(_gameId, msg.sender, wagerAmount);
    }

    // Claim pending payouts
    function claimPendingPayout() 
        external 
        nonReentrant 
    {
        uint256 amount = pendingPayouts[msg.sender];
        require(amount > 0, "No pending payouts");
        
        pendingPayouts[msg.sender] = 0;
        
        bool success = safeTransferETH(payable(msg.sender), amount);
        require(success, "Payout transfer failed");
        
        emit PendingPayoutClaimed(msg.sender, amount);
    }

    // --- Owner Administrative Functions ---
    function setEmergencyState(EmergencyState _newState) 
        external 
        onlyOwner 
    {
        emergencyState = _newState;
        
        // If setting to Paused, also call the pause function
        if (_newState == EmergencyState.Paused) {
            _pause();
        } else if (_newState == EmergencyState.Normal) {
            _unpause();
        }
        
        emit EmergencyStateChanged(_newState);
    }

    function setMaxPendingGames(uint256 _newMaxPendingGames) 
        external 
        onlyOwner 
    {
        require(_newMaxPendingGames > 0, "Max pending games must be greater than 0");
        maxPendingGames = _newMaxPendingGames;
        emit MaxPendingGamesUpdated(_newMaxPendingGames);
    }

    function setFeeWallet(address payable _newFeeWallet) 
        external 
        onlyOwner 
    {
        require(_newFeeWallet != address(0), "New fee wallet cannot be zero address");
        feeWallet = _newFeeWallet;
        emit FeeWalletUpdated(_newFeeWallet);
    }

    function setFeePercentage(uint256 _newFeePercentage) 
        external 
        onlyOwner 
    {
        require(_newFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points (100%)");
        feePercentage = _newFeePercentage;
        emit FeePercentageUpdated(_newFeePercentage);
    }

    function setMaxWager(uint256 _newMaxWager) 
        external 
        onlyOwner 
    {
        require(_newMaxWager >= minWager, "Max wager must be greater than or equal to min wager");
        maxWager = _newMaxWager;
        emit MaxWagerUpdated(_newMaxWager);
    }

    function setMinWager(uint256 _newMinWager) 
        external 
        onlyOwner 
    {
        require(_newMinWager > 0, "Min wager must be greater than 0");
        require(maxWager >= _newMinWager, "Max wager must be greater than or equal to new min wager");
        minWager = _newMinWager;
        emit MinWagerUpdated(_newMinWager);
    }

    function setVRFParameters(uint256 _newSubscriptionId, bytes32 _newKeyHash, uint32 _newCallbackGasLimit) 
        external 
        onlyOwner 
    {
        require(_newSubscriptionId != 0, "Subscription ID cannot be zero");
        require(_newCallbackGasLimit >= 200000, "Callback gas limit too low");
        require(_newCallbackGasLimit <= 2000000, "Callback gas limit too high");
        
        s_subscriptionId = _newSubscriptionId;
        s_keyHash = _newKeyHash;
        s_callbackGasLimit = _newCallbackGasLimit;
        emit VRFParametersUpdated(s_subscriptionId, s_keyHash, s_callbackGasLimit);
    }

    function pause() 
        external 
        onlyOwner 
        whenNotPaused 
    {
        _pause();
        if (emergencyState != EmergencyState.Paused) {
            emergencyState = EmergencyState.Paused;
            emit EmergencyStateChanged(EmergencyState.Paused);
        }
    }

    function unpause() 
        external 
        onlyOwner 
        whenPaused 
    {
        _unpause();
        if (emergencyState != EmergencyState.Normal) {
            emergencyState = EmergencyState.Normal;
            emit EmergencyStateChanged(EmergencyState.Normal);
        }
    }

    function withdrawStuckTokens(address _tokenAddress, uint256 _amount) 
        external 
        onlyOwner 
        nonReentrant 
    {
        require(_tokenAddress != address(0), "Token address cannot be zero");
        IERC20Minimal token = IERC20Minimal(_tokenAddress);
        bool success = token.transfer(owner(), _amount);
        require(success, "ERC20 token withdrawal failed");
    }

    function withdrawContractBalance() 
        external 
        onlyOwner 
        nonReentrant 
    {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        bool success = safeTransferETH(payable(owner()), balance);
        require(success, "Contract ETH balance withdrawal failed");
    }
    
    receive() external payable {}
    fallback() external payable {}
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}
