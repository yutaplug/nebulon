import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:nebulon/models/base.dart';
import 'package:nebulon/models/channel.dart';
import 'package:nebulon/models/guild.dart';
import 'package:nebulon/models/message.dart';
import 'package:nebulon/models/user.dart';

import 'package:nebulon/providers/providers.dart';

import 'package:nebulon/services/gateway_channel.dart';
import 'package:nebulon/services/interceptors/authorization_interceptor.dart';
import 'package:nebulon/services/interceptors/ratelimit_interceptor.dart';


enum MessageEventType { create, update, delete }

class MessageEvent {
  final MessageEventType type;
  final Snowflake channelId;
  final Snowflake messageId;
  final MessageModel? message;

  MessageEvent({
    required this.type,
    required this.channelId,
    required this.messageId,
    this.message,
  });
}

class ChannelTypingEvent {
  final Snowflake userId;
  final Snowflake channelId;
  final Snowflake? guildId;
  final DateTime timestamp;

  ChannelTypingEvent({
    required this.userId,
    required this.channelId,
    this.guildId,
    required this.timestamp,
  });
}

// ignore: non_constant_identifier_names
final DiscordAPIOptions = BaseOptions(
  baseUrl: "https://discord.com/api/v10/",
  responseType: ResponseType.json,
  headers: {'Content-Type': 'application/json'},
);

class ApiService {
  // this class is really a mess

  ApiService._internal({required token}) : _token = token {
    _connectGateway();
  }

  static ApiService? _instance;
  late final Ref _ref;

  factory ApiService({String? token, Ref? ref}) {
    assert(
      token == null ? _instance != null : true,
      "Please provide a token to initialize the service.",
    );

    if (token != null) {
      _instance?.dispose();
      _instance = ApiService._internal(token: token);
    }
    if (ref != null) {
      _instance!._ref = ref;
    }

    return _instance!;
  }

  void dispose() {
    _gateway?.dispose();
    _dio.close();
    _messageEventController.close();
    _channelTypingController.close();
    _currentUserStreamController.close();
  }

  final String _token;

  GatewayChannel? _gateway;

  late final Dio _dio = () {
    final dio = Dio(DiscordAPIOptions);
    dio.interceptors.addAll([
      AuthorizationInterceptor(_token),
      RateLimitInterceptor(dio),
    ]);

    return dio;
  }();

  final _messageEventController = StreamController<MessageEvent>.broadcast();
  Stream<MessageEvent> get messageEventStream => _messageEventController.stream;

  final _channelTypingController =
      StreamController<ChannelTypingEvent>.broadcast();
  Stream<ChannelTypingEvent> get channelTypingStream =>
      _channelTypingController.stream;

  final _currentUserStreamController = StreamController<UserModel>.broadcast();
  Stream<UserModel> get currentUserStream =>
      _currentUserStreamController.stream;

  void _connectGateway() async {
    if (_token == "") return;

    _gateway = GatewayChannel(
      (await _dio.get<Map<String, dynamic>>("/gateway")).data!["url"],
      _token,
    );
    _gateway!.listen(_onGatewayEvent);
  }

  void _onGatewayEvent(DispatchEvent event) {
    final data = event.data;
    switch (event.type) {
      case "READY":
        _currentUserStreamController.add(UserModel.fromJson(data["user"]));
        _ref.read(guildsProvider.notifier).state =
            (data["guilds"] as List)
                .map((guild) => GuildModel.fromJson(guild, service: this))
                .toList();
        _ref.read(privateChannelsProvider.notifier).state =
            (data["private_channels"] as List)
                .map((channel) => ChannelModel.fromJson(channel, service: this))
                .toList();

        if (data["read_state"] != null) {
          final entries = data["read_state"] is List ? data["read_state"] : data["read_state"]["entries"];
          if (entries != null) {
            for (var entry in entries) {
            try {
              final channelId = Snowflake(entry["id"]);
              final lastRead = entry["last_message_id"] != null ? Snowflake(entry["last_message_id"]) : null;
              
              if (lastRead != null) {
                final channel = ChannelModel.getById(channelId.value);
                if (channel != null && channel.lastMessageId != null) {
                  if (channel.lastMessageId! > lastRead) {
                    _ref.read(unreadChannelsProvider.notifier).markUnread(channelId.value);
                  }
                }
              }
            } catch (_) {}
          }
          }
        }
        break;
      case "MESSAGE_CREATE":
        final channelId = Snowflake(data["channel_id"]);
        _messageEventController.add(
          MessageEvent(
            type: MessageEventType.create,
            messageId: Snowflake(data["id"]),
            channelId: channelId,
            message: MessageModel.fromJson(data),
          ),
        );
        final selectedChannel = _ref.read(selectedChannelProvider);
        if (selectedChannel?.id != channelId) {
          _ref.read(unreadChannelsProvider.notifier).markUnread(channelId.value);
        }
        break;
      case "MESSAGE_UPDATE":
        _messageEventController.add(
          MessageEvent(
            type: MessageEventType.update,
            messageId: Snowflake(data["id"]),
            channelId: Snowflake(data["channel_id"]),
            message: MessageModel.fromJson(data),
          ),
        );
        break;
      case "MESSAGE_DELETE":
        _messageEventController.add(
          MessageEvent(
            type: MessageEventType.delete,
            messageId: Snowflake(data["id"]),
            channelId: Snowflake(data["channel_id"]),
          ),
        );
        break;
      case "TYPING_START":
        _channelTypingController.add(
          ChannelTypingEvent(
            userId: Snowflake(data["user_id"]),
            channelId: Snowflake(data["channel_id"]),
            timestamp: DateTime.fromMicrosecondsSinceEpoch(data["timestamp"]),
          ),
        );
        break;
    }
  }

