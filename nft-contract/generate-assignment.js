// Generate the Crown Racer Cards PAID-BLOCK tier assignment.
//
// Why this exists: the collection's metadata is statically hosted
// (<tokenId>.json on GitHub Pages), so the tier of every token ID must be
// fixed BEFORE launch — a static file cannot know a tier "drawn" at mint
// time. Tiers are therefore pre-assigned per token ID:
//
//   - Free block:  IDs 1–500      → all ROOKIE (decided by the contract).
//   - Paid block:  IDs 501–2222   → tiers assigned by THIS shuffle:
//       ROOKIE 833, PRO 556, NITRO 244, CHAMPION 89  (1,722 tokens)
//     (Collection totals: 1,333 / 556 / 244 / 89 = 2,222.)
//
// Fairness model (provably fair, revealed at mint):
//   - The shuffle is fully deterministic from a published seed string
//     (SEED_PHRASE below). Anyone can re-run this script and reproduce
//     nft/assignment.json byte-for-byte.
//   - Before launch, assignment.json AND its SHA-256 commitment
//     (nft/assignment-commitment.txt) are published in the repo. After the
//     contract is deployed, anyone can also compare the on-chain
//     `paidAssignment` bytes against nft/assignment-bytes.txt.
//   - Tiers are NOT drawn at mint time; mintPaid() simply mints the next
//     paid-block ID with its pre-assigned tier.
//
// Random stream: counter-mode SHA-256 — block c is
// sha256(SEED_PHRASE + ":" + c); uint64 draws are taken big-endian from
// the stream, with rejection sampling for unbiased randBelow(). The
// shuffle is Fisher–Yates from the end of the bag.
//
// Packing (must match CrownRacerCards.sol exactly):
//   paid index i = tokenId - 501 (0-based, 0..1721)
//   byte index   = i / 4,  bit shift = (i % 4) * 2  (first token = lowest bits)
//   1,722 tokens × 2 bits = 3,444 bits → 431 bytes.
//
// Usage: node tools/generate-assignment.js
// Outputs: nft/assignment.json        — array of tier codes for IDs 501..2222
//          nft/assignment-bytes.txt   — packed bytes, 0x-prefixed hex
//          nft/assignment-commitment.txt — SHA-256 of assignment.json (hex)
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const SEED_PHRASE = 'crown-racer-cards-launch-shuffle-v1';
const PAID_START = 501;
const PAID_COUNT = 1722;
// Tier codes: 0=ROOKIE, 1=PRO, 2=NITRO, 3=CHAMPION.
const TIER_COUNTS = [833, 556, 244, 89];
const NFT_DIR = path.join(__dirname, '..', 'nft');

// ---------- Deterministic random stream (counter-mode SHA-256) ----------
let streamBlock = -1;
let streamBuf = Buffer.alloc(0);
let streamPos = 0;
function refill() {
  streamBlock += 1;
  streamBuf = crypto.createHash('sha256').update(`${SEED_PHRASE}:${streamBlock}`).digest();
  streamPos = 0;
}
function nextUint64() {
  if (streamPos + 8 > streamBuf.length) refill();
  const v = streamBuf.readBigUInt64BE(streamPos);
  streamPos += 8;
  return v;
}
function randBelow(n) {
  const bn = BigInt(n);
  const limit = (1n << 64n) - ((1n << 64n) % bn);
  for (;;) {
    const x = nextUint64();
    if (x < limit) return Number(x % bn);
  }
}

// ---------- Build the bag and shuffle (Fisher–Yates from the end) ----------
const bag = [];
TIER_COUNTS.forEach((count, tier) => { for (let k = 0; k < count; k++) bag.push(tier); });
if (bag.length !== PAID_COUNT) throw new Error(`bag size ${bag.length} != ${PAID_COUNT}`);
for (let i = bag.length - 1; i > 0; i--) {
  const j = randBelow(i + 1);
  const tmp = bag[i]; bag[i] = bag[j]; bag[j] = tmp;
}

// ---------- Verify the shuffle preserved the exact tier counts ----------
const counts = [0, 0, 0, 0];
for (const t of bag) counts[t]++;
if (JSON.stringify(counts) !== JSON.stringify(TIER_COUNTS)) {
  throw new Error(`count mismatch after shuffle: ${counts}`);
}

// ---------- Pack 2 bits per token ----------
const packed = Buffer.alloc(Math.ceil((PAID_COUNT * 2) / 8), 0);
bag.forEach((tier, i) => {
  packed[i >> 2] |= tier << ((i & 3) * 2);
});
// Round-trip self-check: unpacking must reproduce the bag exactly.
for (let i = 0; i < PAID_COUNT; i++) {
  const t = (packed[i >> 2] >> ((i & 3) * 2)) & 3;
  if (t !== bag[i]) throw new Error(`pack round-trip mismatch at paid index ${i}`);
}

// ---------- Write artifacts ----------
fs.mkdirSync(NFT_DIR, { recursive: true });
const assignmentJson = JSON.stringify(bag);
fs.writeFileSync(path.join(NFT_DIR, 'assignment.json'), assignmentJson + '\n');
const bytesHex = '0x' + packed.toString('hex');
fs.writeFileSync(path.join(NFT_DIR, 'assignment-bytes.txt'), bytesHex + '\n');
const commitment = crypto.createHash('sha256').update(assignmentJson + '\n').digest('hex');
fs.writeFileSync(path.join(NFT_DIR, 'assignment-commitment.txt'), commitment + '\n');

console.log('Crown Racer Cards — paid-block tier assignment');
console.log('  seed phrase        :', JSON.stringify(SEED_PHRASE));
console.log('  paid block         : token IDs', PAID_START, '..', PAID_START + PAID_COUNT - 1, `(${PAID_COUNT} tokens)`);
console.log('  tier counts        : ROOKIE', counts[0], '| PRO', counts[1], '| NITRO', counts[2], '| CHAMPION', counts[3]);
console.log('  packed bytes       :', packed.length, 'bytes');
console.log('  assignment.json    : nft/assignment.json');
console.log('  assignment bytes   :', bytesHex);
console.log('  SHA-256 commitment :', commitment, '(of nft/assignment.json)');
