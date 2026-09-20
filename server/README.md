# Existing Gemini Web proxy patch

Upstream: https://github.com/ntthanh2603/gemini-web-to-api

Pinned commit: `363317054e02068f7f3e72a7a97a83f9597457e3`.

`image-input.patch` adds optional image data URL input to the existing generations endpoint, validates size/MIME and reuses the provider upload and authenticated image download. It requires a `PHOTOSERVER_API_KEY` on **every** route via the `X-PhotoServer-Key` request header, disables browser CORS, binds locally through `HOST`, limits request bodies to 36 MiB and generated images to 12 MiB. Existing text-only requests keep their shape.

Reproduce in a fresh upstream checkout at that commit with `git apply /path/to/image-input.patch`. Generate a high-entropy key (for example, `openssl rand -hex 32`) and put it in the root-protected `.env` as `PHOTOSERVER_API_KEY=...`; do not copy it to GitHub or into the IPA. Then run `go test ./internal/modules/openai/... ./internal/commons/configs/...` and rebuild the existing Docker service. Verify both that an unauthenticated `GET /health` returns 401 and that `curl -H "X-PhotoServer-Key: $PHOTOSERVER_API_KEY" http://127.0.0.1:4981/health` returns 200.

The service uses `HOST=127.0.0.1`, port 4981, one account and a 256 MiB memory ceiling. Keep the reverse proxy private to authenticated iOS clients; rate limiting is defense in depth, not authentication. Cookies and `PHOTOSERVER_API_KEY` live only in the root-protected `.env` and the provider's persistent cache. No public listener or new endpoint is introduced.
