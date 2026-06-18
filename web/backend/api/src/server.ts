import bcrypt from "bcryptjs";
import compression from "compression";
import cors from "cors";
import express, { type Response } from "express";
import jwt from "jsonwebtoken";
import { randomUUID } from "node:crypto";
import { env } from "./config.js";
import { pgPool, redis } from "./db.js";
import { signToken } from "./auth.js";
import { sendOtpEmail } from "./mailer.js";
import type { AuthRequest } from "./types.js";

type UserRow = { id: string; email: string; username: string | null; name: string; password_hash: string };

const app = express();
app.use(
  compression({
    threshold: 1024,
    filter: (req, res) => {
      const accept = String(req.headers.accept ?? "").toLowerCase();
      if (accept.includes("text/event-stream") || req.path.endsWith("/stream")) {
        return false;
      }
      return compression.filter(req, res);
    },
  }),
);
const registerVerifiedMemory = new Map<string, number>();
const ADMIN_LOGIN_EMAIL = "gigbitaccess@gmail.com";
const platformCatalogStreamClients = new Set<Response>();
const userApprovalStreamClients = new Map<string, Set<Response>>();

// Controls subscription caps and monthly purchase limits.
// If you add/remove platforms in the app, update this list accordingly.
const AVAILABLE_PLATFORMS = ["zomato", "blinkit", "rapido", "ola"] as const;
const MAX_PLATFORMS = AVAILABLE_PLATFORMS.length;

async function getCatalogPlatformCapacity(): Promise<number> {
  const r = await pgPool.query(
    "SELECT COUNT(*)::int AS c FROM integration_platform_catalog",
  );
  const count = Number(r.rows[0]?.c ?? 0);
  return count > 0 ? count : MAX_PLATFORMS;
}

function publishPlatformCatalogChanged(): void {
  const payload = JSON.stringify({ version: Date.now() });
  for (const client of platformCatalogStreamClients) {
    client.write(`event: platform_catalog\n`);
    client.write(`data: ${payload}\n\n`);
  }
}

function publishUserApprovalUpdate(
  userId: string,
  eventType: "loan_status" | "insurance_status" | "account_deletion_status",
  payload: Record<string, unknown>,
): void {
  const key = String(userId || "").trim();
  if (!key) return;
  const clients = userApprovalStreamClients.get(key);
  if (!clients || !clients.size) return;
  const data = JSON.stringify({
    type: eventType,
    userId: key,
    updatedAt: new Date().toISOString(),
    ...payload,
  });
  for (const client of clients) {
    client.write(`event: approval_update\n`);
    client.write(`data: ${data}\n\n`);
  }
}

const TAX_ASSISTANT_ALLOWED_TERMS = [
  "tax",
  "itr",
  "income tax",
  "return",
  "filing",
  "tds",
  "gst",
  "deduction",
  "80c",
  "80d",
  "44ad",
  "44ada",
  "advance tax",
  "self assessment tax",
  "form 16",
  "form 26as",
  "ais",
  "gigbit",
  "gig",
  "platform",
  "earning",
  "expense",
  "fuel",
  "rent",
  "withdraw",
  "insurance",
  "subscription",
  "zomato",
  "blinkit",
  "rapido",
  "ola",
  // Hindi/Marathi keywords (Devanagari) for in-scope tax queries
  "टैक्स",
  "कर",
  "आयकर",
  "इनकम टैक्स",
  "आईटीआर",
  "रिटर्न",
  "फाइल",
  "फाइलिंग",
  "टीडीएस",
  "जीएसटी",
  "कटौती",
  "खर्च",
  "कमाई",
  "किराया",
  "ईंधन",
  "विमा",
  "बीमा",
  "सदस्यता",
  "तक्रार",
  "टॅक्स",
  "आयकर",
  "आय टी आर",
  "रिटर्न",
  "फायलिंग",
  "कपात",
  "उत्पन्न",
  "भाडे",
  "इंधन",
  "विमा",
] as const;

const TAX_CHAT_TITLE_STOP_WORDS = new Set([
  "a", "an", "the", "is", "are", "am", "was", "were", "be", "been", "being",
  "i", "me", "my", "mine", "we", "our", "you", "your", "he", "she", "it", "they",
  "to", "for", "of", "on", "in", "at", "by", "with", "from", "and", "or", "but",
  "how", "what", "when", "where", "why", "can", "could", "should", "would", "do",
  "does", "did", "please", "help", "about", "tell",
]);

function deriveTaxChatTitle(input: string): string {
  const cleaned = String(input ?? "")
    .trim()
    .replace(/\s+/g, " ");
  if (!cleaned) return "New Chat";

  const words = cleaned
    .split(" ")
    .map((w) => w.replace(/[^a-zA-Z0-9\u0900-\u097F-]/g, ""))
    .filter(Boolean);
  if (!words.length) return "New Chat";

  const important = words.filter((w) => {
    const lw = w.toLowerCase();
    return lw.length > 2 && !TAX_CHAT_TITLE_STOP_WORDS.has(lw);
  });

  const picked = (important.length ? important : words).slice(0, 5).join(" ").trim();
  return (picked || cleaned.split(" ").slice(0, 5).join(" ").trim() || "New Chat").slice(0, 80);
}

type TaxLang = "en" | "hi" | "mr";

function taxLangFrom(value: unknown): TaxLang {
  const v = String(value ?? "").trim().toLowerCase();
  if (v === "hi") return "hi";
  if (v === "mr") return "mr";
  return "en";
}

function taxT(lang: TaxLang, en: string, hi: string, mr: string): string {
  if (lang === "hi") return hi;
  if (lang === "mr") return mr;
  return en;
}

function parseCorsOrigins(value?: string): string[] {
  return String(value ?? "")
    .split(",")
    .map((origin) => origin.trim().replace(/\/+$/, ""))
    .filter(Boolean);
}

const defaultCorsOrigins = [
  "http://127.0.0.1:3000",
  "http://localhost:3000",
  "http://127.0.0.1:4173",
  "http://localhost:4173",
  "http://127.0.0.1:8080",
  "http://localhost:8080",
  "capacitor://localhost",
  "ionic://localhost",
];

const allowedCorsOrigins = new Set([
  ...defaultCorsOrigins,
  ...parseCorsOrigins(env.CORS_ORIGINS),
]);

function isAllowedCorsOrigin(origin: string): boolean {
  const normalized = String(origin ?? "").trim().replace(/\/+$/, "");
  if (!normalized) return false;
  if (allowedCorsOrigins.has(normalized)) return true;
  try {
    const parsed = new URL(normalized);
    return parsed.hostname.endsWith(".railway.app") || parsed.hostname.endsWith(".pages.dev");
  } catch {
    return false;
  }
}

function planIncrement(plan: string): number {
  const p = plan.trim().toLowerCase();
  if (p === "solo") return 1;
  if (p === "duo") return 2;
  if (p === "trio") return 3;
  // Legacy support for previously purchased plans.
  if (p === "unity") return 6;
  return 0;
}

function planAmount(plan: string): number {
  const p = plan.trim().toLowerCase();
  if (p === "solo") return 25;
  if (p === "duo") return 50;
  if (p === "trio") return 75;
  // Legacy support for previously purchased plans.
  if (p === "unity") return 229;
  return 0;
}

// Monthly purchase cap (per plan) based on platform count.
// SOLO: n times/month, DUO: floor(n/2), TRIO: floor(n/3).
function monthlyPurchaseCap(plan: string, maxPlatforms: number): number {
  const p = plan.trim().toLowerCase();
  if (p === "solo") return maxPlatforms;
  if (p === "duo") return Math.floor(maxPlatforms / 2);
  if (p === "trio") return Math.floor(maxPlatforms / 3);
  // Legacy support for previously purchased plans.
  if (p === "unity") return Math.floor(maxPlatforms / 6);
  return 0;
}

type ActivePlanWindow = {
  id: string;
  plan: string;
  startsAt: string;
  expiresAt: string;
  slots: number;
};

type SubscriptionRuntimeState = {
  activePlan: string | null;
  status: "active" | "inactive";
  limit: number;
  used: number;
  remaining: number;
  activePlanExpiresAt: string | null;
  activePlanWindows: ActivePlanWindow[];
  historyPlatforms: string[];
  recentlyExpiredPlanWindows: Array<{ id: string; plan: string; startsAt: string; expiresAt: string }>;
};

async function _loadPlanWindows(userId: string): Promise<{
  active: ActivePlanWindow[];
  recentExpired: Array<{ id: string; plan: string; startsAt: string; expiresAt: string }>;
}> {
  const r = await pgPool.query(
    `SELECT id, plan, created_at, (created_at + INTERVAL '30 days') AS expires_at
     FROM subscription_purchases
     WHERE user_id = $1
     ORDER BY created_at ASC`,
    [userId]
  );
  const now = Date.now();
  const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
  const active: ActivePlanWindow[] = [];
  const recentExpired: Array<{ id: string; plan: string; startsAt: string; expiresAt: string }> = [];

  for (const row of r.rows as any[]) {
    const startsAt = new Date(row.created_at).toISOString();
    const expiresAt = new Date(row.expires_at).toISOString();
    const expMs = new Date(expiresAt).getTime();
    const plan = String(row.plan ?? "").trim().toLowerCase();
    const slots = planIncrement(plan);
    if (!slots) continue;

    if (expMs > now) {
      active.push({
        id: String(row.id),
        plan,
        startsAt,
        expiresAt,
        slots,
      });
    } else if (now - expMs <= sevenDaysMs) {
      recentExpired.push({
        id: String(row.id),
        plan,
        startsAt,
        expiresAt,
      });
    }
  }

  return { active, recentExpired };
}

async function refreshSubscriptionRuntimeState(userId: string): Promise<SubscriptionRuntimeState> {
  const windows = await _loadPlanWindows(userId);
  const maxPlatforms = await getCatalogPlatformCapacity();

  await pgPool.query(
    `UPDATE platform_subscription_bindings b
       SET unbound_at = NOW()
      FROM subscription_purchases sp
     WHERE b.user_id = $1
       AND b.unbound_at IS NULL
       AND b.purchase_id = sp.id
       AND (
         b.expires_at <= NOW() OR
         (sp.created_at + INTERVAL '30 days') <= NOW()
       )`,
    [userId]
  );

  await pgPool.query(
    `DELETE FROM platform_connections pc
      WHERE pc.user_id = $1
        AND NOT EXISTS (
          SELECT 1
          FROM platform_subscription_bindings b
          JOIN subscription_purchases sp ON sp.id = b.purchase_id
          WHERE b.user_id = pc.user_id
            AND lower(b.platform) = lower(pc.platform)
            AND b.unbound_at IS NULL
            AND b.expires_at > NOW()
            AND (sp.created_at + INTERVAL '30 days') > NOW()
        )`,
    [userId]
  );

  const usedR = await pgPool.query(
    `SELECT COUNT(DISTINCT lower(platform))::int AS c
     FROM platform_subscription_bindings b
     JOIN subscription_purchases sp ON sp.id = b.purchase_id
     WHERE b.user_id = $1
       AND b.unbound_at IS NULL
       AND b.expires_at > NOW()
       AND (sp.created_at + INTERVAL '30 days') > NOW()`,
    [userId]
  );
  const used = Number(usedR.rows[0]?.c ?? 0);

  const historyR = await pgPool.query(
    `SELECT DISTINCT ON (lower(platform)) platform
     FROM platform_subscription_bindings b
     JOIN subscription_purchases sp ON sp.id = b.purchase_id
     WHERE b.user_id = $1
       AND b.unbound_at IS NULL
       AND b.expires_at > NOW()
       AND (sp.created_at + INTERVAL '30 days') > NOW()
     ORDER BY lower(platform), b.bound_at ASC`,
    [userId]
  );
  const historyPlatforms = historyR.rows.map((r: any) => String(r.platform));

  const limit = Math.min(
    maxPlatforms,
    windows.active.reduce((a, w) => a + w.slots, 0),
  );

  const activePlan = windows.active.length
    ? windows.active[windows.active.length - 1].plan
    : null;
  const activePlanExpiresAt = windows.active.length
    ? windows.active
        .map((w) => new Date(w.expiresAt).getTime())
        .reduce((a, b) => (a > b ? a : b), 0)
    : null;

  const status: "active" | "inactive" = limit > 0 ? "active" : "inactive";

  await pgPool.query(
    `INSERT INTO subscriptions (user_id, active_plan, status, plan_limit, used, active_plan_expires_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,NOW())
     ON CONFLICT (user_id) DO UPDATE
     SET active_plan = EXCLUDED.active_plan,
         status = EXCLUDED.status,
         plan_limit = EXCLUDED.plan_limit,
         used = EXCLUDED.used,
         active_plan_expires_at = EXCLUDED.active_plan_expires_at,
         updated_at = NOW()`,
    [
      userId,
      activePlan,
      status,
      limit,
      used,
      activePlanExpiresAt == null ? null : new Date(activePlanExpiresAt).toISOString(),
    ]
  );

  return {
    activePlan,
    status,
    limit,
    used,
    remaining: Math.max(0, limit - used),
    activePlanExpiresAt: activePlanExpiresAt == null ? null : new Date(activePlanExpiresAt).toISOString(),
    activePlanWindows: windows.active,
    historyPlatforms,
    recentlyExpiredPlanWindows: windows.recentExpired,
  };
}
app.use(
  cors({
    origin(origin, callback) {
      if (!origin) {
        callback(null, true);
        return;
      }
      if (isAllowedCorsOrigin(origin)) {
        callback(null, true);
        return;
      }
      callback(new Error(`CORS blocked for origin ${origin}`), false);
    },
    credentials: true,
  }),
);
app.use(express.json({ limit: "80mb" }));
app.use((req, _res, next) => {
  const header = req.header("authorization");
  if (header?.startsWith("Bearer ")) {
    try {
      const payload = jwt.verify(header.slice(7), env.JWT_SECRET) as { userId: string };
      (req as AuthRequest).auth = { userId: payload.userId };
    } catch {
      // ignore invalid tokens for legacy routes
    }
  }
  next();
});


function requireAdminKey(req: express.Request, res: express.Response, next: express.NextFunction): void {
  if (!isAdminAuthorized(req)) {
    res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
    return;
  }
  next();
}

function isAdminAuthorized(req: express.Request): boolean {
  const key = env.ADMIN_API_KEY;
  const headerKey = String(req.header("x-admin-key") ?? "").trim();
  if (key && headerKey && headerKey === key) return true;

  const auth = String(req.header("authorization") ?? "");
  if (!auth.startsWith("Bearer ")) return false;
  const token = auth.slice(7).trim();
  if (!token) return false;
  try {
    const payload = jwt.verify(token, env.JWT_SECRET) as { admin?: boolean; role?: string };
    return payload?.admin === true || String(payload?.role ?? "").toLowerCase() === "admin";
  } catch {
    return false;
  }
}

function getAdminTokenPayload(req: express.Request): { adminId?: string; email?: string; username?: string } | null {
  const auth = String(req.header("authorization") ?? "");
  if (!auth.startsWith("Bearer ")) return null;
  const token = auth.slice(7).trim();
  if (!token) return null;
  try {
    const payload = jwt.verify(token, env.JWT_SECRET) as {
      admin?: boolean;
      role?: string;
      adminId?: string;
      email?: string;
      username?: string;
    };
    if (!(payload?.admin === true || String(payload?.role ?? "").toLowerCase() === "admin")) return null;
    return { adminId: payload.adminId, email: payload.email, username: payload.username };
  } catch {
    return null;
  }
}

function adminActorFrom(req: express.Request, fallback = "admin"): string {
  const payload = getAdminTokenPayload(req);
  const fromToken = String(payload?.username ?? "").trim();
  if (fromToken) return fromToken;
  const fromBody = String(req.body?.username ?? "").trim();
  if (fromBody) return fromBody;
  return fallback;
}

async function logAdminActivity(
  req: express.Request,
  action: string,
  details: Record<string, unknown> = {},
  actorOverride?: string,
): Promise<void> {
  const actor = String(actorOverride || adminActorFrom(req, "admin")).trim() || "admin";
  try {
    await pgPool.query(
      "INSERT INTO admin_activity_logs (actor_username, action, details, created_at) VALUES ($1,$2,$3::jsonb,NOW())",
      [actor, String(action || "unknown"), JSON.stringify(details || {})]
    );
  } catch (error) {
    console.error("Failed to write admin activity log", error);
  }
}

