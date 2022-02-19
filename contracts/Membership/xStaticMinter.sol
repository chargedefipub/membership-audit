// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';
import '../ContractWhitelisted.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '../Interfaces/IPancakeRouter02.sol';
import '../Interfaces/IMintableToken.sol';
import '../Interfaces/IBoardroomAllocation.sol';
import '../Interfaces/IBasisAsset.sol';

/*
 * @dev Contract to mint xStatic tokens
 *
 * This contract accepts deposit tokens, locks it up and rewards users with xStatic tokens
 */
contract xStaticMinter is
	AccessControlEnumerable,
	ReentrancyGuard,
	ContractWhitelisted,
	Pausable
{
	bytes32 public constant transferRole = keccak256('transfer');

	using SafeMath for uint256;
	using SafeERC20 for IERC20;
	using SafeERC20 for IERC20Metadata;

	uint256 public maxCap;

	uint256 public maxCapCirculatingBP;

	// The number of blocks a deposits are locked for
	uint256 public lockBlocks;

	// The block number when deposits start
	uint256 public startBlock;

	// The number of blocks that deposits dont lock after launch
	uint256 public lockFreeBlocks;

	// The deposit token
	IERC20 public depositToken;

	// The member token
	IERC20 public memberToken;

	uint256 public multiplierBP;

	bool public unlock;

	IBoardroomAllocation public boardroomAllocation;

	address public treasury;

	// Info of each user
	mapping(address => UserInfo) public userInfo;

	event NewStartAndLockBlocks(
		uint256 startBlock,
		uint256 lockBlocks,
		uint256 lockFreeBlocks
	);
	event NewMaxCap(uint256 maxCap);
	event NewMaxCirculatingBP(uint256 maxCapCirculatingBP);
	event NewTreasury(address indexed treasury);
	event Transfer(address indexed owner, address indexed user, uint256 amount);
	event Deposit(address indexed user, uint256 amount);
	event Withdraw(address indexed user, uint256 amount);
	event NewUnlock(bool unlock);
	event AdminTokenRecovery(address tokenRecovered, uint256 amount);

	struct UserInfo {
		uint256 amount; // User's lp split in basis point
		uint256 lockStartBlock; // Block when the user lock starts
		uint256 lastDepositBlock; // Last block when a user made a deposit
	}

	/**
	 * @dev Modifier to make a function callable only by a certain role. In
	 * addition to checking the sender's role, `address(0)` 's role is also
	 * considered. Granting a role to `address(0)` is equivalent to enabling
	 * this role for everyone.
	 */
	modifier onlyRoleOrOpenRole(bytes32 role) {
		if (!hasRole(role, address(0))) {
			_checkRole(role, _msgSender());
		}
		_;
	}

	constructor(
		uint256 _lockBlocks,
		uint256 _startBlock,
		uint256 _lockFreeBlocks,
		IERC20 _depositToken,
		IERC20 _memberToken,
		IBoardroomAllocation _boardroomAllocation,
		address _treasury,
		uint256 _multiplierBP
	) {
		_setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
		_setupRole(transferRole, _msgSender());

		lockBlocks = _lockBlocks;
		startBlock = _startBlock;
		lockFreeBlocks = _lockFreeBlocks;
		depositToken = _depositToken;
		memberToken = _memberToken;
		maxCap = 3000000 ether;
		maxCapCirculatingBP = 2000;
		multiplierBP = _multiplierBP;
		treasury = _treasury;
		boardroomAllocation = _boardroomAllocation;
		unlock = false;
	}

	function transfer(uint256 _depositTokenAmount, address _userAddress)
		external
		nonReentrant
		whenNotPaused
		isAllowedContract(msg.sender)
		onlyRoleOrOpenRole(transferRole)
	{
		uint256 memberTokenAmount = _depositTokenAmount.mul(multiplierBP).div(
			10000
		);

		UserInfo storage owner = userInfo[msg.sender];

		require(
			owner.amount >= _depositTokenAmount,
			'Owner does not have enough tokens'
		);
		UserInfo storage user = userInfo[_userAddress];

		// reduce owner amount
		owner.amount = owner.amount.sub(_depositTokenAmount);

		// update user info
		user.amount = user.amount.add(_depositTokenAmount);
		user.lastDepositBlock = block.number;

		// lock start block is set if the lock free threshold has been exceeded
		if (
			user.lockStartBlock == 0 ||
			block.number > startBlock.add(lockFreeBlocks)
		) {
			user.lockStartBlock = block.number;
		}

		memberToken.safeTransferFrom(
			address(msg.sender),
			_userAddress,
			memberTokenAmount
		);
		emit Transfer(msg.sender, _userAddress, _depositTokenAmount);
	}

	function deposit(uint256 _depositTokenAmount)
		external
		nonReentrant
		whenNotPaused
		isAllowedContract(msg.sender)
	{
		require(block.number >= startBlock, 'Not started');
		require(_depositTokenAmount > 0, 'Amount cannot be 0');

		UserInfo storage user = userInfo[msg.sender];

		// naked deposits can't exceed max cap
		require(
			depositToken.balanceOf(address(this)).add(_depositTokenAmount) <=
				maxNakedDepositCap(),
			'Exceeds deposit cap'
		);

		depositToken.safeTransferFrom(
			address(msg.sender),
			address(this),
			_depositTokenAmount
		);

		// update user info
		user.amount = user.amount.add(_depositTokenAmount);
		user.lastDepositBlock = block.number;

		// lock start block is set if the lock free threshold has been exceeded
		if (
			user.lockStartBlock == 0 ||
			block.number > startBlock.add(lockFreeBlocks)
		) {
			user.lockStartBlock = block.number;
		}

		uint256 memberTokenAmount = _depositTokenAmount.mul(multiplierBP).div(
			10000
		);
		require(
			IMintableToken(address(memberToken)).mint(
				msg.sender,
				memberTokenAmount
			),
			'Unable to create member tokens'
		);

		emit Deposit(msg.sender, _depositTokenAmount);
	}

	function withdrawAll() external {
		UserInfo storage user = userInfo[msg.sender];
		withdraw(user.amount);
	}

	function withdraw(uint256 _depositTokenAmount)
		public
		nonReentrant
		isAllowedContract(msg.sender)
	{
		require(block.number >= startBlock, 'Not started');
		require(_depositTokenAmount > 0, 'Amount cannot be 0');

		UserInfo storage user = userInfo[msg.sender];

		require(
			_depositTokenAmount <= user.amount,
			"Amount can't exceed tracked balance"
		);

		// lock should have expired for a user to withdraw or unlock mode is activated
		require(block.number > user.lockStartBlock.add(lockBlocks) || unlock);

		// update user balance
		user.amount = user.amount.sub(_depositTokenAmount);

		// transfer out tokens
		depositToken.safeTransfer(msg.sender, _depositTokenAmount);

		//burn member tokens
		uint256 memberTokenAmount = _depositTokenAmount.mul(multiplierBP).div(
			10000
		);
		IBasisAsset(address(memberToken)).burnFrom(
			msg.sender,
			memberTokenAmount
		);

		emit Withdraw(msg.sender, _depositTokenAmount);
	}

	/**
	 * @notice It allows the admin to update start and lock blocks
	 * @dev This function is only callable by owner.
	 * @param _startBlock: the new start block
	 * @param _lockBlocks: the new number of lock blocks
	 * @param _lockFreeBlocks: number of lock free blocks
	 */
	function updateStartAndLockBlocks(
		uint256 _startBlock,
		uint256 _lockBlocks,
		uint256 _lockFreeBlocks
	) external onlyRole(DEFAULT_ADMIN_ROLE) {
		require(block.number < startBlock, 'Has started');
		require(
			block.number < _startBlock,
			'New startBlock must be higher than current block'
		);

		startBlock = _startBlock;
		lockBlocks = _lockBlocks;
		lockFreeBlocks = _lockFreeBlocks;

		emit NewStartAndLockBlocks(_startBlock, _lockBlocks, _lockFreeBlocks);
	}

	function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
		_pause();
	}

	function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
		_unpause();
	}

	/*
	 * @notice Updates treasury contract
	 * @param _treasury: New treasury
	 */
	function setTreasury(address _treasury)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		treasury = _treasury;
		emit NewTreasury(treasury);
	}

	/*
	 * @notice Updates max cap
	 * @param _maxCap: New max cap
	 */
	function setMaxCap(uint256 _maxCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
		maxCap = _maxCap;
		emit NewMaxCap(maxCap);
	}

	/*
	 * @notice Updates maxCapCirculatingBP
	 * @param _maxCapCirculatingBP: New maxCapCirculatingBP
	 */
	function setMaxCapCirculatingBP(uint256 _maxCapCirculatingBP)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		maxCapCirculatingBP = _maxCapCirculatingBP;
		emit NewMaxCirculatingBP(maxCap);
	}

	/*
	 * @notice Updates unlock mode
	 * @param _unlock: New unlock mode
	 */
	function setUnlock(bool _unlock) external onlyRole(DEFAULT_ADMIN_ROLE) {
		unlock = _unlock;
		emit NewUnlock(unlock);
	}

	/**
	 * @notice It allows the admin to recover wrong tokens sent to the contract
	 * @param _tokenAddress: the address of the token to withdraw
	 * @param _tokenAmount: the number of tokens to withdraw
	 * @dev This function is only callable by admin.
	 */
	function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(
			_tokenAddress != address(depositToken),
			'Cannot be reward token'
		);

		IERC20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);

		emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
	}

	function maxNakedDepositCap() public view returns (uint256) {
		uint256 circulatingSupply = depositToken
			.totalSupply()
			.sub(depositToken.balanceOf(treasury))
			.sub(_boardroomsBalance());

		return
			Math.min(
				maxCap,
				circulatingSupply.mul(maxCapCirculatingBP).div(10000)
			);
	}

	function _boardroomsBalance() private view returns (uint256) {
		uint256 bal = 0;

		uint256 boardroomCount = IBoardroomAllocation(boardroomAllocation)
			.boardroomInfoLength();

		for (uint256 i = 0; i < boardroomCount; i++) {
			(address boardroom, , , ) = IBoardroomAllocation(
				boardroomAllocation
			).boardrooms(i);

			bal = bal.add(depositToken.balanceOf(boardroom));
		}

		return bal;
	}
}
