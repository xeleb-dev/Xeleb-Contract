// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./interfaces/IPancakeV3Factory.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/external/IWETH9.sol";
import "./interfaces/ITokenERC20.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./Cashier.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IController.sol";

contract BondingCurve is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public owner;
    address public ADMIN_VERIFY_ADDRESS;
    address public BASE_TOKEN;
    address public CONTROLLER;
    uint256 public POSITION_NFT_ID;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    // Modifier to allow only owner or admin
    modifier onlyOwnerOrAdmin() {
        require(
            msg.sender == owner || hasRole(ADMIN_ROLE, msg.sender),
            "Not owner or admin"
        );
        _;
    }

    enum TradeType {
        Buy,
        Sell
    }

    bool public IS_AUTO_ADD_LIQUIDITY; // Configurable in initialize
    uint256 public BONDING_SUPPLY; // Configurable in initialize
    uint256 public LIQUIDITY_SUPPLY; // Configurable in initialize
    uint256 public FINAL_BASE_AMOUNT; // Configurable in initialize

    uint256 public totalTokensSold;
    uint256 public totalBaseRaised; // Track total base raised
    bool public initialized;
    bool public bondingComplete;
    uint256 public bondingCompleteAt;
    bool public isLiquidityAdded;
    bool public bondingStarted; // Default false, controls if buy/sell is allowed

    // PancakeSwap V3 related addresses
    address public constant PANCAKE_V3_FACTORY =
        0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address public constant PANCAKE_V3_ROUTER =
        0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address public constant NONFUNGIBLE_POSITION_MANAGER =
        0x427bF5b37357632377eCbEC9de3626C71A5396c1;
    uint24 public constant POOL_FEE = 100; // 0.01% fee tier

    // Constants for liquidity range
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;

    uint256 private constant PRECISION = 1e18;

    uint256 public constant DEMI = 10000; // 100.00% = 10000, 1% = 100
    address public STAKING_ADDRESS;

    // Track total amount bought by each user
    mapping(address => uint256) public userTotalBought;

    uint256 private virtualBase;
    uint256 private virtualTokens;

    event InitBondingCurve(uint256 initPrice, uint256 timestamp);
    event Trade(
        address indexed trader,
        TradeType tradeType,
        uint256 tokenAmount,
        uint256 baseAmount,
        uint256 price, // 1e18 precision
        uint256 totalSoldAmount,
        uint256 timestamp
    );

    event BondingEnd(uint256 timestamp);
    event LiquidityAdded(
        address indexed provider,
        address token0,
        address token1,
        address pool,
        uint256 tokenAmount,
        uint256 baseAmount,
        uint256 timestamp
    );
    event BondingStart(uint256 timestamp);

    constructor(address _initAdmin, address _controller) {
        CONTROLLER = _controller;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, _initAdmin);
    }

    function initialize(
        address _token,
        address _baseToken,
        address _adminVerifyAddress,
        address _owner,
        uint256 _bondingSupply,
        uint256 _liquiditySupply,
        uint256 _finalBaseAmount,
        address _stakingAddress,
        bool _isAutoAddLiquidity
    ) external onlyRole(ADMIN_ROLE) {
        require(!initialized, "Already initialized");
        require(_bondingSupply > 0, "Invalid bonding supply");
        require(_liquiditySupply > 0, "Invalid liquidity supply");
        require(_finalBaseAmount > 0, "Invalid final base amount");
        require(_stakingAddress != address(0), "Invalid staking address");

        token = IERC20(_token);
        BASE_TOKEN = _baseToken;
        ADMIN_VERIFY_ADDRESS = _adminVerifyAddress;
        owner = _owner;

        BONDING_SUPPLY = _bondingSupply;
        LIQUIDITY_SUPPLY = _liquiditySupply;
        FINAL_BASE_AMOUNT = _finalBaseAmount;
        STAKING_ADDRESS = _stakingAddress;
        IS_AUTO_ADD_LIQUIDITY = _isAutoAddLiquidity;

        // Calculate virtual reserves so that:
        // 1.  total Base raised equals FINAL_BASE_AMOUNT when BONDING_SUPPLY tokens have been sold; and
        // 2.  The terminal price of the bonding curve (after all tokens are sold) approximates the initial
        //     price of the PancakeSwap V3 pool (FINAL_BASE_AMOUNT / _liquiditySupply).
        //
        // Solving the constant-product equations gives:
        //     virtualTokens  = (BONDING_SUPPLY * _liquiditySupply) / (BONDING_SUPPLY - _liquiditySupply)
        //     virtualBase     = (FINAL_BASE_AMOUNT * _liquiditySupply) / (BONDING_SUPPLY - _liquiditySupply)
        //
        // The derivation assumes BONDING_SUPPLY > _liquiditySupply; enforce this.
        require(
            _bondingSupply > _liquiditySupply,
            "Bonding supply must exceed liquidity supply"
        );

        virtualTokens = Math.mulDiv(
            _bondingSupply,
            _liquiditySupply,
            _bondingSupply - _liquiditySupply
        );

        virtualBase = Math.mulDiv(
            _finalBaseAmount,
            _liquiditySupply,
            _bondingSupply - _liquiditySupply
        );

        token.safeTransferFrom(
            msg.sender,
            address(this),
            BONDING_SUPPLY + LIQUIDITY_SUPPLY
        );
        _initPool(_finalBaseAmount, _liquiditySupply);
        initialized = true;

        emit InitBondingCurve(getCurrentPrice(), block.timestamp);
    }

    function _initPool(
        uint256 _finalBaseAmount,
        uint256 _liquiditySupply
    ) private {
        // Create pool if it doesn't exist
        IPancakeV3Factory factory = IPancakeV3Factory(PANCAKE_V3_FACTORY);
        address pool = factory.getPool(address(token), BASE_TOKEN, POOL_FEE);

        if (pool == address(0)) {
            pool = factory.createPool(address(token), BASE_TOKEN, POOL_FEE);
        }

        // Calculate sqrt price
        uint256 priceRatio = (_finalBaseAmount * 1e18) / _liquiditySupply;
        uint256 sqrtPrice = Math.sqrt(priceRatio);
        uint160 sqrtPriceX96 = uint160((sqrtPrice * 2 ** 96) / 1e9);

        // Initialize pool with price
        IPancakeV3Pool(pool).initialize(sqrtPriceX96);
    }

    /**
     * @notice Current spot price of the bonding curve in Base per token (18-decimals precision)
     */
    function getCurrentPrice() public view returns (uint256) {
        uint256 reserveTokens = virtualTokens +
            (BONDING_SUPPLY - totalTokensSold);
        uint256 reserveBase = virtualBase + totalBaseRaised;

        return (reserveBase * PRECISION) / reserveTokens;
    }

    /**
     * @notice Amount of tokens received for a given Base amount when buying.
     * @dev Uses the constant-product formula: ΔT = R_T * ΔB / (R_B + ΔB)
     */
    function getTokensForBase(
        uint256 baseAmount
    ) public view returns (uint256) {
        require(baseAmount > 0, "Invalid Base amount");

        uint256 reserveTokens = virtualTokens +
            (BONDING_SUPPLY - totalTokensSold);
        uint256 reserveBase = virtualBase + totalBaseRaised;

        return Math.mulDiv(baseAmount, reserveTokens, reserveBase + baseAmount);
    }

    /**
     * @notice Amount of Base returned for a given token amount when selling.
     * @dev Uses the constant-product formula: ΔB = R_B * ΔT / (R_T + ΔT)
     */
    function getBaseForTokens(
        uint256 tokenAmount
    ) public view returns (uint256) {
        require(tokenAmount > 0, "Invalid token amount");

        uint256 reserveTokens = virtualTokens +
            (BONDING_SUPPLY - totalTokensSold);
        uint256 reserveBase = virtualBase + totalBaseRaised;

        return
            Math.mulDiv(tokenAmount, reserveBase, reserveTokens + tokenAmount);
    }

    function buy(
        uint256 _baseAmount,
        uint256 _bonusMaxAmount,
        uint256 signatureExpiredAt,
        bytes memory _signature
    ) external payable nonReentrant returns (uint256) {
        if (_bonusMaxAmount > 0) {
            require(block.timestamp < signatureExpiredAt, "signature expired");
            bytes32 _hash = keccak256(
                abi.encodePacked(
                    "buy",
                    msg.sender,
                    signatureExpiredAt,
                    _bonusMaxAmount
                )
            );
            bytes32 messageHash = MessageHashUtils.toEthSignedMessageHash(
                _hash
            );
            address signer = ECDSA.recover(messageHash, _signature);

            require(signer == ADMIN_VERIFY_ADDRESS, "invalid signature");
        }
        require(bondingStarted, "Bonding not started");
        // Call getBaseTokenConfig once and destructure
        (
            ,
            uint256 MAX_BASE_BUY_A,
            uint256 MAX_BASE_BUY_A_EACH_TX,
            uint256 REQUIRE_BASE_STAKE_A,

        ) = IController(CONTROLLER).getBaseTokenConfig(BASE_TOKEN);

        if (REQUIRE_BASE_STAKE_A > 0) {
            uint256 stakedAmount = IStaking(STAKING_ADDRESS).getStakedAmount(
                BASE_TOKEN,
                msg.sender
            );
            require(
                stakedAmount >= REQUIRE_BASE_STAKE_A,
                "Insufficient base tokens staked"
            );
        }

        require(initialized, "Not initialized");
        require(!bondingComplete, "Bonding complete");
        require(
            _baseAmount > 0 && _baseAmount <= MAX_BASE_BUY_A_EACH_TX,
            "invalid base amount"
        );
        if (Cashier.isNative(BASE_TOKEN)) {
            require(msg.value == _baseAmount, "Incorrect BNB amount sent");
        } else {
            require(msg.value == 0, "Do not send BNB when using ERC20");
        }
        // Deposit base token (BNB or ERC20)
        Cashier.deposit(BASE_TOKEN, msg.sender, _baseAmount);

        // Handle fee and netBase
        uint256 acceptedBaseAmount = _baseAmount;
        if (totalBaseRaised + acceptedBaseAmount > FINAL_BASE_AMOUNT) {
            acceptedBaseAmount = FINAL_BASE_AMOUNT - totalBaseRaised;
        }
        uint256 userMaxBuyAmount = MAX_BASE_BUY_A + _bonusMaxAmount;
        if (
            userTotalBought[msg.sender] + acceptedBaseAmount > userMaxBuyAmount
        ) {
            acceptedBaseAmount = userMaxBuyAmount - userTotalBought[msg.sender];
        }

        uint256 refund = _baseAmount - acceptedBaseAmount;
        (uint256 FEE_PERCENT, uint256 BURN_PERCENT) = IController(CONTROLLER)
            .getFeeAndBurnPercents();
        uint256 fee = (acceptedBaseAmount * FEE_PERCENT) / DEMI;
        uint256 baseUsed = acceptedBaseAmount - fee;

        if (fee > 0) {
            if (Cashier.isNative(BASE_TOKEN)) {
                IStaking(STAKING_ADDRESS).receiveFeeDistribution{value: fee}();
            } else {
                IERC20(BASE_TOKEN).safeTransfer(
                    0x000000000000000000000000000000000000dEaD,
                    fee
                );
            }
        }

        uint256 remainingTokens = BONDING_SUPPLY - totalTokensSold;

        uint256 tokenAmount = getTokensForBase(baseUsed);
        bool finalBuy = totalBaseRaised + acceptedBaseAmount >=
            FINAL_BASE_AMOUNT;
        if (tokenAmount > remainingTokens) {
            tokenAmount = remainingTokens;
        }

        uint256 burnAmount = (tokenAmount * BURN_PERCENT) / DEMI;
        uint256 userReceive = tokenAmount - burnAmount;

        totalTokensSold += tokenAmount;
        totalBaseRaised += baseUsed;
        userTotalBought[msg.sender] += baseUsed;

        token.safeTransfer(msg.sender, userReceive);
        if (burnAmount > 0) {
            ITokenERC20(address(token)).burn(burnAmount);
        }
        emit Trade(
            msg.sender,
            TradeType.Buy,
            userReceive,
            acceptedBaseAmount,
            getCurrentPrice(),
            totalTokensSold,
            block.timestamp
        );

        if (refund > 0) {
            Cashier.withdraw(BASE_TOKEN, msg.sender, refund);
        }

        if (finalBuy) {
            bondingComplete = true;
            bondingCompleteAt = block.timestamp;
            emit BondingEnd(block.timestamp);
            if (IS_AUTO_ADD_LIQUIDITY == true) {
                _addLiquidity();
            }
        }

        return userReceive;
    }

    function sell(uint256 tokenAmount) external nonReentrant returns (uint256) {
        require(bondingStarted, "Bonding not started");
        require(initialized, "Not initialized");
        require(!bondingComplete, "Bonding complete");
        require(tokenAmount > 0, "Invalid token amount");

        (uint256 FEE_PERCENT, uint256 BURN_PERCENT) = IController(CONTROLLER)
            .getFeeAndBurnPercents();

        uint256 burnAmount = (tokenAmount * BURN_PERCENT) / DEMI;
        uint256 sellAmount = tokenAmount - burnAmount;
        uint256 baseAmount = getBaseForTokens(sellAmount);
        require(baseAmount > 0, "Invalid Base amount");
        require(
            baseAmount <= Cashier.balanceOf(BASE_TOKEN, address(this)),
            "Insufficient Base balance"
        );

        uint256 fee = (baseAmount * FEE_PERCENT) / DEMI;
        if (fee > 0) {
            if (Cashier.isNative(BASE_TOKEN)) {
                IStaking(STAKING_ADDRESS).receiveFeeDistribution{value: fee}();
            } else {
                IERC20(BASE_TOKEN).safeTransfer(
                    0x000000000000000000000000000000000000dEaD,
                    fee
                );
            }
        }
        uint userReceiveBase = baseAmount - fee;

        token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        if (burnAmount > 0) {
            ITokenERC20(address(token)).burn(burnAmount);
        }

        Cashier.withdraw(BASE_TOKEN, msg.sender, userReceiveBase);

        totalTokensSold -= sellAmount;
        totalBaseRaised -= baseAmount;

        emit Trade(
            msg.sender,
            TradeType.Sell,
            tokenAmount,
            userReceiveBase,
            getCurrentPrice(),
            totalTokensSold,
            block.timestamp
        );
        return userReceiveBase;
    }

    function addLiquidity() external onlyOwnerOrAdmin {
        _addLiquidity();
    }

    function _addLiquidity() internal {
        require(bondingComplete, "Bonding not complete");
        require(!isLiquidityAdded, "Liquidity already added");
        isLiquidityAdded = true;

        address pool = IPancakeV3Factory(PANCAKE_V3_FACTORY).getPool(
            address(token),
            BASE_TOKEN,
            POOL_FEE
        );

        require((pool != address(0)), "Pool not deployed!");

        uint finalBaseAmount = Cashier.balanceOf(BASE_TOKEN, address(this));
        if (Cashier.isNative(BASE_TOKEN)) {
            IWETH9(BASE_TOKEN).deposit{value: finalBaseAmount}();
        }

        (address token0, address token1) = address(token) < BASE_TOKEN
            ? (address(token), BASE_TOKEN)
            : (BASE_TOKEN, address(token));

        uint finalLiquiditySupply = token.balanceOf(address(this));
        if (finalLiquiditySupply > LIQUIDITY_SUPPLY) {
            finalLiquiditySupply = LIQUIDITY_SUPPLY;
        }

        (uint256 amount0Desired, uint256 amount1Desired) = address(token) <
            BASE_TOKEN
            ? (finalLiquiditySupply, finalBaseAmount)
            : (finalBaseAmount, finalLiquiditySupply);

        token.approve(NONFUNGIBLE_POSITION_MANAGER, finalLiquiditySupply);
        IERC20(BASE_TOKEN).approve(
            NONFUNGIBLE_POSITION_MANAGER,
            finalBaseAmount
        );

        uint256 tokenId;
        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 15 minutes
            });

        (tokenId, , , ) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).mint(params);

        // INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).transferFrom(
        //     address(this),
        //     0x000000000000000000000000000000000000dEaD,
        //     tokenId
        // );
        POSITION_NFT_ID = tokenId;

        ITokenERC20(address(token)).launch();

        emit LiquidityAdded(
            address(this),
            token0,
            token1,
            pool,
            finalLiquiditySupply,
            finalBaseAmount,
            block.timestamp
        );
    }

    function collectRemaining(
        address tokenAddr,
        address to
    ) external onlyRole(ADMIN_ROLE) {
        require(bondingComplete, "Bonding not complete");
        require(to != address(0), "Invalid address");
        uint256 amount = Cashier.balanceOf(tokenAddr, address(this));
        require(amount > 0, "No tokens to collect");
        Cashier.withdraw(tokenAddr, to, amount);
    }

    function setAutoAddLiquidity(
        bool _isAutoAddLiquidity
    ) external onlyRole(ADMIN_ROLE) {
        IS_AUTO_ADD_LIQUIDITY = _isAutoAddLiquidity;
    }

    function setAdminVerifyAddress(
        address _adminVerifyAddress
    ) external onlyRole(ADMIN_ROLE) {
        ADMIN_VERIFY_ADDRESS = _adminVerifyAddress;
    }

    function startBonding() external onlyOwnerOrAdmin {
        require(!bondingStarted, "Bonding already started");
        bondingStarted = true;
        emit BondingStart(block.timestamp);
    }

    function collectFees(address _receiver) external onlyOwner {
        require(POSITION_NFT_ID != 0, "Invalid POSITION_NFT_ID");
        require(_receiver != address(0), "Invalid receiver");

        INonfungiblePositionManager.CollectParams
            memory params = INonfungiblePositionManager.CollectParams({
                tokenId: POSITION_NFT_ID,
                recipient: _receiver,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).collect(
            params
        );
    }
}
