import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pusher_reverb_flutter/pusher_reverb_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A socket that either answers the Reverb handshake or fails to connect.
class _FakeSocket implements WebSocketChannel {
  _FakeSocket({required bool reachable, required int socketNumber}) {
    scheduleMicrotask(() {
      if (reachable) {
        _ready.complete();
        _incoming.add(jsonEncode({
          'event': 'pusher:connection_established',
          'data': jsonEncode({'socket_id': '$socketNumber.1', 'activity_timeout': 30}),
        }));
      } else {
        _ready.completeError(Exception('connection refused'));
        _incoming.addError(Exception('connection refused'));
        _incoming.close();
      }
    });
  }

  final _incoming = StreamController<dynamic>();
  final _ready = Completer<void>();
  bool closedByClient = false;
  final sent = <String>[];

  /// The server sends a raw frame.
  void serverSends(Map<String, dynamic> frame) => _incoming.add(jsonEncode(frame));

  /// The server drops the connection.
  void drop() => _incoming.close();

  @override
  Stream get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _FakeSink(this);

  @override
  Future<void> get ready => _ready.future;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  // The client never pipes or transforms the socket.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._socket);

  final _FakeSocket _socket;

  @override
  void add(dynamic event) {
    // Like a real socket sink, writing after close throws.
    if (_socket.closedByClient) throw StateError('Cannot add event after closing');
    _socket.sent.add(event as String);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<dynamic> stream) => stream.drain();

  @override
  Future close([int? closeCode, String? closeReason]) async {
    _socket.closedByClient = true;
  }

  @override
  Future get done => Future.value();
}

void main() {
  late FakeAsync clock;
  late List<_FakeSocket> sockets;
  late bool reachable;

  ReverbClient newClient({void Function(dynamic error)? onError}) {
    return ReverbClient.forTesting(
      host: 'ws.test.local',
      port: 443,
      appKey: 'app-key',
      useTLS: true,
      authEndpoint: 'https://test.local/broadcasting/auth',
      authorizer: (channelName, socketId) async => {'Authorization': 'Bearer t'},
      onError: onError,
      channelFactory: (_) {
        final socket = _FakeSocket(reachable: reachable, socketNumber: sockets.length + 1);
        sockets.add(socket);
        return socket;
      },
    );
  }

  /// Advances fake time while letting futures that were completed outside the
  /// fake zone (such as a cancelled broadcast subscription) resume.
  Future<void> elapse(Duration duration) async {
    final steps = duration.inMilliseconds ~/ 100;
    for (var i = 0; i < steps; i++) {
      clock.elapse(const Duration(milliseconds: 100));
      await Future<void>.delayed(Duration.zero);
      clock.flushMicrotasks();
    }
  }

  http.Client authAnswering(int statusCode) => MockClient((request) async =>
      http.Response(statusCode == 200 ? jsonEncode({'auth': 'key:sig'}) : '{}', statusCode));

  setUp(() {
    clock = FakeAsync();
    sockets = [];
    reachable = true;
  });

  test('backs off between attempts while the server is unreachable', () async {
    reachable = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));

    await elapse(const Duration(minutes: 5));

    // 2s, 4s, 8s, 16s, then every 30s: about 14 attempts, not one every 2s.
    expect(sockets.length, inInclusiveRange(10, 16));
    client.disconnect();
  });

  test('a long outage keeps the 30s ceiling instead of wrapping to 1s', () async {
    reachable = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(minutes: 40));
    final attemptsBefore = sockets.length;

    await elapse(const Duration(minutes: 5));

    expect(sockets.length - attemptsBefore, inInclusiveRange(9, 11));
    client.disconnect();
  });

  test('the backoff restarts after a connection succeeds', () async {
    reachable = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 70));
    final attemptsWhileDown = sockets.length;

    reachable = true;
    await elapse(const Duration(seconds: 31));
    expect(client.connectionState, ConnectionState.connected);

    sockets.last.drop();
    await elapse(const Duration(seconds: 3));

    expect(sockets.length, attemptsWhileDown + 2);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('connecting again closes the previous socket and stops listening to it', () async {
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));

    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));
    expect(sockets.first.closedByClient, isTrue);

    // A late close of the old socket must not start a reconnect chain.
    sockets.first.drop();
    await elapse(const Duration(minutes: 2));

    expect(sockets.length, 2);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('a reconnect that finds the client already connected does nothing', () async {
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));

    sockets.last.drop(); // schedules a reconnect in 2s
    clock.run((_) => unawaited(client.connect())); // something else reconnects first
    await elapse(const Duration(seconds: 5));

    expect(sockets.length, 2);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('a private channel auth failure is reported to onError, not thrown away', () async {
    final errors = <dynamic>[];
    await http.runWithClient(() async {
      final client = clock.run((_) => newClient(onError: errors.add));
      clock.run((_) => unawaited(client.connect()));
      await elapse(const Duration(seconds: 1));

      clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(seconds: 1));

      expect(
        errors.whereType<AuthenticationException>().map((e) => e.statusCode),
        [401],
      );

      // The same goes for the automatic resubscribe after a reconnect.
      errors.clear();
      clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(milliseconds: 100));
      sockets.last.drop();
      await elapse(const Duration(seconds: 3));

      expect(errors.whereType<AuthenticationException>(), isNotEmpty);
      client.disconnect();
    }, () => authAnswering(401));
  });

  test('subscription_succeeded as Reverb sends it marks the channel subscribed', () async {
    await http.runWithClient(() async {
      final client = clock.run((_) => newClient());
      clock.run((_) => unawaited(client.connect()));
      await elapse(const Duration(seconds: 1));

      final channel = clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(milliseconds: 100));
      // Reverb puts the channel name at the top level and sends empty data.
      clock.run((_) => sockets.last.serverSends({
            'event': 'pusher_internal:subscription_succeeded',
            'data': '{}',
            'channel': 'private-user.1',
          }));
      await elapse(const Duration(milliseconds: 100));

      expect(channel.state, ChannelState.subscribed);
      client.disconnect();
    }, () => authAnswering(200));
  });

  test('disconnecting leaves channels before closing the socket', () async {
    await http.runWithClient(() async {
      final client = clock.run((_) => newClient());
      clock.run((_) => unawaited(client.connect()));
      await elapse(const Duration(seconds: 1));
      clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(milliseconds: 100));

      clock.run((_) => client.disconnect());
      await elapse(const Duration(milliseconds: 100));

      expect(sockets.last.sent.map((m) => jsonDecode(m)['event']), contains('pusher:unsubscribe'));
      expect(sockets.last.closedByClient, isTrue);
    }, () => authAnswering(200));
  });

  test('a failed handshake is not also raised as an unhandled error', () async {
    reachable = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));

    expect(client.connectionState, isNot(ConnectionState.connected));
    client.disconnect();
  });
}
