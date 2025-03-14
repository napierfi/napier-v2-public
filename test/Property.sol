// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

// forgefmt: disable-start

// TODO Numbering of properties is not consistent

// Protocol level properties
string constant T01_INTEREST_ACCURAL = "Accrued interest sub performance fee goes to a user";
string constant T04_ACCURAL_EQ = "Accrued yield doesn't depend on how many times a user accrues yield. Users who hold the same amount of YT always get the same amount of accrued yield";
string constant T04_YIELD_INDEX = "Yield index never decreases";

// pending_interest = SUM_users(accrued_interest) + SUM_users(future_accrued_interest)
// pending_curator_fees = accrued_curator_fees + SUM_users(future_accrued_curator_fees)
// pending_protocol_fees = accrued_protocol_fees + SUM_users(future_accrued_protocol_fees)
// pending_curator_fees + pending_protocol_fees + SUM_users(pending_interest) + SUM_users(redeem()) <= balance of underlying in PT
string constant T05_SOLVENCY = "`1 PT + 1 YT = 1 share` always holds true";

string constant T06_PT_YT_SUPPLY_EQ = "Until expiry, PT.totalSupply() is always equal to YT.totalSupply()";

string constant T06_REWARD_PRE_SETTLEMENT = "Accrued rewards pre-settlement phase goes to a user";
string constant T06_REWARD_POST_SETTLEMENT = "Post settlement fee goes to curator and protocol and remaining rewards goes to a user";
string constant T07_REWARD = "Accrued rewards is always equal to sum of accrued rewards by users";
// Actually it's impossible that the actual reward is always constant because of the precision loss
string constant T08_REWARD_EQ = "Accrued rewards doesn't depend on how many times a user accrues rewards. Users who hold the same amount of YT always get the same amount of accrued rewards";
string constant T09_REWARD_INDEX = "Reward index never decreases";
// Function level properties

string constant T10_SUPPLY = "supply() >= previewSupply() holds true";
string constant T11_ISSUE = "issue() <= previewIssue() holds true";
string constant T12_WITHDRAW = "withdraw() <= previewWithdraw() holds true";
string constant T13_REDEEM = "redeem() >= previewRedeem() holds true";
string constant T13_REDEEM_ACCURAL = "Redeem `redeem()` and `unite()` doesn't update users' pending interest";
string constant T14_UNITE = "unite() <= previewUnite() holds true";
string constant T15_COMBINE = "combine() >= previewCombine() holds true";
string constant T16_COLLECT = "collect() >= previewCollect() holds true";
string constant RT_SUPPLY_COMBINE = "RT never benefits users: combine(supply(s)) <= s";
string constant RT_SUPPLY_REDEEM = "RT never benefits users: redeem(supply(s)) <= s";
string constant RT_COMBINE_SUPPLY = "RT never benefits users: supply(combine(p)) <= p";
string constant RT_SUPPLY_UNITE = "RT never benefits users: p = supply(s) p' = unite(s) p' >= p must hold true";
string constant RT_ISSUE_COMBINE = "RT never benefits users: combine(issue(p)) <= p";
string constant RT_SUPPLY_WITHDRAW = "RT never benefits users:  p = supply(s) p' = withdraw(s) p' >= p must hold true";

// Max redeem/withdraw/supply/issue properties
string constant T17_MAX_REDEEM = "maxRedeem() returns 0 when not expired";
string constant T18_MAX_WITHDRAW = "maxWithdraw() returns 0 when not expired";
string constant T19_MAX_SUPPLY = "maxSupply() returns 0 when issuance is disabled";
string constant T20_MAX_ISSUE = "maxIssue() returns 0 when issuance is disabled";
string constant T21_PREVIEW_SUPPLY = "previewSupply() returns 0 when issuance is disabled";
string constant T22_PREVIEW_ISSUE = "previewIssue() returns 0 when issuance is disabled";
string constant T23_PREVIEW_REDEEM = "previewRedeem() returns 0 when not expired";
string constant T24_PREVIEW_WITHDRAW = "previewWithdraw() returns 0 when not expired";
