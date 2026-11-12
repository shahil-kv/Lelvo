# TDLib's native library creates and reads these classes by name over JNI: renamed or removed, every TDLib answer
# fails at run time.
-keep class org.drinkless.tdlib.** { *; }
