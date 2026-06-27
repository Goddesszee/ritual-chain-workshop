# Privacy-Preserving AI Bounty Judge
### Ritual Chain Workshop — Submission by web3aunty / Goddesszee

**Contract:** `0xC7d598a10DB4300CB2634f25A62b816bCBd1Ea4b`
**Network:** Ritual Chain (Chain ID 1979)
**Deploy tx:** `0xa14abb7b25b12549202d928f10efce48bd9a6a6c7705f4d26aeff2a3b0b1a04f`
**Explorer:** https://explorer.ritualfoundation.org/tx/0xa14abb7b25b12549202d928f10efce48bd9a6a6c7705f4d26aeff2a3b0b1a04f

---

## What Was Built

An upgraded AI Bounty Judge that prevents answer-copying during the submission phase.
The original workshop version stored answers in plaintext immediately — this version
uses a **commit-reveal scheme** so answers stay hidden until all commitments are locked.

---

## Bounty Lifecycle

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PHASE 1: COMMIT                                  │
│                  (before submissionDeadline)                         │
│                                                                      │
│  Participant computes:                                               │
│  commitment = keccak256(answer + salt + address + bountyId)          │
│                                                                      │
│  Calls: submitCommitment(bountyId, commitment)                       │
│                                                                      │
│  ✅ Only the HASH is stored on-chain                                 │
│  ❌ Answer is completely hidden                                       │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ submissionDeadline passes
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     PHASE 2: REVEAL                                  │
│              (after submissionDeadline, before revealDeadline)       │
│                                                                      │
│  Calls: revealAnswer(bountyId, answer, salt)                         │
│                                                                      │
│  Contract verifies:                                                  │
│  keccak256(answer, salt, msg.sender, bountyId) == stored commitment  │
│                                                                      │
│  ✅ Answer proven unchanged since commit                             │
│  ✅ Cannot change answer after seeing others' submissions            │
└─────────────────────────┬───────────────────────────────────────────┘
                          │ revealDeadline passes
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     PHASE 3: JUDGE                                   │
│                    (after revealDeadline)                            │
│                                                                      │
│  Owner fetches revealed answers via getRevealedAnswers()             │
│  Builds ONE batch payload with ALL answers                           │
│  Calls: judgeAll(bountyId, llmInput)                                 │
│                                                                      │
│  → Single Ritual LLM precompile call (0x0802)                       │
│  → LLM ranks all submissions against the rubric                      │
│  → AI verdict stored in aiReview on-chain                           │
└─────────────────────────┬───────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    PHASE 4: FINALIZE                                 │
│                                                                      │
│  Owner reviews AI verdict                                            │
│  Calls: finalizeWinner(bountyId, winnerIndex)                        │
│                                                                      │
│  → Winner receives full reward via .call{value}                    │
│  → Human-in-the-loop: AI recommends, human decides                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Commitment Formula Explained

```solidity
bytes32 commitment = keccak256(
    abi.encodePacked(answer, salt, msg.sender, bountyId)
);
```

| Component | Why it is included |
|---|---|
| `answer` | The actual submission being hidden |
| `salt` | Random bytes32 — prevents brute-force guessing of short answers |
| `msg.sender` | Prevents commitment replay — you cannot submit someone else's hash |
| `bountyId` | Prevents cross-bounty replay — commitment is tied to one specific bounty |

---

## What Changed from the Base Contract

| Area | Before (workshop) | After (this submission) |
|---|---|---|
| Submission | `submitAnswer()` stores plaintext | `submitCommitment()` stores only a hash |
| Reveal | n/a | `revealAnswer()` verifies hash then stores plaintext |
| `createBounty` | single `deadline` | `submissionDeadline` + `revealDeadline` |
| Submissions list | shows answers live | shows 🔒 hidden until after judging |
| Frontend | single submit form | phase-aware: commit → reveal → judged |

---

## Test Plan

