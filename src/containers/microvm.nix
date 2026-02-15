{ inputs, cell }:

let
  mkMicrovm = inputs.std.lib.ops.mkMicrovm;
  lib = inputs.nixpkgs.lib;
  runtime = inputs.cells.nix.lib.runtimeShared;
  fuzzerEnv = inputs.cells.nix.lib.fuzzerEnv;

  # ==============================
  # 🔢 Resource calculation inputs
  # ==============================
  # Tune only these two most of the time:
  rssLimitMb = 1024; # Per-worker libFuzzer RSS cap (MB). Common values: 1024/2048.
  zramFraction = 0.15; # Fraction (0.0–1.0) of VM RAM reserved for zram. ~15% is a good sweet spot.

  # Reserve some RAM for the OS & daemons inside the VM so workers don’t starve the kernel.
  osOverheadGb = 2; # Kernel + systemd + shell + caches, ~2 GiB is safe for headless microVMs.
in
{
  libnet-fuzz-vm = mkMicrovm (
    { pkgs, config, ... }:

    let
      #############################################
      # ✅ Auto-calculate worker count and memory
      #############################################
      # We size *from* the VM RAM you set (microvm.mem), not the host.
      # microvm.mem is a positive integer in MiB.
      vmRamGb = config.microvm.mem / 1024.0;

      # RAM left for *userspace* after holding back OS overhead
      usableGbWithoutZram = vmRamGb - osOverheadGb;

      # After reserving zram (compressed swap living in RAM)
      usableGb = usableGbWithoutZram * (1.0 - zramFraction);

      # How many workers fit safely inside real RAM (no swap thrash):
      rawWorkers = (usableGb * 1024.0) / (rssLimitMb * 1.0);
      workerCount = lib.max 1 (builtins.floor rawWorkers); # never 0

      # Whole-service cgroup cap (keep a bit under usable RAM to avoid pressure spikes)
      # Use integer MB for systemd’s MemoryMax.
      memoryMaxGb = usableGbWithoutZram - 1.0; # 1 GiB safety margin
      memoryMaxMb = builtins.floor (memoryMaxGb * 1024.0);
      memoryMaxString = "${builtins.toString memoryMaxMb}M";

      # Export fuzzer toolchain env vars into an environment file the service can read
      fenv = inputs.cells.nix.lib.fuzzerEnv;
      fuzzer = inputs.cells.fuzzer.installables.default;

      envLines =
        lib.concatStringsSep "\n" (
          map (e: "${e.name}=" + (if e ? eval then e.eval else e.value)) fenv.toolchain.env
        )
        + "\n";

      #############################################
      # ✅ Fuzzer launcher script
      #############################################
      # Uses calculated workerCount instead of nproc
      runFuzzerScript = pkgs.writeShellScript "run-libnet-fuzzer" ''
        #!/usr/bin/env bash
        set -euo pipefail

        CORES=${builtins.toString workerCount}
        CORPUS="${runtime.corpusDir}"
        LOGS="${runtime.logsDir}"
        MERGE="${runtime.mergeFile}"

        mkdir -p "$CORPUS" "$LOGS"
        echo "⭐ Starting $CORES fuzz workers (auto-calculated)"

        export LD_PRELOAD="${fuzzerEnv.toolchain.libmnlCov}/lib/libmnl.so.0:${fuzzerEnv.toolchain.libnftnlCov}/lib/libnftnl.so.11"


        for i in $(seq 0 $((CORES - 1))); do
          "${fuzzer}/bin/${runtime.fuzzerBinary}" \
            -use_value_profile=1 \
            -entropic=1 \
            -reload=1 \
            -merge_control_file="$MERGE" \
            -max_len=512 \
            -rss_limit_mb="$RSS_MB" \
            -artifact_prefix="$CORPUS/" \
            -print_final_stats=1 \
            "$CORPUS" \
            >"$LOGS/fuzz-$i.log" 2>&1 &
        done

        echo "✅ Fuzzers launched"
        touch /run/fuzz-ready

        # Exit when the first worker dies; systemd will restart the service.
        wait -n
        exit 1
      '';
    in
    {
      microvm.host = { };

      system.stateVersion = "24.05";
      networking.hostName = "libnet-fuzz";
      boot.initrd.systemd.enable = true;

      #############################################
      # ✅ VM sizing: set mem once; workers auto-scale
      #############################################
      microvm = {
        hypervisor = "qemu"; # switch to "cloud-hypervisor" later if you want
        vcpu = workerCount; # match vCPUs to the number of workers we’ll launch
        mem = 65536; # MiB. Example: 16 GiB VM. Change this, everything else recomputes.

        # Ballooning introduces jitter under steady pressure like fuzzing → keep off.
        balloon = false;
        deflateOnOOM = false;

        # Shared directory for corpus/logs via virtiofs
        shares = [
          {
            proto = "virtiofs";
            tag = "fuzz-data";
            source = "fuzz-data";
            mountPoint = "/var/lib/libnet-fuzz";
            socket = "/tmp/virtiofsd-fuzz.sock";
          }
        ];
      };

      # Immutable Nix store image: squashfs builds fast; runtime perf is fine.
      microvm.storeDiskType = "squashfs";

      #############################################
      # ✅ ZRAM sizing from fraction (RAM-backed compressed swap)
      #############################################
      # We prefer zram to disk swap for fuzzing: no IO stalls and good results on non-random pages.
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = builtins.floor (zramFraction * 100.0); # e.g. 0.15 → 15
        priority = 100; # zram is used before any real swap
      };

      #############################################
      # ✅ sysctl tuned for libFuzzer & sanitizers
      #############################################
      boot.kernel.sysctl = {
        # Allow optimistic allocation; libFuzzer does a lot of mmap/munmap churn.
        "vm.overcommit_memory" = 1;

        # Prefer RAM, but still let zram absorb bursts.
        "vm.swappiness" = 15;

        # Keep ~128 MiB free so the kernel doesn’t lock up under pressure.
        "vm.min_free_kbytes" = 131072;

        # Don’t evict inode/dentry caches too aggressively; better FS lookup latency.
        "vm.vfs_cache_pressure" = 50;

        # Trickle out dirty pages to avoid large synchronous flush stalls.
        "vm.dirty_ratio" = 6;
        "vm.dirty_background_ratio" = 2;

        # If OOM happens, kill the task that asked for memory, not a random neighbor.
        "vm.oom_kill_allocating_task" = 1;

        # Sanitizers & fuzzers generate many small mmaps; raise the cap to avoid spurious failures.
        "vm.max_map_count" = 262144;
      };

      #############################################
      # ✅ Kernel args: fail fast, log via serial
      #############################################
      boot.kernelParams = [
        "panic=1" # reboot on panic
        "panic_on_oops=1" # treat kernel oops as panic
        "panic_on_oom=1" # if OOM reaches the kernel, hard fail (systemd restarts service)
        "console=ttyS0" # serial console (microVM best-practice)
      ];

      #############################################
      # ✅ Basic tooling in the VM
      #############################################
      environment.systemPackages = [
        fuzzer
        pkgs.bashInteractive
        pkgs.coreutils
        pkgs.procps
      ];
      environment.etc."libnet-env".text = envLines;

      # Direct root for quick serial console debugging (turn off for prod)
      users.users.root.initialPassword = "root";

      #############################################
      # ✅ Prepare fuzz directories
      #############################################
      systemd.services.prepare-fuzz-dirs = {
        wantedBy = [ "multi-user.target" ];
        before = [ "fuzzer.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = [
            "${pkgs.coreutils}/bin/mkdir -p ${runtime.corpusDir}"
            "${pkgs.coreutils}/bin/mkdir -p ${runtime.logsDir}"
            "${pkgs.coreutils}/bin/chmod 0777 ${runtime.corpusDir} ${runtime.logsDir}"
          ];
        };
      };

      #############################################
      # ✅ Fuzzer service with cgroup cap + auto workers
      #############################################
      systemd.services.fuzzer = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "prepare-fuzz-dirs.service" ];
        after = [ "prepare-fuzz-dirs.service" ];
        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = 2;
          WorkingDirectory = runtime.corpusDir;

          # Toolchain env from /etc/libnet-env (compiler paths, etc.)
          EnvironmentFile = "/etc/libnet-env";

          # Export per-worker RSS limit to the launcher script
          Environment = "RSS_MB=${builtins.toString rssLimitMb}";

          # Cap total memory for the whole service (prevents swap-death)
          MemoryMax = memoryMaxString;
          OOMPolicy = "kill";

          ExecStart = "${runFuzzerScript}";
        };
      };

      # Small marker unit that flips when fuzzers are up
      systemd.services.ready-flag = {
        wantedBy = [ "multi-user.target" ];
        after = [ "fuzzer.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/bash -c '[ -f /run/fuzz-ready ]'";
        };
      };
    }
  );
}
