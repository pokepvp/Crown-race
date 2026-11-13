// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Crown Racer Cards — ERC-721 racer cards for the Crown Race game
/// @notice The NFT companion collection of Crown Race (crownrace.site, the
///         weekly heat race game for Binance Agent ID holders). 2,222 cards
///         in four tiers with hard caps:
///           - ROOKIE   1,333 (tier 0)
///           - PRO        556 (tier 1)
///           - NITRO      244 (tier 2)
///           - CHAMPION    89 (tier 3)
///         Token IDs live in two pre-assigned blocks, mirroring the two
///         mint lanes, so that the tier of every ID is fixed BEFORE launch
///         and the statically hosted metadata (<tokenId>.json) always
///         matches tierOf(tokenId):
///           - FREE block, IDs 1–500: every card is a ROOKIE. mintFree()
///             mints the next ID in this block (sequential pointer).
///           - PAID block, IDs 501–2,222 (1,722 cards): tiers pre-assigned
///             by an off-chain fair shuffle — ROOKIE 833, PRO 556,
///             NITRO 244, CHAMPION 89. mintPaid() mints the next ID in
///             this block (sequential pointer) with its pre-assigned tier.
///         Collection tier totals are therefore exactly the hard caps:
///         ROOKIE 1,333 (= 500 free + 833 paid), PRO 556, NITRO 244,
///         CHAMPION 89.
///         Two mint lanes run in PARALLEL from the first minute — the paid
///         lane is never gated on the free lane:
///           - Free: mintFree(), value 0, requires a Binance .ai Agent ID,
///             max 1 free mint per wallet, always a ROOKIE (free block).
///             The free block is part of the 2,222 supply, not additional.
///           - Paid: mintPaid(), exactly 0.001 BNB, mints the next
///             paid-block ID with whatever tier the shuffle assigned it.
///         One wallet may hold at most 5 minted cards in total across BOTH
///         lanes (a free mint counts toward the 5). Minting starts CLOSED
///         (`mintOpen = false`); only the owner can open it. Metadata
///         lives at baseURI + "<tokenId>.json".
/// @dev Dependency-free (no OpenZeppelin imports): ownership, the ERC-721
///      surface and the mint logic are implemented in this single file, in
///      the same house style as CrownRaceGame. The Agent ID registry
///      address is a constructor argument: on BNB Chain mainnet deploy with
///      0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F (the SPACE ID .ai NFT).
///      Local tests substitute a mock registry. baseURI is the second
///      constructor argument (production: "https://crownrace.site/nft/metadata/").
///      The paid-block assignment is the third constructor argument:
///      packed bytes, 2 bits per paid token (1,722 tokens = 431 bytes),
///      immutable after deployment. FAIRNESS, stated honestly: tiers are
///      NOT drawn at mint time and no block-data randomness is involved.
///      They were fixed before launch by a deterministic shuffle whose
///      seed ("crown-racer-cards-launch-shuffle-v1") and the SHA-256
///      commitment of the resulting assignment file are published in the
///      project repo before the mint opens — anyone can regenerate the
///      assignment from the seed, check it against the commitment, and
///      compare it with the on-chain `paidAssignment` bytes. The shuffle
///      outcome is thus committed before launch and revealed per token as
///      the paid block mints out: provably fair, verifiable by anyone.
contract CrownRacerCards {
    // ---------- Ownership ----------
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    /// @notice The Agent ID registry (.ai NFT) checked on every free mint.
    address public immutable agentId;

    // ---------- Collection constants ----------
    string public constant name = "Crown Racer Cards";
    string public constant symbol = "CRACE";

    uint256 public constant MAX_SUPPLY = 2222;
    uint256 public constant FREE_QUOTA = 500;
    uint256 public constant MAX_PER_WALLET = 5; // total mints per wallet, BOTH lanes
    uint256 public constant PAID_PRICE = 0.001 ether;

    // Tier indices (used by tierOf / tierMinted / CardMinted).
    uint8 public constant TIER_ROOKIE = 0;
    uint8 public constant TIER_PRO = 1;
    uint8 public constant TIER_NITRO = 2;
    uint8 public constant TIER_CHAMPION = 3;

    // Hard per-tier caps; they sum to MAX_SUPPLY (1333 + 556 + 244 + 89).
    uint256 public constant ROOKIE_CAP = 1333;
    uint256 public constant PRO_CAP = 556;
    uint256 public constant NITRO_CAP = 244;
    uint256 public constant CHAMPION_CAP = 89;

    // Token-ID blocks. FREE block: IDs 1..FREE_QUOTA (all ROOKIE).
    // PAID block: IDs PAID_START..MAX_SUPPLY (tiers from the assignment).
    uint256 public constant PAID_START = FREE_QUOTA + 1; // 501
    uint256 public constant PAID_COUNT = MAX_SUPPLY - FREE_QUOTA; // 1722
    // Packed assignment size: 2 bits per paid token, rounded up to bytes.
    uint256 public constant ASSIGNMENT_BYTES = (PAID_COUNT * 2 + 7) / 8; // 431

    /// @notice Packed paid-block tier assignment (2 bits per token),
    ///         fixed at deployment and immutable. Paid index i =
    ///         tokenId - PAID_START sits in byte i/4 at bit shift
    ///         (i % 4) * 2. Regenerable from the published seed and
    ///         checkable against the published SHA-256 commitment.
    bytes public paidAssignment;

    /// @notice Minting is accepted only while the owner has enabled it.
    bool public mintOpen = false;

    /// @notice Metadata base URI; tokenURI(id) = baseURI + "<id>.json".
    string public baseURI;

    // ---------- Mint accounting ----------
    uint256 public totalMinted; // cards minted across BOTH blocks
    uint256 public freeMinted; // free-lane mints so far (quota: FREE_QUOTA)
    uint256 public nextFreeId = 1; // next token ID the free lane will mint (1..FREE_QUOTA)
    uint256 public nextPaidId = PAID_START; // next token ID the paid lane will mint (PAID_START..MAX_SUPPLY)
    uint256[4] public tierMinted; // per-tier minted counters, by tier index
    mapping(address => uint256) public mintCountOf; // total mints per wallet (both lanes)
    mapping(address => bool) public freeClaimed; // wallet already used its 1 free mint

    // ---------- ERC-721 storage ----------
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ---------- Events ----------
    // Standard ERC-721 events.
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    // Collection events.
    event CardMinted(address indexed minter, uint256 indexed tokenId, uint8 tier, bool paid);
    event MintOpenSet(bool open);
    event BaseURISet(string baseURI);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(address agentId_, string memory baseURI_, bytes memory assignment_) {
        require(agentId_ != address(0), "Zero address");
        require(assignment_.length == ASSIGNMENT_BYTES, "Bad assignment length");
        owner = msg.sender;
        agentId = agentId_;
        baseURI = baseURI_;
        paidAssignment = assignment_;
    }

    // ---------- Tier helpers ----------
    /// @notice Hard cap of a tier (0=ROOKIE, 1=PRO, 2=NITRO, 3=CHAMPION).
    function tierCap(uint8 tier) public pure returns (uint256) {
        if (tier == TIER_ROOKIE) return ROOKIE_CAP;
        if (tier == TIER_PRO) return PRO_CAP;
        if (tier == TIER_NITRO) return NITRO_CAP;
        if (tier == TIER_CHAMPION) return CHAMPION_CAP;
        revert("Bad tier");
    }

    /// @notice Tier of a minted token (0=ROOKIE, 1=PRO, 2=NITRO, 3=CHAMPION).
    ///         The tier is a pure function of the token ID — free-block
    ///         IDs are always ROOKIE, paid-block IDs unpack their
    ///         pre-assigned tier — which is exactly why the statically
    ///         hosted metadata for an ID can never disagree with this.
    function tierOf(uint256 tokenId) external view returns (uint8) {
        require(_owners[tokenId] != address(0), "Nonexistent token");
        return _assignedTier(tokenId);
    }

    /// @notice The pre-assigned tier of a token ID, whether minted yet or
    ///         not: IDs 1..FREE_QUOTA are ROOKIE; paid-block IDs unpack
    ///         2 bits from `paidAssignment`.
    function _assignedTier(uint256 tokenId) internal view returns (uint8) {
        if (tokenId <= FREE_QUOTA) return TIER_ROOKIE;
        uint256 i = tokenId - PAID_START; // 0..PAID_COUNT-1
        return (uint8(paidAssignment[i >> 2]) >> ((i & 3) * 2)) & 3;
    }

    function _hasAgentId(address wallet) internal view returns (bool) {
        return IAgentId(agentId).balanceOf(wallet) > 0;
    }

    // ---------- Mint lanes (parallel — neither gates the other) ----------
    /// @notice Free lane: no payment, caller must hold a Binance Agent ID,
    ///         max 1 free mint per wallet, total free quota 500, and the
    ///         card is ALWAYS a ROOKIE — it is the next ID of the free
    ///         block (IDs 1–500, sequential pointer). The free mint counts
    ///         toward the wallet's 5-card total cap.
    function mintFree() external returns (uint256 tokenId) {
        require(mintOpen, "Mint closed");
        require(_hasAgentId(msg.sender), "Agent ID required");
        require(!freeClaimed[msg.sender], "Free mint already claimed");
        require(freeMinted < FREE_QUOTA, "Free quota exhausted");
        require(mintCountOf[msg.sender] < MAX_PER_WALLET, "Max 5 per wallet");
        require(tierMinted[TIER_ROOKIE] < ROOKIE_CAP, "ROOKIE sold out");
        freeClaimed[msg.sender] = true;
        freeMinted += 1;
        tokenId = nextFreeId++;
        _mintCard(msg.sender, tokenId, TIER_ROOKIE);
        emit CardMinted(msg.sender, tokenId, TIER_ROOKIE, false);
    }

    /// @notice Paid lane: exactly 0.001 BNB. Mints the next ID of the paid
    ///         block (IDs 501–2,222, sequential pointer) with the tier the
    ///         published pre-launch shuffle assigned to that ID — there is
    ///         NO draw at mint time and no randomness in this function.
    ///         The per-tier counters below therefore mirror the assignment
    ///         exactly: after a full sell-out they must read
    ///         1333 / 556 / 244 / 89, which is how anyone can verify the
    ///         deployed assignment's integrity from chain data alone.
    function mintPaid() external payable returns (uint256 tokenId) {
        require(mintOpen, "Mint closed");
        require(msg.value == PAID_PRICE, "Exact price required");
        require(mintCountOf[msg.sender] < MAX_PER_WALLET, "Max 5 per wallet");
        require(nextPaidId <= MAX_SUPPLY, "Sold out");
        tokenId = nextPaidId++;
        uint8 tier = _assignedTier(tokenId);
        _mintCard(msg.sender, tokenId, tier);
        emit CardMinted(msg.sender, tokenId, tier, true);
    }

    function _mintCard(address to, uint256 tokenId, uint8 tier) internal {
        totalMinted += 1;
        _owners[tokenId] = to;
        _balances[to] += 1;
        tierMinted[tier] += 1;
        mintCountOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    // ---------- ERC-721 surface ----------
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd // ERC721
            || interfaceId == 0x5b5e139f // ERC721Metadata
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function balanceOf(address account) external view returns (uint256) {
        require(account != address(0), "Zero address");
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address tokenOwner = _owners[tokenId];
        require(tokenOwner != address(0), "Nonexistent token");
        return tokenOwner;
    }

    /// @notice Metadata URI: baseURI + "<tokenId>.json". The JSON itself
    ///         (hosted with the site) points at its image under
    ///         "https://crownrace.site/nft/images/<tokenId>.png".
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_owners[tokenId] != address(0), "Nonexistent token");
        if (bytes(baseURI).length == 0) return "";
        return string(abi.encodePacked(baseURI, _toString(tokenId), ".json"));
    }

    function approve(address to, uint256 tokenId) external {
        address tokenOwner = ownerOf(tokenId);
        require(to != tokenOwner, "Approval to current owner");
        require(
            msg.sender == tokenOwner || _operatorApprovals[tokenOwner][msg.sender],
            "Not owner nor operator"
        );
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_owners[tokenId] != address(0), "Nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        require(operator != msg.sender, "Approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) external view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner nor approved");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner nor approved");
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data), "Transfer to non ERC721Receiver");
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = ownerOf(tokenId);
        return spender == tokenOwner
            || _tokenApprovals[tokenId] == spender
            || _operatorApprovals[tokenOwner][spender];
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(ownerOf(tokenId) == from, "Transfer from incorrect owner");
        require(to != address(0), "Transfer to zero address");
        // Clear the per-token approval on every transfer.
        _tokenApprovals[tokenId] = address(0);
        emit Approval(from, address(0), tokenId);
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data)
        internal
        returns (bool)
    {
        if (to.code.length == 0) return true;
        return IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
            == IERC721Receiver.onERC721Received.selector;
    }

    // ---------- Owner controls ----------
    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
        emit MintOpenSet(open);
    }

    /// @notice Update the metadata base URI. Restricted: only while the
    ///         mint is CLOSED, so metadata can never be swapped under
    ///         buyers mid-mint.
    function setBaseURI(string memory newBaseURI) external onlyOwner {
        require(!mintOpen, "Close mint to change baseURI");
        baseURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    /// @notice Withdraw the contract's full BNB balance (paid-mint
    ///         proceeds) to the owner.
    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "Nothing to withdraw");
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "Withdraw failed");
        emit Withdrawn(owner, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    // ---------- Helpers ----------
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

interface IAgentId {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
