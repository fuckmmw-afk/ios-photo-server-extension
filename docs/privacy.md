# Privacy

PhotoServer sends the photograph selected in Apple Photos, its MIME type, and its display orientation to the PhotoServer URL that the person configuring the app enters. The server then sends that image to the Gemini Web service using the server operator's authenticated session.

The iOS client does not embed Gemini cookies or a server API key. The configured URL and API key are stored in the app's App Group so that only the containing app and its Photo Editing Extension can use them. Temporary request, response, and output files use complete file protection and are deleted when the editing session completes, is cancelled, or the next session starts.

The server operator is responsible for disclosing the server's access logs, backups, retention, jurisdiction, and Gemini/Google data handling before other people use that server. Do not expose the proxy without `PHOTOSERVER_API_KEY`, and do not use a shared key for untrusted users.

The client contains no analytics, advertising SDK, or tracking domain. Its bundled privacy manifest declares the Photos/Videos data used for app functionality and the App Group UserDefaults access required to share configuration with the extension.
