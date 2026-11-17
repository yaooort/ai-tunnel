# AppModel verification

The harness uses isolated UserDefaults, a unique Keychain service scoped to its Bundle ID, and temporary runtime and log directories. It removes its Keychain items, defaults and temporary files when it finishes. It prints result or state JSON, never credential contents or captured frpc logs. Development and manual configuration checks explicitly disable bundled presets. Preset checks inject only locally generated fake connection files and never read the private production preset.

Run isolated tests with the fake child process:

```bash
./tests/build-harness.sh
'./tests/.build/AppModel Harness.app/Contents/MacOS/AppModelHarness'
```

The 21 test groups cover empty public configuration defaults and safe address actions, manual settings save and restoration, Bundle ID isolation from personal settings, validation failures preserving active and stored settings, connected edit rejection, and no credential contents in logs or UserDefaults. They retain the preset, import, port, private file mode, proxy environment, redaction, duplicate instance, disconnect, truthful registration state, process recovery, retry cancellation, control connection recovery, log rotation and application exit checks.

Public builds have no preset and restore manually saved settings from their own Bundle ID's Keychain service. Personal builds retain preset priority at startup: a manual save updates the current session and Keychain, while the next launch still uses the bundled preset. Tests explicitly cover both behaviors.

To observe a real connection, rebuild with the distribution's bundled frpc:

```bash
./tests/build-harness.sh --frpc './dist/AI Tunnel.app/Contents/Resources/bin/frpc'
'./tests/.build/AppModel Harness.app/Contents/MacOS/AppModelHarness' \
  --connection /absolute/path/to/connection.json --port 8080 --duration 30
```

The real observation mode injects the selected file through the same preset startup path as the self-use application and does not import it into Keychain. It exits successfully only if proxy registration succeeded at least once. It stops its child and removes the temporary credential files on completion. It does not prove the HTTP/2 business response; verify that separately through the public HTTPS endpoint. Do not run isolated fake-process tests after rebuilding the harness with a real frpc.
