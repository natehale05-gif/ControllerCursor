Console Mode is signed with a self-signed certificate ("Console Mode Signing") so
macOS keeps its Accessibility permission across updates. It is not an Apple
Developer ID; Gatekeeper still treats the app as unidentified.

The certificate and key live only in the repository secrets SIGNING_P12 (base64
of the .p12) and SIGNING_PASSWORD. The in-app updater only installs builds signed
with this certificate (SHA-1 7e003be47e971485c26b551c133545e48857bd9a).
