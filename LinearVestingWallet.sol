// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LinearVestingWallet
 * @dev A smart contract that locks tokens and releases them linearly over time.
 * Features:
 * - Multiple beneficiaries with individual vesting schedules
 * - Cliff period support
 * - Revocable vesting schedules (owner only)
 * - Claim tracking
 * - Event logging for all actions
 * - Reentrancy protection
 * - Gas optimization
 */
contract LinearVestingWallet is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 startTime;
        uint256 duration;
        uint256 cliff;
        bool revoked;
    }

    // Token to be vested
    IERC20 public immutable vestingToken;

    // Mapping from beneficiary to vesting schedule
    mapping(address => VestingSchedule) public vestingSchedules;

    // Total amount of tokens to be vested
    uint256 public totalVestedAmount;

    // Total amount of tokens already claimed
    uint256 public totalClaimedAmount;

    // Events
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff
    );
    event TokensClaimed(address indexed beneficiary, uint256 amount);
    event VestingRevoked(address indexed beneficiary, uint256 unvestedAmount);
    event EmergencyWithdraw(address indexed owner, uint256 amount);

    /**
     * @dev Constructor sets the vesting token
     * @param _token Address of the ERC20 token to be vested
     * @param _initialOwner Address of the contract owner
     */
    constructor(address _token, address _initialOwner) Ownable(_initialOwner) {
        require(_token != address(0), "Token address cannot be zero");
        vestingToken = IERC20(_token);
    }

    /**
     * @dev Creates a new vesting schedule for a beneficiary
     * @param _beneficiary Address of the beneficiary
     * @param _totalAmount Total amount of tokens to vest
     * @param _startTime When vesting starts (unix timestamp)
     * @param _duration Duration of vesting period in seconds
     * @param _cliff Duration in seconds of the cliff (no tokens released before cliff ends)
     */
    function createVestingSchedule(
        address _beneficiary,
        uint256 _totalAmount,
        uint256 _startTime,
        uint256 _duration,
        uint256 _cliff
    ) external onlyOwner {
        require(_beneficiary != address(0), "Beneficiary cannot be zero address");
        require(_totalAmount > 0, "Total amount must be greater than 0");
        require(_duration > 0, "Duration must be greater than 0");
        require(_cliff <= _duration, "Cliff must be less than or equal to duration");
        require(vestingSchedules[_beneficiary].totalAmount == 0, "Beneficiary already has a vesting schedule");

        // Ensure the contract has enough tokens
        uint256 balance = vestingToken.balanceOf(address(this));
        require(balance >= totalVestedAmount + _totalAmount, "Insufficient token balance");

        vestingSchedules[_beneficiary] = VestingSchedule({
            totalAmount: _totalAmount,
            claimedAmount: 0,
            startTime: _startTime,
            duration: _duration,
            cliff: _cliff,
            revoked: false
        });

        totalVestedAmount += _totalAmount;

        emit VestingScheduleCreated(_beneficiary, _totalAmount, _startTime, _duration, _cliff);
    }

    /**
     * @dev Allows a beneficiary to claim their vested tokens
     */
    function claim() external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        require(schedule.totalAmount > 0, "No vesting schedule found");

        uint256 vestedAmount = _calculateVestedAmount(schedule);
        uint256 claimableAmount = vestedAmount - schedule.claimedAmount;
        require(claimableAmount > 0, "No tokens to claim");

        schedule.claimedAmount = vestedAmount;
        totalClaimedAmount += claimableAmount;

        vestingToken.safeTransfer(msg.sender, claimableAmount);
        emit TokensClaimed(msg.sender, claimableAmount);
    }

    /**
     * @dev Calculates the vested amount for a given schedule
     * @param _schedule Vesting schedule to calculate for
     * @return Vested token amount
     */
    function _calculateVestedAmount(VestingSchedule memory _schedule) internal view returns (uint256) {
        if (_schedule.revoked) {
            return _schedule.claimedAmount;
        }

        if (block.timestamp < _schedule.startTime + _schedule.cliff) {
            return 0;
        }

        if (block.timestamp >= _schedule.startTime + _schedule.duration) {
            return _schedule.totalAmount;
        }

        return (_schedule.totalAmount * (block.timestamp - _schedule.startTime)) / _schedule.duration;
    }

    /**
     * @dev Returns the claimable amount for a beneficiary
     * @param _beneficiary Address of the beneficiary
     * @return Claimable token amount
     */
    function getClaimableAmount(address _beneficiary) external view returns (uint256) {
        VestingSchedule memory schedule = vestingSchedules[_beneficiary];
        if (schedule.totalAmount == 0) {
            return 0;
        }
        uint256 vestedAmount = _calculateVestedAmount(schedule);
        return vestedAmount - schedule.claimedAmount;
    }

    /**
     * @dev Revokes a vesting schedule and returns unvested tokens to owner
     * @param _beneficiary Address of the beneficiary to revoke
     */
    function revokeVestingSchedule(address _beneficiary) external onlyOwner {
        VestingSchedule storage schedule = vestingSchedules[_beneficiary];
        require(schedule.totalAmount > 0, "No vesting schedule found");
        require(!schedule.revoked, "Vesting already revoked");

        uint256 vestedAmount = _calculateVestedAmount(schedule);
        uint256 unvestedAmount = schedule.totalAmount - vestedAmount;

        schedule.revoked = true;
        schedule.totalAmount = vestedAmount;
        totalVestedAmount -= unvestedAmount;

        if (unvestedAmount > 0) {
            vestingToken.safeTransfer(owner(), unvestedAmount);
        }

        emit VestingRevoked(_beneficiary, unvestedAmount);
    }

    /**
     * @dev Emergency withdraw function for owner to recover tokens (except vested tokens)
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 _amount) external onlyOwner {
        uint256 availableAmount = vestingToken.balanceOf(address(this)) - (totalVestedAmount - totalClaimedAmount);
        require(_amount <= availableAmount, "Amount exceeds available balance");
        
        vestingToken.safeTransfer(owner(), _amount);
        emit EmergencyWithdraw(owner(), _amount);
    }

    /**
     * @dev Returns vesting schedule details for a beneficiary
     * @param _beneficiary Address of the beneficiary
     * @return Vesting schedule details
     */
    function getVestingSchedule(address _beneficiary) external view returns (
        uint256 totalAmount,
        uint256 claimedAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        bool revoked
    ) {
        VestingSchedule memory schedule = vestingSchedules[_beneficiary];
        return (
            schedule.totalAmount,
            schedule.claimedAmount,
            schedule.startTime,
            schedule.duration,
            schedule.cliff,
            schedule.revoked
        );
    }
}
