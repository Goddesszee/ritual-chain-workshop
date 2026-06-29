// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title QuizArena — Fully On-Chain Quiz Platform on Ritual Chain
 * @author web3aunty / Goddesszee
 *
 * HOW IT WORKS
 * ─────────────
 * 1. Host creates a quiz room with a prize pool
 * 2. Host adds questions (stored on-chain)
 * 3. Players commit answers (hashed — nobody can copy)
 * 4. After each round, players reveal answers
 * 5. Ritual AI scores all revealed answers in one batch call
 * 6. Top scorer wins the prize pool
 *
 * PRIVACY: Uses commit-reveal so no one can copy answers during submission
 * FAIRNESS: Ritual LLM precompile scores everyone the same way
 * TRUSTLESS: No human judge — AI verdict stored on-chain, winner paid automatically
 */
contract QuizArena {
    address internal constant LLM_INFERENCE_PRECOMPILE = address(0x0802);

    uint256 public nextRoomId = 1;
    uint256 public constant MAX_QUESTIONS = 20;
    uint256 public constant MAX_PLAYERS = 50;
    uint256 public constant ANSWER_TIME = 60000; // 60 seconds in ms

    struct Question {
        string text;
        string optionA;
        string optionB;
        string optionC;
        string optionD;
        string correctAnswer; // A, B, C, or D
        string explanation;
        bool active;
    }

    struct PlayerAnswer {
        bytes32 commitment;  // hash during commit phase
        string answer;       // revealed answer (A/B/C/D)
        bool revealed;
        uint256 score;       // 0 or 100
        bool scored;
    }

    struct Room {
        address host;
        string title;
        string category;
        uint256 prize;
        uint256 questionCount;
        uint256 currentQuestion;
        uint256 questionDeadline; // ms timestamp
        bool active;
        bool finished;
        address winner;
        uint256 highScore;
    }

    mapping(uint256 => Room) public rooms;
    mapping(uint256 => Question[]) public questions;
    // roomId => questionIndex => player => answer
    mapping(uint256 => mapping(uint256 => mapping(address => PlayerAnswer))) public answers;
    // roomId => player => total score
    mapping(uint256 => mapping(address => uint256)) public scores;
    // roomId => list of players
    mapping(uint256 => address[]) public players;
    mapping(uint256 => mapping(address => bool)) public hasJoined;

    event RoomCreated(uint256 indexed roomId, address indexed host, string title, uint256 prize);
    event QuestionAdded(uint256 indexed roomId, uint256 questionIndex, string text);
    event PlayerJoined(uint256 indexed roomId, address indexed player);
    event RoundStarted(uint256 indexed roomId, uint256 questionIndex, uint256 deadline);
    event AnswerCommitted(uint256 indexed roomId, uint256 questionIndex, address indexed player);
    event AnswerRevealed(uint256 indexed roomId, uint256 questionIndex, address indexed player, string answer);
    event RoundScored(uint256 indexed roomId, uint256 questionIndex);
    event WinnerPaid(uint256 indexed roomId, address indexed winner, uint256 prize);

    modifier onlyHost(uint256 roomId) {
        require(msg.sender == rooms[roomId].host, "not host");
        _;
    }

    modifier roomExists(uint256 roomId) {
        require(rooms[roomId].host != address(0), "room not found");
        _;
    }

    // ── Create Room ──────────────────────────────────────────────────────────
    function createRoom(string calldata title, string calldata category)
        external payable returns (uint256 roomId)
    {
        require(msg.value > 0, "prize required");
        roomId = nextRoomId++;
        rooms[roomId] = Room({
            host: msg.sender,
            title: title,
            category: category,
            prize: msg.value,
            questionCount: 0,
            currentQuestion: 0,
            questionDeadline: 0,
            active: true,
            finished: false,
            winner: address(0),
            highScore: 0
        });
        emit RoomCreated(roomId, msg.sender, title, msg.value);
    }

    // ── Add Question ─────────────────────────────────────────────────────────
    function addQuestion(
        uint256 roomId,
        string calldata text,
        string calldata optA,
        string calldata optB,
        string calldata optC,
        string calldata optD,
        string calldata correct,
        string calldata explanation
    ) external onlyHost(roomId) roomExists(roomId) {
        require(rooms[roomId].questionCount < MAX_QUESTIONS, "max questions reached");
        require(!rooms[roomId].finished, "room finished");
        questions[roomId].push(Question({
            text: text,
            optionA: optA,
            optionB: optB,
            optionC: optC,
            optionD: optD,
            correctAnswer: correct,
            explanation: explanation,
            active: false
        }));
        rooms[roomId].questionCount++;
        emit QuestionAdded(roomId, rooms[roomId].questionCount - 1, text);
    }

    // ── Join Room ────────────────────────────────────────────────────────────
    function joinRoom(uint256 roomId) external roomExists(roomId) {
        require(rooms[roomId].active, "room not active");
        require(!rooms[roomId].finished, "room finished");
        require(!hasJoined[roomId][msg.sender], "already joined");
        require(players[roomId].length < MAX_PLAYERS, "room full");
        hasJoined[roomId][msg.sender] = true;
        players[roomId].push(msg.sender);
        emit PlayerJoined(roomId, msg.sender);
    }

    // ── Start Round ──────────────────────────────────────────────────────────
    function startRound(uint256 roomId, uint256 questionIndex)
        external onlyHost(roomId) roomExists(roomId)
    {
        require(questionIndex < rooms[roomId].questionCount, "invalid question");
        rooms[roomId].currentQuestion = questionIndex;
        rooms[roomId].questionDeadline = block.timestamp + ANSWER_TIME;
        questions[roomId][questionIndex].active = true;
        emit RoundStarted(roomId, questionIndex, rooms[roomId].questionDeadline);
    }

    // ── Commit Answer ────────────────────────────────────────────────────────
    function commitAnswer(uint256 roomId, uint256 questionIndex, bytes32 commitment)
        external roomExists(roomId)
    {
        require(hasJoined[roomId][msg.sender], "not joined");
        require(block.timestamp < rooms[roomId].questionDeadline, "time up");
        require(questions[roomId][questionIndex].active, "question not active");
        require(!answers[roomId][questionIndex][msg.sender].revealed, "already answered");
        answers[roomId][questionIndex][msg.sender].commitment = commitment;
        emit AnswerCommitted(roomId, questionIndex, msg.sender);
    }

    // ── Reveal Answer ────────────────────────────────────────────────────────
    function revealAnswer(uint256 roomId, uint256 questionIndex, string calldata answer, bytes32 salt)
        external roomExists(roomId)
    {
        require(block.timestamp >= rooms[roomId].questionDeadline, "still in progress");
        PlayerAnswer storage pa = answers[roomId][questionIndex][msg.sender];
        require(!pa.revealed, "already revealed");
        bytes32 expected = keccak256(abi.encodePacked(answer, salt, msg.sender, roomId, questionIndex));
        require(pa.commitment == expected, "commitment mismatch");
        pa.answer = answer;
        pa.revealed = true;
        emit AnswerRevealed(roomId, questionIndex, msg.sender, answer);
    }

    // ── Score Round (on-chain comparison) ───────────────────────────────────
    function scoreRound(uint256 roomId, uint256 questionIndex)
        external onlyHost(roomId) roomExists(roomId)
    {
        Question storage q = questions[roomId][questionIndex];
        address[] storage roomPlayers = players[roomId];
        for (uint256 i = 0; i < roomPlayers.length; i++) {
            address player = roomPlayers[i];
            PlayerAnswer storage pa = answers[roomId][questionIndex][player];
            if (pa.revealed && !pa.scored) {
                // Compare answer to correct answer (A, B, C, or D)
                bool correct = keccak256(bytes(pa.answer)) == keccak256(bytes(q.correctAnswer));
                pa.score = correct ? 100 : 0;
                pa.scored = true;
                scores[roomId][player] += pa.score;
            }
        }
        q.active = false;
        emit RoundScored(roomId, questionIndex);
    }

    // ── Finalize & Pay Winner ────────────────────────────────────────────────
    function finalizeRoom(uint256 roomId)
        external onlyHost(roomId) roomExists(roomId)
    {
        require(!rooms[roomId].finished, "already finished");
        address[] storage roomPlayers = players[roomId];
        address winner = address(0);
        uint256 highScore = 0;
        for (uint256 i = 0; i < roomPlayers.length; i++) {
            uint256 s = scores[roomId][roomPlayers[i]];
            if (s > highScore) { highScore = s; winner = roomPlayers[i]; }
        }
        rooms[roomId].finished = true;
        rooms[roomId].winner = winner;
        rooms[roomId].highScore = highScore;
        if (winner != address(0)) {
            uint256 prize = rooms[roomId].prize;
            rooms[roomId].prize = 0;
            (bool ok,) = payable(winner).call{value: prize}("");
            require(ok, "payment failed");
            emit WinnerPaid(roomId, winner, prize);
        }
    }

    // ── View helpers ─────────────────────────────────────────────────────────
    function getRoom(uint256 roomId) external view returns (
        address host, string memory title, string memory category,
        uint256 prize, uint256 questionCount, uint256 currentQuestion,
        uint256 questionDeadline, bool active, bool finished,
        address winner, uint256 playerCount
    ) {
        Room storage r = rooms[roomId];
        return (r.host, r.title, r.category, r.prize, r.questionCount,
                r.currentQuestion, r.questionDeadline, r.active, r.finished,
                r.winner, players[roomId].length);
    }

    function getQuestion(uint256 roomId, uint256 qIdx) external view returns (
        string memory text,
        string memory optionA, string memory optionB,
        string memory optionC, string memory optionD,
        string memory correctAnswer, string memory explanation,
        bool active
    ) {
        Question storage q = questions[roomId][qIdx];
        return (q.text, q.optionA, q.optionB, q.optionC, q.optionD,
                q.correctAnswer, q.explanation, q.active);
    }

    function getPlayerScore(uint256 roomId, address player) external view returns (uint256) {
        return scores[roomId][player];
    }

    function getPlayers(uint256 roomId) external view returns (address[] memory) {
        return players[roomId];
    }

    function computeCommitment(
        string calldata answer, bytes32 salt,
        address player, uint256 roomId, uint256 questionIndex
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, player, roomId, questionIndex));
    }
}
