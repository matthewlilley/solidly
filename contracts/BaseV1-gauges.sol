// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

library Math {
    function max(uint a, uint b) internal pure returns (uint) {
        return a >= b ? a : b;
    }
    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}

interface erc20 {
    function totalSupply() external view returns (uint256);
    function transfer(address recipient, uint amount) external returns (bool);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
}

interface ve {
    function token() external view returns (address);
    function balanceOfNFT(uint) external view returns (uint);
    function isApprovedOrOwner(address, uint) external view returns (bool);
    function ownerOf(uint) external view returns (address);
    function transferFrom(address, address, uint) external;
}

interface IBaseV1Factory {
    function isPair(address) external view returns (bool);
}

// Gauges are used to incentivize pools, they emit reward tokens over 7 days for staked LP tokens
// Nuance: getReward must be called at least once for tokens other than incentive[0] to start accrueing rewards
contract Gauge {

    address public immutable stake; // the LP token that needs to be staked for rewards
    address immutable _ve; // the ve token used for gauges

    uint public derivedSupply;
    mapping(address => uint) public derivedBalances;

    uint constant DURATION = 7 days; // rewards are released over 7 days
    uint constant PRECISION = 10 ** 18;

    // default snx staking contract implementation
    mapping(address => uint) public rewardRate;
    mapping(address => uint) public periodFinish;
    mapping(address => uint) public lastUpdateTime;
    mapping(address => uint) public rewardPerTokenStored;

    mapping(address => mapping(address => uint)) public lastEarn;

    mapping(address => uint) public tokenIds;

    uint public totalSupply;
    mapping(address => uint) public balanceOf;

    /// @notice A checkpoint for marking balance
   struct Checkpoint {
       uint timestamp;
       uint balanceOf;
   }

  /// @notice A checkpoint for marking reward rate
 struct RewardPerTokenCheckpoint {
     uint timestamp;
     uint rewardPerToken;
 }

  /// @notice A checkpoint for marking supply
 struct SupplyCheckpoint {
     uint timestamp;
     uint supply;
 }

   /// @notice A record of balance checkpoints for each account, by index
   mapping (address => mapping (uint => Checkpoint)) public checkpoints;

   /// @notice The number of checkpoints for each account
   mapping (address => uint) public numCheckpoints;

   /// @notice A record of balance checkpoints for each token, by index
   mapping (uint => SupplyCheckpoint) public supplyCheckpoints;

   /// @notice The number of checkpoints
   uint public supplyNumCheckpoints;

   /// @notice A record of balance checkpoints for each token, by index
   mapping (address => mapping (uint => RewardPerTokenCheckpoint)) public rewardPerTokenCheckpoints;

   /// @notice The number of checkpoints for each token
   mapping (address => uint) public rewardPerTokenNumCheckpoints;

    // simple re-entrancy check
    uint _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(address _stake) {
        stake = _stake;
        address __ve = BaseV1Gauges(msg.sender)._ve();
        _ve = __ve;
    }

    /**
     * @notice Determine the prior balance for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param timestamp The timestamp to get the balance at
     * @return The balance the account had as of the given block
     */
    function getPriorBalanceIndex(address account, uint timestamp) public view returns (uint) {
        uint nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].timestamp > timestamp) {
            return 0;
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorSupplyIndex(uint timestamp) public view returns (uint) {
        uint nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorRewardPerToken(address token, uint timestamp) public view returns (uint, uint) {
        uint nCheckpoints = rewardPerTokenNumCheckpoints[token];
        if (nCheckpoints == 0) {
            return (0,0);
        }

        // First check most recent balance
        if (rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp <= timestamp) {
            return (rewardPerTokenCheckpoints[token][nCheckpoints - 1].rewardPerToken, rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp);
        }

        // Next check implicit zero balance
        if (rewardPerTokenCheckpoints[token][0].timestamp > timestamp) {
            return (0,0);
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            RewardPerTokenCheckpoint memory cp = rewardPerTokenCheckpoints[token][center];
            if (cp.timestamp == timestamp) {
                return (cp.rewardPerToken, cp.timestamp);
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return (rewardPerTokenCheckpoints[token][lower].rewardPerToken, rewardPerTokenCheckpoints[token][lower].timestamp);
    }

    function _writeCheckpoint(address account, uint balance) internal {
      uint _timestamp = block.timestamp;
      uint _nCheckPoints = numCheckpoints[account];

      if (_nCheckPoints > 0 && checkpoints[account][_nCheckPoints - 1].timestamp == _timestamp) {
          checkpoints[account][_nCheckPoints - 1].balanceOf = balance;
      } else {
          checkpoints[account][_nCheckPoints] = Checkpoint(_timestamp, balance);
          numCheckpoints[account] = _nCheckPoints + 1;
      }
    }

    function _writeRewardPerTokenCheckpoint(address token, uint reward, uint timestamp) internal {
      uint _nCheckPoints = rewardPerTokenNumCheckpoints[token];

      if (_nCheckPoints > 0 && rewardPerTokenCheckpoints[token][_nCheckPoints - 1].timestamp == timestamp) {
        rewardPerTokenCheckpoints[token][_nCheckPoints - 1].rewardPerToken = reward;
      } else {
          rewardPerTokenCheckpoints[token][_nCheckPoints] = RewardPerTokenCheckpoint(timestamp, reward);
          rewardPerTokenNumCheckpoints[token] = _nCheckPoints + 1;
      }
    }

    function _writeSupplyCheckpoint() internal {
      uint _nCheckPoints = supplyNumCheckpoints;
      uint _timestamp = block.timestamp;

      if (_nCheckPoints > 0 && supplyCheckpoints[_nCheckPoints - 1].timestamp == _timestamp) {
        supplyCheckpoints[_nCheckPoints - 1].supply = derivedSupply;
      } else {
          supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, derivedSupply);
          supplyNumCheckpoints = _nCheckPoints + 1;
      }
    }

    // returns the last time the reward was modified or periodFinish if the reward has ended
    function lastTimeRewardApplicable(address token) public view returns (uint) {
        return Math.min(block.timestamp, periodFinish[token]);
    }

    // total amount of rewards returned for the 7 day duration
    function getRewardForDuration(address token) external view returns (uint) {
        return rewardRate[token] * DURATION;
    }

    function getReward(address token) external lock {
      uint _reward = earned(token, msg.sender);
      lastEarn[token][msg.sender] = block.timestamp;
      if (_reward > 0) _safeTransfer(token, msg.sender, _reward);

      uint _derivedBalance = derivedBalances[msg.sender];
      derivedSupply -= _derivedBalance;
      _derivedBalance = derivedBalance(msg.sender);
      derivedBalances[msg.sender] = _derivedBalance;
      derivedSupply += _derivedBalance;

      _writeCheckpoint(msg.sender, derivedBalances[msg.sender]);
      _writeSupplyCheckpoint();
    }


    function rewardPerToken(address token) public view returns (uint) {
        if (derivedSupply == 0) {
            return rewardPerTokenStored[token];
        }
        return rewardPerTokenStored[token] + ((lastTimeRewardApplicable(token) - lastUpdateTime[token]) * rewardRate[token] * PRECISION / derivedSupply);
    }

    function derivedBalance(address account) public view returns (uint) {
        uint _tokenId = tokenIds[account];
        uint _balance = balanceOf[account];
        uint _derived = _balance * 40 / 100;
        uint _adjusted = 0;
        if (account == ve(_ve).ownerOf(_tokenId)) {
            _adjusted = ve(_ve).balanceOfNFT(_tokenId);
            _adjusted = (totalSupply * _adjusted / erc20(_ve).totalSupply()) * 60 / 100;
        }
        return Math.min(_derived + _adjusted, _balance);
    }

    function updateRewardPerToken(address token) public view returns (uint) {
        uint _startTimestamp = lastUpdateTime[token];
        uint reward = rewardPerTokenStored[token];

        if (supplyNumCheckpoints == 0) {
            return reward;
        }

        uint _startIndex = getPriorSupplyIndex(_startTimestamp);
        uint _endIndex = supplyNumCheckpoints-1;
        uint _rewardRate = rewardRate[token];

        if (_endIndex - _startIndex > 1) {
            for (uint i = _startIndex; i < _endIndex-1; i++) {
                SupplyCheckpoint memory sp0 = supplyCheckpoints[i];
                if (i == _startIndex) {
                    sp0.timestamp = Math.max(sp0.timestamp, _startTimestamp);
                }
                SupplyCheckpoint memory sp1 = supplyCheckpoints[i+1];
                if (_rewardRate > 0 && sp0.supply > 0) {
                  reward += ((sp1.timestamp - sp0.timestamp) * _rewardRate * PRECISION / sp0.supply);
                }
            }
        }

        SupplyCheckpoint memory sp = supplyCheckpoints[_endIndex];
        if (_endIndex == _startIndex) {
            sp.timestamp = Math.max(sp.timestamp, _startTimestamp);
        }
        if (_rewardRate > 0 && sp.supply > 0) {
            reward += ((lastTimeRewardApplicable(token) - sp.timestamp) * _rewardRate * PRECISION / sp.supply);
        }

        return reward;
    }

    function earned(address token, address account) public view returns (uint) {
        uint _startTimestamp = lastEarn[token][account];
        if (numCheckpoints[account] == 0) {
            return 0;
        }

        uint _startIndex = getPriorBalanceIndex(account, _startTimestamp);
        uint _endIndex = numCheckpoints[account]-1;

        uint reward = 0;

        if (_endIndex - _startIndex > 1) {
            for (uint i = _startIndex; i < _endIndex-1; i++) {
                Checkpoint memory cp0 = checkpoints[account][i];
                Checkpoint memory cp1 = checkpoints[account][i+1];
                (uint _rewardPerTokenStored0,) = getPriorRewardPerToken(token, cp0.timestamp);
                (uint _rewardPerTokenStored1,) = getPriorRewardPerToken(token, cp1.timestamp);
                if (_rewardPerTokenStored0 > 0) {
                  reward += (cp0.balanceOf * _rewardPerTokenStored1 - _rewardPerTokenStored0) / PRECISION;
                }
            }
        }

        Checkpoint memory cp = checkpoints[account][_endIndex];
        (uint _rewardPerTokenStored,) = getPriorRewardPerToken(token, cp.timestamp);
        if (_rewardPerTokenStored > 0) {
            reward += cp.balanceOf * (rewardPerToken(token) - _rewardPerTokenStored / PRECISION);
        }

        return reward;
    }

    function deposit(uint tokenId) external {
        _deposit(erc20(stake).balanceOf(msg.sender), tokenId);
    }

    function deposit(uint amount, uint tokenId) external {
        _deposit(amount, tokenId);
    }

    function deposit_test(uint amount, uint tokenId) external {
        _deposit(amount, tokenId);
    }

    function _deposit(uint amount, uint tokenId) internal lock {
        tokenIds[msg.sender] = tokenId;
        _safeTransferFrom(stake, msg.sender, address(this), amount);
        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        uint _derivedBalance = derivedBalances[msg.sender];
        derivedSupply -= _derivedBalance;
        _derivedBalance = derivedBalance(msg.sender);
        derivedBalances[msg.sender] = _derivedBalance;
        derivedSupply += _derivedBalance;

        _writeCheckpoint(msg.sender, derivedBalances[msg.sender]);
        _writeSupplyCheckpoint();
    }

    function withdraw() external {
        _withdraw(balanceOf[msg.sender]);
    }

    function withdraw(uint amount) external {
        _withdraw(amount);
    }

    function _withdraw(uint amount) internal lock {
        tokenIds[msg.sender] = 0;
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        _safeTransfer(stake, msg.sender, amount);

        uint _derivedBalance = derivedBalances[msg.sender];
        derivedSupply -= _derivedBalance;
        _derivedBalance = derivedBalance(msg.sender);
        derivedBalances[msg.sender] = _derivedBalance;
        derivedSupply += _derivedBalance;

        _writeCheckpoint(msg.sender, derivedBalances[msg.sender]);
        _writeSupplyCheckpoint();
    }

    function notifyRewardAmount(address token, uint amount) external lock {
        rewardPerTokenStored[token] = updateRewardPerToken(token);
        lastUpdateTime[token] = block.timestamp;
        _writeRewardPerTokenCheckpoint(token, rewardPerTokenStored[token], lastUpdateTime[token]);

        if (block.timestamp >= periodFinish[token]) {
            _safeTransferFrom(token, msg.sender, address(this), amount);
            rewardRate[token] = amount / DURATION;
        } else {
            uint _remaining = periodFinish[token] - block.timestamp;
            uint _left = _remaining * rewardRate[token];
            require(amount > _left);
            _safeTransferFrom(token, msg.sender, address(this), amount);
            rewardRate[token] = (amount + _left) / DURATION;
        }
        periodFinish[token] = block.timestamp + DURATION;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}

// Bribes pay out rewards for a given pool based on the votes that were received from the user (goes hand in hand with BaseV1Gauges.vote())
// Nuance: users must call updateReward after they voted for a given bribe
contract Bribe {

    address immutable factory; // only factory can modify balances (since it only happens on vote())
    address immutable _ve;

    uint constant DURATION = 7 days; // rewards are released over 7 days
    uint constant PRECISION = 10 ** 18;

    // default snx staking contract implementation
    mapping(address => uint) public rewardRate;
    mapping(address => uint) public periodFinish;
    mapping(address => uint) public lastUpdateTime;
    mapping(address => uint) public rewardPerTokenStored;

    mapping(address => mapping(uint => uint)) public lastEarn;

    uint public totalSupply;
    mapping(uint => uint) public balanceOf;

    /// @notice A checkpoint for marking balance
   struct Checkpoint {
       uint timestamp;
       uint balanceOf;
   }

  /// @notice A checkpoint for marking reward rate
 struct RewardPerTokenCheckpoint {
     uint timestamp;
     uint rewardPerToken;
 }

  /// @notice A checkpoint for marking supply
 struct SupplyCheckpoint {
     uint timestamp;
     uint supply;
 }

   /// @notice A record of balance checkpoints for each account, by index
   mapping (uint => mapping (uint => Checkpoint)) public checkpoints;

   /// @notice The number of checkpoints for each account
   mapping (uint => uint) public numCheckpoints;

   /// @notice A record of balance checkpoints for each token, by index
   mapping (uint => SupplyCheckpoint) public supplyCheckpoints;

   /// @notice The number of checkpoints
   uint public supplyNumCheckpoints;

   /// @notice A record of balance checkpoints for each token, by index
   mapping (address => mapping (uint => RewardPerTokenCheckpoint)) public rewardPerTokenCheckpoints;

   /// @notice The number of checkpoints for each token
   mapping (address => uint) public rewardPerTokenNumCheckpoints;

    // simple re-entrancy check
    uint _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    /**
     * @notice Determine the prior balance for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param tokenId The token of the NFT to check
     * @param timestamp The timestamp to get the balance at
     * @return The balance the account had as of the given block
     */
    function getPriorBalanceIndex(uint tokenId, uint timestamp) public view returns (uint) {
        uint nCheckpoints = numCheckpoints[tokenId];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[tokenId][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (checkpoints[tokenId][0].timestamp > timestamp) {
            return 0;
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[tokenId][center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorSupplyIndex(uint timestamp) public view returns (uint) {
        uint nCheckpoints = supplyNumCheckpoints;
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (supplyCheckpoints[nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }

        // Next check implicit zero balance
        if (supplyCheckpoints[0].timestamp > timestamp) {
            return 0;
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            SupplyCheckpoint memory cp = supplyCheckpoints[center];
            if (cp.timestamp == timestamp) {
                return center;
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getPriorRewardPerToken(address token, uint timestamp) public view returns (uint, uint) {
        uint nCheckpoints = rewardPerTokenNumCheckpoints[token];
        if (nCheckpoints == 0) {
            return (0,0);
        }

        // First check most recent balance
        if (rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp <= timestamp) {
            return (rewardPerTokenCheckpoints[token][nCheckpoints - 1].rewardPerToken, rewardPerTokenCheckpoints[token][nCheckpoints - 1].timestamp);
        }

        // Next check implicit zero balance
        if (rewardPerTokenCheckpoints[token][0].timestamp > timestamp) {
            return (0,0);
        }

        uint lower = 0;
        uint upper = nCheckpoints - 1;
        while (upper > lower) {
            uint center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            RewardPerTokenCheckpoint memory cp = rewardPerTokenCheckpoints[token][center];
            if (cp.timestamp == timestamp) {
                return (cp.rewardPerToken, cp.timestamp);
            } else if (cp.timestamp < timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return (rewardPerTokenCheckpoints[token][lower].rewardPerToken, rewardPerTokenCheckpoints[token][lower].timestamp);
    }

    function _writeCheckpoint(uint tokenId, uint balance) internal {
      uint _timestamp = block.timestamp;
      uint _nCheckPoints = numCheckpoints[tokenId];

      if (_nCheckPoints > 0 && checkpoints[tokenId][_nCheckPoints - 1].timestamp == _timestamp) {
          checkpoints[tokenId][_nCheckPoints - 1].balanceOf = balance;
      } else {
          checkpoints[tokenId][_nCheckPoints] = Checkpoint(_timestamp, balance);
          numCheckpoints[tokenId] = _nCheckPoints + 1;
      }
    }

    function _writeRewardPerTokenCheckpoint(address token, uint reward, uint timestamp) internal {
      uint _nCheckPoints = rewardPerTokenNumCheckpoints[token];

      if (_nCheckPoints > 0 && rewardPerTokenCheckpoints[token][_nCheckPoints - 1].timestamp == timestamp) {
        rewardPerTokenCheckpoints[token][_nCheckPoints - 1].rewardPerToken = reward;
      } else {
          rewardPerTokenCheckpoints[token][_nCheckPoints] = RewardPerTokenCheckpoint(timestamp, reward);
          rewardPerTokenNumCheckpoints[token] = _nCheckPoints + 1;
      }
    }

    function _writeSupplyCheckpoint() internal {
      uint _nCheckPoints = supplyNumCheckpoints;
      uint _timestamp = block.timestamp;

      if (_nCheckPoints > 0 && supplyCheckpoints[_nCheckPoints - 1].timestamp == _timestamp) {
        supplyCheckpoints[_nCheckPoints - 1].supply = totalSupply;
      } else {
          supplyCheckpoints[_nCheckPoints] = SupplyCheckpoint(_timestamp, totalSupply);
          supplyNumCheckpoints = _nCheckPoints + 1;
      }
    }

    // returns the last time the reward was modified or periodFinish if the reward has ended
    function lastTimeRewardApplicable(address token) public view returns (uint) {
        return Math.min(block.timestamp, periodFinish[token]);
    }

    // total amount of rewards returned for the 7 day duration
    function getRewardForDuration(address token) external view returns (uint) {
        return rewardRate[token] * DURATION;
    }

    // allows a user to claim rewards for a given token
    function getReward(uint tokenId, address token) public lock  {
        require(ve(_ve).isApprovedOrOwner(msg.sender, tokenId));
        uint _reward = earned(token, tokenId);
        lastEarn[token][tokenId] = block.timestamp;
        if (_reward > 0) _safeTransfer(token, msg.sender, _reward);
    }

    constructor() {
        factory = msg.sender;
        _ve = BaseV1Gauges(msg.sender)._ve();
    }

    function rewardPerToken(address token) public view returns (uint) {
        if (totalSupply == 0) {
            return rewardPerTokenStored[token];
        }
        return rewardPerTokenStored[token] + ((lastTimeRewardApplicable(token) - lastUpdateTime[token]) * rewardRate[token] * PRECISION / totalSupply);
    }

    function updateRewardPerToken(address token) public view returns (uint) {
        uint _startTimestamp = lastUpdateTime[token];
        uint reward = rewardPerTokenStored[token];

        if (supplyNumCheckpoints == 0) {
            return reward;
        }

        uint _startIndex = getPriorSupplyIndex(_startTimestamp);
        uint _endIndex = supplyNumCheckpoints-1;
        uint _rewardRate = rewardRate[token];

        if (_endIndex - _startIndex > 1) {
            for (uint i = _startIndex; i < _endIndex-1; i++) {
                SupplyCheckpoint memory sp0 = supplyCheckpoints[i];
                if (i == _startIndex) {
                    sp0.timestamp = Math.max(sp0.timestamp, _startTimestamp);
                }
                SupplyCheckpoint memory sp1 = supplyCheckpoints[i+1];
                if (_rewardRate > 0 && sp0.supply > 0) {
                  reward += ((sp1.timestamp - sp0.timestamp) * _rewardRate * PRECISION / sp0.supply);
                }
            }
        }

        SupplyCheckpoint memory sp = supplyCheckpoints[_endIndex];
        if (_endIndex == _startIndex) {
            sp.timestamp = Math.max(sp.timestamp, _startTimestamp);
        }
        if (_rewardRate > 0 && sp.supply > 0) {
            reward += ((lastTimeRewardApplicable(token) - sp.timestamp) * _rewardRate * PRECISION / sp.supply);
        }

        return reward;
    }

    function earned(address token, uint tokenId) public view returns (uint) {
        uint _startTimestamp = lastEarn[token][tokenId];
        if (numCheckpoints[tokenId] == 0) {
            return 0;
        }

        uint _startIndex = getPriorBalanceIndex(tokenId, _startTimestamp);
        uint _endIndex = numCheckpoints[tokenId]-1;

        uint reward = 0;

        if (_endIndex - _startIndex > 1) {
            for (uint i = _startIndex; i < _endIndex-1; i++) {
                Checkpoint memory cp0 = checkpoints[tokenId][i];
                Checkpoint memory cp1 = checkpoints[tokenId][i+1];
                (uint _rewardPerTokenStored0,) = getPriorRewardPerToken(token, cp0.timestamp);
                (uint _rewardPerTokenStored1,) = getPriorRewardPerToken(token, cp1.timestamp);
                if (_rewardPerTokenStored0 > 0) {
                  reward += (cp0.balanceOf * _rewardPerTokenStored1 - _rewardPerTokenStored0) / PRECISION;
                }
            }
        }

        Checkpoint memory cp = checkpoints[tokenId][_endIndex];
        (uint _rewardPerTokenStored,) = getPriorRewardPerToken(token, cp.timestamp);
        if (_rewardPerTokenStored > 0) {
            reward += cp.balanceOf * (rewardPerToken(token) - _rewardPerTokenStored / PRECISION);
        }

        return reward;
    }

    // This is an external function, but internal notation is used since it can only be called "internally" from BaseV1Gauges
    function _deposit(uint amount, uint tokenId) external {
        require(msg.sender == factory);
        totalSupply += amount;
        balanceOf[tokenId] += amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();
    }

    function _withdraw(uint amount, uint tokenId) external {
        require(msg.sender == factory);
        totalSupply -= amount;
        balanceOf[tokenId] -= amount;

        _writeCheckpoint(tokenId, balanceOf[tokenId]);
        _writeSupplyCheckpoint();
    }

    // used to notify a gauge/bribe of a given reward, this can create griefing attacks by extending rewards
    // TODO: rework to weekly resets, _updatePeriod as per v1 bribes
    function notifyRewardAmount(address token, uint amount) external lock {
        rewardPerTokenStored[token] = updateRewardPerToken(token);
        lastUpdateTime[token] = block.timestamp;
        _writeRewardPerTokenCheckpoint(token, rewardPerTokenStored[token], lastUpdateTime[token]);

        if (block.timestamp >= periodFinish[token]) {
            _safeTransferFrom(token, msg.sender, address(this), amount);
            rewardRate[token] = amount / DURATION;
        } else {
            uint _remaining = periodFinish[token] - block.timestamp;
            uint _left = _remaining * rewardRate[token];
            require(amount > _left);
            _safeTransferFrom(token, msg.sender, address(this), amount);
            rewardRate[token] = (amount + _left) / DURATION;
        }
        periodFinish[token] = block.timestamp + DURATION;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}

contract BaseV1Gauges {

    address public immutable _ve; // the ve token that governs these contracts
    address public immutable factory; // the BaseV1Factory
    address public immutable base;

    uint public totalWeight; // total voting weight

    // simple re-entrancy check
    uint _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    address[] internal _pools; // all pools viable for incentives
    mapping(address => address) public gauges; // pool => gauge
    mapping(address => address) public poolForGauge; // pool => gauge
    mapping(address => address) public bribes; // gauge => bribe
    mapping(address => uint) public weights; // pool => weight
    mapping(uint => mapping(address => uint)) public votes; // nft => votes
    mapping(uint => address[]) public poolVote;// nft => pools
    mapping(uint => uint) public usedWeights;  // nft => total voting weight of user

    function pools() external view returns (address[] memory) {
        return _pools;
    }

    constructor(address __ve, address _factory) {
        _ve = __ve;
        factory = _factory;
        base = ve(__ve).token();
    }

    function reset(uint _tokenId) external {
        _reset(_tokenId);
    }

    function _reset(uint _tokenId) internal {
        address[] storage _poolVote = poolVote[_tokenId];
        uint _poolVoteCnt = _poolVote.length;

        for (uint i = 0; i < _poolVoteCnt; i ++) {
            address _pool = _poolVote[i];
            uint _votes = votes[_tokenId][_pool];

            if (_votes > 0) {
                _updateFor(gauges[_pool]);
                totalWeight -= _votes;
                weights[_pool] -= _votes;
                votes[_tokenId][_pool] = 0;
                Bribe(bribes[gauges[_pool]])._withdraw(_votes, _tokenId);
            }
        }

        delete poolVote[_tokenId];
    }

    function poke(uint _tokenId) public {
        address[] memory _poolVote = poolVote[_tokenId];
        uint _poolCnt = _poolVote.length;
        uint[] memory _weights = new uint[](_poolCnt);

        uint _prevUsedWeight = usedWeights[_tokenId];
        uint _weight = ve(_ve).balanceOfNFT(_tokenId);

        for (uint i = 0; i < _poolCnt; i ++) {
            uint _prevWeight = votes[_tokenId][_poolVote[i]];
            _weights[i] = _prevWeight * _weight / _prevUsedWeight;
        }

        _vote(_tokenId, _poolVote, _weights);
    }

    function _vote(uint _tokenId, address[] memory _poolVote, uint[] memory _weights) internal {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        _reset(_tokenId);
        uint _poolCnt = _poolVote.length;
        uint _weight = ve(_ve).balanceOfNFT(_tokenId);
        uint _totalVoteWeight = 0;
        uint _usedWeight = 0;

        for (uint i = 0; i < _poolCnt; i ++) {
            _totalVoteWeight += _weights[i];
        }

        for (uint i = 0; i < _poolCnt; i ++) {
            address _pool = _poolVote[i];
            address _gauge = gauges[_pool];
            uint _poolWeight = _weights[i] * _weight / _totalVoteWeight;

            if (_gauge != address(0x0)) {
                _updateFor(_gauge);
                _usedWeight += _poolWeight;
                totalWeight += _poolWeight;
                weights[_pool] += _poolWeight;
                poolVote[_tokenId].push(_pool);
                votes[_tokenId][_pool] = _poolWeight;
                Bribe(bribes[_gauge])._deposit(_poolWeight, _tokenId);
            }
        }

        usedWeights[_tokenId] = _usedWeight;
    }

    function vote(uint tokenId, address[] calldata _poolVote, uint[] calldata _weights) external {
        require(_poolVote.length == _weights.length);
        _vote(tokenId, _poolVote, _weights);
    }

    function createGauge(address _pool) external returns (address) {
        require(gauges[_pool] == address(0x0), "exists");
        require(IBaseV1Factory(factory).isPair(_pool), "!_pool");
        address _gauge = address(new Gauge(_pool));
        address _bribe = address(new Bribe());
        bribes[_gauge] = _bribe;
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        _updateFor(_gauge);
        _pools.push(_pool);
        return _gauge;
    }

    function length() external view returns (uint) {
        return _pools.length;
    }

    uint public index;
    mapping(address => uint) public supplyIndex;
    mapping(address => uint) public claimable;

    // Accrue fees on token0
    function notifyRewardAmount(uint amount) public lock {
        _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in
        uint256 _ratio = amount * 1e18 / totalWeight; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
          index += _ratio;
        }
    }

    function updateFor(address _gauge) external {
        _updateFor(_gauge);
    }

    function _updateFor(address _gauge) internal {
        address _pool = poolForGauge[_gauge];
        uint _supplied = weights[_pool];
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];
            uint _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
              uint _share = _supplied * _delta / 1e18; // add accrued difference for each supplied token
              claimable[_gauge] += _share;
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }


    function distribute(address _gauge) public lock {
        uint _claimable = claimable[_gauge];
        claimable[_gauge] = 0;
        erc20(base).approve(_gauge, 0); // first set to 0, this helps reset some non-standard tokens
        erc20(base).approve(_gauge, _claimable);
        Gauge(_gauge).notifyRewardAmount(base, _claimable);
    }

    function distro() external {
        distribute(0, _pools.length);
    }

    function distribute() external {
        distribute(0, _pools.length);
    }

    function distribute(uint start, uint finish) public {
        for (uint x = start; x < finish; x++) {
            distribute(gauges[_pools[x]]);
        }
    }

    function distribute(address[] memory _gauges) external {
        for (uint x = 0; x < _gauges.length; x++) {
            distribute(_gauges[x]);
        }
    }

    function distributeEx(address token) external {
        distributeEx(token, 0, _pools.length);
    }

    // setup distro > then distribute

    function distributeEx(address token, uint start, uint finish) public lock {
        uint _balance = erc20(token).balanceOf(address(this));
        if (_balance > 0 && totalWeight > 0) {
            uint _totalWeight = totalWeight;
            for (uint x = start; x < finish; x++) {
              uint _reward = _balance * weights[_pools[x]] / _totalWeight;
              if (_reward > 0) {
                  address _gauge = gauges[_pools[x]];

                  erc20(token).approve(_gauge, 0); // first set to 0, this helps reset some non-standard tokens
                  erc20(token).approve(_gauge, _reward);
                  Gauge(_gauge).notifyRewardAmount(token, _reward); // can return false, will simply not distribute tokens
              }
            }
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