### Happy path
```
1. createBounty(title, rubric, subDeadline, revDeadline)  -- with ETH
2. computeCommitment(answer, salt, addr, bountyId)         -- get hash
3. submitCommitment(bountyId, hash)                        -- before subDeadline
4. [time passes submissionDeadline]
5. revealAnswer(bountyId, answer, salt)                    -- tx succeeds
6. [time passes revealDeadline]
7. judgeAll(bountyId, llmInput)                            -- Ritual LLM called
8. finalizeWinner(bountyId, 0)                             -- winner paid
```

### Failure cases
| Test | Expected revert |
|---|---|
| `submitCommitment` after deadline | "submission phase closed" |
| `revealAnswer` before deadline | "submission phase still open" |
| `revealAnswer` with wrong salt | "commitment mismatch" |
| `revealAnswer` with wrong answer | "commitment mismatch" |
| `revealAnswer` from different address | "commitment mismatch" |
| `revealAnswer` twice | "already revealed" |
| `submitCommitment` twice | "already committed" |
| `judgeAll` before revealDeadline | "reveal phase still open" |
| `judgeAll` with no reveals | "no revealed answers" |
| `finalizeWinner` on unrevealed submission | "invalid or unrevealed winner" |

---

## Architecture Note: Commit-Reveal vs Ritual-Native TEE

### Commit-Reveal (Required Track — implemented)

```
Participant          Chain                    Everyone
    │                  │                         │
    │──commit hash────►│                         │
    │                  │◄── hash stored          │
    │                  │    answer HIDDEN ───────►│ (cannot read)
    │                  │                         │
    │──reveal answer──►│                         │
    │                  │ verify hash ✓           │
    │                  │ store answer            │
    │                  │──── answer visible ────►│ (reveal phase)
    │                  │                         │
    │         judgeAll(batch LLM call)           │
    │                  │                         │
```

**Limitation:** Answers become public BEFORE AI judging. A very fast actor
could theoretically read revealed answers and try to influence the judging result.

### Ritual-Native TEE (Advanced Track — design)

```
Participant          Chain              Ritual TEE Executor
    │                  │                      │
    │─encrypt(answer)─►│                      │
    │                  │◄─ ciphertext stored  │
    │                  │   plaintext NEVER    │
    │                  │   on public chain    │
    │                  │                      │
    │         judgeAll triggers TEE           │
    │                  │──────────────────────►│
    │                  │              decrypt inside enclave
    │                  │              LLM judges privately
    │                  │◄─────────────────────│ signed verdict
    │                  │                      │
    │         finalizeWinner                  │
    │                  │                      │
```

**Advantage:** Answers stay encrypted until AFTER judging. Even the bounty
owner cannot read submissions before the verdict. Requires Ritual TEE
executor + DKMS precompile (0x081B) for key management.

**What is stored on-chain:** Encrypted ciphertext only.
**What is stored off-chain:** Nothing — TEE decrypts in-enclave at judge time.
**How LLM receives submissions:** TEE decrypts all answers inside the enclave,
builds one batch prompt, calls the LLM in a single request, returns signed verdict.

---

## Reflection

What should be public, what should stay hidden, and what should be decided
by AI versus by a human in a bounty system?

The bounty question, rubric, prize amount, and submission deadline should all
be public so participants can make informed decisions about whether to enter.
Individual answers must remain hidden until all commitments are locked — the
commit-reveal scheme enforces this without trusting any central authority.
Once the reveal phase closes, answers can safely become public because no one
can retroactively copy and improve a submission they have not seen. The
existence of a commitment (but not its content) can be public, letting
participants verify that the field is competitive. AI is well-suited to
scoring answers consistently against a rubric, catching patterns across the
submission set, and doing so in a single auditable batch call — tasks where
human judges introduce bias or fatigue. However, a human should retain the
right to flag disqualifications, override clear AI errors, and make the final
`finalizeWinner` call on-chain, taking accountable responsibility for the
outcome. This hybrid model keeps the process transparent: the AI verdict is
recorded in `aiReview` for anyone to inspect, while the human owner signs
the final decision on-chain.
