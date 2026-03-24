import hre from "hardhat";
import dotenv from "dotenv";
import { privateKeyToAccount } from "viem/accounts";
import fs from "fs";
import { encodeFunctionData, parseUnits } from "viem";

dotenv.config();

export type RoleName = "admin" | "lender1" | "lender2" | "borrower1" | "borrower2";

export function requiredEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env: ${name}`);
  return v;
}

export async function getEnv() {
  const connection = await hre.network.connect();
  const { viem } = connection;

  const [deployer, user2] = await viem.getWalletClients();
  const deployment = JSON.parse(
    fs.readFileSync("scripts/deployments-sepolia.json", "utf-8")
  );
  const lendToken = await viem.getContractAt(
    "MockERC20",
    deployment.LendToken
  );

  const pledgeProxy = await viem.getContractAt(
    "AkaPledge",
    deployment.PledgeProxy
  );

  const collateralToken = await viem.getContractAt(
    "MockERC20",
    deployment.CollateralToken
  );

  const oracle = await viem.getContractAt(
    "MockOracle",
    deployment.Oracle
  );

  const router = await viem.getContractAt(
    "MockUniswapV2Router",
    deployment.Router
  );
  const publicClient = await viem.getPublicClient();

  return {
    admin: deployer.account,
    user2: user2.account,
    poolId: 2n,
    viem,
    pledgeProxy,
    lendToken,
    collateralToken,
    oracle,
    router,
    publicClient
  };
}