function slugifyPlatformName(name: string): string {
  return name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function prettyPlatformName(slug: string): string {
  return slug
    .split("-")
    .filter(Boolean)
    .map((x) => x.charAt(0).toUpperCase() + x.slice(1))
    .join(" ");
}

type MicroInsuranceType = "vehicle_damage" | "product_damage_loss";

function normalizeMicroInsuranceType(input: string): MicroInsuranceType | null {
  const v = String(input || "").trim().toLowerCase();
  if (!v) return null;
  if (v === "vehicle_damage" || v === "vehicle damage" || v === "vehicle-damage") {
    return "vehicle_damage";
  }
  if (
    v === "product_damage_loss" ||
    v === "product damage/loss" ||
    v === "product damage loss" ||
    v === "product-damage-loss"
  ) {
    return "product_damage_loss";
  }
  return null;
}

function microInsuranceRules(type: MicroInsuranceType): { amount: number; annualCap: number } {
  if (type === "vehicle_damage") return { amount: 8000, annualCap: 2 };
  return { amount: 3000, annualCap: 3 };
}

const LOAN_MIN_AMOUNT = 5000;
const LOAN_MAX_AMOUNT = 50000;

function loanTenureMonths(amount: number): number {
  if (amount <= 10000) return 6;
  if (amount <= 25000) return 12;
  if (amount <= 40000) return 18;
  return 24;
}

function annualLoanRatePercentByConditions(conditionsMet: number): number {
  if (conditionsMet >= 3) return 7;
  if (conditionsMet === 2) return 10;
  if (conditionsMet === 1) return 12;
  return 13;
}

function calculateReducingLoanPlan(amount: number, annualRateDecimal: number): {
  tenureMonths: number;
  monthlyInstallment: number;
  totalPayable: number;
  totalInterest: number;
  annualInterestRate: number;
} {
  const principal = Number(amount);
  const months = loanTenureMonths(principal);
  const monthlyRate = annualRateDecimal / 12;
  const pow = Math.pow(1 + monthlyRate, months);
  const emi = monthlyRate === 0
    ? principal / months
    : (principal * monthlyRate * pow) / (pow - 1);
  const totalPayable = emi * months;
  const totalInterest = totalPayable - principal;
  return {
    tenureMonths: months,
    monthlyInstallment: round2(emi),
    totalPayable: round2(totalPayable),
    totalInterest: round2(totalInterest),
    annualInterestRate: round2(annualRateDecimal * 100),
  };
}

let insuranceClaimsColumnsEnsured = false;
let insuranceClaimsColumnsEnsuring: Promise<void> | null = null;
async function ensureInsuranceClaimsColumns(): Promise<void> {
  if (insuranceClaimsColumnsEnsured) return;
  if (insuranceClaimsColumnsEnsuring) return insuranceClaimsColumnsEnsuring;
  insuranceClaimsColumnsEnsuring = (async () => {
    await pgPool.query("ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS proof_name TEXT");
    await pgPool.query("ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS incident_date DATE");
    await pgPool.query("ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS claim_amount NUMERIC(12,2) NOT NULL DEFAULT 0");
    await pgPool.query("ALTER TABLE insurance_claims DROP CONSTRAINT IF EXISTS insurance_claims_claim_type_check");
    await pgPool.query(
      "ALTER TABLE insurance_claims ADD CONSTRAINT insurance_claims_claim_type_check CHECK (claim_type IN ('vehicle_damage','product_damage_loss')) NOT VALID"
    );
    insuranceClaimsColumnsEnsured = true;
    insuranceClaimsColumnsEnsuring = null;
  })().catch((error) => {
    insuranceClaimsColumnsEnsuring = null;
    throw error;
  });
  return insuranceClaimsColumnsEnsuring;
}


app.get("/health", async (_req, res) => {
  const r = await pgPool.query("SELECT NOW() AS now");
  res.json({ status: "ok", now: r.rows[0].now, service: "gigbit-api" });
});

app.post("/admin/login", async (req, res) => {
  const username = String(req.body?.username ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");
  if (!username || !password) {
    return res.status(400).json({ message: "Invalid credentials", detail: "Invalid credentials" });
  }
  const r = await pgPool.query(
    "SELECT id, username, email, password_hash FROM admin_users WHERE lower(username) = lower($1) LIMIT 1",
    [username]
  );
  if (!r.rowCount) {
    return res.status(401).json({ message: "Invalid credentials", detail: "Invalid credentials" });
  }
  const admin = r.rows[0] as { id: string; username: string; email: string; password_hash: string };
  const ok = await bcrypt.compare(password, String(admin.password_hash ?? ""));
  if (!ok) return res.status(401).json({ message: "Invalid credentials", detail: "Invalid credentials" });

  const token = jwt.sign(
    { admin: true, role: "admin", adminId: admin.id, email: admin.email, username: admin.username },
    env.JWT_SECRET,
    { expiresIn: "12h" }
  );
  res.json({ token, admin: { username: admin.username, email: admin.email } });
});

app.post("/admin/password/request-otp", async (req, res) => {
  const username = String(req.body?.username ?? "").trim().toLowerCase();
  if (!username) return res.status(400).json({ message: "Username required", detail: "Username required" });
  const r = await pgPool.query(
    "SELECT id, username FROM admin_users WHERE lower(username) = lower($1) LIMIT 1",
    [username]
  );
  if (!r.rowCount) return res.status(404).json({ message: "Admin not found", detail: "Admin not found" });

  const otp = genOtp();
  await pgPool.query(
    "INSERT INTO admin_password_reset_otps (username, otp, expires_at) VALUES ($1,$2,NOW()+INTERVAL '10 minutes') ON CONFLICT (username) DO UPDATE SET otp = EXCLUDED.otp, expires_at = EXCLUDED.expires_at, created_at = NOW()",
    [username, otp]
  );
  try {
    await sendOtpEmail(ADMIN_LOGIN_EMAIL, otp, "password-reset", {
      username,
      channel: "admin",
    });
  } catch (error) {
    console.error("Failed to send admin password-reset OTP email", error);
    return res.status(500).json({ message: "Unable to send OTP email", detail: "Unable to send OTP email" });
  }
  res.json({
    message: "OTP sent to admin email",
    ...(env.OTP_IN_RESPONSE ? { otp } : {}),
  });
});

app.post("/admin/password/verify-otp-change", async (req, res) => {
  const username = String(req.body?.username ?? "").trim().toLowerCase();
  const otp = String(req.body?.otp ?? "").trim();
  const newPassword = String(req.body?.newPassword ?? req.body?.new_password ?? "");
  if (!username || !otp || newPassword.length < 8) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }
  const otpR = await pgPool.query(
    "SELECT otp, expires_at FROM admin_password_reset_otps WHERE lower(username) = lower($1) LIMIT 1",
    [username]
  );
  if (!otpR.rowCount) return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });
  const found = otpR.rows[0] as { otp: string; expires_at: string };
  const valid = found.otp === otp && new Date(found.expires_at).getTime() >= Date.now();
  if (!valid) return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });

  const adminR = await pgPool.query(
    "SELECT id FROM admin_users WHERE lower(username) = lower($1) LIMIT 1",
    [username]
  );
  if (!adminR.rowCount) return res.status(404).json({ message: "Admin not found", detail: "Admin not found" });

  const nextHash = await bcrypt.hash(newPassword, 10);
  await pgPool.query("UPDATE admin_users SET password_hash = $2, updated_at = NOW() WHERE id = $1", [adminR.rows[0].id, nextHash]);
  await pgPool.query("DELETE FROM admin_password_reset_otps WHERE lower(username) = lower($1)", [username]);
  await logAdminActivity(req, "password.reset.otp", { username }, username);
  res.json({ message: "Admin password updated" });
});

app.post("/admin/password/change", requireAdminKey, async (req, res) => {
  const payload = getAdminTokenPayload(req);
  if (!payload?.adminId && !payload?.email) {
    return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  }
  const oldPassword = String(req.body?.oldPassword ?? req.body?.old_password ?? "");
  const newPassword = String(req.body?.newPassword ?? req.body?.new_password ?? "");
  if (!oldPassword || newPassword.length < 8) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }

  const r = payload.adminId
    ? await pgPool.query("SELECT id, email, password_hash FROM admin_users WHERE id = $1 LIMIT 1", [payload.adminId])
    : await pgPool.query("SELECT id, email, password_hash FROM admin_users WHERE lower(email) = lower($1) LIMIT 1", [payload.email!]);
  if (!r.rowCount) return res.status(404).json({ message: "Admin not found", detail: "Admin not found" });

  const admin = r.rows[0] as { id: string; email: string; password_hash: string };
  const ok = await bcrypt.compare(oldPassword, String(admin.password_hash ?? ""));
  if (!ok) return res.status(401).json({ message: "Invalid old password", detail: "Invalid old password" });

  const nextHash = await bcrypt.hash(newPassword, 10);
  await pgPool.query("UPDATE admin_users SET password_hash = $2, updated_at = NOW() WHERE id = $1", [admin.id, nextHash]);
  await logAdminActivity(req, "password.change", { adminId: admin.id });
  res.json({ message: "Admin password updated" });
});

app.get("/me", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  const r = await pgPool.query(
    "SELECT id, email, username, COALESCE(NULLIF(name,''), full_name) AS name, gigbit_insurance, vehicle_rented, daily_fuel, daily_rent, created_at FROM users WHERE id = $1",
    [userId],
  );
  if (!r.rowCount) return res.status(404).json({ message: "User not found", detail: "User not found" });
  const u = r.rows[0] as {
    id: string;
    email: string;
    username: string | null;
    name: string;
    gigbit_insurance: boolean;
    vehicle_rented: boolean;
    daily_fuel: any;
    daily_rent: any;
    created_at: any;
  };
  res.json({
    id: u.id,
    email: u.email,
    username: u.username,
    fullName: u.name,
    gigbitInsurance: Boolean(u.gigbit_insurance),
    vehicleRented: Boolean(u.vehicle_rented),
    dailyFuel: u.daily_fuel == null ? null : Number(u.daily_fuel),
    dailyRent: u.daily_rent == null ? null : Number(u.daily_rent),
    createdAt: u.created_at,
  });
});

app.post("/user/expense-settings", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const vehicleRentedRaw = req.body?.vehicleRented ?? req.body?.vehicle_rented;
  const dailyFuelRaw = req.body?.dailyFuel ?? req.body?.daily_fuel;
  const dailyRentRaw = req.body?.dailyRent ?? req.body?.daily_rent ?? req.body?.rent;

  const dailyFuelNum = dailyFuelRaw == null || dailyFuelRaw === '' ? null : Number(dailyFuelRaw);
  const dailyRentNum = dailyRentRaw == null || dailyRentRaw === '' ? null : Number(dailyRentRaw);
  const dailyFuel = dailyFuelNum != null && Number.isFinite(dailyFuelNum) ? dailyFuelNum : null;
  const dailyRent = dailyRentNum != null && Number.isFinite(dailyRentNum) ? dailyRentNum : null;

  if (dailyFuel == null || !(dailyFuel > 0)) {
    return res.status(400).json({ message: "Invalid daily fuel", detail: "Invalid daily fuel" });
  }

  const u = await pgPool.query("SELECT vehicle_rented FROM users WHERE id = $1", [userId]);
  if (!u.rowCount) return res.status(404).json({ message: "User not found", detail: "User not found" });
  const currentVehicleRented = Boolean(u.rows[0].vehicle_rented);
  const nextVehicleRented =
    vehicleRentedRaw == null ? currentVehicleRented : Boolean(vehicleRentedRaw);

  // One-way lock: once vehicle rent is enabled, user cannot disable it again.
  if (currentVehicleRented && !nextVehicleRented) {
    return res.status(400).json({
      message: "Vehicle rent cannot be disabled once enabled",
      detail: "Vehicle rent cannot be disabled once enabled",
    });
  }

  if (nextVehicleRented && (dailyRent == null || !(dailyRent > 0))) {
    return res.status(400).json({ message: "Invalid rent", detail: "Invalid rent" });
  }
  if (!nextVehicleRented && dailyRent != null && !(dailyRent > 0)) {
    return res.status(400).json({ message: "Invalid rent", detail: "Invalid rent" });
  }

  await pgPool.query(
    "UPDATE users SET vehicle_rented = $2, daily_fuel = $3, daily_rent = $4 WHERE id = $1",
    [userId, nextVehicleRented, dailyFuel, nextVehicleRented ? dailyRent : null],
  );
  res.json({
    message: "Updated",
    dailyFuel,
    dailyRent: nextVehicleRented ? dailyRent : null,
    vehicleRented: nextVehicleRented,
  });
});


app.post("/account/delete-request", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const reasonCode = String(req.body?.reasonCode ?? req.body?.reason_code ?? "").trim().toLowerCase();
  const reasonText = String(req.body?.reasonText ?? req.body?.reason_text ?? "").trim();

  const allowed = new Set(["privacy", "not_using", "switching", "support", "other"]);
  if (!allowed.has(reasonCode)) {
    return res.status(400).json({ message: "Invalid reason", detail: "Invalid reason" });
  }
    if (reasonCode === "other" && !reasonText) {
    return res.status(400).json({ message: "Reason is required", detail: "Reason is required" });
  }

  const u = await pgPool.query("SELECT email FROM users WHERE id = $1", [userId]);
  if (!u.rowCount) return res.status(404).json({ message: "User not found", detail: "User not found" });
  const email = String(u.rows[0].email ?? "");

  // Keep only one pending request per user.
  await pgPool.query("DELETE FROM account_deletion_requests WHERE user_id = $1 AND status = 'pending'", [userId]);
  const r = await pgPool.query(
    "INSERT INTO account_deletion_requests (user_id, user_email, reason_code, reason_text, status) VALUES ($1,$2,$3,$4,'pending') RETURNING id, status, created_at",
    [userId, email, reasonCode, reasonText || null]
  );

  res.status(201).json({ message: "Deletion request submitted", request: r.rows[0] });
});

app.post("/auth/register", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");
  const fullName = String(req.body?.fullName ?? req.body?.name ?? "").trim();
  if (!email || password.length < 8 || fullName.length < 2) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }
  const existing = await pgPool.query("SELECT id FROM users WHERE email = $1", [email]);
  if (existing.rowCount) {
    return res.status(409).json({ message: "Email already registered", detail: "Email already registered" });
  }
  const hash = await bcrypt.hash(password, 10);
  const created = await pgPool.query(
    "INSERT INTO users (email, password_hash, full_name, name) VALUES ($1,$2,$3,$3) RETURNING id,email,name,full_name",
    [email, hash, fullName]
  );
  const user = created.rows[0] as { id: string; email: string; name: string };
  res.status(201).json({ token: signToken(String(user.id)), user: { id: user.id, email: user.email, fullName: user.name } });
});

app.post("/auth/register/request-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  if (!email) return res.status(400).json({ message: "Email is required", detail: "Email is required" });

  const existing = await pgPool.query("SELECT id FROM users WHERE email = $1", [email]);
  if (existing.rowCount) {
    return res.status(409).json({ message: "Email already registered", detail: "Email already registered" });
  }

  const otp = genOtp();
  await setOtp(email, otp);
  let mailMeta:
    | { messageId: string; response: string; accepted: string[]; rejected: string[] }
    | null = null;
  try {
    mailMeta = await sendOtpEmail(email, otp, "registration");
  } catch (error) {
    console.error("Failed to send registration OTP email", error);
    return res.status(500).json({ message: "Unable to send OTP email", detail: "Unable to send OTP email" });
  }
  res.json({
    message: "OTP sent to email",
    ...(env.OTP_IN_RESPONSE ? { otp } : {}),
    ...(env.OTP_IN_RESPONSE ? { mail: mailMeta } : {}),
  });
});

app.post("/auth/register/verify-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = String(req.body?.otp ?? "").trim();
  if (!email || !otp) {
    return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  }

  if (!(await checkOtp(email, otp))) {
    return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });
  }

  const existing = await pgPool.query("SELECT id FROM users WHERE email = $1", [email]);
  if (existing.rowCount) {
    return res.status(409).json({ message: "Email already registered", detail: "Email already registered" });
  }

  await markRegisterVerified(email);
  await clearOtp(email);
  res.json({ message: "OTP verified" });
});

app.post("/auth/register/complete", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const fullName = String(req.body?.fullName ?? req.body?.name ?? "").trim();
  const username = String(req.body?.username ?? "").trim().toLowerCase();
  const password = String(req.body?.password ?? "");

  const vehicleRented = Boolean(req.body?.vehicleRented ?? req.body?.vehicle_rented ?? false);
  const gigbitInsurance = Boolean(req.body?.gigbitInsurance ?? req.body?.gigbit_insurance ?? false);
  const dailyFuelRaw = req.body?.dailyFuel ?? req.body?.daily_fuel;
  const dailyRentRaw = req.body?.rent ?? req.body?.dailyRent ?? req.body?.daily_rent;
  const dailyFuelNum = dailyFuelRaw == null || dailyFuelRaw === '' ? null : Number(dailyFuelRaw);
  const dailyRentNum = dailyRentRaw == null || dailyRentRaw === '' ? null : Number(dailyRentRaw);
  const dailyFuel = dailyFuelNum != null && Number.isFinite(dailyFuelNum) ? dailyFuelNum : null;
  const dailyRent = dailyRentNum != null && Number.isFinite(dailyRentNum) ? dailyRentNum : null;

  if (!email || fullName.length < 2 || username.length < 3 || password.length < 8 || dailyFuel == null || !(dailyFuel > 0) || (vehicleRented && (dailyRent == null || !(dailyRent > 0)))) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }

  const verified = await isRegisterVerified(email);
  if (!verified) {
    return res.status(400).json({ message: "Email OTP verification required", detail: "Email OTP verification required" });
  }

  const existing = await pgPool.query(
    "SELECT id FROM users WHERE lower(email) = lower($1) OR lower(username) = lower($2)",
    [email, username]
  );
  if (existing.rowCount) {
    return res.status(409).json({ message: "Email or username already registered", detail: "Email or username already registered" });
  }

  const hash = await bcrypt.hash(password, 10);
  const created = await pgPool.query(
    "INSERT INTO users (email, username, password_hash, full_name, name, vehicle_rented, gigbit_insurance, daily_fuel, daily_rent)" +
      " VALUES ($1,$2,$3,$4,$4,$5,$6,$7,$8) RETURNING id,email,username,name,full_name",
    [email, username, hash, fullName, vehicleRented, gigbitInsurance, dailyFuel, dailyRent]
  );
  const user = created.rows[0] as { id: string; email: string; username: string; name: string };

  await clearRegisterVerified(email);
  res.status(201).json({
    token: signToken(String(user.id)),
    user: { id: user.id, email: user.email, username: user.username, fullName: user.name },
  });
});

app.post("/auth/login", async (req, res) => {
  const identifier = String(req.body?.identifier ?? req.body?.email ?? req.body?.username ?? "")
    .trim()
    .toLowerCase();
  const password = String(req.body?.password ?? "");

  const row = await pgPool.query(
    "SELECT id,email,username,COALESCE(NULLIF(name,''), full_name) AS name,password_hash FROM users WHERE lower(email) = lower($1) OR lower(username) = lower($1) LIMIT 1",
    [identifier]
  );
  if (!row.rowCount) return res.status(401).json({ message: "Invalid credentials", detail: "Invalid credentials" });

  const user = row.rows[0] as UserRow;
  if (!(await bcrypt.compare(password, user.password_hash))) {
    return res.status(401).json({ message: "Invalid credentials", detail: "Invalid credentials" });
  }

  res.json({
    token: signToken(String(user.id)),
    user: { id: user.id, email: user.email, username: user.username, fullName: user.name },
  });
});
app.post("/auth/password-reset/request", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  if (!email) return res.status(400).json({ message: "Email is required", detail: "Email is required" });
  const row = await pgPool.query("SELECT id, username FROM users WHERE email = $1", [email]);
  if (!row.rowCount) return res.status(404).json({ message: "Email not found", detail: "Email not found" });
  const otp = genOtp();
  await setOtp(email, otp);
  let mailMeta:
    | { messageId: string; response: string; accepted: string[]; rejected: string[] }
    | null = null;
  try {
    const userRow = row.rows[0] as { id: string; username: string | null };
    mailMeta = await sendOtpEmail(email, otp, "password-reset", { username: userRow.username });
  } catch (error) {
    console.error("Failed to send password-reset OTP email", error);
    return res.status(500).json({ message: "Unable to send OTP email", detail: "Unable to send OTP email" });
  }
  res.json({
    message: "OTP sent to email",
    ...(env.OTP_IN_RESPONSE ? { otp } : {}),
    ...(env.OTP_IN_RESPONSE ? { mail: mailMeta } : {}),
  });
});

