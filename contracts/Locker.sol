// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// GoPlus Locker interface - based on common locker patterns
interface IGoPlusLocker {
    struct FeeStruct {
        string name;
        uint256 lpFee;
        uint256 collectFee;
        uint256 lockFee;
        address lockFeeToken;
    }

    function lock(
        address nftManager,
        uint256 nftId,
        address owner,
        address collector,
        uint256 endTime,
        string memory feeName
    ) external payable returns (uint256 lockId);

    function getFee(
        string memory name_
    ) external view returns (FeeStruct memory);

    function collect(
        uint256 lockId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    )
        external
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);
}

contract Locker is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public GO_PLUS_LOCKER; // GoPlus Locker service address
    address public constant NONFUNGIBLE_POSITION_MANAGER =
        0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;

    // Default lock duration
    uint256 public DEFAULT_LOCK_DURATION = 5 * 365 days;

    // Default fee config for safety checks
    IGoPlusLocker.FeeStruct public defaultFeeConfig;

    // Mapping to track locked LP NFTs
    mapping(uint256 => address) public nftToOwner; // nftId => owner
    mapping(uint256 => uint256) public nftToLockId; // nftId => lockId
    mapping(uint256 => address) public nftToGoPlusLocker; // nftId => goPlusLocker address

    event LPTokenLocked(
        uint256 indexed nftId,
        uint256 indexed lockId,
        address indexed owner,
        uint256 lockDuration,
        uint256 timestamp
    );

    constructor(address _goPlusLocker) {
        GO_PLUS_LOCKER = _goPlusLocker;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        if (GO_PLUS_LOCKER != address(0)) {
            defaultFeeConfig = IGoPlusLocker(GO_PLUS_LOCKER).getFee("LLP");
        }
    }

    /**
     * @dev Internal function to lock NFT with GoPlus Locker
     */
    function _lockWithGoPlus(
        uint256 nftId,
        uint256 lockDuration,
        address owner
    ) internal returns (uint256 lockId) {
        // Approve GoPlus Locker to handle the NFT
        INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).approve(
            GO_PLUS_LOCKER,
            nftId
        );

        // Calculate lock end time
        uint256 lockEndTime = block.timestamp + lockDuration;

        // Get fee info from GoPlus Locker
        IGoPlusLocker.FeeStruct memory feeInfo = IGoPlusLocker(GO_PLUS_LOCKER)
            .getFee(defaultFeeConfig.name);

        // Compare feeInfo to defaultFeeConfig
        require(
            feeInfo.lockFee == defaultFeeConfig.lockFee &&
                feeInfo.lockFeeToken == defaultFeeConfig.lockFeeToken &&
                feeInfo.lpFee == defaultFeeConfig.lpFee &&
                feeInfo.collectFee == defaultFeeConfig.collectFee,
            "Fee config mismatch"
        );

        // Pay fee from contract balance
        if (feeInfo.lockFee > 0 && feeInfo.lockFeeToken != address(0)) {
            // ERC20 fee: ensure contract has enough tokens
            require(
                IERC20(feeInfo.lockFeeToken).balanceOf(address(this)) >=
                    feeInfo.lockFee,
                "Insufficient token for fee"
            );
            // Approve GoPlus Locker to spend fee
            IERC20(feeInfo.lockFeeToken).approve(
                GO_PLUS_LOCKER,
                feeInfo.lockFee
            );
        }

        if (feeInfo.lockFee > 0 && feeInfo.lockFeeToken == address(0)) {
            require(
                address(this).balance >= feeInfo.lockFee,
                "Insufficient ETH for fee"
            );
            // Call lock with value
            lockId = IGoPlusLocker(GO_PLUS_LOCKER).lock{value: feeInfo.lockFee}(
                NONFUNGIBLE_POSITION_MANAGER,
                nftId,
                owner,
                address(this),
                lockEndTime,
                defaultFeeConfig.name
            );
        } else {
            lockId = IGoPlusLocker(GO_PLUS_LOCKER).lock(
                NONFUNGIBLE_POSITION_MANAGER,
                nftId,
                owner,
                address(this),
                lockEndTime,
                defaultFeeConfig.name
            );
        }

        // Store the lock information
        nftToLockId[nftId] = lockId;
        nftToGoPlusLocker[nftId] = GO_PLUS_LOCKER;
    }

    /**
     * @notice Lock LP NFT token using GoPlus Locker service
     * @param nftId The ID of the LP NFT token to lock
     * @param lockDuration Duration to lock the NFT (in seconds)
     * @param owner The address that will be set as the owner of the locked NFT
     */
    function _lock(
        uint256 nftId,
        uint256 lockDuration,
        address owner
    ) internal nonReentrant returns (uint256 lockId) {
        require(nftId > 0, "Invalid NFT ID");
        require(lockDuration > 0, "Invalid lock duration");
        require(owner != address(0), "Invalid owner address");
        require(
            nftToLockId[nftId] == 0 && nftToOwner[nftId] == address(0),
            "NFT already locked"
        );

        require(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).ownerOf(
                nftId
            ) == address(this),
            "NFT not transferred to contract"
        );
        nftToOwner[nftId] = owner;

        if (GO_PLUS_LOCKER != address(0)) {
            lockId = _lockWithGoPlus(nftId, lockDuration, owner);
        }

        emit LPTokenLocked(nftId, lockId, owner, lockDuration, block.timestamp);

        return lockId;
    }

    /**
     * @notice Lock LP NFT token with default duration
     * @param nftId The ID of the LP NFT token to lock
     * @param owner The address that will be set as the owner of the locked NFT
     */
    function lockWithDefaultDuration(
        uint256 nftId,
        address owner
    ) external returns (uint256) {
        return _lock(nftId, DEFAULT_LOCK_DURATION, owner);
    }

    /**
     * @notice Update GoPlus Locker address
     * @param newLockerAddress New GoPlus Locker contract address
     */
    function updateGoPlusLocker(
        address newLockerAddress
    ) external onlyRole(ADMIN_ROLE) {
        GO_PLUS_LOCKER = newLockerAddress;
    }

    /**
     * @notice Update default lock duration
     * @param newDuration New default duration in seconds
     */
    function updateDefaultLockDuration(
        uint256 newDuration
    ) external onlyRole(ADMIN_ROLE) {
        require(newDuration > 0, "Invalid duration");
        DEFAULT_LOCK_DURATION = newDuration;
    }

    /**
     * @notice Update the default fee config for safety checks
     * @param name_ Name of the fee config
     * @param lpFee_ LP fee
     * @param collectFee_ Collect fee
     * @param lockFee_ Lock fee
     * @param lockFeeToken_ Lock fee token address
     */
    function updateDefaultFeeConfig(
        string memory name_,
        uint256 lpFee_,
        uint256 collectFee_,
        uint256 lockFee_,
        address lockFeeToken_
    ) external onlyRole(ADMIN_ROLE) {
        defaultFeeConfig = IGoPlusLocker.FeeStruct({
            name: name_,
            lpFee: lpFee_,
            collectFee: collectFee_,
            lockFee: lockFee_,
            lockFeeToken: lockFeeToken_
        });
    }

    /**
     * @notice Emergency function to withdraw ETH
     */
    function withdrawETH() external onlyRole(ADMIN_ROLE) {
        payable(msg.sender).transfer(address(this).balance);
    }

    /**
     * @notice Get lock information for an NFT
     * @param nftId The NFT ID to query
     * @return lockId The lock ID, 0 if not locked
     * @return owner The original owner of the locked NFT
     */
    function getLockInfo(
        uint256 nftId
    ) external view returns (uint256 lockId, address owner) {
        lockId = nftToLockId[nftId];
        owner = nftToOwner[nftId];
    }

    function collectFees(
        uint256 nftId,
        address recipient
    ) external nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        address owner = nftToOwner[nftId];
        require(msg.sender == owner, "Not owner");

        // Locked: call GoPlus Locker's collect
        uint256 lockId = nftToLockId[nftId];
        address goPlusLocker = nftToGoPlusLocker[nftId];

        if (lockId > 0) {
            IGoPlusLocker(goPlusLocker).collect(
                lockId,
                recipient,
                type(uint128).max,
                type(uint128).max
            );
        } else {
            // Not locked: call INonfungiblePositionManager's collect
            INonfungiblePositionManager.CollectParams
                memory params = INonfungiblePositionManager.CollectParams({
                    tokenId: nftId,
                    recipient: recipient,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                });
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).collect(
                params
            );
        }
    }

    /**
     * @notice Admin function to migrate NFT locked in this contract to GoPlus Locker
     * @param nftId The ID of the LP NFT token to migrate
     */
    function migrateToGoPlusLocker(
        uint256 nftId
    ) external onlyRole(ADMIN_ROLE) nonReentrant returns (uint256 lockId) {
        require(GO_PLUS_LOCKER != address(0), "GoPlus Locker not set");
        require(nftToOwner[nftId] != address(0), "NFT not locked");
        require(nftToLockId[nftId] == 0, "Already migrated");

        require(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).ownerOf(
                nftId
            ) == address(this),
            "NFT not held by contract"
        );
        lockId = _lockWithGoPlus(
            nftId,
            DEFAULT_LOCK_DURATION,
            nftToOwner[nftId]
        );
        emit LPTokenLocked(
            nftId,
            lockId,
            nftToOwner[nftId],
            DEFAULT_LOCK_DURATION,
            block.timestamp
        );
        return lockId;
    }

    // Allow contract to receive ETH for GoPlus fees
    receive() external payable {}
}
