import type { NextFunction, Response } from "express";
import jwt from "jsonwebtoken";
import { env } from "./config.js";
import type { AuthRequest } from "./types.js";

export function signToken(userId: string): string {
  return jwt.sign({ userId }, env.JWT_SECRET, { expiresIn: "7d" });
}

export function requireAuth(req: AuthRequest, res: Response, next: NextFunction): void {
  const header = req.header("authorization");
  if (!header?.startsWith("Bearer ")) {
    res.status(401).json({ message: "Missing Bearer token" });
    return;
  }

  const token = header.slice("Bearer ".length);
  try {
    const payload = jwt.verify(token, env.JWT_SECRET) as { userId: string };
    req.auth = { userId: payload.userId };
    next();
  } catch {
    res.status(401).json({ message: "Invalid token" });
  }
}