app.post("/auth/password-reset/verify", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = String(req.body?.otp ?? "").trim();
  const newPassword = String(req.body?.newPassword ?? req.body?.new_password ?? "");
  if (!email || !otp || newPassword.length < 8) {
    return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  }
  if (!(await checkOtp(email, otp))) {
    return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });
  }
  const hash = await bcrypt.hash(newPassword, 10);
  await pgPool.query("UPDATE users SET password_hash = $1 WHERE email = $2", [hash, email]);
  await clearOtp(email);
  res.json({ message: "Password updated" });
});

app.post("/auth/request-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  if (!email) return res.status(400).json({ message: "Email is required", detail: "Email is required" });
  const otp = genOtp();
  await setOtp(email, otp);
  let mailMeta:
    | { messageId: string; response: string; accepted: string[]; rejected: string[] }
    | null = null;
  try {
    mailMeta = await sendOtpEmail(email, otp, "registration");
  } catch (error) {
    console.error("Failed to send registration OTP email", error);
    return res.status(500).json({ message: "Unable to send OTP email", detail: "Unable to send OTP email" });
  }
  res.json({
    message: "OTP sent to email",
    ...(env.OTP_IN_RESPONSE ? { otp } : {}),
    ...(env.OTP_IN_RESPONSE ? { mail: mailMeta } : {}),
  });
});

app.post("/auth/verify-otp", async (req, res) => {
  const email = String(req.body?.email ?? "").trim().toLowerCase();
  const otp = String(req.body?.otp ?? "").trim();
  const password = String(req.body?.password ?? "");
  const name = String(req.body?.name ?? req.body?.username ?? "User").trim();
  if (!email || !otp || password.length < 8) {
    return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  }
  if (!(await checkOtp(email, otp))) {
    return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });
  }
  const existing = await pgPool.query("SELECT id FROM users WHERE email = $1", [email]);
  if (existing.rowCount) return res.status(409).json({ message: "Email already registered", detail: "Email already registered" });
  const hash = await bcrypt.hash(password, 10);
  const created = await pgPool.query(
    "INSERT INTO users (email,password_hash,full_name,name,username) VALUES ($1,$2,$3,$3,$4) RETURNING id,email,name,full_name,username",
    [email, hash, name, null]
  );
  const user = created.rows[0] as { id: string; email: string; username: string | null; name: string };
  await clearOtp(email);
  res.status(201).json({ token: signToken(String(user.id)), user: { id: user.id, email: user.email, username: user.username, fullName: user.name } });
});

app.get("/user/platforms", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  await refreshSubscriptionRuntimeState(userId);
  res.json({ platforms: await getPlatforms(userId) });
});
app.get("/user/platforms/:userId", async (req, res) => {
  const userId = String(req.params.userId ?? "").trim();
  if (!userId) return res.status(400).json({ message: "User required", detail: "User required" });
  await refreshSubscriptionRuntimeState(userId);
  res.json({ platforms: await getPlatforms(userId) });
});
app.get("/platforms/catalog", async (_req, res) => {
  const r = await pgPool.query(
    "SELECT id, slug, name, logo_url, logo_bg_color, enabled, sort_order FROM integration_platform_catalog WHERE enabled = TRUE ORDER BY sort_order ASC, created_at ASC"
  );
  res.json({ items: r.rows });
});
app.get("/platforms/catalog/stream", async (req, res) => {
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders?.();

  platformCatalogStreamClients.add(res);
  res.write("retry: 3000\n");
  res.write(`data: ${JSON.stringify({ version: Date.now() })}\n\n`);

  const keepAlive = setInterval(() => {
    res.write(": ping\n\n");
  }, 25000);

  req.on("close", () => {
    clearInterval(keepAlive);
    platformCatalogStreamClients.delete(res);
    res.end();
  });
});

app.get("/user/approval-updates/stream", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) {
    return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  }

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.flushHeaders?.();

  let bucket = userApprovalStreamClients.get(userId);
  if (!bucket) {
    bucket = new Set<Response>();
    userApprovalStreamClients.set(userId, bucket);
  }
  bucket.add(res);

  res.write("retry: 3000\n");
  res.write(`event: approval_update\ndata: ${JSON.stringify({ type: "hello", ts: Date.now() })}\n\n`);

  const keepAlive = setInterval(() => {
    res.write(": ping\n\n");
  }, 25000);

  req.on("close", () => {
    clearInterval(keepAlive);
    const set = userApprovalStreamClients.get(userId);
    if (set) {
      set.delete(res);
      if (!set.size) userApprovalStreamClients.delete(userId);
    }
    res.end();
  });
});

app.post("/platforms/connect", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const platform = String(req.body?.platform ?? "").trim().toLowerCase();
  if (!userId || !platform) return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  const platformCatalog = await pgPool.query(
    "SELECT enabled FROM integration_platform_catalog WHERE lower(slug) = $1 LIMIT 1",
    [platform],
  );
  if (!platformCatalog.rowCount || !Boolean(platformCatalog.rows[0].enabled)) {
    return res.status(403).json({ message: "Platform unavailable", detail: "Platform unavailable" });
  }

  const state = await refreshSubscriptionRuntimeState(userId);
  if (state.status !== "active" || !state.limit) {
    return res.status(402).json({ message: "Subscription required", detail: "Subscription required" });
  }

  const existingConn = await pgPool.query(
    "SELECT 1 FROM platform_connections WHERE user_id = $1 AND lower(platform) = $2",
    [userId, platform]
  );
  if (existingConn.rowCount) {
    return res.json({ message: "Platform connected" });
  }

  const existingBinding = await pgPool.query(
    `SELECT b.id
       FROM platform_subscription_bindings b
       JOIN subscription_purchases sp ON sp.id = b.purchase_id
      WHERE b.user_id = $1
        AND lower(b.platform) = $2
        AND b.unbound_at IS NULL
        AND b.expires_at > NOW()
        AND (sp.created_at + INTERVAL '30 days') > NOW()
      LIMIT 1`,
    [userId, platform],
  );

  if (!existingBinding.rowCount) {
    const usageR = await pgPool.query(
      `SELECT b.purchase_id, COUNT(*)::int AS c
       FROM platform_subscription_bindings b
       JOIN subscription_purchases sp ON sp.id = b.purchase_id
       WHERE b.user_id = $1
         AND b.unbound_at IS NULL
         AND b.expires_at > NOW()
         AND (sp.created_at + INTERVAL '30 days') > NOW()
       GROUP BY b.purchase_id`,
      [userId],
    );
    const usage = new Map<string, number>();
    for (const row of usageR.rows as any[]) {
      usage.set(String(row.purchase_id), Number(row.c ?? 0));
    }

    const slot = state.activePlanWindows.find((w) => (usage.get(w.id) ?? 0) < w.slots);
    if (!slot) {
      return res.status(402).json({
        message: "Plan limit reached",
        detail: "Plan limit reached",
        used: state.used,
        limit: state.limit,
      });
    }

    await pgPool.query(
      `INSERT INTO platform_subscription_bindings
        (user_id, platform, purchase_id, plan, bound_at, expires_at)
       VALUES ($1,$2,$3,$4,NOW(),$5)
       ON CONFLICT (user_id, platform) WHERE unbound_at IS NULL DO NOTHING`,
      [userId, platform, slot.id, slot.plan, slot.expiresAt],
    );

    await pgPool.query(
      "INSERT INTO platform_connection_history (user_id,platform) VALUES ($1,$2) ON CONFLICT (user_id,platform) DO NOTHING",
      [userId, platform],
    );
  }

  await pgPool.query(
    "INSERT INTO platform_connections (user_id,platform) VALUES ($1,$2) ON CONFLICT (user_id,platform) DO NOTHING",
    [userId, platform]
  );
  const nextState = await refreshSubscriptionRuntimeState(userId);
  res.json({ message: "Platform connected", used: nextState.used, limit: nextState.limit });
});
app.post("/platforms/disconnect", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  const platform = String(req.body?.platform ?? "").trim().toLowerCase();
  if (!userId || !platform) return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  await pgPool.query("DELETE FROM platform_connections WHERE user_id = $1 AND platform = $2", [userId, platform]);
  res.json({ message: "Platform disconnected" });
});
app.post("/platforms/sync-earning", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  const platform = String(req.body?.platform ?? "").trim().toLowerCase();
  const amount = Number(req.body?.amount ?? 0);
  if (!userId || !platform || !(amount > 0)) return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  const platformCatalog = await pgPool.query(
    "SELECT enabled FROM integration_platform_catalog WHERE lower(slug) = $1 LIMIT 1",
    [platform],
  );
  if (!platformCatalog.rowCount || !Boolean(platformCatalog.rows[0].enabled)) {
    return res.status(403).json({ message: "Platform unavailable", detail: "Platform unavailable" });
  }
  const tripsRaw = req.body?.trips;
  const perTripRaw = req.body?.perTrip ?? req.body?.per_trip;
  const trips = tripsRaw == null ? null : Number(tripsRaw);
  const perTrip = perTripRaw == null ? null : Number(perTripRaw);

  if (trips != null && (!Number.isInteger(trips) || trips <= 0)) {
    return res.status(400).json({ message: "Invalid trips", detail: "Invalid trips" });
  }
  if (perTrip != null && !(perTrip >= 25 && perTrip <= 50)) {
    return res.status(400).json({ message: "Invalid per-trip amount", detail: "Invalid per-trip amount" });
  }
  if (amount > 800) {
    return res.status(400).json({ message: "Amount exceeds max limit", detail: "Amount exceeds max limit" });
  }
  if (trips != null && perTrip != null && Math.round(trips * perTrip) !== Math.round(amount)) {
    return res.status(400).json({ message: "Amount mismatch", detail: "Amount mismatch" });
  }

  const todayR = await pgPool.query(
    "SELECT COALESCE(SUM(amount),0) AS total FROM platform_earnings WHERE user_id = $1 AND platform = $2 AND ((created_at AT TIME ZONE 'Asia/Kolkata')::date = (NOW() AT TIME ZONE 'Asia/Kolkata')::date)",
    [userId, platform],
  );
  const todayTotal = Number(todayR.rows[0]?.total ?? 0);
  if (todayTotal >= 800) {
    return res.status(400).json({ message: "Platform maxed", detail: "Platform maxed at Rs 800 for today" });
  }
  if (todayTotal + amount > 800) {
    return res.status(400).json({ message: "Amount exceeds platform cap", detail: "Per-platform daily cap is Rs 800" });
  }

  const note = (trips != null && perTrip != null)
    ? `Synced from platform | trips: ${trips} | per_trip: ${perTrip}`
    : "Synced from platform";

  await pgPool.query("INSERT INTO platform_earnings (user_id,platform,amount) VALUES ($1,$2,$3)", [userId, platform, amount]);
  await pgPool.query("INSERT INTO transactions (user_id,platform,amount,note) VALUES ($1,$2,$3,$4)", [userId, platform, amount, note]);
  await safeRedisDel("dashboard:" + userId);
  res.json({ message: "Earning synced" });
});

app.get("/dashboard/summary", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  res.json(await getSummary(userId));
});

app.get("/transactions", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  const r = await pgPool.query(
    `SELECT t.id,t.platform,t.amount,t.note,t.created_at
     FROM transactions t
     JOIN integration_platform_catalog c ON lower(c.slug) = lower(t.platform) AND c.enabled = TRUE
     WHERE t.user_id = $1
     ORDER BY t.created_at DESC
     LIMIT 100`,
    [userId]
  );
  res.json(r.rows);
});
app.post("/transactions", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const platform = String(req.body?.platform ?? "").trim();
  const amount = Number(req.body?.amount ?? 0);
  if (!userId || !platform || !(amount > 0)) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  const r = await pgPool.query("INSERT INTO transactions (user_id,platform,amount,note) VALUES ($1,$2,$3,$4) RETURNING id,platform,amount,note,created_at", [userId, platform, amount, req.body?.note ?? null]);
  res.status(201).json(r.rows[0]);
});

app.post("/withdraw", async (req, res) => processWithdraw(req, res));
app.post("/withdrawals", async (req, res) => processWithdraw(req, res));

app.get("/insurance/contributions", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  await ensureMonthlyInsuranceAutoDebit(userId);
  const r = await pgPool.query("SELECT id,amount,created_at FROM insurance_contributions WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50", [userId]);
  res.json(r.rows);
});
app.get("/insurance/claims", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  await ensureInsuranceClaimsColumns();
  const r = await pgPool.query(
    `SELECT id, claim_type, incident_date, claim_amount, proof_name, proof_url, status, created_at
     FROM insurance_claims
     WHERE user_id = $1
     ORDER BY created_at DESC
     LIMIT 120`,
    [userId]
  );
  res.json({ items: r.rows });
});
app.post("/insurance/claims", async (req, res) => submitClaim(req, res));
app.post("/insurance/claim", async (req, res) => submitClaim(req, res));

app.get("/ledger", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  res.json(await getLedger(userId));
});

app.post("/expenses", async (req, res) => {
  const userId = String(req.body?.user_id ?? "").trim();
  const amount = Number(req.body?.amount ?? 0);
  if (!userId || !(amount > 0)) return res.status(400).json({ message: "Invalid expense", detail: "Invalid expense" });
  await pgPool.query("INSERT INTO expenses (user_id,category,amount,note) VALUES ($1,$2,$3,$4)", [userId, req.body?.category ?? "misc", amount, req.body?.note ?? null]);
  res.json({ message: "Expense saved" });
});

app.post("/expenses/upsert-daily", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const categoryRaw = String(req.body?.category ?? "").trim().toLowerCase();
  const amount = Number(req.body?.amount ?? 0);
  const note = req.body?.note == null ? null : String(req.body.note);

  if (!userId || !(amount > 0) || !categoryRaw) {
    return res.status(400).json({ message: "Invalid expense", detail: "Invalid expense" });
  }

  const category = categoryRaw.includes("rent")
    ? "rent"
    : (categoryRaw.includes("fuel") || categoryRaw.includes("petrol") || categoryRaw.includes("diesel"))
        ? "fuel"
        : categoryRaw;

  const updated = await pgPool.query(
    `UPDATE expenses
       SET amount = $3, note = $4
     WHERE id = (
       SELECT id
       FROM expenses
       WHERE user_id = $1
         AND lower(category) = $2
         AND ((created_at AT TIME ZONE 'Asia/Kolkata')::date = (NOW() AT TIME ZONE 'Asia/Kolkata')::date)
       ORDER BY created_at DESC
       LIMIT 1
     )
     RETURNING id, category, amount, note, created_at`,
    [userId, category, amount, note],
  );

  if (updated.rowCount) {
    return res.json({ message: "Expense updated", expense: updated.rows[0] });
  }

  const inserted = await pgPool.query(
    "INSERT INTO expenses (user_id, category, amount, note) VALUES ($1,$2,$3,$4) RETURNING id, category, amount, note, created_at",
    [userId, category, amount, note],
  );
  return res.status(201).json({ message: "Expense saved", expense: inserted.rows[0] });
});

app.get("/expenses", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  // Return recent expenses so clients can build week/month-to-date summaries locally.
  const r = await pgPool.query(
    "SELECT id, category, amount, note, created_at FROM expenses WHERE user_id = $1 ORDER BY created_at DESC LIMIT 500",
    [userId],
  );
  res.json({ expenses: r.rows });
});

app.get("/loan/eligibility", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  res.json(await getLoan(userId));
});
app.get("/loan/requests", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  const r = await pgPool.query(
    `SELECT id, amount, status, created_at
            ,proof_url, proof_name, annual_interest_rate, tenure_months, monthly_installment, total_interest, total_payable
       FROM loans
      WHERE user_id = $1
      ORDER BY created_at DESC
      LIMIT 200`,
    [userId]
  );
  res.json({ items: r.rows });
});
app.post("/loan/apply", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  const amount = Number(req.body?.amount ?? 0);
  const proofUrl = String(req.body?.proof_url ?? req.body?.proofUrl ?? "").trim();
  const proofName = String(req.body?.proof_name ?? req.body?.proofName ?? "").trim();

  if (!userId || !(amount > 0)) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }
  if (amount < LOAN_MIN_AMOUNT || amount > LOAN_MAX_AMOUNT) {
    return res.status(400).json({
      message: `Loan amount must be between ${LOAN_MIN_AMOUNT} and ${LOAN_MAX_AMOUNT}`,
      detail: `Loan amount must be between ${LOAN_MIN_AMOUNT} and ${LOAN_MAX_AMOUNT}`,
    });
  }
  if (!proofUrl) {
    return res.status(400).json({ message: "Loan document is required", detail: "Loan document is required" });
  }

  const eligibility = await getLoan(userId);
  const annualRateDecimal = Number(eligibility.annualInterestRate) / 100;
  const plan = calculateReducingLoanPlan(amount, annualRateDecimal);
  const r = await pgPool.query(
    `INSERT INTO loans
      (user_id, amount, proof_url, proof_name, annual_interest_rate, tenure_months, monthly_installment, total_interest, total_payable, status)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'pending')
     RETURNING id, user_id, amount, proof_url, proof_name, annual_interest_rate, tenure_months, monthly_installment, total_interest, total_payable, status, created_at`,
    [
      userId,
      amount,
      proofUrl,
      proofName || null,
      plan.annualInterestRate,
      plan.tenureMonths,
      plan.monthlyInstallment,
      plan.totalInterest,
      plan.totalPayable,
    ]
  );
  res.status(201).json(r.rows[0]);
});

