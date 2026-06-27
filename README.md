# Privacy-Preserving AI Bounty Judge
### Assignment submission — web3aunty / Goddesszee
**Contract:** `0xC7d598a10DB4300CB2634f25A62b816bCBd1Ea4b` on Ritual Chain (Chain ID 1979)
**Deploy tx:** `0xa14abb7b25b12549202d928f10efce48bd9a6a6c7705f4d26aeff2a3b0b1a04f`

---

## The Problem We Solved

The original bounty judge stored answers publicly on-chain the moment they were submitted. This meant later participants could read earlier answers, copy useful ideas, and submit improved versions — fundamentally unfair in a winner-takes-all system.

**Our solution: a commit-reveal privacy scheme.**

---

## Bounty Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│                    PHASE 0: CREATE                              │
│  owner calls createBounty(title, rubric, subDeadline, revDeadline)│
│  → prize locked in contract                                     │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 1: COMMIT  🔒                             │
│  participants call submitCommitment(bountyId, hash)             │
│                                                                 │
│  hash = keccak256(answer + salt + msg.sender + bountyId)        │
│                                                                 │
│  ✓ Answer is completely hidden — only a hash stored on-chain    │
│  ✓ Cannot copy another person's commitment (sender bound)       │
│  ✓ Cannot reuse across bounties (bountyId bound)                │
│  ✓ Cannot brute-force short answers (salt prevents it)          │
│                                                                 │
│  [submissionDeadline passes — no new commits accepted]          │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 2: REVEAL  🔓                             │
│  participants call revealAnswer(bountyId, answer, salt)         │
│                                                                 │
│  contract verifies:                                             │
│  keccak256(answer, salt, msg.sender, bountyId) == commitment    │
│                                                                 │
│  ✓ Only valid reveals are eligible for judging                  │
│  ✓ Answers now visible — but all commitments already locked     │
│                                                                 │
│  [revealDeadline passes — no new reveals accepted]              │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                 PHASE 3: JUDGE  🤖                              │
│  owner calls judgeAll(bountyId, llmInput)                       │
│                                                                 │
│  → ONE Ritual LLM precompile call for ALL revealed answers      │
│  → Batch judging — never one call per submission                │
│  → AI returns winnerIndex + scores + reasons                    │
│  → Result stored in aiReview bytes on-chain                     │
└─────────────────────┬───────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│              PHASE 4: FINALIZE  🏆                              │
│  owner calls finalizeWinner(bountyId, winnerIndex)              │
│                                                                 │
│  → Human reviews AI recommendation (human-in-the-loop)         │
│  → Winner receives full prize via .call{value: reward}         │
│  → Contract state permanently finalized                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## Commitment Hash Formula

```solidity
bytes32 commitment = keccak256(
    abi.encodePacked(answer, salt, msg.sender, bountyId)
);
```

| Component | Why it's included |
|---|---|
| `answer` | The secret being committed to |
| `salt` | Random bytes32 — prevents brute-force of short answers |
| `msg.sender` | Binds to your wallet — prevents commitment replay attacks |
| `bountyId` | Binds to this bounty — prevents cross-bounty reuse |

---

## What Changed from the Base Contract

| Area | Before | After |
|---|---|---|
| Submission | `submitAnswer()` stores plaintext publicly | `submitCommitment()` stores only a hash |
| Reveal | n/a | `revealAnswer()` verifies hash, then stores plaintext |
| `createBounty` | single `deadline` | `submissionDeadline` + `revealDeadline` |
| Submissions list | shows all answers live | shows 🔒 hidden until after judging |
| JudgeAll | reads answers from storage | reads only REVEALED answers via `getRevealedAnswers()` |

---

## Test Plan

### Happy path
1. Deploy → `createBounty(title, rubric, subDeadline, revDeadline)` with ETH
2. Call `computeCommitment(answer, salt, addr, bountyId)` → get hash
3. `submitCommitment(bountyId, hash)` before subDeadline → succeeds
4. Warp past `submissionDeadline`
5. `revealAnswer(bountyId, answer, salt)` → succeeds, answer stored
6. Warp past `revealDeadline`
7. `judgeAll(bountyId, llmInput)` → Ritual LLM called
8. `finalizeWinner(bountyId, 0)` → winner receives ETH ✅

### Failure cases

