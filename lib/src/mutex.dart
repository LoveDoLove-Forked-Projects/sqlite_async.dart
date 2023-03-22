// Adapted from:
//  https://github.com/tekartik/synchronized.dart
//  (MIT)
import 'dart:async';
import 'dart:isolate';

import './isolate_completer.dart';

abstract class Mutex {
  factory Mutex() {
    return SimpleMutex();
  }

  factory Mutex.shared() {
    return SharedMutex._();
  }

  /// timeout is a timeout for acquiring the lock, not for the callback
  Future<T> lock<T>(Future<T> Function() callback, {Duration? timeout});

  Future<void> close();
}

int mutexId = 0;

/// Mutex maintains a queue of Future-returning functions that
/// are executed sequentially.
/// The internal lock is not shared across Isolates by default.
class SimpleMutex implements Mutex {
  // Adapted from https://github.com/tekartik/synchronized.dart/blob/master/synchronized/lib/src/basic_lock.dart

  Future<dynamic>? last;

  // Hack to make sure the Mutex is not copied to another isolate.
  // ignore: unused_field
  final Finalizer _f = Finalizer((_) {});

  SimpleMutex();

  bool get locked => last != null;

  SharedMutex? _shared;

  @override
  Future<T> lock<T>(Future<T> Function() callback, {Duration? timeout}) async {
    if (Zone.current[this] != null) {
      throw AssertionError('Recursive lock is not allowed');
    }
    var zone = Zone.current.fork(zoneValues: {this: true});

    return zone.run(() async {
      final prev = last;
      final completer = Completer<void>.sync();
      last = completer.future;
      try {
        // If there is a previous running block, wait for it
        if (prev != null) {
          if (timeout != null) {
            // This could throw a timeout error
            try {
              await prev.timeout(timeout);
            } catch (error) {
              if (error is TimeoutException) {
                throw TimeoutException('Failed to acquire lock', timeout);
              } else {
                rethrow;
              }
            }
          } else {
            await prev;
          }
        }

        // Run the function and return the result
        return await callback();
      } finally {
        // Cleanup
        // waiting for the previous task to be done in case of timeout
        void complete() {
          // Only mark it unlocked when the last one complete
          if (identical(last, completer.future)) {
            last = null;
          }
          completer.complete();
        }

        // In case of timeout, wait for the previous one to complete too
        // before marking this task as complete
        if (prev != null && timeout != null) {
          // But we still returns immediately
          prev.then((_) {
            complete();
          }).ignore();
        } else {
          complete();
        }
      }
    });
  }

  @override
  Future<void> close() async {
    _shared?.close();
    await lock(() async {});
  }

  SharedMutex get shared {
    _shared ??= SharedMutex._withMutex(this);
    return _shared!;
  }
}

/// Like Mutex, but can be coped across Isolates.
class SharedMutex implements Mutex {
  late final SendPort _lockPort;

  factory SharedMutex._() {
    final Mutex mutex = Mutex();
    return SharedMutex._withMutex(mutex);
  }

  SharedMutex._withMutex(Mutex mutex) {
    final ReceivePort receivePort = ReceivePort();

    receivePort.listen((dynamic arg) {
      if (arg is _AcquireMessage) {
        IsolateResult unlock = IsolateResult();
        mutex.lock(() async {
          arg.completer.complete(unlock.completer);
          await unlock.future;
          unlock.close();
        });
      } else if (arg is _CloseMessage) {
        if (arg.isSameIsolate()) {
          mutex.lock(() async {
            receivePort.close();
            arg.port.complete();
          });
        } else {
          arg.port.completeError(AssertionError(
              'A Mutex may only be closed from the Isolate that created it'));
        }
      }
    });
    _lockPort = receivePort.sendPort;
  }

  @override
  Future<void> close() async {
    final r = IsolateResult<void>();
    _lockPort.send(_CloseMessage(r.completer));
    await r.future;
  }

  @override
  Future<T> lock<T>(Future<T> Function() callback, {Duration? timeout}) async {
    if (Zone.current[this] != null) {
      throw AssertionError('Recursive lock is not allowed');
    }
    return runZoned(() async {
      final releaseCompleter = await acquire(timeout: timeout);
      try {
        final T result = await callback();
        return result;
      } finally {
        releaseCompleter.complete(true);
      }
    }, zoneValues: {this: true});
  }

  Future<PortCompleter> acquire({Duration? timeout}) async {
    final r = IsolateResult<PortCompleter>();
    _lockPort.send(_AcquireMessage(r.completer));
    var lockFuture = r.future;
    bool timedout = false;

    var handledLockFuture = lockFuture.then((lock) {
      lock.addExitHandler();
      if (timedout) {
        lock.complete();
        throw TimeoutException('Failed to acquire lock', timeout);
      }
      return lock;
    });

    if (timeout != null) {
      handledLockFuture =
          handledLockFuture.timeout(timeout).catchError((error, stacktrace) {
        timedout = true;
        if (error is TimeoutException) {
          throw TimeoutException('Failed to acquire SharedMutex lock', timeout);
        }
        throw error;
      });
    }
    return await handledLockFuture;
  }
}

class _CloseMessage {
  final PortCompleter port;
  late final int code;

  _CloseMessage(this.port) {
    code = Isolate.current.hashCode;
  }

  isSameIsolate() {
    return Isolate.current.hashCode == code;
  }
}

class _AcquireMessage {
  final PortCompleter completer;

  _AcquireMessage(this.completer);
}
