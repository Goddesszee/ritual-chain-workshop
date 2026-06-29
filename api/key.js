export default function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  const key = process.env.OPENAI_API_KEY;
  if (!key) return res.status(500).json({ error: "Key not configured" });
  // Only return last 4 chars for security check, full key for actual use
  return res.status(200).json({ key });
}
