import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pusher_reverb_flutter/pusher_reverb_flutter.dart';
import '../services/reverb_service.dart';

class ClientEventsScreen extends StatefulWidget {
  const ClientEventsScreen({super.key});

  @override
  State<ClientEventsScreen> createState() => _ClientEventsScreenState();
}

class _ClientEventsScreenState extends State<ClientEventsScreen> {
  final _reverbService = ReverbService.instance;
  final _channelNameController = TextEditingController(text: 'presence-chat-demo');
  final _userIdController = TextEditingController(text: 'User${DateTime.now().millisecondsSinceEpoch % 1000}');
  final _messageController = TextEditingController();

  PresenceChannel? _channel;
  final List<ChatMessage> _messages = [];
  final Map<String, DateTime> _typingUsers = {};
  bool _isSubscribed = false;
  bool _isLoading = false;
  String? _error;
  Timer? _typingTimer;

  @override
  void dispose() {
    _channelNameController.dispose();
    _userIdController.dispose();
    _messageController.dispose();
    _typingTimer?.cancel();
    _unsubscribe();
    super.dispose();
  }

  Future<void> _subscribe() async {
    if (_reverbService.client == null) {
      setState(() {
        _error = 'Please connect to the server first from the Home screen';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _messages.clear();
      _typingUsers.clear();
    });

    try {
      final channelName = _channelNameController.text.trim();

      // Validate that it starts with "presence-"
      if (!channelName.startsWith('presence-')) {
        setState(() {
          _error = 'Presence channel names must start with "presence-"';
          _isLoading = false;
        });
        return;
      }

      // Subscribe to presence channel
      _channel = _reverbService.client!.subscribeToPresenceChannel(channelName);

      // Listen for chat messages
      _channel!.on('chat-message').listen((event) {
        setState(() {
          _messages.insert(0, ChatMessage(
            userId: event.data['user_id'] as String,
            message: event.data['message'] as String,
            timestamp: DateTime.parse(event.data['timestamp'] as String),
          ));

          // Keep only last 50 messages
          if (_messages.length > 50) {
            _messages.removeLast();
          }
        });
      });

      // Listen for typing indicators (client events)
      _channel!.on('client-typing').listen((event) {
        final userId = event.data['user_id'] as String;

        // Don't show our own typing indicator
        if (userId != _userIdController.text) {
          setState(() {
            _typingUsers[userId] = DateTime.now();
          });

          // Remove typing indicator after 3 seconds
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted) {
              setState(() {
                final lastTyping = _typingUsers[userId];
                if (lastTyping != null &&
                    DateTime.now().difference(lastTyping).inSeconds >= 3) {
                  _typingUsers.remove(userId);
                }
              });
            }
          });
        }
      });

      setState(() {
        _isSubscribed = true;
        _isLoading = false;
      });
    } on AuthenticationException catch (e) {
      setState(() {
        _error = 'Authentication failed: ${e.message}\n'
            'Status: ${e.statusCode}\n'
            'Make sure your auth token is configured in Settings';
        _isLoading = false;
      });
    } on InvalidChannelNameException catch (e) {
      setState(() {
        _error = 'Invalid channel name: ${e.message}';
        _isLoading = false;
      });
    } on ChannelException catch (e) {
      setState(() {
        _error = 'Channel error: ${e.message}';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _unsubscribe() async {
    if (_channel != null) {
      try {
        await _channel!.unsubscribe();
        setState(() {
          _isSubscribed = false;
          _channel = null;
          _typingUsers.clear();
        });
      } catch (e) {
        setState(() {
          _error = 'Error unsubscribing: $e';
        });
      }
    }
  }

  void _sendMessage() {
    if (_messageController.text.trim().isEmpty) return;
    if (_channel == null || !_isSubscribed) {
      setState(() {
        _error = 'Please subscribe to a channel first';
      });
      return;
    }

    final message = _messageController.text.trim();
    final userId = _userIdController.text.trim();

    // Note: This is a demo. In production, you would send this through your backend
    // Here we're just adding it locally for demonstration
    setState(() {
      _messages.insert(0, ChatMessage(
        userId: userId,
        message: message,
        timestamp: DateTime.now(),
        isLocal: true,
      ));
    });

    _messageController.clear();

    // Stop typing indicator
    _typingTimer?.cancel();
  }

  void _onTyping() {
    if (_channel == null || !_isSubscribed) return;

    // Cancel previous timer
    _typingTimer?.cancel();

    // Send typing event (throttled to every 2 seconds)
    try {
      _channel!.whisper('client-typing', data: {
        'user_id': _userIdController.text.trim(),
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Error sending typing event: $e');
    }

    // Set new timer
    _typingTimer = Timer(const Duration(seconds: 2), () {
      // Timer expired, user stopped typing
    });
  }

  String _getTypingText() {
    if (_typingUsers.isEmpty) return '';

    final users = _typingUsers.keys.toList();
    if (users.length == 1) {
      return '${users[0]} is typing...';
    } else if (users.length == 2) {
      return '${users[0]} and ${users[1]} are typing...';
    } else {
      return '${users.length} people are typing...';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Client Events (Whisper)'),
        elevation: 0,
      ),
      body: Column(
        children: [
          // Header Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Colors.teal.withValues(alpha: 0.1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.teal,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.chat_bubble, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Client Events Demo',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Real-time typing indicators',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Info Card
          if (!_isSubscribed)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: theme.colorScheme.secondary, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'About Client Events',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '• Client events (whisper) allow direct client-to-client messaging\n'
                        '• Perfect for ephemeral events like typing indicators\n'
                        '• Only work on private and presence channels\n'
                        '• Event names must start with "client-"\n'
                        '• Messages don\'t go through your backend server',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Configuration Section
          if (!_isSubscribed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  TextField(
                    controller: _channelNameController,
                    decoration: const InputDecoration(
                      labelText: 'Channel Name',
                      hintText: 'presence-chat-demo',
                      prefixIcon: Icon(Icons.tag),
                      helperText: 'Must start with "presence-"',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _userIdController,
                    decoration: const InputDecoration(
                      labelText: 'Your User ID',
                      hintText: 'User123',
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _subscribe,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(_isLoading ? 'Connecting...' : 'Start Chat'),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Error Message
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Chat Area
          if (_isSubscribed) ...[
            // Messages List
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_outlined,
                            size: 64,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Start typing to send a message',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        final isMe = message.userId == _userIdController.text;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            mainAxisAlignment: isMe
                                ? MainAxisAlignment.end
                                : MainAxisAlignment.start,
                            children: [
                              Container(
                                constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? Colors.teal
                                      : theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!isMe)
                                      Text(
                                        message.userId,
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    Text(
                                      message.message,
                                      style: TextStyle(
                                        color: isMe ? Colors.white : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            // Typing Indicator
            if (_typingUsers.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _getTypingText(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),

            // Message Input
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      onChanged: (_) => _onTyping(),
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ChatMessage {
  final String userId;
  final String message;
  final DateTime timestamp;
  final bool isLocal;

  ChatMessage({
    required this.userId,
    required this.message,
    required this.timestamp,
    this.isLocal = false,
  });
}
