/// A cancellable outgoing send (the handle behind
/// `LibreShareEngine.beginSendTo` / `beginSendFiles`).
///
/// `sendFiles` / `sendTo` answer only when the send is over. A UI also needs
/// to react while it runs (which session, how far) and to stop it: this is the
/// handle for that. It owns the whole attempt, from finding a reachable address
/// of the peer to the final result, so `cancel()` is safe at every moment of it.
library;

import 'dart:async';
import 'dart:io';

import '../client/peer_client.dart';
import '../model/events.dart';
import '../model/transfer_status.dart';
import '../transfer/file_sender.dart';

/// Where a send goes.
typedef SendEndpoint = ({String host, int port});

/// "The caller asked to cancel", as seen by the code that looks for an
/// address. Passed to the lookup so it can stop early.
class CancelSignal {
  bool _cancelled = false;
  final Completer<void> _whenCancelled = Completer<void>();

  /// True once [OutgoingSend.cancel] was called.
  bool get isCancelled => _cancelled;

  /// Completes when [OutgoingSend.cancel] is called (never, if it is not).
  Future<void> get whenCancelled => _whenCancelled.future;

  void _fire() {
    _cancelled = true;
    if (!_whenCancelled.isCompleted) _whenCancelled.complete();
  }
}

/// Finds where to send, or null when the peer cannot be reached. Should return
/// promptly once [cancel] is cancelled.
typedef FindEndpoint = Future<SendEndpoint?> Function(CancelSignal cancel);

/// One outgoing send in flight.
///
/// * [events]: this send's own events, in order: `SessionCreated(outgoing)`
///   (once the peer answered), `FileProgress`*, then exactly one
///   `SessionFinished` as the last event, after which the stream is done. The
///   same events are also published on the engine's `events` stream.
/// * [result]: the final [SendResult]. Network and protocol failures are in it
///   (`FAILED(NO_CONNECTION)`, `FAILED(REJECTED)`, `FAILED(CANCELLED)`...),
///   never thrown. Like `FileSender.send` (and so `sendFiles`) it completes
///   with a [FileSystemException] when a picked file is missing or not
///   readable before any session exists (no events are emitted then).
/// * [cancel]: ends the send. Safe at any moment, any number of times.
class OutgoingSend {
  /// Starts the send now. For `LibreShareEngine`; use its `beginSendTo` /
  /// `beginSendFiles`.
  ///
  /// [find] locates the peer; [connect] opens a client to the endpoint it
  /// found (closed when the send is over); [newSender] builds the sender around
  /// that client and routes its events to the given callback; [publish]
  /// receives every event as well (the engine-wide stream).
  OutgoingSend.start({
    required List<File> files,
    required this._find,
    required this._connect,
    required this._newSender,
    this._publish,
  }) : _files = files {
    if (files.isEmpty) {
      throw ArgumentError.value(files, 'files', 'must not be empty');
    }
    _run().then(_result.complete, onError: _result.completeError);
  }

  final List<File> _files;
  final FindEndpoint _find;
  final PeerClient Function(SendEndpoint) _connect;
  final FileSender Function(PeerClient, void Function(LsEvent)) _newSender;
  final void Function(LsEvent)? _publish;

  // Single-subscription: buffers until the first listener, so a listener that
  // attaches a moment late still sees every event.
  final StreamController<LsEvent> _events = StreamController<LsEvent>();
  final Completer<SendResult> _result = Completer<SendResult>();
  final CancelSignal _cancel = CancelSignal();
  FileSender? _sender;
  String? _sessionId;
  bool _finished = false;

  /// This send's events (see the class comment). Listen once.
  Stream<LsEvent> get events => _events.stream;

  /// The final result. Completes after the last event was added to [events].
  Future<SendResult> get result => _result.future;

  /// The peer's session id, null until the peer created the session.
  String? get sessionId => _sessionId;

  /// [cancel] was called.
  bool get cancelRequested => _cancel.isCancelled;

  /// The send is over ([result] is about to complete or has).
  bool get isFinished => _finished;

  /// Stops the send; [result] then resolves with `FAILED(CANCELLED)` (unless
  /// the send had already completed). Safe at any moment, and idempotent:
  ///
  /// * while the peer is being looked up: nothing is sent, the lookup is
  ///   abandoned at once;
  /// * after the peer created its session, even if the reply naming it has not
  ///   been read yet: the peer is told (`/cancel`) so its consent prompt and
  ///   session close, and no file is transferred;
  /// * mid-transfer: uploading stops and the peer is told.
  ///
  /// Completes once the peer was told, when it already had a session; in the
  /// remaining cases [result] is the thing to await (it resolves only after the
  /// peer has been told).
  Future<void> cancel() async {
    _cancel._fire();
    final sender = _sender;
    if (sender != null) await sender.cancel();
  }

  Future<SendResult> _run() async {
    // A cancel() made right after the constructor returned wins before any
    // network traffic starts.
    await Future<void>.value();
    final sw = Stopwatch()..start();
    try {
      final endpoint = await _find(_cancel);
      if (_cancel.isCancelled) {
        return _ended(sw, FailureReason.cancelled);
      }
      if (endpoint == null) {
        return _ended(sw, FailureReason.noConnection);
      }
      final client = _connect(endpoint);
      try {
        // From here to send() starting there is no await: a cancel() either
        // happened before (handled above) or finds the sender.
        final sender = _newSender(client, _onSenderEvent);
        _sender = sender;
        return await sender.send(_files);
      } finally {
        client.close();
      }
    } finally {
      _finished = true;
      unawaited(_events.close());
    }
  }

  SendResult _ended(Stopwatch sw, FailureReason reason) {
    _emit(SessionFinished('', success: false, reason: reason.wire));
    return SendResult(
      sessionId: '',
      status: TransferStatus.failed,
      failureReason: reason,
      bytesSent: 0,
      elapsed: sw.elapsed,
    );
  }

  void _onSenderEvent(LsEvent e) {
    if (e is SessionCreated && e.outgoing) _sessionId = e.sessionId;
    _emit(e);
  }

  void _emit(LsEvent e) {
    if (!_events.isClosed) _events.add(e);
    final publish = _publish;
    if (publish != null) publish(e);
  }
}
