// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {IUniswapV2RouterLike} from "./IUniswapV2RouterLike.sol";
import {CertificateToken} from "./CertificateToken.sol";
import "hardhat/console.sol"; // for debugging


/**
 * @notice Fixed-rate lending with:
 * - MATCH: deposit lend/collateral
 * - EXECUTION: users claim/refund, admin checks health
 * - FINISH: sell enough collateral to repay lenders (principal + fixed interest + fees)
 * - LIQUIDATION: sell all collateral if health is insufficient
 *
 * IMPORTANT:
 * This is a production-oriented template, but you should review the economics,
 * oracle assumptions and swap path/decimals handling before deployment.
 */
contract AkaPledge is Initializable, UUPSUpgradeable, ReentrancyGuard {
  using SafeERC20 for IERC20Metadata;

  uint256 private constant BPS = 10_000;
  uint256 private constant ONE = 1e18;
  uint256 private constant SECONDS_PER_YEAR = 365 days;

  enum Stage {
    MATCH,  // 匹配阶段
    UNDONE, // 未完成阶段
    EXECUTION, // 执行阶段
    FINISH, // 完成阶段
    LIQUIDATION // 清算阶段
  }

  address public admin; // 管理员地址 

  modifier onlyAdmin() {
    require(msg.sender == admin, "NOT_ADMIN");
    _;
  }

  struct Pool {
    IERC20Metadata lendToken; // LendToken (usually stablecoin)
    IERC20Metadata collateralToken; // borrowToken (collateral, e.g. BTC/ETH)
    IPriceOracle oracle; // 价格预言机
    IUniswapV2RouterLike router; // 路由器

    uint8 lendDecimals; // LendToken 的精度
    uint8 collDecimals; // borrowToken的精度
    uint256 lendScale; // 10**lendDecimals
    uint256 collScale; // 10**collDecimals

    // Timeline (single lifecycle per pool instance)
    uint256 settleTime; // end of MATCH
    uint256 executionEndTime; // end of EXECUTION (maturity)

    // Economics
    uint256 fixedInterestRateBps; // annual fixed rate
    uint256 collateralRatioBps; //抵押率(抵押物价值/借款金额)
    uint256 liquidationThresholdBps; // 清算阈值(抵押率低于该值时触发清算)
    uint256 protocolFeeBps; // 协议费用(利息的手续费)
    uint256 slippageBps; // 滑点(交易时的滑点)

    // User deposit totals (captured at settle)
    uint256 totalLendDeposited; // 借款金额
    uint256 totalCollateralDeposited; // 抵押物金额

    // Certificate token metadata (set at pool creation)
    string spName; // 借款证书名称
    string spSymbol; // 借款证书符号
    string jpName; // 抵押物证书名称
    string jpSymbol; // 抵押物证书符号

    // Matching result
    uint256 matchedPrincipal; // 匹配的借款金额
    uint256 usedCollateralAmount; // 使用的抵押物金额
    uint256 unmatchedLendTotal; // 未匹配的借款金额
    uint256 unmatchedCollateralTotal; // 未匹配的抵押物金额

    // Certificates (deployed at settle when matchedPrincipal > 0)
    CertificateToken spToken; // 借款证书
    CertificateToken jpToken; // 抵押物证书

    // Final supplies (snapshots at finish/liquidation)
    uint256 spFinalSupply; // 借款证书的最终供应量
    uint256 jpFinalSupply; // 抵押物证书的最终供应量

    // Distribution totals (computed at finish/liquidation)
    uint256 stableToLendersTotal; // 借款人的总收益
    uint256 stableToBorrowersSurplusTotal; // 借款人的总收益
    uint256 collateralToBorrowersTotal; // 抵押物人的总收益 超额部分

    Stage stage; // 阶段

    // Internal bookkeeping
    uint256 stableLoanPaidTotal; // 已支付的借款金额 借款人的总收益
    uint256 stableLendRefundPaidTotal; // 已支付的借款退款金额 借款人的总收益
    uint256 collateralBorrowRefundPaidTotal; // 已支付的抵押物退款金额 抵押物人的总收益 超额部分
  }

  uint256 public poolCount; // 池子数量
  mapping(uint256 => Pool) public pools;

  // User deposit tracking
  mapping(uint256 => mapping(address => uint256)) public lenderDeposits; // 借款人的存款
  mapping(uint256 => mapping(address => uint256)) public borrowerDeposits; // 抵押物人的存款

  // Claim/refund flags (per pool + per user)
  mapping(uint256 => mapping(address => bool)) public lenderRefunded; // 借款人的退款标志
  mapping(uint256 => mapping(address => bool)) public lenderClaimed; // 借款人的claim标志
  mapping(uint256 => mapping(address => bool)) public borrowerRefunded; // 抵押物人的退款标志   
  mapping(uint256 => mapping(address => bool)) public borrowerClaimed; // 抵押物人的claim标志 

  // ------------------------
  // Events
  // ------------------------
  event PoolCreated(
    uint256 indexed poolId,
    address indexed admin,
    address lendToken,
    address collateralToken,
    uint256 settleTime,
    uint256 executionEndTime,
    uint256 fixedInterestRateBps,
    uint256 collateralRatioBps,
    uint256 liquidationThresholdBps,
    uint256 protocolFeeBps,
    uint256 slippageBps
  );
  event PoolStageUpdated(uint256 indexed poolId, Stage fromStage, Stage toStage);

  event LendDeposited(uint256 indexed poolId, address indexed lender, uint256 amount);
  event BorrowDeposited(uint256 indexed poolId, address indexed borrower, uint256 amount);

  event Settled(
    uint256 indexed poolId,
    uint256 totalLendDeposited,
    uint256 totalCollateralDeposited,
    uint256 matchedPrincipal,
    uint256 usedCollateralAmount,
    uint256 unmatchedLendTotal,
    uint256 unmatchedCollateralTotal
  );

  event LenderRefunded(uint256 indexed poolId, address indexed lender, uint256 amount);
  event LenderClaimed(
    uint256 indexed poolId,
    address indexed lender,
    uint256 matchedPrincipalShare,
    uint256 spAmountMinted
  );

  event BorrowerRefunded(uint256 indexed poolId, address indexed borrower, uint256 amount);
  event BorrowerClaimed(
    uint256 indexed poolId,
    address indexed borrower,
    uint256 collateralUsedShare,
    uint256 loanPaidAmount,
    uint256 jpAmountMinted
  );

  event HealthChecked(
    uint256 indexed poolId,
    uint256 collateralValueStable,
    uint256 debtTotal,
    uint256 ratioBps,
    bool sufficient
  );
  event Finished(
    uint256 indexed poolId,
    uint256 collateralBalanceBeforeSwap,
    uint256 collateralSold,
    uint256 stableBalanceBefore,
    uint256 stableBalanceAfter,
    uint256 stableToLendersTotal,
    uint256 stableToBorrowersSurplusTotal,
    uint256 collateralToBorrowersTotal
  );
  event Liquidated(
    uint256 indexed poolId,
    uint256 collateralBalanceBeforeSwap,
    uint256 collateralSold,
    uint256 stableBalanceBefore,
    uint256 stableBalanceAfter,
    uint256 stableToLendersTotal,
    uint256 stableToBorrowersSurplusTotal
  );

  event LenderWithdrawn(uint256 indexed poolId, address indexed lender, uint256 spBurned, uint256 stableAmount);
  event BorrowerWithdrawn(
    uint256 indexed poolId,
    address indexed borrower,
    uint256 jpBurned,
    uint256 collateralAmount,
    uint256 stableSurplusAmount
  );

  // ------------------------
  // Initializer / UUPS
  // ------------------------
  constructor() {
    _disableInitializers();
  }

  function initialize(address admin_) external initializer {
    require(admin_ != address(0), "ADMIN_0");
    admin = admin_;
  }

  function _authorizeUpgrade(address) internal view override onlyAdmin {}

  // ------------------------
  // Pool management
  // ------------------------
  struct CreatePoolParams {
    IERC20Metadata lendToken;
    IERC20Metadata collateralToken;
    IPriceOracle oracle;
    IUniswapV2RouterLike router;

    uint256 settleTime;
    uint256 executionEndTime;

    uint256 fixedInterestRateBps;
    uint256 collateralRatioBps;
    uint256 liquidationThresholdBps;
    uint256 protocolFeeBps;
    uint256 slippageBps;

    // Certificate token metadata
    string spName;
    string spSymbol;
    string jpName;
    string jpSymbol;
  }

  function createPool(CreatePoolParams calldata params) external onlyAdmin returns (uint256 poolId) {
    require(address(params.lendToken) != address(0), "LEND_0");
    require(address(params.collateralToken) != address(0), "COLL_0");
    require(address(params.oracle) != address(0), "ORACLE_0");
    require(address(params.router) != address(0), "ROUTER_0");
    require(params.lendToken.decimals() <= 18, "LEND_DEC>18");
    require(params.collateralToken.decimals() <= 18, "COLL_DEC>18");
    require(params.settleTime > block.timestamp, "SETTLE_IN_PAST");
    require(params.executionEndTime > params.settleTime, "END<=SETTLE");
    require(params.fixedInterestRateBps <= BPS, "RATE_TOO_HIGH");
    require(params.collateralRatioBps >= BPS, "COLL_RATIO_TOO_LOW");
    require(params.liquidationThresholdBps > 0, "THRESH_0");
    require(params.protocolFeeBps <= BPS, "FEE_TOO_HIGH");
    require(params.slippageBps < BPS, "SLIP_TOO_HIGH");

    poolId = poolCount;
    poolCount = poolCount + 1;

    Pool storage p = pools[poolId];
    p.lendToken = params.lendToken;
    p.collateralToken = params.collateralToken;
    p.oracle = params.oracle;
    p.router = params.router;

    p.lendDecimals = params.lendToken.decimals();
    p.collDecimals = params.collateralToken.decimals();
    p.lendScale = 10 ** uint256(p.lendDecimals);
    p.collScale = 10 ** uint256(p.collDecimals);

    p.settleTime = params.settleTime;
    p.executionEndTime = params.executionEndTime;

    p.fixedInterestRateBps = params.fixedInterestRateBps;
    p.collateralRatioBps = params.collateralRatioBps;
    p.liquidationThresholdBps = params.liquidationThresholdBps;
    p.protocolFeeBps = params.protocolFeeBps;
    p.slippageBps = params.slippageBps;

    p.spName = params.spName;
    p.spSymbol = params.spSymbol;
    p.jpName = params.jpName;
    p.jpSymbol = params.jpSymbol;

    p.stage = Stage.MATCH;

    emit PoolCreated(
      poolId,
      msg.sender,
      address(params.lendToken),
      address(params.collateralToken),
      params.settleTime,
      params.executionEndTime,
      params.fixedInterestRateBps,
      params.collateralRatioBps,
      params.liquidationThresholdBps,
      params.protocolFeeBps,
      params.slippageBps
    );
  }

  // ------------------------
  // Deposits (MATCH)
  // ------------------------
  function depositLend(uint256 poolId, uint256 amount) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.MATCH, "NOT_MATCH");
    require(block.timestamp < p.settleTime, "SETTLED");
    require(amount > 0, "AMOUNT_0");

    p.totalLendDeposited += amount;
    lenderDeposits[poolId][msg.sender] += amount;

    p.lendToken.safeTransferFrom(msg.sender, address(this), amount);
    emit LendDeposited(poolId, msg.sender, amount);
  }

  function depositBorrow(uint256 poolId, uint256 amount) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.MATCH, "NOT_MATCH");
    require(block.timestamp < p.settleTime, "SETTLED");
    require(amount > 0, "AMOUNT_0");

    p.totalCollateralDeposited += amount;
    borrowerDeposits[poolId][msg.sender] += amount;

    p.collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    emit BorrowDeposited(poolId, msg.sender, amount);
  }

  // ------------------------
  // Settle (MATCH -> EXECUTION / UNDONE)
  // ------------------------
  function settle(uint256 poolId) external onlyAdmin nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.MATCH, "NOT_MATCH");
    require(block.timestamp >= p.settleTime, "TOO_EARLY");

    uint256 totalLend = p.totalLendDeposited;
    uint256 totalColl = p.totalCollateralDeposited;
    require(totalLend > 0 || totalColl > 0, "EMPTY_POOL");

    Stage from = p.stage;
    if (totalLend == 0 || totalColl == 0) {
      // UNDONE: refund everyone (via refund functions).
      p.unmatchedLendTotal = totalLend;
      p.unmatchedCollateralTotal = totalColl;
      p.matchedPrincipal = 0;
      p.usedCollateralAmount = 0;
      p.stage = Stage.UNDONE;
      emit PoolStageUpdated(poolId, from, p.stage);
      emit Settled(poolId, totalLend, totalColl, 0, 0, p.unmatchedLendTotal, p.unmatchedCollateralTotal);
      return;
    }

    // Use oracle price at settle to compute matched amounts.
    uint256 priceX18 = p.oracle.getPrice(address(p.collateralToken));
    require(priceX18 > 0, "ORACLE_PRICE_0");

    uint256 collateralValueStable = _collateralToStable(p, totalColl, priceX18);
    uint256 loanCapacity = Math.mulDiv(collateralValueStable, BPS, p.collateralRatioBps);

    uint256 matchedPrincipal = loanCapacity < totalLend ? loanCapacity : totalLend;
    require(matchedPrincipal > 0, "MATCH_0");

    // usedCollateral such that usedCollateralValueStable = matchedPrincipal * collateralRatioBps / BPS
    uint256 usedCollateralValueStable = Math.mulDiv(matchedPrincipal, p.collateralRatioBps, BPS);
    uint256 usedCollateralAmount = _stableToCollateral(p, usedCollateralValueStable, priceX18);

    require(usedCollateralAmount > 0, "USED_COLL_0");
    require(usedCollateralAmount <= totalColl, "USED_COLL_GT_TOTAL");

    p.matchedPrincipal = matchedPrincipal;
    p.usedCollateralAmount = usedCollateralAmount;

    p.unmatchedLendTotal = totalLend - matchedPrincipal;
    p.unmatchedCollateralTotal = totalColl - usedCollateralAmount;

    // Deploy certificates (decimals match underlying tokens).
    p.spToken = new CertificateToken(p.spName, p.spSymbol, address(this), p.lendDecimals);
    p.jpToken = new CertificateToken(p.jpName, p.jpSymbol, address(this), p.collDecimals);

    p.stage = Stage.EXECUTION;
    emit PoolStageUpdated(poolId, from, p.stage);
    emit Settled(
      poolId,
      totalLend,
      totalColl,
      p.matchedPrincipal,
      p.usedCollateralAmount,
      p.unmatchedLendTotal,
      p.unmatchedCollateralTotal
    );
  }

  // ------------------------
  // Refund / Claim (EXECUTION or UNDONE)
  // ------------------------
  function refundLend(uint256 poolId) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION || p.stage == Stage.UNDONE, "NOT_REFUND");

    uint256 deposit = lenderDeposits[poolId][msg.sender];
    require(deposit > 0, "NO_DEPOSIT");
    require(!lenderRefunded[poolId][msg.sender], "ALREADY");

    uint256 refundAmount;

    if (p.stage == Stage.UNDONE) {
      refundAmount = deposit;
    } else {
      refundAmount = Math.mulDiv(deposit, p.unmatchedLendTotal, p.totalLendDeposited);    
    }

    require(refundAmount > 0, "NO_REFUND");

    lenderRefunded[poolId][msg.sender] = true;
    p.lendToken.safeTransfer(msg.sender, refundAmount);
    p.stableLendRefundPaidTotal += refundAmount;

    emit LenderRefunded(poolId, msg.sender, refundAmount);
  }

  function claimLend(uint256 poolId) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION, "NOT_EXECUTION");
    require(address(p.spToken) != address(0), "NO_SPTOKEN");
    require(!lenderClaimed[poolId][msg.sender], "ALREADY");

    uint256 deposit = lenderDeposits[poolId][msg.sender];
    require(deposit > 0, "NO_DEPOSIT");
    require(p.totalLendDeposited > 0, "TOTAL_0");

    uint256 spAmount = Math.mulDiv(deposit, p.matchedPrincipal, p.totalLendDeposited);
    require(spAmount > 0, "SP_0");

    lenderClaimed[poolId][msg.sender] = true;
    p.spToken.mint(msg.sender, spAmount);

    emit LenderClaimed(poolId, msg.sender, p.matchedPrincipal, spAmount);
  }

  function refundBorrow(uint256 poolId) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION || p.stage == Stage.UNDONE, "NOT_REFUND");

    uint256 deposit = borrowerDeposits[poolId][msg.sender];
    require(deposit > 0, "NO_DEPOSIT");
    require(!borrowerRefunded[poolId][msg.sender], "ALREADY");

    uint256 refundAmount;
    if (p.stage == Stage.UNDONE) {
      refundAmount = deposit;
    } else {
      refundAmount = Math.mulDiv(deposit, p.unmatchedCollateralTotal, p.totalCollateralDeposited);
    }
    require(refundAmount > 0, "NO_REFUND");

    borrowerRefunded[poolId][msg.sender] = true;
    p.collateralToken.safeTransfer(msg.sender, refundAmount);
    p.collateralBorrowRefundPaidTotal += refundAmount;

    emit BorrowerRefunded(poolId, msg.sender, refundAmount);
  }

  function claimBorrow(
    uint256 poolId
  ) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION, "NOT_EXECUTION");
    require(address(p.jpToken) != address(0), "NO_JPTOKEN");
    require(!borrowerClaimed[poolId][msg.sender], "ALREADY");

    uint256 deposit = borrowerDeposits[poolId][msg.sender];
    require(deposit > 0, "NO_DEPOSIT");
    require(p.totalCollateralDeposited > 0, "TOTAL_0");

    uint256 jpAmount = Math.mulDiv(deposit, p.usedCollateralAmount, p.totalCollateralDeposited);
    require(jpAmount > 0, "JP_0");

    uint256 loanAmount = Math.mulDiv(deposit, p.matchedPrincipal, p.totalCollateralDeposited);
    require(loanAmount > 0, "LOAN_0");

    // Stable availability check: loan transfers are done from the pool's current lendToken balance.
    uint256 stableBal = p.lendToken.balanceOf(address(this));
    uint256 remainingStableLoan = p.matchedPrincipal - p.stableLoanPaidTotal;
    require(remainingStableLoan >= loanAmount, "LOAN_PAID");
    require(stableBal >= loanAmount, "STABLE_BAL_0");

    borrowerClaimed[poolId][msg.sender] = true;
    p.stableLoanPaidTotal += loanAmount;

    // Mint borrower certificate and pay loan funds.
    p.jpToken.mint(msg.sender, jpAmount);
    p.lendToken.safeTransfer(msg.sender, loanAmount);

    emit BorrowerClaimed(poolId, msg.sender, jpAmount, loanAmount, jpAmount);
  }

  // ------------------------
  // Execution health check (ADMIN)
  // ------------------------
  function checkCollateralSufficient(uint256 poolId) public returns (bool sufficient) {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION, "NOT_EXECUTION");

    (uint256 ratioBps, uint256 collateralValueStable, uint256 debtTotal) = _healthMetrics(p);
    sufficient = ratioBps >= p.liquidationThresholdBps;

    emit HealthChecked(poolId, collateralValueStable, debtTotal, ratioBps, sufficient);
  }

  function _healthMetrics(Pool storage p) internal view returns (uint256 ratioBps, uint256 collateralValueStable, uint256 debtTotal) {
    uint256 collateralBal = p.collateralToken.balanceOf(address(this));
    if (collateralBal == 0) {
      return (0, 0, _debtTotalAtTime(p, block.timestamp));
    }

    uint256 priceX18 = p.oracle.getPrice(address(p.collateralToken));
    require(priceX18 > 0, "ORACLE_PRICE_0");

    collateralValueStable = _collateralToStable(p, collateralBal, priceX18);
    debtTotal = _debtTotalAtTime(p, block.timestamp);

    if (debtTotal == 0) {
      return (type(uint256).max, collateralValueStable, debtTotal);
    }
    ratioBps = Math.mulDiv(collateralValueStable, BPS, debtTotal);
  }

  // ------------------------
  // Finish / Liquidation (ADMIN)
  // ------------------------
  function finish(
    uint256 poolId,
    uint256 deadline,
    address[] calldata path,
    uint256 minOutOverride
  ) external onlyAdmin nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION, "NOT_EXECUTION");
    require(block.timestamp >= p.executionEndTime, "NOT_MATURE");
    require(address(p.spToken) != address(0) && address(p.jpToken) != address(0), "MISSING_TOKENS");

    // Allow small rounding leftovers from mulDiv floors.
    uint256 principalTol = _tolerance(p.matchedPrincipal);  
    uint256 lendRefundTol = _tolerance(p.unmatchedLendTotal);
    uint256 borrowRefundTol = _tolerance(p.unmatchedCollateralTotal);
    require(p.stableLoanPaidTotal + principalTol >= p.matchedPrincipal, "LOANS_INCOMPLETE");
    require(p.stableLendRefundPaidTotal + lendRefundTol >= p.unmatchedLendTotal, "LEND_REFUNDS_INCOMPLETE");
    require(
      p.collateralBorrowRefundPaidTotal + borrowRefundTol >= p.unmatchedCollateralTotal,
      "BORROW_REFUNDS_INCOMPLETE"
    );

    // Snapshot final supplies (after user claims/refunds)
    p.spFinalSupply = p.spToken.totalSupply();
    p.jpFinalSupply = p.jpToken.totalSupply();

    uint256 debtTotal = _debtTotalAtTime(p, block.timestamp);
    (uint256 ratioBps,,) = _healthMetrics(p);
    require(ratioBps >= p.liquidationThresholdBps, "HEALTH_LOW");

    // Interest and fees at maturity.
    uint256 interestAtMaturity = _interestAtTime(p, block.timestamp);
    uint256 stableToAdminTotal = Math.mulDiv(interestAtMaturity, p.protocolFeeBps, BPS);
    uint256 stableToLendersTotal = debtTotal - stableToAdminTotal;

    uint256 stableBalBefore = p.lendToken.balanceOf(address(this));
    uint256 stableNeeded = stableToLendersTotal + stableToAdminTotal;

    // stableNeeded - stableBalBefore might be <= 0 if some borrowers did not claim loan.
    if (stableBalBefore < stableNeeded) {
      uint256 stableMissing = stableNeeded - stableBalBefore;

      // Swap collateral -> stable to cover missing part.
      uint256 collateralBalBeforeSwap = p.collateralToken.balanceOf(address(this));
      require(collateralBalBeforeSwap > 0, "NO_COLLATERAL");

      uint256 priceX18 = p.oracle.getPrice(address(p.collateralToken));
      require(priceX18 > 0, "ORACLE_PRICE_0");

      uint256 collateralToSell = _stableToCollateralCeil(p, stableMissing, priceX18);
      if (collateralToSell > collateralBalBeforeSwap) collateralToSell = collateralBalBeforeSwap;

      uint256 amountOutMin = minOutOverride > 0
        ? minOutOverride
        : Math.mulDiv(stableMissing, BPS - p.slippageBps, BPS);

      uint256 collateralBalanceBefore = collateralBalBeforeSwap;
      _swapCollateralForStable(p, collateralToSell, amountOutMin, path, deadline);
      uint256 collateralSold = collateralBalanceBefore - p.collateralToken.balanceOf(address(this));

      // Verify that we have enough stable to pay lenders+admin.
      uint256 stableBalAfter = p.lendToken.balanceOf(address(this));
      require(stableBalAfter >= stableNeeded, "STABLE_INSUFFICIENT");

      // Record distribution totals.
      p.stableToLendersTotal = stableToLendersTotal;
      // Borrowers receive surplus stable (if swap yields more than missing).
      p.stableToBorrowersSurplusTotal = stableBalAfter - stableNeeded;
      p.collateralToBorrowersTotal = p.collateralToken.balanceOf(address(this));

      // Transfer admin fee now; lenders/borrowers withdraw later.
      if (stableToAdminTotal > 0) {
        p.lendToken.safeTransfer(admin, stableToAdminTotal);
      }

      emit Finished(
        poolId,
        collateralBalBeforeSwap,
        collateralSold,
        stableBalBefore,
        stableBalAfter,
        stableToLendersTotal,
        p.stableToBorrowersSurplusTotal,
        p.collateralToBorrowersTotal
      );
    } else {
      // No swap required; stable already sufficient.
      p.stableToLendersTotal = stableToLendersTotal;
      p.stableToBorrowersSurplusTotal = stableBalBefore - stableNeeded;
      p.collateralToBorrowersTotal = p.collateralToken.balanceOf(address(this));

      if (stableToAdminTotal > 0) {
        p.lendToken.safeTransfer(admin, stableToAdminTotal);
      }

      emit Finished(
        poolId,
        p.collateralToken.balanceOf(address(this)),
        0,
        stableBalBefore,
        p.lendToken.balanceOf(address(this)),
        stableToLendersTotal,
        p.stableToBorrowersSurplusTotal,
        p.collateralToBorrowersTotal
      );
    }

    p.stage = Stage.FINISH;
    emit PoolStageUpdated(poolId, Stage.EXECUTION, Stage.FINISH);
  }

  function liquidate(
    uint256 poolId,
    uint256 deadline,
    address[] calldata path,
    uint256 minOutOverride
  ) external onlyAdmin nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.EXECUTION, "NOT_EXECUTION");

    // Check health before liquidating.
    (uint256 ratioBps,,) = _healthMetrics(p);
    require(ratioBps < p.liquidationThresholdBps, "HEALTH_OK");

    require(address(p.spToken) != address(0) && address(p.jpToken) != address(0), "MISSING_TOKENS");

    uint256 principalTol = _tolerance(p.matchedPrincipal);
    uint256 lendRefundTol = _tolerance(p.unmatchedLendTotal);
    uint256 borrowRefundTol = _tolerance(p.unmatchedCollateralTotal);
    require(p.stableLoanPaidTotal + principalTol >= p.matchedPrincipal, "LOANS_INCOMPLETE");
    require(p.stableLendRefundPaidTotal + lendRefundTol >= p.unmatchedLendTotal, "LEND_REFUNDS_INCOMPLETE");
    require(
      p.collateralBorrowRefundPaidTotal + borrowRefundTol >= p.unmatchedCollateralTotal,
      "BORROW_REFUNDS_INCOMPLETE"
    );

    // Snapshot final supplies.
    p.spFinalSupply = p.spToken.totalSupply();
    p.jpFinalSupply = p.jpToken.totalSupply();

    uint256 debtTotal = _debtTotalAtTime(p, block.timestamp);
    uint256 interestAtNow = _interestAtTime(p, block.timestamp);
    uint256 stableToAdminPlanned = Math.mulDiv(interestAtNow, p.protocolFeeBps, BPS);
    uint256 stableToLendersPlanned = debtTotal - stableToAdminPlanned;

    uint256 collateralBalanceBeforeSwap = p.collateralToken.balanceOf(address(this));
    uint256 stableBalBefore = p.lendToken.balanceOf(address(this));

    // Sell all collateral held by this contract.
    if (collateralBalanceBeforeSwap > 0) {
      uint256 priceX18 = p.oracle.getPrice(address(p.collateralToken));
      require(priceX18 > 0, "ORACLE_PRICE_0");
      uint256 expectedStableOut = _collateralToStable(p, collateralBalanceBeforeSwap, priceX18);
      uint256 amountOutMin = minOutOverride > 0
        ? minOutOverride
        : Math.mulDiv(expectedStableOut, BPS - p.slippageBps, BPS);

      _swapCollateralForStable(p, collateralBalanceBeforeSwap, amountOutMin, path, deadline);
    }

    uint256 stableBalAfter = p.lendToken.balanceOf(address(this));
    uint256 stableAvailable = stableBalAfter; // all stable sits in this contract

    // Allocate based on availability (supports partial coverage).
    uint256 stableSurplusToBorrowers;
    uint256 stableToAdmin;
    uint256 stableToLenders;

    if (stableAvailable >= debtTotal) {
      stableToAdmin = stableToAdminPlanned;
      stableToLenders = stableToLendersPlanned;
      stableSurplusToBorrowers = stableAvailable - debtTotal;
    } else {
      // Pro-rata allocation when undercollateralized.
      stableToAdmin = Math.mulDiv(stableToAdminPlanned, stableAvailable, debtTotal);
      stableToLenders = stableAvailable - stableToAdmin;
      stableSurplusToBorrowers = 0;
    }

    p.stableToLendersTotal = stableToLenders;
    p.stableToBorrowersSurplusTotal = stableSurplusToBorrowers;
    p.collateralToBorrowersTotal = 0; // all collateral is sold

    if (stableToAdmin > 0) {
      p.lendToken.safeTransfer(admin, stableToAdmin);
    }

    p.stage = Stage.LIQUIDATION;
    emit PoolStageUpdated(poolId, Stage.EXECUTION, Stage.LIQUIDATION);

    emit Liquidated(
      poolId,
      collateralBalanceBeforeSwap,
      collateralBalanceBeforeSwap,
      stableBalBefore,
      stableBalAfter,
      p.stableToLendersTotal,
      p.stableToBorrowersSurplusTotal
    );
  }

  // ------------------------
  // Withdraw (FINISH / LIQUIDATION)
  // ------------------------
  function withdrawLend(uint256 poolId) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.FINISH || p.stage == Stage.LIQUIDATION, "NOT_DONE");
    require(address(p.spToken) != address(0), "NO_SPTOKEN");
    require(p.spFinalSupply > 0, "SP_SUPPLY_0");

    uint256 shares = p.spToken.balanceOf(msg.sender);
    require(shares > 0, "NO_SHARES");

    uint256 supply = p.spFinalSupply;
    uint256 payout = Math.mulDiv(p.stableToLendersTotal, shares, supply);

    // Burn certificate then pay.
    p.spToken.burnFor(msg.sender, shares);
    p.lendToken.safeTransfer(msg.sender, payout);

    emit LenderWithdrawn(poolId, msg.sender, shares, payout);
  }

  function withdrawBorrow(uint256 poolId) external nonReentrant {
    Pool storage p = pools[poolId];
    require(p.stage == Stage.FINISH || p.stage == Stage.LIQUIDATION, "NOT_DONE");
    require(address(p.jpToken) != address(0), "NO_JPTOKEN");
    require(p.jpFinalSupply > 0, "JP_SUPPLY_0");

    uint256 shares = p.jpToken.balanceOf(msg.sender);
    require(shares > 0, "NO_SHARES");

    uint256 supply = p.jpFinalSupply;
    uint256 collateralAmount = Math.mulDiv(p.collateralToBorrowersTotal, shares, supply);
    uint256 stableSurplusAmount = Math.mulDiv(p.stableToBorrowersSurplusTotal, shares, supply);

    p.jpToken.burnFor(msg.sender, shares);

    if (collateralAmount > 0) {
      p.collateralToken.safeTransfer(msg.sender, collateralAmount);
    }
    if (stableSurplusAmount > 0) {
      p.lendToken.safeTransfer(msg.sender, stableSurplusAmount);
    }

    emit BorrowerWithdrawn(poolId, msg.sender, shares, collateralAmount, stableSurplusAmount);
  }

  // ------------------------
  // Views / helpers
  // ------------------------
  function getPoolStage(uint256 poolId) external view returns (Stage) {
    return pools[poolId].stage;
  }

  function getPoolTotals(uint256 poolId)
    external
    view
    returns (
      uint256 totalLendDeposited,
      uint256 totalCollateralDeposited,
      uint256 matchedPrincipal,
      uint256 usedCollateralAmount,
      uint256 unmatchedLendTotal,
      uint256 unmatchedCollateralTotal,
      uint256 stableLoanPaidTotal,
      uint256 stableLendRefundPaidTotal,
      uint256 collateralBorrowRefundPaidTotal 
    )
  {
    Pool storage p = pools[poolId];
    return (
      p.totalLendDeposited,
      p.totalCollateralDeposited,
      p.matchedPrincipal,
      p.usedCollateralAmount,
      p.unmatchedLendTotal,
      p.unmatchedCollateralTotal,
      p.stableLoanPaidTotal,
      p.stableLendRefundPaidTotal,
      p.collateralBorrowRefundPaidTotal
    );
  }

  function getUserLenderData(uint256 poolId, address user)
    external
    view
    returns (
      uint256 deposited,
      bool refunded,
      bool claimed,
      uint256 refundAmount,
      uint256 spClaimableAmount
    )
  {
    Pool storage p = pools[poolId];
    deposited = lenderDeposits[poolId][user];
    refunded = lenderRefunded[poolId][user];
    claimed = lenderClaimed[poolId][user];
    if (deposited == 0) return (0, refunded, claimed, 0, 0);

    if (p.stage == Stage.UNDONE) {
      refundAmount = deposited;
    } else if (p.stage == Stage.EXECUTION) {
      refundAmount = Math.mulDiv(deposited, p.unmatchedLendTotal, p.totalLendDeposited);
      spClaimableAmount = Math.mulDiv(deposited, p.matchedPrincipal, p.totalLendDeposited);
    }
  }

  function getUserBorrowerData(uint256 poolId, address user)
    external
    view
    returns (
      uint256 deposited,
      bool refunded,
      bool claimed,
      uint256 refundAmount,
      uint256 jpClaimableAmount,
      uint256 loanAmount
    )
  {
    Pool storage p = pools[poolId];
    deposited = borrowerDeposits[poolId][user];
    refunded = borrowerRefunded[poolId][user];
    claimed = borrowerClaimed[poolId][user];
    if (deposited == 0) return (0, refunded, claimed, 0, 0, 0);

    if (p.stage == Stage.UNDONE) {
      refundAmount = deposited;
    } else if (p.stage == Stage.EXECUTION) {
      refundAmount = Math.mulDiv(deposited, p.unmatchedCollateralTotal, p.totalCollateralDeposited);
      jpClaimableAmount = Math.mulDiv(deposited, p.usedCollateralAmount, p.totalCollateralDeposited);
      loanAmount = Math.mulDiv(deposited, p.matchedPrincipal, p.totalCollateralDeposited);
    }
  }

  function getUserCertificateBalances(uint256 poolId, address user)
    external
    view
    returns (uint256 spBalance, uint256 jpBalance)
  {
    Pool storage p = pools[poolId];
    if (address(p.spToken) != address(0)) spBalance = p.spToken.balanceOf(user);
    if (address(p.jpToken) != address(0)) jpBalance = p.jpToken.balanceOf(user);
  }

  function interestAt(uint256 poolId, uint256 timestamp) external view returns (uint256) {
    Pool storage p = pools[poolId];
    return _interestAtTime(p, timestamp);
  }

  function debtTotalAt(uint256 poolId, uint256 timestamp) external view returns (uint256) {
    Pool storage p = pools[poolId];
    return _debtTotalAtTime(p, timestamp);
  }

  function collateralRatioAt(uint256 poolId, uint256 _timestamp) external view returns (uint256 ratioBps) {
    Pool storage p = pools[poolId];
    // silence unused parameter warning (pricing uses oracle at call time in this template)
    _timestamp;
    (ratioBps,,) = _healthMetrics(p);
    // timestamp is ignored in this simplified template since oracle is read at call time.
    // If you need deterministic pricing, you should snapshot oracle values during settle/execute.
  }

  // ------------------------
  // Swap + accounting helpers
  // ------------------------
  function _swapCollateralForStable(
    Pool storage p,
    uint256 collateralToSell,
    uint256 amountOutMin,
    address[] calldata path,
    uint256 deadline
  ) internal {
    require(collateralToSell > 0, "SELL_0");
    require(deadline >= block.timestamp, "DEADLINE_PAST");
    require(path.length >= 2, "BAD_PATH");
    require(path[0] == address(p.collateralToken), "PATH_START");
    require(path[path.length - 1] == address(p.lendToken), "PATH_END");

    // Approve router (some ERC20s require resetting allowance to zero first).
    // SafeERC20 v5 provides `forceApprove` (not `safeApprove`) for this purpose.
    SafeERC20.forceApprove(IERC20(address(p.collateralToken)), address(p.router), collateralToSell);

    p.router.swapExactTokensForTokens(collateralToSell, amountOutMin, path, address(this), deadline);
  }

  /**
   * @dev Convert collateral amount (raw, collateral token smallest units) to stable value (raw, stable token smallest units),
   * using oracle price returned as stablePerCollateralX18.
   */
  function _collateralToStable(Pool storage p, uint256 collateralAmount, uint256 priceX18) internal view returns (uint256) {
    // stableValue = collateralAmount * priceX18 * lendScale / (collScale * 1e18)
    // collateralAmount includes collDecimals; priceX18 is per full collateral token (10**collDecimals).
    uint256 numerator = collateralAmount * priceX18 * p.lendScale;
    uint256 denom = p.collScale * ONE;
    return numerator / denom;
  }

  function _stableToCollateral(Pool storage p, uint256 stableAmount, uint256 priceX18) internal view returns (uint256) {
    // collateral = stableAmount * collScale * 1e18 / (priceX18 * lendScale)
    uint256 numerator = stableAmount * p.collScale * ONE;
    uint256 denom = priceX18 * p.lendScale;
    return numerator / denom;
  }

  function _stableToCollateralCeil(Pool storage p, uint256 stableAmount, uint256 priceX18) internal view returns (uint256) {
    // ceil(stableAmount * collScale * 1e18 / (priceX18 * lendScale))
    uint256 denom = priceX18 * p.lendScale;
    require(denom > 0, "DENOM_0");
    uint256 y = p.collScale * ONE;
    return Math.mulDiv(stableAmount, y, denom, Math.Rounding.Ceil);
  }

  function _interestAtTime(Pool storage p, uint256 timestamp) internal view returns (uint256) {
    if (p.matchedPrincipal == 0) return 0;
    if (timestamp <= p.settleTime) return 0;
    uint256 end = timestamp;
    if (end > p.executionEndTime) end = p.executionEndTime;
    uint256 dt = end - p.settleTime;
    uint256 yearly = Math.mulDiv(p.matchedPrincipal, p.fixedInterestRateBps, BPS); // principal * rate / BPS
    return Math.mulDiv(yearly, dt, SECONDS_PER_YEAR);
  }

  function _debtTotalAtTime(Pool storage p, uint256 timestamp) internal view returns (uint256) {
    return p.matchedPrincipal + _interestAtTime(p, timestamp);
  }

  function _tolerance(uint256 amount) internal pure returns (uint256) {
    // 0.1% tolerance, at least 1 smallest-unit.
    return amount == 0 ? 1 : Math.max(1, amount / 1000);
  }
}

