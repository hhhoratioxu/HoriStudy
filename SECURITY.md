# Security and privacy

Please do not post API keys, session cookies, student IDs, exam questions, or authenticated course URLs in public issues.

HoriStudy stores an OpenAI API key in macOS Keychain and uses a separate WebKit content world for page automation. The page adapter never receives the key. Requests go directly to the official OpenAI API. Browser sessions remain in this app's WebKit website store.

Answers, retrieved pages, and imported banks are untrusted data. They cannot supply executable commands. The automation engine accepts a small set of explicit operations and validates the current question before writing.

Navigation diagnostics stay on the user's Mac and contain only schemes, hostnames, event types, and error codes. They exclude paths, query strings, forms, page contents, and cookies. Do not attach local diagnostics to public reports if they identify a private institution host.

Version 0.1.1 is a preview with local fixture coverage. It has not received an independent security audit, an Apple notarization, or live-account acceptance testing. Submit sensitive reports through the repository owner's GitHub contact options without exposing secrets publicly.
