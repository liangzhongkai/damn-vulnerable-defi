# Naive Receiver

There’s a pool with 1000 WETH in balance offering flash loans. It has a fixed fee of 1 WETH. The pool supports meta-transactions by integrating with a permissionless forwarder contract. 

A user deployed a sample contract with 10 WETH in balance. Looks like it can execute flash loans of WETH.

All funds are at risk! Rescue all WETH from the user and the pool, and deposit it into the designated recovery account.


Naive Receiver 系统设计                                                                      
                                               
  这个案例模拟了一个带元交易支持的闪电贷借贷池。                                               
                                                                                               
  1. NaiveReceiverPool（借贷池）                                                               
                                                                                               
  - 持有 1000 WETH，提供闪电贷服务                                                             
  - 固定手续费 1 WETH（不管借多少）
  - 用户可以存入 ETH 获得记账额度（deposits mapping）
  - 支持元交易（meta-transactions）

  2. FlashLoanReceiver（示例接收者合约）

  - 用户部署的示例合约，持有 10 WETH
  - 实现了 onFlashLoan 回调
  - 可以执行闪电贷（但没做什么实际操作）

  3. BasicForwarder（元交易转发器）

  - 允许用户离线签名交易，由别人代付 gas
  - 验证 EIP-712 签名
  - 将 from 地址附加到 calldata 末尾

  设计意图

  正常流程：
  1. 用户签名一个请求
  2. Forwarder 验证签名后代为执行
  3. Pool 通过 _msgSender() 识别真实调用者

  _msgSender() 的逻辑（第86-92行）：
  if (msg.sender == trustedForwarder && msg.data.length >= 20) {
      return address(bytes20(msg.data[msg.data.length - 20:]));  // 从 calldata 末尾读取
  } else {
      return super._msgSender();  // 普通调用
  }

  漏洞所在

  1. 固定手续费：每次闪电贷收费 1 WETH，可以对 FlashLoanReceiver 发起 10 次闪电贷，榨干它的 10
  WETH
  2. _msgSender() 可被操纵：通过 Forwarder 调用时，Pool 从 calldata 末尾读取调用者。如果用
  multicall 批量调用，可以伪造自己是任意地址（包括 Pool 本身），从而提取所有资金

  这个挑战的目标是：清空 Pool 的 1000 WETH 和 Receiver 的 10 WETH，总计 1010 WETH。