// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFairLaunch {
  function deposit(address _for, uint256 _pid, uint256 _amount) external;
  function withdraw(address _for, uint256 _pid, uint256 _amount) external;
  function harvest(uint256 _pid) external;
  function pendingAlpaca(uint256 _pid, address _user) external view returns (uint256);
  function userInfo(uint256 _pid, address _userAddress) external view returns (UserInfo memory _userInfo);
  function poolInfo(uint256 _index) external view returns (PoolInfo memory _poolInfo);
  function stakingToken(uint256 _index) external view returns (IERC20 _token);
  function ALPACA() external view returns (IERC20 _alpacaToken);

  struct UserInfo {
    uint256 amount;
    int256 rewardDebt;
  }

  struct PoolInfo {
    uint128 accAlpacaPerShare;
    uint64 lastRewardTime;
    uint64 allocPoint;
    bool isDebtTokenPool;
  }
}
