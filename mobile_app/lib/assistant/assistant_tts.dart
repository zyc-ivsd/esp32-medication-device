import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// 朗读回答的抽象，便于测试注入假实现（平台通道在测试里不可用）。
abstract class AssistantSpeaker {
  /// 朗读 [text]。
  ///
  /// 返回的 Future **读完才完成**（被 [stop]、引擎报错也完成）。界面的
  /// 「朗读 / 停止」按钮靠它判断什么时候收回状态——`FlutterTts.speak` 本身在
  /// Android 上是立刻返回的，不能当读完信号用。
  ///
  /// [onProgress] 回报「已读到的字符下标（不含）」。引擎不支持进度回报时不会
  /// 回调，界面就只是没有灰色高亮，不影响朗读本身。
  Future<void> speak(String text, {void Function(int endOffset)? onProgress});

  Future<void> stop();

  /// 语速，flutter_tts 取值 0.0–1.0（0.5 为正常）。
  Future<void> setRate(double rate);

  /// 音调，flutter_tts 取值 0.5–2.0（1.0 为正常）。
  Future<void> setPitch(double pitch);

  Future<void> dispose();
}

/// 使用 Android 系统 TTS。能否离线取决于手机安装的语音引擎和语音包。
///
/// 朗读不使用助手的凭据。初始化或朗读失败时 [speak]
/// 返回的 Future 以错误完成，由调用方决定怎么提示用户。
class SystemTtsSpeaker implements AssistantSpeaker {
  SystemTtsSpeaker({
    this.operationTimeout = const Duration(seconds: 8),
    this.completionTimeout,
  });

  final FlutterTts _tts = FlutterTts();

  /// 限制初始化、平台调用和停止等待；缺失引擎不能卡住界面。
  final Duration operationTimeout;

  /// 默认按文字长度与语速给足时间；可注入短时限验证引擎无回调的情况。
  final Duration? completionTimeout;

  double _rate = 0.5;
  double _pitch = 1.0;

  /// 当前这一句的「读完」信号。引擎只回报完成/取消/出错三种事件，这里把它们
  /// 翻译成一个 Future 交给调用方。
  Completer<void>? _utterance;
  Timer? _watchdog;

  @override
  Future<void> speak(String text, {void Function(int endOffset)? onProgress}) {
    if (text.isEmpty) return Future<void>.value();
    // 上一句若还挂着，先收尾，免得两个信号叠在一起。
    _finishUtterance(_utterance);
    final done = Completer<void>();
    _utterance = done;

    // 读完、被停、出错都必须收尾：否则界面会一直停在「停止」状态。
    _tts.setCompletionHandler(() => _finishUtterance(done));
    _tts.setCancelHandler(() => _finishUtterance(done));
    _tts.setErrorHandler(
      (_) => _finishUtterance(done, StateError('TTS engine error')),
    );
    // 总是替换进度回调，避免沿用上一段的监听者。
    _tts.setProgressHandler((_, _, end, _) {
      if (identical(_utterance, done)) onProgress?.call(end);
    });
    final deadline =
        completionTimeout ??
        Duration(
          seconds:
              30 + (text.runes.length / (_rate.clamp(0.1, 1.0) * 2)).ceil(),
        );
    _watchdog = Timer(deadline, () {
      if (!identical(_utterance, done)) return;
      _finishUtterance(done, TimeoutException('TTS did not report completion'));
      unawaited(_stopEngine());
    });
    unawaited(_startUtterance(text, done));
    return done.future;
  }

  Future<void> _startUtterance(String text, Completer<void> done) async {
    try {
      await _configureAndSpeak(text, done).timeout(operationTimeout);
    } catch (error) {
      // 状态码失败、初始化挂起、平台异常都要让页面拿到错误。
      if (!identical(_utterance, done)) return;
      _finishUtterance(done, error);
      unawaited(_stopEngine());
    }
  }

  Future<void> _configureAndSpeak(String text, Completer<void> done) async {
    // 每一步之后确认仍是同一段；超时/停止后迟到的平台响应不能再开始朗读。
    final language = await _tts.setLanguage('en-US');
    if (!identical(_utterance, done)) return;
    if (language != 1) {
      throw StateError('An English text-to-speech voice is unavailable');
    }
    final rate = await _tts.setSpeechRate(_rate);
    if (!identical(_utterance, done)) return;
    if (rate != 1) throw StateError('TTS speed could not be set');
    final pitch = await _tts.setPitch(_pitch);
    if (!identical(_utterance, done)) return;
    if (pitch != 1) throw StateError('TTS pitch could not be set');
    final accepted = await _tts.speak(text);
    if (!identical(_utterance, done)) return;
    if (accepted != 1) throw StateError('TTS did not accept the request');
  }

  void _finishUtterance(Completer<void>? done, [Object? error]) {
    if (done == null || !identical(_utterance, done)) return;
    _watchdog?.cancel();
    _watchdog = null;
    _utterance = null;
    if (done.isCompleted) return;
    if (error != null) {
      done.completeError(error);
    } else {
      done.complete();
    }
  }

  @override
  Future<void> setRate(double rate) async => _rate = rate;

  @override
  Future<void> setPitch(double pitch) async => _pitch = pitch;

  @override
  Future<void> stop() async {
    // 先释放等待者，不能让一个失去响应的 stop 平台调用阻止界面恢复。
    _finishUtterance(_utterance);
    await _stopEngine();
  }

  Future<void> _stopEngine() async {
    try {
      await _tts.stop().timeout(operationTimeout);
    } catch (_) {
      // 停止是尽力而为；初始化失败或平台无响应不应阻止提问、清空或离开页面。
    }
  }

  @override
  Future<void> dispose() => stop();
}
