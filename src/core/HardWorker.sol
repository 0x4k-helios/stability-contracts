// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/Strings.sol";
import "./base/Controllable.sol";
import "./libs/VaultStatusLib.sol";
import "../interfaces/IPlatform.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IVaultManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IHardWorker.sol";
import "../integrations/gelato/IAutomate.sol";
import "../integrations/gelato/IOpsProxyFactory.sol";
import "../integrations/gelato/ITaskTreasuryUpgradable.sol";

/// @notice HardWork resolver and caller. Primary executor is server script, reserve executor is Gelato Automate.
/// @author Alien Deployer (https://github.com/a17)
contract HardWorker is Controllable, IHardWorker {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc IControllable
    string public constant VERSION = "1.0.0";

    address internal constant GELATO_OPS_PROXY_FACTORY = 0xC815dB16D4be6ddf2685C201937905aBf338F5D7;
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    // keccak256(abi.encode(uint256(keccak256("erc7201:stability.HardWorker")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant HARDWORKER_STORAGE_LOCATION = 0xb27d1d090fdefd817c9451b2e705942c4078dc680872cd693dd4ae2b2aaa9000;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @custom:storage-location erc7201:stability.HardWorker
    struct HardWorkerStorage {
        mapping(address => bool) excludedVaults;
        mapping(address caller => bool allowed) dedicatedServerMsgSender;
        address dedicatedGelatoMsgSender;
        ITaskTreasuryUpgradable gelatoTaskTreasury;
        bytes32 gelatoTaskId;
        uint gelatoMinBalance;
        uint gelatoDepositAmount;
        uint delayServer;
        uint delayGelato;
        uint maxHwPerCall;    
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       INITIALIZATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function initialize(
        address platform_,
        address gelatoAutomate,
        uint gelatoMinBalance_,
        uint gelatoDepositAmount_
    ) public initializer payable {
        __Controllable_init(platform_);

        HardWorkerStorage storage $ = _getStorage();
        $.delayServer = 11 hours;
        $.delayGelato = 12 hours;

        emit Delays(11 hours, 12 hours);

        $.maxHwPerCall = 5;
        emit MaxHwPerCall(5);

        if (gelatoAutomate != address(0)) {
            // setup gelato
            $.gelatoMinBalance = gelatoMinBalance_;
            $.gelatoDepositAmount = gelatoDepositAmount_;
            //slither-disable-next-line unused-return
            (address _dedicatedGelatoMsgSender, ) = IOpsProxyFactory(GELATO_OPS_PROXY_FACTORY).getProxyOf(address(this));
            $.dedicatedGelatoMsgSender = _dedicatedGelatoMsgSender;
            IAutomate automate = IAutomate(gelatoAutomate);
            ITaskTreasuryUpgradable _gelatoTaskTreasury = automate.taskTreasury();
            $.gelatoTaskTreasury = _gelatoTaskTreasury;
            emit DedicatedGelatoMsgSender(address(0), _dedicatedGelatoMsgSender);
            // create Gelato Automate task
            ModuleData memory moduleData = ModuleData({
                modules: new Module[](2),
                args: new bytes[](2)
            });
            moduleData.modules[0] = Module.RESOLVER;
            moduleData.modules[1] = Module.PROXY;
            moduleData.args[0] = abi.encode(address(this), abi.encodeCall(this.checkerGelato, ()));
            moduleData.args[1] = bytes("");
            bytes32 id = automate.createTask(
                address(this),
                abi.encode(this.call.selector),
                moduleData,
                address(0)    
            );
            $.gelatoTaskId = id;
            emit GelatoTask(id);
        }

        // storage location check
        // require(HARDWORKER_STORAGE_LOCATION == keccak256(abi.encode(uint256(keccak256("erc7201:stability.HardWorker")) - 1)) & ~bytes32(uint256(0xff)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CALLBACKS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    receive() external payable {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      RESTRICTED ACTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc IHardWorker
    function setDedicatedServerMsgSender(address sender, bool allowed) external onlyGovernanceOrMultisig {
        HardWorkerStorage storage $ = _getStorage();
        require($.dedicatedServerMsgSender[sender] != allowed, "HardWorker: nothing to change");
        $.dedicatedServerMsgSender[sender] = allowed;
        emit DedicatedServerMsgSender(sender, allowed);
    }

    /// @inheritdoc IHardWorker
    function setDelays(uint delayServer_, uint delayGelato_) external onlyGovernanceOrMultisig {
        HardWorkerStorage storage $ = _getStorage();
        require ($.delayServer != delayServer_ || $.delayGelato != delayGelato_, "HardWorker: nothing to change");
        $.delayServer = delayServer_;
        $.delayGelato = delayGelato_;
        emit Delays(delayServer_, delayGelato_);
    }

    /// @inheritdoc IHardWorker
    function setMaxHwPerCall(uint maxHwPerCall_) external onlyOperator {
        HardWorkerStorage storage $ = _getStorage();
        require (maxHwPerCall_ > 0, "HardWorker: wrong");
        $.maxHwPerCall = maxHwPerCall_;
        emit MaxHwPerCall(maxHwPerCall_);
    }

    /// @inheritdoc IHardWorker
    function changeVaultExcludeStatus(address[] memory vaults_, bool[] memory status) external onlyOperator {
        HardWorkerStorage storage $ = _getStorage();
        uint len = vaults_.length;
        require (len == status.length, "HardWorker: wrong input");
        require (len > 0, "HardWorker: zero length");
        IFactory factory = IFactory(IPlatform(platform()).factory());
        for (uint i; i < len; ++i) {
            // calls-loop here is not dangerous
            //slither-disable-next-line calls-loop
            require(factory.vaultStatus(vaults_[i]) != VaultStatusLib.NOT_EXIST, "HardWorker: vault not exist");
            if ($.excludedVaults[vaults_[i]] == status[i]) {
                revert('HardWorker: vault already has this exclude status');
            } else {
                $.excludedVaults[vaults_[i]] = status[i];
                emit VaultExcludeStatusChanged(vaults_[i], status[i]);
            }
        }
    }

    /// @inheritdoc IHardWorker
    function call(address[] memory vaults) external {
        HardWorkerStorage storage $ = _getStorage();

        uint startGas = gasleft();

        bool isServer = $.dedicatedServerMsgSender[msg.sender];
        require(
            isServer || msg.sender == $.dedicatedGelatoMsgSender,
            "HardWorker: only dedicated senders"
        );

        if (!isServer) {
            ITaskTreasuryUpgradable _treasury = $.gelatoTaskTreasury;
            uint bal = _treasury.userTokenBalance(address(this), ETH);
            if (bal < $.gelatoMinBalance) {
                uint contractBal = address(this).balance;
                uint depositAmount = $.gelatoDepositAmount;
                require(contractBal >= depositAmount, "HardWorker: not enough ETH");
                _treasury.depositFunds{value: depositAmount}(
                    address(this),
                    ETH,
                    0
                );
                emit GelatoDeposit(depositAmount);
            }
        }

        uint _maxHwPerCall = $.maxHwPerCall;
        uint vaultsLength = vaults.length;
        uint counter;
        for (uint i; i < vaultsLength; ++i) {
            IVault vault = IVault(vaults[i]);
            try vault.doHardWork() {} catch Error(string memory _err) {
                revert(string(abi.encodePacked("Vault error: 0x", Strings.toHexString(address(vault)), " ", _err)));
            } catch (bytes memory _err) {
                revert(string(abi.encodePacked("Vault low-level error: 0x", Strings.toHexString(address(vault)), " ", string(_err))));
            }
            ++counter;
            if (counter >= _maxHwPerCall) {
                break;
            }
        }

        uint gasUsed = startGas - gasleft();
        uint gasCost = gasUsed * tx.gasprice;

        if (isServer && gasCost > 0 && address(this).balance >= gasCost) {
            //slither-disable-next-line unused-return
            (bool success, ) = msg.sender.call{value: gasCost}("");
            require(success, "HardWorker: native transfer failed");
        }

        emit Call(counter, gasUsed, gasCost, isServer);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getDelays() external view returns (uint delayServer, uint delayGelato) {
        HardWorkerStorage storage $ = _getStorage();
        delayServer = $.delayServer;
        delayGelato = $.delayGelato;
    }

    /// @inheritdoc IHardWorker
    function dedicatedServerMsgSender(address sender) external view returns(bool allowed) {
        return _getStorage().dedicatedServerMsgSender[sender];
    }

    /// @inheritdoc IHardWorker
    function dedicatedGelatoMsgSender() external view returns(address) {
        return _getStorage().dedicatedGelatoMsgSender;
    }

    /// @inheritdoc IHardWorker
    function gelatoMinBalance() external view returns(uint) {
        return _getStorage().gelatoMinBalance;
    }

    /// @inheritdoc IHardWorker
    function maxHwPerCall() external view returns(uint) {
        return _getStorage().maxHwPerCall;
    }

    /// @inheritdoc IHardWorker
    function checkerServer() external view returns (bool canExec, bytes memory execPayload) {
        return _checker(_getStorage().delayServer);
    }

    /// @inheritdoc IHardWorker
    function checkerGelato() external view returns (bool canExec, bytes memory execPayload) {
        return _checker(_getStorage().delayGelato);
    }

    /// @inheritdoc IHardWorker
    function gelatoBalance() external view returns(uint) {
        return _getStorage().gelatoTaskTreasury.userTokenBalance(address(this), ETH);
    }

    /// @inheritdoc IHardWorker
    function excludedVaults(address vault) external view returns (bool) {
        return _getStorage().excludedVaults[vault];
    }

    /// @inheritdoc IHardWorker
    function gelatoTaskId() external view returns(bytes32) {
        return _getStorage().gelatoTaskId;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       INTERNAL LOGIC                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getStorage() private pure returns (HardWorkerStorage storage $) {
        assembly {
            $.slot := HARDWORKER_STORAGE_LOCATION
        }
    }

    function _checker(uint delay_) internal view returns (bool canExec, bytes memory execPayload) {
        HardWorkerStorage storage $ = _getStorage();
        IPlatform _platform = IPlatform(platform());
        IFactory factory = IFactory(_platform.factory());
        address[] memory vaults = IVaultManager(_platform.vaultManager()).vaultAddresses();
        uint len = vaults.length;
        address[] memory vaultsForHardWork = new address[](len);
        uint counter;
        for (uint i; i < len; ++i) {
            if (!$.excludedVaults[vaults[i]]) {
                IVault vault = IVault(vaults[i]);
                IStrategy strategy = vault.strategy();
                //slither-disable-next-line unused-return
                (uint tvl,) = vault.tvl();
                if(
                    tvl > 0
                    && block.timestamp - strategy.lastHardWork() > delay_
                    && factory.vaultStatus(vaults[i]) == VaultStatusLib.ACTIVE
                ) {
                    ++counter;
                    vaultsForHardWork[i] = vaults[i];
                }
            }
        }

        if (counter == 0) {
            return (false, bytes("No ready vaults"));
        } else {
            address[] memory vaultsResult = new address[](counter);
            uint j;
            for (uint i; i < len; ++i) {
                if (vaultsForHardWork[i] != address(0)) {
                    vaultsResult[j] = vaultsForHardWork[i];
                    ++j;
                }
            }

            return (true, abi.encodeWithSelector(HardWorker.call.selector, vaultsResult));
        }
    }
}
