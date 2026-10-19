# Security and privacy

Please do not post API keys, session cookies, student IDs, exam questions, or authenticated course URLs in public issues.

The default connection opens the real ChatGPT, DeepSeek, Doubao or Gemini website, each in a separate persistent WebKit website store. Users handle login and verification themselves. It does not copy cookies from another browser or extract account tokens. Website prompts may enter that service's conversation history and use its account allowance.

Optional API keys are stored separately in macOS Keychain. Custom-service keys are scoped to an exact normalized HTTPS Base URL. Built-in API providers use fixed official destinations. API requests reject redirects and exclude website cookies. Injected page adapters run in separate WebKit content worlds and never receive API keys.

Web answers must match a fresh request nonce, complete JSON shape and website completion state. Automatic filling of agreed web drafts is off by default. Website links are not independently fetched or authenticated as evidence. New conversations do not disable provider memory, and model agreement cannot guarantee correctness. Sends are not automatically retried after dispatch.

Answers, retrieved pages, and imported banks are untrusted data. They cannot supply executable commands. The automation engine accepts a small set of explicit operations and validates the current question before writing.

Navigation diagnostics stay on the user's Mac and contain only schemes, hostnames, event types, and error codes. They exclude paths, query strings, forms, page contents, and cookies. Do not attach local diagnostics to public reports if they identify a private institution host.

Top-level legacy HTTP redirects are upgraded to HTTPS, including institutional landing domains. Paths and parameters are preserved; TLS verification remains enabled and there is no plaintext fallback. Custom institution domains are not added to the course-automation allowlist, and their HTTP subframes remain blocked.

Version 0.2.2 is a preview with 156 local checks. On 2026-10-19, a user completed real ChatGPT sign-in inside HoriStudy; native Chat and Work sample workflows each completed two fresh conversations and correlated answer readback without API requests. This does not establish a particular subscription tier, accuracy on coursework, or the other providers' account flows. Live coursework and course progress still require acceptance testing. It has not received an independent security audit or Apple notarization. Submit sensitive reports through the repository owner's GitHub contact options without exposing secrets publicly.
