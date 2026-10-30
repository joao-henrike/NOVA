# CloudStart Frontend

> Repository-wide documentation: [NOVA documentation index](../../docs/README.md) · [Architecture](../../docs/architecture.md) · [Security model](../../docs/security.md) · [Deployment](../../docs/deployment.md).

## Scope

The current frontend is a deliberately small static status page served by Nginx. It is not a framework-based SPA and does not contain the final CloudStart business application.

The page loads local JavaScript and CSS. The JavaScript requests `GET /api/health` and displays whether the backend is reachable.

## Files

| Path | Responsibility |
| --- | --- |
| `public/index.html` | Static page and same-origin asset references. |
| `public/app.js` | Backend health request and status text. |
| `public/styles.css` | Local page styling. |
| `Dockerfile` | Builds the Nginx image and defines the container health check. |
| `nginx.conf` | AWS image configuration; serves the page and health endpoint. |
| `nginx.local.conf` | Compose-only configuration; additionally proxies `/api` to the Compose service `backend:8000`. |
| `.dockerignore` | Excludes local-only files from the frontend build context. |

## Request routing

### Local Compose

```text
Browser :8080
   |
   v
Frontend Nginx
   |
   +--> / and /health -> static frontend
   |
   +--> /api/* -> http://backend:8000
```

The local Nginx container uses the Compose service DNS name `backend`. Do not copy this proxy dependency into the AWS image.

### AWS

```text
Client
  |
  v
Public ALB
  |
  +--> /api/* -> backend target group -> backend :8000
  |
  +--> other paths -> frontend target group -> frontend :80
```

The deployed `nginx.conf` serves the static UI. The ALB owns the API path routing, so the frontend container has no need to resolve an ECS backend hostname.

## Security headers

The AWS and local Nginx configurations set a restrictive Content Security Policy and security headers including:

- `default-src 'self'`, same-origin scripts/styles/connections, and no inline script or style allowance;
- `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'none'`, and `form-action 'self'`;
- `X-Content-Type-Options: nosniff`;
- `X-Frame-Options: DENY`;
- `Referrer-Policy: no-referrer`;
- a restrictive Permissions Policy disabling camera, microphone, and geolocation.

Keep scripts and styles in the existing external files unless the CSP is deliberately reviewed and changed. The application has no external CDN, font, analytics, or script dependency.

## Health and validation

- `GET /` serves the static page.
- `GET /health` is the Nginx container/ALB health endpoint.
- The Dockerfile health check requests `http://127.0.0.1/health`.
- CI builds the frontend image and runs `nginx -t` against it.
- Compose maps host port `8080` to container port `80`.

Local commands:

```bash
docker compose build frontend
docker compose up -d frontend
curl --fail http://localhost:8080/
curl --fail http://localhost:8080/health
docker compose exec frontend nginx -t
```

The main application stack and deployment procedures are described in [Local Development](../../docs/local-development.md) and [Deployment](../../docs/deployment.md).
