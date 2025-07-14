// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./TokenERC20.sol";
import "./BondingCurveFactory.sol";
import "./interfaces/IVesting.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/IBondingCurve.sol";
import {DevVestingParam} from "./structs/VestingParam.sol";

contract Controller is AccessControl {
    address public ADMIN_VERIFY_ADDRESS =
        0x029cbcE751B86bF87D6541011fAac54C93282507; // @TODO: update in production
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public INITIAL_SUPPLY = 888_888_888 ether;
    bool public IS_AUTO_ADD_LIQUIDITY = false;

    // Config variables
    uint256 public CREATE_TOKEN_FEE = 0.001 ether;
    uint256 public CREATE_TOKEN_FEE_XCX = 50 ether;
    address public bondingAdmin;
    address public FEE_RECEIVER;
    address public XCX_ADDRESS;
    uint256 public constant DEMI = 10000;
    uint256 public BONDING_CURVE_PERCENT = 6500; // 65%
    uint256 public LIQUIDITY_PERCENT = 1500; // 15%
    uint256 public DEV_TEAM_MAX_PERCENT = 1500; // 15%
    uint256 public STAKING_APY = 1000;
    uint256 public REQUIRE_XCX_STAKED_AMOUNT = 0; // Default 1000 XCX tokens

    address private LOCKER_ADDRESS;
    uint24 private FEE_TIER = 2500; // 0.25% fee tier

    IVesting public vesting;
    IStaking public staking;
    bool private initialized;

    // Add variables for BondingCurve settings
    struct TokenConfig {
        uint256 finalBaseAmount;
        uint256 maxBuyAmount;
        uint256 maxBuyAmountEachTx;
        uint256 requireBaseStakeA;
        bool isInitialized;
    }
    // base token address => config
    mapping(address => TokenConfig) private baseTokenConfigs;

    uint256 private BURN_PERCENT = 20; // 0.2% burn (20/10000)
    uint256 private FEE_PERCENT = 100; // 1% fee (100/10000)

    // Add mapping from token address to bondingCurve address
    mapping(address => address) public tokenToBondingCurve;
    mapping(bytes32 => bool) _mapSalt;

    address public bondingCurveFactory; // Address of the factory

    event TokenCreated(
        string id,
        address indexed tokenAddress,
        address indexed baseAddress,
        address indexed bondingAddress,
        string name,
        string symbol,
        address owner,
        uint256 baseRaiseAmount,
        uint256 totalSupply,
        uint256 bondingSupply,
        uint256 liquiditySupply,
        uint256 devTeamSupply
    );

    constructor(
        address _feeReceiver,
        address _xcx,
        address _bondingCurveFactory
    ) {
        require(_feeReceiver != address(0), "Invalid fee receiver");
        require(_xcx != address(0), "Invalid XCX address");
        require(
            _bondingCurveFactory != address(0),
            "Invalid BondingCurveFactory address"
        );
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        FEE_RECEIVER = _feeReceiver;
        XCX_ADDRESS = _xcx;
        bondingAdmin = msg.sender;
        bondingCurveFactory = _bondingCurveFactory;
    }

    function initialize(
        address _vesting,
        address _staking
    ) external onlyRole(ADMIN_ROLE) {
        require(!initialized, "Already initialized");
        require(_vesting != address(0), "Invalid vesting address");
        require(_staking != address(0), "Invalid staking address");
        vesting = IVesting(_vesting);
        staking = IStaking(_staking);
        initialized = true;
    }

    // Main function to create a new token launch
    function createToken(
        address baseToken,
        string memory name,
        string memory symbol,
        bool isAutoStartBonding,
        bytes32 salt,
        string memory id,
        uint256 devTeamPercent,
        DevVestingParam[] memory devVestingParams
    ) external payable returns (address) {
        // Only allow if baseToken is whitelisted (config initialized)
        require(
            baseTokenConfigs[baseToken].isInitialized,
            "Base token not whitelisted"
        );

        if (REQUIRE_XCX_STAKED_AMOUNT > 0) {
            uint256 stakedAmount = staking.getStakedAmount(
                XCX_ADDRESS,
                msg.sender
            );
            require(
                stakedAmount >= REQUIRE_XCX_STAKED_AMOUNT,
                "Insufficient XCX tokens staked"
            );
        }

        require(
            devTeamPercent <= DEV_TEAM_MAX_PERCENT,
            "Dev team percent too high"
        );

        // Fee payment logic: allow BNB or XCX
        if (msg.value >= CREATE_TOKEN_FEE) {
            if (CREATE_TOKEN_FEE > 0) {
                payable(FEE_RECEIVER).transfer(CREATE_TOKEN_FEE);
                uint256 refund = msg.value - CREATE_TOKEN_FEE;
                if (refund > 0) {
                    (bool success, ) = msg.sender.call{value: refund}("");
                    require(success, "Refund failed");
                }
            }
        } else if (CREATE_TOKEN_FEE_XCX > 0) {
            IERC20 xcx = IERC20(XCX_ADDRESS);
            xcx.transferFrom(msg.sender, FEE_RECEIVER, CREATE_TOKEN_FEE_XCX);
        }

        // 2. Calculate allocations
        uint256 bondingAmount = (INITIAL_SUPPLY * BONDING_CURVE_PERCENT) / DEMI;
        uint256 liquidityAmount = (INITIAL_SUPPLY * LIQUIDITY_PERCENT) / DEMI;
        uint256 devTeamAmount = (INITIAL_SUPPLY * devTeamPercent) / DEMI;
        uint256 stakingAmount = INITIAL_SUPPLY -
            bondingAmount -
            liquidityAmount -
            devTeamAmount;

        // 3. Deploy BondingCurve and initialize
        address bondingCurveAddr = BondingCurveFactory(bondingCurveFactory)
            .deploy(bondingAdmin, address(this));
        IBondingCurve bondingCurve = IBondingCurve(bondingCurveAddr);

        // 1. Deploy new TokenERC20
        TokenERC20 token = _deployNewToken(
            baseToken,
            name,
            symbol,
            INITIAL_SUPPLY,
            salt
        );

        emit TokenCreated(
            id,
            address(token),
            baseToken,
            bondingCurveAddr,
            name,
            symbol,
            msg.sender,
            baseTokenConfigs[baseToken].finalBaseAmount,
            INITIAL_SUPPLY,
            bondingAmount,
            liquidityAmount,
            devTeamAmount
        );

        token.approve(bondingCurveAddr, bondingAmount + liquidityAmount);
        bondingCurve.initialize(
            address(token),
            baseToken,
            ADMIN_VERIFY_ADDRESS,
            msg.sender,
            bondingAmount,
            liquidityAmount,
            baseTokenConfigs[baseToken].finalBaseAmount,
            address(staking),
            IS_AUTO_ADD_LIQUIDITY,
            FEE_TIER
        );
        if (isAutoStartBonding) {
            bondingCurve.startBonding();
        }
        // Store the mapping
        tokenToBondingCurve[address(token)] = bondingCurveAddr;

        if (devTeamAmount > 0) {
            token.approve(address(vesting), devTeamAmount);
            vesting.createMultipleVestingSchedule(
                address(token),
                devVestingParams,
                devTeamAmount,
                true // isBondingCurve
            );
        }

        // 5. Staking pool setup
        token.approve(address(staking), stakingAmount);
        staking.initializeToken(address(token), stakingAmount, STAKING_APY); // Example: 10% APY (1000 basis points)

        token.startBonding(address(bondingCurve));

        return address(token);
    }

    // Get bondingComplete status and timestamp for a token
    function getBondingStatus(
        address token
    ) external view returns (bool, uint256) {
        address bondingCurveAddr = tokenToBondingCurve[token];
        require(bondingCurveAddr != address(0), "BondingCurve not found");
        bool complete = IBondingCurve(bondingCurveAddr).bondingComplete();
        uint256 completeAt = IBondingCurve(bondingCurveAddr)
            .bondingCompleteAt();
        return (complete, completeAt);
    }

    function _deployNewToken(
        address baseToken,
        string memory name,
        string memory symbol,
        uint256 inititalSupply,
        bytes32 _salt
    ) private returns (TokenERC20) {
        // Calculate address before deployment
        require(!_mapSalt[_salt], "Salt already used");
        TokenERC20 newToken = new TokenERC20{salt: _salt}(
            name,
            symbol,
            inititalSupply
        );
        require(
            address(newToken) < baseToken,
            "Invalid Token Address!, require token < baseToken"
        );
        _mapSalt[_salt] = true;
        return newToken;
    }

    // Combined function to set both INITIAL_SUPPLY
    function setInitialSupplyAndMode(
        uint256 newSupply,
        bool isAutoAddLiquidity
    ) external onlyRole(ADMIN_ROLE) {
        require(newSupply > 0, "Supply must be positive");
        INITIAL_SUPPLY = newSupply;
        IS_AUTO_ADD_LIQUIDITY = isAutoAddLiquidity;
    }

    // Combined function to set both CREATE_TOKEN_FEE and CREATE_TOKEN_FEE_XCX
    function setFeeSettings(
        address newReceiver,
        uint256 newFee,
        uint256 newFeeXCX
    ) external onlyRole(ADMIN_ROLE) {
        require(newReceiver != address(0), "Invalid fee receiver");
        FEE_RECEIVER = newReceiver;
        CREATE_TOKEN_FEE = newFee;
        CREATE_TOKEN_FEE_XCX = newFeeXCX;
    }

    function setTokenomicPercents(
        uint256 bonding,
        uint256 liquidity,
        uint256 devTeamMax
    ) external onlyRole(ADMIN_ROLE) {
        require(
            bonding + liquidity + devTeamMax <= DEMI,
            "Sum of percents cannot exceed 100%"
        );
        BONDING_CURVE_PERCENT = bonding;
        LIQUIDITY_PERCENT = liquidity;
        DEV_TEAM_MAX_PERCENT = devTeamMax;
    }

    // Admin function to update BondingCurve settings
    function setBondingBurnFeePercents(
        uint256 _burnPercent,
        uint256 _feePercent
    ) external onlyRole(ADMIN_ROLE) {
        BURN_PERCENT = _burnPercent;
        FEE_PERCENT = _feePercent;
    }

    function setRequireXCXStakedAmount(
        uint256 _amount
    ) external onlyRole(ADMIN_ROLE) {
        require(_amount > 0, "Amount must be greater than 0");
        REQUIRE_XCX_STAKED_AMOUNT = _amount;
    }

    // Admin function to set TokenConfig for any base token
    function setBaseTokenConfig(
        address baseToken,
        uint256 finalBaseAmount,
        uint256 maxBuyAmount,
        uint256 maxBuyAmountEachTx,
        uint256 requireBaseStakeA
    ) external onlyRole(ADMIN_ROLE) {
        require(baseToken != address(0), "Invalid base token");
        require(finalBaseAmount > 0, "finalBaseAmount must be positive");
        baseTokenConfigs[baseToken] = TokenConfig({
            finalBaseAmount: finalBaseAmount,
            maxBuyAmount: maxBuyAmount,
            maxBuyAmountEachTx: maxBuyAmountEachTx,
            requireBaseStakeA: requireBaseStakeA,
            isInitialized: true
        });
    }

    function setAdminVerifyAddress(
        address newAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(newAddress != address(0), "Invalid address");
        ADMIN_VERIFY_ADDRESS = newAddress;
    }

    // IController interface functions for BondingCurve
    function getBaseTokenConfig(
        address baseToken
    )
        external
        view
        returns (
            uint256 finalBaseAmount,
            uint256 maxBuyAmount,
            uint256 maxBuyAmountEachTx,
            uint256 requireBaseStakeA,
            bool isInitialized
        )
    {
        TokenConfig memory config = baseTokenConfigs[baseToken];
        return (
            config.finalBaseAmount,
            config.maxBuyAmount,
            config.maxBuyAmountEachTx,
            config.requireBaseStakeA,
            config.isInitialized
        );
    }

    function getFeeAndBurnPercents()
        external
        view
        returns (uint256 feePercent, uint256 burnPercent)
    {
        return (FEE_PERCENT, BURN_PERCENT);
    }

    // View function to check if a salt is valid for a new token deployment
    function isSaltValid(
        address baseToken,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external view returns (address predicted, bool isValid) {
        if (_mapSalt[salt]) {
            return (address(0), false);
        }
        bytes memory bytecode = abi.encodePacked(
            type(TokenERC20).creationCode,
            abi.encode(name, symbol, INITIAL_SUPPLY)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        predicted = address(uint160(uint256(hash)));
        isValid = predicted < baseToken;
        return (predicted, isValid);
    }

    function setLockerAddress(
        address newLockerAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(newLockerAddress != address(0), "Invalid locker address");
        LOCKER_ADDRESS = newLockerAddress;
    }

    function getLockerAddress() external view returns (address) {
        return LOCKER_ADDRESS;
    }

    function setBondingCurveFactory(
        address newFactory
    ) external onlyRole(ADMIN_ROLE) {
        require(newFactory != address(0), "Invalid factory address");
        bondingCurveFactory = newFactory;
    }

    function setBondingAdmin(address newAdmin) external onlyRole(ADMIN_ROLE) {
        require(newAdmin != address(0), "Invalid admin address");
        bondingAdmin = newAdmin;
    }

    function setFeeTier(uint24 newFeeTier) external onlyRole(ADMIN_ROLE) {
        FEE_TIER = newFeeTier;
    }
}
