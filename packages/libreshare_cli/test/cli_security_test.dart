// The CLI in the secure profile (Increment 3, work package P6a): real `ls` processes over loopback,
// plus the offline commands (`identity`, `contacts`) through runCli().
//
// Spec: LSP-1 5.1 (SAS: the receiver never auto-accepts a commitment; TOFU pins after the users
// accepted), 5.2 (PIN), 5.3 (pairing URI and flow), 5.4 (Contacts-only), 4.7 (never negotiated down),
// docs/plans/inc3.md D3/D6/D7, section 5 row P6a, section 9b (advertise-ip, identity directory,
// Broken pipe) and section 11 (the CLI defaults to TLS; `--insecure-plaintext` selects the Inc 1/2
// wire).
//
// Output lines this file fixes (the coder implements to them):
//   SAS 482 913 peer=<alias> fp=<16 hex>      on BOTH sides, fp = the PEER's first 16 hex, uppercase
//   ID <uuid>  /  FINGERPRINT <64 hex>        `ls identity show` (and `identity rotate`, new values)
//   CONTACT <id> trust=<known|trusted|blocked> fp=<16 hex> alias=<alias>   then   CONTACTS <n>
//   PAIR <libreshare://pair URI>              `ls pair --show`, printed once the listener is up
//   PAIR-REQUEST <alias> fp=<16 hex>          `pair --show`, before it asks "Pair? [y/N]" on stdin
//   PAIRED <alias> fp=<16 hex>                on both sides when the pairing succeeded
//   PIN <6 digits>                            `receive --pin auto`, exactly once
// Exit codes (new, none collides with 0, 1, 64, 66): see the constants below.
//
// SPEC-GAP list (safer reading chosen, also in docs/plans/inc3-p6a-tests.md):
//  1. `--insecure-tofu`: no human compares codes; the SAS line is still printed on both sides, the
//     sender continues without asking, and a receiver that also has `--auto-accept` accepts the
//     SAS session without asking (without `--auto-accept` the accept prompt stays). Without the flag a
//     missing answer (EOF on stdin) is "no".
//  2. `receive --pin PIN` fixed PIN, `--pin auto` generates one and prints `PIN nnnnnn`.
//  3. An unanswered prompt never keeps a process alive once the result is known.
//  4. `contacts add --id UUID --fp 64HEX [--alias A] [--trust known|trusted]`, `contacts remove ID`
//     (unknown id: exit 1), `contacts block FP`, `contacts unblock FP`, `contacts list`.
//  5. `send --allow-insecure` makes the engine speak plaintext to a peer that has no fingerprint.
//  6. Exit codes of refusals come from `SendResult.refusal` (the wire LsErrorCode, decided by the
//     orchestrator): KEY_CHANGED -> 80, PIN_REQUIRED/PIN_INVALID/BLOCKED/AUTH_INVALID -> 82. A key
//     change seen by the sender (PeerFingerprintMismatchException) is 80 as well, InsecurePeerException
//     81, SasAbortedException 83, IdentityLost 84. The engine tests assert the refusal values
//     (engine_tofu_test, secure_two_engine_test, unit/send_result_refusal_test).
@Timeout(Duration(minutes: 4))
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_cli/ls_cli.dart';
import 'package:test/test.dart';

const String loopback = '127.0.0.1';
final String sep = Platform.pathSeparator;

/// The peer's key is not the pinned one / the sender's key is not the one the receiver pinned.
const int exitKeyChanged = 80;

/// The peer speaks the plaintext profile (or has no fingerprint) and `--allow-insecure` was not given.
const int exitInsecurePeer = 81;

/// PIN required / wrong / blocked, bad pairing secret: authentication or authorisation refused.
const int exitAuthRefused = 82;

/// The SAS comparison was refused or could not be completed.
const int exitSasAborted = 83;

/// The identity exists but its key is gone (never silently regenerated).
const int exitIdentityLost = 84;

final RegExp sasRe = RegExp(
  r'^SAS (\d{3}) (\d{3}) peer=(.+) fp=([0-9A-F]{16})$',
);
final RegExp contactRe = RegExp(
  r'^CONTACT (\S+) trust=(known|trusted|blocked) fp=([0-9A-F]{16}) alias=(.*)$',
);

late Directory tmp;
late Directory buildDir;
late String dill;

