# GigBit Structure

GigBit is organized around three surfaces that share one backend:

- `app/frontend/flutter_app/` - Flutter mobile app
- `website/frontend/` - static web portal
- `website/backend/api/` - shared Node.js API used by both clients

## Shared Backend

The backend is the canonical source for API routes, database access, auth, and mail.
Both the mobile app and the website talk to the same API.

## Mobile App

The Flutter app lives in `app/frontend/flutter_app/`.

Keep here:

- Flutter source in `lib/`
- Android setup in `android/`
- app assets in `assets/`
- Flutter tests in `test/`

## Website

The web surface lives in `website/frontend/`.

Keep here:

- `landing.html` for the public site
- `admin.html` for admin flows
- `index.html` as the redirect entry
- static assets in `assets/`

## Release Artifacts

Generated APKs live in `app/releases/`.

- Do not store build output anywhere else unless the workflow changes.

## Scripts

Helper scripts live in `scripts/`.

They should keep working from the repo root and should not depend on a personal machine path.

## Cleanup Rule

If a file or folder is not used by the app, website, backend, or scripts, it can be removed.
If it is only a duplicate copy of something canonical, keep one version and delete the rest.
