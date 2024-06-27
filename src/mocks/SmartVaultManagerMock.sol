// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EUROsMock} from "../../src/mocks/EUROsMock.sol";
import {INFTMetadataGenerator} from "src/interfaces/INFTMetadataGenerator.sol";
import {IEUROs} from "src/interfaces/IEUROs.sol";

import {ISmartVaultManagerMock} from "src/mocks/ISmartVaultManagerMock.sol";
// import {ISmartVault} from "src/interfaces/ISmartVault.sol";
import {ISmartVault} from "src/interfaces/ISmartVault.sol";
import {ISmartVaultDeployer} from "src/interfaces/ISmartVaultDeployer.sol";
import {ISmartVaultIndex} from "src/interfaces/ISmartVaultIndex.sol";
import {VaultifyErrors} from "src/libraries/VaultifyErrors.sol";
import {VaultifyEvents} from "src/libraries/VaultifyEvents.sol";
import {VaultifyStructs} from "src/libraries/VaultifyStructs.sol";

/// @title SmartVaultManager
/// OUAIL Allows the vault manager to set important  state variables, generate NFT metadata of the vault, deploy a new smart vault.
/// @notice Contract managing vault deployments, controls admin data which dictates behavior of Smart Vaults.
/// @dev Manages fee rates, collateral rates, dependency addresses, managed by The Standard.

