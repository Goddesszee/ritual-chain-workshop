export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.status(200).end();

  const OPENAI_KEY = process.env.OPENAI_API_KEY;
  if (!OPENAI_KEY) return res.status(500).json({ error: "Key not configured" });

  const { count = 10, usedQuestions = [], topic = "ritual" } = req.body || {};

  // Comprehensive Ritual Chain knowledge base (always current)
  const RITUAL_KNOWLEDGE = `
RITUAL CHAIN — COMPLETE KNOWLEDGE BASE
========================================

## CORE ARCHITECTURE
- Ritual Chain is an EVM-compatible Layer 1 blockchain with NATIVE AI precompiles
- Enables AI inference, image generation, ZK proofs, FHE directly on-chain
- TEE (Trusted Execution Environment) ensures private, verifiable AI computation
- Chain ID: 1979 | RPC: https://rpc.ritualfoundation.org
- Native token: CRAT | Explorer: https://explorer.ritual.net
- block.timestamp is in MILLISECONDS not seconds (critical difference from Ethereum)

## PRECOMPILE ADDRESSES
- LLM Inference precompile: 0x0802
- HTTP Call precompile: 0x0801
- DKMS (key management): 0x081B
- Sovereign Agent precompile: 0x080C
- Async delivery contract: 0x5A16214fF555848411544b005f7Ac063742f39F6
- Call back contract must implement: receiveCompute(bytes32, bytes memory)

## SMART CONTRACT DEVELOPMENT
- PrecompileConsumer: base contract for AI precompile interactions
- RitualWallet: holds CRAT to pay for AI compute (must be funded before use)
- Function call: callLLM(address executor, bytes memory input, uint256 gasLimit)
- Responses are asynchronous — contract receives callback after inference
- viaIR optimizer required for complex contracts (stack too deep otherwise)
- Uses ABI encoding for LLM request/response format

## INFERNET SDK
- Off-chain node infrastructure for compute requests
- Nodes subscribe to on-chain requests and deliver results
- Supports Docker containers for custom compute
- ritual_sdk python package for node operators
- Infernet Router manages node selection and load balancing

## PRIVACY & SECURITY
- TEE attestation proves computation was done correctly without revealing inputs
- Commit-reveal scheme: hash(answer + salt + sender) stored first, reveal later
- keccak256 for commitments: abi.encodePacked(answer, salt, msg.sender, id)
- Zero-knowledge proofs for verifiable private computation
- FHE (Fully Homomorphic Encryption) for computation on encrypted data

## SUPPORTED AI MODELS & TASKS
- LLM inference: text generation, classification, summarization
- Image generation: Stable Diffusion on-chain
- Audio/video processing
- Mathematical proofs via ZK circuits
- Custom ML model deployment via Infernet nodes
- Batch inference: multiple inputs in single transaction

## ECOSYSTEM & COMMUNITY
- Ritual Academy: developer education program
- Genesis NFT: early adopter program, NFT #279 etc
- DoraHacks hackathons: Agentic Economy Infrastructure track
- Discord: official community hub
- X/Twitter: @ritualnet
- GitHub: github.com/ritual-net
- Ritual Foundation governs the protocol
- CRAT token used for gas and compute payment

## USE CASES BUILT ON RITUAL
- AI bounty judge: commit-reveal + LLM scoring
- On-chain gaming with AI NPCs
- Decentralized AI marketplaces
- Privacy-preserving AI oracles  
- Autonomous AI agents on-chain
- On-chain quiz platforms with AI judging
- DeFi protocols with AI risk assessment
- NFT generation with on-chain AI

## TECHNICAL GOTCHAS
- block.timestamp in ms: use block.timestamp + 60000 for 1 minute (not +60)
- Stack too deep: use structs for return values, enable viaIR
- LLM precompile requires funded RitualWallet or transaction reverts
- Async responses: store requestId, match in callback
- Gas estimation may be wrong for precompile calls — set explicit gas limit

## COMPARISON WITH OTHER CHAINS
- Unlike Ethereum: has native AI precompiles, no need for oracle calls
- Unlike Chainlink Functions: AI runs inside TEE, not external servers  
- Unlike Fetch.ai: computation is on-chain verifiable
- Ritual = EVM + AI natively, not bolted on
`;

  const usedList = usedQuestions.length > 0
    ? `\nNEVER use these questions (already asked):\n${usedQuestions.map((q,i) => `${i+1}. ${q}`).join('\n')}\n`
    : '';

  const prompt = `Using the Ritual Chain knowledge base provided, generate exactly ${count} multiple choice quiz questions.
${usedList}
Rules:
- NEVER repeat a question that has been used before
- Each question MUST be about something specific in the knowledge base
- 4 options: A, B, C, D — exactly ONE correct
- Wrong options must be realistic (wrong addresses, wrong chain IDs, wrong values)
- Cover different topics: precompiles, timestamps, architecture, use cases, gotchas
- Difficulty mix: ${Math.floor(count*0.3)} easy, ${Math.floor(count*0.4)} medium, ${count - Math.floor(count*0.3) - Math.floor(count*0.4)} hard

Return ONLY this JSON (no markdown, no explanation):
{"questions":[{"q":"full question text?","options":["A. option1","B. option2","C. option3","D. option4"],"correct":"A","explanation":"why A is correct","difficulty":"easy"}]}`;

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${OPENAI_KEY}`
      },
      body: JSON.stringify({
        model: "gpt-4o",
        max_tokens: 4000,
        temperature: 0.9,
        messages: [
          { role: "system", content: `You are a Ritual Chain expert quiz creator. Here is the complete Ritual Chain knowledge base:\n\n${RITUAL_KNOWLEDGE}\n\nGenerate quiz questions ONLY from this knowledge. Be specific and accurate.` },
          { role: "user", content: prompt }
        ]
      })
    });

    const data = await response.json();
    if (data.error) return res.status(500).json({ error: data.error.message });

    const text = data.choices[0].message.content.trim().replace(/^```json\n?|\n?```$/g, '').trim();
    const result = JSON.parse(text);

    // Deduplicate against used questions
    const filtered = result.questions.filter(q =>
      !usedQuestions.some(used => used.toLowerCase().trim() === q.q.toLowerCase().trim())
    );

    return res.status(200).json({ questions: filtered, total: filtered.length });
  } catch(e) {
    return res.status(500).json({ error: e.message });
  }
}
