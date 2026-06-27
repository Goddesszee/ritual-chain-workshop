"use client";

import { useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { encodePacked, keccak256, toHex, hexToBytes } from "viem";
import { useNow } from "@/hooks/useNow";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { canCommit, canReveal, type Bounty } from "@/lib/bounty";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Textarea,
  Input,
  Button,
  TxStatus,
  Notice,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

/** Generate a cryptographically random 32-byte salt as hex. */
function generateSalt(): `0x${string}` {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return toHex(bytes);
}

export function SubmitAnswer({
  bountyId,
  bounty,
  onSubmitted,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onSubmitted: () => void;
}) {
  const { address, isConnected } = useAccount();
  const now = useNow();
  const nowSec = now / 1000;

  // Commit phase state
  const [answer, setAnswer]   = useState("");
  const [salt,   setSalt]     = useState<`0x${string}`>(generateSalt);
  const [savedAnswer, setSavedAnswer] = useState("");
  const [savedSalt,   setSavedSalt]   = useState("");
  const [commitDone,  setCommitDone]  = useState(false);

  // Reveal phase state
  const [revealAnswer, setRevealAnswer] = useState("");
  const [revealSalt,   setRevealSalt]   = useState("");

  const commitTx = useWriteTx(() => {
    setSavedAnswer(answer);
    setSavedSalt(salt);
    setCommitDone(true);
    onSubmitted();
  });

  const revealTx = useWriteTx(() => {
    onSubmitted();
  });

  // ── Check if this wallet already has a commitment ──
  const { data: existingCommit } = useReadContract({
    address: contractAddress,
    abi: aiJudgeAbi,
    functionName: "getCommitment",
    args: [bountyId, address as `0x${string}`],
    chainId: ritualChain.id,
    query: { enabled: !!contractAddress && !!address },
  });
  const alreadyCommitted = !!(existingCommit?.[0] && existingCommit[0] !== "0x" + "0".repeat(64));
  const alreadyRevealed  = existingCommit?.[1] === true;

  // ── COMMIT PHASE ───────────────────────────────────
  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress || !address) return;

    const commitment = keccak256(
      encodePacked(
        ["string", "bytes32", "address", "uint256"],
        [answer.trim(), salt as `0x${string}`, address, bountyId]
      )
    );

    try {
      await commitTx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "submitCommitment",
        args: [bountyId, commitment],
        chainId: ritualChain.id,
      });
    } catch { /* surfaced via tx.state */ }
  }

  // ── REVEAL PHASE ───────────────────────────────────
  async function handleReveal(e: React.FormEvent) {
    e.preventDefault();
    if (!revealAnswer.trim() || !revealSalt || !contractAddress) return;
    try {
      await revealTx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "revealAnswer",
        args: [bountyId, revealAnswer.trim(), revealSalt as `0x${string}`],
        chainId: ritualChain.id,
      });
    } catch { /* surfaced via tx.state */ }
  }

  // ── COMMIT UI ──────────────────────────────────────
  if (canCommit(bounty, nowSec) && !alreadyCommitted) {
    return (
      <Card>
        <CardHeader
          title="Submit your commitment"
          subtitle="Your answer stays hidden until the reveal phase. Save your salt — you will need it."
        />
        <CardBody>
          <form onSubmit={handleCommit} className="space-y-3">
            <Field label="Your answer">
              <Textarea
                value={answer}
                onChange={(e) => setAnswer(e.target.value)}
                rows={5}
                placeholder="Write your answer…"
              />
            </Field>

            <Field label="Salt (auto-generated — save this!)" hint="Copy and store your salt. Without it you cannot reveal.">
              <div className="flex gap-2">
                <Input
                  value={salt}
                  onChange={(e) => setSalt(e.target.value as `0x${string}`)}
                  className="font-mono text-xs"
                />
                <Button type="button" onClick={() => setSalt(generateSalt())} className="shrink-0 px-3">
                  ↺
                </Button>
              </div>
            </Field>

            <Notice tone="amber">
              ⚠️ Save your answer and salt now. Once you submit the commitment, you cannot change them.
            </Notice>

            <Button
              type="submit"
              disabled={!isConnected || !answer.trim() || commitTx.isBusy}
              className="w-full"
            >
              {commitTx.isBusy ? "Committing…" : "Submit commitment"}
            </Button>

            <TxStatus state={commitTx.state} error={commitTx.error} hash={commitTx.hash} explorerBase={explorerBase} />

            {commitDone && (
              <Notice tone="green">
                ✅ Commitment stored on-chain! Your answer is hidden until the reveal phase.<br />
                <span className="font-mono text-xs break-all">Salt: {savedSalt}</span>
              </Notice>
            )}
          </form>
        </CardBody>
      </Card>
    );
  }

  // ── ALREADY COMMITTED, WAITING FOR REVEAL PHASE ────
  if (alreadyCommitted && canCommit(bounty, nowSec)) {
    return (
      <Card>
        <CardHeader title="Commitment submitted ✓" subtitle="Wait for the submission deadline, then return to reveal your answer." />
        <CardBody>
          <Notice tone="indigo">Your commitment is on-chain. Reveal phase opens after the submission deadline.</Notice>
        </CardBody>
      </Card>
    );
  }

  // ── REVEAL UI ──────────────────────────────────────
  if (canReveal(bounty, nowSec) && alreadyCommitted && !alreadyRevealed) {
    return (
      <Card>
        <CardHeader
          title="Reveal your answer"
          subtitle="Enter the exact answer and salt you used when committing."
        />
        <CardBody>
          <form onSubmit={handleReveal} className="space-y-3">
            <Field label="Your original answer">
              <Textarea
                value={revealAnswer}
                onChange={(e) => setRevealAnswer(e.target.value)}
                rows={5}
                placeholder="Must match your committed answer exactly…"
              />
            </Field>
            <Field label="Your salt" hint="The 0x... value you saved when committing.">
              <Input
                value={revealSalt}
                onChange={(e) => setRevealSalt(e.target.value)}
                className="font-mono text-xs"
                placeholder="0x..."
              />
            </Field>
            <Button
              type="submit"
              disabled={!isConnected || !revealAnswer.trim() || !revealSalt || revealTx.isBusy}
              className="w-full"
            >
              {revealTx.isBusy ? "Revealing…" : "Reveal answer"}
            </Button>
            <TxStatus state={revealTx.state} error={revealTx.error} hash={revealTx.hash} explorerBase={explorerBase} />
          </form>
        </CardBody>
      </Card>
    );
  }

  if (alreadyRevealed) {
    return (
      <Card>
        <CardHeader title="Answer revealed ✓" subtitle="Your answer has been revealed and is eligible for judging." />
      </Card>
    );
  }

  return null;
}