app.post("/support/tickets", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const subject = String(req.body?.subject ?? "Support Ticket").trim();
  const complaint = String(req.body?.complaint ?? req.body?.description ?? "").trim();
  if (complaint.length < 8) {
    return res.status(400).json({ message: "Complaint is too short", detail: "Complaint is too short" });
  }

  const now = new Date();
  const yy = String(now.getFullYear()).slice(-2);
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");

  let created: any = null;
  for (let i = 0; i < 8; i++) {
    const rand = Math.floor(1000 + Math.random() * 9000);
    const ticketNumber = `GB-${yy}${m}${d}-${rand}`;
    const r = await pgPool.query(
      "INSERT INTO support_tickets (ticket_number, user_id, subject, complaint, status, updated_at) VALUES ($1,$2,$3,$4,'open',NOW()) ON CONFLICT (ticket_number) DO NOTHING RETURNING id, ticket_number, subject, complaint, status, created_at, updated_at",
      [ticketNumber, userId, subject || "Support Ticket", complaint]
    );
    if (r.rowCount) {
      created = r.rows[0];
      break;
    }
  }
  if (!created) {
    return res.status(500).json({ message: "Unable to create ticket", detail: "Unable to create ticket" });
  }
  res.status(201).json({ message: "Ticket created", ticket: created });
});

app.get("/support/tickets", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const limitRaw = Number(req.query?.limit ?? 100);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(300, Math.trunc(limitRaw))) : 100;

  const r = await pgPool.query(
    `SELECT
      id,
      ticket_number,
      subject,
      complaint,
      status,
      created_at,
      updated_at,
      CASE
        WHEN lower(status) IN ('resolved','closed','done') THEN 'Resolved'
        WHEN lower(status) IN ('in_progress','in-progress','progress') THEN 'In Progress'
        ELSE 'Open'
      END AS progress
    FROM support_tickets
    WHERE user_id = $1
    ORDER BY created_at DESC
    LIMIT $2`,
    [userId, limit]
  );
  res.json({ tickets: r.rows });
});

app.get("/tax/assistant/history", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.query?.user_id ?? "").trim();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const limitRaw = Number(req.query?.limit ?? 200);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(500, Math.trunc(limitRaw))) : 200;
  const chatId = String(req.query?.chatId ?? req.query?.chat_id ?? "").trim();

  const r = chatId === "__legacy__"
    ? await pgPool.query(
        `SELECT id, question, answer, created_at, session_id
         FROM tax_chat_messages
         WHERE user_id = $1 AND session_id IS NULL
         ORDER BY created_at ASC
         LIMIT $2`,
        [userId, limit]
      )
    : chatId
    ? await pgPool.query(
        `SELECT id, question, answer, created_at, session_id
         FROM tax_chat_messages
         WHERE user_id = $1 AND session_id = $2
         ORDER BY created_at ASC
         LIMIT $3`,
        [userId, chatId, limit]
      )
    : await pgPool.query(
        `SELECT id, question, answer, created_at, session_id
         FROM tax_chat_messages
         WHERE user_id = $1
         ORDER BY created_at ASC
         LIMIT $2`,
        [userId, limit]
      );
  res.json({ messages: r.rows });
});

app.get("/tax/assistant/chats", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.query?.user_id ?? "").trim();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const limitRaw = Number(req.query?.limit ?? 120);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(300, Math.trunc(limitRaw))) : 120;

  const r = await pgPool.query(
    `SELECT s.id,
            COALESCE(NULLIF(s.title, ''), 'New Chat') AS title,
            s.created_at,
            s.updated_at,
            COALESCE(m.message_count, 0)::int AS message_count,
            m.last_message_at
     FROM tax_chat_sessions s
     LEFT JOIN (
       SELECT session_id, COUNT(*) AS message_count, MAX(created_at) AS last_message_at
       FROM tax_chat_messages
       WHERE user_id = $1
       GROUP BY session_id
     ) m ON m.session_id = s.id
     WHERE s.user_id = $1
       AND COALESCE(m.message_count, 0) > 0
     ORDER BY COALESCE(m.last_message_at, s.updated_at, s.created_at) DESC
     LIMIT $2`,
    [userId, limit]
  );

  const chats = [...r.rows];
  const legacy = await pgPool.query(
    "SELECT COUNT(*)::int AS c, MAX(created_at) AS last_message_at FROM tax_chat_messages WHERE user_id = $1 AND session_id IS NULL",
    [userId]
  );
  const legacyCount = Number(legacy.rows[0]?.c ?? 0);
  if (legacyCount > 0) {
    chats.push({
      id: "__legacy__",
      title: "Legacy Chat",
      created_at: null,
      updated_at: legacy.rows[0]?.last_message_at ?? null,
      message_count: legacyCount,
      last_message_at: legacy.rows[0]?.last_message_at ?? null,
    });
    chats.sort((a: any, b: any) => {
      const ta = new Date(String(a.last_message_at ?? a.updated_at ?? a.created_at ?? 0)).getTime();
      const tb = new Date(String(b.last_message_at ?? b.updated_at ?? b.created_at ?? 0)).getTime();
      return tb - ta;
    });
  }

  res.json({ chats });
});

app.post("/tax/assistant/chats", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const rawTitle = String(req.body?.title ?? "").trim();
  const title = rawTitle.length ? rawTitle.slice(0, 120) : "New Chat";

  const r = await pgPool.query(
    `INSERT INTO tax_chat_sessions (user_id, title)
     VALUES ($1, $2)
     RETURNING id, title, created_at, updated_at`,
    [userId, title]
  );
  res.status(201).json({ chat: r.rows[0] });
});

const renameTaxChatHandler = async (req: express.Request, res: express.Response) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const chatId = String(req.params.id ?? "").trim();
  const title = String(req.body?.title ?? "").trim().slice(0, 120);
  if (!chatId || !title) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }

  const r = await pgPool.query(
    `UPDATE tax_chat_sessions
     SET title = $3, updated_at = NOW()
     WHERE id = $1 AND user_id = $2
     RETURNING id, title, created_at, updated_at`,
    [chatId, userId, title]
  );
  if (!r.rowCount) {
    return res.status(404).json({ message: "Chat not found", detail: "Chat not found" });
  }
  res.json({ chat: r.rows[0] });
};

app.patch("/tax/assistant/chats/:id", renameTaxChatHandler);
app.post("/tax/assistant/chats/:id/rename", renameTaxChatHandler);

const deleteTaxChatHandler = async (req: express.Request, res: express.Response) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const chatId = String(req.params.id ?? "").trim();
  if (!chatId) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }

  if (chatId === "__legacy__") {
    const r = await pgPool.query(
      "DELETE FROM tax_chat_messages WHERE user_id = $1 AND session_id IS NULL",
      [userId]
    );
    return res.json({ message: "Chat deleted", deletedMessages: r.rowCount ?? 0 });
  }

  const deletedMessages = await pgPool.query(
    "DELETE FROM tax_chat_messages WHERE user_id = $1 AND session_id = $2",
    [userId, chatId]
  );
  const deletedChat = await pgPool.query(
    "DELETE FROM tax_chat_sessions WHERE id = $1 AND user_id = $2 RETURNING id",
    [chatId, userId]
  );
  if (!deletedChat.rowCount) {
    return res.status(404).json({ message: "Chat not found", detail: "Chat not found" });
  }
  res.json({ message: "Chat deleted", deletedMessages: deletedMessages.rowCount ?? 0 });
};

app.delete("/tax/assistant/chats/:id", deleteTaxChatHandler);
app.post("/tax/assistant/chats/:id/delete", deleteTaxChatHandler);

app.post("/tax/assistant", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  const question = String(req.body?.question ?? "").trim();
  let chatId = String(req.body?.chatId ?? req.body?.chat_id ?? "").trim();
  const lang = taxLangFrom(req.body?.language ?? req.body?.lang);
  if (!userId || question.length < 1) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });

  // If no chat is selected, create one from first user message to avoid storing empty chats.
  if (!chatId) {
    const firstTitle = deriveTaxChatTitle(question);
    const created = await pgPool.query(
      `INSERT INTO tax_chat_sessions (user_id, title)
       VALUES ($1, $2)
       RETURNING id, title`,
      [userId, firstTitle || "New Chat"]
    );
    chatId = String(created.rows[0]?.id ?? "").trim();
  }

  if (chatId && chatId !== "__legacy__") {
    const owns = await pgPool.query(
      "SELECT id, title FROM tax_chat_sessions WHERE id = $1 AND user_id = $2 LIMIT 1",
      [chatId, userId]
    );
    if (!owns.rowCount) {
      return res.status(404).json({ message: "Chat not found", detail: "Chat not found" });
    }
    const currentTitle = String(owns.rows[0].title ?? "").trim();
    if (!currentTitle || currentTitle.toLowerCase() === "new chat") {
      const nextTitle = deriveTaxChatTitle(question);
      await pgPool.query(
        "UPDATE tax_chat_sessions SET title = $3, updated_at = NOW() WHERE id = $1 AND user_id = $2",
        [chatId, userId, nextTitle]
      );
    } else {
      await pgPool.query(
        "UPDATE tax_chat_sessions SET updated_at = NOW() WHERE id = $1 AND user_id = $2",
        [chatId, userId]
      );
    }
  }

  const q = question.toLowerCase();
  const inScope = TAX_ASSISTANT_ALLOWED_TERMS.some((term) => q.includes(term));
  let answer = "";
  if (!inScope) {
    answer = taxT(
      lang,
      "I can only help with Tax, ITR filing, and GigBit platform queries. Please ask about deductions, TDS, ITR form selection, filing steps, or GigBit earnings/expense tax summary.",
      "मैं केवल Tax, ITR filing और GigBit platform से जुड़े सवालों में मदद कर सकता हूँ। कृपया deductions, TDS, ITR form, filing steps या GigBit earnings/expense tax summary के बारे में पूछें।",
      "मी फक्त Tax, ITR filing आणि GigBit platform संबंधित प्रश्नांमध्ये मदत करू शकतो. कृपया deductions, TDS, ITR form, filing steps किंवा GigBit earnings/expense tax summary बद्दल विचारा."
    );
    await pgPool.query(
      "INSERT INTO tax_chat_messages (user_id, session_id, question, answer) VALUES ($1,$2,$3,$4)",
      [userId, chatId && chatId !== "__legacy__" ? chatId : null, question, answer]
    );
    return res.json({ answer, chatId: chatId || null });
  }

  const summary = await getSummary(userId);
  const taxable = Math.max(0, summary.totalEarnings - summary.expenses);
  const istNowR = await pgPool.query("SELECT timezone('Asia/Kolkata', NOW()) AS now_ist");
  const istNow = new Date(String(istNowR.rows[0].now_ist));
  const fyStartYear = istNow.getMonth() >= 3 ? istNow.getFullYear() : istNow.getFullYear() - 1;
  const fyEndYear = fyStartYear + 1;
  const ayStartYear = fyEndYear;
  const ayEndYear = ayStartYear + 1;

  const answerLines = [
    taxT(
      lang,
      "Tax Assistant Scope: Tax, ITR, and GigBit platform finances only.",
      "टैक्स असिस्टेंट का दायरा: केवल Tax, ITR और GigBit platform finance.",
      "टॅक्स असिस्टंटचा विषय: फक्त Tax, ITR आणि GigBit platform finance."
    ),
    "",
    taxT(
      lang,
      `Quick Answer: Estimated taxable business income is about Rs ${Math.round(taxable)}.`,
      `त्वरित उत्तर: अनुमानित करयोग्य व्यवसाय आय लगभग Rs ${Math.round(taxable)} है।`,
      `झटपट उत्तर: अंदाजे करपात्र व्यवसाय उत्पन्न Rs ${Math.round(taxable)} आहे.`
    ),
    taxT(
      lang,
      "Keep expense proofs and verify final liability with a CA before filing.",
      "खर्च के प्रमाण रखें और फाइलिंग से पहले अंतिम टैक्स देनदारी CA से सत्यापित करें।",
      "खर्चाचे पुरावे जतन करा आणि फायलिंगपूर्वी अंतिम करदेयता CA कडून तपासा."
    ),
    "",
    taxT(
      lang,
      "ITR Filing Summary (Use This On Official ITR Portal)",
      "ITR फाइलिंग सारांश (इसे आधिकारिक ITR पोर्टल पर उपयोग करें)",
      "ITR फायलिंग सारांश (हे अधिकृत ITR पोर्टलवर वापरा)"
    ),
    taxT(
      lang,
      `Financial Year (FY): ${fyStartYear}-${String(fyEndYear).slice(-2)}`,
      `वित्तीय वर्ष (FY): ${fyStartYear}-${String(fyEndYear).slice(-2)}`,
      `आर्थिक वर्ष (FY): ${fyStartYear}-${String(fyEndYear).slice(-2)}`
    ),
    taxT(
      lang,
      `Assessment Year (AY): ${ayStartYear}-${String(ayEndYear).slice(-2)}`,
      `आकलन वर्ष (AY): ${ayStartYear}-${String(ayEndYear).slice(-2)}`,
      `आकलन वर्ष (AY): ${ayStartYear}-${String(ayEndYear).slice(-2)}`
    ),
    taxT(lang, "Taxpayer Type: Individual", "करदाता प्रकार: व्यक्तिगत", "करदाता प्रकार: वैयक्तिक"),
    taxT(
      lang,
      "Income Nature: Gig/Platform Income (Business or Profession)",
      "आय का प्रकार: Gig/Platform आय (व्यवसाय या पेशा)",
      "उत्पन्न प्रकार: Gig/Platform उत्पन्न (व्यवसाय किंवा व्यावसायिक)"
    ),
    taxT(
      lang,
      `Gross Receipts (From GigBit): Rs ${Math.round(summary.totalEarnings)}`,
      `कुल प्राप्तियां (GigBit से): Rs ${Math.round(summary.totalEarnings)}`,
      `एकूण प्राप्ती (GigBit मधून): Rs ${Math.round(summary.totalEarnings)}`
    ),
    taxT(
      lang,
      `Allowable Expenses (From GigBit): Rs ${Math.round(summary.expenses)}`,
      `स्वीकार्य खर्च (GigBit से): Rs ${Math.round(summary.expenses)}`,
      `मान्य खर्च (GigBit मधून): Rs ${Math.round(summary.expenses)}`
    ),
    taxT(
      lang,
      `Net Taxable Income (Estimate): Rs ${Math.round(taxable)}`,
      `शुद्ध करयोग्य आय (अनुमान): Rs ${Math.round(taxable)}`,
      `निव्वळ करपात्र उत्पन्न (अंदाज): Rs ${Math.round(taxable)}`
    ),
    taxT(
      lang,
      "TDS Credit: Fill from Form 26AS / AIS",
      "TDS क्रेडिट: Form 26AS / AIS से भरें",
      "TDS क्रेडिट: Form 26AS / AIS मधून भरा"
    ),
    taxT(
      lang,
      "Advance/Self-Assessment Tax: Fill actual challan values",
      "एडवांस/सेल्फ-असेसमेंट टैक्स: वास्तविक चालान मान भरें",
      "Advance/Self-Assessment Tax: प्रत्यक्ष चलन मूल्य भरा"
    ),
    taxT(
      lang,
      "Suggested Form: ITR-3 or ITR-4 (if eligible under presumptive scheme)",
      "सुझाया गया फॉर्म: ITR-3 या ITR-4 (यदि presumptive scheme के तहत पात्र हों)",
      "सुचवलेला फॉर्म: ITR-3 किंवा ITR-4 (presumptive scheme अंतर्गत पात्र असल्यास)"
    ),
    "",
    taxT(
      lang,
      `Original Question: ${question}`,
      `मूल प्रश्न: ${question}`,
      `मूळ प्रश्न: ${question}`
    ),
  ];

  answer = answerLines.join("\n");
  await pgPool.query(
    "INSERT INTO tax_chat_messages (user_id, session_id, question, answer) VALUES ($1,$2,$3,$4)",
    [userId, chatId && chatId !== "__legacy__" ? chatId : null, question, answer]
  );
  res.json({ answer, chatId: chatId || null });
});

app.get("/subscription/purchases", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  const r = await pgPool.query(
    "SELECT id, plan, amount, created_at, (created_at + INTERVAL '30 days') AS expires_at FROM subscription_purchases WHERE user_id = $1 ORDER BY created_at DESC LIMIT 120",
    [userId]
  );
  res.json({ purchases: r.rows });
});

