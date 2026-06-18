# Deploy Now (Railway + Cloudflare)

This is the fastest production path for GigBit now.

## A) One-time in this repo

1. Build APK for production backend:
```bat
cd app\frontend\flutter_app
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-RAILWAY-API-DOMAIN
cd ..\..\..
```

2. Prepare web files and copy APK:
```bat
scripts\prepare-web-release.cmd -ApiBaseUrl "https://YOUR-RAILWAY-API-DOMAIN"
```

3. Push to GitHub:
```bat
git add .
git commit -m "Prepare Railway + Cloudflare deploy"
git push
```

## B) Railway Postgres (Database)

1. Create Railway Postgres in the same Railway project or workspace.
2. Run the schema from:
- `web/database/schema.sql`
3. Copy the Railway Postgres connection string into `DATABASE_URL`.

## C) Railway (API + optional Redis)

1. Create Railway project.
2. Add GitHub service from this repo.
3. Service settings:
- Root Directory: `web/backend/api`
- Build command: `npm install && npm run build`
- Start command: `npm run start`
- Healthcheck path: `/health`

4. Add Redis plugin in Railway only if you want cache/queue support.

5. Env vars in Railway service:
- `PORT=4000`
- `JWT_SECRET=<long random secret>`
- `DATABASE_URL=<Railway Postgres connection string>`
- `REDIS_URL=<Railway Redis URL>`
- `ADMIN_API_KEY=<your key>`
- `SMTP_HOST=<smtp host>`
- `SMTP_PORT=587`
- `SMTP_USER=<smtp user>`
- `SMTP_PASS=<smtp pass>`
- `SMTP_FROM=<display name + email>`
- `SMTP_ADMIN_USER=<admin smtp user>`
- `SMTP_ADMIN_PASS=<admin smtp pass>`
- `SMTP_ADMIN_FROM=<admin display name + email>`
- `SMTP_USER_OTP_USER=<user otp smtp user>`
- `SMTP_USER_OTP_PASS=<user otp smtp pass>`
- `SMTP_USER_OTP_FROM=<user otp display name + email>`

6. Confirm API:
- `https://YOUR-RAILWAY-API-DOMAIN/health` returns `status: ok`

## D) Cloudflare Pages (Web)

1. Create project from GitHub repo.
2. Build settings:
- Build command: *(empty)*
- Output directory: `web/frontend`
3. Set the public API base for the deployed web app to the Railway backend URL.
4. Deploy.

## E) Verify

1. Open:
- `https://YOUR-WEB-DOMAIN/landing.html`
2. Click `Download APK` and validate download.
3. Open admin page and verify API-backed actions.

## F) Update flow (every release)

1. Build new APK:
```bat
cd app\frontend\flutter_app
flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-RAILWAY-API-DOMAIN
cd ..\..\..
```

2. Refresh web APK + API meta + push:
```bat
scripts\prepare-web-release.cmd -ApiBaseUrl "https://YOUR-RAILWAY-API-DOMAIN"
git add app/releases/GigBit.apk web/frontend/landing.html web/frontend/admin.html
git commit -m "Update APK and API URL"
git push
```
