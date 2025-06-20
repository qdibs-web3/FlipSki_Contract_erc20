// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 *
 * @title FlipSki on Base (ERC20)
 * @dev A contract by qdibs for a coin flip game on Base with Chainlink VRF V2.5 integrated using ERC20 tokens.
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

contract FlipSkiBaseVRFerc20 is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    IVRFCoordinatorV2Plus private immutable VRF_COORDINATOR;
    uint256 private s_subscriptionId;
    bytes32 private s_keyHash; 
    uint32 private s_callbackGasLimit = 290000; 
    
    uint16 private constant REQUEST_CONFIRMATIONS = 3; 
    uint32 private constant NUM_WORDS = 1; 

    address private _owner;

    // ERC20 token configuration
    IERC20 public immutable wagerToken;
    address public immutable tokenAddress;

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
        require(msg.sender == _owner, "FlipSkiBaseVRFerc20: caller is not the owner");
        _;
    }

    modifier validWager(uint256 _wagerAmount) {
        require(_wagerAmount >= minWager, "Wager is below minimum limit");
        require(_wagerAmount <= maxWager, "Wager is above maximum limit");
        _;
    }

    constructor(
        address _tokenAddress,
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
        require(_tokenAddress != address(0), "Token address cannot be zero address");
        require(_initialFeeWallet != address(0), "Fee wallet cannot be zero address");
        require(_initialFeePercentage <= 10000, "Fee percentage cannot exceed 10000 basis points (100%)");
        require(_initialMinWager > 0, "Min wager must be greater than 0");
        require(_initialMaxWager >= _initialMinWager, "Max wager must be greater than or equal to min wager");
        require(_vrfCoordinator != address(0), "VRF Coordinator address cannot be zero");
        require(_subscriptionId != 0, "Subscription ID cannot be zero");

        _owner = msg.sender;
        emit OwnershipChanged(address(0), msg.sender);

        tokenAddress = _tokenAddress;
        wagerToken = IERC20(_tokenAddress);
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
        require(newOwner != address(0), "FlipSkiBaseVRFerc20: new owner is the zero address");
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipChanged(oldOwner, newOwner);
    }

    function flip(CoinSide _choice, uint256 _wagerAmount)
        external
        whenNotPaused
        nonReentrant
        validWager(_wagerAmount)
    {
        require(pendingGamesPerPlayer[msg.sender] < maxPendingGamesPerPlayer, 
                "Too many pending games for this player");
        
        // Check allowance and balance
        require(wagerToken.allowance(msg.sender, address(this)) >= _wagerAmount, 
                "Insufficient token allowance");
        require(wagerToken.balanceOf(msg.sender) >= _wagerAmount, 
                "Insufficient token balance");
                
        uint256 gameId = gameIdCounter++;

        Game storage newGame = games[gameId];
        newGame.player = msg.sender;
        newGame.choice = _choice;
        newGame.wagerAmount = _wagerAmount;
        newGame.requested = true; 
        newGame.requestTimestamp = block.timestamp; 

        pendingGamesPerPlayer[msg.sender]++;

        // Transfer tokens from player to contract
        require(wagerToken.transferFrom(msg.sender, address(this), _wagerAmount), 
                "Token transfer failed");

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

        emit GameRequested(gameId, msg.sender, _choice, _wagerAmount, vrfRequestId);
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

            require(wagerToken.balanceOf(address(this)) >= playerReceives + fee, 
                    "Contract has insufficient token balance for win payout and fee");

            if (playerReceives > 0) {
                require(wagerToken.transfer(player, playerReceives), 
                        "Player payout transfer failed");
            }
            
            if (fee > 0) {
                require(wagerToken.transfer(feeWallet, fee), 
                        "Fee transfer to feeWallet failed");
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
        
        require(wagerToken.transfer(player, wagerAmount), 
                "Emergency refund transfer failed");
        
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
        IERC20 token = IERC20(_tokenAddress);
        require(token.transfer(contractOwner(), _amount), "Token withdrawal failed");
    }

    function withdrawContractTokenBalance() external onlyContractOwner nonReentrant {
        uint256 balance = wagerToken.balanceOf(address(this));
        require(balance > 0, "No token balance to withdraw");
        require(wagerToken.transfer(contractOwner(), balance), 
                "Contract token balance withdrawal failed");
    }

    // Function to get token information
    function getTokenInfo() external view returns (address, string memory, string memory, uint8) {
        try IERC20Extended(tokenAddress).name() returns (string memory name) {
            try IERC20Extended(tokenAddress).symbol() returns (string memory symbol) {
                try IERC20Extended(tokenAddress).decimals() returns (uint8 decimals) {
                    return (tokenAddress, name, symbol, decimals);
                } catch {
                    return (tokenAddress, name, symbol, 18);
                }
            } catch {
                return (tokenAddress, name, "UNKNOWN", 18);
            }
        } catch {
            return (tokenAddress, "UNKNOWN", "UNKNOWN", 18);
        }
    }
    
    // Emergency ETH withdrawal (in case ETH is accidentally sent)
    function withdrawETH() external onlyContractOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH balance to withdraw");
        (bool success, ) = payable(contractOwner()).call{value: balance}("");
        require(success, "ETH withdrawal failed");
    }
    
    receive() external payable {}
    fallback() external payable {}
}

interface IERC20Extended {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

