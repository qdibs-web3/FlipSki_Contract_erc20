const { ethers } = require("hardhat");

async function main() {
  const accounts = await ethers.getSigners();

  if (!accounts || accounts.length === 0) {
    console.error("Error: No deployer account found. Please ensure that your PRIVATE_KEY in the .env file is correctly set, is not the placeholder value, and the account has sufficient funds on the selected network (Base Sepolia).");
    process.exit(1);
  }
  const [deployer] = accounts;

  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // User-provided parameters hmmm
  const initialFeeWallet = "0x69Edc00a807042895Fe09595Ee27992B3aF8BB20"; // User provided
  const initialFeePercentage = 1000; // 1000 basis points = 10%
  const initialMaxWagerInEth = "0.01";
  const initialMinWagerInEth = "0.001";

  // Chainlink VRF v2.5 Parameters for Base 
  const vrfCoordinatorAddress = "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634"; // VRF Coordinator V2.5 for Base Sepolia
  const subscriptionId = "59788685954549039791911199740148202612233548775787967855992782509537492601169"; // REPLACE WITH YOUR ACTUAL SUBSCRIPTION ID (uint64)
  const keyHash = "0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70"; // Key Hash for Base (30 gwei)

  if (subscriptionId === "YOUR_VRF_SUBSCRIPTION_ID") {
    console.error("Error: Please replace 'YOUR_VRF_SUBSCRIPTION_ID' in the deploy script with your actual Chainlink VRF Subscription ID.");
    process.exit(1);
  }

  // Convert ETH to Wei for the constructor arguments
  const initialMaxWager = ethers.parseEther(initialMaxWagerInEth);
  const initialMinWager = ethers.parseEther(initialMinWagerInEth);

  console.log(`
    Deploying FlipSkiBaseVRF with parameters:
    Initial Fee Wallet: ${initialFeeWallet}
    Initial Fee Percentage: ${initialFeePercentage} (5%)
    Initial Max Wager: ${initialMaxWagerInEth} ETH (${initialMaxWager.toString()} Wei)
    Initial Min Wager: ${initialMinWagerInEth} ETH (${initialMinWager.toString()} Wei)
    VRF Coordinator: ${vrfCoordinatorAddress}
    Subscription ID: ${subscriptionId}
    Key Hash: ${keyHash}
  `);

  const CoinFlipContract = await ethers.getContractFactory("FlipSkiBaseVRF");
  const coinFlipContract = await CoinFlipContract.deploy(
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
  console.log("FlipSkiBaseVRF contract deployed to:", contractAddress);

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
  console.log(`npx hardhat verify --network ${ethers.provider.network.name} ${contractAddress} "${initialFeeWallet}" ${initialFeePercentage} ${initialMaxWager.toString()} ${initialMinWager.toString()} "${vrfCoordinatorAddress}" ${subscriptionId} "${keyHash}"`);
  console.log("Make sure your .env file has BASESCAN_API_KEY set.");

  // Post-deployment configuration suggestions for new features
  console.log("\n--- Post-Deployment Configuration Suggestions ---");
  console.log("1. The contract now has fees only on wins (no fees on losses)");
  console.log("2. VRF cancellation is enabled with a default timeout of 1 hour");
  console.log("3. To adjust the VRF cancellation timeout, call:");
  console.log(`   await coinFlipContract.setVRFCancellationTimeLimit(${3600}); // Set to desired seconds`);
  console.log("4. Balance checks are disabled by default for lower gas costs. To enable:");
  console.log("   await coinFlipContract.toggleBalanceCheck(true);");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
