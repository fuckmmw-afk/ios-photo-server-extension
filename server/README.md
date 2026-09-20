# Existing Gemini Web proxy patch

Upstream: https://github.com/ntthanh2603/gemini-web-to-api

Pinned commit: `363317054e02068f7f3e72a7a97a83f9597457e3`.

`image-input.patch` adds optional image data URL input to the existing generations endpoint, validates size/MIME and reuses the provider upload and authenticated image download. Includes local HOST binding support and a 36 MiB request body limit. Existing text-only requests keep their shape.

Reproduce in a fresh upstream checkout at that commit with `git apply /path/to/image-input.patch`, then `go test ./internal/modules/openai/... ./internal/commons/configs/...` and rebuild the existing Docker service. Keep the session's existing `.env` locally; never copy it to GitHub.

The service uses `HOST=127.0.0.1`, port 4981, one account and a 256 MiB memory ceiling to accommodate large base64 request/response buffers. Its 10 requests/minute local limiter is not a statement about Google's quota. Cookies live only in the root-protected .env and the provider's persistent cache. No public listener or new endpoint is introduced.
