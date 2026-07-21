# GigBit

GigBit is a gig-worker finance platform with a Flutter mobile app, a static web portal, and a shared Node.js API backed by PostgreSQL.

## Project Structure

- `app/frontend/flutter_app/` - Flutter mobile app
- `app/releases/` - generated APK release artifacts
- `website/frontend/` - static web portal
- `website/backend/api/` - shared Node.js API for web and mobile
- `scripts/` - helper scripts for local development

## Tech Stack

- Frontend: Flutter, HTML, CSS, and JavaScript
- Backend: Node.js, TypeScript, Express
- Database: PostgreSQL

## Getting Started

```bash
git clone https://github.com/NihalMishra3009/GigBit.git
cd GigBit
npm install
```

### Backend

The backend lives in `website/backend/api`.

For local development, start the Docker PostgreSQL service first:

```bash
docker compose up -d db
```

```bash
cd website/backend/api
npm install
npm run build
npm run start
```

### Environment

Create a local environment file in `website/backend/api/.env` with at least:

- `PORT=4000`
- `JWT_SECRET=replace-with-a-strong-secret`
- `DATABASE_URL=postgresql://gigbit:gigbit@127.0.0.1:5433/gigbit`

## Notes

- Keep secrets out of source control.
- The web and mobile clients share the same backend API.
- Legacy duplicate schema files were removed; the backend schema now lives in `website/backend/api/sql/schema.sql`.
