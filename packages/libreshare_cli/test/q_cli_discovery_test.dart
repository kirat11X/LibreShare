// Regression test for Q-CLI-DISCOVERY:
// 1. _awaitMatches settles promptly when device is already present in engine.currentDevices
// (The probe-reply path is covered by core test/integration/probe_ephemeral_reply_test.dart.)

import 'dart:async';
import 'dart:io';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/discovery/testing/in_memory_multicast.dart';
import 'package:test/test.dart';

class _NoIfaces implements NetworkInterfaceProvider {
  const _NoIfaces();
  @override
  Future<List<LocalInterface>> list() async => const [];
}

void main() {
  group('Q-CLI-DISCOVERY: _awaitMatches pre-existing devices', () {
    test(
      'settles promptly when device already in registry before await',
      () async {
        final bus = InMemoryMulticastBus();
        final rxTransport = bus.createTransport(address: '127.0.0.2');
        await rxTransport.start();

        // Announce a receiver on the bus
        final rxInfo = const DeviceInfo(
          deviceId: 'rx-id-0001',
          alias: 'rx-pre-existing',
          platform: 'linux',
          port: 53320,
          addrs: [DeviceAddress('127.0.0.2')],
        );

        // Create engine for send CLI command
        final txTransport = bus.createTransport(address: '127.0.0.3');
        final txEngine = LibreShareEngine(
          self: const DeviceInfo(
            deviceId: 'tx-id-0002',
            alias: 'tx-device',
            platform: 'linux',
          ),
          downloadDir: Directory.systemTemp,
          bindAddress: InternetAddress('127.0.0.3'),
          discovery: DiscoveryConfig(
            multicastTransport: () => txTransport,
            interfaces: const _NoIfaces(),
            autoScan: false,
            announceSchedule: const [],
            announceInterval: const Duration(hours: 1),
          ),
        );
        await txEngine.start();
        addTearDown(txEngine.stop);

        // Deliver announce to txEngine so it is in currentDevices
        txTransport.sendMulticast(encodeAnnounce(rxInfo, announce: true));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          txEngine.currentDevices.any((d) => d.info.alias == 'rx-pre-existing'),
          isTrue,
        );

        // Now run CLI send using find-timeout 5s. With immediate currentDevices check,
        // it must settle in < 1.5s instead of timing out at 5s.
        final sw = Stopwatch()..start();
        final out = <String>[];
        final err = <String>[];
        final code = await runCli(
          [
            'send',
            '--device',
            'rx-pre-existing',
            '--find-timeout',
            '5',
            '--insecure-plaintext',
          ],
          hooks: CliHooks(
            out: out.add,
            err: err.add,
            bindAddress: InternetAddress('127.0.0.3'),
            discovery: DiscoveryConfig(
              multicastTransport: () => txTransport,
              interfaces: const _NoIfaces(),
              autoScan: false,
              announceSchedule: const [],
              announceInterval: const Duration(hours: 1),
            ),
          ),
        );

        sw.stop();
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
        // It found the device immediately and then stopped at "no files given"
        expect(err.join('\n'), contains('no files given'));
        expect(code, 64);
      },
    );
  });
}
