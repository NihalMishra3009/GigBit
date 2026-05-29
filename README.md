# GigBit - Gig Worker Payment & Benefits Platform

GigBit is a single-backend platform with two frontends:

- Flutter mobile app for workers
- Web landing/admin portal for operations
- Shared Node.js + TypeScript API
- PostgreSQL and Redis for data and queue/cache support

Repository: [NihalMishra3009/GigBit](https://github.com/NihalMishra3009/GigBit.git)

## What It Does

- Worker onboarding and login
- Platform connect/sync flow
- Withdrawals and earnings tracking
- Loan and insurance request handling
- Admin approvals and status updates
- Real-time updates across app and web

## Local Run

1. Start Docker Desktop
2. Run `scripts\start-stack.ps1`
3. Open the web app at `http://127.0.0.1:4173/landing.html`
4. Open the admin portal at `http://127.0.0.1:4173/admin.html`
5. API health check: `http://127.0.0.1:4000/health`

## Key URLs

- Web landing page: `http://127.0.0.1:4173/landing.html`
- Web admin page: `http://127.0.0.1:4173/admin.html`
- API base: `http://127.0.0.1:4000`
- API health: `http://127.0.0.1:4000/health`

## Project Structure

- `web/frontend/` - static website and admin portal
- `web/backend/api/` - shared backend API
- `web/database/` - database schema
- `app/frontend/flutter_app/` - Flutter mobile app
- `app/releases/` - APK builds

## Deployment

Recommended deployment split:

- Backend/API: Railway
- Database: Supabase Postgres or managed Postgres
- Web frontend: Cloudflare Pages or similar static hosting
- Mobile app: APK distribution or Play Store build pipeline

## Notes

- The web and mobile app both use the same backend API.
- Admin credentials should be stored only in the database and environment variables, not hardcoded for production.
- Local development uses Docker Compose for Postgres, Redis, and the API.
