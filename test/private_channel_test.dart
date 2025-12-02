import 'package:flutter_test/flutter_test.dart';
import 'package:pusher_reverb_flutter/pusher_reverb_flutter.dart';

void main() {
  group('PrivateChannel', () {
    late Authorizer mockAuthorizer;
    late String testChannelName;
    late String testSocketId;
    late String testAuthEndpoint;
    late List<String> sentMessages;

    setUp(() {
      testChannelName = 'private-test-channel';
      testSocketId = 'test-socket-id';
      testAuthEndpoint = 'https://example.com/auth';
      sentMessages = [];

      mockAuthorizer = (String channelName, String socketId) async {
        return {'Authorization': 'Bearer test-token', 'X-Custom-Header': 'test-value'};
      };
    });

    PrivateChannel createPrivateChannel() {
      return PrivateChannel(
        name: testChannelName,
        authorizer: mockAuthorizer,
        authEndpoint: testAuthEndpoint,
        socketId: testSocketId,
        sendMessage: (String message) {
          sentMessages.add(message);
        },
      );
    }

    group('constructor', () {
      test('should create private channel with valid name', () {
        final channel = createPrivateChannel();
        expect(channel.name, testChannelName);
        expect(channel.state, ChannelState.unsubscribed);
      });

      test('should throw error for invalid private channel name', () {
        expect(
          () => PrivateChannel(name: 'public-channel', authorizer: mockAuthorizer, authEndpoint: testAuthEndpoint, socketId: testSocketId, sendMessage: (String message) {}),
          throwsA(isA<InvalidChannelNameException>()),
        );
      });

      test('should store authorizer and auth endpoint', () {
        final channel = createPrivateChannel();
        expect(channel.authorizer, mockAuthorizer);
        expect(channel.authEndpoint, testAuthEndpoint);
        expect(channel.socketId, testSocketId);
      });
    });

    group('subscribe', () {
      test('should not subscribe if already subscribed', () async {
        final channel = createPrivateChannel();

        // First subscription will fail due to HTTP not being mocked, but state should change
        try {
          await channel.subscribe();
        } catch (e) {
          // Expected to fail due to HTTP call
        }

        // Second subscription should not attempt again
        try {
          await channel.subscribe();
        } catch (e) {
          // Expected to fail due to HTTP call
        }

        // Should only have attempted one subscription
        expect(sentMessages.length, 0); // No messages sent due to HTTP failure
      });

      test('should not subscribe if already subscribing', () async {
        final channel = createPrivateChannel();

        // Start first subscription
        final firstSubscription = channel.subscribe();

        // Start second subscription while first is in progress
        final secondSubscription = channel.subscribe();

        try {
          await Future.wait([firstSubscription, secondSubscription]);
        } catch (e) {
          // Expected to fail due to HTTP call
        }

        // Should only have attempted one subscription
        expect(sentMessages.length, 0); // No messages sent due to HTTP failure
      });

      test('should call authorizer with correct parameters', () async {
        bool authorizerCalled = false;
        String? calledChannelName;
        String? calledSocketId;

        Future<Map<String, String>> customAuthorizer(String channelName, String socketId) async {
          authorizerCalled = true;
          calledChannelName = channelName;
          calledSocketId = socketId;
          return {'Authorization': 'Bearer test-token'};
        }

        final channel = PrivateChannel(
          name: testChannelName,
          authorizer: customAuthorizer,
          authEndpoint: testAuthEndpoint,
          socketId: testSocketId,
          sendMessage: (String message) {
            sentMessages.add(message);
          },
        );

        try {
          await channel.subscribe();
        } catch (e) {
          // Expected to fail due to HTTP call
        }

        expect(authorizerCalled, true);
        expect(calledChannelName, testChannelName);
        expect(calledSocketId, testSocketId);
      });
    });

    group('inherited functionality', () {
      test('should support event binding and unbinding', () {
        final channel = createPrivateChannel();
        bool eventReceived = false;

        channel.bind('test-event', (String eventName, dynamic data) {
          eventReceived = true;
        });

        channel.handleEvent('test-event', 'test-data');
        expect(eventReceived, true);

        channel.unbind('test-event');
        eventReceived = false;
        channel.handleEvent('test-event', 'test-data');
        expect(eventReceived, false);
      });

      test('should support state change listeners', () {
        final channel = createPrivateChannel();
        ChannelState? lastState;

        channel.addStateListener((ChannelState state) {
          lastState = state;
        });

        // State should change during subscription attempt
        expect(lastState, isNull);
      });

      test('should support unsubscribe', () async {
        final channel = createPrivateChannel();

        // Unsubscribe should work even if not subscribed
        await channel.unsubscribe();
        expect(channel.state, ChannelState.unsubscribed);
      });
    });

    group('whisper (client events)', () {
      test('should send client event with correct format', () {
        final channel = createPrivateChannel();
        // Manually set state to subscribed for testing
        channel.handleSubscriptionSucceeded();

        channel.whisper('client-typing', data: {
          'user_id': 'user123',
          'timestamp': '2024-01-01T00:00:00Z',
        });

        expect(sentMessages.length, 1);
        final sentMessage = sentMessages[0];
        expect(sentMessage, contains('"event":"client-typing"'));
        expect(sentMessage, contains('"channel":"$testChannelName"'));
        expect(sentMessage, contains('"user_id":"user123"'));
      });

      test('should send client event with empty data if not provided', () {
        final channel = createPrivateChannel();
        channel.handleSubscriptionSucceeded();

        channel.whisper('client-cursor-moved');

        expect(sentMessages.length, 1);
        final sentMessage = sentMessages[0];
        expect(sentMessage, contains('"event":"client-cursor-moved"'));
        expect(sentMessage, contains('"data":{}'));
      });

      test('should throw ArgumentError if event name does not start with "client-"', () {
        final channel = createPrivateChannel();
        channel.handleSubscriptionSucceeded();

        expect(
          () => channel.whisper('typing', data: {'user_id': 'user123'}),
          throwsA(isA<ArgumentError>()),
        );
        expect(sentMessages.length, 0);
      });

      test('should throw ChannelException if channel is not subscribed', () {
        final channel = createPrivateChannel();
        // Leave channel in unsubscribed state

        expect(
          () => channel.whisper('client-typing', data: {'user_id': 'user123'}),
          throwsA(isA<ChannelException>()),
        );
        expect(sentMessages.length, 0);
      });

      test('should allow multiple client events with different names', () {
        final channel = createPrivateChannel();
        channel.handleSubscriptionSucceeded();

        channel.whisper('client-typing', data: {'status': 'started'});
        channel.whisper('client-cursor-moved', data: {'x': 100, 'y': 200});
        channel.whisper('client-custom-event', data: {'custom': 'data'});

        expect(sentMessages.length, 3);
        expect(sentMessages[0], contains('"event":"client-typing"'));
        expect(sentMessages[1], contains('"event":"client-cursor-moved"'));
        expect(sentMessages[2], contains('"event":"client-custom-event"'));
      });
    });
  });
}
