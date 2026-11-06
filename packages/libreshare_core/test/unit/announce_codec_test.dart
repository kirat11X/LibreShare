import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/discovery/announce_codec.dart';
import 'package:libreshare_core/src/model/device.dart';
import 'package:test/test.dart';

const _fp = 'FC074C4445C65D5C5208058734A816CFC5E77A51D5D9B596AD324828CEFA422E';

DeviceInfo _self({
  String alias = 'Ravi-ThinkPad',
  String fingerprint = _fp,
  int port = 53318,
  List<DeviceAddress> addrs = const [
    DeviceAddress('192.168.1.23', iface: 'wifi'),
    DeviceAddress('10.0.0.5', iface: 'ethernet'),
  ],
}) => DeviceInfo(
  deviceId: '5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f',
  alias: alias,
  platform: 'windows',
  fingerprint: fingerprint,
  port: port,
  addrs: addrs,
  caps: const ['resume', 'tunnel', 'sas'],
);

Map<String, Object?> _valid() => {
  'proto': 'libreshare',
  'v': '1.0',
  'deviceId': 'abc',
  'alias': 'Alice',
  'platform': 'linux',
  'deviceType': 'desktop',
  'fingerprint': '',
  'port': 53318,
  'addrs': <Object?>[],
  'caps': ['resume'],
  'announce': true,
};

