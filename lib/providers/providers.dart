import 'dart:async';

import 'package:nebulon/models/channel.dart';
import 'package:nebulon/models/guild.dart';
import 'package:nebulon/models/message.dart';
import 'package:nebulon/models/user.dart';
import 'package:nebulon/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

class ApiServiceNotifier extends StateNotifier<AsyncValue<ApiService>> {
  ApiServiceNotifier(this.ref) : super(AsyncValue.loading());

  final Ref ref;

  void initialize(String token) {
    try {
      final service = ApiService(ref: ref, token: token);
      state = AsyncValue.data(service);
      service.currentUserStream.listen((user) {
        ref.read(connectedUserProvider.notifier).state = user;
      });
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }
}

final apiServiceProvider =
    StateNotifierProvider<ApiServiceNotifier, AsyncValue<ApiService>>(
      (ref) => ApiServiceNotifier(ref),
    );

final messageEventStreamProvider = StreamProvider<MessageEvent>((ref) {
  return ref
      .watch(apiServiceProvider)
      .when(
        data: (apiService) => apiService.messageEventStream,
        loading: () => const Stream.empty(),
        error: (err, stack) => Stream.error(err, stack),
      );
});

final connectedUserProvider = StateProvider<UserModel?>((_) => null);

final privateChannelsProvider = StateProvider<List<ChannelModel>>((ref) => []);

final guildsProvider = StateProvider<List<GuildModel>>((ref) => []);

class SelectedGuildProvider extends StateNotifier<GuildModel?> {
  SelectedGuildProvider(this.ref) : super(null);

  final Ref ref;

  void set(GuildModel? newGuild) {
    state = newGuild;
    if (newGuild != null) {
      ref.read(apiServiceProvider).value?.subscribeToGuild(newGuild.id);
    }
  }
}

final selectedGuildProvider =
    StateNotifierProvider<SelectedGuildProvider, GuildModel?>(
      (ref) => SelectedGuildProvider(ref),
    );

class SelectedChannelProvider extends StateNotifier<ChannelModel?> {
  SelectedChannelProvider(this.ref) : super(null);

  final Ref ref;

  void set(ChannelModel? newChannel) {
    state = newChannel;
    if (newChannel != null) {
      ref.read(unreadChannelsProvider.notifier).markRead(newChannel.id.value);
    }
  }
}

final selectedChannelProvider =
    StateNotifierProvider<SelectedChannelProvider, ChannelModel?>(
      (ref) => SelectedChannelProvider(ref),
    );

class UnreadChannelsNotifier extends StateNotifier<Set<int>> {
  UnreadChannelsNotifier() : super({});

  void markUnread(int channelId) {
    if (!state.contains(channelId)) {
      state = {...state, channelId};
    }
  }

  void markRead(int channelId) {
    if (state.contains(channelId)) {
      final newState = Set<int>.from(state);
      newState.remove(channelId);
      state = newState;
    }
  }
}

final unreadChannelsProvider = StateNotifierProvider<UnreadChannelsNotifier, Set<int>>((ref) => UnreadChannelsNotifier());

final unreadGuildsProvider = Provider<Set<int>>((ref) {
  final unreadChannels = ref.watch(unreadChannelsProvider);
  
  final unreadGuilds = <int>{};
  for (final channelId in unreadChannels) {
    final channel = ChannelModel.getById(channelId);
    if (channel != null && channel.guildId != null) {
      unreadGuilds.add(channel.guildId!);
    }
  }
  return unreadGuilds;
});

final replyMessageProvider = StateProvider<MessageModel?>((ref) => null);
final editMessageProvider = StateProvider<MessageModel?>((ref) => null);
final pendingAttachmentsProvider = StateProvider<List<Uint8List>>((ref) => []);

final hasDrawerProvider = StateProvider<bool>((ref) => false);
final sidebarWidthProvider = StateProvider<double>((ref) => 320);
final sidebarCollapsedProvider = StateProvider<bool>((ref) => false);
final menuCollapsedProvider = Provider.autoDispose(
  (ref) => !ref.watch(hasDrawerProvider) && ref.watch(sidebarCollapsedProvider),
);
