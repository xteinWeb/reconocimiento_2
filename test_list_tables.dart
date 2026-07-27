import 'package:flutter/widgets.dart';
import 'package:sql_conn/sql_conn.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  print('Connecting to database...');
  final success = await SqlConn.connect(
    connectionId: 'listTables',
    host: '190.85.54.78',
    port: 9788,
    database: 'ARTDECON',
    username: 'sa',
    password: 'sql2025DEVadmin',
  );
  if (!success) {
    print('Failed to connect.');
    return;
  }
  print('Connected!');

  try {
    print('Querying sys.tables...');
    final results = await SqlConn.read('listTables', """
      SELECT name 
      FROM sys.tables 
      WHERE name LIKE '%ausencia%' 
         OR name LIKE '%novedad%' 
         OR name LIKE '%justifica%' 
         OR name LIKE '%asistencia%';
    """);
    print('Results: $results');
  } catch (e) {
    print('Error: $e');
  } finally {
    await SqlConn.disconnect('listTables');
    print('Disconnected.');
  }
}