Uint8List _bytes(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

AnnounceMessage? _decodeWith(void Function(Map<String, Object?> m) mutate) {
  final m = _valid();
  mutate(m);
  return decodeAnnounce(_bytes(m));
}

void main() {
  group('encode', () {
    test('golden JSON follows spec section 4.2 key order exactly', () {
      final bytes = encodeAnnounce(_self(), announce: true);
      expect(
        utf8.decode(bytes),
        '{"proto":"libreshare","v":"1.0",'
        '"deviceId":"5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f",'
        '"alias":"Ravi-ThinkPad","platform":"windows","deviceType":"desktop",'
        '"fingerprint":"$_fp","port":53318,'
        '"addrs":[{"ip":"192.168.1.23","if":"wifi"},'
        '{"ip":"10.0.0.5","if":"ethernet"}],'
        '"caps":["resume","tunnel","sas"],"announce":true}',
      );
      expect(bytes.length, lessThanOrEqualTo(kMaxAnnounceBytes));
    });

    test('announce:false is encoded and round-trips', () {
      final msg = decodeAnnounce(encodeAnnounce(_self(), announce: false))!;
      expect(msg.announce, isFalse);
    });

    test('round-trips every DeviceInfo field', () {
      final msg = decodeAnnounce(encodeAnnounce(_self(), announce: true))!;
      expect(msg.announce, isTrue);
      final i = msg.info;
      expect(i.deviceId, '5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f');
      expect(i.alias, 'Ravi-ThinkPad');
      expect(i.platform, 'windows');
      expect(i.deviceType, 'desktop');
      expect(i.fingerprint, _fp);
      expect(i.port, 53318);
      expect(i.version, '1.0');
      expect(i.caps, ['resume', 'tunnel', 'sas']);
      expect(i.addrs.map((a) => (a.ip, a.iface)), [
        ('192.168.1.23', 'wifi'),
        ('10.0.0.5', 'ethernet'),
      ]);
    });

    test('addrs argument overrides self.addrs; empty fingerprint is legal', () {
      final bytes = encodeAnnounce(
        _self(fingerprint: ''),
        announce: true,
        addrs: const [DeviceAddress('172.16.0.9')],
      );
      final i = decodeAnnounce(bytes)!.info;
      expect(i.fingerprint, '');
      expect(i.addrs.single.ip, '172.16.0.9');
      expect(i.addrs.single.iface, 'unknown');
    });

    test('lowercase fingerprint is emitted uppercase', () {
      final bytes = encodeAnnounce(
        _self(fingerprint: _fp.toLowerCase()),
        announce: true,
      );
      expect(utf8.decode(bytes), contains('"fingerprint":"$_fp"'));
    });

    test('unicode alias survives the round trip', () {
      final bytes = encodeAnnounce(
        _self(alias: 'रवि का लैपटॉप 💻'),
        announce: true,
      );
      expect(decodeAnnounce(bytes)!.info.alias, 'रवि का लैपटॉप 💻');
    });

    test('too many addresses are trimmed to 8 and never truncate JSON', () {
      final many = [
        for (var i = 0; i < 30; i++) DeviceAddress('10.1.$i.1', iface: 'wifi'),
      ];
      final bytes = encodeAnnounce(_self(), announce: true, addrs: many);
      final msg = decodeAnnounce(bytes)!;
      expect(msg.info.addrs.length, kMaxAnnounceAddrs);
      expect(msg.info.addrs.first.ip, '10.1.0.1');
      expect(msg.info.addrs.last.ip, '10.1.7.1');
    });

    test('addrs that overflow 1200 B are dropped from the tail', () {
      // 8 long IPv6 literals + a long (multi-byte) alias + many caps.
      final v6 = [
        for (var i = 0; i < 8; i++)
          DeviceAddress(
            '2001:0db8:85a3:0000:0000:8a2e:0370:73${i}4',
            iface: 'ethernet',
          ),
      ];
      final self = DeviceInfo(
        deviceId: 'd' * 128,
        alias: '日' * 64, // 192 B in UTF-8
        platform: 'p' * 32,
        deviceType: 't' * 32,
        fingerprint: _fp,
        port: 65535,
        caps: [for (var i = 0; i < 16; i++) 'capability-token-number-$i'],
      );
      final all = [
        for (var n = 0; n <= 8; n++)
          encodeAnnounce(self, announce: true, addrs: v6.take(n).toList()),
      ];
      // Sanity: the full list really would not fit.
      final withAll = utf8.encode(
        jsonEncode({
          ...jsonDecode(utf8.decode(all.first)) as Map<String, Object?>,
          'addrs': v6.map((a) => a.toJson()).toList(),
        }),
      );
      expect(withAll.length, greaterThan(kMaxAnnounceBytes));

      final bytes = encodeAnnounce(self, announce: true, addrs: v6);
      expect(bytes.length, lessThanOrEqualTo(kMaxAnnounceBytes));
      final msg = decodeAnnounce(bytes)!;
      expect(msg.info.addrs.length, lessThan(8));
      // Kept addresses are a prefix of the input, in order.
      for (var i = 0; i < msg.info.addrs.length; i++) {
        expect(msg.info.addrs[i].ip, v6[i].ip);
      }
      // And the result is the maximal prefix that fits.
      final fitting = msg.info.addrs.length;
      final oneMore = encodeAnnounce(
        self,
        announce: true,
        addrs: v6.take(fitting + 1).toList(),
      );
      expect(
        utf8.decode(oneMore),
        isNot(contains(v6[fitting].ip)),
        reason: 'would not have fit',
      );
    });

    test('overlong alias is cut to 64 code points, control chars removed', () {
      final bytes = encodeAnnounce(
        _self(alias: 'a\u0000b\n${'x' * 200}'),
        announce: true,
      );
      final alias = decodeAnnounce(bytes)!.info.alias;
      expect(alias.runes.length, 64);
      expect(alias, startsWith('abxxx'));
    });

    test('blank alias falls back to a default instead of being dropped', () {
      final bytes = encodeAnnounce(_self(alias: ' \n '), announce: true);
      expect(decodeAnnounce(bytes)!.info.alias, 'LibreShare');
    });

    test('throws ArgumentError for a self that peers would drop', () {
      expect(
        () => encodeAnnounce(_self(port: 0), announce: true),
        throwsArgumentError,
      );
      expect(
        () => encodeAnnounce(_self(port: 70000), announce: true),
        throwsArgumentError,
      );
      expect(
        () => encodeAnnounce(
          const DeviceInfo(deviceId: '', alias: 'x', platform: 'linux'),
          announce: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => encodeAnnounce(_self(fingerprint: 'abc'), announce: true),
        throwsArgumentError,
      );
    });
  });

  group('decode accepts', () {
    test('the spec example', () {
      final msg = decodeAnnounce(
        utf8.encode(
          '{"proto":"libreshare","v":"1.0","deviceId":"uuid-v4",'
          '"alias":"Ravi-ThinkPad","platform":"windows","deviceType":"desktop",'
          '"fingerprint":"$_fp","port":53318,'
          '"addrs":[{"ip":"192.168.1.23","if":"wifi"},'
          '{"ip":"10.0.0.5","if":"ethernet"}],'
          '"caps":["resume","tunnel","sas"],"announce":true}',
        ),
      );
      expect(msg, isNotNull);
      expect(msg!.info.alias, 'Ravi-ThinkPad');
    });

    test('exactly 1200 bytes', () {
      final m = _valid();
      final base = _bytes(m).length;
      m['alias'] = 'a' * (kMaxAnnounceAliasLength);
      m['platform'] = 'p' * 32;
      // Pad with an unknown member to hit 1200 B exactly.
      final padLen =
          kMaxAnnounceBytes -
          _bytes(m).length -
          ',"pad":""'.length; // member overhead
      m['pad'] = 'z' * padLen;
      final bytes = _bytes(m);
      expect(bytes.length, kMaxAnnounceBytes);
      expect(base, lessThan(kMaxAnnounceBytes));
      expect(decodeAnnounce(bytes), isNotNull);
    });

    test('minor version differences (1.7) and unknown members are ignored', () {
      final msg = _decodeWith((m) {
        m['v'] = '1.7';
        m['shiny'] = {
          'new': [1, 2, 3],
        };
      });
      expect(msg, isNotNull);
      expect(msg!.info.version, '1.7');
    });

    test('lowercase fingerprint is normalised to uppercase', () {
      final msg = _decodeWith((m) => m['fingerprint'] = _fp.toLowerCase());
      expect(msg!.info.fingerprint, _fp);
    });

    test('empty fingerprint (pre-TLS) is accepted', () {
      expect(_decodeWith((m) => m['fingerprint'] = '')!.info.fingerprint, '');
    });

    test('port boundaries 1 and 65535', () {
      expect(_decodeWith((m) => m['port'] = 1)!.info.port, 1);
      expect(_decodeWith((m) => m['port'] = 65535)!.info.port, 65535);
    });

    test('platform/deviceType/addrs/caps default when absent', () {
      final msg = _decodeWith((m) {
        m
          ..remove('platform')
          ..remove('deviceType')
          ..remove('addrs')
          ..remove('caps');
      })!;
      expect(msg.info.platform, 'unknown');
      expect(msg.info.deviceType, 'desktop');
      expect(msg.info.addrs, isEmpty);
      expect(msg.info.caps, isEmpty);
    });

    test('IPv6 literals and unknown iface classes', () {
      final msg = _decodeWith(
        (m) => m['addrs'] = [
          {'ip': 'fe80::1', 'if': 'bluetooth'},
          {'ip': '2001:db8::7'},
        ],
      )!;
      expect(msg.info.addrs[0].ip, 'fe80::1');
      expect(msg.info.addrs[0].iface, 'unknown');
      expect(msg.info.addrs[1].iface, 'unknown');
    });

    test('exactly 8 addrs', () {
      final msg = _decodeWith(
        (m) => m['addrs'] = [
          for (var i = 1; i <= 8; i++) {'ip': '10.0.0.$i', 'if': 'wifi'},
        ],
      );
      expect(msg!.info.addrs.length, 8);
    });
  });

  group('decode rejects (returns null, never throws)', () {
    test('empty input', () {
      expect(decodeAnnounce(const []), isNull);
    });

    test('1201 bytes, even though otherwise valid', () {
      final m = _valid();
      m['pad'] = 'z' * 2000;
      var bytes = _bytes(m);
      // Trim padding to land on exactly 1201 B.
      final excess = bytes.length - (kMaxAnnounceBytes + 1);
      m['pad'] = 'z' * (2000 - excess);
      bytes = _bytes(m);
      expect(bytes.length, kMaxAnnounceBytes + 1);
      expect(decodeAnnounce(bytes), isNull);
      expect(decodeAnnounce(Uint8List(65000)), isNull);
    });

    test('invalid UTF-8', () {
      final good = _bytes(_valid()).toList();
      final i = good.indexOf('A'.codeUnitAt(0)); // inside "Alice"
      final bad = [...good]..[i] = 0xff;
      expect(decodeAnnounce(bad), isNull);
      expect(decodeAnnounce([0xc3, 0x28]), isNull);
    });

    test('not JSON, not an object', () {
      expect(decodeAnnounce(utf8.encode('hello')), isNull);
      expect(decodeAnnounce(utf8.encode('{"proto":')), isNull);
      expect(decodeAnnounce(utf8.encode('[]')), isNull);
      expect(decodeAnnounce(utf8.encode('"libreshare"')), isNull);
      expect(decodeAnnounce(utf8.encode('null')), isNull);
      expect(decodeAnnounce(utf8.encode('42')), isNull);
    });

    test('deeply nested JSON does not blow the stack', () {
      final nested = '[' * 1190 + ']' * 1190;
      expect(decodeAnnounce(utf8.encode(nested)), isNull);
    });

    test('wrong or missing proto', () {
      expect(_decodeWith((m) => m['proto'] = 'localsend'), isNull);
      expect(_decodeWith((m) => m['proto'] = 'LibreShare'), isNull);
      expect(_decodeWith((m) => m.remove('proto')), isNull);
      expect(_decodeWith((m) => m['proto'] = 1), isNull);
    });

    test('unknown major v, malformed v, missing v', () {
      for (final v in ['2.0', '0.9', '10.1', '', '1', 'x.y', '1.0.0', '1.']) {
        expect(_decodeWith((m) => m['v'] = v), isNull, reason: 'v=$v');
      }
      expect(_decodeWith((m) => m['v'] = 1.0), isNull);
      expect(_decodeWith((m) => m.remove('v')), isNull);
    });

    test('missing / empty / wrong-typed deviceId', () {
      expect(_decodeWith((m) => m.remove('deviceId')), isNull);
      expect(_decodeWith((m) => m['deviceId'] = ''), isNull);
      expect(_decodeWith((m) => m['deviceId'] = 7), isNull);
      expect(_decodeWith((m) => m['deviceId'] = 'x' * 129), isNull);
      expect(_decodeWith((m) => m['deviceId'] = 'a\nb'), isNull);
    });

    test('alias: missing, empty, blank, wrong type, huge', () {
      expect(_decodeWith((m) => m.remove('alias')), isNull);
      expect(_decodeWith((m) => m['alias'] = ''), isNull);
      expect(_decodeWith((m) => m['alias'] = '   '), isNull);
      expect(_decodeWith((m) => m['alias'] = 5), isNull);
      expect(_decodeWith((m) => m['alias'] = null), isNull);
      expect(_decodeWith((m) => m['alias'] = 'a' * 65), isNull);
      expect(_decodeWith((m) => m['alias'] = '日' * 65), isNull);
      expect(_decodeWith((m) => m['alias'] = 'a' * 64), isNotNull);
      expect(_decodeWith((m) => m['alias'] = '日' * 64), isNotNull);
    });

    test('alias with control or spoofing characters', () {
      for (final bad in [
        'a\u0000b',
        'line\nbreak',
        'tab\there',
        'del\u007f',
        'c1\u0085x',
        'sep${String.fromCharCode(0x2028)}x',
        'rlo${String.fromCharCode(0x202e)}evil',
        'iso${String.fromCharCode(0x2066)}x',
        'lone\ud800surrogate',
      ]) {
        expect(
          _decodeWith((m) => m['alias'] = bad),
          isNull,
          reason: jsonEncode(bad),
        );
      }
    });

    test('port: missing, 0, 65536, negative, float, string, bool', () {
      expect(_decodeWith((m) => m.remove('port')), isNull);
      expect(_decodeWith((m) => m['port'] = 0), isNull);
      expect(_decodeWith((m) => m['port'] = 65536), isNull);
      expect(_decodeWith((m) => m['port'] = -1), isNull);
      expect(_decodeWith((m) => m['port'] = 53318.5), isNull);
      expect(_decodeWith((m) => m['port'] = '53318'), isNull);
      expect(_decodeWith((m) => m['port'] = true), isNull);
      expect(_decodeWith((m) => m['port'] = 1 << 62), isNull);
    });

    test('fingerprint: missing, short, long, non-hex, wrong type', () {
      expect(_decodeWith((m) => m.remove('fingerprint')), isNull);
      expect(_decodeWith((m) => m['fingerprint'] = _fp.substring(1)), isNull);
      expect(_decodeWith((m) => m['fingerprint'] = '${_fp}0'), isNull);
      expect(
        _decodeWith((m) => m['fingerprint'] = 'G${_fp.substring(1)}'),
        isNull,
      );
      expect(_decodeWith((m) => m['fingerprint'] = '$_fp\n'), isNull);
      expect(_decodeWith((m) => m['fingerprint'] = 12), isNull);
      expect(_decodeWith((m) => m['fingerprint'] = null), isNull);
    });

    test('announce: missing or not a bool', () {
      expect(_decodeWith((m) => m.remove('announce')), isNull);
      expect(_decodeWith((m) => m['announce'] = 'true'), isNull);
      expect(_decodeWith((m) => m['announce'] = 1), isNull);
    });

    test('addrs: more than 8, non-list, bad entries, bad IPs', () {
      expect(
        _decodeWith(
          (m) => m['addrs'] = [
            for (var i = 1; i <= 9; i++) {'ip': '10.0.0.$i'},
          ],
        ),
        isNull,
      );
      expect(_decodeWith((m) => m['addrs'] = 'nope'), isNull);
      expect(_decodeWith((m) => m['addrs'] = {'ip': '1.2.3.4'}), isNull);
      expect(_decodeWith((m) => m['addrs'] = ['1.2.3.4']), isNull);
      expect(_decodeWith((m) => m['addrs'] = [<String, Object?>{}]), isNull);
      for (final ip in [
        '',
        'example.com',
        '999.1.1.1',
        '1.2.3',
        '1.2.3.4.5',
        '1.2.3.4/24',
        ' 1.2.3.4',
        '1.2.3.4 ',
        'fe80::1%eth0',
        'gggg::1',
        ':::',
        '1.2.3.4\n',
        '1' * 60,
      ]) {
        expect(
          _decodeWith(
            (m) => m['addrs'] = [
              {'ip': ip},
            ],
          ),
          isNull,
          reason: 'ip=$ip',
        );
      }
      expect(
        _decodeWith(
          (m) => m['addrs'] = [
            {'ip': 1234},
          ],
        ),
        isNull,
      );
      // One bad entry poisons the whole datagram.
      expect(
        _decodeWith(
          (m) => m['addrs'] = [
            {'ip': '10.0.0.1'},
            {'ip': 'bogus'},
          ],
        ),
        isNull,
      );
    });

    test('caps: not a list, non-string entries, too many', () {
      expect(_decodeWith((m) => m['caps'] = 'resume'), isNull);
      expect(_decodeWith((m) => m['caps'] = [1]), isNull);
      expect(
        _decodeWith((m) => m['caps'] = [for (var i = 0; i < 17; i++) 'c$i']),
        isNull,
      );
    });

    test('platform / deviceType wrong type or oversize', () {
      expect(_decodeWith((m) => m['platform'] = 5), isNull);
      expect(_decodeWith((m) => m['platform'] = 'p' * 33), isNull);
      expect(_decodeWith((m) => m['deviceType'] = ['x']), isNull);
    });
  });

  group('fuzz', () {
    test('5,000 random byte arrays never throw and are all dropped', () {
      final rnd = Random(0xC0DEC);
      var accepted = 0;
      for (var i = 0; i < 5000; i++) {
        final len = rnd.nextInt(i.isEven ? 64 : 1500);
        final bytes = Uint8List.fromList([
          for (var j = 0; j < len; j++) rnd.nextInt(256),
        ]);
        expect(() => decodeAnnounce(bytes), returnsNormally);
        if (decodeAnnounce(bytes) != null) accepted++;
      }
      expect(accepted, 0);
    });

    test('5,000 byte-mutations of a valid datagram never throw', () {
      final rnd = Random(1234);
      final seed = encodeAnnounce(_self(), announce: true);
      for (var i = 0; i < 5000; i++) {
        final b = Uint8List.fromList(seed);
        final flips = 1 + rnd.nextInt(4);
        for (var k = 0; k < flips; k++) {
          b[rnd.nextInt(b.length)] = rnd.nextInt(256);
        }
        var out = b;
        if (rnd.nextInt(5) == 0) {
          out = Uint8List.fromList(b.sublist(0, rnd.nextInt(b.length)));
        }
        expect(() => decodeAnnounce(out), returnsNormally);
        // Whatever is accepted must respect every invariant.
        final msg = decodeAnnounce(out);
        if (msg != null) {
          expect(msg.info.port, inInclusiveRange(1, 65535));
          expect(msg.info.alias.runes.length, lessThanOrEqualTo(64));
          expect(msg.info.addrs.length, lessThanOrEqualTo(8));
          expect(msg.info.fingerprint, matches(RegExp(r'^([0-9A-F]{64})?$')));
        }
      }
    });

    test('random JSON-shaped objects never throw', () {
      final rnd = Random(99);
      Object? value(int depth) {
        switch (rnd.nextInt(depth > 2 ? 6 : 8)) {
          case 0:
            return null;
          case 1:
            return rnd.nextBool();
          case 2:
            return rnd.nextInt(100000) - 10;
          case 3:
            return rnd.nextDouble() * 1e6;
          case 4:
            return String.fromCharCodes([
              for (var i = 0; i < rnd.nextInt(80); i++) rnd.nextInt(0x3000),
            ]);
          case 5:
            return '${rnd.nextInt(256)}.${rnd.nextInt(256)}.1.1';
          case 6:
            return [for (var i = 0; i < rnd.nextInt(5); i++) value(depth + 1)];
          default:
            return {
              for (var i = 0; i < rnd.nextInt(5); i++)
                'k${rnd.nextInt(5)}': value(depth + 1),
            };
        }
      }

      const keys = [
        'proto',
        'v',
        'deviceId',
        'alias',
        'platform',
        'deviceType',
        'fingerprint',
        'port',
        'addrs',
        'caps',
        'announce',
      ];
      for (var i = 0; i < 3000; i++) {
        final m = _valid();
        for (final k in keys) {
          if (rnd.nextInt(3) == 0) m[k] = value(0);
          if (rnd.nextInt(12) == 0) m.remove(k);
        }
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(m)));
        expect(() => decodeAnnounce(bytes), returnsNormally);
      }
    });
  });
  group('send-only probes (port 0, LSP-1 4.2 rule 8)', () {
    test(
      'golden JSON: announce:true with port 0, everything else unchanged',
      () {
        final bytes = encodeAnnounce(_self(), announce: true, probe: true);
        expect(
          utf8.decode(bytes),
          '{"proto":"libreshare","v":"1.0",'
          '"deviceId":"5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f",'
          '"alias":"Ravi-ThinkPad","platform":"windows","deviceType":"desktop",'
          '"fingerprint":"$_fp","port":0,'
          '"addrs":[{"ip":"192.168.1.23","if":"wifi"},'
          '{"ip":"10.0.0.5","if":"ethernet"}],'
          '"caps":["resume","tunnel","sas"],"announce":true}',
        );
      },
    );

    test('a probe ignores self.port and round-trips as a probe', () {
      for (final port in [0, 53318, 65535]) {
        final bytes = encodeAnnounce(
          _self(port: port),
          announce: true,
          probe: true,
        );
        final msg = decodeAnnounce(bytes, allowProbe: true)!;
        expect(msg.info.port, 0, reason: 'self.port=$port');
        expect(msg.announce, isTrue);
        expect(msg.isProbe, isTrue);
        expect(msg.info.deviceId, _self().deviceId);
        expect(msg.info.addrs.map((a) => a.ip), ['192.168.1.23', '10.0.0.5']);
      }
    });

    test('a normal announcement is not a probe', () {
      final msg = decodeAnnounce(
        encodeAnnounce(_self(), announce: true),
        allowProbe: true,
      )!;
      expect(msg.isProbe, isFalse);
      expect(msg.info.port, 53318);
    });

    test(
      'port 0 is rejected unless the receiver opts in (default unchanged)',
      () {
        final bytes = encodeAnnounce(_self(), announce: true, probe: true);
        expect(decodeAnnounce(bytes), isNull);
        expect(decodeAnnounce(bytes, allowProbe: false), isNull);
        expect(decodeAnnounce(bytes, allowProbe: true), isNotNull);
      },
    );

    test(
      'port 0 with announce:false is never valid (a reply must be receivable)',
      () {
        final m = _valid()
          ..['port'] = 0
          ..['announce'] = false;
        expect(decodeAnnounce(_bytes(m), allowProbe: true), isNull);
        expect(
          () => encodeAnnounce(_self(), announce: false, probe: true),
          throwsArgumentError,
        );
      },
    );

    test('allowProbe widens port 0 only: other bad ports still drop', () {
      for (final port in <Object?>[
        -1,
        65536,
        1 << 62,
        0.0,
        0.5,
        '0',
        null,
        false,
      ]) {
        final m = _valid()..['port'] = port;
        expect(
          decodeAnnounce(_bytes(m), allowProbe: true),
          isNull,
          reason: '$port',
        );
      }
      final m = _valid()..['port'] = 0;
      expect(decodeAnnounce(_bytes(m), allowProbe: true)!.info.port, 0);
    });

    test('a probe obeys every other drop rule', () {
      void mutateAndDrop(void Function(Map<String, Object?>) f, String why) {
        final m = _valid()..['port'] = 0;
        f(m);
        expect(
          decodeAnnounce(_bytes(m), allowProbe: true),
          isNull,
          reason: why,
        );
      }

      mutateAndDrop((m) => m['proto'] = 'other', 'proto');
      mutateAndDrop((m) => m['v'] = '2.0', 'major');
      mutateAndDrop((m) => m['deviceId'] = '', 'deviceId');
      mutateAndDrop((m) => m['alias'] = ' ', 'alias');
      mutateAndDrop((m) => m['announce'] = 1, 'announce type');
      mutateAndDrop(
        (m) => m['addrs'] = [
          {'ip': 'nope'},
        ],
        'addr',
      );
      expect(
        decodeAnnounce(Uint8List(1201), allowProbe: true),
        isNull,
        reason: 'oversize',
      );
    });

    test('a probe with a hostile alias is sanitised on the way out', () {
      final bytes = encodeAnnounce(
        _self(alias: 'Ev\u202eil\n'),
        announce: true,
        probe: true,
      );
      expect(decodeAnnounce(bytes, allowProbe: true)!.info.alias, 'Evil');
    });
  });
}
