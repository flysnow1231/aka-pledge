import hre from "hardhat";
import dotenv from "dotenv";
import fs from "fs";
import { encodeFunctionData, parseUnits } from "viem";

dotenv.config();

async function main() {
  const connection = await hre.network.connect();
  const { viem } = connection;

  const [deployer,user2] = await viem.getWalletClients();
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
  "MockOracle",
  deployment.Router
);
  const now = Math.floor(Date.now() / 1000);

  await lendToken.write.mint(
    [deployer.account.address, parseUnits("10000000", 18)],
    { account: deployer.account }
  );
  await collateralToken.write.mint(
    [user2.account.address, parseUnits("10", 8)],
    { account: deployer.account }
  );

  await lendToken.write.approve([pledgeProxy.address, parseUnits("10000000", 18)], { account: deployer.account });
  await collateralToken.write.approve([pledgeProxy.address, parseUnits("10", 8)], { account: user2.account });
  
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
