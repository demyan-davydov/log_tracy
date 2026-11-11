//! The version of the application: major, minor, patch and its text.
module app_version;

public enum APP_VERSION_MAJOR = 0;
public enum APP_VERSION_MINOR = 1;
public enum APP_VERSION_PATCH = 0;

public enum string APP_VERSION_STR = "" ~ APP_VERSION_MAJOR ~ "." ~ APP_VERSION_MINOR ~ "." ~ APP_VERSION_PATCH;
