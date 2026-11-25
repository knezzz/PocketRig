// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'chat_cache.dart';

// ignore_for_file: type=lint
class $ChatsTable extends Chats with TableInfo<$ChatsTable, ChatRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _hostIdMeta = const VerificationMeta('hostId');
  @override
  late final GeneratedColumn<String> hostId = GeneratedColumn<String>(
      'host_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _chatKeyMeta =
      const VerificationMeta('chatKey');
  @override
  late final GeneratedColumn<String> chatKey = GeneratedColumn<String>(
      'chat_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _logPathMeta =
      const VerificationMeta('logPath');
  @override
  late final GeneratedColumn<String> logPath = GeneratedColumn<String>(
      'log_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _logOffsetMeta =
      const VerificationMeta('logOffset');
  @override
  late final GeneratedColumn<int> logOffset = GeneratedColumn<int>(
      'log_offset', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _truncatedMeta =
      const VerificationMeta('truncated');
  @override
  late final GeneratedColumn<bool> truncated = GeneratedColumn<bool>(
      'truncated', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("truncated" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _openedAtMeta =
      const VerificationMeta('openedAt');
  @override
  late final GeneratedColumn<int> openedAt = GeneratedColumn<int>(
      'opened_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _seededMeta = const VerificationMeta('seeded');
  @override
  late final GeneratedColumn<bool> seeded = GeneratedColumn<bool>(
      'seeded', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("seeded" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns =>
      [id, hostId, chatKey, logPath, logOffset, truncated, openedAt, seeded];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chats';
  @override
  VerificationContext validateIntegrity(Insertable<ChatRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('host_id')) {
      context.handle(_hostIdMeta,
          hostId.isAcceptableOrUnknown(data['host_id']!, _hostIdMeta));
    } else if (isInserting) {
      context.missing(_hostIdMeta);
    }
    if (data.containsKey('chat_key')) {
      context.handle(_chatKeyMeta,
          chatKey.isAcceptableOrUnknown(data['chat_key']!, _chatKeyMeta));
    } else if (isInserting) {
      context.missing(_chatKeyMeta);
    }
    if (data.containsKey('log_path')) {
      context.handle(_logPathMeta,
          logPath.isAcceptableOrUnknown(data['log_path']!, _logPathMeta));
    } else if (isInserting) {
      context.missing(_logPathMeta);
    }
    if (data.containsKey('log_offset')) {
      context.handle(_logOffsetMeta,
          logOffset.isAcceptableOrUnknown(data['log_offset']!, _logOffsetMeta));
    }
    if (data.containsKey('truncated')) {
      context.handle(_truncatedMeta,
          truncated.isAcceptableOrUnknown(data['truncated']!, _truncatedMeta));
    }
    if (data.containsKey('opened_at')) {
      context.handle(_openedAtMeta,
          openedAt.isAcceptableOrUnknown(data['opened_at']!, _openedAtMeta));
    } else if (isInserting) {
      context.missing(_openedAtMeta);
    }
    if (data.containsKey('seeded')) {
      context.handle(_seededMeta,
          seeded.isAcceptableOrUnknown(data['seeded']!, _seededMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {hostId, chatKey},
      ];
  @override
  ChatRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      hostId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}host_id'])!,
      chatKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}chat_key'])!,
      logPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}log_path'])!,
      logOffset: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}log_offset'])!,
      truncated: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}truncated'])!,
      openedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}opened_at'])!,
      seeded: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}seeded'])!,
    );
  }

  @override
  $ChatsTable createAlias(String alias) {
    return $ChatsTable(attachedDatabase, alias);
  }
}

class ChatRow extends DataClass implements Insertable<ChatRow> {
  final int id;
  final String hostId;
  final String chatKey;
  final String logPath;

  /// The log byte after the last line read: where the tail resumes.
  final int logOffset;

  /// True when the start of the conversation isn't here.
  final bool truncated;

  /// 0 for a chat only background sync has pulled: evicted before opened ones.
  final int openedAt;

  /// Started from the last part of the log by background sync.
  final bool seeded;
  const ChatRow(
      {required this.id,
      required this.hostId,
      required this.chatKey,
      required this.logPath,
      required this.logOffset,
      required this.truncated,
      required this.openedAt,
      required this.seeded});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['host_id'] = Variable<String>(hostId);
    map['chat_key'] = Variable<String>(chatKey);
    map['log_path'] = Variable<String>(logPath);
    map['log_offset'] = Variable<int>(logOffset);
    map['truncated'] = Variable<bool>(truncated);
    map['opened_at'] = Variable<int>(openedAt);
    map['seeded'] = Variable<bool>(seeded);
    return map;
  }

  ChatsCompanion toCompanion(bool nullToAbsent) {
    return ChatsCompanion(
      id: Value(id),
      hostId: Value(hostId),
      chatKey: Value(chatKey),
      logPath: Value(logPath),
      logOffset: Value(logOffset),
      truncated: Value(truncated),
      openedAt: Value(openedAt),
      seeded: Value(seeded),
    );
  }

  factory ChatRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatRow(
      id: serializer.fromJson<int>(json['id']),
      hostId: serializer.fromJson<String>(json['hostId']),
      chatKey: serializer.fromJson<String>(json['chatKey']),
      logPath: serializer.fromJson<String>(json['logPath']),
      logOffset: serializer.fromJson<int>(json['logOffset']),
      truncated: serializer.fromJson<bool>(json['truncated']),
      openedAt: serializer.fromJson<int>(json['openedAt']),
      seeded: serializer.fromJson<bool>(json['seeded']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'hostId': serializer.toJson<String>(hostId),
      'chatKey': serializer.toJson<String>(chatKey),
      'logPath': serializer.toJson<String>(logPath),
      'logOffset': serializer.toJson<int>(logOffset),
      'truncated': serializer.toJson<bool>(truncated),
      'openedAt': serializer.toJson<int>(openedAt),
      'seeded': serializer.toJson<bool>(seeded),
    };
  }

  ChatRow copyWith(
          {int? id,
          String? hostId,
          String? chatKey,
          String? logPath,
          int? logOffset,
          bool? truncated,
          int? openedAt,
          bool? seeded}) =>
      ChatRow(
        id: id ?? this.id,
        hostId: hostId ?? this.hostId,
        chatKey: chatKey ?? this.chatKey,
        logPath: logPath ?? this.logPath,
        logOffset: logOffset ?? this.logOffset,
        truncated: truncated ?? this.truncated,
        openedAt: openedAt ?? this.openedAt,
        seeded: seeded ?? this.seeded,
      );
  ChatRow copyWithCompanion(ChatsCompanion data) {
    return ChatRow(
      id: data.id.present ? data.id.value : this.id,
      hostId: data.hostId.present ? data.hostId.value : this.hostId,
      chatKey: data.chatKey.present ? data.chatKey.value : this.chatKey,
      logPath: data.logPath.present ? data.logPath.value : this.logPath,
      logOffset: data.logOffset.present ? data.logOffset.value : this.logOffset,
      truncated: data.truncated.present ? data.truncated.value : this.truncated,
      openedAt: data.openedAt.present ? data.openedAt.value : this.openedAt,
      seeded: data.seeded.present ? data.seeded.value : this.seeded,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatRow(')
          ..write('id: $id, ')
          ..write('hostId: $hostId, ')
          ..write('chatKey: $chatKey, ')
          ..write('logPath: $logPath, ')
          ..write('logOffset: $logOffset, ')
          ..write('truncated: $truncated, ')
          ..write('openedAt: $openedAt, ')
          ..write('seeded: $seeded')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, hostId, chatKey, logPath, logOffset, truncated, openedAt, seeded);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatRow &&
          other.id == this.id &&
          other.hostId == this.hostId &&
          other.chatKey == this.chatKey &&
          other.logPath == this.logPath &&
          other.logOffset == this.logOffset &&
          other.truncated == this.truncated &&
          other.openedAt == this.openedAt &&
          other.seeded == this.seeded);
}

class ChatsCompanion extends UpdateCompanion<ChatRow> {
  final Value<int> id;
  final Value<String> hostId;
  final Value<String> chatKey;
  final Value<String> logPath;
  final Value<int> logOffset;
  final Value<bool> truncated;
  final Value<int> openedAt;
  final Value<bool> seeded;
  const ChatsCompanion({
    this.id = const Value.absent(),
    this.hostId = const Value.absent(),
    this.chatKey = const Value.absent(),
    this.logPath = const Value.absent(),
    this.logOffset = const Value.absent(),
    this.truncated = const Value.absent(),
    this.openedAt = const Value.absent(),
    this.seeded = const Value.absent(),
  });
  ChatsCompanion.insert({
    this.id = const Value.absent(),
    required String hostId,
    required String chatKey,
    required String logPath,
    this.logOffset = const Value.absent(),
    this.truncated = const Value.absent(),
    required int openedAt,
    this.seeded = const Value.absent(),
  })  : hostId = Value(hostId),
        chatKey = Value(chatKey),
        logPath = Value(logPath),
        openedAt = Value(openedAt);
  static Insertable<ChatRow> custom({
    Expression<int>? id,
    Expression<String>? hostId,
    Expression<String>? chatKey,
    Expression<String>? logPath,
    Expression<int>? logOffset,
    Expression<bool>? truncated,
    Expression<int>? openedAt,
    Expression<bool>? seeded,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (hostId != null) 'host_id': hostId,
      if (chatKey != null) 'chat_key': chatKey,
      if (logPath != null) 'log_path': logPath,
      if (logOffset != null) 'log_offset': logOffset,
      if (truncated != null) 'truncated': truncated,
      if (openedAt != null) 'opened_at': openedAt,
      if (seeded != null) 'seeded': seeded,
    });
  }

  ChatsCompanion copyWith(
      {Value<int>? id,
      Value<String>? hostId,
      Value<String>? chatKey,
      Value<String>? logPath,
      Value<int>? logOffset,
      Value<bool>? truncated,
      Value<int>? openedAt,
      Value<bool>? seeded}) {
    return ChatsCompanion(
      id: id ?? this.id,
      hostId: hostId ?? this.hostId,
      chatKey: chatKey ?? this.chatKey,
      logPath: logPath ?? this.logPath,
      logOffset: logOffset ?? this.logOffset,
      truncated: truncated ?? this.truncated,
      openedAt: openedAt ?? this.openedAt,
      seeded: seeded ?? this.seeded,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (hostId.present) {
      map['host_id'] = Variable<String>(hostId.value);
    }
    if (chatKey.present) {
      map['chat_key'] = Variable<String>(chatKey.value);
    }
    if (logPath.present) {
      map['log_path'] = Variable<String>(logPath.value);
    }
    if (logOffset.present) {
      map['log_offset'] = Variable<int>(logOffset.value);
    }
    if (truncated.present) {
      map['truncated'] = Variable<bool>(truncated.value);
    }
    if (openedAt.present) {
      map['opened_at'] = Variable<int>(openedAt.value);
    }
    if (seeded.present) {
      map['seeded'] = Variable<bool>(seeded.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatsCompanion(')
          ..write('id: $id, ')
          ..write('hostId: $hostId, ')
          ..write('chatKey: $chatKey, ')
          ..write('logPath: $logPath, ')
          ..write('logOffset: $logOffset, ')
          ..write('truncated: $truncated, ')
          ..write('openedAt: $openedAt, ')
          ..write('seeded: $seeded')
          ..write(')'))
        .toString();
  }
}

class $ChatLinesTable extends ChatLines
    with TableInfo<$ChatLinesTable, ChatLine> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatLinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<int> chatId = GeneratedColumn<int>(
      'chat_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _lineMeta = const VerificationMeta('line');
  @override
  late final GeneratedColumn<String> line = GeneratedColumn<String>(
      'line', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
      'size', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, chatId, line, size];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_lines';
  @override
  VerificationContext validateIntegrity(Insertable<ChatLine> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('chat_id')) {
      context.handle(_chatIdMeta,
          chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta));
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('line')) {
      context.handle(
          _lineMeta, line.isAcceptableOrUnknown(data['line']!, _lineMeta));
    } else if (isInserting) {
      context.missing(_lineMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChatLine map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatLine(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      chatId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}chat_id'])!,
      line: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}line'])!,
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
    );
  }

  @override
  $ChatLinesTable createAlias(String alias) {
    return $ChatLinesTable(attachedDatabase, alias);
  }
}

class ChatLine extends DataClass implements Insertable<ChatLine> {
  final int id;
  final int chatId;
  final String line;
  final int size;
  const ChatLine(
      {required this.id,
      required this.chatId,
      required this.line,
      required this.size});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['chat_id'] = Variable<int>(chatId);
    map['line'] = Variable<String>(line);
    map['size'] = Variable<int>(size);
    return map;
  }

  ChatLinesCompanion toCompanion(bool nullToAbsent) {
    return ChatLinesCompanion(
      id: Value(id),
      chatId: Value(chatId),
      line: Value(line),
      size: Value(size),
    );
  }

  factory ChatLine.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatLine(
      id: serializer.fromJson<int>(json['id']),
      chatId: serializer.fromJson<int>(json['chatId']),
      line: serializer.fromJson<String>(json['line']),
      size: serializer.fromJson<int>(json['size']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'chatId': serializer.toJson<int>(chatId),
      'line': serializer.toJson<String>(line),
      'size': serializer.toJson<int>(size),
    };
  }

  ChatLine copyWith({int? id, int? chatId, String? line, int? size}) =>
      ChatLine(
        id: id ?? this.id,
        chatId: chatId ?? this.chatId,
        line: line ?? this.line,
        size: size ?? this.size,
      );
  ChatLine copyWithCompanion(ChatLinesCompanion data) {
    return ChatLine(
      id: data.id.present ? data.id.value : this.id,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      line: data.line.present ? data.line.value : this.line,
      size: data.size.present ? data.size.value : this.size,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatLine(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('line: $line, ')
          ..write('size: $size')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, chatId, line, size);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatLine &&
          other.id == this.id &&
          other.chatId == this.chatId &&
          other.line == this.line &&
          other.size == this.size);
}

class ChatLinesCompanion extends UpdateCompanion<ChatLine> {
  final Value<int> id;
  final Value<int> chatId;
  final Value<String> line;
  final Value<int> size;
  const ChatLinesCompanion({
    this.id = const Value.absent(),
    this.chatId = const Value.absent(),
    this.line = const Value.absent(),
    this.size = const Value.absent(),
  });
  ChatLinesCompanion.insert({
    this.id = const Value.absent(),
    required int chatId,
    required String line,
    required int size,
  })  : chatId = Value(chatId),
        line = Value(line),
        size = Value(size);
  static Insertable<ChatLine> custom({
    Expression<int>? id,
    Expression<int>? chatId,
    Expression<String>? line,
    Expression<int>? size,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (chatId != null) 'chat_id': chatId,
      if (line != null) 'line': line,
      if (size != null) 'size': size,
    });
  }

  ChatLinesCompanion copyWith(
      {Value<int>? id,
      Value<int>? chatId,
      Value<String>? line,
      Value<int>? size}) {
    return ChatLinesCompanion(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      line: line ?? this.line,
      size: size ?? this.size,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (chatId.present) {
      map['chat_id'] = Variable<int>(chatId.value);
    }
    if (line.present) {
      map['line'] = Variable<String>(line.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatLinesCompanion(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('line: $line, ')
          ..write('size: $size')
          ..write(')'))
        .toString();
  }
}

class $ChatMediaTable extends ChatMedia
    with TableInfo<$ChatMediaTable, ChatMediaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMediaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _chatIdMeta = const VerificationMeta('chatId');
  @override
  late final GeneratedColumn<int> chatId = GeneratedColumn<int>(
      'chat_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _refMeta = const VerificationMeta('ref');
  @override
  late final GeneratedColumn<String> ref = GeneratedColumn<String>(
      'ref', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _toolIdMeta = const VerificationMeta('toolId');
  @override
  late final GeneratedColumn<String> toolId = GeneratedColumn<String>(
      'tool_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _touchedAtMeta =
      const VerificationMeta('touchedAt');
  @override
  late final GeneratedColumn<int> touchedAt = GeneratedColumn<int>(
      'touched_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, chatId, kind, ref, name, toolId, touchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_media';
  @override
  VerificationContext validateIntegrity(Insertable<ChatMediaData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('chat_id')) {
      context.handle(_chatIdMeta,
          chatId.isAcceptableOrUnknown(data['chat_id']!, _chatIdMeta));
    } else if (isInserting) {
      context.missing(_chatIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('ref')) {
      context.handle(
          _refMeta, ref.isAcceptableOrUnknown(data['ref']!, _refMeta));
    } else if (isInserting) {
      context.missing(_refMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('tool_id')) {
      context.handle(_toolIdMeta,
          toolId.isAcceptableOrUnknown(data['tool_id']!, _toolIdMeta));
    }
    if (data.containsKey('touched_at')) {
      context.handle(_touchedAtMeta,
          touchedAt.isAcceptableOrUnknown(data['touched_at']!, _touchedAtMeta));
    } else if (isInserting) {
      context.missing(_touchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {chatId, kind, ref},
      ];
  @override
  ChatMediaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMediaData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      chatId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}chat_id'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      ref: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}ref'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name']),
      toolId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tool_id']),
      touchedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}touched_at'])!,
    );
  }

  @override
  $ChatMediaTable createAlias(String alias) {
    return $ChatMediaTable(attachedDatabase, alias);
  }
}

class ChatMediaData extends DataClass implements Insertable<ChatMediaData> {
  final int id;
  final int chatId;

  /// `image | video | file | artifact`.
  final String kind;

  /// The host path, or an artifact's claude.ai URL ('pending:<toolId>' until it is known).
  final String ref;
  final String? name;
  final String? toolId;

  /// The newest log line that mentioned it, in ms since epoch.
  final int touchedAt;
  const ChatMediaData(
      {required this.id,
      required this.chatId,
      required this.kind,
      required this.ref,
      this.name,
      this.toolId,
      required this.touchedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['chat_id'] = Variable<int>(chatId);
    map['kind'] = Variable<String>(kind);
    map['ref'] = Variable<String>(ref);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    if (!nullToAbsent || toolId != null) {
      map['tool_id'] = Variable<String>(toolId);
    }
    map['touched_at'] = Variable<int>(touchedAt);
    return map;
  }

  ChatMediaCompanion toCompanion(bool nullToAbsent) {
    return ChatMediaCompanion(
      id: Value(id),
      chatId: Value(chatId),
      kind: Value(kind),
      ref: Value(ref),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      toolId:
          toolId == null && nullToAbsent ? const Value.absent() : Value(toolId),
      touchedAt: Value(touchedAt),
    );
  }

  factory ChatMediaData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMediaData(
      id: serializer.fromJson<int>(json['id']),
      chatId: serializer.fromJson<int>(json['chatId']),
      kind: serializer.fromJson<String>(json['kind']),
      ref: serializer.fromJson<String>(json['ref']),
      name: serializer.fromJson<String?>(json['name']),
      toolId: serializer.fromJson<String?>(json['toolId']),
      touchedAt: serializer.fromJson<int>(json['touchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'chatId': serializer.toJson<int>(chatId),
      'kind': serializer.toJson<String>(kind),
      'ref': serializer.toJson<String>(ref),
      'name': serializer.toJson<String?>(name),
      'toolId': serializer.toJson<String?>(toolId),
      'touchedAt': serializer.toJson<int>(touchedAt),
    };
  }

  ChatMediaData copyWith(
          {int? id,
          int? chatId,
          String? kind,
          String? ref,
          Value<String?> name = const Value.absent(),
          Value<String?> toolId = const Value.absent(),
          int? touchedAt}) =>
      ChatMediaData(
        id: id ?? this.id,
        chatId: chatId ?? this.chatId,
        kind: kind ?? this.kind,
        ref: ref ?? this.ref,
        name: name.present ? name.value : this.name,
        toolId: toolId.present ? toolId.value : this.toolId,
        touchedAt: touchedAt ?? this.touchedAt,
      );
  ChatMediaData copyWithCompanion(ChatMediaCompanion data) {
    return ChatMediaData(
      id: data.id.present ? data.id.value : this.id,
      chatId: data.chatId.present ? data.chatId.value : this.chatId,
      kind: data.kind.present ? data.kind.value : this.kind,
      ref: data.ref.present ? data.ref.value : this.ref,
      name: data.name.present ? data.name.value : this.name,
      toolId: data.toolId.present ? data.toolId.value : this.toolId,
      touchedAt: data.touchedAt.present ? data.touchedAt.value : this.touchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMediaData(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('kind: $kind, ')
          ..write('ref: $ref, ')
          ..write('name: $name, ')
          ..write('toolId: $toolId, ')
          ..write('touchedAt: $touchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, chatId, kind, ref, name, toolId, touchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMediaData &&
          other.id == this.id &&
          other.chatId == this.chatId &&
          other.kind == this.kind &&
          other.ref == this.ref &&
          other.name == this.name &&
          other.toolId == this.toolId &&
          other.touchedAt == this.touchedAt);
}

class ChatMediaCompanion extends UpdateCompanion<ChatMediaData> {
  final Value<int> id;
  final Value<int> chatId;
  final Value<String> kind;
  final Value<String> ref;
  final Value<String?> name;
  final Value<String?> toolId;
  final Value<int> touchedAt;
  const ChatMediaCompanion({
    this.id = const Value.absent(),
    this.chatId = const Value.absent(),
    this.kind = const Value.absent(),
    this.ref = const Value.absent(),
    this.name = const Value.absent(),
    this.toolId = const Value.absent(),
    this.touchedAt = const Value.absent(),
  });
  ChatMediaCompanion.insert({
    this.id = const Value.absent(),
    required int chatId,
    required String kind,
    required String ref,
    this.name = const Value.absent(),
    this.toolId = const Value.absent(),
    required int touchedAt,
  })  : chatId = Value(chatId),
        kind = Value(kind),
        ref = Value(ref),
        touchedAt = Value(touchedAt);
  static Insertable<ChatMediaData> custom({
    Expression<int>? id,
    Expression<int>? chatId,
    Expression<String>? kind,
    Expression<String>? ref,
    Expression<String>? name,
    Expression<String>? toolId,
    Expression<int>? touchedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (chatId != null) 'chat_id': chatId,
      if (kind != null) 'kind': kind,
      if (ref != null) 'ref': ref,
      if (name != null) 'name': name,
      if (toolId != null) 'tool_id': toolId,
      if (touchedAt != null) 'touched_at': touchedAt,
    });
  }

  ChatMediaCompanion copyWith(
      {Value<int>? id,
      Value<int>? chatId,
      Value<String>? kind,
      Value<String>? ref,
      Value<String?>? name,
      Value<String?>? toolId,
      Value<int>? touchedAt}) {
    return ChatMediaCompanion(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      kind: kind ?? this.kind,
      ref: ref ?? this.ref,
      name: name ?? this.name,
      toolId: toolId ?? this.toolId,
      touchedAt: touchedAt ?? this.touchedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (chatId.present) {
      map['chat_id'] = Variable<int>(chatId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (ref.present) {
      map['ref'] = Variable<String>(ref.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (toolId.present) {
      map['tool_id'] = Variable<String>(toolId.value);
    }
    if (touchedAt.present) {
      map['touched_at'] = Variable<int>(touchedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMediaCompanion(')
          ..write('id: $id, ')
          ..write('chatId: $chatId, ')
          ..write('kind: $kind, ')
          ..write('ref: $ref, ')
          ..write('name: $name, ')
          ..write('toolId: $toolId, ')
          ..write('touchedAt: $touchedAt')
          ..write(')'))
        .toString();
  }
}

class $MediaFilesTable extends MediaFiles
    with TableInfo<$MediaFilesTable, MediaFile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaFilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _hostIdMeta = const VerificationMeta('hostId');
  @override
  late final GeneratedColumn<String> hostId = GeneratedColumn<String>(
      'host_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
      'size', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _fetchedAtMeta =
      const VerificationMeta('fetchedAt');
  @override
  late final GeneratedColumn<int> fetchedAt = GeneratedColumn<int>(
      'fetched_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _openedAtMeta =
      const VerificationMeta('openedAt');
  @override
  late final GeneratedColumn<int> openedAt = GeneratedColumn<int>(
      'opened_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, hostId, path, size, fetchedAt, openedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_files';
  @override
  VerificationContext validateIntegrity(Insertable<MediaFile> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('host_id')) {
      context.handle(_hostIdMeta,
          hostId.isAcceptableOrUnknown(data['host_id']!, _hostIdMeta));
    } else if (isInserting) {
      context.missing(_hostIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(_fetchedAtMeta,
          fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta));
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    if (data.containsKey('opened_at')) {
      context.handle(_openedAtMeta,
          openedAt.isAcceptableOrUnknown(data['opened_at']!, _openedAtMeta));
    } else if (isInserting) {
      context.missing(_openedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {hostId, path},
      ];
  @override
  MediaFile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaFile(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      hostId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}host_id'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
      fetchedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}fetched_at'])!,
      openedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}opened_at'])!,
    );
  }

  @override
  $MediaFilesTable createAlias(String alias) {
    return $MediaFilesTable(attachedDatabase, alias);
  }
}

class MediaFile extends DataClass implements Insertable<MediaFile> {
  final int id;
  final String hostId;
  final String path;
  final int size;
  final int fetchedAt;
  final int openedAt;
  const MediaFile(
      {required this.id,
      required this.hostId,
      required this.path,
      required this.size,
      required this.fetchedAt,
      required this.openedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['host_id'] = Variable<String>(hostId);
    map['path'] = Variable<String>(path);
    map['size'] = Variable<int>(size);
    map['fetched_at'] = Variable<int>(fetchedAt);
    map['opened_at'] = Variable<int>(openedAt);
    return map;
  }

  MediaFilesCompanion toCompanion(bool nullToAbsent) {
    return MediaFilesCompanion(
      id: Value(id),
      hostId: Value(hostId),
      path: Value(path),
      size: Value(size),
      fetchedAt: Value(fetchedAt),
      openedAt: Value(openedAt),
    );
  }

  factory MediaFile.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaFile(
      id: serializer.fromJson<int>(json['id']),
      hostId: serializer.fromJson<String>(json['hostId']),
      path: serializer.fromJson<String>(json['path']),
      size: serializer.fromJson<int>(json['size']),
      fetchedAt: serializer.fromJson<int>(json['fetchedAt']),
      openedAt: serializer.fromJson<int>(json['openedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'hostId': serializer.toJson<String>(hostId),
      'path': serializer.toJson<String>(path),
      'size': serializer.toJson<int>(size),
      'fetchedAt': serializer.toJson<int>(fetchedAt),
      'openedAt': serializer.toJson<int>(openedAt),
    };
  }

  MediaFile copyWith(
          {int? id,
          String? hostId,
          String? path,
          int? size,
          int? fetchedAt,
          int? openedAt}) =>
      MediaFile(
        id: id ?? this.id,
        hostId: hostId ?? this.hostId,
        path: path ?? this.path,
        size: size ?? this.size,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        openedAt: openedAt ?? this.openedAt,
      );
  MediaFile copyWithCompanion(MediaFilesCompanion data) {
    return MediaFile(
      id: data.id.present ? data.id.value : this.id,
      hostId: data.hostId.present ? data.hostId.value : this.hostId,
      path: data.path.present ? data.path.value : this.path,
      size: data.size.present ? data.size.value : this.size,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
      openedAt: data.openedAt.present ? data.openedAt.value : this.openedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaFile(')
          ..write('id: $id, ')
          ..write('hostId: $hostId, ')
          ..write('path: $path, ')
          ..write('size: $size, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('openedAt: $openedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, hostId, path, size, fetchedAt, openedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaFile &&
          other.id == this.id &&
          other.hostId == this.hostId &&
          other.path == this.path &&
          other.size == this.size &&
          other.fetchedAt == this.fetchedAt &&
          other.openedAt == this.openedAt);
}

class MediaFilesCompanion extends UpdateCompanion<MediaFile> {
  final Value<int> id;
  final Value<String> hostId;
  final Value<String> path;
  final Value<int> size;
  final Value<int> fetchedAt;
  final Value<int> openedAt;
  const MediaFilesCompanion({
    this.id = const Value.absent(),
    this.hostId = const Value.absent(),
    this.path = const Value.absent(),
    this.size = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.openedAt = const Value.absent(),
  });
  MediaFilesCompanion.insert({
    this.id = const Value.absent(),
    required String hostId,
    required String path,
    required int size,
    required int fetchedAt,
    required int openedAt,
  })  : hostId = Value(hostId),
        path = Value(path),
        size = Value(size),
        fetchedAt = Value(fetchedAt),
        openedAt = Value(openedAt);
  static Insertable<MediaFile> custom({
    Expression<int>? id,
    Expression<String>? hostId,
    Expression<String>? path,
    Expression<int>? size,
    Expression<int>? fetchedAt,
    Expression<int>? openedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (hostId != null) 'host_id': hostId,
      if (path != null) 'path': path,
      if (size != null) 'size': size,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (openedAt != null) 'opened_at': openedAt,
    });
  }

  MediaFilesCompanion copyWith(
      {Value<int>? id,
      Value<String>? hostId,
      Value<String>? path,
      Value<int>? size,
      Value<int>? fetchedAt,
      Value<int>? openedAt}) {
    return MediaFilesCompanion(
      id: id ?? this.id,
      hostId: hostId ?? this.hostId,
      path: path ?? this.path,
      size: size ?? this.size,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      openedAt: openedAt ?? this.openedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (hostId.present) {
      map['host_id'] = Variable<String>(hostId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<int>(fetchedAt.value);
    }
    if (openedAt.present) {
      map['opened_at'] = Variable<int>(openedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaFilesCompanion(')
          ..write('id: $id, ')
          ..write('hostId: $hostId, ')
          ..write('path: $path, ')
          ..write('size: $size, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('openedAt: $openedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$ChatCache extends GeneratedDatabase {
  _$ChatCache(QueryExecutor e) : super(e);
  $ChatCacheManager get managers => $ChatCacheManager(this);
  late final $ChatsTable chats = $ChatsTable(this);
  late final $ChatLinesTable chatLines = $ChatLinesTable(this);
  late final $ChatMediaTable chatMedia = $ChatMediaTable(this);
  late final $MediaFilesTable mediaFiles = $MediaFilesTable(this);
  late final Index chatLinesChat = Index('chat_lines_chat',
      'CREATE INDEX chat_lines_chat ON chat_lines (chat_id)');
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [chats, chatLines, chatMedia, mediaFiles, chatLinesChat];
}

typedef $$ChatsTableCreateCompanionBuilder = ChatsCompanion Function({
  Value<int> id,
  required String hostId,
  required String chatKey,
  required String logPath,
  Value<int> logOffset,
  Value<bool> truncated,
  required int openedAt,
  Value<bool> seeded,
});
typedef $$ChatsTableUpdateCompanionBuilder = ChatsCompanion Function({
  Value<int> id,
  Value<String> hostId,
  Value<String> chatKey,
  Value<String> logPath,
  Value<int> logOffset,
  Value<bool> truncated,
  Value<int> openedAt,
  Value<bool> seeded,
});

class $$ChatsTableFilterComposer extends Composer<_$ChatCache, $ChatsTable> {
  $$ChatsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get hostId => $composableBuilder(
      column: $table.hostId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get chatKey => $composableBuilder(
      column: $table.chatKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get logPath => $composableBuilder(
      column: $table.logPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get logOffset => $composableBuilder(
      column: $table.logOffset, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get truncated => $composableBuilder(
      column: $table.truncated, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get openedAt => $composableBuilder(
      column: $table.openedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get seeded => $composableBuilder(
      column: $table.seeded, builder: (column) => ColumnFilters(column));
}

class $$ChatsTableOrderingComposer extends Composer<_$ChatCache, $ChatsTable> {
  $$ChatsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get hostId => $composableBuilder(
      column: $table.hostId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get chatKey => $composableBuilder(
      column: $table.chatKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get logPath => $composableBuilder(
      column: $table.logPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get logOffset => $composableBuilder(
      column: $table.logOffset, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get truncated => $composableBuilder(
      column: $table.truncated, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get openedAt => $composableBuilder(
      column: $table.openedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get seeded => $composableBuilder(
      column: $table.seeded, builder: (column) => ColumnOrderings(column));
}

class $$ChatsTableAnnotationComposer
    extends Composer<_$ChatCache, $ChatsTable> {
  $$ChatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get hostId =>
      $composableBuilder(column: $table.hostId, builder: (column) => column);

  GeneratedColumn<String> get chatKey =>
      $composableBuilder(column: $table.chatKey, builder: (column) => column);

  GeneratedColumn<String> get logPath =>
      $composableBuilder(column: $table.logPath, builder: (column) => column);

  GeneratedColumn<int> get logOffset =>
      $composableBuilder(column: $table.logOffset, builder: (column) => column);

  GeneratedColumn<bool> get truncated =>
      $composableBuilder(column: $table.truncated, builder: (column) => column);

  GeneratedColumn<int> get openedAt =>
      $composableBuilder(column: $table.openedAt, builder: (column) => column);

  GeneratedColumn<bool> get seeded =>
      $composableBuilder(column: $table.seeded, builder: (column) => column);
}

class $$ChatsTableTableManager extends RootTableManager<
    _$ChatCache,
    $ChatsTable,
    ChatRow,
    $$ChatsTableFilterComposer,
    $$ChatsTableOrderingComposer,
    $$ChatsTableAnnotationComposer,
    $$ChatsTableCreateCompanionBuilder,
    $$ChatsTableUpdateCompanionBuilder,
    (ChatRow, BaseReferences<_$ChatCache, $ChatsTable, ChatRow>),
    ChatRow,
    PrefetchHooks Function()> {
  $$ChatsTableTableManager(_$ChatCache db, $ChatsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> hostId = const Value.absent(),
            Value<String> chatKey = const Value.absent(),
            Value<String> logPath = const Value.absent(),
            Value<int> logOffset = const Value.absent(),
            Value<bool> truncated = const Value.absent(),
            Value<int> openedAt = const Value.absent(),
            Value<bool> seeded = const Value.absent(),
          }) =>
              ChatsCompanion(
            id: id,
            hostId: hostId,
            chatKey: chatKey,
            logPath: logPath,
            logOffset: logOffset,
            truncated: truncated,
            openedAt: openedAt,
            seeded: seeded,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String hostId,
            required String chatKey,
            required String logPath,
            Value<int> logOffset = const Value.absent(),
            Value<bool> truncated = const Value.absent(),
            required int openedAt,
            Value<bool> seeded = const Value.absent(),
          }) =>
              ChatsCompanion.insert(
            id: id,
            hostId: hostId,
            chatKey: chatKey,
            logPath: logPath,
            logOffset: logOffset,
            truncated: truncated,
            openedAt: openedAt,
            seeded: seeded,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ChatsTable, ChatRow>(table),
                    BaseReferences<_$ChatCache, $ChatsTable, ChatRow>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatsTableProcessedTableManager = ProcessedTableManager<
    _$ChatCache,
    $ChatsTable,
    ChatRow,
    $$ChatsTableFilterComposer,
    $$ChatsTableOrderingComposer,
    $$ChatsTableAnnotationComposer,
    $$ChatsTableCreateCompanionBuilder,
    $$ChatsTableUpdateCompanionBuilder,
    (ChatRow, BaseReferences<_$ChatCache, $ChatsTable, ChatRow>),
    ChatRow,
    PrefetchHooks Function()>;
typedef $$ChatLinesTableCreateCompanionBuilder = ChatLinesCompanion Function({
  Value<int> id,
  required int chatId,
  required String line,
  required int size,
});
typedef $$ChatLinesTableUpdateCompanionBuilder = ChatLinesCompanion Function({
  Value<int> id,
  Value<int> chatId,
  Value<String> line,
  Value<int> size,
});

class $$ChatLinesTableFilterComposer
    extends Composer<_$ChatCache, $ChatLinesTable> {
  $$ChatLinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get chatId => $composableBuilder(
      column: $table.chatId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get line => $composableBuilder(
      column: $table.line, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnFilters(column));
}

class $$ChatLinesTableOrderingComposer
    extends Composer<_$ChatCache, $ChatLinesTable> {
  $$ChatLinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get chatId => $composableBuilder(
      column: $table.chatId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get line => $composableBuilder(
      column: $table.line, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnOrderings(column));
}

class $$ChatLinesTableAnnotationComposer
    extends Composer<_$ChatCache, $ChatLinesTable> {
  $$ChatLinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<String> get line =>
      $composableBuilder(column: $table.line, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);
}

class $$ChatLinesTableTableManager extends RootTableManager<
    _$ChatCache,
    $ChatLinesTable,
    ChatLine,
    $$ChatLinesTableFilterComposer,
    $$ChatLinesTableOrderingComposer,
    $$ChatLinesTableAnnotationComposer,
    $$ChatLinesTableCreateCompanionBuilder,
    $$ChatLinesTableUpdateCompanionBuilder,
    (ChatLine, BaseReferences<_$ChatCache, $ChatLinesTable, ChatLine>),
    ChatLine,
    PrefetchHooks Function()> {
  $$ChatLinesTableTableManager(_$ChatCache db, $ChatLinesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatLinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatLinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatLinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> chatId = const Value.absent(),
            Value<String> line = const Value.absent(),
            Value<int> size = const Value.absent(),
          }) =>
              ChatLinesCompanion(
            id: id,
            chatId: chatId,
            line: line,
            size: size,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int chatId,
            required String line,
            required int size,
          }) =>
              ChatLinesCompanion.insert(
            id: id,
            chatId: chatId,
            line: line,
            size: size,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ChatLinesTable, ChatLine>(table),
                    BaseReferences<_$ChatCache, $ChatLinesTable, ChatLine>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatLinesTableProcessedTableManager = ProcessedTableManager<
    _$ChatCache,
    $ChatLinesTable,
    ChatLine,
    $$ChatLinesTableFilterComposer,
    $$ChatLinesTableOrderingComposer,
    $$ChatLinesTableAnnotationComposer,
    $$ChatLinesTableCreateCompanionBuilder,
    $$ChatLinesTableUpdateCompanionBuilder,
    (ChatLine, BaseReferences<_$ChatCache, $ChatLinesTable, ChatLine>),
    ChatLine,
    PrefetchHooks Function()>;
typedef $$ChatMediaTableCreateCompanionBuilder = ChatMediaCompanion Function({
  Value<int> id,
  required int chatId,
  required String kind,
  required String ref,
  Value<String?> name,
  Value<String?> toolId,
  required int touchedAt,
});
typedef $$ChatMediaTableUpdateCompanionBuilder = ChatMediaCompanion Function({
  Value<int> id,
  Value<int> chatId,
  Value<String> kind,
  Value<String> ref,
  Value<String?> name,
  Value<String?> toolId,
  Value<int> touchedAt,
});

class $$ChatMediaTableFilterComposer
    extends Composer<_$ChatCache, $ChatMediaTable> {
  $$ChatMediaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get chatId => $composableBuilder(
      column: $table.chatId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ref => $composableBuilder(
      column: $table.ref, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get toolId => $composableBuilder(
      column: $table.toolId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get touchedAt => $composableBuilder(
      column: $table.touchedAt, builder: (column) => ColumnFilters(column));
}

class $$ChatMediaTableOrderingComposer
    extends Composer<_$ChatCache, $ChatMediaTable> {
  $$ChatMediaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get chatId => $composableBuilder(
      column: $table.chatId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ref => $composableBuilder(
      column: $table.ref, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get toolId => $composableBuilder(
      column: $table.toolId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get touchedAt => $composableBuilder(
      column: $table.touchedAt, builder: (column) => ColumnOrderings(column));
}

class $$ChatMediaTableAnnotationComposer
    extends Composer<_$ChatCache, $ChatMediaTable> {
  $$ChatMediaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get chatId =>
      $composableBuilder(column: $table.chatId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get ref =>
      $composableBuilder(column: $table.ref, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get toolId =>
      $composableBuilder(column: $table.toolId, builder: (column) => column);

  GeneratedColumn<int> get touchedAt =>
      $composableBuilder(column: $table.touchedAt, builder: (column) => column);
}

class $$ChatMediaTableTableManager extends RootTableManager<
    _$ChatCache,
    $ChatMediaTable,
    ChatMediaData,
    $$ChatMediaTableFilterComposer,
    $$ChatMediaTableOrderingComposer,
    $$ChatMediaTableAnnotationComposer,
    $$ChatMediaTableCreateCompanionBuilder,
    $$ChatMediaTableUpdateCompanionBuilder,
    (
      ChatMediaData,
      BaseReferences<_$ChatCache, $ChatMediaTable, ChatMediaData>
    ),
    ChatMediaData,
    PrefetchHooks Function()> {
  $$ChatMediaTableTableManager(_$ChatCache db, $ChatMediaTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMediaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMediaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMediaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<int> chatId = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String> ref = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<String?> toolId = const Value.absent(),
            Value<int> touchedAt = const Value.absent(),
          }) =>
              ChatMediaCompanion(
            id: id,
            chatId: chatId,
            kind: kind,
            ref: ref,
            name: name,
            toolId: toolId,
            touchedAt: touchedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required int chatId,
            required String kind,
            required String ref,
            Value<String?> name = const Value.absent(),
            Value<String?> toolId = const Value.absent(),
            required int touchedAt,
          }) =>
              ChatMediaCompanion.insert(
            id: id,
            chatId: chatId,
            kind: kind,
            ref: ref,
            name: name,
            toolId: toolId,
            touchedAt: touchedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$ChatMediaTable, ChatMediaData>(table),
                    BaseReferences<_$ChatCache, $ChatMediaTable, ChatMediaData>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatMediaTableProcessedTableManager = ProcessedTableManager<
    _$ChatCache,
    $ChatMediaTable,
    ChatMediaData,
    $$ChatMediaTableFilterComposer,
    $$ChatMediaTableOrderingComposer,
    $$ChatMediaTableAnnotationComposer,
    $$ChatMediaTableCreateCompanionBuilder,
    $$ChatMediaTableUpdateCompanionBuilder,
    (
      ChatMediaData,
      BaseReferences<_$ChatCache, $ChatMediaTable, ChatMediaData>
    ),
    ChatMediaData,
    PrefetchHooks Function()>;
typedef $$MediaFilesTableCreateCompanionBuilder = MediaFilesCompanion Function({
  Value<int> id,
  required String hostId,
  required String path,
  required int size,
  required int fetchedAt,
  required int openedAt,
});
typedef $$MediaFilesTableUpdateCompanionBuilder = MediaFilesCompanion Function({
  Value<int> id,
  Value<String> hostId,
  Value<String> path,
  Value<int> size,
  Value<int> fetchedAt,
  Value<int> openedAt,
});

class $$MediaFilesTableFilterComposer
    extends Composer<_$ChatCache, $MediaFilesTable> {
  $$MediaFilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get hostId => $composableBuilder(
      column: $table.hostId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get openedAt => $composableBuilder(
      column: $table.openedAt, builder: (column) => ColumnFilters(column));
}

class $$MediaFilesTableOrderingComposer
    extends Composer<_$ChatCache, $MediaFilesTable> {
  $$MediaFilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get hostId => $composableBuilder(
      column: $table.hostId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get openedAt => $composableBuilder(
      column: $table.openedAt, builder: (column) => ColumnOrderings(column));
}

class $$MediaFilesTableAnnotationComposer
    extends Composer<_$ChatCache, $MediaFilesTable> {
  $$MediaFilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get hostId =>
      $composableBuilder(column: $table.hostId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<int> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);

  GeneratedColumn<int> get openedAt =>
      $composableBuilder(column: $table.openedAt, builder: (column) => column);
}

class $$MediaFilesTableTableManager extends RootTableManager<
    _$ChatCache,
    $MediaFilesTable,
    MediaFile,
    $$MediaFilesTableFilterComposer,
    $$MediaFilesTableOrderingComposer,
    $$MediaFilesTableAnnotationComposer,
    $$MediaFilesTableCreateCompanionBuilder,
    $$MediaFilesTableUpdateCompanionBuilder,
    (MediaFile, BaseReferences<_$ChatCache, $MediaFilesTable, MediaFile>),
    MediaFile,
    PrefetchHooks Function()> {
  $$MediaFilesTableTableManager(_$ChatCache db, $MediaFilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaFilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaFilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaFilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> hostId = const Value.absent(),
            Value<String> path = const Value.absent(),
            Value<int> size = const Value.absent(),
            Value<int> fetchedAt = const Value.absent(),
            Value<int> openedAt = const Value.absent(),
          }) =>
              MediaFilesCompanion(
            id: id,
            hostId: hostId,
            path: path,
            size: size,
            fetchedAt: fetchedAt,
            openedAt: openedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String hostId,
            required String path,
            required int size,
            required int fetchedAt,
            required int openedAt,
          }) =>
              MediaFilesCompanion.insert(
            id: id,
            hostId: hostId,
            path: path,
            size: size,
            fetchedAt: fetchedAt,
            openedAt: openedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable<$MediaFilesTable, MediaFile>(table),
                    BaseReferences<_$ChatCache, $MediaFilesTable, MediaFile>(
                        db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MediaFilesTableProcessedTableManager = ProcessedTableManager<
    _$ChatCache,
    $MediaFilesTable,
    MediaFile,
    $$MediaFilesTableFilterComposer,
    $$MediaFilesTableOrderingComposer,
    $$MediaFilesTableAnnotationComposer,
    $$MediaFilesTableCreateCompanionBuilder,
    $$MediaFilesTableUpdateCompanionBuilder,
    (MediaFile, BaseReferences<_$ChatCache, $MediaFilesTable, MediaFile>),
    MediaFile,
    PrefetchHooks Function()>;

class $ChatCacheManager {
  final _$ChatCache _db;
  $ChatCacheManager(this._db);
  $$ChatsTableTableManager get chats =>
      $$ChatsTableTableManager(_db, _db.chats);
  $$ChatLinesTableTableManager get chatLines =>
      $$ChatLinesTableTableManager(_db, _db.chatLines);
  $$ChatMediaTableTableManager get chatMedia =>
      $$ChatMediaTableTableManager(_db, _db.chatMedia);
  $$MediaFilesTableTableManager get mediaFiles =>
      $$MediaFilesTableTableManager(_db, _db.mediaFiles);
}
