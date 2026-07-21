import 'package:flutter_test/flutter_test.dart';
import 'package:reconocimiento_facial/main.dart';

void main() {
  testWidgets('Smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const FacialAttendanceApp());
    expect(find.text('BioAttendance'), findsOneWidget);
  });
}