app.get("/subscription/:userId", async (req, res) => {
  const userId = req.params.userId;
  if (!userId) return res.status(400).json({ message: "User required", detail: "User required" });

  const state = await refreshSubscriptionRuntimeState(userId);
  const r = await pgPool.query("SELECT pending_plan, updated_at FROM subscriptions WHERE user_id = $1", [userId]);
  const pendingPlan = r.rowCount ? (r.rows[0] as any).pending_plan : null;
  const pendingActivationAt = r.rowCount ? (r.rows[0] as any).updated_at : null;

  res.json({
    activePlan: state.activePlan,
    pendingPlan,
    activePlanExpiresAt: state.activePlanExpiresAt,
    pendingActivationAt,
    used: state.used,
    limit: state.limit,
    remaining: state.remaining,
    historyPlatforms: state.historyPlatforms,
    activePlanWindows: state.activePlanWindows,
    recentlyExpiredPlanWindows: state.recentlyExpiredPlanWindows,
  });
});
app.post("/subscription/select", async (req, res) => {
  const userId = String(req.body?.user_id ?? "").trim();
  const plan = String(req.body?.plan ?? "").trim().toLowerCase();
  const inc = planIncrement(plan);
  const amount = planAmount(plan);
  if (!userId || !inc || !amount) return res.status(400).json({ message: "Invalid plan", detail: "Invalid plan" });

  const maxPlatforms = await getCatalogPlatformCapacity();
  const cap = monthlyPurchaseCap(plan, maxPlatforms);
  if (!cap) return res.status(400).json({ message: "Invalid plan", detail: "Invalid plan" });

  // Prevent buying plans that would push active limit beyond available platforms.
  const runtime = await refreshSubscriptionRuntimeState(userId);
  const prevLimit = runtime.limit;
  if (prevLimit >= maxPlatforms) {
    return res.status(409).json({ message: "Platform limit already maxed", detail: "Platform limit already maxed", limit: prevLimit, max: maxPlatforms });
  }
  if (prevLimit + inc > maxPlatforms) {
    return res.status(409).json({ message: "Plan exceeds available platforms", detail: "Plan exceeds available platforms", limit: prevLimit, inc, max: maxPlatforms });
  }

  // Use IST month boundaries for monthly purchase caps.
  const monthStartR = await pgPool.query(
    "SELECT (date_trunc('month', timezone('Asia/Kolkata', NOW())) AT TIME ZONE 'Asia/Kolkata') AS m",
  );
  const monthStart = monthStartR.rows[0].m;

  const countR = await pgPool.query(
    "SELECT COUNT(*)::int AS c FROM subscription_purchases WHERE user_id = $1 AND plan = $2 AND created_at >= $3 AND created_at < ($3 + INTERVAL '1 month')",
    [userId, plan, monthStart]
  );
  const purchasesThisMonth = Number(countR.rows[0]?.c ?? 0);
  if (purchasesThisMonth >= cap) {
    return res.status(429).json({
      message: "Monthly purchase limit reached",
      detail: "Monthly purchase limit reached",
      cap,
      purchasesThisMonth,
    });
  }

  await pgPool.query(
    "INSERT INTO subscriptions (user_id,pending_plan,status) VALUES ($1,$2,'pending_payment') ON CONFLICT (user_id) DO UPDATE SET pending_plan = EXCLUDED.pending_plan, status = 'pending_payment', updated_at = NOW()",
    [userId, plan]
  );

  res.json({ message: "Plan selected", plan, limit: inc, amount, cap, purchasesThisMonth });
});
app.post("/subscription/confirm-mock-payment", async (req, res) => {
  const userId = String(req.body?.user_id ?? "").trim();
  if (!userId) return res.status(400).json({ message: "User required", detail: "User required" });

  const r = await pgPool.query("SELECT pending_plan FROM subscriptions WHERE user_id = $1", [userId]);
  if (!r.rowCount || !r.rows[0].pending_plan) return res.status(400).json({ message: "No pending plan", detail: "No pending plan" });

  const plan = String(r.rows[0].pending_plan);
  const inc = planIncrement(plan);
  if (!inc) return res.status(400).json({ message: "Invalid plan", detail: "Invalid plan" });

  const maxPlatforms = await getCatalogPlatformCapacity();
  const cap = monthlyPurchaseCap(plan, maxPlatforms);
  const monthStartR = await pgPool.query(
    "SELECT (date_trunc('month', timezone('Asia/Kolkata', NOW())) AT TIME ZONE 'Asia/Kolkata') AS m",
  );
  const monthStart = monthStartR.rows[0].m;

  const countR = await pgPool.query(
    "SELECT COUNT(*)::int AS c FROM subscription_purchases WHERE user_id = $1 AND plan = $2 AND created_at >= $3 AND created_at < ($3 + INTERVAL '1 month')",
    [userId, plan, monthStart]
  );
  const purchasesThisMonth = Number(countR.rows[0]?.c ?? 0);
  if (purchasesThisMonth >= cap) {
    return res.status(429).json({
      message: "Monthly purchase limit reached",
      detail: "Monthly purchase limit reached",
      cap,
      purchasesThisMonth,
    });
  }

  const runtime = await refreshSubscriptionRuntimeState(userId);
  const prevLimit = runtime.limit;
  if (prevLimit >= maxPlatforms) {
    return res.status(409).json({ message: "Platform limit already maxed", detail: "Platform limit already maxed", limit: prevLimit, max: maxPlatforms });
  }
  if (prevLimit + inc > maxPlatforms) {
    return res.status(409).json({ message: "Plan exceeds available platforms", detail: "Plan exceeds available platforms", limit: prevLimit, inc, max: maxPlatforms });
  }

  await pgPool.query(
    "INSERT INTO subscription_purchases (user_id, plan, amount) VALUES ($1,$2,$3)",
    [userId, plan, planAmount(plan)]
  );

  await pgPool.query(
    "UPDATE subscriptions SET pending_plan = NULL, updated_at = NOW() WHERE user_id = $1",
    [userId]
  );

  const nextState = await refreshSubscriptionRuntimeState(userId);

  res.json({
    message: "Payment confirmed",
    plan,
    planLimit: nextState.limit,
    purchasesThisMonth: purchasesThisMonth + 1,
    cap,
    activePlanWindows: nextState.activePlanWindows,
    used: nextState.used,
    remaining: nextState.remaining,
  });
});
app.post("/users/:userId/profile", async (req, res) => {
  const name = String(req.body?.name ?? req.body?.fullName ?? "").trim();
  if (!name) return res.status(400).json({ message: "Name required", detail: "Name required" });
  await pgPool.query("UPDATE users SET name = $1, full_name = $1 WHERE id = $2", [name, req.params.userId]);
  res.json({ message: "Profile updated", name });
});

app.post("/user/profile/password/verify-old", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const oldPassword = String(req.body?.old_password ?? req.body?.oldPassword ?? "");
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  if (!oldPassword) return res.status(400).json({ message: "Old password required", detail: "Old password required" });

  const row = await pgPool.query("SELECT password_hash FROM users WHERE id = $1", [userId]);
  if (!row.rowCount) return res.status(404).json({ message: "User not found", detail: "User not found" });
  const hash = String(row.rows[0].password_hash ?? "");
  const ok = await bcrypt.compare(oldPassword, hash);
  if (!ok) return res.status(401).json({ message: "Invalid old password", detail: "Invalid old password" });

  const token = randomUUID();
  await pgPool.query("DELETE FROM profile_password_verifications WHERE user_id = $1", [userId]);
  await pgPool.query(
    "INSERT INTO profile_password_verifications (token, user_id, expires_at) VALUES ($1,$2,NOW()+INTERVAL '10 minutes')",
    [token, userId]
  );
  res.json({ message: "Old password verified", verifyToken: token });
});

app.post("/user/profile/password/update", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const verifyToken = String(req.body?.verifyToken ?? req.body?.verify_token ?? "");
  const newPassword = String(req.body?.new_password ?? req.body?.newPassword ?? "");
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  if (newPassword.length < 8) return res.status(400).json({ message: "New password too short", detail: "New password too short" });
  if (!verifyToken) return res.status(400).json({ message: "Verify token required", detail: "Verify token required" });

  const v = await pgPool.query(
    "SELECT token FROM profile_password_verifications WHERE user_id = $1 AND token = $2 AND expires_at >= NOW() LIMIT 1",
    [userId, verifyToken]
  );
  if (!v.rowCount) return res.status(401).json({ message: "Old password verification required", detail: "Old password verification required" });

  const hash = await bcrypt.hash(newPassword, 10);
  await pgPool.query("UPDATE users SET password_hash = $1 WHERE id = $2", [hash, userId]);
  await pgPool.query("DELETE FROM profile_password_verifications WHERE user_id = $1", [userId]);
  res.json({ message: "Password updated" });
});

// Backward-compatible path used by older app builds.
app.post("/user/profile/password", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const oldPassword = String(req.body?.old_password ?? req.body?.oldPassword ?? "");
  const newPassword = String(req.body?.new_password ?? req.body?.newPassword ?? "");
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  if (!oldPassword || newPassword.length < 8) {
    return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  }
  const row = await pgPool.query("SELECT password_hash FROM users WHERE id = $1", [userId]);
  if (!row.rowCount) return res.status(404).json({ message: "User not found", detail: "User not found" });
  const hash = String(row.rows[0].password_hash ?? "");
  const ok = await bcrypt.compare(oldPassword, hash);
  if (!ok) return res.status(401).json({ message: "Invalid old password", detail: "Invalid old password" });
  const nextHash = await bcrypt.hash(newPassword, 10);
  await pgPool.query("UPDATE users SET password_hash = $1 WHERE id = $2", [nextHash, userId]);
  await pgPool.query("DELETE FROM profile_password_verifications WHERE user_id = $1", [userId]);
  res.json({ message: "Password updated" });
});

app.post("/user/profile/email/change/request-old-otp", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });

  const u = await pgPool.query("SELECT email FROM users WHERE id = $1", [userId]);
  if (!u.rowCount) return res.status(404).json({ message: "User not found", detail: "User not found" });
  const oldEmail = String(u.rows[0].email ?? "").toLowerCase();

  const flowId = randomUUID();
  const oldOtp = genOtp();
  await pgPool.query(
    "INSERT INTO user_email_change_flows (id, user_id, old_email, old_otp, old_otp_expires_at, status) VALUES ($1,$2,$3,$4,NOW()+INTERVAL '10 minutes','pending_old')",
    [flowId, userId, oldEmail, oldOtp]
  );
  try {
    await sendOtpEmail(oldEmail, oldOtp, "profile-email-old");
  } catch (error) {
    console.error("Failed to send old-email OTP", error);
    return res.status(500).json({ message: "Unable to send OTP email", detail: "Unable to send OTP email" });
  }
  res.json({ message: "OTP sent to old email", flowId, ...(env.OTP_IN_RESPONSE ? { otp: oldOtp } : {}) });
});

app.post("/user/profile/email/change/verify-old", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const flowId = String(req.body?.flowId ?? req.body?.flow_id ?? "");
  const otp = String(req.body?.otp ?? "").trim();
  const newEmail = String(req.body?.newEmail ?? req.body?.new_email ?? "").trim().toLowerCase();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  if (!flowId || !otp || !newEmail) return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(newEmail)) {
    return res.status(400).json({ message: "Invalid email", detail: "Invalid email" });
  }

  const f = await pgPool.query(
    "SELECT id, old_email, old_otp, old_otp_expires_at, status FROM user_email_change_flows WHERE id = $1 AND user_id = $2 LIMIT 1",
    [flowId, userId]
  );
  if (!f.rowCount) return res.status(404).json({ message: "Flow not found", detail: "Flow not found" });
  const flow = f.rows[0] as any;
  if (String(flow.status) !== "pending_old") {
    return res.status(400).json({ message: "Flow already used", detail: "Flow already used" });
  }
  if (String(flow.old_otp ?? "") !== otp || new Date(String(flow.old_otp_expires_at)).getTime() < Date.now()) {
    return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });
  }
  if (String(flow.old_email).toLowerCase() === newEmail) {
    return res.status(400).json({ message: "New email must be different", detail: "New email must be different" });
  }

  const exists = await pgPool.query("SELECT id FROM users WHERE lower(email) = lower($1) LIMIT 1", [newEmail]);
  if (exists.rowCount) return res.status(409).json({ message: "Email already registered", detail: "Email already registered" });

  const newOtp = genOtp();
  await pgPool.query(
    "UPDATE user_email_change_flows SET old_verified = TRUE, new_email = $3, new_otp = $4, new_otp_expires_at = NOW()+INTERVAL '10 minutes', status = 'pending_new', updated_at = NOW() WHERE id = $1 AND user_id = $2",
    [flowId, userId, newEmail, newOtp]
  );
  try {
    await sendOtpEmail(newEmail, newOtp, "profile-email-new");
  } catch (error) {
    console.error("Failed to send new-email OTP", error);
    return res.status(500).json({ message: "Unable to send OTP email", detail: "Unable to send OTP email" });
  }
  res.json({ message: "OTP sent to new email", ...(env.OTP_IN_RESPONSE ? { otp: newOtp } : {}) });
});

app.post("/user/profile/email/change/verify-new", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const flowId = String(req.body?.flowId ?? req.body?.flow_id ?? "");
  const otp = String(req.body?.otp ?? "").trim();
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  if (!flowId || !otp) return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });

  const f = await pgPool.query(
    "SELECT id, new_email, new_otp, new_otp_expires_at, status FROM user_email_change_flows WHERE id = $1 AND user_id = $2 LIMIT 1",
    [flowId, userId]
  );
  if (!f.rowCount) return res.status(404).json({ message: "Flow not found", detail: "Flow not found" });
  const flow = f.rows[0] as any;
  if (String(flow.status) !== "pending_new") {
    return res.status(400).json({ message: "Flow already used", detail: "Flow already used" });
  }
  if (String(flow.new_otp ?? "") !== otp || new Date(String(flow.new_otp_expires_at)).getTime() < Date.now()) {
    return res.status(400).json({ message: "Invalid or expired OTP", detail: "Invalid or expired OTP" });
  }

  const newEmail = String(flow.new_email ?? "").toLowerCase();
  if (!newEmail) return res.status(400).json({ message: "Invalid flow", detail: "Invalid flow" });
  const exists = await pgPool.query("SELECT id FROM users WHERE lower(email) = lower($1) AND id <> $2 LIMIT 1", [newEmail, userId]);
  if (exists.rowCount) return res.status(409).json({ message: "Email already registered", detail: "Email already registered" });

  await pgPool.query("UPDATE users SET email = $1 WHERE id = $2", [newEmail, userId]);
  await pgPool.query(
    "UPDATE user_email_change_flows SET new_verified = TRUE, status = 'completed', updated_at = NOW() WHERE id = $1 AND user_id = $2",
    [flowId, userId]
  );
  res.json({ message: "Email updated", email: newEmail });
});

// Backward-compatible old route. Keeps old builds from breaking.
app.post("/user/profile/email/request", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  const newEmail = String(req.body?.new_email ?? req.body?.newEmail ?? "").trim().toLowerCase();
  if (!userId || !newEmail) return res.status(400).json({ message: "Invalid input", detail: "Invalid input" });
  // Equivalent to first step + verify-old in one go is not secure, so keep route but inform client.
  res.status(400).json({
    message: "Use two-step email change flow",
    detail: "Call /user/profile/email/change/request-old-otp then verify-old and verify-new",
  });
});

app.post("/user/insurance/opt-in", async (req, res) => {
  const userId = (req as AuthRequest).auth?.userId;
  if (!userId) return res.status(401).json({ message: "Unauthorized", detail: "Unauthorized" });
  await pgPool.query("UPDATE users SET gigbit_insurance = TRUE WHERE id = $1", [userId]);
  await safeRedisDel("dashboard:" + userId);
  res.json({ message: "Insured", gigbitInsurance: true });
});

async function processWithdraw(req: express.Request, res: express.Response): Promise<void> {
  const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
  const amount = Number(req.body?.amount ?? 0);
  if (!userId || !(amount > 0)) {
    res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
    return;
  }
  if (amount < 200) {
    res.status(400).json({ message: "Minimum withdrawal is Rs 200", detail: "Minimum withdrawal is Rs 200" });
    return;
  }
  const wdLimit = await getWithdrawalLimitState(userId);
  if (wdLimit.remaining <= 0) {
    res.status(409).json({
      message: "Today's Limit Reached",
      detail: "Today's Limit Reached",
      withdrawalLimitUsed: wdLimit.used,
      withdrawalLimitTotal: wdLimit.totalCap,
      withdrawalLimitAccrued: wdLimit.totalAccrued,
      withdrawalDailyBaseLimit: wdLimit.dailyBaseLimit,
      withdrawalLimitRemaining: wdLimit.remaining,
    });
    return;
  }
  const u = await pgPool.query("SELECT gigbit_insurance FROM users WHERE id = $1", [userId]);
  const insured = Boolean(u.rowCount && u.rows[0].gigbit_insurance);
  const insurance = insured ? round2(amount * 0.01) : 0;
  const fee = 4;
  const totalFee = round2(insurance + fee);
  const r = await pgPool.query(
    "INSERT INTO withdrawals (user_id,amount,insurance_contribution,service_fee,total_fee,user_receives) VALUES ($1,$2,$3,$4,$5,$6) RETURNING *",
    [userId, amount, insurance, fee, totalFee, amount]
  );
  if (insured && insurance > 0) {
    await pgPool.query("INSERT INTO insurance_contributions (user_id,withdrawal_id,amount) VALUES ($1,$2,$3)", [userId, r.rows[0].id, insurance]);
  }
  await safeRedisDel("dashboard:" + userId);
  res.status(201).json({ ...r.rows[0], insurance, service_fee: fee });
}

async function submitClaim(req: express.Request, res: express.Response): Promise<void> {
  try {
    await ensureInsuranceClaimsColumns();
    const userId = (req as AuthRequest).auth?.userId ?? String(req.body?.user_id ?? "").trim();
    const claimTypeRaw = String(req.body?.claimType ?? req.body?.claim_type ?? "").trim();
    const claimType = normalizeMicroInsuranceType(claimTypeRaw);
    const incidentDateRaw = String(req.body?.incidentDate ?? req.body?.incident_date ?? "").trim();
    const proofUrl = String(req.body?.proofUrl ?? req.body?.proof_url ?? "").trim();
    const proofName = String(req.body?.proofName ?? req.body?.proof_name ?? "").trim();
    const description = String(req.body?.description ?? "").trim();
    if (!userId || !claimType || !incidentDateRaw || !proofUrl) {
      res.status(400).json({ message: "Invalid claim", detail: "Invalid claim" });
      return;
    }
    if (proofUrl.length > 12 * 1024 * 1024) {
      res.status(413).json({ message: "Proof document too large", detail: "Proof document too large" });
      return;
    }

    const incidentDate = new Date(incidentDateRaw);
    if (Number.isNaN(incidentDate.getTime())) {
      res.status(400).json({ message: "Invalid incident date", detail: "Invalid incident date" });
      return;
    }
    const dateOnly = incidentDate.toISOString().slice(0, 10);
    const rules = microInsuranceRules(claimType);
    const finalDescription = description || `${claimType} claim for incident on ${dateOnly}`;
    const capR = await pgPool.query(
      `SELECT COUNT(*)::int AS c
       FROM insurance_claims
       WHERE user_id = $1
         AND claim_type = $2
         AND EXTRACT(YEAR FROM incident_date) = EXTRACT(YEAR FROM $3::date)`,
      [userId, claimType, dateOnly]
    );
    const already = Number(capR.rows[0]?.c ?? 0);
    if (already >= rules.annualCap) {
      res.status(409).json({
        message: "Annual claim limit reached",
        detail: "Annual claim limit reached",
        claimType,
        annualCap: rules.annualCap,
      });
      return;
    }
    const r = await pgPool.query(
      `INSERT INTO insurance_claims
        (user_id,claim_type,description,proof_url,proof_name,incident_date,claim_amount,status)
       VALUES ($1,$2,$3,$4,$5,$6,$7,'submitted')
       RETURNING id,user_id,claim_type,description,proof_url,proof_name,incident_date,claim_amount,status,created_at`,
      [userId, claimType, finalDescription, proofUrl, proofName || null, dateOnly, rules.amount]
    );
    res.status(201).json(r.rows[0]);
  } catch (error) {
    console.error("submitClaim failed", error);
    const detail = error instanceof Error ? error.message : "Unable to submit claim";
    res.status(500).json({ message: "Unable to submit claim", detail });
  }
}

