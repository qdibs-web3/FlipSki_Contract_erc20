// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 *
 * @title FlipSki on Base
 * @dev A contract by qdibs for a coin flip game on Base with Chainlink VRF V2.5 integrated.
 *  _____                                        _____ 
 *( ___ )                                      ( ___ )
 * |   |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|   | 
 * |   |  _____ _     ___ ____  ____  _  _____  |   | 
 * |   | |  ___| |   |_ _|  _ \/ ___|| |/ /_ _| |   | 
 * |   | | |_  | |    | || |_) \___ \| ' / | |  |   | 
 * |   | |  _| | |___ | ||  __/ ___) | . \ | |  |   | 
 * |   | |_|   |_____|___|_|   |____/|_|\_\___| |   | 
 * |___|~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|___| 
 *(_____)                                      (_____)
 *
*/

contract FlipSkiBaseVRF is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    IVRFCoordinatorV2Plus private immutable VRF_COORDINATOR;
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash; 
    uint32 private s_callbackGasLimit = 290000; 
    
    uint16 private constant REQUEST_CONFIRMATIONS = 3; 
    uint32 private constant NUM_WORDS = 1; 

    address private _owner;

    address payable public feeWallet;
    uint256 public feePercentage;
    uint256 public maxWager;
    uint256 public minWager;
    uint256 public constant EMERGENCY_TIMEOUT = 3600;
    uint256 public maxPendingGamesPerPlayer = 3;
    
    mapping(address => uint256) public pendingGamesPerPlayer;

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

    event OwnershipChanged(address indexed previousOwner, address indexed newOwner);
    event GameRequested(uint256 indexed gameId, address indexed player, CoinSide choice, uint256 wagerAmount, uint256 indexed vrfRequestId);
    event GameSettled(uint256 indexed gameId, address indexed player, CoinSide result, uint256 payoutAmount, uint256 feeAmount, uint256 indexed vrfRequestId, bool playerWon);
    event EmergencyRefund(uint256 indexed gameId, address indexed player, uint256 amount);
    event FeeWalletUpdated(address indexed newFeeWallet);
    event FeePercentageUpdated(uint256 newFeePercentage);
    event MaxWagerUpdated(uint256 newMaxWager);
    event MinWagerUpdated(uint256 newMinWager);
    event VRFParametersUpdated(uint256 newSubscriptionId, bytes32 newKeyHash, uint32 newCallbackGasLimit);
    event RandomWordReceived(uint256 indexed gameId, uint256 indexed vrfRequestId, uint256 randomWord); 
    event MaxPendingGamesUpdated(uint256 newMaxPendingGames);

    modifier onlyContractOwner() {
        require(msg.sender == _owner, "FlipSkiBaseVRF: caller is not the owner");
        _;
    }

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

        _owner = msg.sender;
        emit OwnershipChanged(address(0), msg.sender);

        feeWallet = _initialFeeWallet;
        feePercentage = _initialFeePercentage;
        maxWager = _initialMaxWager;
        minWager = _initialMinWager;

        VRF_COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
    }

    function contractOwner() public view returns (address) {
        return _owner;
    }

    function transferContractOwnership(address newOwner) public onlyContractOwner {
        require(newOwner != address(0), "FlipSkiBaseVRF: new owner is the zero address");
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipChanged(oldOwner, newOwner);
    }

    function flip(CoinSide _choice)
        external
        payable
        whenNotPaused
        nonReentrant
        validWager
    {
        require(pendingGamesPerPlayer[msg.sender] < maxPendingGamesPerPlayer, 
                "Too many pending games for this player");
                
        uint256 wagerAmount = msg.value;
        uint256 gameId = gameIdCounter++;

        Game storage newGame = games[gameId];
        newGame.player = msg.sender;
        newGame.choice = _choice;
        newGame.wagerAmount = wagerAmount;
        newGame.requested = true; 
        newGame.requestTimestamp = block.timestamp; 

        pendingGamesPerPlayer[msg.sender]++;

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

        gameToSettle.requested = false; 
        gameToSettle.result = (_randomWords[0] % 2 == 0) ? CoinSide.Heads : CoinSide.Tails;

        uint256 wagerAmount = gameToSettle.wagerAmount;
        bool playerWon = (gameToSettle.result == gameToSettle.choice);
        address player = gameToSettle.player;

        gameToSettle.settled = true;
        
        if (pendingGamesPerPlayer[player] > 0) {
            pendingGamesPerPlayer[player]--;
        }

        if (playerWon) { 
            uint256 fee = (wagerAmount * feePercentage) / 10000;
            gameToSettle.feeAmount = fee;
            
            uint256 grossPayout = wagerAmount * 2;
            uint256 playerReceives = grossPayout - fee;
            gameToSettle.payoutAmount = playerReceives;

            require(address(this).balance >= playerReceives + fee, "Contract has insufficient balance for win payout and fee");

            if (playerReceives > 0) {
                (bool success, ) = payable(player).call{value: playerReceives}("");
                require(success, "Player payout transfer failed");
            }
            
            if (fee > 0) {
                (bool feeSuccess, ) = feeWallet.call{value: fee}("");
                require(feeSuccess, "Fee transfer to feeWallet failed");
            }
        } else { 
            gameToSettle.payoutAmount = 0;
            gameToSettle.feeAmount = 0; 
        }

        emit GameSettled(gameId, player, gameToSettle.result, gameToSettle.payoutAmount, gameToSettle.feeAmount, _requestId, playerWon);
    }

    function emergencyRefund(uint256 _gameId) external onlyContractOwner nonReentrant {
        Game storage gameToRefund = games[_gameId];
        
        require(gameToRefund.requested, "Game not in requested state");
        require(!gameToRefund.settled, "Game already settled");
        require(block.timestamp >= gameToRefund.requestTimestamp + EMERGENCY_TIMEOUT, 
                "Emergency timeout period not elapsed");
        
        address player = gameToRefund.player;
        uint256 wagerAmount = gameToRefund.wagerAmount;
        
        gameToRefund.settled = true;
        gameToRefund.requested = false;
        
        if (pendingGamesPerPlayer[player] > 0) {
            pendingGamesPerPlayer[player]--;
        }
        
        (bool success, ) = payable(player).call{value: wagerAmount}("");
        require(success, "Emergency refund transfer failed");
        
        emit EmergencyRefund(_gameId, player, wagerAmount);
    }

    function isEligibleForEmergencyRefund(uint256 _gameId) external view returns (bool) {
        Game storage game = games[_gameId];
        return (
            game.requested && 
            !game.settled && 
            block.timestamp >= game.requestTimestamp + EMERGENCY_TIMEOUT
        );
    }

    function setMaxPendingGamesPerPlayer(uint256 _maxPendingGames) external onlyContractOwner {
        require(_maxPendingGames > 0, "Max pending games must be greater than 0");
        maxPendingGamesPerPlayer = _maxPendingGames;
        emit MaxPendingGamesUpdated(_maxPendingGames);
    }

    function setFeeWallet(address payable _newFeeWallet) external onlyContractOwner {
        require(_newFeeWallet != address(0), "New fee wallet cannot be zero address");
        feeWallet = _newFeeWallet;
        emit FeeWalletUpdated(_newFeeWallet);
    }

    function setFeePercentage(uint256 _newFeePercentage) external onlyContractOwner {
        require(_newFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points (100%)");
        feePercentage = _newFeePercentage;
        emit FeePercentageUpdated(_newFeePercentage);
    }

    function setMaxWager(uint256 _newMaxWager) external onlyContractOwner {
        require(_newMaxWager >= minWager, "Max wager must be greater than or equal to min wager");
        maxWager = _newMaxWager;
        emit MaxWagerUpdated(_newMaxWager);
    }

    function setMinWager(uint256 _newMinWager) external onlyContractOwner {
        require(_newMinWager > 0, "Min wager must be greater than 0");
        require(maxWager >= _newMinWager, "Max wager must be greater than or equal to new min wager");
        minWager = _newMinWager;
        emit MinWagerUpdated(_newMinWager);
    }

    function setVRFParameters(uint256 _newSubscriptionId, bytes32 _newKeyHash, uint32 _newCallbackGasLimit) external onlyContractOwner {
        require(_newSubscriptionId != 0, "Subscription ID cannot be zero");
        require(_newCallbackGasLimit > 0, "Callback gas limit must be greater than 0");
        s_subscriptionId = _newSubscriptionId;
        s_keyHash = _newKeyHash;
        s_callbackGasLimit = _newCallbackGasLimit;
        emit VRFParametersUpdated(s_subscriptionId, s_keyHash, s_callbackGasLimit);
    }

    function pause() external onlyContractOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyContractOwner whenPaused {
        _unpause();
    }

    function withdrawStuckTokens(address _tokenAddress, uint256 _amount) external onlyContractOwner {
        require(_tokenAddress != address(0), "Token address cannot be zero");
        IERC20Minimal token = IERC20Minimal(_tokenAddress);
        bool success = token.transfer(contractOwner(), _amount);
        require(success, "ERC20 token withdrawal failed");
    }

    function withdrawContractBalance() external onlyContractOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        (bool success, ) = payable(contractOwner()).call{value: balance}("");
        require(success, "Contract ETH balance withdrawal failed");
    }
    
    receive() external payable {}
    fallback() external payable {}
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}
