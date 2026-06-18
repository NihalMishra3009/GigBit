# GigBit

GigBit is a gig-worker finance platform with a Flutter mobile app, a static web portal, and a shared Node.js API backed by PostgreSQL.

## Badges

![License](https://img.shields.io/badge/License-ISC-blue.svg)
![Railway](https://img.shields.io/badge/Deploy%20Backend-Railway-0B0D0E?logo=railway&logoColor=white)
![Cloudflare Pages](https://img.shields.io/badge/Deploy%20Frontend-Cloudflare%20Pages-F38020?logo=cloudflare&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL-336791?logo=postgresql&logoColor=white)
![Node.js](https://img.shields.io/badge/Backend-Node.js-339933?logo=node.js&logoColor=white)
![Flutter](https://img.shields.io/badge/Mobile-Flutter-02569B?logo=flutter&logoColor=white)

## Live Demo

- Frontend: `https://YOUR-CLOUDFLARE-PAGES-URL`
- Backend API: `https://YOUR-RAILWAY-URL`

## Screenshots

![Dashboard](docs/screenshots/dashboard.png)

![Transactions](docs/screenshots/transactions.png)

![Payouts](docs/screenshots/payouts.png)

![Mobile View](docs/screenshots/mobile-view.png)

## Problem Statement

Gig workers often manage income across multiple platforms, but their earnings, withdrawals, deductions, and support requests are scattered across different systems. That creates three common problems:

- Delayed visibility into payouts and balances
- Limited financial transparency across platforms
- Harder loan, insurance, and support workflows

GigBit centralizes these flows so workers and operators can see a clearer financial picture in one place.

## Features

- Worker onboarding and authentication
- Platform connection and sync flow
- Earnings tracking and transaction history
- Withdrawal and payout visibility
- Loan request and insurance request handling
- Admin portal for operational review and approvals
- Real-time updates for platform and approval activity
- Shared API for web and mobile clients

## Architecture

```mermaid
flowchart TD
  U[Users] --> C[Cloudflare Pages]
  C --> R[Railway Backend API]
  R --> P[(Railway PostgreSQL)]
```

## Tech Stack

### Frontend

- Static HTML, CSS, and JavaScript for the web portal
- Flutter for the mobile app

### Backend

- Node.js
- Express
- TypeScript

### Database

- PostgreSQL

### Deployment

- Cloudflare Pages for the web frontend
- Railway for the backend API
- Railway PostgreSQL for persistent storage

## Repository Structure

- `app/` - Flutter mobile app and release artifacts
- `web/` - static frontend, backend API, and database schema
- `scripts/` - helper scripts for local dev and release packaging
- `docs/` - diagrams, screenshots, and supporting documentation

## Local Setup

```bash
git clone https://github.com/NihalMishra3009/GigBit.git
cd GigBit
npm install
```

### Backend

The backend lives in `web/backend/api`.

```bash
cd web/backend/api
npm install
npm run build
npm run start
```

### Local Environment Variables

Copy `web/backend/api/.env.example` to `web/backend/api/.env` and set:

- `PORT=4000`
- `JWT_SECRET=replace-with-strong-secret`
- `DATABASE_URL=postgres://gigbit:gigbit@127.0.0.1:5433/gigbit`
- `REDIS_URL=redis://127.0.0.1:6379`
- `CORS_ORIGINS=http://127.0.0.1:4173,http://localhost:4173`

For the Flutter app, provide the API base URL at build time:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-RAILWAY-URL
```

## Deployment Guide

### Frontend on Cloudflare Pages

1. Connect the GitHub repository to Cloudflare Pages.
2. Set the root/output to the static frontend under `web/frontend`.
3. Deploy the site.
4. Ensure the frontend is pointed at the Railway API URL.

### Backend on Railway

1. Create a Railway service from this repository.
2. Set the root directory to `web/backend/api`.
3. Use:
   - Build command: `npm install && npm run build`
   - Start command: `npm run start`
   - Healthcheck path: `/health`
4. Set Railway environment variables:
   - `PORT=4000`
   - `JWT_SECRET`
   - `DATABASE_URL`
   - `REDIS_URL` if used
   - `CORS_ORIGINS`
   - SMTP variables if email is enabled

### PostgreSQL on Railway

1. Provision Railway PostgreSQL.
2. Run the schema from `web/database/schema.sql`.
3. Point `DATABASE_URL` to the Railway database connection string.

## Future Improvements

- Real-time notifications
- AI-powered financial insights
- Mobile application enhancements
- Analytics dashboard

## Notes

- This repository is a monorepo-style project with a shared backend and multiple clients.
- The web and Flutter clients use the same backend API.
- Do not hardcode production secrets in the source code.
