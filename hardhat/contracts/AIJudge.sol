// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title AIJudge — Privacy-Preserving Commit-Reveal Bounty Judge
 * @author web3aunty / Goddesszee
 *
 * LIFECYCLE
 * ─────────
 * 1. Owner calls createBounty() — sets submissionDeadline + revealDeadline, funds prize.
 * 2. Participants call submitCommitment() before submissionDeadline.
 *    Only a hash is stored on-chain; the answer stays private.
 * 3. After submissionDeadline, participants call revealAnswer() with plaintext + salt.
 *    Contract verifies keccak256(answer, salt, msg.sender, bountyId) == stored commitment.
 * 4. Owner calls judgeAll() — batch-judges ALL revealed answers via Ritual LLM precompile.
 * 5. Owner calls finalizeWinner() — winner is paid out.
 */
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS  = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        bytes32 commitment;   // stored at commit phase
        string  answer;       // populated only after reveal
        bool    revealed;
    }

    struct Bounty {
        address  owner;
        string   title;
        string   rubric;
        uint256  reward;
        uint256  submissionDeadline; // no new commits after this
        uint256  revealDeadline;     // no new reveals after this
        bool     judged;
        bool     finalized;
        bytes    aiReview;
        uint256  winnerIndex;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty)                           public  bounties;
    mapping(uint256 => Submission[])                     private _submissions;
    // bountyId => submitter => 1-based index (0 = no submission)
    mapping(uint256 => mapping(address => uint256))      private _submitterIndex;

    // ── Events ──────────────────────────────────────────────
    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string  title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );
    event CommitmentSubmitted(uint256 indexed bountyId, uint256 indexed subIndex, address indexed submitter);
    event AnswerRevealed(uint256 indexed bountyId, uint256 indexed subIndex, address indexed submitter);
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(uint256 indexed bountyId, uint256 indexed winnerIndex, address indexed winner, uint256 reward);

    // ── Modifiers ───────────────────────────────────────────
    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }
    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ── Bounty creation ─────────────────────────────────────
    function createBounty(
        string  calldata title,
        string  calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission deadline must be future");
        require(revealDeadline > submissionDeadline,  "reveal deadline must be after submission deadline");

        bountyId = nextBountyId++;

        Bounty storage b = bounties[bountyId];
        b.owner              = msg.sender;
        b.title              = title;
        b.rubric             = rubric;
        b.reward             = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.revealDeadline     = revealDeadline;
        b.winnerIndex        = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline, revealDeadline);
    }

    // ── PHASE 1: Commit ─────────────────────────────────────
    /**
     * @notice Submit a commitment hash. Answer stays hidden until reveal phase.
     * @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *                   Compute this off-chain before calling.
     */
    function submitCommitment(uint256 bountyId, bytes32 commitment)
        external
        bountyExists(bountyId)
    {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp < b.submissionDeadline, "submission phase closed");
        require(_submitterIndex[bountyId][msg.sender] == 0, "already committed");
        require(_submissions[bountyId].length < MAX_SUBMISSIONS, "too many submissions");
        require(commitment != bytes32(0), "empty commitment");

        _submissions[bountyId].push(Submission({
            submitter:  msg.sender,
            commitment: commitment,
            answer:     "",
            revealed:   false
        }));

        uint256 idx = _submissions[bountyId].length - 1;
        _submitterIndex[bountyId][msg.sender] = idx + 1; // 1-based

        emit CommitmentSubmitted(bountyId, idx, msg.sender);
    }

    // ── PHASE 2: Reveal ─────────────────────────────────────
    /**
     * @notice Reveal your plaintext answer. Contract verifies it matches your commitment.
     * @param answer  Your original answer text.
     * @param salt    The random bytes32 salt you used when computing the commitment.
     */
    function revealAnswer(
        uint256 bountyId,
        string  calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp >= b.submissionDeadline, "submission phase still open");
        require(block.timestamp <  b.revealDeadline,     "reveal phase closed");
        require(!b.judged,    "already judged");
        require(!b.finalized, "already finalized");
        require(bytes(answer).length > 0,                "empty answer");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 raw = _submitterIndex[bountyId][msg.sender];
        require(raw != 0, "no commitment found");

        Submission storage sub = _submissions[bountyId][raw - 1];
        require(!sub.revealed, "already revealed");

        // ── Core security check ──
        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(sub.commitment == expected, "commitment mismatch — wrong answer or salt");

        sub.answer   = answer;
        sub.revealed = true;

        emit AnswerRevealed(bountyId, raw - 1, msg.sender);
    }

    // ── PHASE 3: Judge ──────────────────────────────────────
    /**
     * @notice Batch-judge ALL revealed answers via Ritual LLM precompile in a single call.
     *         llmInput should be constructed off-chain from getRevealedAnswers().
     */
    function judgeAll(
        uint256 bountyId,
        bytes   calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp >= b.revealDeadline, "reveal phase still open");
        require(!b.judged,    "already judged");
        require(!b.finalized, "already finalized");

        uint256 revealCount = _countRevealed(bountyId);
        require(revealCount > 0, "no revealed answers");

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        (
            bool   hasError,
            bytes  memory completionData,
            ,
            string memory errorMessage,
        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        b.judged   = true;
        b.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    // ── PHASE 4: Finalize ───────────────────────────────────
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(b.judged,     "not judged yet");
        require(!b.finalized, "already finalized");

        Submission[] storage subs = _submissions[bountyId];
        require(winnerIndex < subs.length, "invalid winner index");
        require(subs[winnerIndex].revealed, "winner has not revealed");

        b.finalized   = true;
        b.winnerIndex = winnerIndex;

        address winner = subs[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ── View helpers ────────────────────────────────────────
    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string  memory title,
            string  memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool    judged,
            bool    finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes   memory aiReview
        )
    {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner, b.title, b.rubric, b.reward,
            b.submissionDeadline, b.revealDeadline,
            b.judged, b.finalized,
            _submissions[bountyId].length,
            b.winnerIndex, b.aiReview
        );
    }

    /**
     * @notice Returns all revealed answers for building the LLM batch payload off-chain.
     *         Commitments and unrevealed entries are excluded.
     */
    function getRevealedAnswers(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (address[] memory submitters, string[] memory answers)
    {
        Submission[] storage subs = _submissions[bountyId];
        uint256 n = _countRevealed(bountyId);
        submitters = new address[](n);
        answers    = new string[](n);
        uint256 j;
        for (uint256 i; i < subs.length; i++) {
            if (subs[i].revealed) {
                submitters[j] = subs[i].submitter;
                answers[j]    = subs[i].answer;
                j++;
            }
        }
    }

    /**
     * @notice Returns the commitment hash for a given submitter (for off-chain verification).
     *         Does NOT reveal the answer.
     */
    function getCommitment(uint256 bountyId, address submitter)
        external
        view
        bountyExists(bountyId)
        returns (bytes32 commitment, bool revealed)
    {
        uint256 raw = _submitterIndex[bountyId][submitter];
        require(raw != 0, "no submission");
        Submission storage sub = _submissions[bountyId][raw - 1];
        return (sub.commitment, sub.revealed);
    }

    /**
     * @notice Helper — compute the commitment hash off-chain equivalent.
     *         Call this view function to preview what commitment you should submit.
     */
    function computeCommitment(
        string  calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    function getSubmissionCount(uint256 bountyId) external view bountyExists(bountyId) returns (uint256) {
        return _submissions[bountyId].length;
    }

    // ── Internal ─────────────────────────────────────────────
    function _countRevealed(uint256 bountyId) internal view returns (uint256 count) {
        Submission[] storage subs = _submissions[bountyId];
        for (uint256 i; i < subs.length; i++) {
            if (subs[i].revealed) count++;
        }
    }
}
