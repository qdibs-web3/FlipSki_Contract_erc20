const { ethers } = require("hardhat");

async function main() {
  const accounts = await ethers.getSigners();

  if (!accounts || accounts.length === 0) {
    console.error("Error: No deployer account found. Please ensure that your PRIVATE_KEY in the .env file is correctly set, is not the placeholder value, and the account has sufficient funds on the selected network (Base Mainnet).");
    process.exit(1);
  }
  const [deployer] = accounts;

  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // FlipSki Token Configuration
  const flipSkiTokenAddress = "0xE4b2F8B5B9497222093e2B1Afb98CE2728D3bB07"; // FlipSki token contract address

  // User-provided parameters
  const initialFeeWallet = "0x69Edc00a807042895Fe09595Ee27992B3aF8BB20"; // User provided
  const initialFeePercentage = 1000; // 1000 basis points = 10%
  
  // Wager limits in FlipSki tokens (adjust based on token decimals)
  // Assuming FlipSki has 18 decimals like most ERC20 tokens
  const initialMaxWagerInTokens = "100000000"; // 100 mil FlipSki tokens
  const initialMinWagerInTokens = "1000000";   // 1 mil FlipSki tokens

  // Chainlink VRF v2.5 Parameters for Base Mainnet
  const vrfCoordinatorAddress = "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634"; // VRF Coordinator V2.5 for Base Mainnet
  const subscriptionId = process.env.VRF_SUBSCRIPTION_ID || "YOUR_VRF_SUBSCRIPTION_ID"; // Get from environment
  const keyHash = "0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70"; // Key Hash for Base (30 gwei)

  if (subscriptionId === "YOUR_VRF_SUBSCRIPTION_ID" || !subscriptionId) {
    console.error("Error: Please set VRF_SUBSCRIPTION_ID in your .env file with your actual Chainlink VRF Subscription ID.");
    process.exit(1);
  }

  // Convert token amounts to wei (assuming 18 decimals)
  const initialMaxWager = ethers.parseUnits(initialMaxWagerInTokens, 18);
  const initialMinWager = ethers.parseUnits(initialMinWagerInTokens, 18);

  console.log(`
    Deploying FlipSkiBaseVRFerc20 with parameters:
    FlipSki Token Address: ${flipSkiTokenAddress}
    Initial Fee Wallet: ${initialFeeWallet}
    Initial Fee Percentage: ${initialFeePercentage} (10%)
    Initial Max Wager: ${initialMaxWagerInTokens} FlipSki (${initialMaxWager.toString()} Wei)
    Initial Min Wager: ${initialMinWagerInTokens} FlipSki (${initialMinWager.toString()} Wei)
    VRF Coordinator: ${vrfCoordinatorAddress}
    Subscription ID: ${subscriptionId}
    Key Hash: ${keyHash}
  `);

  const CoinFlipContract = await ethers.getContractFactory("FlipSkiBaseVRFerc20");
  const coinFlipContract = await CoinFlipContract.deploy(
    flipSkiTokenAddress,
    initialFeeWallet,
    initialFeePercentage,
    initialMaxWager,
    initialMinWager,
    vrfCoordinatorAddress,
    subscriptionId,
    keyHash
  );

  await coinFlipContract.waitForDeployment();

  const contractAddress = await coinFlipContract.getAddress();
  console.log("FlipSkiBaseVRFerc20 contract deployed to:", contractAddress);

  // Save deployment info to a file
  const deploymentInfo = {
    contractAddress: contractAddress,
    network: "baseMainnet",
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    constructorArgs: {
      flipSkiTokenAddress,
      initialFeeWallet,
      initialFeePercentage,
      initialMaxWager: initialMaxWager.toString(),
      initialMinWager: initialMinWager.toString(),
      vrfCoordinatorAddress,
      subscriptionId,
      keyHash
    }
  };

  const fs = require('fs');
  fs.writeFileSync(
    './deployment-info.json', 
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("Deployment info saved to deployment-info.json");

  // Wait for a few blocks for Basescan to index the transaction
  console.log("Waiting for 5 confirmations before attempting verification...");
  const deployTx = coinFlipContract.deploymentTransaction();
  if (deployTx) {
    await deployTx.wait(5);
    console.log("5 confirmations received.");
  } else {
    console.warn("Deployment transaction not found, skipping wait for confirmations.");
  }

  // Verify the contract on Basescan
  console.log("To verify the contract, run the following command in your terminal:");
  console.log(`npx hardhat verify --network baseMainnet ${contractAddress} "${flipSkiTokenAddress}" "${initialFeeWallet}" ${initialFeePercentage} ${initialMaxWager.toString()} ${initialMinWager.toString()} "${vrfCoordinatorAddress}" ${subscriptionId} "${keyHash}"`);
  console.log("Make sure your .env file has BASESCAN_API_KEY set.");

  // Post-deployment configuration suggestions
  console.log("\n--- Post-Deployment Configuration Suggestions ---");
  console.log("1. The contract now uses FlipSki ERC20 tokens for wagering");
  console.log("2. Players need to approve the contract to spend their FlipSki tokens");
  console.log("3. Ensure the contract has sufficient FlipSki tokens for payouts");
  console.log("4. VRF cancellation is enabled with a default timeout of 1 hour");
  console.log("5. To fund the contract with FlipSki tokens for payouts:");
  console.log(`   - Transfer FlipSki tokens to contract address: ${contractAddress}`);
  console.log("6. To adjust wager limits based on token price:");
  console.log(`   await coinFlipContract.setMaxWager(ethers.parseUnits("NEW_MAX", 18));`);
  console.log(`   await coinFlipContract.setMinWager(ethers.parseUnits("NEW_MIN", 18));`);
  console.log("\n--- Frontend Configuration ---");
  console.log("7. Update your frontend config.js file:");
  console.log(`   export const COINFLIP_ERC20_CONTRACT_ADDRESS = "${contractAddress}";`);
  console.log("8. The frontend is already configured to support both ETH and FlipSki wagering");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

