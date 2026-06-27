# Privacy-Preserving AI Bounty Judge
### Assignment submission — web3aunty / Goddesszee

## Overview

This fork adds a **commit-reveal privacy layer** to the Ritual AI Bounty Judge.
Participants can no longer see each other's answers during the submission phase,
eliminating copy-cat submissions.

---

## Bounty Lifecycle

```
createBounty()                     ← owner funds prize + sets two deadlines
     │
     ▼  [Commit phase]
submitCommitment(bountyId, hash)   ← participants submit keccak256 hash only
     │
     │  ← submissionDeadline passes ──────────────────────────────────┐
     ▼  [Reveal phase]                                                 │ no answer
revealAnswer(bountyId, answer, salt) ← participants reveal plaintext    │ visible
     │                                 contract verifies hash matches   │ on-chain
     │  ← revealDeadline passes ─────────────────────────────────────┘
     ▼  [Judge phase]
judgeAll(bountyId, llmInput)       ← owner triggers SINGLE batch Ritual LLM call
     │                                covering ALL revealed answers
     ▼  [Finalize]
finalizeWinner(bountyId, index)    ← owner records AI verdict, transfers prize
```

---

## Commitment Hash Formula

```
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

- **answer** — your plaintext submission string
- **salt** — a random `bytes32` you generate client-side (`crypto.getRandomValues`)
- **msg.sender** — binds the commitment to your address (prevents replay)
- **bountyId** — binds to this specific bounty (prevents cross-bounty reuse)

The contract's `computeCommitment()` view function lets you verify the hash off-chain.

---

## What Changed from the Base Contract

| Area | Before | After |
|---|---|---|
| Submission | `submitAnswer()` stores plaintext on-chain | `submitCommitment()` stores only a hash |
| Reveal | n/a | `revealAnswer()` verifies hash + stores plaintext |
| `createBounty` | single `deadline` | `submissionDeadline` + `revealDeadline` |
| `getBounty` | returns old tuple | extended tuple with both deadlines |
| ABI | original | updated to match new contract |
| Frontend | single submit form | commit form → reveal form (phase-aware) |
| Submissions list | shows all answers live | shows 🔒 hidden until after judging |

---

## Test Plan

### Happy path
1. Deploy → `createBounty(title, rubric, subDeadline, revDeadline)` with ETH
2. Call `computeCommitment(answer, salt, addr, bountyId)` → get `commitment`
3. `submitCommitment(bountyId, commitment)` ← before subDeadline
4. Warp time past `submissionDeadline`
5. `revealAnswer(bountyId, answer, salt)` → tx succeeds
6. Warp time past `revealDeadline`
7. `judgeAll(bountyId, llmInput)` → Ritual LLM called
8. `finalizeWinner(bountyId, 0)` → winner receives ETH

### Failure cases
| Test | Expected revert |
|---|---|
| `submitCommitment` after deadline | "submission phase closed" |
| `revealAnswer` before deadline | "submission phase still open" |
| `revealAnswer` with wrong salt | "commitment mismatch" |
| `revealAnswer` with wrong answer | "commitment mismatch" |
| `revealAnswer` from different address | "commitment mismatch" (address bound) |
| `revealAnswer` twice | "already revealed" |
| `submitCommitment` twice | "already committed" |
| `judgeAll` before revealDeadline | "reveal phase still open" |
| `finalizeWinner` on unrevealed submission | "winner has not revealed" |

---

## Architecture Note — Advanced Track (Ritual-Native)

### Where does plaintext exist?

| Layer | What's stored | Plaintext visible? |
|---|---|---|
| On-chain (commit phase) | `commitment` hash only | ❌ No |
| On-chain (after reveal) | plaintext `answer` | ✅ Yes — but only after all commitments locked |
| Off-chain (client) | answer + salt in browser memory | ✅ Yes — only to the user |
| Ritual TEE (judgeAll) | batch payload inside TEE | ✅ Yes — but isolated in hardware enclave |

### How does the LLM receive submissions for batch judging?

1. After `revealDeadline`, the owner calls `getRevealedAnswers(bountyId)` — a view function returning parallel arrays of `(submitters[], answers[])`.
2. The owner encodes all answers into a single `llmInput` bytes payload (JSON: `{question, rubric, submissions:[{index, answer}…]}`).
3. `judgeAll()` makes **one** call to Ritual's `LLM_INFERENCE_PRECOMPILE` with the entire batch — no per-answer LLM calls.
4. The LLM returns a structured verdict (`winnerIndex`, per-answer `score` + `reason`) encoded in `aiReview`.

### With full Ritual TEE-backed hidden submissions (Advanced Track concept)

In a fully private system, answers would be encrypted to the TEE's public key client-side and stored encrypted on-chain or in decentralised storage. The TEE would decrypt and judge inside the enclave, with the `TEEServiceRegistry` attesting to the executor's identity. Plaintext answers would exist **only inside the TEE enclave** — never on the public chain until after judging. This repo implements the commit-reveal approach (Required Track), which achieves the same fairness guarantee without requiring TEE encryption infrastructure.

---

## Reflection Question

> *What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?*

The bounty question, rubric, prize amount, and submission deadline should all be public so participants can make informed decisions about whether to enter. Individual answers must remain hidden until all commitments are locked — the commit-reveal scheme enforces this without trusting any central authority. Once the reveal phase closes, answers can safely become public because no one can retroactively copy and improve a submission they haven't seen. The existence of a commitment (but not its content) can be public, letting participants verify that the field is competitive. AI is well-suited to scoring answers consistently against a rubric, catching plagiarism across the submission set, and doing so in a single auditable batch call — tasks where human judges introduce bias or fatigue. However, a human should retain the right to flag disqualifications, override clear AI errors, and make the final `finalizeWinner` call on-chain. This hybrid model keeps the process transparent: the AI verdict is recorded in `aiReview` for anyone to inspect, while the human owner takes accountable, gas-signed responsibility for the final outcome.

---

## Deployed contract

> Update this after deploying to Ritual testnet:
> `NEXT_PUBLIC_CONTRACT_ADDRESS=0x...` in `web/.env.local`