async function getPlatforms(userId: string): Promise<string[]> {
  const r = await pgPool.query(
    `SELECT pc.platform
     FROM platform_connections pc
     JOIN integration_platform_catalog c ON lower(c.slug) = lower(pc.platform) AND c.enabled = TRUE
     WHERE pc.user_id = $1
     ORDER BY pc.connected_at DESC`,
    [userId]
  );
  return r.rows.map((x) => String(x.platform));
}

async function getLedger(userId: string): Promise<any[]> {
  const r = await pgPool.query(
    `SELECT id, entry_type, platform, amount, description, created_at FROM (
       SELECT t.id, 'earning'::text AS entry_type, t.platform, t.amount, COALESCE(t.note, 'Earning') AS description, t.created_at
       FROM transactions t
       JOIN integration_platform_catalog c ON lower(c.slug) = lower(t.platform) AND c.enabled = TRUE
       WHERE t.user_id = $1
       UNION ALL
       SELECT id, 'withdrawal'::text AS entry_type, NULL::text AS platform, amount, 'Withdrawal processed'::text AS description, created_at FROM withdrawals WHERE user_id = $1
       UNION ALL
       SELECT id, 'expense'::text AS entry_type, NULL::text AS platform, amount, COALESCE(note, category) AS description, created_at FROM expenses WHERE user_id = $1
     ) x ORDER BY created_at DESC LIMIT 200`,
    [userId]
  );
  return r.rows;
}

async function getWithdrawalLimitState(userId: string): Promise<{
  used: number;
  totalCap: number;
  totalAccrued: number;
  dailyBaseLimit: number;
  remaining: number;
}> {
  const accruedR = await pgPool.query(
    `SELECT
      COALESCE(SUM(
        2 * GREATEST(
          0,
          LEAST(
            30,
            ((timezone('Asia/Kolkata', NOW())::date - timezone('Asia/Kolkata', created_at)::date) + 1)
          )
        )
      ),0)::int AS accrued_total,
      COUNT(*)::int AS purchase_count,
      COALESCE(SUM(
        CASE
          WHEN (timezone('Asia/Kolkata', NOW())::date) BETWEEN timezone('Asia/Kolkata', created_at)::date
            AND (timezone('Asia/Kolkata', created_at)::date + 29)
          THEN 1 ELSE 0
        END
      ),0)::int AS active_window_count
     FROM subscription_purchases
     WHERE user_id = $1`,
    [userId]
  );
  const usedR = await pgPool.query(
    "SELECT COUNT(*)::int AS c FROM withdrawals WHERE user_id = $1 AND COALESCE(user_receives,0) > 0",
    [userId]
  );
  const totalAccrued = Number(accruedR.rows[0]?.accrued_total ?? 0);
  const purchaseCount = Number(accruedR.rows[0]?.purchase_count ?? 0);
  const activeWindowCount = Number(accruedR.rows[0]?.active_window_count ?? 0);
  const totalCap = Math.max(0, purchaseCount * 60);
  const used = Number(usedR.rows[0]?.c ?? 0);
  const remainingByAccrual = Math.max(0, totalAccrued - used);
  const remainingByCap = Math.max(0, totalCap - used);
  return {
    used,
    totalCap,
    totalAccrued,
    dailyBaseLimit: Math.max(0, activeWindowCount * 2),
    remaining: Math.min(remainingByAccrual, remainingByCap),
  };
}

async function getSummary(userId: string): Promise<{
  totalEarnings: number;
  totalWithdrawn: number;
  totalInsuranceContributed: number;
  transactionCount: number;
  expenses: number;
  withdrawalLimitUsed: number;
  withdrawalLimitTotal: number;
  withdrawalLimitAccrued: number;
  withdrawalDailyBaseLimit: number;
  withdrawalLimitRemaining: number;
}> {
  await ensureMonthlyInsuranceAutoDebit(userId);
  const [e, w, i, x, wdLimit] = await Promise.all([
    pgPool.query(
      `SELECT COALESCE(SUM(t.amount),0) AS total, COUNT(*)::int AS count
       FROM transactions t
       JOIN integration_platform_catalog c ON lower(c.slug) = lower(t.platform) AND c.enabled = TRUE
       WHERE t.user_id = $1`,
      [userId]
    ),
    pgPool.query(
      "SELECT COALESCE(SUM(COALESCE(user_receives, amount)),0) AS total FROM withdrawals WHERE user_id = $1",
      [userId]
    ),
    pgPool.query("SELECT COALESCE(SUM(amount),0) AS total FROM insurance_contributions WHERE user_id = $1", [userId]),
    pgPool.query("SELECT COALESCE(SUM(amount),0) AS total FROM expenses WHERE user_id = $1", [userId]),
    getWithdrawalLimitState(userId),
  ]);
  return {
    totalEarnings: Number(e.rows[0].total),
    totalWithdrawn: Number(w.rows[0].total),
    totalInsuranceContributed: Number(i.rows[0].total),
    transactionCount: Number(e.rows[0].count),
    expenses: Number(x.rows[0].total),
    withdrawalLimitUsed: wdLimit.used,
    withdrawalLimitTotal: wdLimit.totalCap,
    withdrawalLimitAccrued: wdLimit.totalAccrued,
    withdrawalDailyBaseLimit: wdLimit.dailyBaseLimit,
    withdrawalLimitRemaining: wdLimit.remaining,
  };
}

async function ensureMonthlyInsuranceAutoDebit(userId: string): Promise<void> {
  const insuranceMonthlyCharge = 50;
  const u = await pgPool.query(
    "SELECT gigbit_insurance FROM users WHERE id = $1",
    [userId],
  );
  if (!u.rowCount || !Boolean(u.rows[0].gigbit_insurance)) return;

  const monthR = await pgPool.query(
    "SELECT (date_trunc('month', timezone('Asia/Kolkata', NOW())) AT TIME ZONE 'Asia/Kolkata') AS m",
  );
  const monthStart = monthR.rows[0].m;
  const nextMonthR = await pgPool.query("SELECT ($1::timestamptz + INTERVAL '1 month') AS m", [monthStart]);
  const nextMonthStart = nextMonthR.rows[0].m;

  const exists = await pgPool.query(
    "SELECT 1 FROM withdrawals WHERE user_id = $1 AND created_at >= $2 AND created_at < $3 AND insurance_contribution > 0 AND service_fee = 0 AND user_receives = 0 LIMIT 1",
    [userId, monthStart, nextMonthStart],
  );
  if (exists.rowCount) return;

  const w = await pgPool.query(
    "INSERT INTO withdrawals (user_id,amount,insurance_contribution,service_fee,total_fee,user_receives,created_at) VALUES ($1,$2,$2,0,$2,0,NOW()) RETURNING id",
    [userId, insuranceMonthlyCharge],
  );
  await pgPool.query(
    "INSERT INTO insurance_contributions (user_id,withdrawal_id,amount,created_at) VALUES ($1,$2,$3,NOW())",
    [userId, w.rows[0].id, insuranceMonthlyCharge],
  );
  await safeRedisDel("dashboard:" + userId);
}

type LoanEligibilityState = {
  score: number;
  limit: number;
  minAmount: number;
  maxAmount: number;
  annualInterestRate: number;
  conditionsMet: number;
  totalConditions: number;
  tenureDays: number;
  monthsWorked: number;
  consideredDays: number;
  workedDays: number;
  daysWithMinEarnings: number;
  totalEarnings: number;
  avgEarningsPerWorkedDay: number;
  met1: boolean;
  met2: boolean;
  met3: boolean;
};

async function getLoan(userId: string): Promise<LoanEligibilityState> {
  const nowR = await pgPool.query(
    "SELECT (NOW() AT TIME ZONE 'Asia/Kolkata')::date AS today_ist_date"
  );
  const userR = await pgPool.query(
    "SELECT (created_at AT TIME ZONE 'Asia/Kolkata')::date AS user_start_ist_date FROM users WHERE id = $1 LIMIT 1",
    [userId]
  );
  const today = new Date(String(nowR.rows[0]?.today_ist_date));
  const userStart = userR.rowCount
    ? new Date(String(userR.rows[0]?.user_start_ist_date))
    : today;

  const tenureDays = Math.max(
    1,
    Math.floor((today.getTime() - userStart.getTime()) / (24 * 60 * 60 * 1000)) + 1,
  );
  const working90DaysMet = tenureDays >= 90;

  const windowStart = new Date(today);
  windowStart.setDate(windowStart.getDate() - 89);
  const effectiveStart = windowStart > userStart ? windowStart : userStart;
  const consideredDays = Math.max(
    1,
    Math.floor((today.getTime() - effectiveStart.getTime()) / (24 * 60 * 60 * 1000)) + 1,
  );

  const dailyR = await pgPool.query(
    `SELECT (created_at AT TIME ZONE 'Asia/Kolkata')::date AS d, COALESCE(SUM(amount),0)::numeric AS total
     FROM transactions
     WHERE user_id = $1
       AND (created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN $2::date AND $3::date
     GROUP BY (created_at AT TIME ZONE 'Asia/Kolkata')::date`,
    [userId, effectiveStart.toISOString().slice(0, 10), today.toISOString().slice(0, 10)]
  );

  let workedDays = 0;
  let daysWithMinEarnings = 0;
  let totalEarnings = 0;
  for (const row of dailyR.rows as any[]) {
    const total = Number(row.total ?? 0);
    if (total > 0) workedDays += 1;
    if (total >= 800) daysWithMinEarnings += 1;
    totalEarnings += total;
  }
  const avgEarningsPerWorkedDay = workedDays ? totalEarnings / workedDays : 0;
  const monthsWorked = tenureDays / 30;

  const c1Progress = Math.max(0, Math.min(1, tenureDays / 90));
  const c2Progress = Math.max(0, Math.min(1, workedDays / 75));
  const c3Progress = Math.max(0, Math.min(1, daysWithMinEarnings / 75));
  const score = Math.round(c1Progress * 300 + c2Progress * 350 + c3Progress * 350);

  const met1 = working90DaysMet;
  const met2 = workedDays >= 75;
  const met3 = daysWithMinEarnings >= 75;
  const conditionsMet = Number(met1) + Number(met2) + Number(met3);
  const annualInterestRate = annualLoanRatePercentByConditions(conditionsMet);

  return {
    score: Math.max(0, Math.min(1000, score)),
    limit: LOAN_MAX_AMOUNT,
    minAmount: LOAN_MIN_AMOUNT,
    maxAmount: LOAN_MAX_AMOUNT,
    annualInterestRate,
    conditionsMet,
    totalConditions: 3,
    tenureDays,
    monthsWorked,
    consideredDays,
    workedDays,
    daysWithMinEarnings,
    totalEarnings: round2(totalEarnings),
    avgEarningsPerWorkedDay: round2(avgEarningsPerWorkedDay),
    met1,
    met2,
    met3,
  };
}

function registerVerifiedKey(email: string): string {
  return "register:verified:" + email;
}

async function markRegisterVerified(email: string): Promise<void> {
  registerVerifiedMemory.set(email, Date.now() + 15 * 60 * 1000);
  if (!redis?.isOpen) return;
  try {
    await redis.set(registerVerifiedKey(email), "1", { EX: 900 });
  } catch {
    // ignore when Redis is unavailable
  }
}

async function isRegisterVerified(email: string): Promise<boolean> {
  const mem = registerVerifiedMemory.get(email);
  if (mem && mem > Date.now()) return true;
  if (mem) registerVerifiedMemory.delete(email);

  if (!redis?.isOpen) return false;
  try {
    return (await redis.get(registerVerifiedKey(email))) === "1";
  } catch {
    return false;
  }
}

async function clearRegisterVerified(email: string): Promise<void> {
  registerVerifiedMemory.delete(email);
  if (!redis?.isOpen) return;
  try {
    await redis.del(registerVerifiedKey(email));
  } catch {
    // ignore when Redis is unavailable
  }
}

async function safeRedisDel(key: string): Promise<void> {
  if (!redis?.isOpen) return;
  try {
    await redis.del(key);
  } catch {
    // ignore when Redis is unavailable
  }
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

function genOtp(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
}

async function setOtp(email: string, otp: string): Promise<void> {
  await pgPool.query(
    "INSERT INTO password_reset_otps (email,otp,expires_at) VALUES ($1,$2,NOW()+INTERVAL '10 minutes') ON CONFLICT (email) DO UPDATE SET otp = EXCLUDED.otp, expires_at = EXCLUDED.expires_at, created_at = NOW()",
    [email, otp]
  );
}

async function checkOtp(email: string, otp: string): Promise<boolean> {
  const row = await pgPool.query("SELECT otp, expires_at FROM password_reset_otps WHERE email = $1", [email]);
  if (!row.rowCount) return false;
  const found = row.rows[0] as { otp: string; expires_at: string };
  return found.otp === otp && new Date(found.expires_at).getTime() >= Date.now();
}

async function clearOtp(email: string): Promise<void> {
  await pgPool.query("DELETE FROM password_reset_otps WHERE email = $1", [email]);
}


async function deleteUserHard(userId: string): Promise<void> {
  const client = await pgPool.connect();
  try {
    await client.query("BEGIN");

    // Delete dependent records explicitly for legacy schemas without ON DELETE CASCADE.
    await client.query("DELETE FROM platform_connections WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM platform_earnings WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM insurance_contributions WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM insurance_claims WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM loans WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM expenses WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM support_tickets WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM subscriptions WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM withdrawals WHERE user_id = $1", [userId]);
    await client.query("DELETE FROM transactions WHERE user_id = $1", [userId]);

    await client.query("DELETE FROM users WHERE id = $1", [userId]);

    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }

  await safeRedisDel("dashboard:" + userId);
}

app.get("/admin/account-deletions", requireAdminKey, async (req, res) => {
  const status = String(req.query?.status ?? "pending").trim().toLowerCase();
  const allowed = new Set(["pending", "approved", "rejected"]);
  const st = allowed.has(status) ? status : "pending";

  const r = await pgPool.query(
    "SELECT id, user_id, user_email, reason_code, reason_text, status, created_at, reviewed_at FROM account_deletion_requests WHERE status = $1 ORDER BY created_at DESC LIMIT 200",
    [st]
  );

  res.json({ items: r.rows });
});

app.post("/admin/account-deletions/:id/approve", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  if (!id) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });

  const note = String(req.body?.adminNote ?? req.body?.admin_note ?? "").trim();
  const reviewedBy = String(req.body?.reviewedBy ?? req.body?.reviewed_by ?? "admin").trim();

  const client = await pgPool.connect();
  try {
    await client.query("BEGIN");
    const row = await client.query(
      "SELECT id, user_id, status FROM account_deletion_requests WHERE id = $1 FOR UPDATE",
      [id]
    );
    if (!row.rowCount) {
      await client.query("ROLLBACK");
      return res.status(404).json({ message: "Not found", detail: "Not found" });
    }
    const reqRow = row.rows[0] as { user_id: string; status: string };

    await client.query(
      "UPDATE account_deletion_requests SET status = 'approved', reviewed_at = NOW(), reviewed_by = $2, admin_note = $3 WHERE id = $1",
      [id, reviewedBy, note || null]
    );
    await client.query("COMMIT");

    // Notify user first, then permanently delete shortly after.
    publishUserApprovalUpdate(String(reqRow.user_id), "account_deletion_status", {
      requestId: id,
      status: "approved",
      reviewedBy,
    });
    setTimeout(() => {
      deleteUserHard(String(reqRow.user_id)).catch((e) => {
        console.error("Failed to delete user after approval", e);
      });
    }, 2000);
    await logAdminActivity(req, "account_deletion.approve", {
      requestId: id,
      userId: String(reqRow.user_id),
      reviewedBy,
    });

    res.json({ message: "Approved" });
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
});

app.post("/admin/account-deletions/:id/reject", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  if (!id) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });

  const note = String(req.body?.adminNote ?? req.body?.admin_note ?? "").trim();
  const reviewedBy = String(req.body?.reviewedBy ?? req.body?.reviewed_by ?? "admin").trim();

  await pgPool.query(
    "UPDATE account_deletion_requests SET status = 'rejected', reviewed_at = NOW(), reviewed_by = $2, admin_note = $3 WHERE id = $1",
    [id, reviewedBy, note || null]
  );
  const row = await pgPool.query(
    "SELECT user_id FROM account_deletion_requests WHERE id = $1",
    [id]
  );
  const userId = String(row.rows[0]?.user_id ?? "").trim();
  if (userId) {
    publishUserApprovalUpdate(userId, "account_deletion_status", {
      requestId: id,
      status: "rejected",
      reviewedBy,
    });
  }
  await logAdminActivity(req, "account_deletion.reject", { requestId: id, reviewedBy });

  res.json({ message: "Rejected" });
});

app.get("/admin/loans", requireAdminKey, async (req, res) => {
  const status = String(req.query?.status ?? "").trim().toLowerCase();
  const where = status ? "WHERE lower(l.status) = lower($1)" : "";
  const params = status ? [status] : [];
  const r = await pgPool.query(
    `SELECT
      l.id,
      l.user_id,
      l.amount,
      l.tenure_months,
      l.monthly_installment,
      l.annual_interest_rate,
      l.status,
      l.proof_url,
      l.created_at,
      u.email,
      COALESCE(NULLIF(u.name,''), u.full_name) AS full_name,
      u.username
     FROM loans l
     LEFT JOIN users u ON u.id = l.user_id
     ${where}
     ORDER BY l.created_at DESC
     LIMIT 400`,
    params
  );
  res.json({ items: r.rows });
});

app.get("/admin/loan-eligibility/:userId", requireAdminKey, async (req, res) => {
  const userId = String(req.params.userId ?? "").trim();
  if (!userId) {
    return res.status(400).json({ message: "Invalid user", detail: "Invalid user" });
  }
  const eligibility = await getLoan(userId);
  res.json({
    userId,
    score: eligibility.score,
    conditionsMet: eligibility.conditionsMet,
    totalConditions: eligibility.totalConditions,
    annualInterestRate: eligibility.annualInterestRate,
  });
});

