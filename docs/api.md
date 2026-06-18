# GigBit API Overview

GigBit uses a shared Node.js API for the web frontend and Flutter mobile app.

## Purpose

- Authenticate users and admins
- Track earnings, transactions, and withdrawals
- Handle loan and insurance workflows
- Serve platform catalog and sync endpoints
- Expose dashboard and admin management APIs

## Runtime

- Framework: Express
- Language: TypeScript
- Database: PostgreSQL
- Optional cache: Redis

## Deployment

- Host the API on Railway
- Connect Railway PostgreSQL for persistent storage
- Configure `CORS_ORIGINS` for Cloudflare Pages and local development

## Important Endpoints

- `GET /health`
- `POST /admin/login`
- `GET /platforms/catalog`
- `GET /platforms/catalog/stream`
- `POST /platforms/connect`
- `POST /platforms/disconnect`
- `POST /platforms/sync-earning`

## Notes

- The frontend and mobile app must use the deployed Railway API URL in production.
- Keep database schema changes aligned with `web/database/schema.sql`.
