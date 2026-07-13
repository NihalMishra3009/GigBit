# GigBit

GigBit is a gig-worker finance platform with a Flutter mobile app, a static web portal, and a shared Node.js API backed by PostgreSQL.

## Project Structure

- `app/` - Flutter mobile app and release artifacts
- `website/` - web frontend, backend API, and database schema
- `docs/` - project documentation
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
- `DATABASE_URL=postgresql://user:password@host:5432/database`

## Notes

- Keep secrets out of source control.
- The web and mobile clients share the same backend API.