| Test | Expected revert |
|---|---|
| `submitCommitment` after deadline | `"submission phase closed"` |
| `revealAnswer` before submission deadline | `"submission phase still open"` |
| `revealAnswer` after reveal deadline | `"reveal phase closed"` |
| `revealAnswer` with wrong salt | `"commitment mismatch"` |
| `revealAnswer` with wrong answer | `"commitment mismatch"` |
| `revealAnswer` from different address | `"commitment mismatch"` |
| `revealAnswer` twice | `"already revealed"` |
| `submitCommitment` twice | `"already committed"` |
| `judgeAll` before reveal deadline | `"reveal phase still open"` |
| `judgeAll` with no reveals | `"no revealed answers"` |
| `finalizeWinner` on unrevealed submission | `"invalid or unrevealed winner"` |
| `finalizeWinner` before judging | `"not judged or already finalized"` |
| Non-owner calls `judgeAll` | `"not bounty owner"` |

---

## Architecture Note: Commit-Reveal vs Ritual-Native TEE

### Commit-Reveal (Required Track — Implemented)

```
Participant                    Chain                      Ritual LLM
    │                            │                            │
    │── submitCommitment(hash) ──►│                            │
    │   [answer hidden]          │                            │
    │                            │                            │
    │── revealAnswer(answer,salt)►│                            │
    │   [hash verified on-chain] │                            │
    │                            │                            │
    │                     owner──►── judgeAll(allAnswers) ────►│
    │                            │◄── AI verdict ─────────────│
    │                            │                            │
    │                     owner──►── finalizeWinner()         │
```

**Limitation:** Answers become public on-chain after the reveal phase, before AI judging happens. Anyone can read them between reveal and judge.

---

### Ritual-Native TEE (Advanced Track — Design)

```
Participant                    Chain              Ritual TEE Executor
    │                            │                       │
    │  encrypt(answer, TEE_pubkey)                       │
    │── submitEncrypted(ciphertext)──►│                  │
    │   [plaintext NEVER on-chain]   │                  │
    │                                │                  │
    │                         owner──►── judgeAll() ────►│
    │                                │   TEE decrypts    │
    │                                │   answers inside  │
    │                                │   enclave         │
    │                                │   LLM judges all  │
    │                                │◄── verdict + hash─│
    │                                │                   │
    │                   revealedAnswersHash stored on-chain
    │                   revealedAnswersRef → IPFS bundle
```

**Where plaintext exists:** Only inside the Ritual TEE hardware enclave. Never on the public chain.

**What's stored on-chain:** Encrypted ciphertext during submission. After judging: `revealedAnswersHash` + `revealedAnswersRef` (IPFS).

**How LLM receives submissions:** TEE decrypts all answers privately, builds the batch prompt, calls LLM once inside the enclave.

**How result is verified:** The `TEEServiceRegistry` attests the executor's public key and attestation hash on-chain. The output is signed by the TEE.

---

## Reflection

What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?

The bounty question, rubric, prize amount, and submission deadlines should all be fully public so participants can make informed decisions about whether to enter. Individual answers must remain hidden until all commitments are locked — the commit-reveal scheme enforces this cryptographically without trusting any central authority. Once the reveal phase closes, answers can safely become public because no one can retroactively submit a copy of something they hadn't seen. The existence of a commitment — but not its content — can be public, letting participants verify the field is competitive. AI is well-suited to scoring answers consistently against a rubric, catching duplicate or plagiarised content across the full submission set, and doing so in a single auditable batch call — tasks where human judges introduce fatigue and bias. However, a human should retain the right to flag disqualifications, override clear AI errors, and make the final `finalizeWinner` call on-chain. This hybrid model keeps the process transparent: the AI verdict is recorded in `aiReview` bytes for anyone to verify, while the human owner takes accountable, gas-signed responsibility for the final payout decision.

---

## Files Changed

- `hardhat/contracts/AIJudge.sol` — full commit-reveal contract with inline documentation
- `web/src/abi/AIJudge.ts` — updated ABI matching new contract
- `web/src/lib/bounty.ts` — new `BountyStatus` type with 5 phases
- `web/src/components/SubmitAnswer.tsx` — phase-aware UI (commit → reveal → done)
- `web/src/components/CreateBountyForm.tsx` — two deadline inputs
- `web/src/components/SubmissionsList.tsx` — answers hidden until judged
- `web/src/components/BountyDetail.tsx` — shows both deadlines
- `web/src/components/JudgeAll.tsx` — uses `getRevealedAnswers()` for batch payload
- `web/src/config/contract.ts` — contract address + chain config
