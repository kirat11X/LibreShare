import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/notifications/notification_service.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/notification_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// Test clock that allows explicit time manipulation.
class TestClock implements Clock {
  TestClock([DateTime? initial]) : _now = initial ?? DateTime(2026, 11, 6, 10);
  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}

/// Fake receiver extending FileReceiver for testing engine receiver seam.
class FakeReceiver extends FileReceiver {
  FakeReceiver()
    : super(
        self: const DeviceInfo(
          deviceId: 'self-id',
          alias: 'Test Receiver',
          platform: 'linux',
        ),
        downloadDir: Directory.systemTemp,
      );

  final Map<String, SessionRequest> testRequests = {};
  final List<String> acceptedSessions = [];
  final List<String> rejectedSessions = [];
  final List<String> cancelledSessions = [];

  @override
  SessionRequest? requestFor(String sessionId) => testRequests[sessionId];

  @override
  Future<SessionStatus> accept(String sessionId) async {
    acceptedSessions.add(sessionId);
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.inProgress,
    );
  }

  @override
  Future<void> reject(String sessionId) async {
    rejectedSessions.add(sessionId);
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelledSessions.add(sessionId);
  }
}

/// Fake LibreShareEngine for testing engine events and receiver seam.
class TestEngine implements LibreShareEngine {
  TestEngine() : receiver = FakeReceiver();

  @override
  final FakeReceiver receiver;

  final StreamController<LsEvent> _eventController =
      StreamController<LsEvent>.broadcast();

  @override
  Stream<LsEvent> get events => _eventController.stream;

  void emitEvent(LsEvent event) {
    _eventController.add(event);
  }

  @override
  Duration get permissionTimeout => const Duration(seconds: 120);

  @override
  List<DiscoveredDevice> get currentDevices => const [];

