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

Access tokens are short-lived JWTs bound to the same session family as their refresh token. Protected requests verify that the family still has an unexpired, non-revoked refresh record in PostgreSQL. Logging out or detecting refresh-token reuse therefore invalidates already-issued access tokens on subsequent requests, not only future refreshes.

Refresh tokens are opaque random values. Only their SHA-256 hashes are stored in PostgreSQL. Refresh-token rotation is enabled, and reuse of a revoked token revokes the complete token family. This adds one indexed session-family lookup to authenticated requests; the backend already queries PostgreSQL to load the user.

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
PostgreSQL-backed per-client authentication rate limits
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

The Item entity is intentionally technical. Every Item is owned by the authenticated user. List, read, update, and delete operations are scoped by that owner. A user who does not own an Item receives the same 404 response as an unknown Item.

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
0003_scope_items_to_users
0004_auth_rate_limit_buckets
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

### AWS ECS / Secrets Manager

The ECS backend task reads authentication settings from one Secrets Manager secret using JSON-key references. Terraform accepts only the secret ARN through backend_auth_secret_arn; it never receives or stores the secret values.

The JSON secret must contain all of these keys. Values for an unused provider may be empty strings, but the keys must exist:

```json
{
  "AUTH_JWT_SECRET_KEY": "<at-least-32-random-characters>",
  "GOOGLE_CLIENT_ID": "",
  "GOOGLE_CLIENT_SECRET": "",
  "GOOGLE_REDIRECT_URI": "",
  "APPLE_CLIENT_ID": "",
  "APPLE_TEAM_ID": "",
  "APPLE_KEY_ID": "",
  "APPLE_PRIVATE_KEY": "",
  "APPLE_REDIRECT_URI": ""
}
```

Create the secret in the target AWS account and region, populate it with this JSON using real values, then pass its ARN through backend_auth_secret_arn (or TF_VAR_backend_auth_secret_arn). Keep the JSON file outside the repository, protect it with restrictive filesystem permissions, and never pass secret values as Terraform variables.

Create an empty secret container first:

```bash
aws secretsmanager create-secret --name cloudstart-dev/backend-auth --description "CloudStart backend JWT and OAuth configuration" --region us-east-1
```

Then populate it from a protected local JSON file:

```bash
chmod 600 backend-auth.json
aws secretsmanager put-secret-value --secret-id cloudstart-dev/backend-auth --secret-string file://backend-auth.json --region us-east-1
```

Use the ARN returned by create-secret in config/dev.tfvars. The app deployment guard requires the ARN whenever deploy_application = true. The secret value must be populated before starting ECS tasks, because ECS resolves these JSON keys during task startup.

The ECS execution role receives secretsmanager:GetSecretValue for this secret ARN only. The application task role does not receive Secrets Manager permissions.

This configures credential delivery; it does not create Google/Apple OAuth client registrations. Apple web sign-in also remains dependent on an HTTPS callback domain and an Apple-registered Service ID. The current HTTP-only ALB is not sufficient for production OAuth callbacks.

For production, provider credentials and the JWT signing secret must come from the secret-management layer rather than repository files.


### Authentication rate limits

Authentication endpoints use PostgreSQL-backed fixed-window limits shared between ECS tasks. Defaults are 10 OAuth login starts, 20 callbacks, 30 refresh requests, and 60 logout requests per client address per five minutes. Rejected requests return HTTP 429 with Retry-After.

Non-local deployments must keep the backend private behind the ALB. Client address extraction trusts the final ALB-appended X-Forwarded-For address; do not expose the backend directly or change ALB forwarding behavior without revisiting this trust boundary.
