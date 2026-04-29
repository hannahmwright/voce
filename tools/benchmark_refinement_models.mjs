#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const OPENAI_BASE_URL = "https://api.openai.com";

function usage() {
  return `
Usage:
  node tools/benchmark_refinement_models.mjs [options]

Options:
  --history <path>       Transcript history JSON. Defaults to Voce history.
  --models <csv>         Models to test. Defaults to VOCE_REFINEMENT_BENCH_MODELS or gpt-4o-mini.
  --strategies <csv>     full,chunked. Defaults to full,chunked.
  --limit <n>            Max samples. Defaults to 20.
  --min-words <n>        Minimum raw transcript words. Defaults to 25.
  --chunk-words <n>      Target words per chunk for chunked strategy. Defaults to 140.
  --parallel <n>         Max parallel chunk requests. Defaults to 4.
  --output <path>        Optional JSON output path.
  --include-text         Include raw/reference/hypothesis text in JSON output.
  --help                 Show this help.

Environment:
  OPENAI_API_KEY or VOCE_OPENAI_API_KEY is required.
`.trim();
}

function parseArgs(argv) {
  const args = {
    history: join(homedir(), "Library/Application Support/Voce/transcript-history.json"),
    models: (process.env.VOCE_REFINEMENT_BENCH_MODELS ?? "gpt-4o-mini")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
    strategies: ["full", "chunked"],
    limit: 20,
    minWords: 25,
    chunkWords: 140,
    parallel: 4,
    output: null,
    includeText: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const next = () => {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`Missing value for ${token}`);
      }
      index += 1;
      return value;
    };

    switch (token) {
      case "--history":
        args.history = next();
        break;
      case "--models":
        args.models = next()
          .split(",")
          .map((value) => value.trim())
          .filter(Boolean);
        break;
      case "--strategies":
        args.strategies = next()
          .split(",")
          .map((value) => value.trim())
          .filter(Boolean);
        break;
      case "--limit":
        args.limit = positiveInteger(next(), token);
        break;
      case "--min-words":
        args.minWords = positiveInteger(next(), token);
        break;
      case "--chunk-words":
        args.chunkWords = positiveInteger(next(), token);
        break;
      case "--parallel":
        args.parallel = positiveInteger(next(), token);
        break;
      case "--output":
        args.output = next();
        break;
      case "--include-text":
        args.includeText = true;
        break;
      case "--help":
      case "-h":
        console.log(usage());
        process.exit(0);
      default:
        throw new Error(`Unknown option: ${token}\n\n${usage()}`);
    }
  }

  for (const strategy of args.strategies) {
    if (!["full", "chunked"].includes(strategy)) {
      throw new Error(`Unknown strategy: ${strategy}`);
    }
  }
  if (args.models.length === 0) {
    throw new Error("At least one model is required.");
  }
  return args;
}

function positiveInteger(value, name) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer.`);
  }
  return parsed;
}

function apiKey() {
  const key = process.env.VOCE_OPENAI_API_KEY ?? process.env.OPENAI_API_KEY;
  if (!key) {
    throw new Error("Set OPENAI_API_KEY or VOCE_OPENAI_API_KEY.");
  }
  return key;
}

function normalizeText(value) {
  return (value ?? "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .trim();
}

function compactForComparison(value) {
  return normalizeText(value)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s']/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function words(value) {
  const normalized = compactForComparison(value);
  return normalized ? normalized.split(/\s+/g) : [];
}

function characters(value) {
  return Array.from(compactForComparison(value).replace(/\s+/g, ""));
}

function levenshtein(lhs, rhs) {
  if (lhs.length === 0) return rhs.length;
  if (rhs.length === 0) return lhs.length;

  let previous = Array.from({ length: rhs.length + 1 }, (_, index) => index);
  let current = Array(rhs.length + 1).fill(0);

  for (let leftIndex = 0; leftIndex < lhs.length; leftIndex += 1) {
    current[0] = leftIndex + 1;
    for (let rightIndex = 0; rightIndex < rhs.length; rightIndex += 1) {
      const cost = lhs[leftIndex] === rhs[rightIndex] ? 0 : 1;
      current[rightIndex + 1] = Math.min(
        previous[rightIndex + 1] + 1,
        current[rightIndex] + 1,
        previous[rightIndex] + cost,
      );
    }
    [previous, current] = [current, previous];
  }
  return previous[rhs.length];
}

function score(reference, hypothesis) {
  const referenceWords = words(reference);
  const hypothesisWords = words(hypothesis);
  const referenceCharacters = characters(reference);
  const hypothesisCharacters = characters(hypothesis);
  const wordEdits = levenshtein(referenceWords, hypothesisWords);
  const charEdits = levenshtein(referenceCharacters, hypothesisCharacters);
  return {
    wer: referenceWords.length === 0 ? (hypothesisWords.length === 0 ? 0 : 1) : wordEdits / referenceWords.length,
    cer: referenceCharacters.length === 0
      ? (hypothesisCharacters.length === 0 ? 0 : 1)
      : charEdits / referenceCharacters.length,
    wordEdits,
    referenceWords: referenceWords.length,
    charEdits,
    referenceCharacters: referenceCharacters.length,
  };
}

function dictionaryPayload(entries) {
  const prioritized = entries.slice(0, 200).map((entry) => {
    if (entry.scope === "app" && entry.bundleIdentifier) {
      return `- [app:${entry.bundleIdentifier}] ${entry.term} -> ${entry.preferred}`;
    }
    return `- [global] ${entry.term} -> ${entry.preferred}`;
  });
  return prioritized.length > 0 ? prioritized.join("\n") : "- none";
}

function buildPrompt({ transcript, localeIdentifier, dictionary, profile, appContext }) {
  const appDescription = appContext
    ? `${appContext.appName} (${appContext.bundleIdentifier})`
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
Locale: ${localeIdentifier}
App: ${appDescription}
Style profile: tone=${profile.tone}, structure=${profile.structureMode}, filler=${profile.fillerPolicy}, command=${profile.commandPolicy}
Dictionary:
${dictionaryPayload(dictionary)}

Transcript:
${transcript}
    `.trim(),
  };
}

