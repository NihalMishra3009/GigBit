import nodemailer, { type SentMessageInfo } from "nodemailer";
import SMTPTransport from "nodemailer/lib/smtp-transport/index.js";
import { env } from "./config.js";

export type OtpMailResult = {
  messageId: string;
  response: string;
  accepted: string[];
  rejected: string[];
};

type OtpMailChannel = "admin" | "user";

function smtpProfile(channel: OtpMailChannel): { user?: string; pass?: string; from?: string } {
  if (channel === "admin") {
    return {
      user: env.SMTP_ADMIN_USER || env.SMTP_USER,
      pass: env.SMTP_ADMIN_PASS || env.SMTP_PASS,
      from: env.SMTP_ADMIN_FROM || env.SMTP_FROM,
    };
  }
  return {
    user: env.SMTP_USER_OTP_USER || env.SMTP_USER,
    pass: env.SMTP_USER_OTP_PASS || env.SMTP_PASS,
    from: env.SMTP_USER_OTP_FROM || env.SMTP_FROM,
  };
}

function getTransport(channel: OtpMailChannel) {
  const profile = smtpProfile(channel);
  if (!env.SMTP_HOST || !profile.user || !profile.pass) {
    return null;
  }

  const options: SMTPTransport.Options = {
    host: env.SMTP_HOST,
    port: env.SMTP_PORT,
    secure: env.SMTP_PORT === 465,
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 15000,
    auth: {
      user: profile.user,
      pass: profile.pass,
    },
  };
  // Render instances may not have working outbound IPv6 to Gmail SMTP.
  // Force IPv4 so OTP delivery remains reliable.
  (options as any).family = 4;
  return nodemailer.createTransport(options);
}

function parseFromHeader(input: string): { name?: string; email: string } {
  const raw = String(input || "").trim();
  const m = raw.match(/^(.*)<([^>]+)>$/);
  if (m) {
    const name = m[1].trim().replace(/^"|"$/g, "");
    const email = m[2].trim();
    return { name: name || undefined, email };
  }
  return { email: raw };
}

async function sendViaBrevoApi(params: {
  from: string;
  to: string;
  subject: string;
  html: string;
}): Promise<OtpMailResult> {
  const apiKey = String(env.BREVO_API_KEY || "").trim();
  if (!apiKey) throw new Error("BREVO_API_KEY is not configured on server");

  const from = parseFromHeader(params.from);
  const toEmail = String(params.to || "").trim();
  const toName = toEmail.split("@")[0] || "User";

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        "accept": "application/json",
        "content-type": "application/json",
        "api-key": apiKey,
      },
      body: JSON.stringify({
        sender: from.name ? { name: from.name, email: from.email } : { email: from.email },
        to: [{ email: toEmail, name: toName }],
        subject: params.subject,
        htmlContent: params.html,
      }),
      signal: controller.signal,
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`Brevo API error ${response.status}: ${text || response.statusText}`);
    }
    return {
      messageId: text || "",
      response: `brevo:${response.status}`,
      accepted: [toEmail.toLowerCase()],
      rejected: [],
    };
  } finally {
    clearTimeout(timer);
  }
}

