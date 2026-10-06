// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/src/Test.sol";
import {SymTest} from "halmos-cheatcodes/src/SymTest.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import "src/Types.sol";

using SafeCastLib for uint256;

contract PackingSymTest is Test, SymTest {
    function check_Pack(uint128 a, uint128 b) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        assert(Packing.unwrap(packed) == (uint256(a) << 128) | uint256(b));
    }

    function check_Pack_Unpack(uint128 a, uint128 b) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        (uint128 ua, uint128 ub) = Packing.unpack(packed);
        assert(ua == a);
        assert(ub == b);
    }

    function check_Value0_Value1(uint128 a, uint128 b) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        assert(Packing.value0(packed) == a);
        assert(Packing.value1(packed) == b);
    }

    function check_Add(uint256 a, uint128 b, uint128 c) public pure {
        uint256 mask = type(uint128).max;

        Uint128x2 result = Packing.add(Uint128x2.wrap(a), b, c);
        uint256 lower = (a & mask) + uint256(c);
        uint256 upper = (a >> 128) + uint256(b);
        assert(Packing.unwrap(result) & mask == lower);
        assert(Packing.unwrap(result) >> 128 == upper);
    }

    function check_RAdd(uint256 a, uint256 b) public pure {
        Uint128x2 result = Packing.radd(Uint128x2.wrap(a), Uint128x2.wrap(b));

        uint256 mask = type(uint128).max;
        uint256 lower = (a & mask) + (b & mask);
        uint256 upper = (a >> 128) + (b >> 128);
        assert(Packing.unwrap(result) & mask == lower);
        assert(Packing.unwrap(result) >> 128 == upper);
    }

    function check_Sub(uint128 a, uint128 b, uint128 c, uint128 d) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        Uint128x2 result = Packing.sub(packed, c, d);
        (uint128 a2, uint128 b2) = Packing.unpack(result);
        assert(a2 == a - c);
        assert(b2 == b - d);
    }
}