function buildChunkPrompt(args) {
  const prompt = buildPrompt(args);
  return {
    system: `${prompt.system}
This is one chunk of a longer transcript. Refine only this chunk. Use neighboring context only to resolve local wording; do not repeat context.`,
    user: prompt.user,
  };
}

function responseFormat() {
  return {
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
  };
}

async function refine({ model, prompt }) {
  const body = {
    model,
    messages: [
      { role: "system", content: prompt.system },
      { role: "user", content: prompt.user },
    ],
    temperature: 0.1,
    max_completion_tokens: 700,
    response_format: responseFormat(),
  };

  const startedAt = performance.now();
  const response = await fetch(`${OPENAI_BASE_URL}/v1/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey()}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const elapsedMS = Math.round(performance.now() - startedAt);
  const payload = await response.json().catch(async () => ({ raw: await response.text() }));

  if (!response.ok) {
    const message = payload?.error?.message ?? payload?.message ?? `HTTP ${response.status}`;
    throw new Error(message);
  }

  const content = payload.choices?.[0]?.message?.content ?? "";
  const parsed = JSON.parse(content);
  const text = normalizeText(parsed.text);
  if (!text) {
    throw new Error("Model returned empty text.");
  }
  return {
    text,
    elapsedMS,
    requestCharacters: JSON.stringify(body).length,
    outputCharacters: text.length,
  };
}

function chunkTranscript(transcript, targetWords) {
  const parts = normalizeText(transcript)
    .split(/(?<=[.!?])\s+|\n+/g)
    .map((part) => part.trim())
    .filter(Boolean);
  const units = parts.length > 1 ? parts : normalizeText(transcript).split(/\s+/g);
  const chunks = [];
  let current = [];
  let currentWords = 0;

  for (const unit of units) {
    const count = words(unit).length || 1;
    if (current.length > 0 && currentWords + count > targetWords) {
      chunks.push(current.join(parts.length > 1 ? " " : " "));
      current = [];
      currentWords = 0;
    }
    current.push(unit);
    currentWords += count;
  }
  if (current.length > 0) {
    chunks.push(current.join(parts.length > 1 ? " " : " "));
  }
  return chunks;
}

async function mapLimited(items, limit, worker) {
  const results = Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

async function runFull(sample, model) {
  const prompt = buildPrompt({
    transcript: sample.rawText,
    localeIdentifier: "en-US",
    dictionary: [],
    profile: defaultProfile(),
    appContext: appContextForSample(sample),
  });
  const result = await refine({ model, prompt });
  return {
    ...result,
    chunks: 1,
  };
}

async function runChunked(sample, model, args) {
  const chunks = chunkTranscript(sample.rawText, args.chunkWords);
  const chunkResults = await mapLimited(chunks, args.parallel, async (chunk, index) => {
    const previous = index > 0 ? chunks[index - 1].split(/\s+/g).slice(-20).join(" ") : "";
    const next = index + 1 < chunks.length ? chunks[index + 1].split(/\s+/g).slice(0, 20).join(" ") : "";
    const transcript = [
      previous ? `Previous context: ${previous}` : "",
      `Chunk: ${chunk}`,
      next ? `Next context: ${next}` : "",
    ].filter(Boolean).join("\n");
    const prompt = buildChunkPrompt({
      transcript,
      localeIdentifier: "en-US",
      dictionary: [],
      profile: defaultProfile(),
      appContext: appContextForSample(sample),
    });
    return await refine({ model, prompt });
  });

  return {
    text: chunkResults.map((result) => result.text).join("\n").trim(),
    elapsedMS: Math.max(...chunkResults.map((result) => result.elapsedMS)),
    summedElapsedMS: chunkResults.reduce((sum, result) => sum + result.elapsedMS, 0),
    requestCharacters: chunkResults.reduce((sum, result) => sum + result.requestCharacters, 0),
    outputCharacters: chunkResults.reduce((sum, result) => sum + result.outputCharacters, 0),
    chunks: chunks.length,
  };
}

function defaultProfile() {
  return {
    tone: "natural",
    structureMode: "paragraph",
    fillerPolicy: "balanced",
    commandPolicy: "transform",
  };
}

function appContextForSample(sample) {
  return {
    bundleIdentifier: sample.appBundleID || "unknown",
    appName: sample.appBundleID || "unknown",
  };
}

async function loadSamples(args) {
  const data = JSON.parse(await readFile(args.history, "utf8"));
  return data
    .filter((entry) => normalizeText(entry.rawText) && normalizeText(entry.cleanText))
    .filter((entry) => words(entry.rawText).length >= args.minWords)
    .slice(0, args.limit)
    .map((entry) => ({
      id: entry.id,
      createdAt: entry.createdAt,
      appBundleID: entry.appBundleID,
      rawText: normalizeText(entry.rawText),
      referenceText: normalizeText(entry.cleanText),
      rawWords: words(entry.rawText).length,
      referenceWords: words(entry.cleanText).length,
    }));
}

function summarize(results) {
  const groups = new Map();
  for (const result of results.filter((result) => result.status === "success")) {
    const key = `${result.model}:${result.strategy}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(result);
  }

  return Array.from(groups.entries()).map(([key, values]) => {
    const [model, strategy] = key.split(":");
    const latencies = values.map((value) => value.elapsedMS).sort((a, b) => a - b);
    const wers = values.map((value) => value.metrics.wer);
    const cers = values.map((value) => value.metrics.cer);
    return {
      model,
      strategy,
      samples: values.length,
      meanLatencyMS: mean(latencies),
      p50LatencyMS: percentile(latencies, 0.5),
      p90LatencyMS: percentile(latencies, 0.9),
      meanWERAgainstHistory: mean(wers),
      meanCERAgainstHistory: mean(cers),
      meanChunks: mean(values.map((value) => value.chunks)),
    };
  });
}