  @override
  DeviceInfo get self => const DeviceInfo(
    deviceId: 'self-device-id',
    alias: 'This Device',
    platform: 'linux',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<void> dispose({bool force = false}) async {
    await _eventController.close();
  }
}

void main() {
  group('NotificationService interface and NoOp implementation', () {
    test('NoOpNotificationService handles all methods without error', () async {
      const service = NoOpNotificationService();

      await service.showIncomingRequest(
        sessionId: 's1',
        peerName: 'Pixel',
        fileCount: 2,
        totalBytes: 4096,
      );
      await service.showProgress(
        sessionId: 's1',
        progress: 0.5,
        speed: '1.2 MB/s',
      );
      await service.showCompleted(sessionId: 's1', fileCount: 2);
      await service.showFailed(sessionId: 's1', reason: 'Connection timeout');
      await service.cancel('s1');

      service.onAction(const NotificationAction.accept('s1'));

      final actions = await service.actions.toList();
      expect(actions, isEmpty);
    });

    test('NotificationAction equality and properties', () {
      const a1 = NotificationAction.accept('session-1');
      const a2 = NotificationAction(
        sessionId: 'session-1',
        type: NotificationActionType.accept,
      );
      const r1 = NotificationAction.reject('session-1');
      const r2 = NotificationAction.reject('session-2');

      expect(a1, equals(a2));
      expect(a1.isAccept, isTrue);
      expect(a1.isReject, isFalse);
      expect(r1.isReject, isTrue);
      expect(r1.isAccept, isFalse);
      expect(a1, isNot(equals(r1)));
      expect(r1, isNot(equals(r2)));
      expect(a1.hashCode, equals(a2.hashCode));
      expect(a1.toString(), contains('session-1'));
    });
  });

  group('Clean file name truncation and sanitization', () {
    test('truncateFileName handles short and long names properly', () {
      expect(truncateFileName('report.pdf', maxLength: 32), 'report.pdf');
      expect(
        truncateFileName(
          'very_long_document_name_exceeding_budget_by_far.pdf',
          maxLength: 24,
        ),
        'very_long_document_….pdf',
      );
      expect(
        truncateFileName(
          'name_without_extension_that_is_quite_long',
          maxLength: 16,
        ),
        'name_without_ex…',
      );
      expect(truncateFileName('exact10chs', maxLength: 10), 'exact10chs');
      expect(truncateFileName('.hidden', maxLength: 10), '.hidden');
    });

    test('sanitizeNotificationText scrubs sensitive secrets and PINS', () {
      // 64-hex fingerprint
      const fullFingerprint =
          '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
      expect(
        sanitizeNotificationText('Failed for peer $fullFingerprint'),
        'Failed for peer [fingerprint]',
      );

      // Private key blocks
      const privKey =
          '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0...\n-----END RSA PRIVATE KEY-----';
      expect(sanitizeNotificationText('Key: $privKey'), 'Key: [redacted key]');

      // Pairing secrets
      expect(
        sanitizeNotificationText('Pair link s=secret_code_123456789'),
        'Pair link s=[redacted]',
      );

      // 6-digit PIN patterns
      expect(
        sanitizeNotificationText('Auth failed: pin: 123456'),
        'Auth failed: pin: [pin]',
      );
      expect(
        sanitizeNotificationText('pin=987654 rejected'),
        'pin=[pin] rejected',
      );
    });
  });

  group('NotificationProvider and Riverpod mapping', () {
    late FakeNotificationService fakeService;
    late TestEngine engine;
    late TestClock clock;
    late ProviderContainer container;

    setUp(() {
      fakeService = FakeNotificationService();
      engine = TestEngine();
      clock = TestClock();

      container = ProviderContainer(
        overrides: [
          notificationServiceProvider.overrideWithValue(fakeService),
          notificationThrottleDurationProvider.overrideWithValue(
            const Duration(milliseconds: 500),
          ),
          clockProvider.overrideWithValue(clock),
          engineOrNullProvider.overrideWithValue(engine),
        ],
      );

      // Initialize providers to subscribe to engine events
      container.read(transfersProvider);
      container.read(notificationProvider);
    });

    tearDown(() {
      container.dispose();
      engine.dispose();
      fakeService.dispose();
    });

    test(
      'incoming session notification is posted with correct details',
      () async {
        const sessionId = 'incoming-session-001';
        engine.receiver.testRequests[sessionId] = const SessionRequest(
          sender: DeviceInfo(
            deviceId: 'peer-device-1',
            alias: 'Alice MacBook',
            platform: 'macos',
          ),
          files: [
            FileItem(
              fileId: 'f1',
              fileName: 'photo.jpg',
              size: 1024,
              chunkCount: 1,
            ),
            FileItem(
              fileId: 'f2',
              fileName: 'notes.txt',
              size: 2048,
              chunkCount: 1,
            ),
          ],
          totalSize: 3072,
        );

        engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
        await Future<void>.delayed(Duration.zero);

        expect(fakeService.incomingRequests.length, 1);
        final call = fakeService.incomingRequests.single;
        expect(call.sessionId, sessionId);
        expect(call.peerName, 'Alice MacBook');
        expect(call.fileCount, 2);
        expect(call.totalBytes, 3072);

        final state = container.read(notificationProvider);
        expect(state.activeNotifications.containsKey(sessionId), isTrue);
        expect(
          state.activeNotifications[sessionId]!.type,
          NotificationType.incoming,
        );
      },
    );

    test('deduplication invariant: exactly ONE notification posted per incoming session', () async {
      const sessionId = 'incoming-session-dedup';
      engine.receiver.testRequests[sessionId] = const SessionRequest(
        sender: DeviceInfo(
          deviceId: 'peer-device-2',
          alias: 'Bob Phone',
          platform: 'android',
        ),
        files: [
          FileItem(
            fileId: 'f1',
            fileName: 'doc.pdf',
            size: 5000,
            chunkCount: 1,
          ),
        ],
        totalSize: 5000,
      );

      // Fire SessionCreated multiple times for the same session ID
      engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
      await Future<void>.delayed(Duration.zero);
      engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
      await Future<void>.delayed(Duration.zero);
      engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
      await Future<void>.delayed(Duration.zero);

      expect(fakeService.incomingRequests.length, 1);
    });

    test(
      'accept action triggers receive session accept and cancels notification',
      () async {
        const sessionId = 'incoming-session-accept';
        engine.receiver.testRequests[sessionId] = const SessionRequest(
          sender: DeviceInfo(
            deviceId: 'peer-device-3',
            alias: 'Charlie Linux',
            platform: 'linux',
          ),
          files: [
            FileItem(
              fileId: 'f1',
              fileName: 'archive.tar.gz',
              size: 10000,
              chunkCount: 1,
            ),
          ],
          totalSize: 10000,
        );

        // Post incoming notification
        engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
        await Future<void>.delayed(Duration.zero);
        expect(fakeService.incomingRequests.length, 1);

        // Trigger accept notification action
        fakeService.triggerAction(const NotificationAction.accept(sessionId));
        await Future<void>.delayed(Duration.zero);

        // Receiver accept was called with the SAME session id
        expect(engine.receiver.acceptedSessions, contains(sessionId));
        // Incoming notification was cancelled
        expect(fakeService.cancelledSessions, contains(sessionId));
      },
    );

    test(
      'reject action triggers receive session reject and cancels notification',
      () async {
        const sessionId = 'incoming-session-reject';
        engine.receiver.testRequests[sessionId] = const SessionRequest(
          sender: DeviceInfo(
            deviceId: 'peer-device-4',
            alias: 'Dana Windows',
            platform: 'windows',
          ),
          files: [
            FileItem(
              fileId: 'f1',
              fileName: 'video.mp4',
              size: 80000,
              chunkCount: 1,
            ),
          ],
          totalSize: 80000,
        );

        // Post incoming notification
        engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
        await Future<void>.delayed(Duration.zero);
        expect(fakeService.incomingRequests.length, 1);

        // Trigger reject notification action
        fakeService.triggerAction(const NotificationAction.reject(sessionId));
        await Future<void>.delayed(Duration.zero);

        // Receiver reject was called with the SAME session id
        expect(engine.receiver.rejectedSessions, contains(sessionId));
        // Incoming notification was cancelled
        expect(fakeService.cancelledSessions, contains(sessionId));
      },
    );

    test('progress updates are throttled within throttle interval', () async {
      const sessionId = 'session-progress-throttle';

      // First progress event immediately posts notification
      engine.emitEvent(const FileProgress(sessionId, 'f1', 100, 1000));
      await Future<void>.delayed(Duration.zero);
      expect(fakeService.progressUpdates.length, 1);
      expect(fakeService.progressUpdates.first.progress, 0.1);

      // Rapid progress events within 500 ms window should be throttled
      clock.advance(const Duration(milliseconds: 100));
      engine.emitEvent(const FileProgress(sessionId, 'f1', 200, 1000));
      clock.advance(const Duration(milliseconds: 100));
      engine.emitEvent(const FileProgress(sessionId, 'f1', 300, 1000));
      clock.advance(const Duration(milliseconds: 100));
      engine.emitEvent(const FileProgress(sessionId, 'f1', 400, 1000));
      await Future<void>.delayed(Duration.zero);

      // Still only 1 progress update posted due to throttling!
      expect(fakeService.progressUpdates.length, 1);

      // Advance clock past the 500 ms throttle interval
      clock.advance(const Duration(milliseconds: 300)); // Total 600 ms elapsed
      engine.emitEvent(const FileProgress(sessionId, 'f1', 600, 1000));
      await Future<void>.delayed(Duration.zero);

      // Second update posted!
      expect(fakeService.progressUpdates.length, 2);
      expect(fakeService.progressUpdates.last.progress, 0.6);

      // 100% completion is posted without throttling delay
      clock.advance(const Duration(milliseconds: 50));
      engine.emitEvent(const FileProgress(sessionId, 'f1', 1000, 1000));
      await Future<void>.delayed(Duration.zero);

      expect(fakeService.progressUpdates.length, 3);
      expect(fakeService.progressUpdates.last.progress, 1.0);
    });

    test('assert no PIN or secret in notification payload', () async {
      const sessionId = 'session-secret-check';
      const sensitivePin = '849201';
      const fullFingerprint =
          'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789';

      engine.receiver.testRequests[sessionId] = const SessionRequest(
        sender: DeviceInfo(
          deviceId: 'peer-sec',
          alias: 'Secure Device',
          platform: 'linux',
          fingerprint: fullFingerprint,
        ),
        pin: sensitivePin,
        files: [
          FileItem(
            fileId: 'f1',
            fileName: 'secret_file.pdf',
            size: 1000,
            chunkCount: 1,
          ),
        ],
        totalSize: 1000,
      );

      engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
      await Future<void>.delayed(Duration.zero);

      expect(fakeService.incomingRequests.length, 1);
      final incoming = fakeService.incomingRequests.single;

      // Assert PIN is NOT in any notification payload field
      expect(incoming.peerName.contains(sensitivePin), isFalse);
      expect(incoming.sessionId.contains(sensitivePin), isFalse);
      expect(incoming.peerName.contains(fullFingerprint), isFalse);

      // Check failure notification sanitization
      engine.emitEvent(
        const SessionFinished(
          sessionId,
          success: false,
          reason: 'Failed with pin: 849201 and cert ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(fakeService.failedCalls.length, 1);
      final failure = fakeService.failedCalls.single;
      expect(failure.reason.contains(sensitivePin), isFalse);
      expect(failure.reason.contains(fullFingerprint), isFalse);
      expect(failure.reason, contains('[pin]'));
      expect(failure.reason, contains('[fingerprint]'));
    });

    test('session completed triggers showCompleted with file count', () async {
      const sessionId = 'session-completed-check';
      engine.receiver.testRequests[sessionId] = const SessionRequest(
        sender: DeviceInfo(
          deviceId: 'peer-comp',
          alias: 'Sender Device',
          platform: 'android',
        ),
        files: [
          FileItem(fileId: 'f1', fileName: 'f1.txt', size: 100, chunkCount: 1),
          FileItem(fileId: 'f2', fileName: 'f2.txt', size: 200, chunkCount: 1),
          FileItem(fileId: 'f3', fileName: 'f3.txt', size: 300, chunkCount: 1),
        ],
        totalSize: 600,
      );

      // Establish session
      engine.emitEvent(const SessionCreated(sessionId, outgoing: false));
      await Future<void>.delayed(Duration.zero);

      // Complete session
      engine.emitEvent(const SessionFinished(sessionId, success: true));
      await Future<void>.delayed(Duration.zero);

      expect(fakeService.completedCalls.length, 1);
      final completed = fakeService.completedCalls.single;
      expect(completed.sessionId, sessionId);
      expect(completed.fileCount, 3);
    });
  });
}
