import type { Request } from "express";

export interface AuthPayload {
  userId: string;
}

export interface AuthRequest extends Request {
  auth?: AuthPayload;
}
