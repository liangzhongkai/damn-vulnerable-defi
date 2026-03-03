# Side Entrance

A surprisingly simple pool allows anyone to deposit ETH, and withdraw it at any point in time.

It has 1000 ETH in balance already, and is offering free flashloans using the deposited ETH to promote their system.

You start with 1 ETH in balance. Pass the challenge by rescuing all ETH from the pool and depositing it in the designated recovery account.

Side Entrance 合约分析
  这是一个闪电贷池合约，提供以下功能：
  主要功能
  ┌───────────────────┬────────────────────────────┐
  │       函数        │            作用             │
  ├───────────────────┼────────────────────────────┤
  │ deposit()         │ 存入 ETH，记录用户余额       │
  ├───────────────────┼────────────────────────────┤
  │ withdraw()        │ 提取用户存入的 ETH          │
  ├───────────────────┼────────────────────────────┤
  │ flashLoan(amount) │ 闪电贷，借出指定数量的 ETH   │
  └───────────────────┴────────────────────────────┘

  闪电贷逻辑 (第 35-43 行)

  function flashLoan(uint256 amount) external {
      uint256 balanceBefore = address(this).balance;  // 记录借款前余额

      IFlashLoanEtherReceiver(msg.sender).execute{value: amount}();  // 借出 ETH

      if (address(this).balance < balanceBefore) {  // 检查余额是否恢复
          revert RepayFailed();
      }
  }

  漏洞点

  合约只检查合约余额是否恢复到借款前水平，但没有验证资金是如何回来的。

  攻击者可以利用 deposit() 作为还款方式：
  1. 调用 flashLoan() 借出 ETH
  2. 在 execute() 回调中调用 deposit() 把借来的 ETH 存入
  3. 闪电贷检查通过（合约余额恢复了）
  4. 但此时攻击者的 balances 被记入了这笔存款
  5. 攻击者调用 withdraw() 把池子的资金全部取走

  这就是 Side Entrance（侧门）攻击 —— 通过合法的存款入口来"偿还"闪电贷，绕过了还款检查。