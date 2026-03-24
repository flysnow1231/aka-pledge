import hre from "hardhat";
import dotenv from "dotenv";
import fs from "fs";

dotenv.config();

async function main() {
  console.log("create pool sepolia");
  const connection = await hre.network.connect();
  const { viem } = connection;

  const [admin,user1] = await viem.getWalletClients();
  const deployment = JSON.parse(
    fs.readFileSync("scripts/deployments-sepolia.json", "utf-8")
  );
  const lendToken = await viem.getContractAt(
    "MockERC20",
    deployment.LendToken
  );  

const pledgeContract = await viem.getContractAt(
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

  const settleTime = BigInt(now + 300);
  const executionEndTime = BigInt(now + 600);

  const params = [
    lendToken.address,
    collateralToken.address,
    oracle.address,
    router.address,
    settleTime,
    executionEndTime,
    1000n,
    15000n,
    12000n,
    30n,
    500n,
    "Supply Position Token",
    "SPT",
    "Junior Position Token",
    "JPT",
  ] as const;
  console.log("create pool sepolia");

  const txHash = await pledgeContract.write.createPool([params], {
    account: admin.account,
  });

  console.log("createPool tx:", txHash);

  const poolCount = (await pledgeContract.read.getPoolTotals([0n]));
  console.log("new poolId:", poolCount);



  
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
