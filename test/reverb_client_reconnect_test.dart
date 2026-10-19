import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pusher_reverb_flutter/pusher_reverb_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// How the fake server treats a new socket.
enum _Server { up, refusing, hanging }

/// A socket that answers the Reverb handshake, fails to connect, or hangs.
class _FakeSocket implements WebSocketChannel {
  _FakeSocket({required _Server server, required int socketNumber, this.answersPings = true}) {
    scheduleMicrotask(() {
      if (server == _Server.hanging) return;
      if (server == _Server.up) {
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

  /// Whether the server answers pusher:ping; a half-open socket does not.
  bool answersPings;

  List<String> get sentEvents => sent.map((m) => jsonDecode(m)['event'] as String).toList();

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
    if (_socket.answersPings && jsonDecode(event)['event'] == 'pusher:ping') {
      scheduleMicrotask(() => _socket.serverSends({'event': 'pusher:pong', 'data': '{}'}));
    }
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
  late _Server server;
  late bool answersPings;

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
        final socket = _FakeSocket(server: server, socketNumber: sockets.length + 1, answersPings: answersPings);
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
    server = _Server.up;
    answersPings = true;
  });

  test('backs off between attempts while the server is unreachable', () async {
    server = _Server.refusing;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));

    await elapse(const Duration(minutes: 5));

    // 2s, 4s, 8s, 16s, then every 30s: about 14 attempts, not one every 2s.
    expect(sockets.length, inInclusiveRange(10, 16));
    client.disconnect();
  });

