// Конфигурация для PerAccountMediaCache
// Файл: lib/config/cache_config.dart

class CacheConfig {
  // Лимиты кэша по умолчанию (в байтах)
  static const int defaultMediaCacheSizeLimit = 50 * 1024 * 1024; // 50 MB
  static const int minMediaCacheSizeLimit = 10 * 1024 * 1024;     // 10 MB
  static const int maxMediaCacheSizeLimit = 200 * 1024 * 1024;    // 200 MB
  
  // Лимиты для разных профилей устройств
  static const Map<String, int> deviceProfiles = {
    'low_end': 25 * 1024 * 1024,      // 25 MB для слабых устройств
    'mid_range': 50 * 1024 * 1024,    // 50 MB для средних устройств
    'high_end': 100 * 1024 * 1024,    // 100 MB для мощных устройств
    'tablet': 150 * 1024 * 1024,      // 150 MB для планшетов
  };
  
  // Метод для получения лимита для конкретного профиля устройства
  static int getCacheLimitForDeviceProfile(String profile) {
    return deviceProfiles[profile] ?? defaultMediaCacheSizeLimit;
  }
  
  // Проверка, находится ли значение лимита в допустимом диапазоне
  static bool isValidCacheLimit(int limit) {
    return limit >= minMediaCacheSizeLimit && limit <= maxMediaCacheSizeLimit;
  }
}