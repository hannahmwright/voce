import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval(
  "delete expired auth sessions, codes and rate limits",
  { hours: 1 },
  internal.auth.cleanupExpiredAuthRecords,
  {},
);

export default crons;