String? _findCliEntry() {
  var dir = Directory.current.absolute;
  while (true) {
    for (final rel in [
      ['bin', 'ls.dart'],
      ['packages', 'libreshare_cli', 'bin', 'ls.dart'],
    ]) {
      final f = File([dir.path, ...rel].join(sep));
      if (f.existsSync()) return f.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// A running `ls` process with its output collected line by line.
class Ls {
  Ls._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stdoutLines.add, onDone: _outDone.complete);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(stderrLines.add, onDone: _errDone.complete);
    process.exitCode.then((c) => exited = c);
  }

  final Process process;
  final List<String> stdoutLines = [];
  final List<String> stderrLines = [];
  final Completer<void> _outDone = Completer<void>();
  final Completer<void> _errDone = Completer<void>();

  /// Set when the process ended.
  int? exited;

  static Future<Ls> start(List<String> args) async =>
      Ls._(await Process.start(Platform.resolvedExecutable, [dill, ...args]));

  String get stdout => stdoutLines.join('\n');
  String get stderr => stderrLines.join('\n');
  String get everything => '$stdout\n$stderr';

  /// First stdout line matching [re], waiting up to [timeout].
  Future<RegExpMatch> waitForLine(
    RegExp re, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final sw = Stopwatch()..start();
    while (true) {
      for (final l in stdoutLines) {
        final m = re.firstMatch(l);
        if (m != null) return m;
      }
      if (exited != null) {
        throw StateError(
          'process ended ($exited) before a line matching $re.\n'
          'stdout:\n$stdout\nstderr:\n$stderr',
        );
      }
      if (sw.elapsed > timeout) {
        throw TimeoutException(
          'no stdout line matching $re within $timeout.\n'
          'stdout:\n$stdout\nstderr:\n$stderr',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Types a line on the terminal.
  void answer(String line) {
    try {
      process.stdin.writeln(line);
    } on Object {
      // the process may be gone already
    }
  }

  Future<void> eof() async {
    try {
      await process.stdin.close();
    } on Object {
      // already closed
    }
  }

  /// Waits for the process to exit and for its output to be drained.
  Future<int> exit([Duration timeout = const Duration(seconds: 40)]) async {
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          'process did not exit within $timeout.\n'
          'stdout:\n$stdout\nstderr:\n$stderr',
        );
      },
    );
    await _outDone.future.timeout(const Duration(seconds: 5));
    await _errDone.future.timeout(const Duration(seconds: 5));
    return code;
  }

  void kill() => process.kill();
}

File writeFile(String name, int size, int seed) {
  final r = Random(seed);
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = r.nextInt(256);
  }
  return File('${tmp.path}$sep$name')..writeAsBytesSync(bytes);
}

bool sameBytes(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

List<String> leftovers(Directory dir) => [
  for (final e in dir.listSync(recursive: true, followLinks: false))
    if (e.path.split(sep).last.contains('.lspart')) e.path,
];

Directory dir(String name) => Directory('${tmp.path}$sep$name');

/// `runCli` in-process; returns exit code, stdout lines and stderr lines.
Future<({int code, List<String> out, List<String> err})> cli(
  List<String> args,
) async {
  final out = <String>[];
  final err = <String>[];
  final code = await runCli(
    args,
    hooks: CliHooks(out: out.add, err: err.add, handleSignals: false),
  );
  return (code: code, out: out, err: err);
}

/// Device id and fingerprint of the identity in [identityDir] (created on first use).
Future<({String id, String fp})> identityOf(Directory identityDir) async {
  final r = await cli(['identity', 'show', '--identity-dir', identityDir.path]);
  expect(r.code, 0, reason: 'identity show failed: ${r.err}');
  final id = r.out
      .map((l) => RegExp(r'^ID (\S+)$').firstMatch(l)?.group(1))
      .whereType<String>()
      .single;
  final fp = r.out
      .map(
        (l) => RegExp(r'^FINGERPRINT ([0-9A-F]{64})$').firstMatch(l)?.group(1),
      )
      .whereType<String>()
      .single;
  return (id: id, fp: fp);
}

/// Contacts in [identityDir] by device id.
Future<Map<String, RegExpMatch>> contactsIn(Directory identityDir) async {
  final r = await cli(['contacts', 'list', '--identity-dir', identityDir.path]);
  expect(r.code, 0, reason: '${r.err}');
  final byId = <String, RegExpMatch>{};
  for (final l in r.out) {
    final m = contactRe.firstMatch(l);
    if (m != null) byId[m.group(1)!] = m;
  }
  expect(r.out.last, 'CONTACTS ${byId.length}');
  return byId;
}

Future<int> closedPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  final running = <Ls>[];

  setUpAll(() async {
    final entry =
        _findCliEntry() ??
        (throw StateError('packages/libreshare_cli/bin/ls.dart not found'));
    buildDir = Directory.systemTemp.createTempSync('ls_cli_sec_build_');
    dill = '${buildDir.path}${sep}ls.dill';
    final r = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      entry,
      '-o',
      dill,
    ]);
    if (r.exitCode != 0) {
      fail(
        'dart compile kernel failed (${r.exitCode}):\n${r.stdout}\n${r.stderr}',
      );
    }
  });

  tearDownAll(() => buildDir.deleteSync(recursive: true));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_cli_sec_');
  });

  tearDown(() {
    for (final p in running) {
      p.kill();
    }
    running.clear();
    tmp.deleteSync(recursive: true);
  });

  Future<Ls> start(List<String> args) async {
    final p = await Ls.start(args);
    running.add(p);
    return p;
  }

  /// Runs to completion with stdin at EOF (no terminal).
  Future<Ls> runLs(List<String> args) async {
    final p = await start(args);
    await p.eof();
    await p.exit();
    return p;
  }

  /// A receiver process (secure unless [extra] says otherwise) that is listening.
  Future<({Ls proc, int port})> startReceiver(
    Directory id,
    Directory rx, {
    List<String> extra = const [],
    String alias = 'cli-rx',
  }) async {
    final p = await start([
      'receive',
      '--port',
      '0',
      '--dir',
      rx.path,
      '--identity-dir',
      id.path,
      '--alias',
      alias,
      ...extra,
    ]);
    final m = await p.waitForLine(RegExp(r'^LISTENING .* port=(\d+) '));
    return (proc: p, port: int.parse(m.group(1)!));
  }

  Future<Ls> startSender(
    Directory id,
    int port,
    List<File> files, {
    List<String> extra = const [],
    String alias = 'cli-tx',
  }) => start([
    'send',
    '--to',
    '$loopback:$port',
    '--identity-dir',
    id.path,
    '--alias',
    alias,
    ...extra,
    ...files.map((f) => f.path),
  ]);

  Future<void> pause([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // ------------------------------------------------------------------ identity
  // docs/plans/inc3.md D3, D6, D7.
  group('ls identity', () {
    test('show creates an identity once and prints the same ID and FINGERPRINT every time; another directory is another identity', () async {
      final a = await identityOf(dir('a'));
      final again = await identityOf(dir('a'));
      expect(again.id, a.id);
      expect(again.fp, a.fp);
      expect(a.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      final other = await identityOf(dir('b'));
      expect(other.id, isNot(a.id));
      expect(other.fp, isNot(a.fp));
    });

    test('rotate keeps the device id and gives a new key; show then prints the new fingerprint', () async {
      final before = await identityOf(dir('a'));
      final r = await cli([
        'identity',
        'rotate',
        '--identity-dir',
        dir('a').path,
      ]);
      expect(r.code, 0, reason: '${r.err}');
      final shown = r.out
          .map(
            (l) =>
                RegExp(r'^FINGERPRINT ([0-9A-F]{64})$').firstMatch(l)?.group(1),
          )
          .whereType<String>();
      expect(shown, hasLength(1));
      final after = await identityOf(dir('a'));
      expect(after.id, before.id);
      expect(after.fp, isNot(before.fp));
      expect(shown.single, after.fp);
    });

    test('the private key file is mode 0600 and nothing in the directory is group/world readable', () async {
      await identityOf(dir('a'));
      var found = 0;
      for (final e in dir('a').listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (utf8
            .decode(e.readAsBytesSync(), allowMalformed: true)
            .contains('PRIVATE KEY')) {
          found++;
          expect(e.statSync().mode & 0x1ff, 0x180, reason: e.path);
        }
      }
      expect(
        found,
        greaterThan(0),
        reason: 'twin: the harness found the key file',
      );
    }, skip: Platform.isWindows ? 'POSIX modes' : null);

    test('a missing key is IdentityLost (exit 84), is reported, and nothing is regenerated; commands that need the identity refuse too', () async {
      final first = await identityOf(dir('a'));
      final meta = File('${dir('a').path}${sep}identity.json');
      final metaBefore = meta.readAsBytesSync();
      for (final e in dir('a').listSync(recursive: true, followLinks: false)) {
        if (e is File &&
            utf8
                .decode(e.readAsBytesSync(), allowMalformed: true)
                .contains('PRIVATE KEY')) {
          e.deleteSync();
        }
      }
      final show = await cli([
        'identity',
        'show',
        '--identity-dir',
        dir('a').path,
      ]);
      expect(show.code, exitIdentityLost);
      expect(show.err.join('\n'), isNot(contains('Unhandled')));
      expect(show.out.join('\n'), isNot(contains(first.fp)));
      expect(
        meta.readAsBytesSync(),
        metaBefore,
        reason: 'identity.json untouched',
      );

      final rx = await runLs([
        'receive',
        '--port',
        '0',
        '--dir',
        dir('rx').path,
        '--identity-dir',
        dir('a').path,
        '--once',
      ]);
      expect(rx.exited, exitIdentityLost);
      expect(rx.stdout, isNot(contains('LISTENING')));
      final again = await cli([
        'identity',
        'show',
        '--identity-dir',
        dir('a').path,
      ]);
      expect(
        again.code,
        exitIdentityLost,
        reason: 'still lost, never silently regenerated',
      );
    });

    test(
      'usage errors: unknown subcommand and missing subcommand -> 64',
      () async {
        final ok = await cli([
          'identity',
          'show',
          '--identity-dir',
          dir('a').path,
        ]);
        expect(ok.code, 0, reason: 'twin: the valid form works: ${ok.err}');
        expect((await cli(['identity', 'bogus'])).code, 64);
        expect((await cli(['identity'])).code, 64);
      },
    );
  });

  // ------------------------------------------------------------------ contacts
  group('ls contacts', () {
    final fpDana = 'AB${'0' * 62}';
    final idDana = '11111111-1111-4111-8111-111111111111';
    List<String> ids(String name) => ['--identity-dir', dir(name).path];

    test('list is empty at first; add, list, remove; a trusted contact shows its level', () async {
      expect((await cli(['contacts', 'list', ...ids('a')])).out, [
        'CONTACTS 0',
      ]);
      final add = await cli([
        'contacts',
        'add',
        '--id',
        idDana,
        '--fp',
        fpDana,
        '--alias',
        'Dana',
        ...ids('a'),
      ]);
      expect(add.code, 0, reason: '${add.err}');
      var list = await contactsIn(dir('a'));
      expect(list.keys, [idDana]);
      expect(list[idDana]!.group(2), 'known');
      expect(list[idDana]!.group(3), fpDana.substring(0, 16));
      expect(list[idDana]!.group(4), 'Dana');

      final idEve = '22222222-2222-4222-8222-222222222222';
      expect(
        (await cli([
          'contacts',
          'add',
          '--id',
          idEve,
          '--fp',
          'CD${'0' * 62}',
          '--alias',
          'Eve',
          '--trust',
          'trusted',
          ...ids('a'),
        ])).code,
        0,
      );
      list = await contactsIn(dir('a'));
      expect(list[idEve]!.group(2), 'trusted');

      expect((await cli(['contacts', 'remove', idDana, ...ids('a')])).code, 0);
      list = await contactsIn(dir('a'));
      expect(list.keys, [idEve]);
    });

    test(
      'the contact list survives (it is a file in the identity directory)',
      () async {
        await cli([
          'contacts',
          'add',
          '--id',
          idDana,
          '--fp',
          fpDana,
          '--alias',
          'Dana',
          ...ids('a'),
        ]);
        expect((await contactsIn(dir('a'))).keys, [idDana]);
        expect(
          (await contactsIn(dir('b'))).keys,
          isEmpty,
          reason: 'another directory has its own list',
        );
      },
    );

    test('block and unblock; a blocked contact is listed as blocked, unblocking restores it', () async {
      await cli([
        'contacts',
        'add',
        '--id',
        idDana,
        '--fp',
        fpDana,
        '--alias',
        'Dana',
        ...ids('a'),
      ]);
      expect((await cli(['contacts', 'block', fpDana, ...ids('a')])).code, 0);
      expect((await contactsIn(dir('a')))[idDana]!.group(2), 'blocked');
      expect((await cli(['contacts', 'unblock', fpDana, ...ids('a')])).code, 0);
      expect((await contactsIn(dir('a')))[idDana]!.group(2), 'known');
      // A fingerprint of nobody we know can be blocked as well.
      expect(
        (await cli(['contacts', 'block', 'EF${'0' * 62}', ...ids('a')])).code,
        0,
      );
    });

    test('adding a known device id with another key is a key change (exit 80) and keeps the pin', () async {
      await cli([
        'contacts',
        'add',
        '--id',
        idDana,
        '--fp',
        fpDana,
        '--alias',
        'Dana',
        ...ids('a'),
      ]);
      final r = await cli([
        'contacts',
        'add',
        '--id',
        idDana,
        '--fp',
        'CD${'0' * 62}',
        '--alias',
        'Dana',
        ...ids('a'),
      ]);
      expect(r.code, exitKeyChanged);
      expect(
        (await contactsIn(dir('a')))[idDana]!.group(3),
        fpDana.substring(0, 16),
      );
    });

    test('usage errors -> 64; removing an unknown contact -> 1', () async {
      expect(
        (await cli(['contacts', 'add', '--id', idDana, ...ids('a')])).code,
        64,
        reason: 'no --fp',
      );
      expect(
        (await cli(['contacts', 'add', '--fp', fpDana, ...ids('a')])).code,
        64,
        reason: 'no --id',
      );
      expect(
        (await cli([
          'contacts',
          'add',
          '--id',
          idDana,
          '--fp',
          'xyz',
          ...ids('a'),
        ])).code,
        64,
        reason: 'bad fp',
      );
      expect(
        (await cli([
          'contacts',
          'add',
          '--id',
          'not-a-uuid',
          '--fp',
          fpDana,
          ...ids('a'),
        ])).code,
        64,
      );
      expect((await cli(['contacts', 'block', 'zz', ...ids('a')])).code, 64);
      expect((await cli(['contacts', 'bogus', ...ids('a')])).code, 64);
      expect((await cli(['contacts'])).code, 64);
      expect((await cli(['contacts', 'remove', idDana, ...ids('a')])).code, 1);
    });
  });

  // ------------------------------------------------------------------ first contact
  group('secure transfer between two processes', () {
    test('first contact: SAS line on both sides with equal digits and the peer\'s fingerprint; --auto-accept does not skip the comparison; then both pin; the second send needs no SAS', () async {
      final rd = dir('rid');
      final sd = dir('sid');
      final rid = await identityOf(rd);
      final sid = await identityOf(sd);
      final rx = dir('rx');
      final f = writeFile('hello.bin', 4 * 1024 * 1024 + 500000, 1);

      final recv = await startReceiver(
        rd,
        rx,
        extra: ['--auto-accept', '--once'],
      );
      final send = await startSender(sd, recv.port, [f]);

      final sasTx = await send.waitForLine(sasRe);
      final sasRx = await recv.proc.waitForLine(sasRe);
      expect(
        '${sasTx.group(1)} ${sasTx.group(2)}',
        '${sasRx.group(1)} ${sasRx.group(2)}',
        reason: 'both users see the same six digits',
      );
      expect(
        sasTx.group(3),
        'cli-rx',
        reason: 'the sender shows the receiver\'s alias',
      );
      expect(
        sasRx.group(3),
        'cli-tx',
        reason: 'the receiver shows the sender\'s alias',
      );
      expect(
        sasTx.group(4),
        rid.fp.substring(0, 16),
        reason: 'sender shows the RECEIVER\'s fingerprint',
      );
      expect(
        sasRx.group(4),
        sid.fp.substring(0, 16),
        reason: 'receiver shows the SENDER\'s fingerprint',
      );

      // --auto-accept must not skip the human comparison.
      await pause(800);
      expect(
        recv.proc.stdoutLines.where((l) => l.startsWith('RECEIVED ')),
        isEmpty,
      );
      expect(recv.proc.exited, isNull);
      expect(send.exited, isNull);
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);

      recv.proc.answer('y');
      send.answer('y');
      expect(await send.exit(), 0, reason: send.everything);
      expect(await recv.proc.exit(), 0, reason: recv.proc.everything);
      expect(send.stdoutLines.last, 'COMPLETED');
      expect(sameBytes(f, File('${rx.path}${sep}hello.bin')), isTrue);
      expect(leftovers(rx), isEmpty);

      // Pinned both ways.
      final tx = await contactsIn(sd);
      expect(tx.keys, [rid.id]);
      expect(tx[rid.id]!.group(2), 'known');
      expect(tx[rid.id]!.group(3), rid.fp.substring(0, 16));
      final rc = await contactsIn(rd);
      expect(rc.keys, [sid.id]);
      expect(rc[sid.id]!.group(3), sid.fp.substring(0, 16));

      // The second send, to a fresh receiver process with the same identity: no SAS anywhere.
      final f2 = writeFile('again.bin', 1234, 2);
      final recv2 = await startReceiver(
        rd,
        rx,
        extra: ['--auto-accept', '--once'],
      );
      final send2 = await runLs([
        'send',
        '--to',
        '$loopback:${recv2.port}',
        '--identity-dir',
        sd.path,
        '--alias',
        'cli-tx',
        f2.path,
      ]);
      expect(send2.exited, 0, reason: send2.everything);
      expect(await recv2.proc.exit(), 0, reason: recv2.proc.everything);
      expect(send2.stdout, isNot(contains('SAS')));
      expect(recv2.proc.stdout, isNot(contains('SAS')));
      expect(sameBytes(f2, File('${rx.path}${sep}again.bin')), isTrue);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the receiver answers n after the SAS: both FAILED REJECTED (exit 1), nothing pinned, nothing written', () async {
      final rid = await identityOf(dir('rid'));
      final sid = await identityOf(dir('sid'));
      final rx = dir('rx');
      final recv = await startReceiver(
        dir('rid'),
        rx,
        extra: ['--auto-accept', '--once'],
      );
      final send = await startSender(dir('sid'), recv.port, [
        writeFile('x.bin', 500, 3),
      ]);
      await send.waitForLine(sasRe);
      await recv.proc.waitForLine(sasRe);
      recv.proc.answer('n');
      expect(
        await send.exit(),
        1,
        reason:
            'the sender must not hang on its own unanswered prompt: ${send.everything}',
      );
      expect(send.stdoutLines.last, 'FAILED REJECTED');
      expect(await recv.proc.exit(), 1);
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);
      expect(await contactsIn(dir('sid')), isEmpty);
      expect(await contactsIn(dir('rid')), isEmpty);
      expect(rid.id, isNot(sid.id));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('the sender answers n: exit 83 (SAS aborted), the receiver\'s session fails, nothing pinned', () async {
      await identityOf(dir('rid'));
      await identityOf(dir('sid'));
      final rx = dir('rx');
      final recv = await startReceiver(
        dir('rid'),
        rx,
        extra: ['--auto-accept', '--once'],
      );
      final send = await startSender(dir('sid'), recv.port, [
        writeFile('x.bin', 500, 4),
      ]);
      await send.waitForLine(sasRe);
      await recv.proc.waitForLine(sasRe);
      send.answer('n');
      expect(await send.exit(), exitSasAborted, reason: send.everything);
      expect(send.stderr, isNot(contains('Unhandled')));
      expect(
        await recv.proc.exit(),
        1,
        reason: 'the cancelled session ends the receiver (--once)',
      );
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);
      expect(await contactsIn(dir('sid')), isEmpty);
      expect(await contactsIn(dir('rid')), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('without a terminal and without --insecure-tofu the sender cannot confirm the codes: exit 83', () async {
      await identityOf(dir('rid'));
      await identityOf(dir('sid'));
      final recv = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: ['--once'],
      );
      final send = await startSender(dir('sid'), recv.port, [
        writeFile('x.bin', 500, 5),
      ]);
      await send.eof();
      expect(await send.exit(), exitSasAborted, reason: send.everything);
      recv.proc.answer('n');
      await recv.proc.exit();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('--insecure-tofu on both sides: the SAS lines are still printed, nobody is asked, the transfer completes and both pin', () async {
      final rid = await identityOf(dir('rid'));
      final sid = await identityOf(dir('sid'));
      final rx = dir('rx');
      final f = writeFile('tofu.bin', 7777, 6);
      final recv = await startReceiver(
        dir('rid'),
        rx,
        extra: ['--auto-accept', '--insecure-tofu', '--once'],
      );
      await recv.proc.eof();
      final send = await startSender(
        dir('sid'),
        recv.port,
        [f],
        extra: ['--insecure-tofu'],
      );
      await send.eof();
      expect(await send.exit(), 0, reason: send.everything);
      expect(await recv.proc.exit(), 0, reason: recv.proc.everything);
      expect(send.stdoutLines.where(sasRe.hasMatch), hasLength(1));
      expect(recv.proc.stdoutLines.where(sasRe.hasMatch), hasLength(1));
      expect(sameBytes(f, File('${rx.path}${sep}tofu.bin')), isTrue);
      expect((await contactsIn(dir('sid'))).keys, [rid.id]);
      expect((await contactsIn(dir('rid'))).keys, [sid.id]);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a receiver without a terminal (EOF) and without --insecure-tofu rejects the first contact, as before', () async {
      await identityOf(dir('rid'));
      await identityOf(dir('sid'));
      final recv = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: ['--auto-accept', '--once'],
      );
      await recv.proc.eof();
      final send = await startSender(
        dir('sid'),
        recv.port,
        [writeFile('x.bin', 10, 7)],
        extra: ['--insecure-tofu'],
      );
      await send.eof();
      expect(await send.exit(), 1, reason: send.everything);
      expect(send.stdoutLines.last, 'FAILED REJECTED');
      expect(await recv.proc.exit(), 1);
      expect(dir('rx').existsSync() ? dir('rx').listSync() : const [], isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ------------------------------------------------------------------ refusals
  group('refusals have their own exit codes', () {
    /// Gives sender and receiver a pin of each other through the CLI (no network).
    Future<({String rid, String rfp, String sid, String sfp})> befriend(
      Directory rd,
      Directory sd,
    ) async {
      final r = await identityOf(rd);
      final s = await identityOf(sd);
      expect(
        (await cli([
          'contacts',
          'add',
          '--id',
          s.id,
          '--fp',
          s.fp,
          '--alias',
          'cli-tx',
          '--identity-dir',
          rd.path,
        ])).code,
        0,
      );
      expect(
        (await cli([
          'contacts',
          'add',
          '--id',
          r.id,
          '--fp',
          r.fp,
          '--alias',
          'cli-rx',
          '--identity-dir',
          sd.path,
        ])).code,
        0,
      );
      return (rid: r.id, rfp: r.fp, sid: s.id, sfp: s.fp);
    }

    test('receiver key changed (identity rotate): the pinned sender exits 80 and no byte reaches the new key', () async {
      final rd = dir('rid');
      final sd = dir('sid');
      final ids = await befriend(rd, sd);
      // Twin: before the rotation the very same send works without a SAS.
      final ok = await startReceiver(
        rd,
        dir('rx'),
        extra: ['--auto-accept', '--once'],
      );
      final first = await runLs([
        'send',
        '--to',
        '$loopback:${ok.port}',
        '--identity-dir',
        sd.path,
        writeFile('a.bin', 100, 8).path,
      ]);
      expect(first.exited, 0, reason: first.everything);
      await ok.proc.exit();

      expect(
        (await cli(['identity', 'rotate', '--identity-dir', rd.path])).code,
        0,
      );
      expect((await identityOf(rd)).fp, isNot(ids.rfp));
      final rx2 = dir('rx2');
      final recv = await startReceiver(rd, rx2, extra: ['--auto-accept']);
      final send = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        sd.path,
        writeFile('b.bin', 100, 9).path,
      ]);
      expect(send.exited, exitKeyChanged, reason: send.everything);
      expect(send.stderr, isNot(contains('Unhandled')));
      expect(send.stdout, isNot(contains('COMPLETED')));
      expect(
        recv.proc.stdoutLines.where((l) => l.startsWith('SESSION ')),
        isEmpty,
        reason: 'zero requests reached the new key',
      );
      expect(rx2.existsSync() ? rx2.listSync() : const [], isEmpty);

      // Explicit removal of the contact, then a SAS-confirmed first contact works again.
      expect(
        (await cli(['contacts', 'remove', ids.rid, '--identity-dir', sd.path]))
            .code,
        0,
      );
      final send2 = await startSender(
        sd,
        recv.port,
        [writeFile('c.bin', 100, 10)],
        extra: ['--insecure-tofu'],
      );
      await send2.eof();
      await recv.proc.waitForLine(sasRe);
      recv.proc.answer('y');
      expect(await send2.exit(), 0, reason: send2.everything);
      expect(
        (await contactsIn(sd))[ids.rid]!.group(3),
        (await identityOf(rd)).fp.substring(0, 16),
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('sender key changed (identity rotate): the receiver that pinned the old key refuses; exit 80, nothing accepted', () async {
      final rd = dir('rid');
      final sd = dir('sid');
      await befriend(rd, sd);
      expect(
        (await cli(['identity', 'rotate', '--identity-dir', sd.path])).code,
        0,
      );
      // The sender's pin of the receiver survives the rotation (the pin store is separate from the key).
      final rx = dir('rx');
      final recv = await startReceiver(rd, rx, extra: ['--auto-accept']);
      final send = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        sd.path,
        writeFile('a.bin', 100, 11).path,
      ]);
      expect(send.exited, exitKeyChanged, reason: send.everything);
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);
      expect(
        recv.proc.stdoutLines.where((l) => l.startsWith('RECEIVED ')),
        isEmpty,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a plaintext (legacy) receiver: exit 81 and no session; with --allow-insecure the send works', () async {
      await identityOf(dir('sid'));
      final rx = dir('rx');
      final legacy = await start([
        'receive',
        '--port',
        '0',
        '--dir',
        rx.path,
        '--insecure-plaintext',
        '--auto-accept',
      ]);
      final port = int.parse(
        (await legacy.waitForLine(RegExp(r'^LISTENING .* port=(\d+) ')))
            .group(1)!,
      );

      final refused = await runLs([
        'send',
        '--to',
        '$loopback:$port',
        '--identity-dir',
        dir('sid').path,
        writeFile('a.bin', 100, 12).path,
      ]);
      expect(refused.exited, exitInsecurePeer, reason: refused.everything);
      expect(refused.stderr, isNot(contains('Unhandled')));
      expect(
        legacy.stdoutLines.where((l) => l.startsWith('SESSION ')),
        isEmpty,
        reason: 'zero bytes sent',
      );
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);

      final f = writeFile('b.bin', 3000, 13);
      final allowed = await runLs([
        'send',
        '--to',
        '$loopback:$port',
        '--identity-dir',
        dir('sid').path,
        '--allow-insecure',
        f.path,
      ]);
      expect(allowed.exited, 0, reason: allowed.everything);
      expect(sameBytes(f, File('${rx.path}${sep}b.bin')), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a plaintext sender against a secure receiver fails and the receiver sees nothing', () async {
      await identityOf(dir('rid'));
      final rx = dir('rx');
      final recv = await startReceiver(
        dir('rid'),
        rx,
        extra: ['--auto-accept'],
      );
      final send = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--insecure-plaintext',
        writeFile('a.bin', 100, 14).path,
      ]);
      expect(send.exited, isNot(0));
      expect(send.stdout, isNot(contains('COMPLETED')));
      expect(
        recv.proc.stdoutLines.where((l) => l.startsWith('SESSION ')),
        isEmpty,
      );
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('PIN: missing and wrong are exit 82; the right one completes; the PIN is printed nowhere', () async {
      await identityOf(dir('rid'));
      await identityOf(dir('sid'));
      final rx = dir('rx');
      final recv = await startReceiver(
        dir('rid'),
        rx,
        extra: ['--pin', '424242', '--auto-accept', '--insecure-tofu', '-v'],
      );
      await recv.proc.eof();
      List<String> send(
        String name,
        int seed, [
        List<String> extra = const [],
      ]) => [
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        dir('sid').path,
        '--insecure-tofu',
        ...extra,
        writeFile(name, 100, seed).path,
      ];

      final none = await runLs(send('n.bin', 15));
      expect(none.exited, exitAuthRefused, reason: none.everything);
      final wrong = await runLs(send('w.bin', 16, ['--pin', '000000']));
      expect(wrong.exited, exitAuthRefused, reason: wrong.everything);
      expect(rx.existsSync() ? rx.listSync() : const [], isEmpty);

      final f = writeFile('ok.bin', 2222, 17);
      final ok = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        dir('sid').path,
        '--insecure-tofu',
        '--pin',
        '424242',
        '-v',
        f.path,
      ]);
      expect(ok.exited, 0, reason: ok.everything);
      expect(sameBytes(f, File('${rx.path}${sep}ok.bin')), isTrue);
      for (final p in [none, wrong, ok]) {
        expect(p.everything, isNot(contains('424242')));
      }
      expect(
        recv.proc.everything,
        isNot(contains('424242')),
        reason: 'a fixed PIN is never echoed or logged',
      );
      expect(
        wrong.everything,
        isNot(contains('000000')),
        reason: 'nor a wrong PIN',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test(
      'five wrong PINs block the source: the correct PIN is exit 82 too',
      () async {
        await identityOf(dir('rid'));
        await identityOf(dir('sid'));
        final recv = await startReceiver(
          dir('rid'),
          dir('rx'),
          extra: ['--pin', '424242', '--auto-accept', '--insecure-tofu'],
        );
        for (var i = 0; i < 5; i++) {
          final r = await runLs([
            'send',
            '--to',
            '$loopback:${recv.port}',
            '--identity-dir',
            dir('sid').path,
            '--insecure-tofu',
            '--pin',
            '10000$i',
            writeFile('w$i.bin', 10, 20 + i).path,
          ]);
          expect(
            r.exited,
            exitAuthRefused,
            reason: 'attempt $i: ${r.everything}',
          );
        }
        final sixth = await runLs([
          'send',
          '--to',
          '$loopback:${recv.port}',
          '--identity-dir',
          dir('sid').path,
          '--insecure-tofu',
          '--pin',
          '424242',
          writeFile('right.bin', 10, 30).path,
        ]);
        expect(
          sixth.exited,
          exitAuthRefused,
          reason: 'blocked even for the right PIN',
        );
        expect(
          dir('rx').existsSync() ? dir('rx').listSync() : const [],
          isEmpty,
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '--pin auto prints the generated PIN once and that PIN works',
      () async {
        await identityOf(dir('rid'));
        await identityOf(dir('sid'));
        final recv = await startReceiver(
          dir('rid'),
          dir('rx'),
          extra: [
            '--pin',
            'auto',
            '--auto-accept',
            '--insecure-tofu',
            '--once',
          ],
        );
        final pin = (await recv.proc.waitForLine(RegExp(r'^PIN (\d{6})$')))
            .group(1)!;
        await recv.proc.eof();
        final f = writeFile('auto.bin', 321, 40);
        final send = await runLs([
          'send',
          '--to',
          '$loopback:${recv.port}',
          '--identity-dir',
          dir('sid').path,
          '--insecure-tofu',
          '--pin',
          pin,
          f.path,
        ]);
        expect(send.exited, 0, reason: send.everything);
        expect(await recv.proc.exit(), 0);
        expect(
          recv.proc.stdoutLines.where((l) => l.contains(pin)),
          hasLength(1),
          reason: 'the PIN appears on the PIN line only',
        );
        expect(recv.proc.stderr, isNot(contains(pin)));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('a blocked fingerprint is exit 82; unblocking lets the same sender through', () async {
      await identityOf(dir('rid'));
      final s = await identityOf(dir('sid'));
      expect(
        (await cli([
          'contacts',
          'block',
          s.fp,
          '--identity-dir',
          dir('rid').path,
        ])).code,
        0,
      );
      final recv = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: ['--auto-accept', '--insecure-tofu'],
      );
      final blocked = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        dir('sid').path,
        '--insecure-tofu',
        writeFile('b.bin', 10, 41).path,
      ]);
      expect(blocked.exited, exitAuthRefused, reason: blocked.everything);
      expect(
        recv.proc.stdoutLines.where((l) => l.startsWith('SESSION ')),
        isEmpty,
      );
      recv.proc.kill();

      expect(
        (await cli([
          'contacts',
          'unblock',
          s.fp,
          '--identity-dir',
          dir('rid').path,
        ])).code,
        0,
      );
      final recv2 = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: ['--auto-accept', '--insecure-tofu', '--once'],
      );
      final send2 = await startSender(
        dir('sid'),
        recv2.port,
        [writeFile('c.bin', 10, 42)],
        extra: ['--insecure-tofu'],
      );
      await send2.eof();
      await recv2.proc.waitForLine(sasRe);
      expect(await send2.exit(), 0, reason: send2.everything);
      await recv2.proc.exit();
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // ------------------------------------------------------------------ pairing
  group('pairing and Contacts-only', () {
    test('pair --show / pair --scan between two processes: URI with s=, the inviter decides, both are trusted contacts, then a Contacts-only receive serves the paired sender and 404s a stranger', () async {
      final ad = dir('aid');
      final bd = dir('bid');
      final a = await identityOf(ad);
      final b = await identityOf(bd);

      final show = await start([
        'pair',
        '--show',
        '--identity-dir',
        ad.path,
        '--alias',
        'cli-a',
        '--advertise-ip',
        loopback,
        '--port',
        '0',
      ]);
      final uriLine = (await show.waitForLine(
        RegExp(r'^PAIR (libreshare://pair\?\S+)$'),
      )).group(1)!;
      final uri = Uri.parse(uriLine);
      expect(uri.queryParameters['v'], '1');
      expect(uri.queryParameters['s'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(uri.queryParameters['id'], a.id);
      expect(uri.queryParameters['fp'], a.fp);
      expect(uri.queryParameters['ip'], loopback);
      expect(int.parse(uri.queryParameters['port']!), greaterThan(0));

      final scan = await start([
        'pair',
        '--scan',
        uriLine,
        '--identity-dir',
        bd.path,
        '--alias',
        'cli-b',
      ]);
      final req = await show.waitForLine(
        RegExp(r'^PAIR-REQUEST (.+) fp=([0-9A-F]{16})$'),
      );
      expect(req.group(1), 'cli-b');
      expect(req.group(2), b.fp.substring(0, 16));
      show.answer('y');

      final pa = await show.waitForLine(
        RegExp(r'^PAIRED (.+) fp=([0-9A-F]{16})$'),
      );
      final pb = await scan.waitForLine(
        RegExp(r'^PAIRED (.+) fp=([0-9A-F]{16})$'),
      );
      expect(pa.group(1), 'cli-b');
      expect(pa.group(2), b.fp.substring(0, 16));
      expect(pb.group(1), 'cli-a');
      expect(pb.group(2), a.fp.substring(0, 16));
      expect(await scan.exit(), 0, reason: scan.everything);
      expect(await show.exit(), 0, reason: show.everything);
      // The secret is user-facing on the PAIR line only.
      expect(scan.stderr, isNot(contains(uri.queryParameters['s']!)));
      expect(show.stderr, isNot(contains(uri.queryParameters['s']!)));

      final ca = await contactsIn(ad);
      final cb = await contactsIn(bd);
      expect(ca[b.id]!.group(2), 'trusted');
      expect(cb[a.id]!.group(2), 'trusted');

      // Contacts-only receive: the paired contact is served without any SAS, a stranger is not.
      final rx = dir('rx');
      final recv = await startReceiver(
        ad,
        rx,
        extra: [
          '--visibility',
          'contacts',
          '--auto-accept',
          '--advertise-ip',
          loopback,
        ],
      );
      final f = writeFile('paired.bin', 5000, 50);
      final ok = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        bd.path,
        f.path,
      ]);
      expect(ok.exited, 0, reason: ok.everything);
      expect(ok.stdout, isNot(contains('SAS')));
      expect(sameBytes(f, File('${rx.path}${sep}paired.bin')), isTrue);

      await identityOf(dir('cid'));
      final stranger = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        dir('cid').path,
        '--insecure-tofu',
        writeFile('s.bin', 100, 51).path,
      ]);
      expect(
        stranger.exited,
        isNot(0),
        reason: 'a stranger gets the 404 of an unknown route',
      );
      expect(stranger.stdout, isNot(contains('COMPLETED')));
      expect(
        recv.proc.stdoutLines.where((l) => l.startsWith('SESSION ')),
        hasLength(1),
        reason: 'only the paired contact created a session',
      );
      expect(File('${rx.path}${sep}s.bin').existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('the inviter declines: the scanner exits non-zero and nobody is a contact', () async {
      final ad = dir('aid');
      final bd = dir('bid');
      await identityOf(ad);
      await identityOf(bd);
      final show = await start([
        'pair',
        '--show',
        '--identity-dir',
        ad.path,
        '--advertise-ip',
        loopback,
        '--port',
        '0',
      ]);
      final uriLine = (await show.waitForLine(
        RegExp(r'^PAIR (libreshare://pair\?\S+)$'),
      )).group(1)!;
      final scan = await start([
        'pair',
        '--scan',
        uriLine,
        '--identity-dir',
        bd.path,
      ]);
      await show.waitForLine(RegExp(r'^PAIR-REQUEST '));
      show.answer('n');
      expect(await scan.exit(), isNot(0), reason: scan.everything);
      expect(scan.stdout, isNot(contains('PAIRED')));
      expect(await contactsIn(ad), isEmpty);
      expect(await contactsIn(bd), isEmpty);
      show.kill();
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a wrong secret is exit 82 and the inviter is not even asked; usage errors are 64', () async {
      final ad = dir('aid');
      await identityOf(ad);
      await identityOf(dir('bid'));
      final show = await start([
        'pair',
        '--show',
        '--identity-dir',
        ad.path,
        '--advertise-ip',
        loopback,
        '--port',
        '0',
      ]);
      final uriLine = (await show.waitForLine(
        RegExp(r'^PAIR (libreshare://pair\?\S+)$'),
      )).group(1)!;
      final u = Uri.parse(uriLine);
      final bad = u
          .replace(
            queryParameters: {
              ...u.queryParameters,
              's': u.queryParameters['s']!.split('').reversed.join(),
            },
          )
          .toString();
      final scan = await runLs([
        'pair',
        '--scan',
        bad,
        '--identity-dir',
        dir('bid').path,
      ]);
      expect(scan.exited, exitAuthRefused, reason: scan.everything);
      expect(
        show.stdoutLines.where((l) => l.startsWith('PAIR-REQUEST')),
        isEmpty,
      );
      show.kill();

      expect((await cli(['pair'])).code, 64);
      expect((await cli(['pair', '--show', '--scan', uriLine])).code, 64);
      expect((await cli(['pair', '--scan', 'https://example.org/'])).code, 64);
      expect(
        (await cli(['pair', '--scan', 'libreshare://peer?ip=127.0.0.1&port=1']))
            .code,
        64,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ------------------------------------------------------------------ profile switch and options
  group('profiles and options', () {
    test('--insecure-plaintext is the Inc 1/2 behaviour byte for byte: v=1.0, no SAS, three files, no identity written', () async {
      final files = [
        writeFile('empty.bin', 0, 1),
        writeFile('notes.txt', 1234, 2),
        writeFile('multi-chunk.bin', 4 * 1024 * 1024 + 500000, 3),
      ];
      final total = files.fold<int>(0, (s, f) => s + f.lengthSync());
      final rx = dir('rx');
      final idDir = dir('unused-id');
      final recv = await start([
        'receive',
        '--port',
        '0',
        '--dir',
        rx.path,
        '--auto-accept',
        '--once',
        '--alias',
        'cli-rx',
        '--insecure-plaintext',
        '--identity-dir',
        idDir.path,
      ]);
      final port = int.parse(
        (await recv.waitForLine(RegExp(r'^LISTENING .* port=(\d+) ')))
            .group(1)!,
      );

      final info = await runLs([
        'info',
        '--to',
        '$loopback:$port',
        '--insecure-plaintext',
      ]);
      expect(info.exited, 0, reason: info.everything);
      expect(
        info.stdoutLines.single,
        matches(RegExp(r'^cli-rx \(\w+\) id=[0-9a-f-]{36} port=\d+ v=1\.0$')),
      );

      final send = await runLs([
        'send',
        '--to',
        '$loopback:$port',
        '--insecure-plaintext',
        files[2].path,
        files[0].path,
        files[1].path,
      ]);
      expect(send.exited, 0, reason: send.everything);
      expect(send.stdout, contains('status=COMPLETED'));
      expect(send.stdout, contains('SENT 3 file(s) $total bytes'));
      expect(send.stdoutLines.last, 'COMPLETED');
      expect(send.stdout, isNot(contains('SAS')));
      expect(send.stderr, isEmpty);
      expect(await recv.exit(), 0, reason: recv.everything);
      expect(recv.stdout, isNot(contains('SAS')));
      expect(recv.stdoutLines.last, 'COMPLETED');
      for (final f in files) {
        expect(
          sameBytes(f, File('${rx.path}$sep${f.path.split(sep).last}')),
          isTrue,
        );
      }
      expect(leftovers(rx), isEmpty);
      expect(
        idDir.existsSync() ? idDir.listSync() : const [],
        isEmpty,
        reason: 'the plaintext profile has no identity',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('the CLI defaults to TLS: no flag = secure (v=1.1 in info, a plain HTTP request gets nothing), --secure is the same, both flags together are a usage error', () async {
      await identityOf(dir('rid'));
      final recv = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: ['--auto-accept'],
      );
      final info = await runLs([
        'info',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        dir('sid').path,
      ]);
      expect(info.exited, 0, reason: info.everything);
      expect(info.stdoutLines.first, contains('v=1.1'));
      expect(
        info.stdoutLines.first,
        contains('id=${(await identityOf(dir('rid'))).id}'),
      );
      expect(
        info.stdoutLines.first,
        isNot(contains(RegExp(r'[0-9A-F]{64}'))),
        reason: 'fingerprints are shortened',
      );

      final explicit = await runLs([
        'info',
        '--to',
        '$loopback:${recv.port}',
        '--secure',
        '--identity-dir',
        dir('sid').path,
      ]);
      expect(explicit.exited, 0, reason: explicit.everything);
      expect(explicit.stdoutLines.first, contains('v=1.1'));

      // A plaintext client gets no HTTP answer from a default receiver (TLS only).
      final s = await Socket.connect(loopback, recv.port);
      s.write(
        'GET /api/v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      final got = StringBuffer();
      try {
        await s
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach(got.write)
            .timeout(const Duration(seconds: 5));
      } on Object {
        // reset
      }
      s.destroy();
      expect(got.toString(), isNot(contains('HTTP/')));

      expect(
        (await cli([
          'info',
          '--to',
          '$loopback:1',
          '--secure',
          '--insecure-plaintext',
        ])).code,
        64,
      );
      expect(
        (await cli(['receive', '--secure', '--insecure-plaintext'])).code,
        64,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('--advertise-ip is what the printed link, info and the pair URI tell others; without it the real address is told', () async {
      await identityOf(dir('rid'));
      final recv = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: ['--advertise-ip', '203.0.113.7'],
      );
      final link = await recv.proc.waitForLine(
        RegExp(r'^PEER-LINK (libreshare://peer\?\S+)$'),
      );
      expect(link.group(1), contains('ip=203.0.113.7'));
      expect(link.group(1), contains('port=${recv.port}'));
      expect(
        link.group(1),
        contains('id=${(await identityOf(dir('rid'))).id}'),
      );
      expect(
        link.group(1),
        contains('fp='),
        reason: 'the secure peer link pins the fingerprint',
      );
      recv.proc.kill();

      final info = await runLs([
        'info',
        '--identity-dir',
        dir('rid').path,
        '--advertise-ip',
        '203.0.113.7',
      ]);
      expect(info.exited, 0, reason: info.everything);
      expect(info.stdoutLines.where((l) => l.startsWith('ADDR ')), [
        'ADDR 203.0.113.7 unknown',
      ]);

      final plain = await start([
        'receive',
        '--port',
        '0',
        '--dir',
        dir('rx2').path,
        '--insecure-plaintext',
        '--advertise-ip',
        '203.0.113.8',
      ]);
      final plink = await plain.waitForLine(
        RegExp(r'^PEER-LINK (libreshare://peer\?\S+)$'),
      );
      expect(plink.group(1), contains('ip=203.0.113.8'));

      expect((await cli(['info', '--advertise-ip', 'not-an-ip'])).code, 64);
      expect(
        (await cli([
          'receive',
          '--advertise-ip',
          '999.1.1.1',
          '--identity-dir',
          dir('rid').path,
        ])).code,
        64,
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('-v on both sides: no PIN, no full fingerprint, no long token-like string on stderr through a PIN-protected SAS transfer', () async {
      await identityOf(dir('rid'));
      await identityOf(dir('sid'));
      final recv = await startReceiver(
        dir('rid'),
        dir('rx'),
        extra: [
          '--pin',
          '424242',
          '--auto-accept',
          '--insecure-tofu',
          '--once',
          '-v',
        ],
      );
      await recv.proc.eof();
      final send = await runLs([
        'send',
        '--to',
        '$loopback:${recv.port}',
        '--identity-dir',
        dir('sid').path,
        '--insecure-tofu',
        '--pin',
        '424242',
        '-v',
        writeFile('v.bin', 3000, 60).path,
      ]);
      expect(send.exited, 0, reason: send.everything);
      expect(await recv.proc.exit(), 0);
      for (final p in [send, recv.proc]) {
        expect(p.stderr, isNotEmpty, reason: 'twin: -v really logs');
        expect(p.stderr, isNot(contains('424242')));
        expect(p.stderr, isNot(matches(RegExp(r'[0-9A-Fa-f]{64}'))));
        expect(p.stderr, isNot(matches(RegExp(r'[A-Za-z0-9_-]{40,}'))));
        expect(p.stderr, isNot(contains('PRIVATE KEY')));
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('--help lists the new commands and options', () async {
      final r = await cli(['--help']);
      final text = r.out.join('\n');
      for (final word in [
        'identity',
        'contacts',
        'pair',
        '--insecure-plaintext',
      ]) {
        expect(text, contains(word));
      }
    });
  });

  // ------------------------------------------------------------------ Broken pipe
  // docs/plans/inc3.md section 9b item 3.
  group('stdout closed early', () {
    Future<({String out, int? rc})> piped(
      List<String> args,
      String sink,
    ) async {
      final r = await Process.run('bash', [
        '-c',
        'exec 3>&1; "\$0" "\$@" 2>&3 | $sink; echo "rc=\${PIPESTATUS[0]}" >&3',
        Platform.resolvedExecutable,
        dill,
        ...args,
      ]);
      final text = '${r.stdout}${r.stderr}';
      final rc = RegExp(r'rc=(\d+)').firstMatch(text)?.group(1);
      return (out: text, rc: rc == null ? null : int.parse(rc));
    }

    test('info | true and devices | true end without a stack trace; the control with a reader still prints', () async {
      final control = await piped([
        'info',
        '--insecure-plaintext',
        '--advertise-ip',
        '192.0.2.1',
      ], 'cat');
      expect(
        control.out,
        contains('ADDR 192.0.2.1'),
        reason: 'twin: the output exists',
      );
      expect(control.out, isNot(contains('Unhandled')));

      for (final args in [
        ['info', '--insecure-plaintext', '--advertise-ip', '192.0.2.1'],
        [
          'info',
          '--identity-dir',
          dir('pipe-id').path,
          '--advertise-ip',
          '192.0.2.1',
        ],
        ['devices', '--timeout', '0.2', '--insecure-plaintext'],
        ['devices', '--timeout', '0.2', '--identity-dir', dir('pipe-id').path],
      ]) {
        final r = await piped(args, 'true');
        expect(
          r.out,
          isNot(contains('Unhandled exception')),
          reason: '${args.join(' ')}: ${r.out}',
        );
        expect(r.out, isNot(contains('Broken pipe')), reason: args.join(' '));
        expect(
          r.out,
          isNot(contains('FileSystemException')),
          reason: args.join(' '),
        );
        expect(r.rc, isNot(255), reason: 'exit code of an unhandled exception');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  test('the closed-port send in the secure profile still fails fast with NO_CONNECTION (exit 1)', () async {
    await identityOf(dir('sid'));
    final port = await closedPort();
    final r = await runLs([
      'send',
      '--to',
      '$loopback:$port',
      '--identity-dir',
      dir('sid').path,
      writeFile('x.bin', 10, 70).path,
    ]);
    expect(r.exited, 1, reason: r.everything);
    expect(r.stdoutLines.last, 'FAILED NO_CONNECTION');
    expect(r.stderr, isNot(contains('Unhandled')));
  });
}
