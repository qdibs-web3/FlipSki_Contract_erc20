# Deploying and Verifying CoinFlipETH Contract in VSCode

This guide will walk you through deploying and verifying the `CoinFlipETH.sol` smart contract using Hardhat within your VSCode environment. We have already set up the Hardhat project structure, including the contract, deployment scripts, and configuration files.

## Prerequisites

1.  **VSCode (Visual Studio Code)**: Ensure you have VSCode installed. You can download it from [https://code.visualstudio.com/](https://code.visualstudio.com/).
2.  **Node.js and npm**: Hardhat and its dependencies require Node.js (which includes npm). Download and install it from [https://nodejs.org/](https://nodejs.org/) (LTS version recommended).
3.  **Git (Optional but Recommended)**: For version control. Download from [https://git-scm.com/](https://git-scm.com/).
4.  **MetaMask (or similar wallet)**: You will need a wallet to manage your accounts and private keys for deployment. Ensure you have accounts for Base Sepolia (testnet) and Base Mainnet with sufficient funds (ETH for gas, and testnet ETH for Sepolia).

## Project Setup in Your Local Environment

1.  **Download and Unzip Project**: You will receive a `coinflip-hardhat-project.zip` file. Download it and extract its contents to a directory on your computer.
2.  **Open Project in VSCode**:
    *   Open VSCode.
    *   Go to `File > Open Folder...` and select the extracted `coinflip-hardhat-project` directory.
3.  **Open Integrated Terminal**: 
    *   In VSCode, go to `Terminal > New Terminal` (or use the shortcut, usually `Ctrl+\`` or `Cmd+\``).
4.  **Install Dependencies**:
    *   In the VSCode terminal, ensure you are in the project root directory (`coinflip-hardhat-project`).
    *   Run the following command to install all the necessary project dependencies defined in `package.json`:
        ```bash
        npm install
        ```

## Configure Environment Variables (.env file)

The project uses a `.env` file to store sensitive information like your private key and API keys. This file is included in the `.gitignore` so it won't be accidentally committed to a public repository.

1.  **Locate `.env` file**: In the root of your `coinflip-hardhat-project` directory, you will find a file named `.env`. It will have the following content:

    ```env
    PRIVATE_KEY=
    BASE_SEPOLIA_RPC_URL=
    BASE_MAINNET_RPC_URL=
    BASESCAN_API_KEY=
    ```

2.  **Edit `.env` file**: Open this file in VSCode and fill in the details:
    *   `PRIVATE_KEY`: **CRITICAL!** This is the private key of the Ethereum account you will use for deploying the contract. 
        *   **Never share this key with anyone or commit it to version control.**
        *   The key should be the raw private key string, typically 64 hexadecimal characters (e.g., `abcdef1234...`). Do NOT include the `0x` prefix here; the scripts and Hardhat config will handle it.
        *   Ensure this account has sufficient ETH on Base Sepolia for testnet deployment and Base Mainnet for mainnet deployment to cover gas fees.
    *   `BASE_SEPOLIA_RPC_URL`: The RPC URL for the Base Sepolia test network. You can get this from an RPC provider like Infura, Alchemy, Ankr, or use the public Base RPC (`https://sepolia.base.org`). Using your own dedicated RPC endpoint is generally more reliable.
    *   `BASE_MAINNET_RPC_URL`: The RPC URL for the Base Mainnet. Similar to Sepolia, get this from an RPC provider or use the public Base RPC (`https://mainnet.base.org`).
    *   `BASESCAN_API_KEY`: Your API key from Basescan (the block explorer for Base). This is required for automatic contract verification. 
        *   Go to [https://basescan.org/](https://basescan.org/).
        *   Create an account or log in.
        *   Navigate to your account settings to find or generate an API key.

    **Example `.env` content (replace with your actual values):**
    ```env
    PRIVATE_KEY=YOUR_64_CHARACTER_PRIVATE_KEY_HERE
    BASE_SEPOLIA_RPC_URL=https://your-base-sepolia-rpc-provider-url.com/your-api-key
    BASE_MAINNET_RPC_URL=https://your-base-mainnet-rpc-provider-url.com/your-api-key
    BASESCAN_API_KEY=YOUR_ACTUAL_BASESCAN_API_KEY_HERE
    ```

3.  **Save the `.env` file.**

## Compiling the Smart Contract

Before deploying, it's good practice to compile your contract to ensure there are no syntax errors.

*   In the VSCode terminal, run:
    ```bash
    npx hardhat compile
    ```
    This command will compile your `CoinFlipETH.sol` contract (and any other contracts in the `contracts` directory) and place the artifacts in the `artifacts` directory.

## Deploying to Base Sepolia Testnet

1.  **Ensure `.env` is correctly configured for Sepolia** (especially `PRIVATE_KEY` and `BASE_SEPOLIA_RPC_URL`).
2.  **Run the deployment script**:
    *   In the VSCode terminal, execute:
        ```bash
        npx hardhat run scripts/deploy.js --network baseSepolia
        ```
    *   This script will:
        *   Connect to the Base Sepolia network using your RPC URL and private key.
        *   Deploy the `CoinFlipETH.sol` contract with the constructor arguments you provided earlier:
            *   Fee Wallet: `0xED946D2F962cF5207E209CE0F16b629A293d0A8F`
            *   Fee Percentage: `500` (5%)
            *   Max Wager: `0.01 ETH` (converted to Wei)
            *   Min Wager: `0.001 ETH` (converted to Wei)
        *   Print the deployer's address, balance, and the deployed contract address to the console.
        *   Wait for 5 block confirmations.
        *   Print the command you need to run for verification.

3.  **Note the Deployed Contract Address**: The script will output `CoinFlipETH contract deployed to: <YOUR_CONTRACT_ADDRESS>`. Copy this address.

## Verifying on Base Sepolia (Basescan)

After successful deployment, the `deploy.js` script will output the command needed for verification. It will look like this:

`npx hardhat verify --network baseSepolia YOUR_CONTRACT_ADDRESS "0xED946D2F962cF5207E209CE0F16b629A293d0A8F" 500 "10000000000000000" "1000000000000000"`

(The last two numbers are 0.01 ETH and 0.001 ETH in Wei, respectively. The script calculates these for you.)

1.  **Ensure `BASESCAN_API_KEY` is set in your `.env` file.**
2.  **Run the verification command**:
    *   Copy the command printed by the `deploy.js` script (or construct it manually using your deployed contract address) and run it in the VSCode terminal.
    *   Hardhat will attempt to verify your contract source code on Basescan.
    *   If successful, you will see a success message and a link to the verified contract on Basescan.

## Deploying to Base Mainnet

**CAUTION: Deploying to mainnet involves real funds. Double-check everything carefully.**

1.  **Ensure `.env` is correctly configured for Mainnet**:
    *   Verify `PRIVATE_KEY` is for your mainnet deployment account (with sufficient real ETH).
    *   Verify `BASE_MAINNET_RPC_URL` is correct.
    *   `BASESCAN_API_KEY` remains the same.
2.  **Review Constructor Arguments**: The `scripts/deploy.js` script uses hardcoded constructor arguments. If you need different values for mainnet (e.g., a different fee wallet or fee percentage), you must update them in `scripts/deploy.js` before deploying.
    ```javascript
    // Inside scripts/deploy.js
    const initialFeeWallet = "0xED946D2F962cF5207E209CE0F16b629A293d0A8F"; // CHANGE IF NEEDED FOR MAINNET
    const initialFeePercentage = 500; // CHANGE IF NEEDED FOR MAINNET
    const initialMaxWagerInEth = "0.01"; // CHANGE IF NEEDED FOR MAINNET
    const initialMinWagerInEth = "0.001"; // CHANGE IF NEEDED FOR MAINNET
    ```
3.  **Run the deployment script for Mainnet**:
    *   In the VSCode terminal, execute:
        ```bash
        npx hardhat run scripts/deploy.js --network baseMainnet
        ```
    *   Follow the same process as with Sepolia. The script will output the deployed contract address.

4.  **Note the Deployed Contract Address** for mainnet.

## Verifying on Base Mainnet (Basescan)

The `deploy.js` script will again output the command needed for verification, but this time with `--network baseMainnet`.

`npx hardhat verify --network baseMainnet YOUR_MAINNET_CONTRACT_ADDRESS "CONSTRUCTOR_ARG_1" ...`

1.  **Run the verification command** printed by the script (or construct it manually) in the VSCode terminal.
2.  Hardhat will attempt to verify your contract on Basescan (mainnet).

## Troubleshooting

*   **`Error: No deployer account found...`**: Your `PRIVATE_KEY` in `.env` is likely incorrect, missing, or the account has no funds on the selected network. Double-check it. Ensure it's the raw key without `0x`.
*   **`Nonce too high` / `Nonce too low` / `Replacement transaction underpriced`**: These are common Ethereum transaction issues. Often, waiting a bit and retrying helps. Ensure your RPC provider is synced. You might need to reset your account nonce in MetaMask if you've been sending transactions manually.
*   **Verification Fails**: 
    *   Ensure `BASESCAN_API_KEY` is correct.
    *   Ensure the contract code hasn't changed since deployment.
    *   Ensure the constructor arguments provided to the `verify` command exactly match those used during deployment (the `deploy.js` script prints these for you).
    *   Sometimes Basescan takes a few minutes to index the contract. Wait a bit and retry verification.
    *   Check the `hardhat.config.js` for correct `etherscan` and `customChains` configuration (it should be correctly set up in the provided project).
*   **Compiler Version Mismatch (during verification)**: Ensure the Solidity version in your `hardhat.config.js` (`solidity: "0.8.24"`) matches the pragma in your `CoinFlipETH.sol` (`pragma solidity ^0.8.24;`).

This guide should provide you with all the steps needed to deploy and verify your CoinFlipETH smart contract from your VSCode environment. Good luck!
