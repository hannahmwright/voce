type SerializedLexiconEntry = {
  term: string;
  preferred: string;
  scope: "global" | "app";
  bundleIdentifier?: string;
};

type SerializedStyleProfile = {
  tone: string;
  structureMode: string;
  fillerPolicy: string;
  commandPolicy: string;
};

type SerializedAppContext = {
  bundleIdentifier: string;
  appName: string;
  inputFieldDescription?: string | null;
  isRemoteDesktop?: boolean;
  isIDE?: boolean;
};

type ChatCompletionsRequest = {
  model: string;
  messages: Array<{
    role: "system" | "user";
    content: string;
  }>;
  temperature: number;
  max_completion_tokens: number;
};

type ChatCompletionsResponse = {
  choices?: Array<{
    message?: {
      content?: string;
    };
  }>;
};

type AudioTranscriptionResponse = {
  text?: string;
};

export class CloudDictationProviderError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "CloudDictationProviderError";
    this.status = status;
  }
}

const OPENAI_BASE_URL = "https://api.openai.com";

function openAIAPIKey() {
  const key = process.env.VOCE_OPENAI_API_KEY ?? process.env.OPENAI_API_KEY;
  if (!key) {
    throw new CloudDictationProviderError(
      503,
      "Cloud dictation is not configured on the server.",
    );
  }
  return key;
}

function transcriptionModel() {
  return process.env.VOCE_OPENAI_TRANSCRIPTION_MODEL ?? "gpt-4o-mini-transcribe";
}

function refinementModel() {
  return process.env.VOCE_OPENAI_REFINEMENT_MODEL ?? "gpt-4o-mini";
}

async function readJSONSafe(response: Response) {
  const text = await response.text();
  if (!text.trim()) {
    return null;
  }

  try {
    return JSON.parse(text) as Record<string, any>;
  } catch {
    return { raw: text };
  }
}

function providerFailureMessage(status: number, payload: Record<string, any> | null) {
  const nestedMessage =
    typeof payload?.error === "string"
      ? payload.error
      : typeof payload?.error?.message === "string"
        ? payload.error.message
        : typeof payload?.message === "string"
          ? payload.message
          : null;

  switch (status) {
    case 400:
      return nestedMessage ?? "Cloud dictation request was rejected.";
    case 401:
    case 403:
      return "Cloud dictation provider authentication failed.";
    case 408:
      return "Cloud dictation request timed out.";
    case 429:
      return "Cloud dictation is temporarily rate limited.";
    default:
      if (status >= 500) {
        return nestedMessage ?? "Cloud dictation provider is unavailable.";
      }
      return nestedMessage ?? "Cloud dictation provider returned an invalid response.";
  }
}

async function openAIJSONRequest(path: string, body: ChatCompletionsRequest, timeoutMs: number) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(`${OPENAI_BASE_URL}${path}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${openAIAPIKey()}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    const payload = await readJSONSafe(response);
    if (!response.ok) {
      throw new CloudDictationProviderError(
        response.status === 429 ? 429 : response.status >= 500 ? 502 : 502,
        providerFailureMessage(response.status, payload),
      );
    }

    return payload as ChatCompletionsResponse;
  } catch (error) {
    if (error instanceof CloudDictationProviderError) {
      throw error;
    }
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new CloudDictationProviderError(504, "Cloud dictation request timed out.");
    }
    throw new CloudDictationProviderError(502, "Cloud dictation provider is unavailable.");
  } finally {
    clearTimeout(timeout);
  }
}

async function openAIAudioTranscriptionRequest(formData: FormData, timeoutMs: number) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(`${OPENAI_BASE_URL}/v1/audio/transcriptions`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${openAIAPIKey()}`,
      },
      body: formData,
      signal: controller.signal,
    });

    const payload = await readJSONSafe(response);
    if (!response.ok) {
      throw new CloudDictationProviderError(
        response.status === 429 ? 429 : response.status >= 500 ? 502 : 502,
        providerFailureMessage(response.status, payload),
      );
    }

    return payload as AudioTranscriptionResponse;
  } catch (error) {
    if (error instanceof CloudDictationProviderError) {
      throw error;
    }
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new CloudDictationProviderError(504, "Cloud dictation request timed out.");
    }
    throw new CloudDictationProviderError(502, "Cloud dictation provider is unavailable.");
  } finally {
    clearTimeout(timeout);
  }
}

