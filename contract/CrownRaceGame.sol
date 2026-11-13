// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Crown Race — weekly heat race game for Binance Agent ID holders
/// @notice A brand-new game (public name "Crown Race") that reuses only the
///         crownrace.site domain of the legacy project. It has NOTHING to do
///         with the old CrownRace pass contract: no NFTs are minted here —
///         racers are plain records inside this contract.
///
///         The race runs in weekly heats, Monday 00:00 UTC to the next
///         Monday 00:00 UTC. Two entry lanes run in parallel from the first
///         minute of each heat (never gated on each other):
///           - Rookie: free (value 0), requires a Binance .ai Agent ID,
///             max 1 racer per wallet per heat, starts at step 0.
///           - Pro: exactly 0.0007 BNB, max 3 racers per wallet per heat,
///             starts at step 5 (head start).
///         Each racer may move() once per UTC day, advancing 1–6 steps drawn
///         from the previous block hash (verifiable after the fact, NOT
///         VRF-grade). Paid Nitro boosts add +2 / +7 / +20 steps. The track
///         is 100 steps; reaching 100 finishes the heat early. When a heat
///         ends (or is finished), anyone can settleHeat(): the winner (the
///         finisher, else the farthest racer, ties broken by who reached
///         the position first) is recorded on-chain as the champion, with
///         a prize entitlement of exactly 50% of the heat pool — all Pro
///         entry fees and Nitro payments of that heat. The contract does
///         NOT pay the prize itself: the full pool (100%) is credited to
///         the owner balance, the owner pays the champion's 50% prize
///         manually (within 24 hours of settlement), and then flags the
///         heat with markPrizePaid() so the payment duty and its
///         fulfilment are publicly auditable on-chain. No own token.
/// @dev The contract is named CrownRaceGame to stay distinct from the legacy
///      CrownRace contract. Agent ID registry address is a constructor
///      argument: on BNB Chain mainnet deploy with
///      0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F (the SPACE ID .ai NFT).
///      Local tests substitute a mock registry.
contract CrownRaceGame {
    // ---------- Ownership ----------
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @notice The Agent ID registry (.ai NFT) checked on every Rookie entry.
    address public immutable agentId;

    // ---------- Game constants ----------
    uint256 public constant TRACK_LENGTH = 100;
    uint256 public constant MAX_PER_HEAT = 2222;
    uint256 public constant PRO_PRICE = 0.0007 ether;
    uint256 public constant PRO_HEAD_START = 5;
    uint256 public constant MAX_PRO_PER_WALLET = 3;

    uint256 internal constant WEEK = 604800;
    // The unix epoch (1970-01-01) was a Thursday. Adding 3 days (259200 s)
    // before dividing by the week length makes heat boundaries fall exactly
    // on Mondays 00:00 UTC.
    uint256 internal constant MONDAY_OFFSET = 259200;

    /// @notice Entries are accepted only while the owner has enabled them.
    bool public entryOpen = false;

    uint256[3] public nitroPrice; // wei, by tier 0/1/2
    uint256[3] public nitroSteps; // steps, by tier 0/1/2

    // ---------- Racers and heats ----------
    struct Racer {
        address owner;
        uint256 heatId;
        uint256 position;
        bool pro;
        uint256 lastMoveDay; // UTC day of the last move() (0 = never; day 0 was in 1970)
        uint256 reachedAt; // timestamp of the last position increase (tie-break)
    }

    struct Heat {
        uint256 pool; // Pro entry fees + Nitro payments of this heat, in wei
        uint256 racerCount;
        uint256 leaderRacer; // racerId of the current farthest racer (0 = none)
        uint256 finisherRacer; // racerId that reached step 100 (0 = none)
        uint256 finishTime;
        address champion; // winner recorded at settlement (0 until settled / if no racers)
        uint256 prize; // champion's prize entitlement recorded at settlement: 50% of pool, paid manually by the owner
        bool prizePaid; // owner flags true after paying the champion manually (see markPrizePaid)
        bool settled;
    }

    mapping(uint256 => Racer) public racers; // racerId -> racer (IDs sequential from 1)
    mapping(uint256 => Heat) public heats; // heatId -> heat
    uint256 public totalRacers;

    mapping(uint256 => mapping(address => uint256)) public rookieEntries; // per heat, per wallet
    mapping(uint256 => mapping(address => uint256)) public proEntries; // per heat, per wallet
    mapping(address => mapping(uint256 => uint256[])) private _racersOf; // wallet -> heatId -> racerIds

    /// @notice Owner's withdrawable balance: 100% of SETTLED heat pools.
    ///         Unsettled heat pools are NEVER part of this balance, so
    ///         withdraw() cannot touch a running heat, and one heat's money
    ///         can never leak into another heat's accounting. From this
    ///         balance the owner pays each champion's recorded 50% prize
    ///         manually (see the `prize` field of each settled heat).
    uint256 public ownerBalance;

    event RacerEntered(uint256 indexed heatId, uint256 indexed racerId, address indexed owner, bool pro);
    event Moved(uint256 indexed heatId, uint256 indexed racerId, uint256 steps, uint256 position);
    event NitroUsed(uint256 indexed heatId, uint256 indexed racerId, uint8 tier, uint256 steps, uint256 position);
    event Finished(uint256 indexed heatId, uint256 indexed racerId, address indexed owner, uint256 finishTime);
    event HeatSettled(uint256 indexed heatId, address indexed champion, uint256 prize, uint256 ownerShare);
    event PrizePaid(uint256 indexed heatId, address indexed champion, uint256 prize);
    event EntryOpenSet(bool open);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(address agentId_) {
        require(agentId_ != address(0), "Zero address");
        owner = msg.sender;
        agentId = agentId_;
        // Nitro schedule: prices locked at deployment (same tiers the
        // audience already knows from the legacy boost schedule).
        nitroPrice[0] = 0.00015 ether; // +2 steps
        nitroPrice[1] = 0.0005 ether; // +7 steps
        nitroPrice[2] = 0.0015 ether; // +20 steps
        nitroSteps[0] = 2;
        nitroSteps[1] = 7;
        nitroSteps[2] = 20;
    }

    // ---------- Heat calendar (Monday-aligned weeks) ----------
    /// @notice The heat containing a timestamp. Heat N starts exactly at
    ///         heatStart(N) — a Monday 00:00 UTC.
    function heatIdAt(uint256 timestamp) public pure returns (uint256) {
        return (timestamp + MONDAY_OFFSET) / WEEK;
    }

    function currentHeat() public view returns (uint256) {
        return heatIdAt(block.timestamp);
    }

    /// @notice Start timestamp (Monday 00:00 UTC) of a heat.
    function heatStart(uint256 heatId) public pure returns (uint256) {
        if (heatId == 0) return 0; // heat 0 began before the epoch; clamped
        return heatId * WEEK - MONDAY_OFFSET;
    }

    /// @notice End timestamp (= start of the next heat) of a heat.
    function heatEnd(uint256 heatId) public pure returns (uint256) {
        if (heatId == 0) return WEEK - MONDAY_OFFSET; // Monday 1970-01-05
        return heatStart(heatId) + WEEK;
    }

    function _hasAgentId(address wallet) internal view returns (bool) {
        return IAgentId(agentId).balanceOf(wallet) > 0;
    }

    // ---------- Entries (parallel lanes) ----------
    /// @notice Free Rookie entry: value must be exactly 0, caller must hold
    ///         a Binance Agent ID, max 1 Rookie racer per wallet per heat.
    ///         The racer starts at step 0.
    function enterRookie() external payable returns (uint256 racerId) {
        require(msg.value == 0, "Rookie entry is value 0");
        require(_hasAgentId(msg.sender), "Agent ID required");
        uint256 heatId = currentHeat();
        require(rookieEntries[heatId][msg.sender] == 0, "One rookie per wallet per heat");
        rookieEntries[heatId][msg.sender] = 1;
        racerId = _enter(false);
    }

    /// @notice Pro entry at exactly 0.0007 BNB, max 3 Pro racers per wallet
    ///         per heat. The racer starts at step 5 and the fee enters the
    ///         current heat's prize pool. (Paid lane: no Agent ID required.)
    function enterPro() external payable returns (uint256 racerId) {
        require(msg.value == PRO_PRICE, "Exact price required");
        uint256 heatId = currentHeat();
        require(proEntries[heatId][msg.sender] < MAX_PRO_PER_WALLET, "Max 3 Pro per wallet per heat");
        proEntries[heatId][msg.sender] += 1;
        heats[heatId].pool += msg.value;
        racerId = _enter(true);
    }

    function _enter(bool pro) internal returns (uint256 racerId) {
        require(entryOpen, "Entries closed");
        uint256 heatId = currentHeat();
        Heat storage heat = heats[heatId];
        require(heat.racerCount < MAX_PER_HEAT, "Heat full");
        racerId = ++totalRacers;
        racers[racerId] = Racer({
            owner: msg.sender,
            heatId: heatId,
            position: pro ? PRO_HEAD_START : 0,
            pro: pro,
            lastMoveDay: 0,
            reachedAt: block.timestamp
        });
        heat.racerCount += 1;
        _racersOf[msg.sender][heatId].push(racerId);
        _updateLeader(heatId, racerId);
        emit RacerEntered(heatId, racerId, msg.sender, pro);
    }

    // ---------- Racing ----------
    /// @notice Move once per UTC day. Advances 1–6 steps drawn from the
    ///         previous block's hash (verifiable after the fact, NOT
    ///         VRF-grade). Position is capped at the 100-step finish line.
    function move(uint256 racerId) external returns (uint256 steps) {
        Racer storage racer = racers[racerId];
        require(racer.owner == msg.sender, "Not racer owner");
        _requireRacing(racer);
        uint256 day = block.timestamp / 86400;
        require(racer.lastMoveDay != day, "Already moved today");
        racer.lastMoveDay = day;
        steps = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), racerId, day, msg.sender))) % 6 + 1;
        _advance(racerId, steps);
        emit Moved(racer.heatId, racerId, steps, racer.position);
    }

    /// @notice Nitro boost: tier 0/1/2 costs exactly 0.00015 / 0.0005 /
    ///         0.0015 BNB for +2 / +7 / +20 steps. The full payment enters
    ///         the racer's heat pool. Only the racer's owner may boost it,
    ///         and only while its heat is live and unfinished.
    function nitro(uint256 racerId, uint8 tier) external payable {
        require(tier < 3, "Bad tier");
        require(msg.value == nitroPrice[tier], "Exact price required");
        Racer storage racer = racers[racerId];
        require(racer.owner == msg.sender, "Not racer owner");
        _requireRacing(racer);
        heats[racer.heatId].pool += msg.value;
        _advance(racerId, nitroSteps[tier]);
        emit NitroUsed(racer.heatId, racerId, tier, nitroSteps[tier], racer.position);
    }

    function _requireRacing(Racer storage racer) internal view {
        require(block.timestamp < heatEnd(racer.heatId), "Heat ended");
        require(heats[racer.heatId].finisherRacer == 0, "Heat finished");
    }

    function _advance(uint256 racerId, uint256 steps) internal {
        Racer storage racer = racers[racerId];
        uint256 newPosition = racer.position + steps;
        if (newPosition > TRACK_LENGTH) newPosition = TRACK_LENGTH;
        racer.position = newPosition;
        racer.reachedAt = block.timestamp;
        _updateLeader(racer.heatId, racerId);
        if (newPosition == TRACK_LENGTH && heats[racer.heatId].finisherRacer == 0) {
            heats[racer.heatId].finisherRacer = racerId;
            heats[racer.heatId].finishTime = block.timestamp;
            emit Finished(racer.heatId, racerId, racer.owner, block.timestamp);
        }
    }

    /// @notice The leader is the farthest racer; on equal positions the one
    ///         who reached that position EARLIEST keeps the lead. Once a
    ///         heat is finished the lead can no longer change.
    function _updateLeader(uint256 heatId, uint256 racerId) internal {
        Heat storage heat = heats[heatId];
        if (heat.finisherRacer != 0) return;
        uint256 leaderId = heat.leaderRacer;
        if (leaderId == 0) {
            heat.leaderRacer = racerId;
            return;
        }
        if (leaderId == racerId) return;
        Racer storage challenger = racers[racerId];
        Racer storage leader = racers[leaderId];
        if (challenger.position > leader.position ||
            (challenger.position == leader.position && challenger.reachedAt < leader.reachedAt)) {
            heat.leaderRacer = racerId;
        }
    }

    // ---------- Settlement ----------
    /// @notice Settle a heat once it has ended (Monday 00:00 UTC) or a
    ///         racer has finished it early. Permissionless. The winner —
    ///         the finisher if any, otherwise the farthest racer with the
    ///         earliest-reach tie-break — is recorded as the champion,
    ///         together with a prize entitlement of exactly 50% of the
    ///         heat pool. The contract does NOT transfer the prize: the
    ///         FULL pool (100%) is credited to the owner balance, and the
    ///         owner pays the champion's prize manually (within 24 hours)
    ///         and flags it via markPrizePaid(). A heat with no racers or
    ///         a zero pool settles as a no-op (the champion is still
    ///         recorded when racers exist) and can never be settled twice.
    function settleHeat(uint256 heatId) external {
        Heat storage heat = heats[heatId];
        require(!heat.settled, "Already settled");
        require(block.timestamp >= heatEnd(heatId) || heat.finisherRacer != 0, "Heat not ended");
        heat.settled = true;
        address winner = address(0);
        if (heat.finisherRacer != 0) {
            winner = racers[heat.finisherRacer].owner;
        } else if (heat.leaderRacer != 0) {
            winner = racers[heat.leaderRacer].owner;
        }
        heat.champion = winner;
        uint256 pool = heat.pool;
        uint256 prize = 0;
        uint256 ownerShare = 0;
        if (winner != address(0) && pool > 0) {
            prize = pool / 2;
            heat.prize = prize;
            ownerShare = pool;
            ownerBalance += ownerShare;
        }
        emit HeatSettled(heatId, winner, prize, ownerShare);
    }

    /// @notice Flag a settled heat's champion prize as paid. The owner
    ///         calls this AFTER transferring the recorded prize to the
    ///         champion from their own wallet; the flag and the transfer
    ///         are both public, so anyone can audit that the duty was met.
    function markPrizePaid(uint256 heatId) external onlyOwner {
        Heat storage heat = heats[heatId];
        require(heat.settled, "Not settled");
        require(heat.champion != address(0), "No champion");
        require(heat.prize > 0, "No prize");
        require(!heat.prizePaid, "Already marked");
        heat.prizePaid = true;
        emit PrizePaid(heatId, heat.champion, heat.prize);
    }

    // ---------- Views for the website ----------
    /// @notice Number of racers entered in a heat.
    function racerCount(uint256 heatId) external view returns (uint256) {
        return heats[heatId].racerCount;
    }

    /// @notice Core racer record for the site (reachedAt is available via
    ///         the public `racers` getter).
    function racerInfo(uint256 racerId)
        external
        view
        returns (address owner_, uint256 heatId_, uint256 position_, bool pro_, uint256 lastMoveDay_)
    {
        Racer storage racer = racers[racerId];
        return (racer.owner, racer.heatId, racer.position, racer.pro, racer.lastMoveDay);
    }

    /// @notice All racer IDs a wallet owns in a heat.
    function racersOf(address wallet, uint256 heatId) external view returns (uint256[] memory) {
        return _racersOf[wallet][heatId];
    }

    /// @notice Prize pool accumulated by a heat, in wei.
    function poolOf(uint256 heatId) external view returns (uint256) {
        return heats[heatId].pool;
    }

    /// @notice Winner of a heat once settled (address(0) before settlement
    ///         or when the heat had no racers).
    function championOf(uint256 heatId) external view returns (address) {
        return heats[heatId].champion;
    }

    /// @notice Owner of the current farthest racer of a heat (same
    ///         position + earliest-reach tie-break as settlement).
    function leaderOf(uint256 heatId) external view returns (address) {
        uint256 leaderId = heats[heatId].leaderRacer;
        return leaderId == 0 ? address(0) : racers[leaderId].owner;
    }

    /// @notice Racer ID of the current leader of a heat (0 = none).
    function leaderRacerOf(uint256 heatId) external view returns (uint256) {
        return heats[heatId].leaderRacer;
    }

    /// @notice Racer ID that finished a heat early (0 = none), plus the
    ///         finish timestamp.
    function finisherOf(uint256 heatId) external view returns (uint256 racerId_, uint256 finishTime_) {
        return (heats[heatId].finisherRacer, heats[heatId].finishTime);
    }

    function isSettled(uint256 heatId) external view returns (bool) {
        return heats[heatId].settled;
    }

    // ---------- Owner controls ----------
    function setEntryOpen(bool open) external onlyOwner {
        entryOpen = open;
        emit EntryOpenSet(open);
    }

    /// @notice Withdraw the owner balance only (100% of settled heat
    ///         pools). Unsettled heat pools are untouchable here.
    function withdraw() external onlyOwner {
        uint256 amount = ownerBalance;
        require(amount > 0, "Nothing to withdraw");
        ownerBalance = 0;
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit Withdrawn(owner, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}

interface IAgentId {
    function balanceOf(address account) external view returns (uint256);
}
