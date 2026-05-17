# Proxy Setup Guide

This guide covers how to set up a company proxy between Hold To Talk and an AI provider (OpenAI, Anthropic). The proxy holds the real API key, authenticates employees via SSO, and enforces usage policies.

## Architecture

```
Employee Mac                      Your infrastructure              AI Provider
┌──────────────┐                 ┌─────────────────────┐          ┌──────────────┐
│ Hold To Talk │ ── bearer ───>  │   OpenAI-compatible │ ── key ──> │  api.openai  │
│              │    token        │       proxy         │          │     .com     │
│ base URL:    │                 │                     │          └──────────────┘
│ proxy.corp   │                 │ - Okta/Entra ID JWT │
│ .com/v1      │                 │ - Rate limit        │
│              │                 │ - Audit log         │
│ API key:     │                 │ - Cost attribution  │
│ <okta token> │                 └─────────────────────┘
└──────────────┘
```

Hold To Talk calls the standard OpenAI endpoints (`/audio/transcriptions`, `/chat/completions`). The proxy validates the request, then forwards it to the real provider with the real API key.

## What the proxy needs to do

1. **Accept OpenAI-compatible requests** at the same paths (`/v1/audio/transcriptions`, `/v1/chat/completions`)
2. **Validate the bearer token** against your SSO (Okta, Entra ID, etc.)
3. **Forward the request** to the real provider with the real API key
4. **Return the response** unchanged
5. Optionally: rate limit, log, attribute costs

## Example: minimal Node.js proxy

```js
import express from "express";
import { createProxyMiddleware } from "http-proxy-middleware";
import OktaJwtVerifier from "@okta/jwt-verifier";

const app = express();

const oktaVerifier = new OktaJwtVerifier({
  issuer: "https://your-org.okta.com/oauth2/default",
});

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

// Authenticate every request
app.use(async (req, res, next) => {
  const token = req.headers.authorization?.replace("Bearer ", "");
  if (!token) return res.status(401).json({ error: "No token" });

  try {
    const jwt = await oktaVerifier.verifyAccessToken(token, "api://default");
    req.user = jwt.claims;
    next();
  } catch {
    return res.status(401).json({ error: "Invalid token" });
  }
});

// Optional: rate limiting per user
// app.use(rateLimit({ keyGenerator: (req) => req.user.sub, ... }));

// Optional: audit logging
app.use((req, res, next) => {
  console.log(JSON.stringify({
    event: "transcription_request",
    user: req.user.sub,
    timestamp: new Date().toISOString(),
    path: req.path,
    // Do NOT log request body (contains audio/text)
  }));
  next();
});

// Forward to OpenAI
app.use(
  "/v1",
  createProxyMiddleware({
    target: "https://api.openai.com",
    changeOrigin: true,
    pathRewrite: { "^/v1": "/v1" },
    onProxyReq: (proxyReq) => {
      proxyReq.setHeader("Authorization", `Bearer ${OPENAI_API_KEY}`);
    },
  })
);

app.listen(3000, () => console.log("Proxy running on :3000"));
```

## Example: minimal Python proxy

```python
from fastapi import FastAPI, Request, HTTPException
from httpx import AsyncClient
import jwt  # PyJWT

app = FastAPI()
OPENAI_API_KEY = "sk-..."
OKTA_ISSUER = "https://your-org.okta.com/oauth2/default"
OKTA_AUDIENCE = "api://default"

http = AsyncClient(base_url="https://api.openai.com")


async def verify_token(request: Request) -> dict:
    auth = request.headers.get("authorization", "")
    token = auth.removeprefix("Bearer ")
    if not token:
        raise HTTPException(401, "No token")
    try:
        # In production, fetch Okta JWKS and verify properly
        claims = jwt.decode(token, options={"verify_signature": True},
                           audience=OKTA_AUDIENCE, issuer=OKTA_ISSUER)
        return claims
    except jwt.InvalidTokenError:
        raise HTTPException(401, "Invalid token")


@app.api_route("/v1/{path:path}", methods=["GET", "POST"])
async def proxy(request: Request, path: str):
    user = await verify_token(request)

    # Audit log (no content)
    print(f"[audit] user={user['sub']} path=/v1/{path}")

    # Forward to OpenAI
    headers = dict(request.headers)
    headers["authorization"] = f"Bearer {OPENAI_API_KEY}"
    headers.pop("host", None)

    body = await request.body()
    resp = await http.request(
        method=request.method,
        url=f"/v1/{path}",
        headers=headers,
        content=body,
    )

    return resp.content
```

## Existing proxy solutions

You don't have to build your own. These work out of the box with Hold To Talk's base URL field:

| Solution | Type | SSO | Rate limiting | Cost tracking |
|----------|------|-----|---------------|---------------|
| **Azure OpenAI** | Managed | Entra ID | Built-in | Built-in |
| **LiteLLM Proxy** | Open-source | OIDC, API keys | Per-user | Per-user/team |
| **Helicone** | Hosted | SSO | Yes | Yes |
| **Portkey** | Hosted | SSO | Yes | Yes |

### Azure OpenAI

If you're already on Azure, this is the easiest path. Azure hosts the model, Entra ID handles auth, and you get per-user quotas and cost tracking for free.

```bash
# Hold To Talk configuration
defaults write com.holdtotalk.app openaiBaseURL -string "https://your-resource.openai.azure.com/openai/deployments/your-deployment"
```

### LiteLLM Proxy

Open-source, self-hosted. Supports 100+ LLM providers behind a single OpenAI-compatible endpoint.

```bash
# Run LiteLLM proxy
litellm --model openai/gpt-4o-mini-transcribe --port 4000

# Hold To Talk configuration
defaults write com.holdtotalk.app openaiBaseURL -string "https://litellm.corp.com/v1"
```

## SSO integration patterns

### Okta

1. Create an API application in Okta
2. Issue per-employee access tokens (or use client credentials flow for service accounts)
3. The token goes into Hold To Talk's API key field (or pushed via MDM Keychain script)
4. The proxy validates the JWT on every request

### Microsoft Entra ID (Azure AD)

1. Register an app in Entra ID
2. Assign employees to the app
3. Use managed identity or client credentials for the token
4. If using Azure OpenAI, Entra ID auth is native -- no separate proxy needed

### Generic OIDC

Any OIDC provider works. The proxy just needs to:
1. Accept a bearer token
2. Validate it against the provider's JWKS endpoint
3. Extract the user identity for logging/rate limiting

## Employee onboarding

Once the proxy is running and MDM configuration is pushed:

1. Employee installs Hold To Talk (Homebrew, DMG, or MDM)
2. App launches pre-configured with cloud provider and proxy URL
3. Employee grants macOS permissions (Microphone, Accessibility)
4. Employee starts dictating -- no API key management, no model download

If using Okta/OIDC tokens with expiration, you'll need a mechanism to refresh the token in Keychain periodically (a small background agent or login script).