  test('a long outage keeps the 30s ceiling instead of wrapping to 1s', () async {
    server = _Server.refusing;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(minutes: 40));
    final attemptsBefore = sockets.length;

    await elapse(const Duration(minutes: 5));

    expect(sockets.length - attemptsBefore, inInclusiveRange(9, 11));
    client.disconnect();
  });

  test('the backoff restarts after a connection succeeds', () async {
    server = _Server.refusing;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 70));
    final attemptsWhileDown = sockets.length;

    server = _Server.up;
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
    server = _Server.refusing;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));

    expect(client.connectionState, isNot(ConnectionState.connected));
    client.disconnect();
  });

  test('a pending reconnect does nothing when something else reconnected first', () async {
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));

    sockets.last.drop();
    await elapse(const Duration(milliseconds: 100));
    expect(client.connectionState, ConnectionState.reconnecting); // waiting 2s

    clock.run((_) => unawaited(client.connect())); // e.g. the app on resume
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

      expect(errors.whereType<AuthenticationException>().map((e) => e.statusCode), [401]);
      client.disconnect();
    }, () => authAnswering(401));
  });

  test('a 401 on the automatic resubscribe after a reconnect reaches onError', () async {
    final errors = <dynamic>[];
    var status = 200;
    await http.runWithClient(() async {
      final client = clock.run((_) => newClient(onError: errors.add));
      clock.run((_) => unawaited(client.connect()));
      await elapse(const Duration(seconds: 1));
      final channel = clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(milliseconds: 100));
      clock.run((_) => sockets.last.serverSends({'event': 'pusher_internal:subscription_succeeded', 'data': '{}', 'channel': 'private-user.1'}));
      await elapse(const Duration(milliseconds: 100));
      expect(channel.state, ChannelState.subscribed);

      status = 401;
      sockets.last.drop();
      await elapse(const Duration(seconds: 3));

      expect(sockets.length, 2);
      expect(errors.whereType<AuthenticationException>().map((e) => e.statusCode), [401]);
      client.disconnect();
    }, () => MockClient((request) async => http.Response(status == 200 ? jsonEncode({'auth': 'key:sig'}) : '{}', status)));
  });

  test('an auth request from before a reconnect cannot undo the resubscribe on the new socket', () async {
    final errors = <dynamic>[];
    var requests = 0;
    await http.runWithClient(() async {
      final client = clock.run((_) => newClient(onError: errors.add));
      clock.run((_) => unawaited(client.connect()));
      await elapse(const Duration(seconds: 1));

      // The first auth is slow and fails; the one for the new socket succeeds.
      final channel = clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(milliseconds: 100));
      sockets.last.drop(); // reconnects 2s later, while the first auth is in flight
      await elapse(const Duration(seconds: 8));

      expect(requests, 2);
      expect(sockets.last.sentEvents, contains('pusher:subscribe'));
      expect(channel.state, ChannelState.subscribing); // waiting for the server
      expect(errors.whereType<AuthenticationException>(), isEmpty);
      client.disconnect();
    }, () => MockClient((request) async {
          requests++;
          final first = requests == 1;
          await Future<void>.delayed(const Duration(seconds: 3));
          return first ? http.Response('{}', 500) : http.Response(jsonEncode({'auth': 'key:sig'}), 200);
        }));
  });

  test('after a quiet period the client pings, and a pong keeps the socket', () async {
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 29));
    expect(sockets.last.sentEvents, isNot(contains('pusher:ping')));

    await elapse(const Duration(seconds: 2)); // activity_timeout is 30s
    expect(sockets.last.sentEvents, contains('pusher:ping'));

    await elapse(const Duration(minutes: 3));
    expect(sockets.length, 1);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('traffic from the server postpones the ping', () async {
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    for (var i = 0; i < 4; i++) {
      await elapse(const Duration(seconds: 20));
      clock.run((_) => sockets.last.serverSends({'event': 'pusher:ping', 'data': '{}'}));
    }
    expect(sockets.last.sentEvents, isNot(contains('pusher:ping')));
    client.disconnect();
  });

  test('a socket that stops answering is replaced exactly once', () async {
    answersPings = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    answersPings = true;

    // Ping at 30s, no pong by 60s, a last ping with 5s grace, reconnect 2s later.
    await elapse(const Duration(seconds: 70));

    expect(sockets.length, 2);
    expect(sockets.first.closedByClient, isTrue);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('no ping is sent after disconnecting', () async {
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 1));
    client.disconnect();
    final sentBefore = sockets.last.sent.length;

    await elapse(const Duration(minutes: 2));

    expect(sockets.last.sent.length, sentBefore);
    expect(sockets.length, 1);
  });

  test('a handshake that never completes is abandoned and retried with backoff', () async {
    server = _Server.hanging;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 14));
    expect(sockets.length, 1);

    server = _Server.up;
    await elapse(const Duration(seconds: 4)); // 15s timeout, then 2s backoff

    expect(sockets.length, 2);
    expect(sockets.first.closedByClient, isTrue);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('checkConnection cuts a pending backoff short', () async {
    server = _Server.refusing;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 40)); // now waiting up to 30s
    final attempts = sockets.length;

    server = _Server.up;
    clock.run((_) => client.checkConnection());
    await elapse(const Duration(seconds: 1));

    expect(sockets.length, attempts + 1);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('checkConnection on a connected socket pings it right away', () async {
    answersPings = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 5));

    clock.run((_) => client.checkConnection());
    await elapse(const Duration(milliseconds: 100));
    expect(sockets.first.sentEvents, contains('pusher:ping'));

    // The socket is dead: replaced ~37s later instead of after a full quiet period.
    answersPings = true;
    await elapse(const Duration(seconds: 40));
    expect(sockets.length, 2);
    client.disconnect();
  });

  test('a pong that arrives right after the timeout, as after the app was frozen, keeps the socket', () async {
    answersPings = false;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 61)); // ping at 30s, timeout at 60s

    clock.run((_) => sockets.last.serverSends({'event': 'pusher:pong', 'data': '{}'}));
    await elapse(const Duration(seconds: 10));

    expect(sockets.length, 1);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('an auth request in flight when the socket drops cannot fail the channel for the new socket', () async {
    var requests = 0;
    await http.runWithClient(() async {
      final client = clock.run((_) => newClient());
      clock.run((_) => unawaited(client.connect()));
      await elapse(const Duration(seconds: 1));

      final channel = clock.run((_) => client.subscribeToPrivateChannel('private-user.1'));
      await elapse(const Duration(milliseconds: 100));
      sockets.last.drop();
      await elapse(const Duration(seconds: 1)); // the first auth fails during the outage
      await elapse(const Duration(seconds: 3)); // reconnect

      expect(sockets.length, 2);
      expect(requests, 2);
      expect(sockets.last.sentEvents, contains('pusher:subscribe'));
      expect(channel.state, ChannelState.subscribing); // waiting for the server
      client.disconnect();
    }, () => MockClient((request) async {
          requests++;
          if (requests == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            throw http.ClientException('network is down');
          }
          return http.Response(jsonEncode({'auth': 'key:sig'}), 200);
        }));
  });

  test('checkConnection replaces a handshake that has been hanging', () async {
    server = _Server.hanging;
    final client = clock.run((_) => newClient());
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(seconds: 5));

    server = _Server.up;
    clock.run((_) => client.checkConnection()); // e.g. the app resumes
    await elapse(const Duration(seconds: 1));

    expect(sockets.length, 2);
    expect(client.connectionState, ConnectionState.connected);
    client.disconnect();
  });

  test('checkConnection leaves a handshake that just started alone', () async {
    final client = clock.run((_) => newClient());
    server = _Server.hanging;
    clock.run((_) => unawaited(client.connect()));
    await elapse(const Duration(milliseconds: 500));

    clock.run((_) => client.checkConnection());
    await elapse(const Duration(milliseconds: 500));

    expect(sockets.length, 1);
    client.disconnect();
  });
}