app.get("/admin/loans/:id/repayments", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  if (!id) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }
  const loanR = await pgPool.query(
    `SELECT id, user_id, tenure_months, monthly_installment, created_at
     FROM loans
     WHERE id = $1
     LIMIT 1`,
    [id]
  );
  if (!loanR.rowCount) {
    return res.status(404).json({ message: "Not found", detail: "Not found" });
  }
  const loan = loanR.rows[0] as any;
  const tenureMonths = Math.max(0, Number(loan.tenure_months || 0));
  const installmentAmount = Number(loan.monthly_installment || 0);

  const payR = await pgPool.query(
    `SELECT installment_no, paid_at
     FROM loan_repayments
     WHERE loan_id = $1
     ORDER BY installment_no ASC`,
    [id]
  );
  const paidByInstallment = new Map<number, string>();
  for (const row of payR.rows as any[]) {
    const no = Number(row.installment_no || 0);
    if (no > 0 && !paidByInstallment.has(no)) {
      paidByInstallment.set(no, String(row.paid_at ?? ""));
    }
  }

  const baseDate = new Date(String(loan.created_at ?? new Date().toISOString()));
  const schedule = Array.from({ length: tenureMonths }, (_, idx) => {
    const installmentNo = idx + 1;
    const due = new Date(baseDate);
    due.setMonth(due.getMonth() + idx);
    const paidAt = paidByInstallment.get(installmentNo) || null;
    return {
      installmentNo,
      monthLabel: due.toISOString().slice(0, 7),
      amount: installmentAmount,
      status: paidAt ? "paid" : "pending",
      paidAt,
    };
  });

  res.json({
    loanId: String(loan.id),
    tenureMonths,
    installmentAmount,
    schedule,
  });
});

app.post("/admin/loans/:id/status", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const status = String(req.body?.status ?? "").trim().toLowerCase();
  const allowed = new Set(["approved", "rejected", "pending"]);
  if (!id || !allowed.has(status)) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }
  const r = await pgPool.query(
    "UPDATE loans SET status = $2 WHERE id = $1 RETURNING id, user_id, amount, status, created_at",
    [id, status]
  );
  if (!r.rowCount) return res.status(404).json({ message: "Not found", detail: "Not found" });
  const item = r.rows[0] as any;
  publishUserApprovalUpdate(String(item.user_id), "loan_status", {
    loanId: String(item.id),
    status: String(item.status ?? status),
    amount: Number(item.amount ?? 0),
  });
  await logAdminActivity(req, "loan.status.update", {
    loanId: String(item.id),
    userId: String(item.user_id),
    amount: Number(item.amount ?? 0),
    status: String(item.status ?? status),
  });
  res.json({ message: "Updated", item: r.rows[0] });
});

app.get("/admin/insurance-claims", requireAdminKey, async (req, res) => {
  const status = String(req.query?.status ?? "").trim().toLowerCase();
  const where = status ? "WHERE lower(c.status) = lower($1)" : "";
  const params = status ? [status] : [];
  const r = await pgPool.query(
    `SELECT
     c.id,
     c.user_id,
     c.claim_type,
      c.claim_amount AS amount,
      c.incident_date,
      c.description,
      c.proof_url,
      c.status,
      c.created_at,
      u.email,
      COALESCE(NULLIF(u.name,''), u.full_name) AS full_name,
      u.username
     FROM insurance_claims c
     LEFT JOIN users u ON u.id = c.user_id
     ${where}
     ORDER BY c.created_at DESC
     LIMIT 400`,
    params
  );
  res.json({ items: r.rows });
});

app.post("/admin/insurance-claims/:id/status", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const status = String(req.body?.status ?? "").trim().toLowerCase();
  const allowed = new Set(["approved", "rejected", "submitted"]);
  if (!id || !allowed.has(status)) {
    return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  }
  const r = await pgPool.query(
    "UPDATE insurance_claims SET status = $2 WHERE id = $1 RETURNING id, user_id, claim_type, status, created_at",
    [id, status]
  );
  if (!r.rowCount) return res.status(404).json({ message: "Not found", detail: "Not found" });
  const item = r.rows[0] as any;
  publishUserApprovalUpdate(String(item.user_id), "insurance_status", {
    claimId: String(item.id),
    status: String(item.status ?? status),
    claimType: String(item.claim_type ?? ""),
  });
  await logAdminActivity(req, "insurance_claim.status.update", {
    claimId: String(item.id),
    userId: String(item.user_id),
    claimType: String(item.claim_type ?? ""),
    status: String(item.status ?? status),
  });
  res.json({ message: "Updated", item: r.rows[0] });
});

app.get("/admin/activity-logs", requireAdminKey, async (req, res) => {
  const rawLimit = Number(req.query?.limit ?? 80);
  const limit = Number.isFinite(rawLimit) ? Math.max(1, Math.min(300, Math.floor(rawLimit))) : 80;
  const r = await pgPool.query(
    `SELECT id, actor_username, action, details, created_at
     FROM admin_activity_logs
     ORDER BY created_at DESC
     LIMIT $1`,
    [limit]
  );
  res.json({ items: r.rows });
});

app.get("/admin/support-tickets", requireAdminKey, async (req, res) => {
  const rawLimit = Number(req.query?.limit ?? 500);
  const limit = Number.isFinite(rawLimit) ? Math.max(1, Math.min(2000, Math.floor(rawLimit))) : 500;
  const r = await pgPool.query(
    `SELECT
      s.id,
      s.ticket_number,
      s.user_id,
      s.complaint,
      s.created_at,
      u.email,
      COALESCE(NULLIF(u.name,''), u.full_name) AS full_name,
      u.username
     FROM support_tickets s
     LEFT JOIN users u ON u.id = s.user_id
     ORDER BY s.created_at DESC
     LIMIT $1`,
    [limit]
  );
  res.json({ items: r.rows });
});

app.get("/admin/withdrawals", requireAdminKey, async (_req, res) => {
  const [r, totals, claimsStats] = await Promise.all([
    pgPool.query(
      `SELECT
        w.id,
        w.user_id,
        w.amount,
        w.insurance_contribution,
        w.service_fee,
        w.total_fee,
        w.user_receives,
        w.created_at,
        u.email,
        COALESCE(NULLIF(u.name,''), u.full_name) AS full_name,
        u.username
       FROM withdrawals w
       LEFT JOIN users u ON u.id = w.user_id
       WHERE COALESCE(w.user_receives, 0) > 0
       ORDER BY w.created_at DESC
       LIMIT 1000`
    ),
    pgPool.query(
      `SELECT
        COALESCE(SUM(COALESCE(user_receives, amount)),0) AS total_withdrawn,
        COALESCE(SUM(insurance_contribution),0) AS total_insurance,
        COALESCE(SUM(service_fee),0) AS total_fees,
        (SELECT COUNT(*)::int FROM users) AS total_users,
        (
          WITH wd_used AS (
            SELECT w.user_id, COUNT(*)::int AS used
            FROM withdrawals w
            WHERE COALESCE(w.user_receives,0) > 0
            GROUP BY w.user_id
          ),
          purchases AS (
            SELECT
              sp.user_id,
              COUNT(*)::int AS purchase_count,
              COALESCE(SUM(
                2 * GREATEST(
                  0,
                  LEAST(
                    30,
                    ((timezone('Asia/Kolkata', NOW())::date - timezone('Asia/Kolkata', sp.created_at)::date) + 1)
                  )
                )
              ),0)::int AS accrued_total,
              COALESCE(SUM(
                CASE
                  WHEN (timezone('Asia/Kolkata', NOW())::date) BETWEEN timezone('Asia/Kolkata', sp.created_at)::date
                    AND (timezone('Asia/Kolkata', sp.created_at)::date + 29)
                  THEN 1 ELSE 0
                END
              ),0)::int AS active_window_count
            FROM subscription_purchases sp
            GROUP BY sp.user_id
          ),
          limits AS (
            SELECT
              u.id AS user_id,
              COALESCE(p.active_window_count, 0) AS active_window_count,
              LEAST(
                GREATEST(0, COALESCE(p.accrued_total, 0) - COALESCE(wu.used, 0)),
                GREATEST(0, (COALESCE(p.purchase_count, 0) * 60) - COALESCE(wu.used, 0))
              )::int AS remaining_limit
            FROM users u
            LEFT JOIN purchases p ON p.user_id = u.id
            LEFT JOIN wd_used wu ON wu.user_id = u.id
          )
          SELECT COUNT(*)::int
          FROM limits l
          WHERE l.active_window_count > 0 OR l.remaining_limit > 0
        ) AS total_active_users
       FROM withdrawals
       WHERE COALESCE(user_receives, 0) > 0`
    ),
    pgPool.query(
      `SELECT
        COUNT(*)::int AS approved_claims_count,
        COALESCE(SUM(claim_amount), 0) AS claimed_insurance_amount
       FROM insurance_claims
       WHERE lower(status) = 'approved'`
    ),
  ]);
  const totalsRow = totals.rows[0] ?? {};
  const claimsRow = claimsStats.rows[0] ?? {};
  res.json({
    items: r.rows,
    totals: {
      ...totalsRow,
      claimed_insurance_amount: Number((claimsRow as any).claimed_insurance_amount ?? 0),
      approved_claims_count: Number((claimsRow as any).approved_claims_count ?? 0),
    },
  });
});

app.get("/admin/insurance-contributions", requireAdminKey, async (_req, res) => {
  const r = await pgPool.query(
    `SELECT
      ic.id,
      ic.user_id,
      ic.amount,
     ic.created_at,
     u.email,
     COALESCE(NULLIF(u.name,''), u.full_name) AS full_name,
     u.username
     FROM insurance_contributions ic
     LEFT JOIN users u ON u.id = ic.user_id
     ORDER BY ic.created_at DESC`
  );
  const totals = await pgPool.query(
    `SELECT COALESCE(SUM(amount),0) AS total_contributions
     FROM insurance_contributions`
  );
  res.json({
    items: r.rows,
    totals: {
      total_contributions: Number(totals.rows[0]?.total_contributions ?? 0),
    },
  });
});

app.get("/admin/commission-share", requireAdminKey, async (req, res) => {
  const monthRaw = String(req.query?.month ?? "").trim();
  const m = /^(\d{4})-(\d{2})$/.exec(monthRaw);
  const monthYear = m ? Number(m[1]) : null;
  const monthNum = m ? Number(m[2]) : null;
  const useRequestedMonth =
    monthYear != null &&
    Number.isInteger(monthYear) &&
    monthNum != null &&
    Number.isInteger(monthNum) &&
    monthNum >= 1 &&
    monthNum <= 12;
  const monthBoundsSql = useRequestedMonth
    ? "make_timestamptz($1,$2,1,0,0,0,'Asia/Kolkata') AS m_start, (make_timestamptz($1,$2,1,0,0,0,'Asia/Kolkata') + INTERVAL '1 month') AS m_end"
    : "(date_trunc('month', timezone('Asia/Kolkata', NOW())) AT TIME ZONE 'Asia/Kolkata') AS m_start, ((date_trunc('month', timezone('Asia/Kolkata', NOW())) + INTERVAL '1 month') AT TIME ZONE 'Asia/Kolkata') AS m_end";
  const monthParams = useRequestedMonth ? [monthYear!, monthNum!] : [];

  const byPlatform = await pgPool.query(
    `WITH month_bounds AS (SELECT ${monthBoundsSql}),
     eligible_purchases AS (
       SELECT
         sp.user_id,
         lower(sp.plan) AS plan,
         sp.created_at
       FROM subscription_purchases sp
       CROSS JOIN month_bounds mb
       WHERE sp.created_at < mb.m_end
         AND (sp.created_at + INTERVAL '30 days') > mb.m_start
     ),
     user_month_plan AS (
       SELECT p.user_id, p.plan
       FROM eligible_purchases p
       JOIN (
         SELECT ep.user_id, MAX(ep.created_at) AS latest_created_at
         FROM eligible_purchases ep
         GROUP BY ep.user_id
       ) x ON x.user_id = p.user_id AND x.latest_created_at = p.created_at
     ),
     rated_users AS (
       SELECT
         ap.user_id,
         CASE
           WHEN ap.plan = 'solo' THEN 10
           WHEN ap.plan = 'duo' THEN 13
           WHEN ap.plan = 'trio' THEN 15
           WHEN ap.plan = 'unity' THEN 15
           ELSE 0
         END::int AS rate
       FROM user_month_plan ap
     ),
     platform_commission AS (
       SELECT
         lower(pc.platform) AS platform,
         COALESCE(SUM(ru.rate), 0)::int AS commission,
         COUNT(DISTINCT pc.user_id)::int AS users_count
       FROM platform_connection_history pc
       JOIN rated_users ru ON ru.user_id = pc.user_id
       WHERE ru.rate > 0
       GROUP BY lower(pc.platform)
     ),
     historical_platforms AS (
       SELECT
         lower(platform) AS platform,
         MIN(first_connected_at) AS start_date
       FROM platform_connection_history
       GROUP BY lower(platform)
     )
     SELECT
       lower(c.slug) AS platform,
       COALESCE(pc.commission, 0)::int AS commission,
       COALESCE(pc.users_count, 0)::int AS users_count,
       hp.start_date
     FROM integration_platform_catalog c
     JOIN historical_platforms hp ON hp.platform = lower(c.slug)
     LEFT JOIN platform_commission pc ON pc.platform = lower(c.slug)
     ORDER BY lower(c.slug) ASC`,
    monthParams
  );

  // Calendar-month (IST) revenue/cost model:
  // - Subscription amount: SUM(subscription purchase amount)
  // - Transaction charge: actual SUM(service_fee) from withdrawals in month
  const totals = await pgPool.query(
    `WITH month_bounds AS (SELECT ${monthBoundsSql})
     SELECT
       COALESCE((
         SELECT SUM(sp.amount)
         FROM subscription_purchases sp
         CROSS JOIN month_bounds mb
         WHERE sp.created_at >= mb.m_start
           AND sp.created_at < mb.m_end
       ),0)::int AS subscription_amount_total,
       COALESCE((
         SELECT SUM(w.service_fee)
         FROM withdrawals w
         CROSS JOIN month_bounds mb
         WHERE w.created_at >= mb.m_start
           AND w.created_at < mb.m_end
       ),0)::int AS transaction_charge_total,
       COALESCE((
         SELECT SUM(
           CASE
             WHEN lower(sp.plan) = 'solo' THEN 15
             WHEN lower(sp.plan) = 'duo' THEN 24
             WHEN lower(sp.plan) = 'trio' THEN 30
             WHEN lower(sp.plan) = 'unity' THEN 30
             ELSE 0
           END
         )
         FROM subscription_purchases sp
         CROSS JOIN month_bounds mb
         WHERE sp.created_at >= mb.m_start
           AND sp.created_at < mb.m_end
       ),0)::int AS profit_total`,
    monthParams
  );

  const monthsR = await pgPool.query(
    `SELECT to_char(month_key, 'YYYY-MM') AS month
     FROM (
       SELECT date_trunc('month', timezone('Asia/Kolkata', NOW())) AS month_key
       UNION
       SELECT date_trunc('month', timezone('Asia/Kolkata', sp.created_at)) AS month_key
       FROM subscription_purchases sp
       UNION
       SELECT date_trunc('month', timezone('Asia/Kolkata', w.created_at)) AS month_key
       FROM withdrawals w
     ) x
     ORDER BY month_key DESC
     LIMIT 36`
  );
  const availableMonths = monthsR.rows.map((x: any) => String(x.month ?? "")).filter(Boolean);
  const selectedMonth = useRequestedMonth
    ? `${monthYear}-${String(monthNum).padStart(2, "0")}`
    : (availableMonths[0] ?? "");

  const items = byPlatform.rows.map((r: any) => ({
    platform: String(r.platform ?? ""),
    commission: Number(r.commission ?? 0),
    usersCount: Number(r.users_count ?? 0),
    startDate: r.start_date ?? null,
  }));
  const totalCommission = items.reduce((s, x) => s + Number(x.commission || 0), 0);
  const subscriptionAmountTotal = Number(totals.rows[0]?.subscription_amount_total ?? 0);
  const transactionChargeTotal = Number(totals.rows[0]?.transaction_charge_total ?? 0);
  const profit = Number(totals.rows[0]?.profit_total ?? 0);

  res.json({
    items,
    totalCommission,
    subscriptionAmountTotal,
    transactionChargeTotal,
    profit,
    selectedMonth,
    availableMonths,
  });
});

app.get("/admin/platforms", requireAdminKey, async (_req, res) => {
  const r = await pgPool.query(
    "SELECT id, slug, name, logo_url, logo_bg_color, enabled, sort_order, created_at, updated_at FROM integration_platform_catalog ORDER BY sort_order ASC, created_at ASC"
  );
  res.json({ items: r.rows });
});

app.post("/admin/platforms", requireAdminKey, async (req, res) => {
  const name = String(req.body?.name ?? "").trim();
  const logoUrl = String(req.body?.logoUrl ?? req.body?.logo_url ?? "").trim();
  const logoBgColor = String(req.body?.logoBgColor ?? req.body?.logo_bg_color ?? "#1E3A8A").trim();
  const enabled = req.body?.enabled == null ? true : Boolean(req.body.enabled);
  if (!name) return res.status(400).json({ message: "Name is required", detail: "Name is required" });
  const slug = slugifyPlatformName(name);
  if (!slug) return res.status(400).json({ message: "Invalid platform name", detail: "Invalid platform name" });

  const maxSortR = await pgPool.query("SELECT COALESCE(MAX(sort_order),0)::int AS m FROM integration_platform_catalog");
  const nextSort = Number(maxSortR.rows[0]?.m ?? 0) + 1;
  const r = await pgPool.query(
    "INSERT INTO integration_platform_catalog (slug, name, logo_url, logo_bg_color, enabled, sort_order, updated_at) VALUES ($1,$2,$3,$4,$5,$6,NOW()) RETURNING id, slug, name, logo_url, logo_bg_color, enabled, sort_order, created_at, updated_at",
    [slug, name, logoUrl || null, logoBgColor || "#1E3A8A", enabled, nextSort]
  );
  await logAdminActivity(req, "platform.create", {
    platformId: String(r.rows[0].id),
    slug: String(r.rows[0].slug),
    name: String(r.rows[0].name),
    enabled: Boolean(r.rows[0].enabled),
  });
  publishPlatformCatalogChanged();
  res.status(201).json({ message: "Platform created", item: r.rows[0] });
});

