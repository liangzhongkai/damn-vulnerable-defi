# Truster

More and more lending pools are offering flashloans. In this case, a new pool has launched that is offering flashloans of DVT tokens for free.

The pool holds 1 million DVT tokens. You have nothing.

To pass this challenge, rescue all funds in the pool executing a single transaction. Deposit the funds into the designated recovery account.


Truster 挑战 - 合约设计意图                                                                                                                                     
                                                                                                                                                                  
  TrusterLenderPool（借贷池）                                                                                                                                     
                                                                                                                                                                  
  这是一个闪电贷池，设计目的是：                                                                                                                                  
                                                                                                                                                                  
  1. 提供闪电贷服务：让用户可以无抵押借出 token，在同一交易中还款
  2. 支持回调机制：通过 target.functionCall(data) 让借款人可以在借款后执行自定义逻辑

  正常使用流程

  1. 用户调用 flashLoan(amount, borrower, target, data)
  2. Pool 把 token 转给 borrower
  3. Pool 调用 target 的回调函数
  4. 借款人在回调中做些操作（比如套利）
  5. 借款人把 token + 利息还给 Pool
  6. Pool 检查余额是否恢复

  设计缺陷

  target.functionCall(data) 的设计初衷是让借款人执行自定义逻辑（比如在 Uniswap 上套利）。

  但问题是：
  - 没有限制 target 和 data 的内容
  - 任何调用者都可以让 pool 执行任意调用
  - 这包括让 pool 执行 token.approve(攻击者, 所有余额)

  教训

  在设计闪电贷回调机制时，应该：
  1. 限制 target 只能是 borrower
  2. 或者限制可调用的函数白名单
  3. 或者完全移除这个功能（大多数闪电贷协议不提供这个功能）