// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IChainlinkAggregator.sol";
import "./interfaces/IPancakeswapV2Pair.sol";
import "./interfaces/IERC20Detailed.sol";

contract KalmarBondingStrategy is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct UserBalance {
        uint256 avaliableAmount;
        uint256 lockAmount;
        uint256 lastUnlockTime;
    }

    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
    }

    struct BondingEmission {
        uint256 index;
        uint256 startBondingTime;
        uint256 endBondingTime;
        uint256 maxBondingSell;
        uint256 currentSold;
        uint256 discount;
    }
    // Kalmar Token
    address public constant kalm = 0x4BA0057f784858a48fe351445C672FF2a3d43515;
    address public constant chainlink = 0xcBb98864Ef56E9042e7d2efef76141f15731B82f; // pricefeed for token
    address public constant lp = 0xb7890ab80570750564a810eF6F214f1893Feb602; // kalm-busd
    // Buying Bond as token
    IERC20 public immutable stakingToken;
    // Treasury address
    address public immutable treasury;
    // Duration of lock period
    uint256 public constant lockDuration = 60 * 15;
    // Total kalm sold
    uint256 public totalBondSold;
    // Total burn of staking token
    uint256 public totalStakingBurn;
    // Sending staking token to burnAddress for buyback or burn
    address public burnAddress;

    uint256 public constant DISCOUNT_FACTOR = 1e6;
    uint256 public constant DISCOUNT_MAX = 80000;
    uint256 public constant BONDPERDAY_MAX = 5000000000000000000000; // max 5000 kalm
    uint256 public constant BONDPERDAY_MIN = 500000000000000000000; // min 500 kalm
    address admin;
    mapping(address => LockedBalance[]) private userLocks;
    BondingEmission[] public bondingEmission;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _stakingToken,
        uint256 _startBondingTime,
        uint256 _endBondingTime,
        uint256 _maxBondingSell,
        uint256 _discount,
        address _treasury
    ) public {
        stakingToken = IERC20(_stakingToken);
        treasury = _treasury;
        require(_endBondingTime > _startBondingTime, "endTime > startTime!");
        bondingEmission.push(
          BondingEmission({
                    index: 0,
                    startBondingTime: _startBondingTime,
                    endBondingTime: _endBondingTime,
                    maxBondingSell: _maxBondingSell,
                    currentSold: 0,
                    discount: _discount
                })
        );
    }

    /**
     * @notice Checks if the msg.sender is a contract or a proxy
     */
    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    /* ========== VIEWS ========== */
    function emissionIndex() external view returns (uint256) {
        uint256 length = bondingEmission.length;
        return length-1;
    }

    function usdPrice() external view returns (uint256) {
        return _usdTokenPrice();
    }

    function kalmPriceInUSD() external view returns (uint256) {
        return _kalmPrice();
    }

    function bondPriceInUSD() external view returns (uint256) {
        return _bondPrice();
    }

    function lpPriceInUSD() external view returns (uint256) {
        return _getLpPrice();
    }

    function calculateBondPerToken(uint256 amount) external view returns (uint256) {
        return _calculateBondPerToken(amount);
    }

    function userBalance(address user) external view returns (UserBalance memory balance) {
      LockedBalance[] storage locks = userLocks[user];
      /* UserBalance memory balance; */
      uint256 amountAvaliable;
      uint256 amountLock;
      uint256 lastTimeLock;
      uint256 length = locks.length;

      for (uint i = 0; i < length; i++) {
          if (locks[i].unlockTime > block.timestamp){
            amountLock = amountLock.add(locks[i].amount);
            lastTimeLock = locks[i].unlockTime;
          }else{
            amountAvaliable = amountAvaliable.add(locks[i].amount);
          }
      }

      balance.avaliableAmount = amountAvaliable;
      balance.lockAmount = amountLock;
      balance.lastUnlockTime = lastTimeLock;
      return balance;
    }

    function userLockedBalance(address user) external view returns (LockedBalance[] memory locked) {
      LockedBalance[] storage locks = userLocks[user];
      return locks;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function buy(uint256 amount) external nonReentrant notContract whenNotPaused {
      require(amount > 0, "Amount cannot be 0");
      stakingToken.safeTransferFrom(msg.sender, address(this), amount);
      // calculate bond per staking token amount
      uint256 userBondValue = _calculateBondPerToken(amount);
      uint256 length = bondingEmission.length;
      require(block.timestamp < bondingEmission[length-1].endBondingTime, "Ended bond sell");
      require(bondingEmission[length-1].currentSold + userBondValue <=  bondingEmission[length-1].maxBondingSell, "Over bonding limit amount");
      // get kalm to from treasury for vest
      IERC20(kalm).safeTransferFrom(treasury, address(this), userBondValue);
      totalBondSold += userBondValue;
      userLocks[msg.sender].push(LockedBalance({amount: userBondValue, unlockTime: block.timestamp + lockDuration}));
      bondingEmission[length-1].currentSold += userBondValue;
      // send stakingToken to burn address
      _burn(amount);

      emit Buy(msg.sender, amount);

    }

    function claim() public nonReentrant {
      LockedBalance[] storage locks = userLocks[msg.sender];
      uint256 amountAvaliable;
      uint256 length = locks.length;

      for (uint i = 0; i < length; i++) {
          if (locks[i].unlockTime <= block.timestamp){
            amountAvaliable = amountAvaliable.add(locks[i].amount);
            delete locks[i];
          }else{
            break;
          }
      }

      IERC20(kalm).safeTransfer(msg.sender, amountAvaliable);
      emit Claim(msg.sender, amountAvaliable);

    }

    function updateBondingEmission(
      uint256 _startBondingTime,
      uint256 _endBondingTime,
      uint256 _maxBondingSell,
      uint256 _discount
    ) external onlyOwner {
        uint256 length = bondingEmission.length;
        require(_maxBondingSell < BONDPERDAY_MAX && _maxBondingSell >= BONDPERDAY_MIN, "Bond sell in limit amount.");
        /* require(block.timestamp > bondingEmission[length-1].endBondingTime, "Not finished last bonding time yet."); */
        require(_endBondingTime > _startBondingTime, "endTime > startTime!");
        bondingEmission.push(
          BondingEmission({
                    index: length,
                    startBondingTime: _startBondingTime,
                    endBondingTime: _endBondingTime,
                    maxBondingSell: _maxBondingSell,
                    currentSold: 0,
                    discount: _discount
                })
        );
        emit UpdatedBondingEmission(length,_startBondingTime,_endBondingTime,_maxBondingSell);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function _usdTokenPrice() internal view returns (uint256) {
      int256 ans = IChainlinkAggregator(chainlink).latestAnswer();
      uint256 price = uint256(ans).mul(1e10);
      return price;
      /* uint256 price = 1e18;
      return price; */
    }

    function _kalmPrice() internal view returns (uint256) {
        IPancakeswapV2Pair pair = IPancakeswapV2Pair(lp);
        address other = pair.token0() == kalm ? pair.token1() : pair.token0();
        (uint256 Res0, uint256 Res1, ) = pair.getReserves();
        (uint256 kalmReserve, uint256 otherReserve) = pair.token0() == kalm ? (Res0, Res1) : (Res1, Res0);
        uint256 decimalsOther = IERC20Detailed(other).decimals();
        // amount
        uint256 otherPERkalm = (1e18*otherReserve)/kalmReserve;
        uint256 kalmPrice = (otherPERkalm*_usdTokenPrice())/(10**decimalsOther);

        return kalmPrice;
    }

    function _bondPrice() internal view returns (uint256) {
      uint256 length = bondingEmission.length;
      uint256 priceDiscount = _kalmPrice().mul(bondingEmission[length-1].discount).div(DISCOUNT_FACTOR);
      uint256 bondPrice = _kalmPrice() - priceDiscount;
      return bondPrice;
    }

    function _getLpPrice() internal view returns(uint256)
    {
      IPancakeswapV2Pair pair = IPancakeswapV2Pair(lp);
      address other = pair.token0() == kalm ? pair.token1() : pair.token0();
      (uint256 Res0, uint256 Res1,) = pair.getReserves();
      (uint256 kalmReserve, uint256 otherReserve) = pair.token0() == kalm ? (Res0, Res1) : (Res1, Res0);
      uint256 decimalsOther = IERC20Detailed(other).decimals();

      uint totalSupply = pair.totalSupply();
      uint256 totalOtherPrice = ((otherReserve*1e18)/(10**decimalsOther)) * _usdTokenPrice();
      uint256 totalKalmPrice = kalmReserve * _kalmPrice();

      uint256 lpPrice = (totalOtherPrice + totalKalmPrice) / totalSupply;
      return lpPrice;
    }

    function _calculateBondPerToken(uint256 _amount) internal view returns (uint256) {
      uint256 buyAmountUsd = _amount.mul(_getLpPrice());
      uint256 amountBond = buyAmountUsd.div(_bondPrice());
      return amountBond;
    }

    function _burn(uint256 _amount) internal {
      totalStakingBurn += _amount;
      stakingToken.safeTransfer(burnAddress, _amount);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /**
     * @notice Sets burn address
     * @dev Only callable by the contract admin.
     */
    function setBurnAddress(address _burnAddr) external onlyOwner {
        burnAddress = _burnAddr;
        emit BurnAddressSet(_burnAddr);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
        emit Unpause();
    }

    /**
     * @notice Checks if address is a contract
     * @dev It prevents contract from being targetted
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /* ========== EVENTS ========== */

    event Buy(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event Recovered(address token, uint256 amount);
    event Pause();
    event Unpause();
    event BurnAddressSet(address burnAddress);
    event UpdatedBondingEmission(uint256 index, uint256 startTime, uint256 endTime, uint256 maxSell);
}