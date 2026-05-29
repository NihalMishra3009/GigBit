import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

const currentFile = fileURLToPath(import.meta.url);
const currentDir = path.dirname(currentFile);

// Always load the API-local env file even when process cwd is repository root.
dotenv.config({ path: path.resolve(currentDir, "../.env") });

const envSchema = z.object({
  PORT: z.coerce.number().default(4000),
  JWT_SECRET: z.string().min(16),
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url().optional(),
  SMTP_HOST: z.string().optional(),
  SMTP_PORT: z.coerce.number().default(587),
  SMTP_USER: z.string().optional(),
  SMTP_PASS: z.string().optional(),
  SMTP_FROM: z.string().optional(),
  SMTP_ADMIN_USER: z.string().optional(),
  SMTP_ADMIN_PASS: z.string().optional(),
  SMTP_ADMIN_FROM: z.string().optional(),
  SMTP_USER_OTP_USER: z.string().optional(),
  SMTP_USER_OTP_PASS: z.string().optional(),
  SMTP_USER_OTP_FROM: z.string().optional(),
  BREVO_API_KEY: z.string().optional(),
  OTP_IN_RESPONSE: z.coerce.boolean().default(false),
  // Optional: enables admin-only endpoints (e.g. account deletion approvals).
  ADMIN_API_KEY: z.string().optional(),
  ADMIN_USERNAME: z.string().optional(),
  ADMIN_PASSWORD: z.string().optional(),
});

export const env = envSchema.parse(process.env);
