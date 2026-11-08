// Regression test for Q-CLI-DISCOVERY:
// 1. _awaitMatches settles promptly when device is already present in engine.currentDevices
// 2. Multicast discovery probe replies are sent via multicast when source is loopback/default port

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

  group(
    'Q-CLI-DISCOVERY: multicast probe reply on loopback / default port',
    () {
      test('probe reply is broadcast to multicast when source is loopback or default port', () async {
        final bus = InMemoryMulticastBus();
        final rxTransport = bus.createTransport(
          address: '127.0.0.2',
          port: 53318,
        );
        final txTransport = bus.createTransport(
          address: '127.0.0.3',
          port: 53318,
        );

        final registry = PeerRegistry(selfDeviceId: 'rx-id-0001');
        final rxDiscovery = MulticastDiscovery(
          selfInfo: () => const DeviceInfo(
            deviceId: 'rx-id-0001',
            alias: 'rx-peer',
            platform: 'linux',
            port: 53320,
          ),
          transport: rxTransport,
          registry: registry,
          ifaces: const _NoIfaces(),
          probes: true,
          announceSchedule: const [],
          periodicInterval: const Duration(hours: 1),
        );
        await rxDiscovery.start();
        addTearDown(rxDiscovery.stop);
        await txTransport.start();
        addTearDown(txTransport.stop);

        // Clear any startup multicasts
        bus.sent.clear();

        // tx sends probe datagram (port 0, announce true)
        final probeInfo = const DeviceInfo(
          deviceId: 'tx-id-0002',
          alias: 'tx-peer',
          platform: 'linux',
          port: 0,
        );
        final probeBytes = encodeAnnounce(
          probeInfo,
          announce: true,
          probe: true,
        );

        // Inject packet with loopback source address into rxTransport
        rxTransport.inject(probeBytes, from: '127.0.0.1', fromPort: 53318);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Check bus: in addition to unicast reply, bus.multicasts must have the reply
        expect(bus.multicasts.isNotEmpty, isTrue);
        final replyPacket = bus.multicasts.first;
        final replyMsg = decodeAnnounce(replyPacket.data);
        expect(replyMsg, isNotNull);
        expect(replyMsg!.announce, isFalse);
        expect(replyMsg.info.alias, 'rx-peer');
      });
    },
  );
}
