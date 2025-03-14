// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {EIP5095PropertyPlus} from "./EIP5095.prop.sol";
import {MockFeeModule} from "../mocks/MockFeeModule.sol";
import {MockResolver} from "../mocks/MockResolver.sol";
import {MockRewardProxyModule, MockBadRewardProxyModule} from "../mocks/MockRewardProxy.sol";
import {ModuleAccessor} from "src/utils/ModuleAccessor.sol";
import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {FeeModule} from "src/modules/FeeModule.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {Casting} from "src/utils/Casting.sol";
import "src/Types.sol";
import "src/Constants.sol";
import {Errors} from "src/Errors.sol";

abstract contract PrincipalTokenTest is EIP5095PropertyPlus {
    using stdStorage for StdStorage;
    using Casting for *;

    address pointer;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          Factory                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function args() external view returns (Factory.ConstructorArg memory) {
        return Factory.ConstructorArg({
            expiry: expiry,
            resolver: address(resolver),
            yt: address(yt),
            accessManager: address(accessManager),
            modules: pointer
        });
    }

    function s_treasury() external view returns (address) {
        return treasury;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          SetUp                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public virtual override {
        super.setUp();

        bytes32 salt = keccak256("salt");
        principalToken =
            PrincipalToken(vm.computeCreate2Address(salt, keccak256(type(PrincipalToken).creationCode), address(this)));
        resolver = new MockResolver(address(target));
        feeModule = new MockFeeModule();
        bytes memory immutableArgs = abi.encode(rewardTokens, multiRewardDistributor);
        rewardProxy =
            MockRewardProxyModule(LibClone.clone(mockRewardProxy_logic, abi.encode(principalToken, immutableArgs)));
        rewardProxy.initialize();

        address[] memory modules = new address[](MAX_MODULES);
        ModuleAccessor.set(modules, FEE_MODULE_INDEX, address(feeModule));
        ModuleAccessor.set(modules, REWARD_PROXY_MODULE_INDEX, address(rewardProxy));
        pointer = SSTORE2.write(abi.encode(modules));
        FeePcts feePcts = FeePctsLib.pack(5_000, 0, 100, 0, 0); // 50% split fee, 0 issuance fee, 1% performance fee, 0 redemption fee, 0 performance post-settlement fee
        setMockFeePcts(address(feeModule), feePcts);

        accessManager = AccessManager(makeAddr("accessManager"));
        deployCodeTo("src/modules/AccessManager.sol:AccessManager", address(accessManager));
        accessManager.initializeOwner(curator);
        yt = YieldToken(deployCode("src/tokens/YieldToken.sol", abi.encode(principalToken)));
        PrincipalToken instance = new PrincipalToken{salt: salt}();
        require(instance == principalToken, "Setup failed to deploy PrincipalToken correctly");

        _label();
    }

    function setFeePcts(FeePcts v) public {
        setMockFeePcts(address(feeModule), v);
    }

    function setBadRewardProxy() public returns (address badRewardProxy) {
        address implementation = address(new MockBadRewardProxyModule());
        badRewardProxy = LibClone.clone(implementation, abi.encode(address(principalToken), abi.encode(rewardTokens)));
        MockBadRewardProxyModule(badRewardProxy).initialize();
        MockBadRewardProxyModule(badRewardProxy).i_principalToken();

        address p = principalToken.s_modules();
        address[] memory modules = ModuleAccessor.read(p);
        ModuleAccessor.set(modules, REWARD_PROXY_MODULE_INDEX, badRewardProxy);
        p = SSTORE2.write(abi.encode(modules));

        vm.prank(address(principalToken.i_factory()));
        principalToken.setModules(p);
    }
}
