import 'package:libreshare_core/src/security/secret_redactor.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('SecretRedactor Patterns', () {
    test('/t/<token> segment in path is redacted', () {
      expect(
        redactSecrets('GET /api/v1/t/AbCdEf12345/manifest HTTP/1.1'),
        'GET /api/v1/t/[redacted]/manifest HTTP/1.1',
      );
      expect(
        redactSecrets('URL: https://example.com/t/secret-token?foo=bar'),
        'URL: https://example.com/t/[redacted]?foo=bar',
      );
      expect(
        redactSecrets('Path: /t/my_token_123#frag'),
        'Path: /t/[redacted]#[redacted]',
      );
      expect(
        redactSecrets('Endpoint: "/t/token_end"'),
        'Endpoint: "/t/[redacted]"',
      );
    });

    test('URL fragments are redacted', () {
      expect(
        redactSecrets(
          'Visit https://libreshare.github.io/r#v=1&h=node1&k=secret',
        ),
        'Visit https://libreshare.github.io/r#[redacted]',
      );
      expect(
        redactSecrets('http://127.0.0.1:8080/path#secret_fragment and more'),
        'http://127.0.0.1:8080/path#[redacted] and more',
      );
    });

    test('parameters k, t, pin, s, claim values are redacted', () {
      expect(
        redactSecrets(
          'params: k=secretKey123&t=token456&pin=123456&s=session789&claim=claimVal',
        ),
        'params: k=[redacted]&t=[redacted]&pin=[redacted]&s=[redacted]&claim=[redacted]',
      );
      expect(
        redactSecrets('Single param: ?pin=999999'),
        'Single param: ?pin=[redacted]',
      );
      expect(
        redactSecrets('URI: libreshare://pair?s=pairSecret123'),
        'URI: libreshare://pair?[redacted]',
      );
    });

    test('X-LS-Claim header is redacted case-insensitively', () {
      expect(
        redactSecrets(
          'Headers: X-LS-Claim: 0123456789abcdef\nContent-Type: json',
        ),
        'Headers: X-LS-Claim: [redacted]\nContent-Type: json',
      );
      expect(
        redactSecrets('x-ls-claim: secret-claim-val'),
        'x-ls-claim: [redacted]',
      );
      expect(
        redactSecrets('X-Ls-Claim: secret-claim-val'),
        'X-Ls-Claim: [redacted]',
      );
    });

    test('libreshare:// query is redacted completely', () {
      expect(
        redactSecrets('Deep link: libreshare://r?v=1&h=foo.com&k=secret123'),
        'Deep link: libreshare://r?[redacted]',
      );
      expect(
        redactSecrets('Link: libreshare://pair?s=pairing-secret'),
        'Link: libreshare://pair?[redacted]',
      );
    });
  });

  group('False Positives and Idempotence', () {
    test('SHA-256 hex digests and filenames are NOT redacted', () {
      const sha =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      const filename = 'important_document_2026.pdf';
      final text = 'File $filename has sha256: $sha (chunk 0)';
      expect(redactSecrets(text), text);
    });

    test('Idempotence: redactSecrets(redactSecrets(x)) == redactSecrets(x)', () {
      const sample =
          'Error connecting to https://node.trycloudflare.com/t/abcde123#v=1&k=topsecret with pin=123456 and X-LS-Claim: 998877';
      final once = redactSecrets(sample);
      final twice = redactSecrets(once);
      expect(twice, equals(once));
    });

    test('redactUri scrubs URI secrets', () {
      final uri = Uri.parse(
        'https://example.com/t/secretToken?pin=1234#k=secretKey',
      );
      final redacted = redactUri(uri);
      expect(redacted, isNot(contains('secretToken')));
      expect(redacted, isNot(contains('1234')));
      expect(redacted, isNot(contains('secretKey')));
    });
  });

  group('Performance & Linear Time', () {
    test('1 MiB input completes in under 1 second (no catastrophic backtracking)', () {
      final buffer = StringBuffer();
      for (var i = 0; i < 20000; i++) {
        buffer.writeln(
          '2026-11-06 12:00:00.000 INFO [libreshare] File chunk-$i hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 status=ok /t/tempToken$i pin=555555',
        );
      }
      final input = buffer.toString();
      expect(input.length, greaterThan(1024 * 1024)); // > 1 MiB

      final sw = Stopwatch()..start();
      final output = redactSecrets(input);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(output, isNot(contains('tempToken0')));
      expect(output, isNot(contains('pin=555555')));
      expect(
        output,
        contains(
          'hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ),
      );
    });
  });

  group('redactingLogHandler', () {
    test('scrubs message, error and stack trace before passing to sink', () {
      final lines = <String>[];
      final handler = redactingLogHandler(lines.add);

      final record = LogRecord(
        Level.SEVERE,
        'Connecting to https://foo.com/t/secret123#k=mykey',
        'libreshare.test',
        Exception('Failed with pin=123456 and claim=secretClaim'),
        StackTrace.fromString(
          'at Object.connect (libreshare://r?v=1&k=secretKey)',
        ),
      );

      handler(record);

      expect(lines.length, 1);
      final logged = lines.first;
      expect(logged, isNot(contains('secret123')));
      expect(logged, isNot(contains('mykey')));
      expect(logged, isNot(contains('123456')));
      expect(logged, isNot(contains('secretClaim')));
      expect(logged, isNot(contains('secretKey')));
      expect(logged, contains('[redacted]'));
    });

    test('swallows exceptions thrown by sink', () {
      final handler = redactingLogHandler(
        (_) => throw StateError('Sink broken'),
      );
      final record = LogRecord(Level.INFO, 'Test message', 'libreshare');
      expect(() => handler(record), returnsNormally);
    });
  });
}
