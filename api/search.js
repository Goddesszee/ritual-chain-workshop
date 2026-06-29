export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.status(200).end();

  const OPENAI_KEY = process.env.OPENAI_API_KEY;
  if (!OPENAI_KEY) return res.status(500).json({ error: "Key not configured" });

  const { topic, count, usedQuestions } = req.body || {};

  // Step 1: Fetch real-time Ritual docs from public sources
  let ritualContext = "";
  const sources = [
    "https://docs.ritual.net",
    "https://ritual.net",
  ];

  // Fetch Ritual docs
  for (const url of sources) {
    try {
      const r = await fetch(url, {
        headers: { "User-Agent": "Mozilla/5.0" },
        signal: AbortSignal.timeout(3000)
      });
      if (r.ok) {
        const text = await r.text();
        // Extract readable text
        const clean = text.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 3000);
        ritualContext += `\nFrom ${url}:\n${clean}\n`;
      }
    } catch(e) {
      // Skip failed sources
    }
  }

  // Step 2: Generate questions using GPT-4o with real context + no repeats
  const usedList = (usedQuestions || []).join(" | ");

  const systemPrompt = `You are an expert blockchain quiz creator specializing in Ritual Chain.
You have access to the latest Ritual Chain documentation and community knowledge.

RITUAL CHAIN KEY FACTS (always accurate):
- Ritual Chain is an EVM-compatible blockchain with NATIVE AI precompiles
- LLM inference precompile address: 0x0802
- HTTP call precompile: 0x0801
- DKMS precompile: 0x081B  
- Sovereign Agent precompile: 0x080C
- block.timestamp is in MILLISECONDS (not seconds) on Ritual Chain
- Chain ID: 1979
- Native token: CRAT
- RPC: https://rpc.ritualfoundation.org
- Async delivery contract: 0x5A16214fF555848411544b005f7Ac063742f39F6
- Ritual uses TEE (Trusted Execution Environment) for private AI computation
- RitualWallet contract handles compute payment for AI precompiles
- Supports batch LLM judging in a single on-chain transaction
- PrecompileConsumer base contract for interacting with precompiles
- Ritual Academy trains developers to build AI-native dApps
- Genesis NFT program for early community members
- Infernet SDK for off-chain compute nodes
- Ritual supports: image generation, audio, video, ZK proofs, FHE on-chain
${ritualContext ? "\nLIVE DOCS:\n" + ritualContext : ""}`;

  const userPrompt = `Generate exactly ${count || 10} UNIQUE multiple choice quiz questions about Ritual Chain.

${usedList ? `DO NOT repeat these questions (already used):\n${usedList}\n` : ""}

Requirements:
- Each question tests specific Ritual Chain knowledge
- 4 options (A, B, C, D) — one correct
- Wrong options must be plausible (e.g. wrong addresses, wrong chain IDs)
- Mix: technical (precompile addresses, timestamps), conceptual (what is TEE), practical (how to use)
- 3 easy, 4 medium, 3 hard

Return ONLY this JSON (no markdown):
{"questions":[{"q":"question","options":["A. opt1","B. opt2","C. opt3","D. opt4"],"correct":"A","explanation":"why","difficulty":"easy|medium|hard"}]}`;

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${OPENAI_KEY}` },
      body: JSON.stringify({
        model: "gpt-4o",
        max_tokens: 4000,
        temperature: 0.8,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt }
        ]
      })
    });

    const data = await response.json();
    if (data.error) return res.status(500).json({ error: data.error.message });

    const text = data.choices[0].message.content.trim().replace(/^```json\n?|\n?```$/g, '');
    const result = JSON.parse(text);
    return res.status(200).json(result);
  } catch(e) {
    return res.status(500).json({ error: e.message });
  }
}