contract SmartVaultManagerMock is
    ISmartVaultManagerMock,
    Initializable,
    ContextUpgradeable,
    OwnableUpgradeable,
    ERC721Upgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant HUNDRED_PRC = 1e5; // 100%;

    address public protocol;
    address public liquidator;
    address public euros;
    uint256 public collateralRate;
    address public tokenManager;
    address public smartVaultDeployer;
    ISmartVaultIndex private smartVaultIndexContract;
    uint256 public lastTokenId;
    address public nftMetadataGenerator;
    uint256 public mintFeeRate;
    uint256 public burnFeeRate;
    uint256 public swapFeeRate;
    address public weth;
    address public swapRouter;
    address public swapRouter2;

    modifier onlyLiquidator() {
        require(_msgSender() == liquidator, "err-invalid-liquidator");
        _;
    }

    /// @dev To prevent the implementation contract from being used, we invoke the _disableInitializers
    /// function in the constructor to automatically lock it when it is deployed.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _smartVaultIndex,
        uint256 _mintFeeRate,
        uint256 _burnFeeRate,
        uint256 _swapFeeRate,
        uint256 _collateralRate,
        address _protocol,
        address _liquidator,
        address _tokenManager,
        address _smartVaultDeployer,
        address _euros,
        address _weth
    ) external initializer {
        __Ownable_init(_msgSender());
        __Context_init();
        __ERC721_init("The Standard Smart Vault Manager", "TSVAULTMAN");
        setMintFeeRate(_mintFeeRate);
        setBurnFeeRate(_burnFeeRate);
        setSwapFeeRate(_swapFeeRate);
        setSmartVaultDeployer(_smartVaultDeployer);
        setProtocolAddress(_protocol);
        setLiquidatorAddress(_liquidator);
        setWethAddress(address(_weth));
        smartVaultIndexContract = ISmartVaultIndex(_smartVaultIndex);
        euros = _euros;
        tokenManager = _tokenManager;
        collateralRate = _collateralRate;
    }

    function mintNewVault() external returns (uint256 tokenId, address vault) {
        // increment tokenId by 1
        tokenId = lastTokenId + 1;

        // // Mint the smart vault to the caller
        _safeMint(_msgSender(), tokenId);

        // set the tokenId to the last token Id
        lastTokenId = tokenId;

        // Deploy the smart vault
        vault = ISmartVaultDeployer(smartVaultDeployer).deploy(
            address(this),
            _msgSender(),
            euros
        );

        // // Add the vault to the smart vault index
        smartVaultIndexContract.addVaultAddress(tokenId, payable(vault));

        // // Grante the vault Burn and MINT role
        IEUROs(euros).grantRole(IEUROs(euros).MINTER_ROLE(), address(vault));
        IEUROs(euros).grantRole(IEUROs(euros).BURNER_ROLE(), address(vault));

        emit VaultifyEvents.VaultDeployed(vault, _msgSender(), euros, tokenId);
    }

    // returns VaultifyStructs.SmartVaultData struct type array
    function getVaults()
        external
        view
        returns (VaultifyStructs.SmartVaultData[] memory)
    {
        // Get vaults who belong to the user by ids from smartcontractIndex;
        uint256[] memory tokenIds = smartVaultIndexContract.getTokenIds(
            _msgSender()
        );

        uint256 tokenIdsLengh = tokenIds.length;

        // create fixed sized array to store data of each smart vault based on their IDs
        VaultifyStructs.SmartVaultData[]
            memory vaultData = new VaultifyStructs.SmartVaultData[](
                tokenIdsLengh
            );

        for (uint256 i = 0; i < tokenIdsLengh; i++) {
            uint256 tokenId = tokenIds[i];
            vaultData[i] = VaultifyStructs.SmartVaultData({
                tokenId: tokenId,
                collateralRate: collateralRate,
                mintFeeRate: mintFeeRate,
                burnFeeRate: burnFeeRate,
                status: ISmartVault(
                    smartVaultIndexContract.getVaultAddress(tokenId)
                ).vaultStatus()
            });
        }

        return vaultData;
    }

    function tokenURI(
        uint256 _tokenId
    ) public view virtual override returns (string memory) {
        VaultifyStructs.VaultStatus memory vaultStatus = ISmartVault(
            smartVaultIndexContract.getVaultAddress(_tokenId)
        ).vaultStatus();
        return
            // Generate metadata based on the vault status and tokenId
            INFTMetadataGenerator(nftMetadataGenerator).generateNFTMetadata(
                _tokenId,
                vaultStatus
            );
    }

    function liquidateVault(uint256 _tokenId) external onlyLiquidator {
        // Retrieve vault with the tokenId
        ISmartVault vault = ISmartVault(
            smartVaultIndexContract.getVaultAddress(_tokenId)
        );

        try vault.underCollateralized() returns (bool _undercollateralised) {
            if (!_undercollateralised)
                revert VaultifyErrors.VaultNotUnderCollateralized(
                    address(vault)
                );

            // liquidate vault
            vault.liquidate();

            // REVOKE ROLE
            IEUROs(euros).revokeRole(
                IEUROs(euros).MINTER_ROLE(),
                address(vault)
            );

            IEUROs(euros).revokeRole(
                IEUROs(euros).BURNER_ROLE(),
                address(vault)
            );

            // emit VaultLiquidated()
            emit VaultifyEvents.VaultLiquidated(address(vault));
        } catch {
            revert("other-liquidation-error");
        }
    }

    // Liquidate vault(); todo later;

    // setter functions //
    function totalSupply() external view returns (uint256) {
        return lastTokenId;
    }

    function setMintFeeRate(uint256 _mintFeeRate) public onlyOwner {
        mintFeeRate = _mintFeeRate;
    }

    function setBurnFeeRate(uint256 _burnFeeRate) public onlyOwner {
        burnFeeRate = _burnFeeRate;
    }

    function setSwapFeeRate(uint256 _swapFeerate) public onlyOwner {
        swapFeeRate = _swapFeerate;
    }

    function setWethAddress(address _weth) public onlyOwner {
        weth = _weth;
    }

    function setSwapRouter2(address _swapRouter) public onlyOwner {
        swapRouter2 = _swapRouter;
    }

    function setNFTMetadataGenerator(
        address _nftMetadataGenerator
    ) public onlyOwner {
        nftMetadataGenerator = _nftMetadataGenerator;
    }

    function setSmartVaultDeployer(
        address _smartVaultDeployer
    ) public onlyOwner {
        smartVaultDeployer = _smartVaultDeployer;
    }

    function setProtocolAddress(address _protocol) public onlyOwner {
        protocol = _protocol;
    }

    function setLiquidatorAddress(address _liquidator) public onlyOwner {
        liquidator = _liquidator;
    }

    // // Also Added function to fix bug in LiquidationPool
    // Create a function that get invoked when a burn, mint, transfer of tokens is being made
    function grantPoolBurnApproval(address poolAddr) public onlyOwner {
        // Grant burner role to LiquidityPool for EURO
        IEUROs(euros).grantRole(IEUROs(euros).BURNER_ROLE(), poolAddr);
    }

    function revokePoolBurnApproval(address poolAddr) public onlyOwner {
        // Grant burner role to LiquidityPool for EURO
        IEUROs(euros).revokeRole(IEUROs(euros).BURNER_ROLE(), poolAddr);
    }

    // Triggerd when a NFT is minted or transffered
    function _update(
        address _to,
        uint256 _tokenId,
        address _auth
    ) internal override returns (address) {
        // update return the prevouis owner
        address _from = super._update(_to, _tokenId, _auth);
        smartVaultIndexContract.transferTokenId(_from, _to, _tokenId);
        if (address(_from) != address(0)) {
            address vaultAddress = smartVaultIndexContract.getVaultAddress(
                _tokenId
            );
            ISmartVault(vaultAddress).setOwner(_to);
        }
        emit VaultifyEvents.VaultTransferred(_tokenId, _from, _to);

        return _from;
    }

    // // TODO test transfer
    // function _afterTokenTransfer(
    //     //
    //     address _from,
    //     address _to,
    //     uint256 _tokenId,
    //     uint256
    // ) internal override {
    //     smartVaultIndex.transferTokenId(_from, _to, _tokenId);
    //     if (address(_from) != address(0))
    //         ISmartVault(smartVaultIndex.getVaultAddress(_tokenId)).setOwner(
    //             _to
    //         );
    //     emit VaultTransferred(_tokenId, _from, _to);
    // }
}
