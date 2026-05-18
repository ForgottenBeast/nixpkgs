{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tor.onionbalance;
  runDir = "/run/onionbalance";

  configFile =
    (pkgs.formats.yaml { }).generate "onionbalance.yaml"
      {
        services = lib.imap0 (
          i: svc:
          {
            key = "${runDir}/key-${toString i}/hs_ed25519_secret_key";
            instances = map (
              inst:
              { inherit (inst) address; }
              // lib.optionalAttrs (inst.name != null) { inherit (inst) name; }
            ) svc.instances;
          }
        ) cfg.services;
      };

  # Runs as root in ExecStartPre to copy each master key into a runtime
  # directory owned by the onionbalance user, with correct permissions.
  keySetupScript = pkgs.writeShellScript "onionbalance-key-setup" (
    lib.concatStringsSep "\n" (
      [ "set -eu" ]
      ++ lib.imap0 (
        i: svc:
        ''
          install -d -o onionbalance -g onionbalance -m 0700 \
            ${runDir}/key-${toString i}
          install -o onionbalance -g onionbalance -m 0400 \
            ${lib.escapeShellArg svc.key} \
            ${runDir}/key-${toString i}/hs_ed25519_secret_key
        ''
      ) cfg.services
    )
  );
in
{
  options.services.tor.onionbalance = {
    enable = lib.mkEnableOption "OnionBalance, a load-balancer for Tor v3 onion services";

    package = lib.mkPackageOption pkgs "onionbalance" { };

    services = lib.mkOption {
      description = ''
        List of frontend onion services to load-balance.
        Each entry maps a master ED25519 key to a set of backend instances.

        Each backend instance must be configured with
        {option}`services.tor.relay.onionServices.<name>.settings.HiddenServiceOnionbalanceInstance`
        set to `true`, and its `HiddenServiceDir` must contain an
        `ob_config` file with `MasterOnionAddress <frontend-address>.onion`.
      '';
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            key = "/run/secrets/ob-frontend-hs_ed25519_secret_key";
            instances = [
              { address = "backend1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.onion"; name = "node1"; }
              { address = "backend2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.onion"; name = "node2"; }
            ];
          }
        ]
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            key = lib.mkOption {
              type = lib.types.externalPath;
              description = ''
                Path to the ED25519 secret key for this frontend onion service,
                in Tor's `hs_ed25519_secret_key` format
                (32-byte header `== ed25519v1-secret: type0 ==\x00\x00\x00`
                followed by 64 bytes of expanded private key).

                A privileged `ExecStartPre` step copies the file into a
                runtime directory owned by the `onionbalance` user; the
                original path is never read by the daemon directly.

                ::: {.warning}
                Use a quoted string path (e.g. `"/run/secrets/ob.key"`) rather
                than a Nix path literal, to prevent the key from being copied
                into the world-readable Nix store.
                :::
              '';
              example = "/run/agenix/ob-frontend.key";
            };

            instances = lib.mkOption {
              description = "Backend onion service instances to balance across.";
              default = [ ];
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    address = lib.mkOption {
                      type = lib.types.str;
                      description = "v3 `.onion` address of the backend instance.";
                      example = "backendxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.onion";
                    };
                    name = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Optional human-readable label for this backend.";
                      example = "node1";
                    };
                  };
                }
              );
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.services != [ ];
        message = "services.tor.onionbalance.enable requires at least one entry in services.tor.onionbalance.services";
      }
    ];

    # OnionBalance needs Tor running with a control socket and cookie auth.
    # All mkDefault so an operator who has already configured services.tor
    # explicitly is not overridden.
    services.tor = {
      enable = lib.mkDefault true;
      controlSocket.enable = lib.mkDefault true;
      settings = {
        CookieAuthentication = lib.mkDefault true;
        CookieAuthFileGroupReadable = lib.mkDefault true;
      };
    };

    users.users.onionbalance = {
      description = "OnionBalance daemon user";
      group = "onionbalance";
      # Membership in the tor group lets onionbalance read the cookie file
      # when CookieAuthFileGroupReadable = true in services.tor.settings.
      extraGroups = [ "tor" ];
      isSystemUser = true;
    };
    users.groups.onionbalance = { };

    systemd.services.onionbalance = {
      description = "OnionBalance onion service load balancer";
      documentation = [ "https://onionbalance.readthedocs.io/" ];

      requires = [ "tor.service" ];
      after = [ "tor.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ configFile ];

      serviceConfig = {
        Type = "simple";
        User = "onionbalance";
        Group = "onionbalance";

        RuntimeDirectory =
          [ "onionbalance" ]
          ++ lib.imap0 (i: _: "onionbalance/key-${toString i}") cfg.services;
        RuntimeDirectoryMode = "0700";
        StateDirectory = "onionbalance";
        StateDirectoryMode = "0700";

        # '+' prefix: runs as root so it can read key files at arbitrary paths.
        ExecStartPre = [ ("+" + keySetupScript) ];
        ExecStart = "${lib.getExe cfg.package} -v info -c ${configFile}";

        Restart = "on-failure";
        RestartSec = "30s";

        # Hardening — mirrors tor.nix where applicable.
        AmbientCapabilities = [ "" ];
        CapabilityBoundingSet = [ "" ];
        # ProtectClock= adds DeviceAllow=char-rtc r without this explicit deny.
        DeviceAllow = "";
        LockPersonality = true;
        # MemoryDenyWriteExecute must NOT be set: Python's cffi (used by the
        # cryptography library) requires anonymous writable+executable mappings.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        # OnionBalance never binds any ports, so PrivateUsers is always safe.
        PrivateUsers = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        UMask = "0066";
        SystemCallArchitectures = "native";
        SystemCallErrorNumber = "EPERM";
        SystemCallFilter = [
          "@system-service"
          "~@aio"
          "~@chown"
          "~@keyring"
          "~@memlock"
          "~@resources"
          "~@setuid"
          "~@timer"
        ];
      };
    };
  };

  meta.maintainers = with lib.maintainers; [ ForgottenBeast ];
}
