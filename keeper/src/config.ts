import dotenv from "dotenv";
dotenv.config();

// Also load web/.env for DATABASE_URL if not set locally
if (!process.env.DATABASE_URL) {
  dotenv.config({ path: "../web/.env" });
}

export const CONFIG = {
  // Sui RPC
  rpcUrl: process.env.SUI_RPC_URL || "https://fullnode.testnet.sui.io:443",

  // Keeper wallet
  secretKey: process.env.KEEPER_SECRET_KEY || "",

  // Package ID
  packageId:
    process.env.PACKAGE_ID ||
    process.env.NEXT_PUBLIC_PACKAGE_ID ||
    "0x1e07b1f952d66f479773589f2930ae99d4038fa46844abdb2e496bbc8b0c4518",

  // Intervals (ms)
  rateUpdateInterval: parseInt(process.env.RATE_UPDATE_INTERVAL || "30000"),
  maturityCheckInterval: parseInt(
    process.env.MATURITY_CHECK_INTERVAL || "60000"
  ),
  snapshotInterval: parseInt(process.env.SNAPSHOT_INTERVAL || "300000"), // 5 min

  // Object IDs
  registryId:
    process.env.REGISTRY_ID ||
    process.env.NEXT_PUBLIC_REGISTRY_ID ||
    "0x163892b9725b04484cc39c19f7fd55894ea0de7dee456a0b94c9706a2162bbe8",
  syVaultId: process.env.SY_VAULT_ID || "",
  haedalAdapterId: process.env.HAEDAL_ADAPTER_ID || "",
  suilendAdapterId: process.env.SUILEND_ADAPTER_ID || "",
  naviAdapterId: process.env.NAVI_ADAPTER_ID || "",
  scallopAdapterId: process.env.SCALLOP_ADAPTER_ID || "",
  rateOracleId: process.env.RATE_ORACLE_ID || "",
};
