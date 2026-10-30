# CloudStart Backend

Python/FastAPI backend for the CloudStart MVP.

> Repository-wide documentation: [NOVA documentation index](../../docs/README.md) · [Architecture](../../docs/architecture.md) · [Security model](../../docs/security.md) · [Configuration reference](../../docs/configuration-reference.md) · [Deployment](../../docs/deployment.md).

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

### AWS database identities

The deployed ECS stack uses three PostgreSQL identities with distinct purposes:

| Identity | Where it is used | Permissions |
|---|---|---|
| `cloudstart_runtime` | Normal backend HTTP service | `SELECT`, `INSERT`, `UPDATE`, `DELETE`, and sequence usage |
| `cloudstart_migrator` | One-off Alembic Fargate task | Owns application schema objects and can create/alter them |
| RDS master (`cloudstart_admin`) | One-off role-bootstrap Fargate task only | Provisions the two restricted roles and reapplies runtime grants |

The runtime role cannot create or alter schema objects and has no superuser, role-management, database-creation, replication, or RLS-bypass attributes. The migration role is never injected into the normal HTTP service. The RDS master password is not injected into the normal backend task.

The bootstrap command is explicit and idempotent:

```bash
python -m app.db.bootstrap_roles
```

It transfers existing application tables/sequences/views to the migrator and reapplies DML grants to the runtime role. Run it once before migrations and again after migrations so new objects receive runtime grants. The repository's ECS deployment workflows perform this order automatically.

Local Compose development continues to use its explicitly development-only database account; the AWS role separation is applied to ECS/RDS deployment tasks.

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

## Tests and coverage

Install the development tooling from this directory:

```bash
pip install -r requirements.txt -r requirements-dev.txt
```

Run the backend suite with line and branch coverage enabled:

```bash
coverage run -m pytest -q
coverage report --show-missing
coverage html
```

The coverage source is restricted to `app/`; test code and third-party packages are not counted. Branch measurement records whether both outcomes of conditional paths are exercised, not only whether a line ran. The terminal report lists modules and missing line numbers, while `htmlcov/index.html` provides a navigable per-file view.

The GitHub Actions backend job runs the same coverage command against PostgreSQL 16, prints the per-module report, and uploads JSON, XML, text, and HTML reports as the `backend-coverage` workflow artifact. The initial report establishes the measured baseline; no percentage threshold is imposed until the uncovered paths have been reviewed and the baseline is understood.

```bash
# Machine-readable reports
coverage json -o coverage.json
coverage xml -o coverage.xml
```

Coverage files are generated outputs and are ignored by Git.

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

The normal backend ECS task reads its runtime database password from a dedicated Secrets Manager JSON secret and authentication settings from a separate JSON secret. Terraform accepts only their ARNs through db_runtime_secret_arn and backend_auth_secret_arn; it never receives plaintext password or OAuth values.

The Alembic task reads a separate migrator password through db_migrator_secret_arn. A one-off bootstrap task is the only ECS task definition allowed to inject the RDS-managed master password. The bootstrap and migration task definitions omit task_role_arn entirely; their execution roles are used only for image pulls, logs, and startup-time secret injection.

The development scripts provision or reuse these secrets automatically:

| Secret name | JSON fields | Used by |
| --- | --- | --- |
| cloudstart-dev/database/runtime | password | Normal backend HTTP task; DML-only login. |
| cloudstart-dev/database/migrator | password | One-off Alembic task. |
| cloudstart-dev/backend/authentication | AUTH_JWT_SECRET_KEY and Google/Apple OAuth fields | Backend session and OAuth configuration. |

The RDS master password is created and managed by RDS. It is not one of the application-generated secrets.

#### Backend authentication secret schema

The secret must be a JSON object with all keys present. Values for an unused provider may be empty strings:

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

The current provisioner is scripts/provision-backend-auth-secret.sh. Its default name is cloudstart-dev/backend/authentication; BACKEND_AUTH_SECRET_NAME can override it. On first creation it generates a high-entropy JWT key. On later runs it validates and preserves the existing key, merging only non-empty OAuth environment values. It rejects partially configured Google or Apple provider sets and never prints secret values. The local ignored file .deploy/backend-auth-secret-arn.env contains only the secret ARN.

The database provisioner is scripts/provision-db-credentials.sh. It creates/reuses cloudstart-dev/database/runtime and cloudstart-dev/database/migrator, generates high-entropy passwords on first creation, and writes only their ARNs to .deploy/db-secret-arns.env. The values remain in Secrets Manager.

The development GitHub OIDC role must permit secretsmanager:DescribeSecret, GetSecretValue, CreateSecret, and PutSecretValue for all three provisioned application secrets: runtime, migrator, and backend authentication. ECS execution roles have narrower read access scoped to each task's required secret.

Local deployment accepts the matching GOOGLE_* and APPLE_* variables in the shell environment. GitHub deployment reads those values from the development Environment secrets. Supply the complete set of fields for a provider or leave that provider unused.

This configures credential delivery; it does not create Google/Apple OAuth client registrations. Apple web sign-in requires an HTTPS callback domain and a registered Apple Service ID. The committed development ALB is HTTP-only until an operator supplies an already-issued ACM certificate and matching hostname.

For production, provider credentials and the JWT signing secret must come from the secret-management layer rather than repository files. See docs/configuration-reference.md for the full variable/secret inventory.

### Authentication rate limits

Authentication endpoints use PostgreSQL-backed fixed-window limits shared between ECS tasks. Defaults are 10 OAuth login starts, 20 callbacks, 30 refresh requests, and 60 logout requests per client address per five minutes. Rejected requests return HTTP 429 with Retry-After.

Non-local deployments must keep the backend private behind the ALB. Client address extraction trusts the final ALB-appended X-Forwarded-For address; do not expose the backend directly or change ALB forwarding behavior without revisiting this trust boundary.