  Future<List<MessageModel>> getMessages({
    required Snowflake channelId,
    int? limit = 50,
    Snowflake? before,
  }) async {
    Map<String, dynamic> queryParameters = {};
    if (limit != null) queryParameters["limit"] = limit;
    if (before != null) queryParameters["before"] = before.value;
    final data =
        (await _dio.get(
          "/channels/$channelId/messages",
          queryParameters: queryParameters,
        )).data;
    return (data as List).map((d) => MessageModel.fromJson(d)).toList();
  }

  int _messageCount = 0;

  String getNextNonce() {
    final nonce =
        DateTime.now().millisecondsSinceEpoch.toString() +
        _messageCount.toString();
    _messageCount++;
    return nonce;
  }

  Future<MessageModel> sendMessage(
    Snowflake channelId,
    String content,
    String nonce, {
    Snowflake? replyToMessageId,
    List<MultipartFile>? files,
  }) async {
    dynamic data;
    if (files != null && files.isNotEmpty) {
      final payload = {
        "content": content,
        "nonce": nonce,
        if (replyToMessageId != null)
          "message_reference": {"message_id": replyToMessageId.value},
        "attachments": List.generate(files.length, (i) {
          final bytes = files[i].finalize();
          final dimensions = _getImageDimensions(bytes);
          return {
            "id": i,
            "filename": files[i].filename,
            "content_type": files[i].contentType?.mimeType ?? "application/octet-stream",
            "size": files[i].length,
            if (dimensions["width"]! > 0 && dimensions["height"]! > 0) ...{
              "width": dimensions["width"],
              "height": dimensions["height"],
            },
          };
        }),
      };

      final formData = FormData();
      
      formData.files.add(
        MapEntry(
          "payload_json",
          MultipartFile.fromString(
            jsonEncode(payload),
            contentType: MediaType("application", "json"),
          ),
        ),
      );

      for (int i = 0; i < files.length; i++) {
        formData.files.add(MapEntry("files[$i]", files[i]));
      }

      data = formData;
    } else {
      data = {
        "content": content,
        "nonce": nonce,
        if (replyToMessageId != null)
          "message_reference": {"message_id": replyToMessageId.value},
      };
    }

    final response = await _dio.post(
      "/channels/$channelId/messages",
      data: data,
    );
    final message = MessageModel.fromJson(response.data);
    message.nonce = nonce;
    return message;
  }

  Future<MessageModel> editMessage(
    Snowflake channelId,
    Snowflake messageId,
    String content,
  ) async {
    final response = await _dio.patch(
      "/channels/$channelId/messages/$messageId",
      data: {
        "content": content,
      },
    );
    return MessageModel.fromJson(response.data);
  }

  Future<UserModel> getUser(Snowflake id) async {
    return UserModel.fromJson((await _dio.get("/users/$id")).data);
  }

  Future<void> sendTyping(Snowflake channelId) async {
    await _dio.post("/channels/$channelId/typing");
  }

  Map<String, int> _getImageDimensions(Uint8List bytes) {
    if (bytes.length < 24) return {'width': 0, 'height': 0};
    
    // PNG dimensions: bytes 16-19 are width, 20-23 are height (big-endian)
    if (bytes.length >= 24 && 
        bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      return {'width': width, 'height': height};
    }
    
    // JPEG dimensions: need to find SOF marker (0xFF 0xC0)
    if (bytes.length >= 4 && 
        bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      int i = 2;
      while (i < bytes.length - 2) {
        if (bytes[i] == 0xFF) {
          final marker = bytes[i + 1];
          if (marker == 0xC0 || marker == 0xC2) {
            // SOF0 or SOF2 marker found
            if (i + 9 < bytes.length) {
              final height = (bytes[i + 5] << 8) | bytes[i + 6];
              final width = (bytes[i + 7] << 8) | bytes[i + 8];
              return {'width': width, 'height': height};
            }
          }
          // Skip to next marker
          if (i + 3 < bytes.length) {
            final length = (bytes[i + 2] << 8) | bytes[i + 3];
            i += length + 2;
          } else {
            break;
          }
        } else {
          i++;
        }
      }
    }
    
    // Default dimensions if detection fails
    return {'width': 0, 'height': 0};
  }

  void subscribeToGuild(
    Snowflake guildId, {
    bool typing = true,
    bool activities = true,
    bool threads = true,
  }) {
    _gateway?.send({
      "op": 14,
      "d": {
        "guild_id": guildId.value,
        "typing": typing,
        "activities": activities,
        "threads": threads,
      },
    });
  }
}
