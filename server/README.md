# Historical Gemini Web proxy patch (deprecated)

This patch predates the VPS browser-session manager and must not be applied to the current deployment. The active backend source is `/root/gemini-web-to-api` on the VPS. It uses a persistent Playwright browser profile and no `GEMINI_COOKIES` setting or separate cookie cache.

Upstream: https://github.com/ntthanh2603/gemini-web-to-api

Pinned commit: `363317054e02068f7f3e72a7a97a83f9597457e3`.

`image-input.patch` adds optional image data URL input to the existing generations endpoint, validates size/MIME and reuses the provider upload and authenticated image download. It requires a `PHOTOSERVER_API_KEY` on **every** route via the `X-PhotoServer-Key` request header, disables browser CORS, binds locally through `HOST`, limits request bodies to 36 MiB and generated images to 12 MiB. Existing text-only requests keep their shape.

Reproduce in a fresh upstream checkout at that commit with `git apply /path/to/image-input.patch`. Generate a high-entropy key (for example, `openssl rand -hex 32`) and put it in the root-protected `.env` as `PHOTOSERVER_API_KEY=...`; do not copy it to GitHub or into the IPA. Then run `go test ./internal/modules/openai/... ./internal/commons/configs/...` and rebuild the existing Docker service. Verify both that an unauthenticated `GET /health` returns 401 and that `curl -H "X-PhotoServer-Key: $PHOTOSERVER_API_KEY" http://127.0.0.1:4981/health` returns 200.

This historical patch used `HOST=127.0.0.1`, port 4981, one account and a 256 MiB memory ceiling. It is retained for provenance only. Current Google session state lives in the mode-0700 Chrome profile on the VPS; `PHOTOSERVER_API_KEY` remains in the root-protected `.env`. The live service exposes authenticated `/api/gemini/auth/*` routes and a short-lived, token-protected browser login flow.