app.put("/admin/platforms/:id", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  const name = String(req.body?.name ?? "").trim();
  const logoUrl = String(req.body?.logoUrl ?? req.body?.logo_url ?? "").trim();
  const logoBgColor = String(req.body?.logoBgColor ?? req.body?.logo_bg_color ?? "").trim();
  const enabled = req.body?.enabled;
  if (!id) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });

  const current = await pgPool.query("SELECT id, slug, name, logo_url, logo_bg_color, enabled FROM integration_platform_catalog WHERE id = $1", [id]);
  if (!current.rowCount) return res.status(404).json({ message: "Not found", detail: "Not found" });
  const c = current.rows[0] as any;
  const nextName = name || String(c.name);
  // Keep slug stable so existing user/platform mappings remain intact.
  const nextSlug = String(c.slug);
  const nextLogo = logoUrl === "" ? c.logo_url : logoUrl;
  const nextBg = logoBgColor || String(c.logo_bg_color ?? "#1E3A8A");
  const nextEnabled = enabled == null ? Boolean(c.enabled) : Boolean(enabled);

  const r = await pgPool.query(
    "UPDATE integration_platform_catalog SET slug = $2, name = $3, logo_url = $4, logo_bg_color = $5, enabled = $6, updated_at = NOW() WHERE id = $1 RETURNING id, slug, name, logo_url, logo_bg_color, enabled, sort_order, created_at, updated_at",
    [id, nextSlug, nextName, nextLogo || null, nextBg, nextEnabled]
  );
  await logAdminActivity(req, "platform.update", {
    platformId: String(r.rows[0].id),
    slug: String(r.rows[0].slug),
    name: String(r.rows[0].name),
    enabled: Boolean(r.rows[0].enabled),
  });
  publishPlatformCatalogChanged();
  res.json({ message: "Platform updated", item: r.rows[0] });
});

app.post("/admin/platforms/:id/toggle", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  if (!id) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  const r = await pgPool.query(
    "UPDATE integration_platform_catalog SET enabled = NOT enabled, updated_at = NOW() WHERE id = $1 RETURNING id, slug, name, logo_url, logo_bg_color, enabled, sort_order, created_at, updated_at",
    [id]
  );
  if (!r.rowCount) return res.status(404).json({ message: "Not found", detail: "Not found" });
  await logAdminActivity(req, "platform.toggle", {
    platformId: String(r.rows[0].id),
    slug: String(r.rows[0].slug),
    name: String(r.rows[0].name),
    enabled: Boolean(r.rows[0].enabled),
  });
  publishPlatformCatalogChanged();
  res.json({ message: "Platform toggled", item: r.rows[0] });
});

app.delete("/admin/platforms/:id", requireAdminKey, async (req, res) => {
  const id = String(req.params.id ?? "").trim();
  if (!id) return res.status(400).json({ message: "Invalid request", detail: "Invalid request" });
  const existing = await pgPool.query("SELECT id, slug, name FROM integration_platform_catalog WHERE id = $1", [id]);
  if (!existing.rowCount) return res.status(404).json({ message: "Not found", detail: "Not found" });
  const ex = existing.rows[0] as any;
  await pgPool.query("DELETE FROM integration_platform_catalog WHERE id = $1", [id]);
  await logAdminActivity(req, "platform.delete", {
    platformId: String(ex.id),
    slug: String(ex.slug ?? ""),
    name: String(ex.name ?? ""),
  });
  publishPlatformCatalogChanged();
  res.json({ message: "Platform deleted" });
});

async function ensureSchema(): Promise<void> {
  const userIdTypeRow = await pgPool.query(
    "SELECT data_type FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'id' LIMIT 1"
  );
  const userIdType =
    userIdTypeRow.rowCount &&
    String(userIdTypeRow.rows[0].data_type).toLowerCase().includes("int")
      ? "INTEGER"
      : "UUID";

  const statements = [
    "CREATE EXTENSION IF NOT EXISTS pgcrypto",
    // Core tables for fresh database bootstrap (Render/Postgres empty DB).
    "CREATE TABLE IF NOT EXISTS users (id " + userIdType + " PRIMARY KEY, email TEXT NOT NULL UNIQUE, username TEXT, password_hash TEXT NOT NULL, full_name TEXT, name TEXT NOT NULL DEFAULT '', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS transactions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, platform TEXT NOT NULL, amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), note TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS withdrawals (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), insurance_contribution NUMERIC(12,2) NOT NULL CHECK (insurance_contribution >= 0), service_fee NUMERIC(12,2) NOT NULL CHECK (service_fee >= 0), total_fee NUMERIC(12,2) NOT NULL CHECK (total_fee >= 0), user_receives NUMERIC(12,2) NOT NULL CHECK (user_receives >= 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS insurance_contributions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, withdrawal_id UUID NOT NULL REFERENCES withdrawals(id) ON DELETE CASCADE, amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS insurance_claims (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, claim_type TEXT NOT NULL, description TEXT NOT NULL, proof_url TEXT, proof_name TEXT, incident_date DATE, claim_amount NUMERIC(12,2) NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'submitted', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS platform_connections (user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, platform TEXT NOT NULL, connected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY (user_id, platform))",
    "CREATE TABLE IF NOT EXISTS platform_connection_history (user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, platform TEXT NOT NULL, first_connected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY (user_id, platform))",
    "CREATE TABLE IF NOT EXISTS integration_platform_catalog (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), slug TEXT NOT NULL UNIQUE, name TEXT NOT NULL, logo_url TEXT, logo_bg_color TEXT NOT NULL DEFAULT '#1E3A8A', enabled BOOLEAN NOT NULL DEFAULT TRUE, sort_order INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS platform_earnings (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, platform TEXT NOT NULL, amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS platform_otps (user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, platform TEXT NOT NULL, otp TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY (user_id, platform))",
    "CREATE TABLE IF NOT EXISTS loans (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), proof_url TEXT, proof_name TEXT, annual_interest_rate NUMERIC(5,2), tenure_months INTEGER, monthly_installment NUMERIC(12,2), total_interest NUMERIC(12,2), total_payable NUMERIC(12,2), status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS loan_repayments (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), loan_id UUID NOT NULL REFERENCES loans(id) ON DELETE CASCADE, user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, installment_no INTEGER NOT NULL CHECK (installment_no > 0), amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount >= 0), status TEXT NOT NULL DEFAULT 'paid' CHECK (status IN ('paid','pending')), paid_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), UNIQUE(loan_id, installment_no))",
    "CREATE TABLE IF NOT EXISTS expenses (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, category TEXT NOT NULL, amount NUMERIC(12,2) NOT NULL CHECK (amount > 0), note TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS subscriptions (user_id " + userIdType + " PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, active_plan TEXT, pending_plan TEXT, status TEXT NOT NULL DEFAULT 'inactive', plan_limit INTEGER, used INTEGER NOT NULL DEFAULT 0, active_plan_expires_at TIMESTAMPTZ, updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS subscription_purchases (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, plan TEXT NOT NULL, amount INTEGER NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS platform_subscription_bindings (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, platform TEXT NOT NULL, purchase_id UUID NOT NULL REFERENCES subscription_purchases(id) ON DELETE CASCADE, plan TEXT NOT NULL, bound_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), expires_at TIMESTAMPTZ NOT NULL, unbound_at TIMESTAMPTZ)",
    "CREATE TABLE IF NOT EXISTS support_tickets (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), ticket_number TEXT NOT NULL UNIQUE, user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, subject TEXT NOT NULL, complaint TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS admin_users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), username TEXT NOT NULL UNIQUE, email TEXT NOT NULL, password_hash TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS admin_activity_logs (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), actor_username TEXT NOT NULL, action TEXT NOT NULL, details JSONB NOT NULL DEFAULT '{}'::jsonb, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS admin_password_reset_otps (username TEXT PRIMARY KEY, otp TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS password_reset_otps (email TEXT PRIMARY KEY, otp TEXT NOT NULL, expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS profile_password_verifications (token UUID PRIMARY KEY, user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS user_email_change_flows (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, old_email TEXT NOT NULL, new_email TEXT, old_otp TEXT NOT NULL, old_otp_expires_at TIMESTAMPTZ NOT NULL, old_verified BOOLEAN NOT NULL DEFAULT FALSE, new_otp TEXT, new_otp_expires_at TIMESTAMPTZ, new_verified BOOLEAN NOT NULL DEFAULT FALSE, status TEXT NOT NULL DEFAULT 'pending_old', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS tax_chat_sessions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, title TEXT NOT NULL DEFAULT 'New Chat', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "CREATE TABLE IF NOT EXISTS tax_chat_messages (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id " + userIdType + " NOT NULL REFERENCES users(id) ON DELETE CASCADE, question TEXT NOT NULL, answer TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    "ALTER TABLE tax_chat_messages ADD COLUMN IF NOT EXISTS session_id UUID REFERENCES tax_chat_sessions(id) ON DELETE CASCADE",
    "ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS proof_url TEXT",
    "ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS proof_name TEXT",
    "ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS incident_date DATE",
    "ALTER TABLE insurance_claims ADD COLUMN IF NOT EXISTS claim_amount NUMERIC(12,2) NOT NULL DEFAULT 0",
    "ALTER TABLE insurance_claims DROP CONSTRAINT IF EXISTS insurance_claims_claim_type_check",
    "ALTER TABLE insurance_claims ADD CONSTRAINT insurance_claims_claim_type_check CHECK (claim_type IN ('vehicle_damage','product_damage_loss')) NOT VALID",
    "ALTER TABLE loans ADD COLUMN IF NOT EXISTS proof_name TEXT",
    "ALTER TABLE loans ADD COLUMN IF NOT EXISTS annual_interest_rate NUMERIC(5,2)",
    "ALTER TABLE loans ADD COLUMN IF NOT EXISTS tenure_months INTEGER",
    "ALTER TABLE loans ADD COLUMN IF NOT EXISTS monthly_installment NUMERIC(12,2)",
    "ALTER TABLE loans ADD COLUMN IF NOT EXISTS total_interest NUMERIC(12,2)",
    "ALTER TABLE loans ADD COLUMN IF NOT EXISTS total_payable NUMERIC(12,2)",
    "ALTER TABLE loan_repayments ADD COLUMN IF NOT EXISTS amount NUMERIC(12,2) NOT NULL DEFAULT 0",
    "ALTER TABLE loan_repayments ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'paid'",
    "ALTER TABLE loan_repayments ADD COLUMN IF NOT EXISTS paid_at TIMESTAMPTZ",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS name TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS full_name TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS vehicle_rented BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS gigbit_insurance BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS daily_fuel NUMERIC(12,2)",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS daily_rent NUMERIC(12,2)",
    "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='users' AND column_name='id' AND data_type='uuid') THEN ALTER TABLE users ALTER COLUMN id SET DEFAULT gen_random_uuid(); END IF; END $$;",
    "ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_unique ON users ((lower(username))) WHERE username IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_loan_repayments_loan_installment ON loan_repayments (loan_id, installment_no)",
    "ALTER TABLE admin_users DROP CONSTRAINT IF EXISTS admin_users_email_key",
    "ALTER TABLE admin_users ADD COLUMN IF NOT EXISTS username TEXT",
    "UPDATE admin_users SET username = 'admin-' || substring(id::text,1,8) WHERE username IS NULL OR username = ''",
    "DROP INDEX IF EXISTS idx_admin_users_email_unique",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_users_username_unique ON admin_users ((lower(username)))",
    "CREATE INDEX IF NOT EXISTS idx_admin_activity_logs_created_at ON admin_activity_logs (created_at DESC)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_integration_platform_catalog_slug_unique ON integration_platform_catalog (slug)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_platform_connections_user_platform ON platform_connections (user_id, platform)",
    "CREATE INDEX IF NOT EXISTS idx_subscription_purchases_user_created_at ON subscription_purchases (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_platform_subscription_bindings_user_active ON platform_subscription_bindings (user_id, expires_at DESC) WHERE unbound_at IS NULL",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_platform_subscription_bindings_user_platform_active ON platform_subscription_bindings (user_id, platform) WHERE unbound_at IS NULL",
    "CREATE INDEX IF NOT EXISTS idx_support_tickets_user_created_at ON support_tickets (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_profile_password_verifications_user_expires ON profile_password_verifications (user_id, expires_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_user_email_change_flows_user_created ON user_email_change_flows (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_tax_chat_sessions_user_updated_at ON tax_chat_sessions (user_id, updated_at DESC, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_tax_chat_messages_user_created_at ON tax_chat_messages (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_tax_chat_messages_session_created_at ON tax_chat_messages (session_id, created_at ASC)",
    "CREATE INDEX IF NOT EXISTS idx_transactions_user_created_at ON transactions (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_withdrawals_user_created_at ON withdrawals (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_withdrawals_created_at ON withdrawals (created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_insurance_contributions_user_created_at ON insurance_contributions (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_insurance_claims_user_created_at ON insurance_claims (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_insurance_claims_status_created_at ON insurance_claims (status, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_loans_user_created_at ON loans (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_loans_status_created_at ON loans (status, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_expenses_user_created_at ON expenses (user_id, created_at DESC)",
    "CREATE INDEX IF NOT EXISTS idx_platform_earnings_user_created_at ON platform_earnings (user_id, created_at DESC)",
    "CREATE TABLE IF NOT EXISTS account_deletion_requests (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), user_id TEXT NOT NULL, user_email TEXT NOT NULL, reason_code TEXT NOT NULL, reason_text TEXT, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), reviewed_at TIMESTAMPTZ, reviewed_by TEXT, admin_note TEXT)",
    "CREATE INDEX IF NOT EXISTS idx_account_deletion_requests_status_created_at ON account_deletion_requests (status, created_at DESC)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_account_deletion_requests_pending_user_id ON account_deletion_requests (user_id) WHERE status = 'pending'"
  ];

  for (const sql of statements) {
    try {
      await pgPool.query(sql);
    } catch (error: any) {
      const code = String(error?.code ?? "");
      const text = String(sql).trim().toUpperCase();
      const isUniqueIndexStmt = text.startsWith("CREATE UNIQUE INDEX");
      // Existing production data may violate late-added unique index rules.
      // Do not crash startup for those cases; continue with degraded indexing.
      if (isUniqueIndexStmt && code === "23505") {
        console.warn("Skipping unique index creation due to duplicate existing data", {
          code,
          detail: error?.detail,
          statement: sql,
        });
        continue;
      }
      throw error;
    }
  }

  // Remove deprecated platforms completely.
  await pgPool.query(
    "DELETE FROM platform_otps WHERE lower(platform) IN ('swiggy','uber')"
  );
  await pgPool.query(
    "DELETE FROM platform_earnings WHERE lower(platform) IN ('swiggy','uber')"
  );
  await pgPool.query(
    "DELETE FROM transactions WHERE lower(platform) IN ('swiggy','uber')"
  );
  await pgPool.query(
    "DELETE FROM platform_subscription_bindings WHERE lower(platform) IN ('swiggy','uber')"
  );
  await pgPool.query(
    "DELETE FROM platform_connection_history WHERE lower(platform) IN ('swiggy','uber')"
  );
  await pgPool.query(
    "DELETE FROM platform_connections WHERE lower(platform) IN ('swiggy','uber')"
  );
  await pgPool.query(
    "DELETE FROM integration_platform_catalog WHERE lower(slug) IN ('swiggy','uber')"
  );

  // Backfill platform slot history from current connections (safe no-op after first run).
  await pgPool.query(
    "INSERT INTO platform_connection_history (user_id,platform,first_connected_at) SELECT user_id,platform,connected_at FROM platform_connections ON CONFLICT (user_id,platform) DO NOTHING"
  );

  // Seed admin-manageable platform catalog with defaults (safe no-op on conflict).
  for (let i = 0; i < AVAILABLE_PLATFORMS.length; i++) {
    const slug = AVAILABLE_PLATFORMS[i];
    const name = prettyPlatformName(slug);
    await pgPool.query(
      "INSERT INTO integration_platform_catalog (slug, name, enabled, sort_order, updated_at) VALUES ($1,$2,TRUE,$3,NOW()) ON CONFLICT (slug) DO NOTHING",
      [slug, name, i + 1]
    );
  }

  // Backfill name from legacy full_name if needed.
  await pgPool.query(
    "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='users' AND column_name='full_name') THEN UPDATE users SET name = COALESCE(NULLIF(name, ''), full_name) WHERE (name IS NULL OR name = '') AND full_name IS NOT NULL; END IF; END $$;"
  );
}

async function ensureAdminAccount(): Promise<void> {
  async function ensureNamedAdmin(username: string, password: string): Promise<void> {
    const canonical = username.trim();
    const normalized = canonical.toLowerCase();
    if (!canonical) return;
    const hash = await bcrypt.hash(password, 10);
    const existing = await pgPool.query(
      "SELECT id FROM admin_users WHERE lower(username) = lower($1) LIMIT 1",
      [normalized]
    );
    if (existing.rowCount) {
      await pgPool.query(
        "UPDATE admin_users SET username = $2, email = $3, password_hash = $4, updated_at = NOW() WHERE id = $1",
        [existing.rows[0].id, canonical, ADMIN_LOGIN_EMAIL, hash]
      );
      return;
    }
    await pgPool.query(
      "INSERT INTO admin_users (username, email, password_hash, updated_at) VALUES ($1,$2,$3,NOW())",
      [canonical, ADMIN_LOGIN_EMAIL, hash]
    );
  }

  await ensureNamedAdmin("AdminNihal", "Nihal@300906");
  await ensureNamedAdmin("Admin2", "Admin@123");
}

async function start(): Promise<void> {
  try {
    if (redis) {
      await redis.connect();
    }
  } catch (error) {
    console.warn("Redis unavailable, continuing with degraded mode", error);
  }

  await pgPool.query("SELECT 1");
  await ensureSchema();
  await ensureAdminAccount();
  app.listen(env.PORT, '0.0.0.0', () => {
    console.log('GigBit API running on http://0.0.0.0:' + env.PORT);
  });
}

start().catch((error) => {
  console.error("Startup failure", error);
  process.exit(1);
});

// Always respond with JSON for unexpected errors instead of dropping connection.
app.use((err: any, _req: express.Request, res: express.Response, next: express.NextFunction) => {
  if (!err) return next();
  if (res.headersSent) return next(err);
  if (err?.type === "entity.too.large" || err?.status === 413) {
    return res.status(413).json({ message: "Request payload too large", detail: "Request payload too large" });
  }
  console.error("Unhandled API error", err);
  return res.status(500).json({ message: "Internal server error", detail: "Internal server error" });
});





















