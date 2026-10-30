# Third-party notices and independent implementation

QuotaWatch's original code, build scripts and procedurally generated AppIcon
are provided under the MIT license in `LICENSE`. The icon is original geometric
art: no imported logos, fonts, stock images or OpenMinis assets are used.
Third-party names and trademarks remain the property of their respective owners;
no affiliation, endorsement or official-client status is implied.

## Protocol and interoperability references

These are references to public standards and service documentation, not bundled
source code or a claim to ownership of a service's protocols:

- OAuth 2.0: <https://www.rfc-editor.org/rfc/rfc6749>
- PKCE: <https://www.rfc-editor.org/rfc/rfc7636>
- OAuth for native apps / loopback redirect: <https://www.rfc-editor.org/rfc/rfc8252>
- OpenAI Codex public client/protocol reference (Apache-2.0 project):
  <https://github.com/openai/codex>
- DeepSeek balance API documentation:
  <https://api-docs.deepseek.com/api/get-user-balance>

QuotaWatch implements interoperability independently using platform frameworks.
Protocol names, endpoints, public OAuth client identifiers and documented JSON
field names are not represented as copied implementation code. Credentials are
user-provided; none are included in the project or build pipeline.

## Related product reference, not a dependency

[OpenMinis](https://github.com/OpenMinis/OpenMinis) is a separate GPL-3.0 project.
The general idea of displaying provider quotas may be inspired by comparable
products; QuotaWatch is not a fork and does not copy, link, bundle or relicense
OpenMinis source code, artwork or compiled components. Public protocols and
independently implemented ideas are distinct from that project's GPL-covered
implementation. The MIT license here covers only QuotaWatch's original material;
it does not replace any third party's license.

## Build-only tools (not included in the IPA)

- XcodeGen (MIT): <https://github.com/yonaskolb/XcodeGen>
- ldid (AGPL-3.0-or-later upstream tool): <https://git.saurik.com/ldid.git>
  and <https://formulae.brew.sh/formula/ldid>
- Python standard library (PSF): <https://docs.python.org/3/license.html>
- GitHub checkout action (MIT): <https://github.com/actions/checkout>
- GitHub upload-artifact action (MIT): <https://github.com/actions/upload-artifact>
- Apple Xcode, SDKs and system frameworks are subject to Apple's own terms.

These tools execute during development/CI; their executables or source are not
redistributed inside QuotaWatch. No third-party runtime package is added by this
build configuration. Any future bundled dependency must be reviewed and added
here with its required license text before distribution.