function mean(values) {
  if (values.length === 0) return null;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function percentile(sortedValues, percentileValue) {
  if (sortedValues.length === 0) return null;
  const index = Math.max(0, Math.min(sortedValues.length - 1, Math.ceil(sortedValues.length * percentileValue) - 1));
  return sortedValues[index];
}

function printSummary(summary) {
  console.log("\nmodel\tstrategy\tsamples\tmean_ms\tp50_ms\tp90_ms\tmean_WER\tmean_CER\tchunks");
  for (const row of summary) {
    console.log([
      row.model,
      row.strategy,
      row.samples,
      Math.round(row.meanLatencyMS ?? 0),
      row.p50LatencyMS ?? 0,
      row.p90LatencyMS ?? 0,
      (row.meanWERAgainstHistory ?? 0).toFixed(4),
      (row.meanCERAgainstHistory ?? 0).toFixed(4),
      (row.meanChunks ?? 0).toFixed(1),
    ].join("\t"));
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const samples = await loadSamples(args);
  if (samples.length === 0) {
    throw new Error("No benchmarkable samples found.");
  }

  console.log(`Loaded ${samples.length} samples from ${args.history}`);
  const results = [];
  for (const sample of samples) {
    for (const model of args.models) {
      for (const strategy of args.strategies) {
        const label = `${sample.id} ${model} ${strategy}`;
        process.stdout.write(`Running ${label}... `);
        try {
          const run = strategy === "chunked"
            ? await runChunked(sample, model, args)
            : await runFull(sample, model);
          const metrics = score(sample.referenceText, run.text);
          const result = {
            sampleID: sample.id,
            model,
            strategy,
            status: "success",
            elapsedMS: run.elapsedMS,
            summedElapsedMS: run.summedElapsedMS,
            requestCharacters: run.requestCharacters,
            outputCharacters: run.outputCharacters,
            chunks: run.chunks,
            rawWords: sample.rawWords,
            referenceWords: sample.referenceWords,
            metrics,
            ...(args.includeText ? {
              rawText: sample.rawText,
              referenceText: sample.referenceText,
              hypothesisText: run.text,
            } : {}),
          };
          results.push(result);
          console.log(`${run.elapsedMS}ms WER=${metrics.wer.toFixed(4)} CER=${metrics.cer.toFixed(4)}`);
        } catch (error) {
          results.push({
            sampleID: sample.id,
            model,
            strategy,
            status: "failed",
            errorMessage: error instanceof Error ? error.message : String(error),
          });
          console.log(`failed: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    }
  }

  const output = {
    generatedAt: new Date().toISOString(),
    config: {
      history: args.history,
      models: args.models,
      strategies: args.strategies,
      limit: args.limit,
      minWords: args.minWords,
      chunkWords: args.chunkWords,
      parallel: args.parallel,
    },
    summary: summarize(results),
    results,
  };
  printSummary(output.summary);

  if (args.output) {
    await writeFile(args.output, `${JSON.stringify(output, null, 2)}\n`);
    console.log(`\nWrote ${args.output}`);
  }
}

main().catch((error) => {
  console.error(`Error: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
