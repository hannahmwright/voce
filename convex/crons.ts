import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval(
  "delete expired auth sessions, codes, rate limits and old usage report IDs",
  { hours: 1 },
  internal.auth.cleanupExpiredAuthRecords,
  {},
);

export default crons;