contract PackingTest is Test {
    function testFuzz_Pack(uint128 a, uint128 b) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        assertEq(Packing.unwrap(packed), (uint256(a) << 128) | uint256(b), "pack");
    }

    function test_Pack_Unpack_MaxValues() public pure {
        uint128 a = type(uint128).max;
        uint128 b = type(uint128).max;
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        (uint128 ua, uint128 ub) = Packing.unpack(packed);
        assertEq(ua, a, "unpack max value0");
        assertEq(ub, b, "unpack max value1");
    }

    function test_Pack_Unpack_Zero() public pure {
        uint128 a = 0;
        uint128 b = type(uint128).max;
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        (uint128 ua, uint128 ub) = Packing.unpack(packed);
        assertEq(ua, a, "unpack value0");
        assertEq(ub, b, "unpack value1");
    }

    function testFuzz_Pack_Unpack(uint128 a, uint128 b) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        (uint128 ua, uint128 ub) = Packing.unpack(packed);
        assertEq(ua, a, "unpack value0");
        assertEq(ub, b, "unpack value1");
    }

    function testFuzz_Value0_Value1(uint128 a, uint128 b) public pure {
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        assertEq(Packing.value0(packed), a, "value0");
        assertEq(Packing.value1(packed), b, "value1");
    }

    function test_Add() public pure {
        uint128 a = 1033419303;
        uint128 b = 21129119304394039430;
        uint128 c = 3;
        uint128 d = 490;
        Uint128x2 packed = Packing.pack_uint128x2(a, b);
        Uint128x2 result = Packing.add(packed, c, d);
        (uint128 a2, uint128 b2) = Packing.unpack(result);
        assertEq(a2, a + c, "add value0");
        assertEq(b2, b + d, "add value1");
    }

    function testFuzz_Add(Uint128x2 a, uint128 v1, uint128 v2) public view {
        (bool s1, bytes memory r1) = address(this).staticcall(abi.encodeCall(this._add, (a, v1, v2)));
        (bool s2, bytes memory r2) = address(this).staticcall(abi.encodeCall(this._nativeAdd, (a, v1, v2)));

        assertEq(s1, s2, "success");
        if (s1) {
            assertEq(abi.decode(r1, (uint256)), abi.decode(r2, (uint256)), "result");
        }
    }

    function test_RAdd() public pure {
        uint128 a = 1033419303;
        uint128 b = 21129119304394039430;
        uint128 c = 3;
        uint128 d = 490;
        Uint128x2 packed1 = Packing.pack_uint128x2(a, b);
        Uint128x2 packed2 = Packing.pack_uint128x2(c, d);
        Uint128x2 result = Packing.radd(packed1, packed2);
        (uint128 a2, uint128 b2) = Packing.unpack(result);
        assertEq(a2, a + c, "radd value0");
        assertEq(b2, b + d, "radd value1");
    }

    function testFuzz_RAdd(Uint128x2 a, Uint128x2 b) public view {
        (bool s1, bytes memory r1) = address(this).staticcall(abi.encodeCall(this._radd, (a, b)));
        (bool s2, bytes memory r2) = address(this).staticcall(abi.encodeCall(this._nativeRAdd, (a, b)));

        assertEq(s1, s2, "success");
        if (s1) {
            assertEq(abi.decode(r1, (uint256)), abi.decode(r2, (uint256)), "result");
        }
    }

    function test_Sub() public pure {
        Uint128x2 packed = Packing.pack_uint128x2(10, 20);
        Uint128x2 result = Packing.sub(packed, 3, 4);
        (uint128 a, uint128 b) = Packing.unpack(result);
        assertEq(a, 7, "sub value0");
        assertEq(b, 16, "sub value1");
    }

    function test_Add_RevertWhen_Overflow() public {
        uint128 max = type(uint128).max;
        vm.expectRevert();
        this._add(Packing.pack_uint128x2(max, 29809), 1, 0);
        vm.expectRevert();
        this._add(Packing.pack_uint128x2(2312890, max), 0, 1);
        vm.expectRevert();
        this._add(Packing.pack_uint128x2(2121, type(uint128).max - 0xfff), 0, 0x1000);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_RAdd_RevertWhen_Overflow() public {
        uint128 max = type(uint128).max;
        vm.expectRevert();
        this._radd(Packing.pack_uint128x2(max, 831903843131298798989), Packing.pack_uint128x2(1, 0));
        vm.expectRevert();
        this._radd(Packing.pack_uint128x2(2311232890, max), Packing.pack_uint128x2(0, 1));
        vm.expectRevert();
        this._radd(Packing.pack_uint128x2(2312121, type(uint128).max - 0xabc), Packing.pack_uint128x2(0, 0xabd));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_Sub_RevertWhen_Underflow() public {
        vm.expectRevert();
        this._sub(Packing.pack_uint128x2(0, 100), 1, 0);

        vm.expectRevert();
        this._sub(Packing.pack_uint128x2(100, 0), 0, 1);

        vm.expectRevert();
        this._sub(Packing.pack_uint128x2(0, 0), 1, 1);
    }

    function _add(Uint128x2 a, uint128 v1, uint128 v2) public pure returns (Uint128x2) {
        return Packing.add(a, v1, v2);
    }

    function _nativeAdd(Uint128x2 a, uint128 v1, uint128 v2) public pure returns (Uint128x2) {
        uint256 mask = type(uint128).max;
        uint256 lower = (Packing.unwrap(a) & mask) + v2;
        uint256 upper = (Packing.unwrap(a) >> 128) + v1;
        return Packing.pack_uint128x2(upper.toUint128(), lower.toUint128());
    }

    function _nativeRAdd(Uint128x2 a, Uint128x2 b) public pure returns (Uint128x2) {
        uint256 mask = type(uint128).max;
        uint256 c = b.unwrap() & mask;
        uint256 d = b.unwrap() >> 128;
        uint256 e = a.unwrap() & mask;
        uint256 f = a.unwrap() >> 128;

        uint256 lower = e + c;
        uint256 upper = f + d;
        return Packing.pack_uint128x2(upper.toUint128(), lower.toUint128());
    }

    function _radd(Uint128x2 a, Uint128x2 b) public pure returns (Uint128x2) {
        return Packing.radd(a, b);
    }

    function _sub(Uint128x2 a, uint128 v1, uint128 v2) public pure returns (Uint128x2) {
        return Packing.sub(a, v1, v2);
    }

    function _nativeSub(Uint128x2 a, uint128 v1, uint128 v2) public pure returns (Uint128x2) {
        uint256 mask = type(uint128).max;
        uint256 lower = (Packing.unwrap(a) & mask) - v2;
        uint256 upper = (Packing.unwrap(a) >> 128) - v1;
        return Packing.pack_uint128x2(upper.toUint128(), lower.toUint128());
    }
}
