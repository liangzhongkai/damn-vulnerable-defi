# Unstoppable

There's a tokenized vault with a million DVT tokens deposited. It’s offering flash loans for free, until the grace period ends.

To catch any bugs before going 100% permissionless, the developers decided to run a live beta in testnet. There's a monitoring contract to check liveness of the flashloan feature.

Starting with 10 DVT tokens in balance, show that it's possible to halt the vault. It must stop offering flash loans.


这个案例模拟了一个带监控的闪电贷金库系统。                                                   
                                                                                             
  系统架构                                                                                     
                                               
  1. UnstoppableVault（金库）                                                                  
                                                                                               
  - 是一个 ERC4626 代币化金库
  - 用户可以存入 DamnValuableToken，获得 vault shares
  - 提供闪电贷服务（零费用，用于监控检查时）
  - 正常借贷有 0.05% 手续费（借满额时收取高额费用）

  2. UnstoppableMonitor（监控合约）

  - 由 deployer 控制
  - 定期调用 checkFlashLoan() 检查闪电贷是否正常工作
  - 如果闪电贷失败，说明金库出问题了：
    - 暂停金库（setPause(true)）
    - 转移所有权给 deployer 以便修复

  设计意图

  这是一个安全监控系统的思路：

  正常情况：
  Monitor --检查--> Vault.flashLoan() 成功 --> 一切正常

  异常情况：
  Monitor --检查--> Vault.flashLoan() 失败 --> 暂停 + 转移所有权

  漏洞所在

  Vault 的 flashLoan 有一个" sanity check"（健全性检查）：

  if (convertToShares(totalSupply) != balanceBefore) revert InvalidBalance();

  设计者想确保 shares 和实际资产保持同步。但问题是：

  直接转账（不走 deposit）会打破这个同步，导致闪电贷永久失效，监控系统会把正常 vault
  误判为"出问题"并关停它。

  这就是为什么叫 "Unstoppable" — 本意是想让 vault
  不可被阻止，但实际上一笔简单的转账就能让它停摆。