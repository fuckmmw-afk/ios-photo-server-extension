# Verification record

## CI

- 2026-09-20 `988552a` — successful build, IPA layout and five unit tests passed: https://github.com/fuckmmw-afk/ios-photo-server-extension/actions/runs/35533649825.
- Its Photos UI test was skipped before the CI gate was tightened; it is not evidence that the extension can be opened or saved from Photos.

## Server — 2026-09-20

- Existing Gemini Web service was patched and rebuilt in place. That deployment must be patched again with the current `PHOTOSERVER_API_KEY` authentication change before it is exposed to an iPhone.
- Go tests for OpenAI service/DTO and configuration pass.
- Live image-to-image test passed: the previous 33,429-byte test image containing a blue circle was uploaded, Gemini returned a 34,531-byte JPEG with the same composition and a green circle as requested. Output visually inspected. No new text-only image was substituted for input processing.
- Invalid image/base64 returns HTTP 400 before contacting Gemini.
- Listener verified as 127.0.0.1 only; approximately 10 MiB idle RAM, configured ceiling 256 MiB (not a measured worst-case consumption).
- The 25 MiB maximum input and high-resolution HEIC/P3 behavior still require device/large-file testing; synthetic unit tests do not prove those upstream guarantees.

Apple's renderedContentURL documentation was read directly: JPEG output must bake in orientation and declare up. The client copies upright JPEGs and renders oriented results upright before committing to Photos.

No physical iPhone has been tested by the agent. API availability, successful compilation, simulator menu discovery and actual same-asset/Revert behavior are separate claims.
