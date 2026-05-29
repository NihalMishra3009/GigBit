import { Pool } from "pg";
import { createClient } from "redis";
import { env } from "./config.js";

export const pgPool = new Pool({
  connectionString: env.DATABASE_URL
});

export const redis = env.REDIS_URL
  ? createClient({
      url: env.REDIS_URL,
      // Do not queue commands while Redis is down; fail fast so HTTP handlers don't hang.
      disableOfflineQueue: true,
      socket: {
        connectTimeout: 500
      }
    })
  : null;


