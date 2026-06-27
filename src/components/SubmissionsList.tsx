"use client";

import { useReadContract } from "wagmi";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { shortenAddress } from "@/lib/format";
import type { JudgeResult } from "@/lib/aiReview";
import { Card, CardHeader, CardBody, Badge } from "@/components/ui";
import type { Bounty } from "@/lib/bounty";

export function SubmissionsList({
  bountyId,
  bounty,
  count,
  judge,
  finalWinner,
}: {
  bountyId: bigint;
  bounty: Bounty;
  count: number;
  judge?: JudgeResult | null;
  finalWinner?: number;
}) {
  const indices = Array.from({ length: count }, (_, i) => i);
  const revealPhaseOpen =
    !bounty.judged &&
    !bounty.finalized &&
    Date.now() / 1000 >= Number(bounty.submissionDeadline) &&
    Date.now() / 1000 <  Number(bounty.revealDeadline);

  return (
    <Card>
      <CardHeader
        title="Commitments"
        subtitle={
          bounty.judged
            ? "All revealed answers have been judged."
            : revealPhaseOpen
              ? "Reveal phase is open. Answers visible after reveal."
              : "Commitment phase. Answers hidden until reveal."
        }
        action={<Badge tone="zinc">{count}</Badge>}
      />
      <CardBody className="space-y-3">
        {count === 0 ? (
          <p className="text-sm text-zinc-500">No commitments yet.</p>
        ) : (
          indices.map((i) => (
            <CommitmentRow
              key={i}
              bountyId={bountyId}
              bounty={bounty}
              index={i}
              ranking={judge?.ranking?.find((r) => r.index === i)}
              recommended={judge?.winnerIndex === i}
              isWinner={finalWinner === i}
            />
          ))
        )}
      </CardBody>
    </Card>
  );
}

function CommitmentRow({
  bountyId,
  bounty,
  index,
  ranking,
  recommended,
  isWinner,
}: {
  bountyId: bigint;
  bounty: Bounty;
  index: number;
  ranking?: { index: number; score: number; reason: string };
  recommended?: boolean;
  isWinner?: boolean;
}) {
  // We read from getRevealedAnswers only after judging, so we only show revealed answers.
  // For the commitment list we just show submitter + revealed status.
  const { data: commitData } = useReadContract({
    address: contractAddress,
    abi: aiJudgeAbi,
    // Use getSubmissionCount proxy via bounties mapping — we read commitment via getCommitment
    // but we don't have the submitter address here, so we use a trick:
    // We call getRevealedAnswers and index into it.
    functionName: "getRevealedAnswers",
    args: [bountyId],
    chainId: ritualChain.id,
    query: { enabled: !!contractAddress && bounty.judged },
  });

  const submitter = commitData?.[0]?.[index];
  const answer    = commitData?.[1]?.[index];
  const showAnswer = bounty.judged && !!answer;

  return (
    <div
      className={`rounded-xl border p-3 ${
        isWinner
          ? "border-emerald-500/40 bg-emerald-500/5"
          : recommended
            ? "border-indigo-500/40 bg-indigo-500/5"
            : "border-white/10 bg-black/20"
      }`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <span className="font-mono text-xs text-zinc-500">#{index}</span>
          <span className="font-mono text-sm text-zinc-300">
            {submitter ? shortenAddress(submitter) : "hidden"}
          </span>
        </div>
        <div className="flex items-center gap-1.5">
          {ranking ? <Badge tone="zinc">score {ranking.score}</Badge> : null}
          {isWinner ? (
            <Badge tone="green">Winner</Badge>
          ) : recommended ? (
            <Badge tone="indigo">AI pick</Badge>
          ) : null}
          {!showAnswer && !bounty.judged && (
            <Badge tone="zinc">🔒 hidden</Badge>
          )}
        </div>
      </div>

      {showAnswer ? (
        <p className="mt-2 whitespace-pre-wrap break-words text-sm text-zinc-200">{answer}</p>
      ) : (
        <p className="mt-2 text-xs text-zinc-600 italic">
          Answer hidden until after judging.
        </p>
      )}

      {ranking?.reason ? (
        <p className="mt-2 border-t border-white/5 pt-2 text-xs text-zinc-400">
          <span className="text-zinc-500">AI: </span>
          {ranking.reason}
        </p>
      ) : null}
    </div>
  );
}
