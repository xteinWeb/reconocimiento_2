# Proguard rules for jTDS and jcifs used by sql_conn plugin
-dontwarn jcifs.**
-dontwarn org.ietf.jgss.**
-dontwarn net.sourceforge.jtds.**
-keep class net.sourceforge.jtds.** { *; }
