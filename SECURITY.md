# Security policy

Report vulnerabilities privately through GitHub security advisories:
https://github.com/mcheemaa/mistri/security/advisories/new

Please do not open public issues for security reports. You will get a
response within a few days, and credit in the fix's release notes unless
you prefer otherwise.

Notes worth knowing when assessing reports:

- mistri has zero runtime dependencies; supply-chain surface is Ruby's
  standard library.
- Tokens and API keys are never logged by the gem and never persisted by
  the gem itself; storage is the host application's, and the generated
  Rails models encrypt token columns.
- Remote MCP and OAuth URLs default to public HTTPS. Mistri rejects credentials,
  fragments, private, loopback, link-local, shared, multicast, documentation,
  and reserved destinations; validates every DNS answer; and pins an approved
  address while preserving hostname-based TLS verification. Every connection
  cycle validates a fresh DNS set, including keep-alive reconnect cycles, and
  never falls back from an unsafe set to an old address. Approved candidates
  from one set are tried only before request transmission. MCP and server-side
  OAuth requests do not follow redirects or inherit ambient HTTP proxy settings.
  The user's browser resolves the authorization endpoint independently.
- A host can explicitly approve an internal HTTPS destination with
  `allow_non_public:`. Plain HTTP remains limited to an explicitly approved,
  actually resolved loopback address. The callback is part of the host's
  security boundary and should match both an expected hostname and IP range.
- OAuth protected-resource and issuer metadata are bound to exact identifiers.
  Pre-registered clients require the issuer trusted at registration, and token
  endpoints are rediscovered from that issuer before credentials are sent.
  OAuth response bodies are read incrementally with a 256 KiB limit and
  compression disabled; server-controlled descriptions are not copied into
  token errors.
