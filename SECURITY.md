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
- MCP bearer tokens are refused over plain HTTP to non-loopback hosts, and
  authorization server endpoints are validated HTTPS.
