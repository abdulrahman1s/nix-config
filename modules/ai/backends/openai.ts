type ModelRequest = {
  prompt: string;
  route: "private" | "public" | "vision";
  image?: string;
};

const request = JSON.parse(await Bun.stdin.text()) as ModelRequest;
if (!request.prompt || !["private", "public", "vision"].includes(request.route)) throw new Error("Invalid model backend request.");

const baseUrl = (process.env.PERSONAL_AI_OPENAI_BASE_URL ?? "http://127.0.0.1:4100/v1").replace(/\/$/, "");
const apiKey = process.env.PERSONAL_AI_OPENAI_API_KEY ?? "local-router-no-secret";
const models = {
  private: process.env.PERSONAL_AI_PRIVATE_MODEL ?? "privacy-auto",
  public: process.env.PERSONAL_AI_PUBLIC_MODEL ?? "public-bypass",
  vision: process.env.PERSONAL_AI_VISION_MODEL ?? "vision-online",
};

let content: string | Array<Record<string, unknown>> = request.prompt;
if (request.image) {
  const image = Bun.file(request.image);
  if (!(await image.exists())) throw new Error(`Image does not exist: ${request.image}`);
  const encoded = Buffer.from(await image.arrayBuffer()).toString("base64");
  content = [
    { type: "text", text: request.prompt },
    { type: "image_url", image_url: { url: `data:${image.type || "application/octet-stream"};base64,${encoded}` } },
  ];
}

const response = await fetch(`${baseUrl}/chat/completions`, {
  method: "POST",
  headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
  body: JSON.stringify({ model: models[request.route], messages: [{ role: "user", content }], stream: false }),
});
if (!response.ok) throw new Error(`Model backend returned HTTP ${response.status}: ${(await response.text()).slice(0, 1000)}`);
const body = await response.json() as { choices?: Array<{ message?: { content?: string | Array<{ text?: string }> } }> };
const responseContent = body.choices?.[0]?.message?.content;
const text = typeof responseContent === "string" ? responseContent : responseContent?.map((part) => part.text ?? "").join("");
if (!text?.trim()) throw new Error("Model backend returned no text response.");
process.stdout.write(text.trim());
