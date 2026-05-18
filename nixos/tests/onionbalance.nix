{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Generate a Tor v3 hs_ed25519_secret_key at build time using a fixed seed,
  # so the derivation is reproducible and requires no network access.
  #
  # The file format is: 32-byte header + 64-byte expanded ed25519 private key.
  # Header: b"== ed25519v1-secret: type0 ==\x00\x00\x00"
  # Expanded key: SHA-512(seed) with RFC 8032 clamping applied to the first half.
  masterKey = pkgs.runCommand "ob-test-master-key" {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (ps: [ ps.cryptography ]))
    ];
  } ''
    mkdir -p "$out"
    python3 - "$out/hs_ed25519_secret_key" <<'PYEOF'
import hashlib, sys

# Fixed seed — deterministic, not security-sensitive (test only).
seed = bytes(range(32))

h = hashlib.sha512(seed).digest()
a = bytearray(h[:32])
# RFC 8032 / libsodium clamping for the scalar
a[0] &= 248
a[31] &= 63
a[31] |= 64
expanded = bytes(a) + h[32:]

# Tor hs_ed25519_secret_key on-disk format
header = b"== ed25519v1-secret: type0 ==\x00\x00\x00"
with open(sys.argv[1], "wb") as f:
    f.write(header + expanded)
PYEOF
  '';

  # A syntactically valid v3 onion address (56 uppercase base32 chars) that
  # does not correspond to a real service.  OnionBalance will fail to fetch its
  # descriptor (expected without a full Tor network) but must not crash.
  fakeBackend = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.onion";
in
{
  name = "onionbalance";
  meta.maintainers = with lib.maintainers; [ ForgottenBeast ];

  nodes.machine =
    { config, ... }:
    {
      services.tor.onionbalance = {
        enable = true;
        services = [
          {
            key = "${masterKey}/hs_ed25519_secret_key";
            instances = [
              {
                address = fakeBackend;
                name = "backend1";
              }
            ];
          }
        ];
      };
    };

  testScript = ''
    machine.start()

    machine.wait_for_unit("tor.service")
    machine.wait_for_unit("onionbalance.service")

    # The control socket must exist once tor is up.
    machine.wait_until_succeeds("test -S /run/tor/control")

    # OnionBalance must have connected to the Tor control port.
    # stem logs "Controller opened" once the control connection is established.
    machine.wait_until_succeeds(
        "journalctl -u onionbalance.service | grep -qiE 'controller opened|connected to tor control'"
    )

    # Verify the systemd security hardening score (informational).
    machine.log(machine.succeed("systemd-analyze security onionbalance.service | grep -v '✓'"))
  '';
}
