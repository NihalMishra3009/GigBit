# Deployment Plan (Railway + Cloudflare)

This setup uses:

- Web frontend/admin: Cloudflare Pages
- Backend/API: Railway
- Database: Railway Postgres
- Cache: Railway Redis
- APK distribution: GitHub Releases / project-hosted APK link

## 1) Deploy Database (Railway Postgres)

1. Create Railway Postgres in your Railway workspace.
2. Open the Railway database console or use your local SQL client.
3. Run schema from:
- `web/database/schema.sql`
4. Copy the Railway Postgres connection string.

## 2) Deploy Backend API (Railway)

1. Create Railway project and connect GitHub repository.
2. Create service from this repo with:
- Root Directory: `web/backend/api`
- Build Command: `npm install && npm run build`
- Start Command: `npm run start`
- Healthcheck: `/health`

3. Add Railway Redis plugin only if you need it.

4. Set Railway env vars:
- `PORT=4000`
- `JWT_SECRET=<strong-random-secret>`
- `DATABASE_URL=<from Railway Postgres>`
- `REDIS_URL=<from Railway Redis>`
- `ADMIN_API_KEY=<your key>`
- SMTP vars (OTP/email)

5. Verify API:
- `https://<your-railway-domain>/health`

## 3) Deploy Web Frontend (Cloudflare Pages)

1. Push repo to GitHub.
2. Create Cloudflare Pages project.
3. Build settings:
- Build command: empty
- Output directory: `web/frontend`
4. Deploy.

## 4) Point Web to Railway API

Set API base URL using either:

- `scripts\prepare-web-release.cmd -ApiBaseUrl "https://<your-railway-domain>"`
- or directly in the meta tag in:
  - `web/frontend/landing.html`
  - `web/frontend/admin.html`

## 5) Publish APK

1. Build APK:
- `cd app/frontend/flutter_app`
- `flutter build apk --release --dart-define=API_BASE_URL=https://<your-railway-domain>`
2. Upload APK to GitHub release (recommended for large file delivery).

## Notes

- Railway Postgres is the recommended DB for this deployment path because the backend is PostgreSQL-native.
- Keep `web/database/schema.sql` as source of truth for DB bootstrap.
- If the Railway domain changes, rerun `prepare-web-release.cmd` and redeploy the web app.
