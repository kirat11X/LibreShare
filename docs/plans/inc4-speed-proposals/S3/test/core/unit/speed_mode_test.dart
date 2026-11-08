// Speed modes (docs/plans/inc4-speed.md section 3): the contract file
// transfer/speed_mode.dart. CHARACTERIZATION: every expectation here is
// already true of the contract as it stands, so these tests are GREEN today.
// They pin the names, aliases and numbers that the CLI, the app and the
// engine rely on; a change to any of them must be a deliberate one.
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  group('CHARACTERIZATION: kDefaultSpeedMode', () {
    test('the default mode is balanced', () {
      expect(kDefaultSpeedMode, SpeedMode.balanced);
    });

    test('there are exactly three modes, in this order', () {
      expect(SpeedMode.values, [
        SpeedMode.eco,
        SpeedMode.balanced,
        SpeedMode.turbo,
      ]);
    });
  });

  group('CHARACTERIZATION: speedProfileFor', () {
    test('eco: one chunk in flight', () {
      expect(speedProfileFor(SpeedMode.eco).chunkConcurrency, 1);
    });

    test('balanced: three chunks in flight', () {
      expect(speedProfileFor(SpeedMode.balanced).chunkConcurrency, 3);
    });

    test('turbo: eight chunks in flight', () {
      expect(speedProfileFor(SpeedMode.turbo).chunkConcurrency, 8);
    });

    test(
      'turbo is strictly more parallel than balanced, balanced than eco',
      () {
        final eco = speedProfileFor(SpeedMode.eco).chunkConcurrency;
        final bal = speedProfileFor(SpeedMode.balanced).chunkConcurrency;
        final turbo = speedProfileFor(SpeedMode.turbo).chunkConcurrency;
        expect(bal, greaterThan(eco));
        expect(turbo, greaterThan(bal));
      },
    );

    test('every profile is a valid FileSender concurrency (>= 1)', () {
      for (final m in SpeedMode.values) {
        expect(speedProfileFor(m).chunkConcurrency, greaterThanOrEqualTo(1));
      }
    });
  });

  group('CHARACTERIZATION: parseSpeedMode names and aliases', () {
    test('canonical names', () {
      expect(parseSpeedMode('eco'), SpeedMode.eco);
      expect(parseSpeedMode('balanced'), SpeedMode.balanced);
      expect(parseSpeedMode('turbo'), SpeedMode.turbo);
    });

    test('aliases: slow = eco, normal and default = balanced, fast and high = turbo', () {
      expect(parseSpeedMode('slow'), SpeedMode.eco);
      expect(parseSpeedMode('normal'), SpeedMode.balanced);
      expect(parseSpeedMode('default'), SpeedMode.balanced);
      expect(parseSpeedMode('fast'), SpeedMode.turbo);
      expect(parseSpeedMode('high'), SpeedMode.turbo);
    });

    test('case-insensitive', () {
      expect(parseSpeedMode('ECO'), SpeedMode.eco);
      expect(parseSpeedMode('Balanced'), SpeedMode.balanced);
      expect(parseSpeedMode('TuRbO'), SpeedMode.turbo);
      expect(parseSpeedMode('FAST'), SpeedMode.turbo);
    });

    test('surrounding whitespace is ignored', () {
      expect(parseSpeedMode('  turbo \t'), SpeedMode.turbo);
      expect(parseSpeedMode(' slow'), SpeedMode.eco);
    });

    test('null, empty and whitespace-only input give null', () {
      expect(parseSpeedMode(null), isNull);
      expect(parseSpeedMode(''), isNull);
      expect(parseSpeedMode('   '), isNull);
    });

    test('unknown names give null (no silent default)', () {
      expect(parseSpeedMode('warp'), isNull);
      expect(parseSpeedMode('ludicrous'), isNull);
      expect(parseSpeedMode('ecoo'), isNull);
      expect(parseSpeedMode('1'), isNull);
    });

    test('an inner space is not trimmed away', () {
      expect(parseSpeedMode('tu rbo'), isNull);
    });

    test('every enum value round-trips through its own name', () {
      for (final m in SpeedMode.values) {
        expect(parseSpeedMode(m.name), m);
      }
    });
  });
}
