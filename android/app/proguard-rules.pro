# TDLib's native library creates and reads these classes by name over JNI: renamed or removed, every TDLib answer
# fails at run time.
-keep class org.drinkless.tdlib.** { *; }

# ML Kit builds its labeller from components it finds by name (manifest metadata, then reflection). With R8 they were
# stripped or merged, and ImageLabeling.getClient() threw a NullPointerException on the first photo read: the release
# app crashed on launch for anyone who allowed photo access. Debug builds aren't shrunk, so it never showed there.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
