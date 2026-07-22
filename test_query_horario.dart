import 'package:sql_conn/sql_conn.dart';

void main() async {
  print('Connecting to database...');
  final success = await SqlConn.connect(
    connectionId: 'testHorario',
    host: '192.168.10.101',
    port: 1433,
    database: 'ARTDECON',
    username: 'sa',
    password: 'ADMadm1234',
  );
  if (!success) {
    print('Failed to connect.');
    return;
  }
  print('Connected!');

  try {
    print('Querying itm_horarios for 0103...');
    final results = await SqlConn.read('testHorario', """
      SELECT ID_UN, ITEM, ID_HORARIO, INICIO, FINAL, TIPO, DIAS 
      FROM itm_horarios 
      WHERE LTRIM(RTRIM(ID_HORARIO)) = '0103';
    """);
    print('Results: $results');
  } catch (e) {
    print('Error: $e');
  } finally {
    await SqlConn.disconnect('testHorario');
    print('Disconnected.');
  }
}
