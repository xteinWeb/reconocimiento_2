import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'theme/app_colors.dart';
import 'services/sync_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Iniciar temporizador automático para autogenerar faltas a las 4:00 PM
  SyncService().iniciarTemporizadorDiarioSc();
  
  runApp(const FacialAttendanceApp());
}

class FacialAttendanceApp extends StatelessWidget {
  const FacialAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BioAttendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: AppColors.primary,
        colorScheme: ColorScheme.light(
          primary: AppColors.primary,
          secondary: AppColors.secondary,
          surface: AppColors.surface,
          error: AppColors.error,
        ),
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: AppColors.kioskAccent,
        colorScheme: ColorScheme.dark(
          primary: AppColors.kioskAccent,
          secondary: AppColors.secondary,
          surface: AppColors.kioskSurface,
          error: AppColors.error,
        ),
        scaffoldBackgroundColor: AppColors.kioskBackground,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      themeMode: ThemeMode.dark, // Por defecto modo oscuro (kiosco) para el tótem
      home: const HomeScreen(),
    );
  }
}
