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
  response_format?: {
    type: "json_schema";
    json_schema: {
      name: string;
      strict: boolean;
      schema: {
        type: "object";
        properties: {
          text: {
            type: "string";
          };
        };
        required: ["text"];
        additionalProperties: false;
      };
    };
  };
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

type RealtimeClientSecretResponse = {
  value?: string;
  expires_at?: number;
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

function realtimeTranscriptionModel() {
  return process.env.VOCE_OPENAI_REALTIME_TRANSCRIPTION_MODEL ?? "gpt-realtime-whisper";
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
  const startedAt = Date.now();
  const bodyJSON = JSON.stringify(body);

  try {
    const response = await fetch(`${OPENAI_BASE_URL}${path}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${openAIAPIKey()}`,
        "content-type": "application/json",
      },
      body: bodyJSON,
      signal: controller.signal,
    });
    console.info("openai json request completed", {
      path,
      model: body.model,
      status: response.status,
      requestBytes: bodyJSON.length,
      elapsedMs: Date.now() - startedAt,
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
    console.error("openai json request failed", {
      path,
      model: body.model,
      elapsedMs: Date.now() - startedAt,
      error: error instanceof Error ? error.message : String(error),
    });
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

async function openAIRealtimeTranscriptionSessionRequest(body: Record<string, unknown>) {
  const bodyJSON = JSON.stringify(body);
  const response = await fetch(`${OPENAI_BASE_URL}/v1/realtime/client_secrets`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${openAIAPIKey()}`,
      "content-type": "application/json",
    },
    body: bodyJSON,
  });

  const payload = await readJSONSafe(response);
  if (!response.ok) {
    throw new CloudDictationProviderError(
      response.status === 429 ? 429 : response.status >= 500 ? 502 : 502,
      providerFailureMessage(response.status, payload),
    );
  }

  return payload as RealtimeClientSecretResponse;
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
Refine speech-to-text dictation for insertion. Return compact JSON only: {"text":"..."}.
Preserve intent and wording unless a correction is explicitly spoken.
Resolve self-corrections: "no", "I mean", "or I meant", "actually", "no actually", "wait no", "rather", "scratch that", "sorry", and "replace X with Y".
When the speaker revises a place, person, object, action, or choice, keep only the final intended version.
Examples: "Yesterday I went to Publix or I meant Lowes to pick up groceries" -> "Yesterday I went to Lowes to pick up groceries."; "Let's do xyz no actually let's do abc" -> "Let's do abc."
Preserve dictionary spellings when present or strongly implied.
Use bullets only when the transcript clearly represents requirements, tasks, criteria, ingredients, steps, or grouped attributes. Otherwise return a paragraph.
Do not add headings, summarize away substance, or add marketing language or PM-speak.
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

export async function createRealtimeTranscriptionSession(args: {
  localeIdentifier: string;
  hints: string[];
  model?: string;
}) {
  const model = args.model?.trim() || realtimeTranscriptionModel();
  const response = await openAIRealtimeTranscriptionSessionRequest({
    expires_after: {
      anchor: "created_at",
      seconds: 600,
    },
    session: {
      type: "transcription",
      audio: {
        input: {
          format: {
            type: "audio/pcm",
            rate: 24000,
          },
          noise_reduction: {
            type: "near_field",
          },
          transcription: {
            model,
            language: effectiveLanguageCode(args.localeIdentifier),
          },
          turn_detection: null,
        },
      },
    },
  });

  const value = response.value?.trim();
  if (!value) {
    throw new CloudDictationProviderError(
      502,
      "Cloud dictation provider did not return a realtime session token.",
    );
  }

  return {
    clientSecret: value,
    expiresAt: response.expires_at,
  };
}

export async function refineWithCloudProvider(args: {
  transcript: string;
  localeIdentifier: string;
  dictionary: SerializedLexiconEntry[];
  profile: SerializedStyleProfile;
  appContext?: SerializedAppContext | null;
}) {
  const startedAt = Date.now();
  const prompt = buildRefinementPrompt(args);
  console.info("cloud refinement started", {
    model: refinementModel(),
    transcriptCharacters: args.transcript.length,
    dictionaryEntries: args.dictionary.length,
    promptCharacters: prompt.system.length + prompt.user.length,
  });
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
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "voce_refined_transcript",
          strict: true,
          schema: {
            type: "object",
            properties: {
              text: { type: "string" },
            },
            required: ["text"],
            additionalProperties: false,
          },
        },
      },
    },
    45_000,
  );

  const content = response.choices?.[0]?.message?.content ?? "";
  const text = extractJSONTextPayload(content);
  if (!text) {
    throw new CloudDictationProviderError(502, "Cloud dictation provider returned an invalid response.");
  }

  console.info("cloud refinement completed", {
    outputCharacters: text.length,
    elapsedMs: Date.now() - startedAt,
  });
  return { text };
}
