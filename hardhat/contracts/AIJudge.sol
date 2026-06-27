// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AIJudge — Privacy-Preserving Commit-Reveal Bounty Judge
 * @author web3aunty / Goddesszee
 *
 * LIFECYCLE
 * ─────────
 * 1. Owner creates a bounty with a prize pool, submission deadline, and reveal deadline.
 * 2. Participants submit a COMMITMENT HASH during the submission phase.
 *    - Nothing about the answer is revealed on-chain at this point.
 *    - Formula: keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
 *      • answer    — the plaintext answer (kept secret off-chain)
 *      • salt      — random bytes32 generated client-side (prevents brute-force)
 *      • msg.sender — binds commitment to this wallet (prevents replay attacks)
 *      • bountyId  — binds to this specific bounty (prevents cross-bounty reuse)
 * 3. After the submission deadline, participants REVEAL their answer + salt.
 *    - Contract verifies the hash matches the stored commitment.
 *    - Only then is the plaintext stored on-chain.
 * 4. After the reveal deadline, owner calls judgeAll() — ONE Ritual LLM call
 *    judges ALL revealed answers together in a single batch request.
 * 5. Owner calls finalizeWinner() — winner is paid the full prize pool.
 */
contract AIJudge {
    address internal constant LLM_INFERENCE_PRECOMPILE = address(0x0802);

    uint256 public constant MAX_SUBMISSIONS  = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;
    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        bytes32 commitment;   // stored at commit phase — answer stays hidden
        string  answer;       // populated only after successful reveal
        bool    revealed;
    }

    struct Bounty {
        address  owner;
        string   title;
        string   rubric;
        uint256  reward;
        uint256  submissionDeadline; // commit phase closes here
        uint256  revealDeadline;     // reveal phase closes here
        bool     judged;
        bool     finalized;
        bytes    aiReview;
        uint256  winnerIndex;
    }

    struct BountyView {
        address  owner;
        string   title;
        string   rubric;
        uint256  reward;
        uint256  submissionDeadline;
        uint256  revealDeadline;
        bool     judged;
        bool     finalized;
        uint256  submissionCount;
        uint256  winnerIndex;
        bytes    aiReview;
    }

    struct ConvoHistory { string storageType; string path; string secretsName; }

    mapping(uint256 => Bounty)                           public  bounties;
    mapping(uint256 => Submission[])                     private _submissions;
    mapping(uint256 => mapping(address => uint256))      private _submitterIndex;

    event BountyCreated(uint256 indexed bountyId, address indexed owner, string title, uint256 reward, uint256 submissionDeadline, uint256 revealDeadline);
    event CommitmentSubmitted(uint256 indexed bountyId, uint256 indexed subIndex, address indexed submitter);
    event AnswerRevealed(uint256 indexed bountyId, uint256 indexed subIndex, address indexed submitter);
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(uint256 indexed bountyId, uint256 indexed winnerIndex, address indexed winner, uint256 reward);

    modifier onlyOwner(uint256 bountyId) { require(msg.sender == bounties[bountyId].owner, "not bounty owner"); _; }
    modifier bountyExists(uint256 bountyId) { require(bounties[bountyId].owner != address(0), "bounty not found"); _; }

    function _executePrecompile(address precompile, bytes memory input) internal returns (bytes memory) {
        (bool success, bytes memory rawOutput) = precompile.call(input);
        if (!success) { assembly { revert(add(rawOutput, 32), mload(rawOutput)) } }
        (, bytes memory actualOutput) = abi.decode(rawOutput, (bytes, bytes));
        return actualOutput;
    }

    // ── Phase 0: Create ────────────────────────────────────────────────────
    function createBounty(
        string  calldata title,
        string  calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission deadline must be future");
        require(revealDeadline > submissionDeadline, "reveal deadline must be after submission deadline");
        bountyId = nextBountyId++;
        Bounty storage b = bounties[bountyId];
        b.owner = msg.sender; b.title = title; b.rubric = rubric;
        b.reward = msg.value; b.submissionDeadline = submissionDeadline;
        b.revealDeadline = revealDeadline; b.winnerIndex = type(uint256).max;
        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline, revealDeadline);
    }

    // ── Phase 1: Commit ────────────────────────────────────────────────────
    /**
     * @notice Submit a commitment hash. Your answer stays completely hidden.
     * @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *
     * WHY include msg.sender?
     *   Prevents another participant from copying your commitment and submitting it
     *   as their own — they can never produce a valid reveal for your address.
     *
     * WHY include bountyId?
     *   Prevents reusing a commitment from one bounty in a different bounty.
     *
     * WHY include salt?
     *   Prevents brute-force guessing of short answers by pre-computing rainbow tables.
     */
    function submitCommitment(uint256 bountyId, bytes32 commitment) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp < b.submissionDeadline, "submission phase closed");
        require(_submitterIndex[bountyId][msg.sender] == 0, "already committed");
        require(_submissions[bountyId].length < MAX_SUBMISSIONS, "too many submissions");
        require(commitment != bytes32(0), "empty commitment");
        _submissions[bountyId].push(Submission({ submitter: msg.sender, commitment: commitment, answer: "", revealed: false }));
        uint256 idx = _submissions[bountyId].length - 1;
        _submitterIndex[bountyId][msg.sender] = idx + 1;
        emit CommitmentSubmitted(bountyId, idx, msg.sender);
    }

    // ── Phase 2: Reveal ────────────────────────────────────────────────────
    /**
     * @notice Reveal your answer after the submission deadline.
     *         The contract recomputes the hash and verifies it matches your commitment.
     *         Only then is the plaintext answer stored on-chain and eligible for judging.
     */
    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp >= b.submissionDeadline, "submission phase still open");
        require(block.timestamp < b.revealDeadline, "reveal phase closed");
        require(!b.judged && !b.finalized, "already judged or finalized");
        require(bytes(answer).length > 0 && bytes(answer).length <= MAX_ANSWER_LENGTH, "invalid answer length");
        uint256 raw = _submitterIndex[bountyId][msg.sender];
        require(raw != 0, "no commitment found");
        Submission storage sub = _submissions[bountyId][raw - 1];
        require(!sub.revealed, "already revealed");
        require(sub.commitment == keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)), "commitment mismatch");
        sub.answer = answer; sub.revealed = true;
        emit AnswerRevealed(bountyId, raw - 1, msg.sender);
    }

    // ── Phase 3: Judge ─────────────────────────────────────────────────────
    /**
     * @notice Batch-judge ALL revealed answers in a single Ritual LLM call.
     *         Build llmInput off-chain using getRevealedAnswers().
     *         One batch request — never one LLM call per submission.
     */
    function judgeAll(uint256 bountyId, bytes calldata llmInput) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(block.timestamp >= b.revealDeadline, "reveal phase still open");
        require(!b.judged && !b.finalized, "already judged or finalized");
        require(_countRevealed(bountyId) > 0, "no revealed answers");
        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);
        (bool hasError, bytes memory completionData,, string memory errorMessage,) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));
        require(!hasError, errorMessage);
        b.judged = true; b.aiReview = completionData;
        emit AllAnswersJudged(bountyId, completionData);
    }

    // ── Phase 4: Finalize ──────────────────────────────────────────────────
    /**
     * @notice Human-in-the-loop: owner reviews AI recommendation and finalizes winner.
     *         AI recommends, human decides, contract enforces payout.
     */
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        require(b.judged && !b.finalized, "not judged or already finalized");
        Submission[] storage subs = _submissions[bountyId];
        require(winnerIndex < subs.length && subs[winnerIndex].revealed, "invalid or unrevealed winner");
        b.finalized = true; b.winnerIndex = winnerIndex;
        address winner = subs[winnerIndex].submitter;
        uint256 reward = b.reward; b.reward = 0;
        (bool ok,) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");
        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ── View helpers ───────────────────────────────────────────────────────
    function getBounty(uint256 bountyId) external view bountyExists(bountyId) returns (BountyView memory) {
        Bounty storage b = bounties[bountyId];
        return BountyView(b.owner, b.title, b.rubric, b.reward, b.submissionDeadline, b.revealDeadline, b.judged, b.finalized, _submissions[bountyId].length, b.winnerIndex, b.aiReview);
    }

    function getRevealedAnswers(uint256 bountyId) external view bountyExists(bountyId) returns (address[] memory submitters, string[] memory answers) {
        Submission[] storage subs = _submissions[bountyId];
        uint256 n = _countRevealed(bountyId);
        submitters = new address[](n); answers = new string[](n);
        uint256 j;
        for (uint256 i; i < subs.length; i++) { if (subs[i].revealed) { submitters[j] = subs[i].submitter; answers[j] = subs[i].answer; j++; } }
    }

    function getCommitment(uint256 bountyId, address submitter) external view bountyExists(bountyId) returns (bytes32 commitment, bool revealed) {
        uint256 raw = _submitterIndex[bountyId][submitter];
        require(raw != 0, "no submission");
        Submission storage sub = _submissions[bountyId][raw - 1];
        return (sub.commitment, sub.revealed);
    }

    function computeCommitment(string calldata answer, bytes32 salt, address submitter, uint256 bountyId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    function getSubmissionCount(uint256 bountyId) external view bountyExists(bountyId) returns (uint256) {
        return _submissions[bountyId].length;
    }

    function _countRevealed(uint256 bountyId) internal view returns (uint256 count) {
        Submission[] storage subs = _submissions[bountyId];
        for (uint256 i; i < subs.length; i++) { if (subs[i].revealed) count++; }
    }
}
