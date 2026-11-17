# AppModel verification

The harness uses isolated UserDefaults, a unique Keychain service, temporary runtime and log directories. It removes its Keychain item, defaults and temporary files when it finishes. It prints result or state JSON, never credential contents or captured frpc logs. Legacy development checks explicitly disable bundled presets. Preset checks inject only locally generated fake connection files and never read the private production preset.

Run isolated tests with the fake child process:

```bash
./tests/build-harness.sh
'./tests/.build/AppModel Harness.app/Contents/MacOS/AppModelHarness'
```

The 15 test groups cover automatic startup with a valid preset and no Keychain item, preset priority without changing old Keychain data, invalid or missing presets failing without fallback or credential disclosure, legacy development imports and Keychain restoration, missing credentials, invalid local ports, private runtime file modes, proxy environment clearing, credential redaction in UI and disk logs, duplicate instance protection, disconnect cleanup, truthful proxy registration status, child process recovery, cancellation of scheduled retries, control connection recovery, bounded disk log rotation, and application exit cleanup.

To observe a real connection, rebuild with the distribution's bundled frpc:

```bash
./tests/build-harness.sh --frpc './dist/AI Tunnel.app/Contents/Resources/bin/frpc'
'./tests/.build/AppModel Harness.app/Contents/MacOS/AppModelHarness' \
  --connection /absolute/path/to/connection.json --port 8080 --duration 30
```

The real observation mode injects the selected file through the same preset startup path as the self-use application and does not import it into Keychain. It exits successfully only if proxy registration succeeded at least once. It stops its child and removes the temporary credential files on completion. It does not prove the HTTP/2 business response; verify that separately through the public HTTPS endpoint. Do not run isolated fake-process tests after rebuilding the harness with a real frpc.
