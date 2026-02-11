module app_version;

enum APP_VERSION_MAJOR = 0;
enum APP_VERSION_MINOR = 1;
enum APP_VERSION_PATCH = 0;

public enum string APP_VERSION_STR = "" ~ APP_VERSION_MAJOR ~ "." ~ APP_VERSION_MINOR ~ "." ~ APP_VERSION_PATCH;