export async function sendOtpEmail(
  email: string,
  otp: string,
  purpose: "registration" | "password-reset" | "profile-email-old" | "profile-email-new",
  options?: { username?: string | null; channel?: OtpMailChannel }
): Promise<OtpMailResult> {
  const channel = options?.channel === "admin" ? "admin" : "user";
  const profile = smtpProfile(channel);
  const transport = getTransport(channel);
  if (!transport) {
    if (env.OTP_IN_RESPONSE) {
      console.warn(`SMTP is not configured for channel ${channel}; returning OTP in response for local dev.`);
      return {
        messageId: "local",
        response: "local",
        accepted: [email.toLowerCase()],
        rejected: [],
      };
    }
    throw new Error("SMTP is not configured on server");
  }

  const isRegistration = purpose === "registration";
  const isPasswordReset = purpose === "password-reset";
  const isProfileEmailChange =
    purpose === "profile-email-old" || purpose === "profile-email-new";
  const subject = isRegistration
    ? "GigBit registration OTP"
    : isPasswordReset
      ? "GigBit Password Verification"
      : isProfileEmailChange
        ? "GigBit Email Verification"
        : "GigBit OTP";

  const usernameLine =
    !isRegistration && options?.username
      ? `<p style="margin:0 0 8px;"><strong>Registered Username:</strong> ${options.username}</p>`
      : "";

  const html = `
    <div style="font-family: Inter, Arial, sans-serif; line-height:1.5; color:#0f172a;">
      <h2 style="margin:0 0 8px;">GigBit</h2>
      ${usernameLine}
      <p style="margin:0 0 10px;">Your one-time password is:</p>
      <div style="font-size:28px; letter-spacing:6px; font-weight:700; color:#1E3A8A; margin:8px 0 12px;">${otp}</div>
      <p style="margin:0 0 6px;">This OTP is valid for 10 minutes.</p>
      <p style="margin:0; color:#475569;">If you did not request this, you can ignore this email.</p>
    </div>
  `;
  if (env.BREVO_API_KEY) {
    return sendViaBrevoApi({
      from: profile.from || profile.user!,
      to: email,
      subject,
      html,
    });
  }

  let info: SentMessageInfo;
  try {
    info = await transport.sendMail({
      from: profile.from || profile.user!,
      to: email,
      subject,
      html,
    });
  } catch (_) {
    // Retry once for transient SMTP/network issues.
    info = await transport.sendMail({
      from: profile.from || profile.user!,
      to: email,
      subject,
      html,
    });
  }
  const accepted = (info.accepted ?? []).map((v: unknown) => String(v).toLowerCase());
  const rejected = (info.rejected ?? []).map((v: unknown) => String(v).toLowerCase());
  const target = email.toLowerCase();
  if (rejected.includes(target) || !accepted.includes(target)) {
    throw new Error("SMTP rejected recipient");
  }

  return {
    messageId: String(info.messageId ?? ""),
    response: String((info as { response?: string }).response ?? ""),
    accepted,
    rejected,
  };
}

export async function sendAdminPasswordEmail(
  email: string,
  password: string
): Promise<OtpMailResult> {
  const profile = smtpProfile("admin");
  const transport = getTransport("admin");
  if (!transport) {
    throw new Error("SMTP is not configured on server");
  }

  const subject = "GigBit Admin Portal Access";
  const html = `
    <div style="font-family: Inter, Arial, sans-serif; line-height:1.5; color:#0f172a;">
      <h2 style="margin:0 0 8px;">GigBit Admin Access</h2>
      <p style="margin:0 0 8px;">Admin Email: <strong>${email}</strong></p>
      <p style="margin:0 0 8px;">Temporary Password:</p>
      <div style="font-size:22px; letter-spacing:2px; font-weight:700; color:#1E3A8A; margin:8px 0 12px;">${password}</div>
      <p style="margin:0 0 6px;">Please login and change this password from the admin portal immediately.</p>
      <p style="margin:0; color:#475569;">If you did not request this, contact GigBit support.</p>
    </div>
  `;

  if (env.BREVO_API_KEY) {
    return sendViaBrevoApi({
      from: profile.from || profile.user!,
      to: email,
      subject,
      html,
    });
  }

  let info: SentMessageInfo;
  try {
    info = await transport.sendMail({
      from: profile.from || profile.user!,
      to: email,
      subject,
      html,
    });
  } catch (_) {
    info = await transport.sendMail({
      from: profile.from || profile.user!,
      to: email,
      subject,
      html,
    });
  }

  const accepted = (info.accepted ?? []).map((v: unknown) => String(v).toLowerCase());
  const rejected = (info.rejected ?? []).map((v: unknown) => String(v).toLowerCase());
  const target = email.toLowerCase();
  if (rejected.includes(target) || !accepted.includes(target)) {
    throw new Error("SMTP rejected recipient");
  }

  return {
    messageId: String(info.messageId ?? ""),
    response: String((info as { response?: string }).response ?? ""),
    accepted,
    rejected,
  };
}