function normalizedText(value: string | undefined | null) {
  return (value ?? "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .trim();
}

function transcriptionPrompt(hints: string[]) {
  const prioritizedHints = hints
    .map((hint) => hint.trim())
    .filter(Boolean)
    .slice(0, 40);

  if (prioritizedHints.length === 0) {
    return "";
  }

  return `Prefer these spellings when they are clearly intended:\n${prioritizedHints.join("\n")}`;
}

function dictionaryPayload(entries: SerializedLexiconEntry[]) {
  const prioritized = entries.slice(0, 200).map((entry) => {
    if (entry.scope === "app" && entry.bundleIdentifier) {
      return `- [app:${entry.bundleIdentifier}] ${entry.term} -> ${entry.preferred}`;
    }
    return `- [global] ${entry.term} -> ${entry.preferred}`;
  });

  return prioritized.length > 0 ? prioritized.join("\n") : "- none";
}

function buildRefinementPrompt(args: {
  transcript: string;
  localeIdentifier: string;
  dictionary: SerializedLexiconEntry[];
  profile: SerializedStyleProfile;
  appContext?: SerializedAppContext | null;
}) {
  const appDescription = args.appContext
    ? `${args.appContext.appName} (${args.appContext.bundleIdentifier})`
    : "unknown";

  return {
    system: `
You refine speech-to-text transcripts for dictation.
Return compact JSON only: {"text":"..."}.
Preserve intent and wording unless a correction is explicitly spoken.
Resolve spoken self-corrections like "no", "I mean", "or I meant", "actually", "no actually", "wait no", "rather", "scratch that", "sorry", or "replace X with Y".
When the speaker revises a place, person, object, action, or choice mid-sentence, keep only the final intended version and remove the superseded alternative.
For example, "Yesterday I went to Publix or I meant Lowes to pick up groceries" should become "Yesterday I went to Lowes to pick up groceries."
Likewise, "Let's do xyz no actually let's do abc" should become "Let's do abc."
Preserve dictionary spellings exactly when they are present or strongly implied.
Infer bullet lists when the transcript clearly represents multiple requirements, tasks, acceptance criteria, ingredients, steps, or grouped attributes.
Use bullet lists only when structure is clearly beneficial. Otherwise return a paragraph.
Do not add headings.
Do not summarize away substance.
Do not add marketing language or PM-speak.
Keep punctuation clean and natural.
    `.trim(),
    user: `
Locale: ${args.localeIdentifier}
App: ${appDescription}
Style profile: tone=${args.profile.tone}, structure=${args.profile.structureMode}, filler=${args.profile.fillerPolicy}, command=${args.profile.commandPolicy}
Dictionary:
${dictionaryPayload(args.dictionary)}

Transcript:
${args.transcript}
    `.trim(),
  };
}

function extractJSONTextPayload(content: string) {
  const trimmed = content.trim();
  const first = trimmed.indexOf("{");
  const last = trimmed.lastIndexOf("}");
  if (first < 0 || last < 0 || last <= first) {
    return "";
  }

  try {
    const payload = JSON.parse(trimmed.slice(first, last + 1)) as { text?: string };
    return normalizedText(payload.text);
  } catch {
    return "";
  }
}

function effectiveLanguageCode(localeIdentifier: string) {
  const [languageCode] = localeIdentifier.split(/[-_]/, 1);
  return languageCode || "en";
}

export async function runCloudDictationPreflight(localeIdentifier: string) {
  const response = await openAIJSONRequest(
    "/v1/chat/completions",
    {
      model: refinementModel(),
      messages: [
        {
          role: "system",
          content: "You are a connectivity check. Reply with READY.",
        },
        {
          role: "user",
          content: `Locale: ${localeIdentifier}`,
        },
      ],
      temperature: 0,
      max_completion_tokens: 12,
    },
    15_000,
  );

  const content = normalizedText(response.choices?.[0]?.message?.content);
  if (!content) {
    throw new CloudDictationProviderError(502, "Cloud dictation provider returned an invalid response.");
  }
}

export async function transcribeWithCloudProvider(args: {
  localeIdentifier: string;
  hints: string[];
  audioBlob: Blob;
  filename: string;
}) {
  if (args.audioBlob.size <= 0) {
    throw new CloudDictationProviderError(400, "Cloud dictation received an empty audio file.");
  }

  const formData = new FormData();
  formData.set("model", transcriptionModel());
  formData.set("language", effectiveLanguageCode(args.localeIdentifier));
  formData.set("response_format", "json");

  const prompt = transcriptionPrompt(args.hints);
  if (prompt) {
    formData.set("prompt", prompt);
  }

  const mimeType = args.audioBlob.type || "audio/wav";
  const file = new Blob([args.audioBlob], { type: mimeType });
  formData.set("file", file, args.filename);

  const response = await openAIAudioTranscriptionRequest(formData, 90_000);
  const text = normalizedText(response.text);
  if (!text) {
    throw new CloudDictationProviderError(502, "Cloud dictation did not capture any speech.");
  }

  return { text };
}

export async function refineWithCloudProvider(args: {
  transcript: string;
  localeIdentifier: string;
  dictionary: SerializedLexiconEntry[];
  profile: SerializedStyleProfile;
  appContext?: SerializedAppContext | null;
}) {
  const prompt = buildRefinementPrompt(args);
  const response = await openAIJSONRequest(
    "/v1/chat/completions",
    {
      model: refinementModel(),
      messages: [
        { role: "system", content: prompt.system },
        { role: "user", content: prompt.user },
      ],
      temperature: 0.1,
      max_completion_tokens: 700,
    },
    45_000,
  );

  const content = response.choices?.[0]?.message?.content ?? "";
  const text = extractJSONTextPayload(content);
  if (!text) {
    throw new CloudDictationProviderError(502, "Cloud dictation provider returned an invalid response.");
  }

  return { text };
}
