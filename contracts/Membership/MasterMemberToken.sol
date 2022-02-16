import '@openzeppelin/contracts/access/AccessControlEnumerable.sol';
import '../ContractWhitelisted.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '../Interfaces/IPancakeRouter02.sol';
import '../Interfaces/IZapper.sol';
import '../Interfaces/IMintableToken.sol';
import '../Interfaces/IBoardroomAllocation.sol';

/*
 * @dev Contract to handle the minting of new member tokens
 *
 * This contract accepts deposit token and stables. Locks it up in a split between deposit and deposit LP,
 * and rewards users with member tokens
 */
contract MasterMemberToken is
	AccessControlEnumerable,
	ReentrancyGuard,
	ContractWhitelisted,
	Pausable
{
	using SafeMath for uint256;
	using SafeERC20 for IERC20;
	using SafeERC20 for IERC20Metadata;

	uint256 public maxCap;

	uint256 public maxCapCirculatingBP;

	// The number of blocks a deposits are locked for
	uint256 public lockBlocks;

	// The block number when deposits start
	uint256 public startBlock;

	// The deposit token
	IERC20 public depositToken;

	// The depositLP token
	IERC20 public depositLPToken;

	// The member token
	IERC20 public memberToken;

	// The path to convert deposit to stable
	address[] public depositToStablePath;

	// The path to convert stable to deposit
	address[] public stableToDepositPath;

	// Router to compute prices
	IPancakeRouter02 public router;

	// Zapper to zap to LP
	IZapper public zapper;

	IBoardroomAllocation public boardroomAllocation;

	address public treasury;

	// Info of each user
	mapping(address => UserInfo) public userInfo;

	// Info of each user
	mapping(uint256 => LPSplitInfo) public lpSplitInfo;

	event NewZapper(address indexed newZapper);
	event NewStartAndLockBlocks(uint256 startBlock, uint256 lockBlocks);

	struct UserInfo {
		uint256 lpSplitBP; // User's lp split in basis point
		uint256 nakedDepositAmount; // How many naked tokens user provided
		uint256 lpDepositAmount; // How many lp tokens user provided
		uint256 memberTokenBalance; // member token balance of the user
		uint256 lockStartBlock; // Block when the user lock starts
		uint256 lastDepositBlock; // Last block when a user made a deposit
	}

	struct LPSplitInfo {
		uint256 lockFreeDepositBlocks; // number of blocks before a deposit resets the lock
		uint256 memberTokenMultiplier; // multiplier during minting member tokens
		uint256 maxNakedDepositAmountPerAddress; // max deposit tokens for this lp split
		uint256 totalNakedDepositAmount; // total amount of naked deposit locked towards this split
	}

	constructor(
		uint256 _lockBlocks,
		uint256 _startBlock,
		IERC20 _depositToken,
		IERC20 _depositLPToken,
		IERC20 _memberToken,
		IPancakeRouter02 _router,
		IZapper _zapper,
		IBoardroomAllocation _boardroomAllocation,
		address _treasury,
		address[] memory _depositToStablePath,
		address[] memory _stableToDepositPath
	) {
		_setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

		lockBlocks = _lockBlocks;
		startBlock = _startBlock;
		depositToken = _depositToken;
		depositLPToken = _depositLPToken;
		memberToken = _memberToken;
		router = _router;
		zapper = _zapper;
		depositToStablePath = _depositToStablePath;
		stableToDepositPath = _stableToDepositPath;
		boardroomAllocation = _boardroomAllocation;
		treasury = _treasury;
		maxCap = type(uint256).max;
		maxCapCirculatingBP = 2500;

		depositToken.approve(address(zapper), type(uint256).max);
		IERC20(stableToDepositPath[0]).approve(
			address(router),
			type(uint256).max
		);
	}

	modifier validLPSplit(uint256 _lpSplitBP) {
		require(
			lpSplitInfo[_lpSplitBP].memberTokenMultiplier > 0,
			'Split does not exist'
		);
		_;
	}

	function depositStable(uint256 _amount, uint256 _lpSplitBP) external {
		require(_amount > 0, 'Amount cannot be 0');

		IERC20(stableToDepositPath[0]).safeTransferFrom(
			address(msg.sender),
			address(this),
			_amount
		);

		uint256 balanceBefore = depositToken.balanceOf(address(this));
		uint256[] memory amounts = router.getAmountsOut(
			_amount,
			stableToDepositPath
		);
		router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
			_amount,
			amounts[amounts.length - 1],
			stableToDepositPath,
			address(this),
			block.timestamp + 600
		);

		uint256 depositTokens = depositToken.balanceOf(address(this)).sub(
			balanceBefore
		);

		deposit(depositTokens, _lpSplitBP);
	}

	function deposit(uint256 _amount, uint256 _lpSplitBP)
		public
		nonReentrant
		validLPSplit(_lpSplitBP)
		whenNotPaused
		isAllowedContract(msg.sender)
	{
		require(block.number >= startBlock, 'Not started');
		require(_amount > 0, 'Amount cannot be 0');

		UserInfo storage user = userInfo[msg.sender];
		LPSplitInfo storage lpInfo = lpSplitInfo[_lpSplitBP];

		require(
			user.lpSplitBP == 0 || user.lpSplitBP == _lpSplitBP,
			'Does not match prev split'
		);

		depositToken.safeTransferFrom(
			address(msg.sender),
			address(this),
			_amount
		);

		uint256 depositForLP = _amount.mul(_lpSplitBP).div(10000);
		uint256 nakedDeposit = _amount.sub(depositForLP);

		// naked deposits can't exceed max cap
		require(
			depositToken.balanceOf(address(this)).add(nakedDeposit) <=
				maxNakedDepositCap(),
			'Exceeds deposit cap'
		);
		// users naked deposit cannot be more than threshold defined by lp info
		require(
			user.nakedDepositAmount.add(nakedDeposit) <=
				lpInfo.maxNakedDepositAmountPerAddress
		);

		uint256 memberTokens = nakedDeposit
			.mul(lpInfo.memberTokenMultiplier)
			.div(100);

		uint256 lpTokens = _zapDepositToLP(depositForLP);

		// update user info
		user.lpSplitBP = _lpSplitBP;
		user.nakedDepositAmount = user.nakedDepositAmount.add(nakedDeposit);
		user.lpDepositAmount = user.lpDepositAmount.add(lpTokens);
		user.memberTokenBalance = user.memberTokenBalance.add(memberTokens);
		user.lastDepositBlock = block.number;
		if (
			user.lockStartBlock.add(lpInfo.lockFreeDepositBlocks) > block.number
		) {
			user.lockStartBlock = block.number;
		}

		// update lp info stat
		lpInfo.totalNakedDepositAmount = lpInfo.totalNakedDepositAmount.add(
			nakedDeposit
		);

		require(
			IMintableToken(address(memberToken)).mint(msg.sender, memberTokens),
			'Unable to create member tokens'
		);
	}

	/**
	 * @notice It allows the admin to update start and lock blocks
	 * @dev This function is only callable by owner.
	 * @param _startBlock: the new start block
	 * @param _lockBlocks: the new number of lock blocks
	 */
	function updateStartAndLockBlocks(uint256 _startBlock, uint256 _lockBlocks)
		external
		onlyRole(DEFAULT_ADMIN_ROLE)
	{
		require(block.number < startBlock, 'Has started');
		require(
			block.number < _startBlock,
			'New startBlock must be higher than current block'
		);

		startBlock = _startBlock;
		lockBlocks = _lockBlocks;

		emit NewStartAndLockBlocks(_startBlock, _lockBlocks);
	}

	function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
		_pause();
	}

	function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
		_unpause();
	}

	/*
	 * @notice Updates zapper contract
	 * @param zapper_: New zapper
	 */
	function setZapper(IZapper zapper_) external onlyRole(DEFAULT_ADMIN_ROLE) {
		emit NewZapper(address(zapper_));
		depositToken.safeApprove(address(zapper), 0);
		zapper = zapper_;
		depositToken.approve(address(zapper), type(uint256).max);
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

	function _zapDepositToLP(uint256 _amount) private returns (uint256) {
		uint256 balanceBefore = depositLPToken.balanceOf(address(this));
		zapper.zapTokenToLP(
			address(depositToken),
			_amount,
			address(depositLPToken)
		);
		return depositLPToken.balanceOf(address(this)).sub(balanceBefore);
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
