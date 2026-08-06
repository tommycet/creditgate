// CreditGateVault ABI — Key functions for the frontend
export const CREDIT_GATE_ABI = [
  // View functions
  "function fxrp() view returns (address)",
  "function usdt0() view returns (address)",
  "function teeAuthority() view returns (address)",
  "function collateralRatioBps() view returns (uint256)",
  "function ftsoStalenessLimit() view returns (uint64)",
  "function loanDuration() view returns (uint256)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function nextLoanId() view returns (uint256)",
  "function loans(uint256) view returns (tuple(address borrower, uint256 collateralAmount, uint256 loanAmount, uint256 requiredRepaymentDrops, uint256 deadline, uint64 eligibilityExpiry, uint32 eligibilityNonce, bytes32 expectedCommitment, uint8 state, bytes32 borrowerSourceAddressHash))",
  "function getLoan(uint256) view returns (tuple(address borrower, uint256 collateralAmount, uint256 loanAmount, uint256 requiredRepaymentDrops, uint256 deadline, uint64 eligibilityExpiry, uint32 eligibilityNonce, bytes32 expectedCommitment, uint8 state, bytes32 borrowerSourceAddressHash))",
  "function getBorrowerLoanIds(address) view returns (uint256[])",
  "function borrowerXRPLAddressHash(address) view returns (bytes32)",

  // Mutating functions
  "function depositCollateral(uint256 amount) returns (uint256 loanId)",
  "function registerXRPLAddress(bytes32 xrplAddressHash)",
  "function withdrawCollateral(uint256 loanId)",
  "function requestEligibility(uint256 loanId)",
  "function submitEligibility(uint256 loanId, tuple(address borrower, uint256 limit, uint64 expiry, uint32 nonce, uint8 revocationVersion, uint8 v, bytes32 r, bytes32 s) attestation)",
  "function drawLoan(uint256 loanId, uint256 loanAmount) payable",
  "function submitRepaymentProof(uint256 loanId, tuple(bytes32[] merkleProof, tuple(bytes32 attestationType, bytes32 sourceId, uint64 votingRound, uint64 lowestUsedTimestamp, tuple(bytes32 transactionId, address proofOwner) requestBody, tuple(uint64 blockNumber, uint64 blockTimestamp, string sourceAddress, bytes32 sourceAddressHash, bytes32 receivingAddressHash, bytes32 intendedReceivingAddressHash, int256 spentAmount, int256 intendedSpentAmount, int256 receivedAmount, int256 intendedReceivedAmount, bool hasMemoData, bytes firstMemoData, bool hasDestinationTag, uint256 destinationTag, uint8 status) responseBody) data) proof)",
  "function liquidate(uint256 loanId)",
  "function recoverDefaultedCollateral(uint256 loanId)",

  // S49: Dutch-auction liquidation functions + views (subagent #48/#49)
  // getHealthFactor is a payable view (forwards the FTSO query fee in msg.value;
  // 0 on Coston2). getAuctionPrice reverts if the loan is not in AUCTION state,
  // so we only call it when state == 9. auctions(uint256) is a public mapping getter
  // returning the LiquidationAuction tuple (startPrice, startTimestamp, highestBidder, highestBid).
  "function startLiquidationAuction(uint256 loanId) payable",
  "function bidOnLiquidation(uint256 loanId, uint256 bidAmount)",
  "function finalizeAuction(uint256 loanId)",
  "function getAuctionPrice(uint256 loanId) view returns (uint256)",
  "function getHealthFactor(uint256 loanId) payable returns (uint256)",
  "function auctions(uint256) view returns (uint256 startPrice, uint64 startTimestamp, address highestBidder, uint256 highestBid)",

  // Events
  "event CollateralDeposited(uint256 indexed loanId, address indexed borrower, uint256 amount)",
  "event EligibilityRequested(uint256 indexed loanId, address indexed borrower)",
  "event EligibilitySubmitted(uint256 indexed loanId, address indexed borrower, uint256 limit, uint64 expiry)",
  "event LoanFunded(uint256 indexed loanId, address indexed borrower, uint256 loanAmount, uint256 collateralAmount, bytes32 expectedCommitment)",
  "event RepaymentProofSubmitted(uint256 indexed loanId, bytes32 indexed proofHash, int256 receivedDrops)",
  "event LoanClosed(uint256 indexed loanId, address indexed borrower, uint256 collateralReleased)",
  "event LoanDefaulted(uint256 indexed loanId, address indexed borrower, uint256 collateralSeized)",
] as const;

// S3: Standard ERC20 ABI for token reads (balanceOf/allowance) and writes
// (approve/transfer). Use this — not CREDIT_GATE_ABI — for all ERC20 token
// operations so the vault ABI is never overloaded for token contract calls.
export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function transfer(address,uint256) returns (bool)",
] as const;
