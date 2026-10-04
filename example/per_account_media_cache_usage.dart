// Пример использования PerAccountMediaCache с размерным ограничением

import 'package:wellmagram/core/storage/per_account_media_cache.dart';
import 'package:wellmagram/core/accounts/account_key.dart';

class MediaManager {
  final PerAccountMediaCache _cache;
  
  MediaManager(this._cache);
  
  /// Сохраняет медиа-файл в кэше аккаунта
  Future<String> saveMedia(AccountKey account, String sourceFilePath) async {
    // Генерируем путь для сохранения в кэше
    String cacheDir = await _cache.rootFor(account);
    String fileName = _generateFileName(sourceFilePath);
    String cachePath = '$cacheDir/$fileName';
    
    // Копируем файл в кэш (реализация копирования опущена)
    await _copyFile(sourceFilePath, cachePath);
    
    // Добавляем файл в отслеживание кэша - это запустит eviction при необходимости
    await _cache.trackFile(account, cachePath);
    
    return cachePath;
  }
  
  /// Получает путь к закэшированному файлу
  Future<String?> getCachedMedia(AccountKey account, String originalFileName) async {
    String cacheDir = await _cache.rootFor(account);
    String cachePath = '$cacheDir/$_sanitizeFileName(originalFileName)';
    
    // Обновляем время доступа к файлу для LRU
    await _cache.touch(account, cachePath);
    
    return cachePath;
  }
  
  /// Проверяет, есть ли место для нового файла
  Future<bool> hasSpaceForNewMedia(AccountKey account, int fileSize) async {
    int currentSize = await _cache.getCurrentSize(account);
    return (currentSize + fileSize) <= _cache.maxSizeBytes;
  }
  
  // Вспомогательные методы (реализация опущена для краткости)
  String _generateFileName(String sourcePath) => 'cached_${DateTime.now().millisecondsSinceEpoch}';
  String _sanitizeFileName(String fileName) => fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  Future<void> _copyFile(String source, String destination) async {
    // Реализация копирования файла
  }
}

// Конфигурация для разных типов устройств
class CacheConfiguration {
  // Для бюджетных устройств
  static const int budgetDeviceLimit = 25 * 1024 * 1024; // 25MB
  
  // Для устройств со средней памятью
  static const int standardDeviceLimit = 50 * 1024 * 1024; // 50MB
  
  // Для устройств с большой памятью
  static const int highEndDeviceLimit = 100 * 1024 * 1024; // 100MB
}

// Пример инициализации с учетом характеристик устройства
/*
PerAccountMediaCache createCacheForDevice(AccountStoragePaths paths, AccountStorageFs fs, String deviceTier) {
  int limit;
  switch(deviceTier) {
    case 'budget':
      limit = CacheConfiguration.budgetDeviceLimit;
      break;
    case 'high_end':
      limit = CacheConfiguration.highEndDeviceLimit;
      break;
    default:
      limit = CacheConfiguration.standardDeviceLimit;
  }
  
  return PerAccountMediaCache(
    paths: paths,
    fs: fs,
    maxSizeBytes: limit
  );
}
*/