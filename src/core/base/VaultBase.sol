// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./Controllable.sol";
import "../libs/ConstantsLib.sol";
import "../../interfaces/IVault.sol";
import "../../interfaces/IStrategy.sol";
import "../../interfaces/IPriceReader.sol";
import "../../interfaces/IPlatform.sol";
import "../../interfaces/IAprOracle.sol";

/// @notice Base vault implementation.
///         User can deposit and withdraw a changing set of assets managed by the strategy.
///         Start price of vault share is $1.
/// @dev Used by all vault implementations (CVault, RVault, etc)
/// @author Alien Deployer (https://github.com/a17)
abstract contract VaultBase is Controllable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IVault {
    using SafeERC20 for IERC20;

    //region ----- Constants -----

    /// @dev Version of VaultBase implementation
    string public constant VERSION_VAULT_BASE = '1.0.0';

    /// @dev Delay between deposits/transfers and withdrawals
    uint internal constant _WITHDRAW_REQUEST_BLOCKS = 5;

    /// @dev Initial shares of the vault minted at the first deposit and sent to the dead address.
    uint internal constant _INITIAL_SHARES = 1e15;

    /// @dev Delay for calling strategy.doHardWork() on user deposits
    uint internal constant _MIN_HARDWORK_DELAY = 3600;

    //endregion -- Constants -----

    //region ----- Storage -----

    /// @inheritdoc IVault
    IStrategy public strategy;

    /// @inheritdoc IVault
    uint public maxSupply;

    /// @inheritdoc IVault
    uint public tokenId;

    /// @dev Trigger doHardwork on invest action. Enabled by default.
    bool public doHardWorkOnDeposit;

    /// @dev Prevents manipulations with deposit and withdraw in short time.
    ///      For simplification we are setup new withdraw request on each deposit/transfer.
    mapping(address msgSender => uint blockNumber) internal _withdrawRequests;

    /// @dev Immutable vault type ID
    string internal _type;

    /// @dev This empty reserved space is put in place to allow future versions to add new.
    /// variables without shifting down storage in the inheritance chain.
    /// Total gap == 50 - storage slots used.
    uint[50 - 6] private __gap;

    //endregion -- Storage -----

    //region ----- Init -----

    function __VaultBase_init(
        address platform_,
        string memory type_,
        address strategy_,
        string memory name_,
        string memory symbol_,
        uint tokenId_
    ) internal onlyInitializing {
        __Controllable_init(platform_);
        __ERC20_init(name_, symbol_);
        _type = type_;
        strategy = IStrategy(strategy_);
        tokenId = tokenId_;
        __ReentrancyGuard_init();
        doHardWorkOnDeposit = true;
    }

    //endregion -- Init -----

    //region ----- Callbacks -----

    /// @dev Need to receive ETH for HardWork and re-balance gas compensation
    receive() external payable {}

    //endregion -- Callbacks -----

    //region ----- Restricted actions -----

    /// @inheritdoc IVault
    function setMaxSupply(uint maxShares) public virtual onlyGovernanceOrMultisig {
        maxSupply = maxShares;
        emit MaxSupply(maxShares);
    }

    /// @inheritdoc IVault
    function setDoHardWorkOnDeposit(bool value) external onlyGovernanceOrMultisig {
        doHardWorkOnDeposit = value;
        emit DoHardWorkOnDepositChanged(doHardWorkOnDeposit, value);
    }

    /// @inheritdoc IVault
    function doHardWork() external {
        IPlatform _platform = IPlatform(platform());
        require(
            msg.sender == _platform.hardWorker() || _platform.isOperator(msg.sender),
            "VaultBase: you are not HardWorker or operator"
        );
        uint startGas = gasleft();
        strategy.doHardWork();
        uint gasUsed = startGas - gasleft();
        uint gasCost = gasUsed * tx.gasprice;
        bool compensated;
        if (gasCost > 0) {
            bool canCompensate = payable(address(this)).balance >= gasCost;
            if (canCompensate) {
                (bool success, ) = msg.sender.call{value: gasCost}("");
                require(success, "Vault: native transfer failed");
                compensated = true;
            } else {
                (uint _tvl,) = tvl();
                // todo IPlatform variable
                if (_tvl < 100e18) {
                    revert("Vault: not enough balance to pay gas");
                }
            }
        }

        emit HardWorkGas(gasUsed, gasCost, compensated);
    }

    //endregion -- Restricted actions ----

    //region ----- User actions -----

    /// @inheritdoc IVault
    function depositAssets(address[] memory assets_, uint[] memory amountsMax, uint minSharesOut) external virtual nonReentrant {
        if (doHardWorkOnDeposit && block.timestamp > strategy.lastHardWork() + _MIN_HARDWORK_DELAY) {
            strategy.doHardWork();
        }

        uint _totalSupply = totalSupply();
        uint totalValue = strategy.total();

        require(_totalSupply == 0 || totalValue > 0, "Vault: fuse trigger");

        address[] memory assets = strategy.assets();
        address underlying = strategy.underlying();

        uint len = amountsMax.length;
        require(len == assets_.length, "Vault: incorrect amounts length");

        uint[] memory amountsConsumed;
        uint value;

        if (len == 1 && underlying != address(0) && underlying == assets_[0]) {
            value = amountsMax[0];
            IERC20(underlying).safeTransferFrom(msg.sender, address(strategy), value);
            (amountsConsumed) = strategy.depositUnderlying(value);
        } else {
            (amountsConsumed, value) = strategy.previewDepositAssets(assets_, amountsMax);
            for (uint i; i < len; ++i) {
                IERC20(assets[i]).safeTransferFrom(msg.sender, address(strategy), amountsConsumed[i]);
            }
            value = strategy.depositAssets(amountsConsumed);
        }

        require(value > 0, "Vault: zero invest amount");

        uint mintAmount = _mintShares(_totalSupply, value, totalValue, amountsConsumed, minSharesOut);

        _withdrawRequests[msg.sender] = block.number;

        emit DepositAssets(msg.sender, assets_, amountsConsumed, mintAmount);
    }

    /// @inheritdoc IVault
    function withdrawAssets(address[] memory assets_, uint amountShares, uint[] memory minAssetAmountsOut) external virtual nonReentrant {
        require(amountShares > 0, "Vault: zero amount");
        require(amountShares <= balanceOf(msg.sender), "Vault: not enough balance");
        require(assets_.length == minAssetAmountsOut.length, "Vault: incorrect length");

        _beforeWithdraw();

        uint _totalSupply = totalSupply();
        uint totalValue = strategy.total();

        uint[] memory amountsOut;
        address underlying = strategy.underlying();
        bool isUnderlyingWithdrawal = assets_.length == 1 && underlying != address(0) && underlying == assets_[0];

        // fuse is not triggered
        if (totalValue > 0) {
            uint value = amountShares * totalValue / _totalSupply;
            if (isUnderlyingWithdrawal) {
                amountsOut = new uint[](1);
                amountsOut[0] = value;
                strategy.withdrawUnderlying(amountsOut[0], msg.sender);
            } else {
                amountsOut = strategy.withdrawAssets(assets_, value, msg.sender);
            }
        } else {
            if (isUnderlyingWithdrawal) {
                amountsOut = new uint[](1);
                amountsOut[0] = amountShares * IERC20(underlying).balanceOf(address(strategy)) / _totalSupply;
                strategy.withdrawUnderlying(amountsOut[0], msg.sender);
            } else {
                amountsOut = strategy.transferAssets(amountShares, _totalSupply, msg.sender);
            }
        }

        uint len = amountsOut.length;
        for (uint i; i < len; ++i) {
            require(amountsOut[i] >= minAssetAmountsOut[i], "Vault: slippage");
        }

        _burn(msg.sender, amountShares);

        emit WithdrawAssets(msg.sender, assets_, amountShares, amountsOut);
    }

    //endregion -- User actions ----

    //region ----- View functions -----

    function VAULT_TYPE() external view returns (string memory) {
        return _type;
    }

    /// @inheritdoc IVault
    function price() external view returns (uint price_, bool trusted_) {
        (address[] memory _assets, uint[] memory _amounts) = strategy.assetsAmounts();
        IPriceReader priceReader = IPriceReader(IPlatform(platform()).priceReader());
        uint _tvl;
        (_tvl,, trusted_) = priceReader.getAssetsPrice(_assets, _amounts);
        uint __totalSupply = totalSupply();
        if (__totalSupply > 0) {
            price_ = _tvl * 1e18 / __totalSupply;
        }
    }

    /// @inheritdoc IVault
    function tvl() public view returns (uint tvl_, bool trusted_) {
        (address[] memory _assets, uint[] memory _amounts) = strategy.assetsAmounts();
        IPriceReader priceReader = IPriceReader(IPlatform(platform()).priceReader());
        (tvl_,, trusted_) = priceReader.getAssetsPrice(_assets, _amounts);
    }

    /// @inheritdoc IVault
    function previewDepositAssets(address[] memory assets_, uint[] memory amountsMax) external view returns (uint[] memory amountsConsumed, uint sharesOut, uint valueOut) {
        (amountsConsumed, valueOut) = strategy.previewDepositAssets(assets_, amountsMax);
        (sharesOut,) = _calcMintShares(totalSupply(), valueOut, strategy.total(), amountsConsumed);
    }

    function getApr() external view returns (uint totalApr, uint strategyApr, address[] memory assetsWithApr, uint[] memory assetsAprs) {
        strategyApr = strategy.lastApr();
        totalApr = strategyApr;
        address[] memory strategyAssets = strategy.assets();
        uint[] memory proportions = strategy.getAssetsProportions();
        address underlying = strategy.underlying();
        uint assetsLengthTmp = strategyAssets.length;
        if (underlying != address(0)) {
            ++assetsLengthTmp;
        }
        address[] memory queryAprAssets = new address[](assetsLengthTmp);
        for (uint i; i < strategyAssets.length; ++i) {
            queryAprAssets[i] = strategyAssets[i];
        }
        if (underlying != address(0)) {
            queryAprAssets[assetsLengthTmp - 1] = underlying;
        }
        uint[] memory queryAprs = IAprOracle(IPlatform(platform()).aprOracle()).getAprs(queryAprAssets);
        assetsLengthTmp = 0;
        for (uint i; i < queryAprs.length; ++i) {
            if (queryAprs[i] > 0) {
                ++assetsLengthTmp;
            }
        }
        assetsWithApr = new address[](assetsLengthTmp);
        assetsAprs = new uint[](assetsLengthTmp);

        uint k;
        for (uint i; i < queryAprs.length; ++i) {
            if (queryAprs[i] > 0) {
                assetsWithApr[k] = queryAprAssets[i];
                assetsAprs[k] = queryAprs[i];
                if (i < strategyAssets.length) {
                    totalApr += assetsAprs[k] * proportions[i] / 1e18;
                } else {
                    totalApr += assetsAprs[k];
                }
                ++k;
            }
        }

    }

    //endregion -- View functions -----

    //region ----- Internal logic -----

    /// @dev Minting shares of the vault to the user's address when he deposits funds into the vault.
    ///
    /// During the first deposit, initial shares are also minted and sent to the dead address.
    /// Initial shares save proportion of value to total supply and share price when all users withdraw all their funds from vault.
    /// It prevent flash loan attacks on users' funds.
    /// Also their presence allows the strategy to work without user funds, providing APR for the logic and the farm, if available.
    /// @param totalSupply_ Total supply of shares before deposit
    /// @param value_ Liquidity value or underlying token amount received after deposit
    /// @param totalValue_ Total liquidity value or underlying token amount before deposit
    /// @param amountsConsumed Amounts of strategy assets consumed during the execution of the deposit.
    ///        Consumed amounts used by calculation of minted amount during the first deposit for setting the first share price to 1 USD.
    /// @param minSharesOut Slippage tolerance. Minimal shares amount which must be received by user after deposit
    /// @return mintAmount Amount of minted shares for the user
    function _mintShares(uint totalSupply_, uint value_, uint totalValue_, uint[] memory amountsConsumed, uint minSharesOut) internal returns (uint mintAmount) {
        uint initialShares;
        (mintAmount, initialShares) = _calcMintShares(totalSupply_, value_,  totalValue_, amountsConsumed);
        require(maxSupply == 0 || mintAmount + totalSupply_ <= maxSupply, "Vault: max supply");

        require(mintAmount >= minSharesOut, "Vault: slippage");

        if (initialShares > 0) {
            _mint(ConstantsLib.DEAD_ADDRESS, initialShares);
        }

        _mint(msg.sender, mintAmount);
    }

    /// @dev Calculating amount of new shares for given deposited value and totals
    function _calcMintShares(uint totalSupply_, uint value_, uint totalValue_, uint[] memory amountsConsumed) internal view returns (uint mintAmount, uint initialShares) {
        if (totalSupply_ > 0) {
            mintAmount = value_ * totalSupply_ / totalValue_;
            initialShares = 0; // hide warning
        } else {
            // calc mintAmount for USD amount of value
            // its setting sharePrice to 1e18
            IPriceReader priceReader = IPriceReader(IPlatform(platform()).priceReader());
            (mintAmount,,) = priceReader.getAssetsPrice(strategy.assets(), amountsConsumed);

            // initialShares for saving share price after full withdraw
            initialShares = _INITIAL_SHARES;
            require(mintAmount >= initialShares * 1000, "Vault: not enough amount to init supply");
            mintAmount -= initialShares;
        }
    }

    function _beforeWithdraw() internal {
        require(_withdrawRequests[msg.sender] + _WITHDRAW_REQUEST_BLOCKS < block.number, "Vault: wait few blocks");
        _withdrawRequests[msg.sender] = block.number;
    }

    function _update(
        address from,
        address to,
        uint value
    ) internal virtual override {
        super._update(from, to, value);
        _withdrawRequests[from] = block.number;
        _withdrawRequests[to] = block.number;
    }

    // function _afterTokenTransfer(
    //     address from,
    //     address to,
    //     uint /*amount*/
    // ) internal override {
    //     _withdrawRequests[from] = block.number;
    //     _withdrawRequests[to] = block.number;
    // }

    //endregion -- Internal logic -----
}
