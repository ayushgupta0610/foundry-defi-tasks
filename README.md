## Defi Tasks

**Just some legos to interact with OG Defi protocols**

The repo consists of the below Defi tasks:

- First task on Polygon with all V2
    - Take $1000 USDC and deposit in Aave V2
    - Borrow $500 worth of ETH from Aave V2
    - Swap ETH to USDC($500) via Uniswap V2
    - Deposit $500 USDC in Compound V3 (V2 doesn't exist on Polygon)

- Execute the first task on Ethereum with all Defi V3 protocols
  
- Second task on Ethereum with all V3 - Migrate $1000 position to compound by paying the debt using flash loan

  - First take a flash loan from Aave worth of $500 USDC
  - Repay debt of $500 USDC which was borrowed earlier as ETH
  - Withdraw $1000 USDC
  - Repay flash loan of $500 USDC + premium to Aave 
  - Deposit remaining about $500 USDC into compound - pending (This and supply in first task pending => 1000 USDC with the user) 
