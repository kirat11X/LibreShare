// Inc 4 acceptance: D6 - pin continuity on every tier (docs/plans/inc4.md D6,
// section 4 "security/ladder_pin_test.dart", section 4.1 "fallback address
// owned by another device").
//
// A fallback candidate carries the pinned fingerprint of the peer. If the
// server at that address presents ANOTHER identity it must be refused, the
// refusal must be reported as a key change (PeerKeyChanged), never as a plain
// connection failure, and not one byte of the file may reach it. The PIN the
// user typed must never appear in an event or a log record.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

const String thePin = '654321';

List<LogRecord> captureLogs() {
  final old = Logger.root.level;
  Logger.root.level = Level.ALL;
  final records = <LogRecord>[];
  final sub = Logger.root.onRecord.listen(records.add);
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = old;
  });
  return records;
}

String flatten(Iterable<LogRecord> records) =>
    records.map((r) => '${r.message} ${r.error} ${r.stackTrace}').join('\n');

String dump(P6aNode n) => n.events.all
    .map(
      (e) => switch (e) {
        ChannelStateChanged(:final event) => 'channel: $event',
        SasReady(:final code) => 'sas: $code',
        _ => '${e.runtimeType}',
      },
    )
    .join('\n');

Future<void> main() async {
  final skip = await p6aSkipReason();
  late Directory sandbox;
  late P6aRig rig;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ls_inc4_pin_');
    rig = P6aRig(sandbox);
  });
  tearDown(() async {
    await rig.dispose();
    sandbox.deleteSync(recursive: true);
  });

  DiscoveredDevice deviceOf(
    String id,
    String alias,
    String fp,
    String ip, {
    required int port,
    List<String>? addrs,
  }) => DiscoveredDevice(
    info: DeviceInfo(
      deviceId: id,
      alias: alias,
      platform: 'linux',
      port: port,
      fingerprint: fp,
      addrs: [
        for (final a in addrs ?? [ip]) DeviceAddress(a),
      ],
    ),
    address: ip,
    lastSeen: DateTime.now(),
    source: DiscoverySource.multicast,
  );

  test('D6 guard fallback-other-identity-refused: tier 1 (Bob) is dead, '
      'tier 2 answers with Mallory\'s key -> refused, PeerKeyChanged, '
      'nothing sent to Mallory, the PIN is in no event', () async {
    final logs = captureLogs();
    final alice = await rig.start('Alice');
    final bob = await rig.start('Bob');
    final mallory = await rig.start('Mallory');
    final small = writeRandomFile(
      Directory('${sandbox.path}/src'),
      'hello.bin',
      4096,
    );
    // Alice pins Bob through a normal SAS-confirmed first contact.
    expect((await sendTo(alice, bob, [small])).isSuccess, isTrue);
    final bobPort = bob.port;
    final bobFp = bob.fp;
    final bobId = bob.deviceId;
    final malloryFp = mallory.fp;
    expect(malloryFp, isNot(bobFp));
    await rig.stop(bob); // tier 1 is now a dead address

    final victim = writeRandomFile(
      Directory('${sandbox.path}/src'),
      'secret.bin',
      3 * 1024 * 1024,
      seed: 7,
    );
    final tier1 = Candidate.create(
      kind: CandidateKind.wifi,
      host: bob.ip,
      port: bobPort,
      peerFingerprint: bobFp,
    );
    final tier2 = Candidate.create(
      kind: CandidateKind.lan,
      host: mallory.ip,
      port: mallory.port,
      peerFingerprint: bobFp, // the pin of the device we mean to reach
    );
    final send = alice.engine.beginSendToCandidates(
      deviceOf(
        bobId,
        'Bob',
        bobFp,
        bob.ip,
        port: bobPort,
        addrs: [bob.ip, mallory.ip],
      ),
      [victim],
      candidates: [tier1, tier2],
      enableFallback: true,
      pin: thePin,
      probeTimeout: const Duration(seconds: 3),
    );
    final res = await send.result.timeout(const Duration(seconds: 60));
    await settle(200);

    expect(res.status, isNot(TransferStatus.completed), reason: '$res');
    // Mallory received nothing: no session, no file, no partial.
    expect(
      mallory.events.of<SessionCreated>().where((e) => !e.outgoing),
      isEmpty,
      reason: 'Mallory saw an incoming session',
    );
    expect(
      mallory.rx.existsSync()
          ? mallory.rx.listSync(recursive: true).whereType<File>()
          : const <File>[],
      isEmpty,
      reason: 'bytes landed at the impostor',
    );
    // Never used as the channel.
    final active = alice.events
        .of<ChannelStateChanged>()
        .map((e) => e.event)
        .whereType<ChannelActive>()
        .where((a) => a.candidate.host == mallory.ip);
    expect(active, isEmpty, reason: 'the impostor became the active channel');
    // Reported as a key change, not as a plain connection failure.
    final changed = alice.events.of<PeerKeyChanged>();
    expect(
      changed,
      isNotEmpty,
      reason: 'no PeerKeyChanged; result=$res (reported as a plain failure?)',
    );
    expect(changed.first.deviceId, bobId);
    expect(changed.first.pinnedFingerprint, bobFp);
    expect(changed.first.presentedFingerprint, malloryFp);
    expect(res.failureReason, isNot(FailureReason.noConnection));
    // The PIN is nowhere.
    for (final blob in [dump(alice), dump(mallory), flatten(logs)]) {
      expect(blob.contains(thePin), isFalse, reason: 'PIN leaked');
    }
  }, skip: skip);

  test(
    'D6 guard pin-not-in-events: a PIN-protected send over a healthy '
    'two-candidate ladder completes and the PIN is in no event or log',
    () async {
      final logs = captureLogs();
      final alice = await rig.start('Alice');
      final bob = await rig.start(
        'Bob',
        pinPolicy: const PinPolicy(mode: PinMode.fixed),
        pin: thePin,
      );
      final f = writeRandomFile(
        Directory('${sandbox.path}/src'),
        'p.bin',
        9 * 1024 * 1024,
        seed: 3,
      );
      final good = Candidate.create(
        kind: CandidateKind.wifi,
        host: bob.ip,
        port: bob.port,
        peerFingerprint: bob.fp,
      );
      final spare = Candidate.create(
        kind: CandidateKind.lan,
        host: bob.ip,
        port: bob.port,
        peerFingerprint: bob.fp,
        id: 'lan:spare',
      );
      final send = alice.engine.beginSendToCandidates(
        deviceOf(bob.deviceId, 'Bob', bob.fp, bob.ip, port: bob.port),
        [f],
        candidates: [good, spare],
        pin: thePin,
      );
      final res = await send.result.timeout(const Duration(seconds: 60));
      await settle(200);
      expect(res.status, TransferStatus.completed, reason: '$res');
      await expectSameFile(f, File('${bob.rx.path}/p.bin'));
      for (final blob in [dump(alice), dump(bob), flatten(logs)]) {
        expect(blob.contains(thePin), isFalse, reason: 'PIN leaked');
      }
    },
    skip: skip,
  );
}
