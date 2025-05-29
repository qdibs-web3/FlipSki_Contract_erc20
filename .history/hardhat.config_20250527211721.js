require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xYOUR_PRIVATE_KEY"; // Default to a placeholder if not set. Ensure it starts with 0x if directly used.
const BASE_SEPOLIA_RPC_URL = process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
const BASE_MAINNET_RPC_URL = process.env.BASE_MAINNET_RPC_URL || "https://mainnet.base.org";
const BASESCAN_API_KEY = process.env.BASESCAN_API_KEY || "YOUR_BASESCAN_API_KEY";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.24",
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      // ChainID for Hardhat Network, useful for testing specific chain conditions
      chainId: 31337,
    },
    baseSepolia: {
      url: BASE_SEPOLIA_RPC_URL,
      accounts: PRIVATE_KEY !== "0xYOUR_PRIVATE_KEY" ? [`0x${PRIVATE_KEY.startsWith("0x") ? PRIVATE_KEY.substring(2) : PRIVATE_KEY}`] : [],
      chainId: 84532,
    },
    baseMainnet: {
      url: BASE_MAINNET_RPC_URL,
      accounts: PRIVATE_KEY !== "0xYOUR_PRIVATE_KEY" ? [`0x${PRIVATE_KEY.startsWith("0x") ? PRIVATE_KEY.substring(2) : PRIVATE_KEY}`] : [],
      chainId: 8453,
    },
  },
  etherscan: {
    apiKey: {
      base: BASESCAN_API_KEY,
      baseSepolia: BASESCAN_API_KEY,
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org"
        }
      },
      {
        network: "baseMainnet", // Corrected from base to baseMainnet for clarity, though 'base' is often used for mainnet in apiKey map
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org"
        }
      }
    ]
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  mocha: {
    timeout: 120000
  }
};

