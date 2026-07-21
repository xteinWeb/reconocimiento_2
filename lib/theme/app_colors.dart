import 'package:flutter/material.dart';

class AppColors {
  // Primary (Gold/Bronze corporativo)
  static const Color primary = Color(0xFFB39C70);
  static const Color primaryDark = Color(0xFF8B754B);
  static const Color primaryLight = Color(0xFFD6C096);

  // Secondary (Green/Olive corporativo)
  static const Color secondary = Color(0xFF5E6738);
  static const Color secondaryDark = Color(0xFF3F4623);
  static const Color secondaryLight = Color(0xFF838E5B);

  // Accent (Beige corporativo)
  static const Color accent = Color(0xFFD9C5B2);

  // Backgrounds
  static const Color background = Color(0xFFF7F4F0);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color cardBackground = Color(0xFFFFFFFF);

  // Text
  static const Color textPrimary = Color(0xFF222222); // Neutral Black C
  static const Color textSecondary = Color(0xFF5A5A5A);
  static const Color textDisabled = Color(0xFFBDBDBD);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Status
  static const Color success = Color(0xFF5E6738); // Reutilizamos el verde corporativo
  static const Color successLight = Color(0xFFEFEFEA);
  static const Color error = Color(0xFFC62828);
  static const Color errorLight = Color(0xFFFFEBEE);
  static const Color warning = Color(0xFFE65100);
  static const Color warningLight = Color(0xFFFFF3E0);
  static const Color info = Color(0xFFB39C70); // Usamos el gold para info
  static const Color infoLight = Color(0xFFF7F4F0);

  // Attendance types
  static const Color colorNormal = Color(0xFF5E6738); // Verde corporativo
  static const Color colorRetardo = Color(0xFFE65100);
  static const Color colorPermiso = Color(0xFFB39C70); // Gold corporativo
  static const Color colorAlmuerzo = Color(0xFF8B754B);
  static const Color colorSalida = Color(0xFFD9C5B2); // Beige corporativo
  static const Color colorExtras = Color(0xFF3F4623);
  static const Color colorNoRegistrar = Color(0xFFB71C1C);

  // Borders & Dividers
  static const Color border = Color(0xFFD9C5B2); // Beige corporativo para bordes suaves
  static const Color divider = Color(0xFFEFEFEA);

  // Kiosk mode (dark bg for totem)
  static const Color kioskBackground = Color(0xFF1B2815); // Verde oscuro basado en el corporativo
  static const Color kioskSurface = Color(0xFF2B3A24);
  static const Color kioskAccent = Color(0xFFB39C70); // Gold corporativo para destacar en modo oscuro
}
