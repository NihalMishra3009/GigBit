import { z } from "zod";

export const registerSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8),
  fullName: z.string().min(2)
});

export const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8)
});

export const transactionSchema = z.object({
  platform: z.string().min(2),
  amount: z.coerce.number().positive(),
  note: z.string().max(200).optional()
});

export const withdrawalSchema = z.object({
  amount: z.coerce.number().positive()
});

export const claimSchema = z.object({
  claimType: z.enum(["accident", "hospital"]),
  description: z.string().min(8).max(500)
});

export const connectPlatformSchema = z.object({
  platform: z.string().min(2).max(40)
});

export const syncPlatformSchema = z.object({
  platform: z.string().min(2).max(40),
  amount: z.coerce.number().positive()
});

export const taxSchema = z.object({
  question: z.string().min(5).max(400)
});

export const loanApplySchema = z.object({
  amount: z.coerce.number().positive(),
  proofUrl: z.string().url().optional()
});

export const resetRequestSchema = z.object({
  email: z.string().email()
});

export const resetVerifySchema = z.object({
  email: z.string().email(),
  otp: z.string().length(6),
  newPassword: z.string().min(8)
});
