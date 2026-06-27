"use client";

import { useState } from "react";
import { useAccount, usePublicClient } from "wagmi";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import type { Bounty } from "@/lib/bounty";
import { buildJudgeAllLlmInput, type JudgeSubmission } from "@/lib/ritualLlm";
import { useWriteTx } from "@/hooks/useWriteTx";
import { useRitualWalletStatus } from "@/hooks/useRitualWalletStatus";
import { RitualWalletPanel } from "@/components/RitualWalletPanel";
import { Card, CardHeader, CardBody, Button, TxStatus, Notice, Spinner } from "@/components/ui";
import { useNow } from "@/hooks/useNow";

const explorerBase = ritualChain.blockExplorers?.default.url;

const FALLBACK_EXECUTOR = "0x0000000000000000000000000000000000000000" as `0x${string}`;

export function JudgeAll({
  bountyId,
  bounty,
  isOwner,
  onJudged,
}: {
  bountyId: bigint;
  bounty: Bounty;
  isOwner: boolean;
  onJudged: () => void;
}) {
  const { address } = useAccount();
  const publicClient = usePublicClient({ chainId: ritualChain.id });
  const [gathering, setGathering] = useState(false);
  const [gatherError, setGatherError] = useState<string | null>(null);
  const tx = useWriteTx(() => onJudged());
  const now = useNow();
  const nowSec = now / 1000;

  const walletStatus = useRitualWalletStatus(address);

  const count = Number(bounty.submissionCount);
  const revealDeadlinePassed = Number(bounty.revealDeadline) <= nowSec;

  if (!isOwner || bounty.judged || bounty.finalized || count === 0 || !revealDeadlinePassed) {
    return null;
  }

  async function handleJudge() {
    if (!publicClient || !contractAddress || !walletStatus.ready) return;
    setGatherError(null);
    setGathering(true);
    try {
      const [submitters, answers] = await publicClient.readContract({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "getRevealedAnswers",
        args: [bountyId],
      });

      if (submitters.length === 0) {
        setGatherError("No revealed answers to judge. Participants must reveal first.");
        setGathering(false);
        return;
      }

      const submissions: JudgeSubmission[] = submitters.map((submitter, i) => ({
        index: i,
        submitter,
        answer: answers[i],
      }));

      const executorAddr = (process.env.NEXT_PUBLIC_EXECUTOR_ADDRESS as `0x${string}` | undefined) ?? FALLBACK_EXECUTOR;

      const llmInput = buildJudgeAllLlmInput({
        executorAddress: executorAddr,
        title: bounty.title,
        rubric: bounty.rubric,
        submissions,
      });

      setGathering(false);

      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "judgeAll",
        args: [bountyId, llmInput],
        chainId: ritualChain.id,
      });
    } catch (e) {
      setGathering(false);
      setGatherError(
        (e as { shortMessage?: string; message?: string }).shortMessage ||
          (e as Error).message ||
          "Failed to gather submissions.",
      );
    }
  }

  const busy = gathering || tx.isBusy;
  const fundingReady = walletStatus.ready === true;

  return (
    <Card>
      <CardHeader
        title="Judge all submissions"
        subtitle="Sends one Ritual LLM request ranking every revealed answer."
      />
      <CardBody className="space-y-3">
        <Notice tone="indigo">AI review is advisory. The bounty owner finalizes the winner.</Notice>
        <RitualWalletPanel status={walletStatus} onDeposited={walletStatus.refetch} />
        <Button onClick={handleJudge} disabled={busy || !fundingReady} className="w-full">
          {gathering ? (
            <><Spinner /> Loading revealed answers…</>
          ) : tx.isBusy ? (
            "Judging…"
          ) : !fundingReady ? (
            "Fund RitualWallet to judge"
          ) : (
            `Judge all revealed (${count} committed)`
          )}
        </Button>
        {gatherError && <Notice tone="red">{gatherError}</Notice>}
        <TxStatus state={tx.state} error={tx.error} hash={tx.hash} explorerBase={explorerBase} />
      </CardBody>
    </Card>
  );
}
