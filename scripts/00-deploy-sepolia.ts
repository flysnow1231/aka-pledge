import hre from "hardhat";
import { encodeFunctionData, parseUnits } from "viem";
import dotenv from "dotenv";

dotenv.config();

async function main() {
  const connection = await hre.network.connect();
  const { viem } = connection;

  const [deployer,user1] = await viem.getWalletClients();

  console.log("========================================");
  console.log("Deploying to Sepolia...");
  console.log("deployer:", deployer.account.address);
  console.log("========================================");

  const lendToken = await viem.deployContract("MockERC20", [
    "USD Stable",
    "USDQ",
    18,
  ]);

  const collateralToken = await viem.deployContract("MockERC20", [
    "Wrapped BTC",
    "WBTC",
    8,
  ]);

  const oracle = await viem.deployContract("MockOracle");
  const router = await viem.deployContract("MockUniswapV2Router");

  const priceX18 = parseUnits("100000", 18);

  await oracle.write.setPrice(
    [collateralToken.address, priceX18],
    { account: deployer.account }
  );

  await lendToken.write.mint(
    [router.address, parseUnits("10000000", 18)],
    { account: deployer.account }
  );

  


  const impl = await viem.deployContract("AkaPledge");

  const artifact = await hre.artifacts.readArtifact("AkaPledge");

  const initData = encodeFunctionData({
    abi: artifact.abi,
    functionName: "initialize",
    args: [deployer.account.address],
  });

  const proxy = await viem.deployContract("TestERC1967Proxy", [
    impl.address,
    initData,
  ]);

  console.log("lendToken:", lendToken.address);
  console.log("collateralToken:", collateralToken.address);
  console.log("oracle:", oracle.address);
  console.log("router:", router.address);
  console.log("impl:", impl.address);
  console.log("proxy:", proxy.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
