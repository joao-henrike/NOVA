# CloudStart Backend

Python/FastAPI backend for the CloudStart MVP.

The backend keeps the existing health contract used by the ALB/frontend and adds a structured persistence layer, a protected technical CRUD slice, and Sign in with Google / Sign in with Apple authentication.

## Stack

Python 3.12, FastAPI, Uvicorn, SQLAlchemy 2.x, psycopg 3, PostgreSQL, Alembic, PyJWT and the Google authentication library.

## Application structure

```text
app/
├── api/
│   ├── dependencies.py
│   └── routes/
│       ├── auth.py
│       ├── health.py
│       └── items.py
├── core/
│   ├── config.py
│   └── security.py
├── db/
│   ├── base.py
│   └── session.py
├── models/
│   ├── auth.py
│   ├── item.py
│   └── user.py
├── repositories/
│   ├── auth.py
│   └── items.py
├── schemas/
│   ├── auth.py
│   └── item.py
└── services/
    ├── auth.py
    ├── items.py
    └── providers.py
```

The layers are intentionally separated:

```text
HTTP
 ↓
Service
 ↓
Repository
 ↓
SQLAlchemy
 ↓
PostgreSQL
```

## Existing health endpoints

```text
GET /health
GET /api/health
GET /api/info
GET /api/health/db
```

These contracts remain compatible with the existing ALB/frontend architecture.

## Authentication

The backend supports:

```text
Google
Apple
```

The providers authenticate the external identity. CloudStart then creates or resolves its own local user and issues its own application session.

### Identity model

The canonical provider identity is:

```text
provider + provider_subject
```

The provider subject is the external provider's `sub` claim. Email is profile data, not the primary identity key.

Automatic account linking by matching email is deliberately disabled. When the email already belongs to another local account, an explicit account-linking workflow is required.

### Google flow

```text
Browser
  ↓
/api/auth/google/login
  ↓
Google Authorization Code
  ↓
S256 PKCE + state + nonce
  ↓
/api/auth/google/callback
  ↓
Google token endpoint
  ↓
Google ID token validation
  ↓
CloudStart user/session
```

### Apple flow

```text
Browser
  ↓
/api/auth/apple/login
  ↓
Apple authorization
  ↓
state + nonce + form_post
  ↓
/api/auth/apple/callback
  ↓
Apple token endpoint
  ↓
Apple ID token/JWS validation
  ↓
CloudStart user/session
```

The Apple web flow requires an HTTPS redirect URI on a registered domain.

### Authentication endpoints

The login and callback endpoints are browser-oriented:

```text
GET  /api/auth/google/login
GET  /api/auth/google/callback
GET  /api/auth/apple/login
POST /api/auth/apple/callback
```

Session endpoints:

```text
POST /api/auth/refresh
POST /api/auth/logout
GET  /api/auth/me
```

Access tokens are short-lived JWTs.

Refresh tokens are opaque random values. Only their SHA-256 hashes are stored in PostgreSQL. Refresh-token rotation is enabled, and reuse of a revoked token revokes the complete token family.

The refresh token is delivered in an HttpOnly cookie:

```text
nova_refresh_token
```

The cookie is Secure in the production configuration.

## Authentication security controls

Implemented in the backend:

```text
OAuth state generation
server-side state persistence
one-time state consumption
state cookie binding
nonce validation
Google PKCE S256
provider ID-token validation
fixed JWT algorithm
JWT issuer validation
JWT audience validation
JWT expiry
HttpOnly refresh cookie
refresh-token hashing
refresh-token rotation
refresh-token reuse detection
explicit account-linking requirement
no provider credentials committed to source
```

The application does not persist Google or Apple provider access/refresh tokens because the MVP only needs provider identity. This minimizes retained credential material.

## CRUD slice

The current technical resource is `Item`.

```text
POST   /api/items
GET    /api/items
GET    /api/items/{id}
PATCH  /api/items/{id}
DELETE /api/items/{id}
```

All Item endpoints require a valid CloudStart bearer token.

Listing accepts:

```text
/api/items?offset=0&limit=50
/api/items?status=active
```

The Item entity is intentionally technical. The repository does not yet define the final CloudStart business domain.

## Database

Tables are managed explicitly with Alembic. The application does not create or alter the schema during startup.

Apply:

```bash
alembic upgrade head
```

Rollback one revision:

```bash
alembic downgrade -1
```

Create a new migration after a model change:

```bash
alembic revision --autogenerate -m "describe change"
```

Always review generated migrations before applying them.

Current migrations include:

```text
0001_create_items
0002_add_authentication
```

## Required configuration

Do not commit real credentials.

Configure these values through environment variables or the deployment secret mechanism:

```text
GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET
GOOGLE_REDIRECT_URI

APPLE_CLIENT_ID
APPLE_TEAM_ID
APPLE_KEY_ID
APPLE_PRIVATE_KEY or APPLE_PRIVATE_KEY_PATH
APPLE_REDIRECT_URI

AUTH_JWT_SECRET_KEY
```

Generate the application signing secret with a cryptographically secure random generator, for example:

```bash
openssl rand -hex 32
```

For local Google development, the example environment file uses an HTTP localhost redirect and should use `AUTH_COOKIE_SECURE=false`.

Apple web authentication requires a registered HTTPS domain, so the Apple flow is not expected to work against a plain localhost HTTP callback.

## Local development

From `apps/backend`:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

alembic upgrade head

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

OpenAPI:

```text
http://localhost:8000/docs
```

For production, provider credentials and the JWT signing secret must come from the secret-management layer rather than repository files.
