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

  // User-provided parameters
  const initialFeeWallet = "0xED946D2F962cF5207E209CE0F16b629A293d0A8F"; // User provided
  const initialFeePercentage = 1000; // 500 basis points = 10%
  const initialMaxWagerInEth = "0.01";
  const initialMinWagerInEth = "0.001";

  // Chainlink VRF v2.5 Parameters for Base Sepolia
  const vrfCoordinatorAddress = "0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE"; // VRF Coordinator V2.5 for Base Sepolia
  const subscriptionId = "735567865254146982589629849288344123898350234912932034375983834189117400818"; // REPLACE WITH YOUR ACTUAL SUBSCRIPTION ID (uint64)
  const keyHash = "0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71"; // Example Key Hash for Base Sepolia (30 gwei)

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
